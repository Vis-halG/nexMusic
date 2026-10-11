import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

/// Cloudflare Worker that sends activity notifications to the other phones
/// (see push_worker/worker.js). Not a secret: it only accepts signed-in
/// nexMusic users. Activity is not reported while it is empty.
const pushWorkerUrl = String.fromEnvironment(
  'PUSH_WORKER_URL',
  defaultValue: 'https://nexmusic-push.vishalgupta25989.workers.dev',
);

/// A notification about something someone did in the shared catalogue.
typedef Activity = ({String title, String body});

/// Notification for a finished upload batch.
Activity uploadActivity(List<String> titles, String category) {
  if (titles.length == 1) {
    return (title: 'New upload in $category', body: titles.first);
  }
  final more = titles.length - 2;
  return (
    title: '${titles.length} new uploads in $category',
    body: more > 0
        ? '${titles.take(2).join(', ')} and $more more'
        : titles.join(' and '),
  );
}

/// Notification for a song that was renamed, moved, or both. Null when
/// nothing changed.
Activity? songEditActivity({
  required String oldTitle,
  required String newTitle,
  String? movedTo,
}) {
  final renamed = oldTitle != newTitle;
  if (renamed && movedTo != null) {
    return (
      title: 'Song updated',
      body: '$oldTitle → $newTitle · moved to $movedTo',
    );
  }
  if (renamed) return (title: 'Song renamed', body: '$oldTitle → $newTitle');
  if (movedTo != null) return (title: 'Song moved to $movedTo', body: newTitle);
  return null;
}

Activity songDeleteActivity(String title) =>
    (title: 'Song removed', body: title);

Activity categoryCreateActivity(String name) =>
    (title: 'New category', body: name);

Activity categoryRenameActivity(String from, String to) =>
    (title: 'Category renamed', body: '$from → $to');

/// Notification for a deleted category and the [songs] deleted with it.
Activity categoryDeleteActivity(String name, {int songs = 0}) => (
  title: 'Category deleted',
  body: songs == 0
      ? name
      : '$name · $songs song${songs == 1 ? '' : 's'} removed',
);

/// Shows playback controls on the lock screen and in the notification bar,
/// and keeps music playing while nexMusic is in the background.
class NexAudioHandler extends BaseAudioHandler with SeekHandler {
  NexAudioHandler(this.player) {
    bindPlayer(player);
  }
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];
  void bindPlayer(AudioPlayer value) {
    for (final subscription in _playerSubscriptions) {
      unawaited(subscription.cancel());
    }
    _playerSubscriptions.clear();
    player = value;
    _playerSubscriptions.add(
      player.playbackEventStream.listen(
        (_) => _broadcast(),
        onError: (Object _, StackTrace _) {},
      ),
    );
    _playerSubscriptions.add(player.playingStream.listen((_) => _broadcast()));
    _broadcast();
  }

  AudioPlayer player;
  Future<void> Function()? onPlay, onPause, onStop;
  Future<void> Function(Duration)? onSeek;
  Future<void> Function(String)? onPlayMediaId;
  Future<List<MediaItem>> Function(String)? onBrowse;

  /// Set by the controller so the notification buttons follow the app queue.
  Future<void> Function()? onNext, onPrevious;

  void _broadcast() {
    final playing = player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          const MediaControl(
            androidIcon: 'drawable/ic_player_close',
            label: 'Close player',
            action: MediaAction.stop,
          ),
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering =>
            playing
                ? AudioProcessingState.ready
                : AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (onPlay != null) {
      await onPlay!();
    } else {
      unawaited(player.play());
    }
    _broadcast();
  }

  @override
  Future<void> pause() async {
    if (onPause != null) {
      await onPause!();
    } else {
      await player.pause();
    }
    _broadcast();
  }

  @override
  Future<void> seek(Duration position) =>
      onSeek?.call(position) ?? player.seek(position);

  @override
  Future<void> stop() async {
    if (onStop != null) {
      await onStop!();
    } else {
      await player.stop();
    }
    await super.stop();
    _broadcast();
  }

  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrevious?.call();

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async => onPlayMediaId?.call(mediaId);
  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async =>
      onBrowse?.call(
        parentMediaId == AudioService.browsableRootId ? 'root' : parentMediaId,
      ) ??
      [];
}

/// Home screen widgets, upload and download progress notifications, and
/// activity push notifications on Android. Calls do nothing where the
/// platform code is missing, e.g. in tests.
class PhoneServices {
  PhoneServices({
    required this._auth,
    required this._firestore,
    required this._messaging,
  }) {
    _channel.setMethodCallHandler((call) async {
      final action = call.arguments;
      if (call.method == 'launchAction' && action is String) {
        _launchActions.add(action);
      }
    });
  }

  static const _channel = MethodChannel('com.thenex.nexmusic/phone');
  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final FirebaseMessaging _messaging;
  final _launchActions = StreamController<String>.broadcast();
  StreamSubscription<String>? _tokenRefresh;
  StreamSubscription<RemoteMessage>? _foregroundMessages;
  var _activityId = 0;

  /// Widget taps that reach a running app: `play:<songId>`, `player`,
  /// `upload`, `search`, `browser` or `downloads`.
  Stream<String> get launchActions => _launchActions.stream;

  /// The widget action that started the app, if any.
  Future<String?> takeLaunchAction() => _call<String>('takeLaunchAction');

  /// Shows or updates an ongoing progress notification. A null [percent]
  /// shows an indeterminate bar.
  Future<void> showProgress(
    int id, {
    required String title,
    required String text,
    int? percent,
  }) => _call<void>('showProgress', {
    'id': id,
    'title': title,
    'text': text,
    'percent': percent ?? -1,
  });

  /// Replaces a progress notification with a finished one.
  Future<void> showDone(
    int id, {
    required String title,
    required String text,
  }) => _call<void>('showDone', {'id': id, 'title': title, 'text': text});

  Future<void> showActivity(String title, String body) => _call<void>(
    'showActivity',
    {'id': 3000 + (++_activityId % 1000), 'title': title, 'text': body},
  );

  /// Hands the latest songs and playback state to the home screen widgets.
  Future<void> updateWidgets(String json) =>
      _call<void>('updateWidgets', {'data': json});

  /// Lets the Now playing widget control playback while a song is loaded.
  Future<void> setSessionActive(bool active) =>
      _call<void>('setSessionActive', {'active': active});

  /// Launches Android's system package installer for the APK at [filePath].
  Future<bool> installApk(String filePath) async {
    final success = await _call<bool>('installApk', {'path': filePath});
    return success ?? false;
  }

  /// Opens an external URL in the system browser.
  Future<bool> openUrl(String url) async {
    final success = await _call<bool>('openUrl', {'url': url});
    return success ?? false;
  }

  /// Returns the installed application version from Android's PackageManager.
  Future<({String versionName, int buildNumber, String version})?>
  getAppVersion() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'getAppVersion',
      );
      if (res != null) {
        final name = (res['versionName'] as String?) ?? '';
        final build = (res['buildNumber'] as num?)?.toInt() ?? 0;
        final ver =
            (res['version'] as String?) ?? (build > 0 ? '$name+$build' : name);
        return (versionName: name, buildNumber: build, version: ver);
      }
    } catch (e) {
      debugPrint('Error fetching installed app version: $e');
    }
    return null;
  }

  /// Opens Android's chooser for any number of audio and video files. It
  /// returns content URIs with names and sizes and copies nothing, so a big
  /// batch cannot fill the phone. Null when the native chooser is missing.
  Future<List<({String uri, String name, int size})>?> pickMedia() async {
    try {
      final chosen = await _channel.invokeListMethod<Object?>('pickMedia');
      return [
        for (final entry in chosen ?? const <Object?>[])
          if (entry is Map)
            (
              uri: '${entry['uri']}',
              name: '${entry['name']}',
              size: (entry['size'] as num?)?.toInt() ?? -1,
            ),
      ];
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('File chooser failed: ${error.message}');
      return null;
    }
  }

  /// Copies a chosen file into the cache just before it uploads.
  Future<String> copyToCache(String uri, String name) async {
    try {
      final copy = await _channel.invokeMethod<String>('copyToCache', {
        'uri': uri,
        'name': name,
      });
      if (copy == null) throw const FileSystemException('No copy was made.');
      return copy;
    } on PlatformException catch (error) {
      throw FileSystemException(error.message ?? 'The file could not be read.');
    }
  }

  /// Copies a device song while preserving its real audio file extension.
  Future<File> copyAudioToCache(String uri) async {
    final copied = await _channel.invokeMethod<String>('copyAudioToCache', {
      'uri': uri,
    });
    if (copied == null) {
      throw const FileSystemException('The device song could not be read.');
    }
    return File(copied);
  }

  /// Reads an embedded artist tag from a local upload copy.
  Future<String> readMediaArtist(String filePath) async =>
      (await _call<String>('readMediaArtist', {'path': filePath}))?.trim() ??
      '';

  /// Gives back the lasting read access taken when a file was chosen.
  Future<void> releaseUri(String uri) =>
      _call<void>('releaseUri', {'uri': uri});

  Future<T?> _call<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('Phone service $method failed: ${error.message}');
      return null;
    }
  }

  // ── Activity push notifications ──────────────────────────────────────────

  /// Asks for notification permission and registers this phone, so it is
  /// told when someone else uploads, edits or deletes.
  Future<void> enablePush() async {
    if (_auth.currentUser == null) return;
    try {
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      final token = await _messaging.getToken();
      if (token != null) await _saveToken(token);
      _tokenRefresh ??= _messaging.onTokenRefresh.listen(
        (token) => unawaited(_saveToken(token)),
      );
      // Android only shows push notifications by itself while the app is
      // closed or in the background.
      _foregroundMessages ??= FirebaseMessaging.onMessage.listen((message) {
        final notification = message.notification;
        if (notification == null) return;
        unawaited(
          showActivity(
            notification.title ?? 'nexMusic',
            notification.body ?? '',
          ),
        );
      });
    } catch (error) {
      debugPrint('Push notifications could not be enabled: $error');
    }
  }

  /// Stops activity notifications on this phone. Call it before signing out.
  Future<void> disablePush() async {
    await _tokenRefresh?.cancel();
    await _foregroundMessages?.cancel();
    _tokenRefresh = null;
    _foregroundMessages = null;
    try {
      final token = await _messaging.getToken();
      if (token != null && _auth.currentUser != null) {
        await _tokenDocument(token).delete();
      }
      await _messaging.deleteToken();
    } catch (error) {
      debugPrint('Push notifications could not be disabled: $error');
    }
  }

  Future<void> _saveToken(String token) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    try {
      await _tokenDocument(token).set({
        'uid': uid,
        'token': token,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (error) {
      debugPrint('Push token could not be saved: $error');
    }
  }

  /// FCM tokens contain ':' which Google REST paths treat specially, so the
  /// document id is the token in base64url.
  DocumentReference<Map<String, dynamic>> _tokenDocument(String token) =>
      _firestore
          .collection('pushTokens')
          .doc(base64Url.encode(utf8.encode(token)).replaceAll('=', ''));

  /// Sends [activity] to every other signed-in phone through the Worker.
  Future<void> report(Activity activity) async {
    final user = _auth.currentUser;
    if (pushWorkerUrl.isEmpty || user == null) return;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final idToken = await user.getIdToken();
      final request = await client.postUrl(Uri.parse(pushWorkerUrl));
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $idToken')
        ..contentType = ContentType.json;
      request.write(
        jsonEncode({'title': activity.title, 'body': activity.body}),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      // The Worker replies with how many phones it notified, or an error.
      final reply = await response.transform(utf8.decoder).join();
      debugPrint('Activity notification: HTTP ${response.statusCode} $reply');
    } catch (error) {
      debugPrint('Activity notification failed: $error');
    } finally {
      client.close(force: true);
    }
  }
}
