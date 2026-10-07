import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_update.dart';
import 'cloudinary_status.dart';
import 'main.dart';
import 'media_library.dart';
import 'music_controller.dart';
import 'music_data.dart';
import 'music_discovery.dart';
import 'listening_models.dart';
import 'music_downloads.dart';
import 'music_lyrics.dart';
import 'music_device.dart';
import 'music_longform.dart';
import 'music_portability.dart';
import 'music_catalog.dart';
import 'music_artists.dart';
import 'music_social.dart';
import 'song_selection.dart';
import 'music_sharing.dart';
import 'phone_services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'listening_ui.dart';
part 'discovery_ui.dart';
part 'social_ui.dart';
part 'recognition_ui.dart';
part 'device_ui.dart';
part 'portability_ui.dart';
part 'previews_ui.dart';
part 'song_selection_ui.dart';
part 'advance_ui.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

bool get _webViewSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Color _muted(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

String _time(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String _fileSize(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).ceil()} KB';

String _fileName(String filePath) => filePath.split(RegExp(r'[\\/]')).last;

IconData _mediaIcon(SavedMedia item) => switch (item.kind) {
  'audio' => Icons.music_note_rounded,
  'video' => Icons.play_arrow_rounded,
  _ => Icons.link_rounded,
};

String _mediaSubtitle(MusicController music, SavedMedia item) {
  final type = switch (item.kind) {
    'audio' => 'Audio',
    'video' => 'Video',
    _ => 'Link',
  };
  return music.isDownloaded(item) ? '$type · Offline' : type;
}

void _push(BuildContext context, Widget screen) {
  Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => screen));
}

Future<void> _openSong(
  BuildContext context,
  Song song, {
  List<Song>? queue,
}) async {
  final selection = context.read<SongSelection?>();
  if (selection != null && selection.active && queue != null) {
    selection.toggle(song, queue);
    return;
  }
  final music = context.read<MusicController>();
  if (song.isVideo) {
    try {
      final url = await music.resolvedPlayableUrl(song);
      if (!context.mounted) return;
      _push(
        context,
        VideoScreen(
          song: song.copyWith(url: url),
          httpHeaders: music.playbackHeadersFor(song),
        ),
      );
    } catch (_) {
      music.announce('Could not load this video. Try another result.');
    }
    return;
  }
  await music.play(song, from: queue);
}

Future<void> _openSongVideo(BuildContext context, Song song) async {
  final music = context.read<MusicController>();
  final account = music.personal;
  final matching = music.current?.id == song.id;
  final resume = matching && music.playing;
  var exitPosition = matching ? music.position : Duration.zero;
  try {
    await music.pauseAudio();
    final videoSong = song.copyWith(kind: 'video');
    final url = await music.resolvedPlayableUrl(videoSong);
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => VideoScreen(
          song: videoSong.copyWith(url: url),
          httpHeaders: music.playbackHeadersFor(videoSong),
          initialPosition: exitPosition,
          onClosed: (position) => exitPosition = position,
        ),
      ),
    );
    if (account == music.personal && matching && music.current?.id == song.id) {
      await music.play(song, initialPosition: exitPosition);
      if (!resume) await music.pauseAudio();
    }
  } catch (_) {
    music.announce('Could not load video for this track.');
    if (resume && account == music.personal) await music.playback.resume();
  }
}

void _openPlayer(BuildContext context) {
  Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const NowPlayingScreen(),
    ),
  );
}

Future<void> _sheet(
  BuildContext context,
  List<Widget> Function(BuildContext sheetContext) children, {
  String? title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ...children(sheetContext),
            ],
          ),
        ),
      ),
    ),
  );
}

void _showUpdateSheet(
  BuildContext context,
  AppUpdateInfo info, {
  VoidCallback? onDismiss,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _UpdateSheet(info: info, onDismiss: onDismiss),
  );
}

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({required this.info, this.onDismiss});
  final AppUpdateInfo info;
  final VoidCallback? onDismiss;

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  bool _downloading = false;
  double _fraction = 0.0;
  String? _error;

  Future<void> _startUpdate() async {
    setState(() {
      _downloading = true;
      _fraction = 0.0;
      _error = null;
    });
    final phone = context.read<MusicController>().phone;
    final service = AppUpdateService();
    final file = await service.downloadApk(
      widget.info,
      onProgress: (progress) {
        if (mounted) setState(() => _fraction = progress);
      },
    );
    if (!mounted) return;
    if (file == null) {
      setState(() {
        _downloading = false;
        _error = 'Download failed. Tap to try again or open in browser.';
      });
      return;
    }
    setState(() => _downloading = false);
    final installed = await service.installUpdate(file, phone);
    if (!installed && mounted) {
      await phone?.openUrl(widget.info.downloadUrl);
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mutedColor = _muted(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: NexMusic.violet.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.rocket_launch_rounded,
                    color: NexMusic.violet,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Update Available',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.info.displayVersion}${widget.info.formattedSize.isNotEmpty ? ' · ${widget.info.formattedSize}' : ''}',
                        style: TextStyle(
                          fontSize: 13,
                          color: mutedColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (widget.info.releaseNotes.isNotEmpty) ...[
              Text(
                "What's new:",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: mutedColor,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 140),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.brightness == Brightness.dark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    widget.info.releaseNotes,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
              const SizedBox(height: 12),
            ],
            if (_downloading) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Downloading update…',
                    style: TextStyle(fontSize: 13, color: mutedColor),
                  ),
                  Text(
                    '${(_fraction * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: NexMusic.violet,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _fraction > 0 ? _fraction : null,
                  minHeight: 6,
                  color: NexMusic.violet,
                  backgroundColor: NexMusic.violet.withValues(alpha: 0.15),
                ),
              ),
              const SizedBox(height: 16),
            ] else ...[
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: _startUpdate,
                  style: FilledButton.styleFrom(
                    backgroundColor: NexMusic.violet,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.download_rounded),
                  label: const Text(
                    'Update Now',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () {
                    widget.onDismiss?.call();
                    Navigator.of(context).pop();
                  },
                  child: Text('Later', style: TextStyle(color: mutedColor)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<String?> _nameDialog(
  BuildContext context, {
  required String title,
  required String action,
  String? hint,
  String? initialValue,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(
      title: title,
      action: action,
      hint: hint,
      initialValue: initialValue,
    ),
  );
  final trimmed = result?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<MusicCategory?> _createCategory(BuildContext context) async {
  final music = context.read<MusicController>();
  final name = await _nameDialog(
    context,
    title: 'New category',
    action: 'Create',
    hint: 'e.g. Bollywood',
  );
  if (name == null) return null;
  return music.createCategory(name);
}

Future<MediaFolder?> _createFolder(BuildContext context) async {
  final music = context.read<MusicController>();
  final name = await _nameDialog(
    context,
    title: 'New folder',
    action: 'Create',
    hint: 'e.g. Workout clips',
  );
  if (name == null) return null;
  return music.createMediaFolder(name);
}

/// Native Android helpers for trimming and extracting audio.
const _mediaTools = MethodChannel('com.thenex.nexmusic/media_tools');

bool get _canTrim => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Opens the trim screen for an upload and applies the chosen range.
Future<bool> _trimUpload(BuildContext context, UploadItem item) async {
  final result = await Navigator.of(context)
      .push<({String path, Duration start, Duration end})>(
        MaterialPageRoute(
          builder: (_) => TrimScreen(
            source: item.original?.path ?? item.path,
            title: item.title,
            start: item.trimStart,
            end: item.trimEnd,
          ),
        ),
      );
  if (result == null) return false;
  final previousCopy = item.trimmed ? item.path : null;
  item.applyTrim(
    trimmedPath: result.path,
    trimmedSize: File(result.path).lengthSync(),
    start: result.start,
    end: result.end,
  );
  if (previousCopy != null) discardTemporaryCopy(previousCopy);
  return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Rounded choice used for categories, folders and "new" actions.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.icon,
    this.onLongPress,
  });
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.surface : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        height: 36,
        child: Material(
          color: selected ? scheme.onSurface : Colors.transparent,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected ? scheme.onSurface : scheme.outlineVariant,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: foreground),
                    const SizedBox(width: 4),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Required single choice (category or folder) with a trailing "new" pill.
class _ChoicePicker extends StatelessWidget {
  const _ChoicePicker({
    required this.label,
    required this.options,
    required this.selectedId,
    required this.onChanged,
    required this.onCreate,
    required this.createLabel,
    this.onManage,
  });
  final String label, createLabel;
  final List<({String id, String name})> options;
  final String? selectedId;
  final ValueChanged<String> onChanged;
  final Future<String?> Function() onCreate;

  /// Opens a screen to rename or delete the options, when set.
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: _muted(context)),
            ),
          ),
          if (onManage != null)
            TextButton.icon(
              onPressed: onManage,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Edit', style: TextStyle(fontSize: 13)),
            ),
        ],
      ),
      SizedBox(height: onManage == null ? 10 : 2),
      Wrap(
        runSpacing: 8,
        children: [
          for (final option in options)
            _Pill(
              label: option.name,
              selected: option.id == selectedId,
              onTap: () => onChanged(option.id),
            ),
          _Pill(
            icon: Icons.add_rounded,
            label: createLabel,
            onTap: () async {
              final id = await onCreate();
              if (id != null) onChanged(id);
            },
          ),
        ],
      ),
    ],
  );
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.icon,
    this.active = false,
    this.size = 44,
    this.imageUrl = '',
  });
  final IconData icon;
  final bool active;
  final double size;
  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Icon(
      icon,
      size: size * 0.46,
      color: active ? NexMusic.violet : scheme.onSurfaceVariant,
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: active
            ? NexMusic.violet.withValues(alpha: 0.12)
            : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(size * 0.22),
        border: active ? Border.all(color: NexMusic.violet, width: 1.5) : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: imageUrl.isEmpty
          ? fallback
          : Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initials, this.size = 36});
  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: scheme.surfaceContainer,
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: TextStyle(
          fontSize: size * 0.36,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: _muted(context)),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted(context), fontSize: 13, height: 1.4),
          ),
        ],
      ),
    ),
  );
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.trailing,
    this.showChevron = true,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailing;
  final bool showChevron;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle != null
        ? Text(
            subtitle!,
            style: TextStyle(color: _muted(context), fontSize: 12),
          )
        : null,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (trailing != null)
          Text(trailing!, style: TextStyle(color: _muted(context))),
        if (showChevron)
          Icon(Icons.chevron_right_rounded, color: _muted(context)),
      ],
    ),
    onTap: onTap,
    onLongPress: onLongPress,
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.action,
    this.hint,
    this.initialValue,
  });
  final String title, action;
  final String? hint, initialValue;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(hintText: widget.hint),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        style: TextButton.styleFrom(foregroundColor: NexMusic.violet),
        onPressed: () => Navigator.pop(context, _controller.text),
        child: Text(widget.action),
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sign in
// ─────────────────────────────────────────────────────────────────────────────

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context
        .select<
          MusicController,
          ({bool loading, bool configured, String? notice})
        >(
          (music) => (
            loading: music.loading,
            configured: music.backendConfigured,
            notice: music.notice,
          ),
        );
    final music = context.read<MusicController>();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(3),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/branding/nexmusic-logo.png',
                      width: 56,
                      height: 56,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'nexMusic',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Upload songs and videos into categories.\nEveryone signed in can listen.',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: _muted(context),
                ),
              ),
              const Spacer(),
              // The snackbar host only exists after sign-in, so login errors
              // are shown inline here.
              if (state.notice != null) ...[
                Text(
                  state.notice!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              OutlinedButton(
                onPressed: state.loading || !state.configured
                    ? null
                    : music.signInWithGoogle,
                child: state.loading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _GoogleLogo(),
                          SizedBox(width: 12),
                          Text('Continue with Google'),
                        ],
                      ),
              ),
              TextButton(
                onPressed: music.enterGuestMode,
                child: const Text('Continue on this device'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoogleLogo extends StatelessWidget {
  const _GoogleLogo();
  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 20,
    child: CustomPaint(painter: _GoogleLogoPainter()),
  );
}

class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();
  static const _blue = Color(0xFF4285F4);
  static const _red = Color(0xFFEA4335);
  static const _yellow = Color(0xFFFBBC05);
  static const _green = Color(0xFF34A853);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.18;
    final rect =
        Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = stroke;
    paint.color = _red;
    canvas.drawArc(rect, -2.45, 1.35, false, paint);
    paint.color = _yellow;
    canvas.drawArc(rect, 2.35, 0.98, false, paint);
    paint.color = _green;
    canvas.drawArc(rect, 1.05, 1.35, false, paint);
    paint.color = _blue;
    canvas.drawArc(rect, -0.1, 1.18, false, paint);
    final barPaint = Paint()
      ..color = _blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.square;
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawLine(
      center,
      Offset(size.width - stroke * 0.35, center.dy),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Home: one screen with category pills and every upload
// ─────────────────────────────────────────────────────────────────────────────

class MusicShell extends StatefulWidget {
  const MusicShell({super.key});
  @override
  State<MusicShell> createState() => _MusicShellState();
}

class _MusicShellState extends State<MusicShell> with WidgetsBindingObserver {
  StreamSubscription<List<SharedMediaFile>>? _shareSubscription;
  StreamSubscription<String>? _launchSubscription;
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kIsWeb) return;
    final phone = context.read<MusicController>().phone;
    _launchSubscription = phone?.launchActions.listen(_runLaunchAction);
    phone?.takeLaunchAction().then((action) {
      if (action != null) _runLaunchAction(action);
    });
    _shareSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      _openSharedItems,
      onError: (Object _) {},
    );
    ReceiveSharingIntent.instance.getInitialMedia().then((items) {
      _openSharedItems(items);
      ReceiveSharingIntent.instance.reset();
    }, onError: (Object _) {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAutoUpdate();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAutoUpdate();
    }
  }

  void _checkAutoUpdate() {
    if (!mounted || kIsWeb) return;
    _updateTimer?.cancel();
    _updateTimer = Timer(const Duration(milliseconds: 1500), () async {
      if (!mounted) return;
      try {
        final controller = context.read<MusicController>();
        final update = await AppUpdateService().checkForUpdate(
          phone: controller.phone,
        );
        debugPrint('Auto update check result: ${update?.displayVersion}');
        if (update != null && mounted) {
          final lastDismissed = controller.preferences.getString(
            'dismissed_update_tag',
          );
          if (lastDismissed == update.tagName) {
            debugPrint('Update ${update.tagName} was dismissed; skipping.');
            return;
          }
          _showUpdateSheet(
            context,
            update,
            onDismiss: () {
              controller.preferences.setString(
                'dismissed_update_tag',
                update.tagName,
              );
            },
          );
        }
      } catch (e) {
        debugPrint('Auto update check error: $e');
      }
    });
  }

  void _openSharedItems(List<SharedMediaFile> items) {
    if (!mounted || items.isEmpty) return;
    final media = [
      for (final item in items)
        if (item.type == SharedMediaType.video ||
            item.type == SharedMediaType.file)
          item.path,
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (media.isEmpty) {
        final youtube = youtubeLinkIn(items.first.path);
        if (youtube != null && _webViewSupported) {
          _push(context, UploadScreen(sharedLink: youtube));
        } else {
          _push(context, SharedImportScreen(source: items.first.path));
        }
        return;
      }
      _sheet(
        context,
        title: media.length == 1
            ? 'Add shared file'
            : 'Add ${media.length} shared files',
        (sheetContext) => [
          ListTile(
            leading: const Icon(Icons.public_rounded),
            title: const Text('Upload for everyone'),
            subtitle: const Text('Choose a category and share it'),
            onTap: () {
              Navigator.pop(sheetContext);
              _push(context, UploadScreen(initialPaths: media));
            },
          ),
          if (media.length == 1)
            ListTile(
              leading: const Icon(Icons.lock_outline_rounded),
              title: const Text('Keep privately'),
              subtitle: const Text('Trim it or save the original for yourself'),
              onTap: () {
                Navigator.pop(sheetContext);
                _push(
                  context,
                  OwnedMediaEditorScreen(
                    source: media.first,
                    suggestedName: _fileName(media.first),
                  ),
                );
              },
            ),
        ],
      );
    });
  }

  /// Runs a home screen widget tap. A song to play may still be loading from
  /// the catalogue cache when the app has just started.
  void _runLaunchAction(String action, [int attempt = 0]) {
    if (!mounted) return;
    final music = context.read<MusicController>();
    if (action.startsWith('link:')) {
      _openMusicLink(context, action.substring(5));
      return;
    }
    if (action == 'toggle') {
      music.togglePlay();
      return;
    }
    if (action == 'next') {
      music.next();
      return;
    }
    if (action == 'previous') {
      music.previous();
      return;
    }
    if (action.startsWith('play:')) {
      final song = music.songById(action.substring('play:'.length));
      if (song != null) {
        _openSong(context, song, queue: music.songs);
      } else if (attempt < 10) {
        Future<void>.delayed(
          const Duration(milliseconds: 500),
          () => _runLaunchAction(action, attempt + 1),
        );
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      switch (action) {
        case 'player':
          if (music.current != null) _openPlayer(context);
        case 'upload':
          _push(context, const UploadScreen());
        case 'search':
          _push(context, const SearchScreen());
        case 'browser':
          if (_webViewSupported) {
            _push(context, const NexBrowserScreen(sharedLink: ''));
          }
        case 'downloads':
          setState(() => _currentTabIndex = 2);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateTimer?.cancel();
    _shareSubscription?.cancel();
    _launchSubscription?.cancel();
    super.dispose();
  }

  int _currentTabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final notice = context.select<MusicController, String?>(
      (music) => music.notice,
    );
    if (notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final music = context.read<MusicController>();
        final message = music.notice;
        if (message == null) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
        music.clearNotice();
      });
    }

    final Widget currentView = switch (_currentTabIndex) {
      1 => const _SpotifyStreamView(),
      2 => const _SpotifyLibraryView(),
      3 => const ProfileScreen(showAppBar: false),
      _ => const _SpotifyHomeView(),
    };

    return _SongSelectionScaffold(
      key: ValueKey(_currentTabIndex),
      body: SafeArea(bottom: false, child: currentView),
      floatingActionButton: _currentTabIndex < 3
          ? FloatingActionButton(
              tooltip: 'Play random',
              onPressed: () => _playRandomSong(context),
              child: const Icon(Icons.shuffle_rounded),
            )
          : null,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: _currentTabIndex,
            onDestinationSelected: (index) {
              setState(() => _currentTabIndex = index);
            },
            backgroundColor: Theme.of(context).colorScheme.surface,
            elevation: 8,
            indicatorColor: NexMusic.violet.withValues(alpha: 0.18),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded, color: NexMusic.violet),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.stream_rounded),
                selectedIcon: Icon(
                  Icons.stream_rounded,
                  color: NexMusic.violet,
                ),
                label: 'Stream',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(
                  Icons.library_music_rounded,
                  color: NexMusic.violet,
                ),
                label: 'Library',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(
                  Icons.person_rounded,
                  color: NexMusic.violet,
                ),
                label: 'Profile',
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _playRandomSong(BuildContext context) {
    final scope = switch (_currentTabIndex) {
      1 => MusicRandomScope.stream,
      2 => MusicRandomScope.library,
      _ => MusicRandomScope.home,
    };
    unawaited(context.read<MusicController>().playRandom(scope));
  }
}

String _timeGreeting() {
  final hour = DateTime.now().hour;
  if (hour < 12) return 'Good morning';
  if (hour < 17) return 'Good afternoon';
  return 'Good evening';
}

// ─────────────────────────────────────────────────────────────────────────────
// Spotify-Style Components
// ─────────────────────────────────────────────────────────────────────────────

class _SpotifySongCard extends StatelessWidget {
  const _SpotifySongCard({required this.song, required this.queue, this.width});

  final Song song;
  final List<Song> queue;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final selection = context.watch<SongSelection?>();
    final scheme = Theme.of(context).colorScheme;
    final isCurrent = context.select<MusicController, bool>(
      (m) => m.current?.id == song.id,
    );
    final isPlaying = context.select<MusicController, bool>(
      (m) => m.playing && isCurrent,
    );

    final card = InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openSong(context, song, queue: queue),
      onLongPress: () => _selectSong(context, song, queue),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: song.artworkUrl.isNotEmpty
                      ? Image.network(
                          song.artworkUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _fallback(scheme),
                        )
                      : _fallback(scheme),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: selection?.active == true
                    ? Material(
                        color: scheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(8),
                        child: _songCheckbox(context, song, queue),
                      )
                    : IconButton(
                        tooltip: 'More',
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black.withValues(alpha: 0.45),
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.more_vert_rounded),
                        onPressed: () => _songActions(context, song),
                      ),
              ),
              if (selection?.active != true)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? NexMusic.violet
                          : const Color(0xFF1DB954),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: isCurrent ? NexMusic.violet : scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            song.artist.isNotEmpty
                ? song.artist
                : (song.isProvider ? 'Online stream' : 'nexMusic'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
          ),
        ],
      ),
    );

    if (width != null && width!.isFinite) {
      return SizedBox(width: width, child: card);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isInfinite) {
          return SizedBox(width: 142, child: card);
        }
        return card;
      },
    );
  }

  Widget _fallback(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            NexMusic.violet.withValues(alpha: 0.35),
            scheme.surfaceContainerHighest,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          song.isVideo ? Icons.play_arrow_rounded : Icons.music_note_rounded,
          size: 38,
          color: NexMusic.violet.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

class _SpotifyQuickTile extends StatelessWidget {
  const _SpotifyQuickTile({
    required this.title,
    required this.icon,
    this.gradient,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final Gradient? gradient;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                gradient:
                    gradient ??
                    LinearGradient(
                      colors: [
                        NexMusic.violet,
                        NexMusic.violet.withValues(alpha: 0.6),
                      ],
                    ),
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: NexMusic.violet.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  size: 18,
                  color: NexMusic.violet,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpotifySection extends StatelessWidget {
  const _SpotifySection({
    required this.title,
    this.subtitle,
    required this.songs,
    this.onSeeAll,
  });

  final String title;
  final String? subtitle;
  final List<Song> songs;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onSeeAll != null)
                TextButton(
                  onPressed: onSeeAll,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Show all',
                    style: TextStyle(
                      color: NexMusic.violet,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 195,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: songs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (_, i) =>
                _SpotifySongCard(song: songs[i], queue: songs, width: 142),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spotify Home View
// ─────────────────────────────────────────────────────────────────────────────

class _SpotifyHomeView extends StatefulWidget {
  const _SpotifyHomeView();

  @override
  State<_SpotifyHomeView> createState() => _SpotifyHomeViewState();
}

class _SpotifyHomeViewState extends State<_SpotifyHomeView> {
  String? _selectedCategory;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final music = context.read<MusicController>();
      if (music.providerSongs.isEmpty && !music.providerLoading) {
        music.loadDiscoveryHome();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    final allSongs = music.songs;

    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([music.refreshCatalog(), music.loadDiscoveryHome()]);
      },
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _timeGreeting(),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Search',
                    onPressed: () => _push(context, const SearchScreen()),
                    icon: const Icon(Icons.search_rounded, size: 26),
                  ),
                  IconButton(
                    tooltip: 'Upload song',
                    onPressed: () => _push(context, const UploadScreen()),
                    icon: const Icon(Icons.add_circle_outline_rounded),
                  ),
                ],
              ),
            ),
          ),

          // Horizontal Category Filter Pills
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                children: [
                  _Pill(
                    label: 'All',
                    selected: _selectedCategory == null,
                    onTap: () {
                      context.read<SongSelection?>()?.close();
                      setState(() => _selectedCategory = null);
                    },
                  ),
                  for (final cat in music.categories)
                    _Pill(
                      label: cat.name,
                      selected: _selectedCategory == cat.id,
                      onTap: () {
                        context.read<SongSelection?>()?.close();
                        setState(() => _selectedCategory = cat.id);
                      },
                      onLongPress: () => _categoryActions(context, cat),
                    ),
                  _Pill(
                    icon: Icons.add_rounded,
                    label: 'New',
                    onTap: () async {
                      final cat = await _createCategory(context);
                      if (cat != null && mounted) {
                        setState(() => _selectedCategory = cat.id);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),

          // Upload / conversion progress
          if (music.uploads.isNotEmpty)
            SliverToBoxAdapter(
              child: InkWell(
                onTap: () => _push(context, const UploadScreen()),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        music.uploading
                            ? 'Uploading ${music.uploadsFinished} of ${music.uploads.length}'
                            : 'Uploads finished · tap to review',
                        style: TextStyle(color: _muted(context), fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: music.uploadFraction,
                        minHeight: 3,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // IF A SPECIFIC CATEGORY IS SELECTED: Show filtered tracklist
          if (_selectedCategory != null) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      music.categoryName(_selectedCategory!),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        minimumSize: Size.zero,
                      ),
                      onPressed: () {
                        final songs = music.songsIn(_selectedCategory);
                        if (songs.isNotEmpty) {
                          _openSong(context, songs.first, queue: songs);
                        }
                      },
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('Play'),
                    ),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final list = music.songsIn(_selectedCategory);
                  if (list.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(
                        child: Text(
                          'No songs in this category yet',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    );
                  }
                  return SongTile(song: list[index], queue: list);
                },
                childCount: math.max(
                  1,
                  music.songsIn(_selectedCategory).length,
                ),
              ),
            ),
          ] else ...[
            // QUICK ACCESS HERO GRID (Top 4-6 cards)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return GridView.count(
                      crossAxisCount: 2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 2.7,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _SpotifyQuickTile(
                          title: 'Liked Songs',
                          icon: Icons.favorite_rounded,
                          gradient: const LinearGradient(
                            colors: [Color(0xFF8B5CF6), Color(0xFF4C1D95)],
                          ),
                          onTap: () => _push(
                            context,
                            SongListScreen(
                              title: 'Liked Songs',
                              emptyText: 'No liked songs yet.',
                              select: (m) => m.likedSongs,
                            ),
                          ),
                        ),
                        _SpotifyQuickTile(
                          title: 'Recently Played',
                          icon: Icons.history_rounded,
                          gradient: const LinearGradient(
                            colors: [Color(0xFF3B82F6), Color(0xFF1E3A8A)],
                          ),
                          onTap: () => _push(
                            context,
                            SongListScreen(
                              title: 'Recently Played',
                              emptyText: 'Play a song to start your history.',
                              select: (m) =>
                                  m.librarySongs(MediaCollection.recent),
                            ),
                          ),
                        ),
                        for (final (collection, title, icon) in const [
                          (
                            MediaCollection.mostPlayed,
                            'Most Played',
                            Icons.bar_chart_rounded,
                          ),
                          (
                            MediaCollection.neverPlayed,
                            'Never Played',
                            Icons.explore_outlined,
                          ),
                        ])
                          _SpotifyQuickTile(
                            title: title,
                            icon: icon,
                            onTap: () => _push(
                              context,
                              SongListScreen(
                                title: title,
                                emptyText:
                                    collection == MediaCollection.mostPlayed
                                    ? 'Your most played songs will appear here.'
                                    : 'No unplayed songs available yet.',
                                select: (m) => m.librarySongs(collection),
                              ),
                            ),
                          ),
                        _SpotifyQuickTile(
                          title: 'Downloads',
                          icon: Icons.offline_pin_rounded,
                          gradient: const LinearGradient(
                            colors: [Color(0xFF10B981), Color(0xFF064E3B)],
                          ),
                          onTap: () => _push(
                            context,
                            SongListScreen(
                              title: 'Downloads',
                              emptyText: 'No downloaded songs.',
                              select: (m) => m.downloadedSongs,
                            ),
                          ),
                        ),
                        if (music.categories.isNotEmpty)
                          _SpotifyQuickTile(
                            title: music.categories.first.name,
                            icon: Icons.queue_music_rounded,
                            gradient: const LinearGradient(
                              colors: [Color(0xFFEC4899), Color(0xFF831843)],
                            ),
                            onTap: () {
                              final catSongs = music.songsIn(
                                music.categories.first.id,
                              );
                              if (catSongs.isNotEmpty) {
                                _openSong(
                                  context,
                                  catSongs.first,
                                  queue: catSongs,
                                );
                              } else {
                                setState(
                                  () => _selectedCategory =
                                      music.categories.first.id,
                                );
                              }
                            },
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),

            // SECTIONS: history and likes mixed across JioSaavn, YouTube
            // and the shared catalogue.
            for (final (collection, title) in const [
              (MediaCollection.recent, 'Recently Played'),
              (MediaCollection.watched, 'Recently Watched'),
              (MediaCollection.likedSongs, 'Liked Songs'),
              (MediaCollection.mostPlayed, 'Most Played'),
              (MediaCollection.neverPlayed, 'Never Played'),
            ])
              SliverToBoxAdapter(
                child: _SpotifySection(
                  title: title,
                  songs: music.librarySongs(collection),
                  onSeeAll: () => _push(
                    context,
                    SongListScreen(
                      title: title,
                      emptyText: 'Nothing here yet.',
                      select: (m) => m.librarySongs(collection),
                    ),
                  ),
                ),
              ),

            // SECTION: Trending & New Uploads
            if (allSongs.isNotEmpty)
              SliverToBoxAdapter(
                child: _SpotifySection(
                  title: 'Trending & New Releases',
                  subtitle: 'Fresh community uploads',
                  songs: allSongs.take(15).toList(),
                ),
              ),

            // DYNAMIC CATEGORY CAROUSELS
            for (final cat in music.categories)
              if (music.songsIn(cat.id).isNotEmpty)
                SliverToBoxAdapter(
                  child: _SpotifySection(
                    title: cat.name,
                    subtitle: 'Category playlist',
                    songs: music.songsIn(cat.id),
                    onSeeAll: () => setState(() => _selectedCategory = cat.id),
                  ),
                ),

            // Recommendations from both online music catalogues.
            if (music.providerSongs.isNotEmpty)
              SliverToBoxAdapter(
                child: _SpotifySection(
                  title: 'Music Highlights',
                  subtitle: 'JioSaavn + YouTube Music',
                  songs: music.providerSongs,
                ),
              ),

            if (allSongs.isEmpty && music.providerSongs.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Center(
                    child: music.providerLoading
                        ? const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: NexMusic.violet,
                                ),
                              ),
                              SizedBox(height: 12),
                              Text(
                                'Loading music for you...',
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          )
                        : Text(
                            'No songs available yet.\nExplore the Stream tab or upload songs.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _muted(context),
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                  ),
                ),
              ),

            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spotify Browse / Search View
// ─────────────────────────────────────────────────────────────────────────────

class _SpotifyBrowseCard extends StatelessWidget {
  const _SpotifyBrowseCard({
    required this.title,
    required this.colors,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final List<Color> colors;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 96,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
          ),
          child: Stack(
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  letterSpacing: -0.2,
                ),
              ),
              Positioned(
                right: -8,
                bottom: -8,
                child: Transform.rotate(
                  angle: 0.28,
                  child: Icon(
                    icon,
                    size: 52,
                    color: Colors.white.withValues(alpha: 0.32),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spotify Stream View (JioSaavn & YouTube Streaming with Categories)
// ─────────────────────────────────────────────────────────────────────────────

class _SpotifyStreamView extends StatefulWidget {
  const _SpotifyStreamView();
  @override
  State<_SpotifyStreamView> createState() => _SpotifyStreamViewState();
}

class _SpotifyStreamViewState extends State<_SpotifyStreamView> {
  final _search = TextEditingController();
  Timer? _debounce;
  int _request = 0;
  int _page = 1;
  bool _loading = false, _loadingMore = false, _hasMore = false;
  String _category = 'Trending';
  List<Song> _songs = [], _quickPicks = [], _similar = [];
  String _similarTitle = '';
  List<String> _unavailable = [];
  static const _categories = [
    'Trending',
    'Quick Picks',
    'Energize',
    'Relax',
    'Workout',
    'Focus',
    'Party',
    'Romance',
    'Bollywood',
    'Punjabi',
    'Lo-Fi',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _request++;
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim().isNotEmpty
      ? _search.text.trim()
      : _category == 'Trending' || _category == 'Quick Picks'
      ? ''
      : '$_category songs';

  Future<void> _load({bool more = false, bool refresh = false}) async {
    if (more &&
        (_loading || _loadingMore || !_hasMore || _category == 'Quick Picks')) {
      return;
    }
    _debounce?.cancel();
    final request = ++_request;
    final music = context.read<MusicController>();
    final query = _query;
    final page = more ? _page + 1 : 1;
    if (refresh) music.discovery.clearCache();
    setState(() {
      _loading = !more;
      _loadingMore = more;
      if (!more) {
        _songs = [];
        _page = 1;
        _hasMore = false;
      }
    });
    try {
      final result = await music.discovery.browse(
        query: more && query.isEmpty ? 'Trending Indian music' : query,
        videos: false,
        page: more && query.isEmpty ? page - 1 : page,
        limit: 20,
      );
      if (!mounted || request != _request) return;
      final home = query.isEmpty && !more;
      setState(() {
        final combined = mergeMusicResults([
          [..._songs, ...result.songs],
        ]);
        _hasMore = result.songs.isNotEmpty && combined.length > _songs.length;
        _songs = combined.where(music.personal.accepts).toList();
        _unavailable = result.unavailable;
        _page = page;
        _loading = false;
        _loadingMore = false;
      });
      music.streamRandomTracks = List.of(_songs);
      music.library.rememberSongs(_songs);
      if (home) {
        final picks = await music.fetchQuickPicks(limit: 12);
        final similar = await music.fetchSimilarToLastPlayed(limit: 12);
        if (!mounted || request != _request) return;
        setState(() {
          _quickPicks = picks;
          _similar = similar?.songs ?? [];
          _similarTitle = similar?.title ?? '';
        });
      }
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _request++; // Invalidate in-flight work immediately, including during debounce.
    setState(() {
      _loading = true;
      _loadingMore = false;
    });
    _debounce = Timer(const Duration(milliseconds: 350), () => _load());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showHome = _search.text.trim().isEmpty && _category == 'Trending';
    final tracks = _category == 'Quick Picks' && _search.text.trim().isEmpty
        ? _quickPicks
        : _songs;
    final artists = groupSongsByArtist(
      tracks,
    ).where((a) => !a.unknown).take(12).toList();
    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        if (scrollInfo.metrics.axis == Axis.vertical) {
          final metrics = scrollInfo.metrics;
          // Auto load more when scrolling within 450 pixels of the bottom
          if (metrics.maxScrollExtent > 0 &&
              metrics.pixels >= metrics.maxScrollExtent - 450) {
            if (!_loading &&
                !_loadingMore &&
                _hasMore &&
                _category != 'Quick Picks') {
              _load(more: true);
            }
          }
        }
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: ListView(
          key: const PageStorageKey('stream'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
              child: Row(
                children: [
                  const Icon(
                    Icons.stream_rounded,
                    color: NexMusic.violet,
                    size: 30,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Stream',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'JioSaavn + YouTube Music, together',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh streams',
                    onPressed: () => _load(refresh: true),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: TextField(
                controller: _search,
                onChanged: _onSearch,
                decoration: InputDecoration(
                  hintText: 'Search both music providers',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            _search.clear();
                            _onSearch('');
                          },
                        ),
                ),
              ),
            ),
            if (_search.text.trim().isEmpty)
              SizedBox(
                height: 48,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  scrollDirection: Axis.horizontal,
                  itemCount: _categories.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => ChoiceChip(
                    label: Text(_categories[i]),
                    selected: _category == _categories[i],
                    onSelected: (_) {
                      setState(() => _category = _categories[i]);
                      _load();
                    },
                  ),
                ),
              ),
            if (artists.isNotEmpty && !_loading) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  'Browse by artist',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(
                height: 48,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: artists.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => ActionChip(
                    avatar: const Icon(Icons.person_outline, size: 18),
                    label: Text(artists[i].name),
                    onPressed: () => _push(
                      context,
                      ArtistAlbumScreen(
                        song: artists[i].tracks.first.copyWith(
                          artist: artists[i].name,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (_unavailable.isNotEmpty && !_loading)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  '${_unavailable.join(' and ')} unavailable. Pull down to retry.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (showHome && _quickPicks.isNotEmpty) ...[
                _heading('Quick Picks', 'Inspired by your listening'),
                SizedBox(
                  height: 218,
                  child: GridView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisExtent: 290,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 4,
                        ),
                    itemCount: _quickPicks.length,
                    itemBuilder: (_, i) => _QuickPickTile(
                      song: _quickPicks[i],
                      queue: _quickPicks,
                    ),
                  ),
                ),
              ],
              if (showHome && _similar.isNotEmpty)
                _SpotifySection(
                  title: 'Similar to $_similarTitle',
                  subtitle: 'Recommendations across both providers',
                  songs: _similar,
                ),
              _heading(
                _search.text.trim().isNotEmpty
                    ? 'Search results'
                    : _category == 'Trending'
                    ? 'Made for your next listen'
                    : _category,
                'A mix from JioSaavn and YouTube Music',
              ),
              if (tracks.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      const Icon(Icons.search_off_rounded, size: 40),
                      const SizedBox(height: 12),
                      const Text(
                        'No tracks available. Try another search or refresh.',
                      ),
                      TextButton(
                        onPressed: () => _load(refresh: true),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              else
                for (final song in tracks) SongTile(song: song, queue: tracks),
              if (_loadingMore)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                )
              else if (_hasMore && _category != 'Quick Picks')
                Center(
                  child: TextButton.icon(
                    onPressed: () => _load(more: true),
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Load more'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _heading(String title, String subtitle) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(subtitle, style: TextStyle(fontSize: 12, color: _muted(context))),
      ],
    ),
  );
}

class _QuickPickTile extends StatelessWidget {
  const _QuickPickTile({required this.song, required this.queue});

  final Song song;
  final List<Song> queue;

  @override
  Widget build(BuildContext context) {
    final selection = context.watch<SongSelection?>();
    final scheme = Theme.of(context).colorScheme;
    final isCurrent = context.select<MusicController, bool>(
      (m) => m.current?.id == song.id,
    );
    final isPlaying = context.select<MusicController, bool>(
      (m) => m.playing && isCurrent,
    );

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _openSong(context, song, queue: queue),
      onLongPress: () => _selectSong(context, song, queue),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 44,
                height: 44,
                color: scheme.surfaceContainerHighest,
                child: song.artworkUrl.isNotEmpty
                    ? Image.network(
                        song.artworkUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          song.isVideo
                              ? Icons.play_arrow_rounded
                              : Icons.music_note_rounded,
                          color: NexMusic.violet,
                          size: 20,
                        ),
                      )
                    : Icon(
                        song.isVideo
                            ? Icons.play_arrow_rounded
                            : Icons.music_note_rounded,
                        color: NexMusic.violet,
                        size: 20,
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isCurrent ? NexMusic.violet : scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist.isNotEmpty ? song.artist : 'YouTube Music',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (isCurrent && selection?.active != true)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  isPlaying
                      ? Icons.graphic_eq_rounded
                      : Icons.play_arrow_rounded,
                  size: 18,
                  color: NexMusic.violet,
                ),
              ),
            if (selection?.active == true)
              _songCheckbox(context, song, queue)
            else
              IconButton(
                icon: const Icon(Icons.more_vert_rounded, size: 18),
                tooltip: 'More',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => _songActions(context, song),
              ),
          ],
        ),
      ),
    );
  }
}

class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _SongSelectionScaffold(
      appBar: AppBar(title: const Text('Search'), elevation: 0),
      body: const SafeArea(child: _SpotifyBrowseView()),
    );
  }
}

class _SpotifyBrowseView extends StatefulWidget {
  const _SpotifyBrowseView();

  @override
  State<_SpotifyBrowseView> createState() => _SpotifyBrowseViewState();
}

class _SpotifyBrowseViewState extends State<_SpotifyBrowseView> {
  final _searchController = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    final query = _searchController.text.trim().toLowerCase();

    final searchResults = query.isEmpty
        ? const <Song>[]
        : music.allMusic.where((s) {
            return s.title.toLowerCase().contains(query) ||
                s.artist.toLowerCase().contains(query) ||
                music.categoryName(s.categoryId).toLowerCase().contains(query);
          }).toList();
    final selectableResults = [...searchResults, ...music.providerSongs];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onChanged: (val) {
              context.read<SongSelection?>()?.close();
              setState(() {});
              _debounce?.cancel();
              if (val.trim().isNotEmpty && music.musicProviders.isNotEmpty) {
                _debounce = Timer(
                  const Duration(milliseconds: 500),
                  () => music.searchAllMusic(val),
                );
              }
            },
            decoration: InputDecoration(
              hintText: 'What do you want to listen to?',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        context.read<SongSelection?>()?.close();
                        _searchController.clear();
                        _debounce?.cancel();
                        music.searchAllMusic('');
                        setState(() {});
                      },
                    )
                  : null,
            ),
          ),
        ),
        Expanded(
          child: query.isNotEmpty
              ? (searchResults.isEmpty && music.providerSongs.isEmpty
                    ? Center(
                        child: Text(
                          'No results for "$query"',
                          style: TextStyle(color: _muted(context)),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 80),
                        children: [
                          if (searchResults.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                              child: Text(
                                'Library & Community',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            for (final song in searchResults)
                              SongTile(
                                song: song,
                                queue: searchResults,
                                selectionSongs: selectableResults,
                              ),
                          ],
                          if (music.providerSongs.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                              child: Text(
                                'Online Streams',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            for (final song in music.providerSongs)
                              SongTile(
                                song: song,
                                queue: music.providerSongs,
                                selectionSongs: selectableResults,
                              ),
                          ],
                        ],
                      ))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 80),
                  children: [
                    const Text(
                      'Browse Categories',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 14),
                    GridView.count(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1.6,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _SpotifyBrowseCard(
                          title: 'Pop & Hits',
                          colors: const [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
                          icon: Icons.trending_up_rounded,
                          onTap: () {
                            _searchController.text = 'Pop';
                            setState(() {});
                          },
                        ),
                        _SpotifyBrowseCard(
                          title: 'Lo-Fi & Chill',
                          colors: const [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
                          icon: Icons.bedtime_rounded,
                          onTap: () {
                            _searchController.text = 'Chill';
                            setState(() {});
                          },
                        ),
                        _SpotifyBrowseCard(
                          title: 'Hip-Hop',
                          colors: const [Color(0xFF10B981), Color(0xFF047857)],
                          icon: Icons.graphic_eq_rounded,
                          onTap: () {
                            _searchController.text = 'Hip Hop';
                            setState(() {});
                          },
                        ),
                        _SpotifyBrowseCard(
                          title: 'Party Beats',
                          colors: const [Color(0xFFF59E0B), Color(0xFFD97706)],
                          icon: Icons.celebration_rounded,
                          onTap: () {
                            _searchController.text = 'Party';
                            setState(() {});
                          },
                        ),
                        _SpotifyBrowseCard(
                          title: 'Rock & Metal',
                          colors: const [Color(0xFFEF4444), Color(0xFFB91C1C)],
                          icon: Icons.bolt_rounded,
                          onTap: () {
                            _searchController.text = 'Rock';
                            setState(() {});
                          },
                        ),
                        _SpotifyBrowseCard(
                          title: 'Acoustic',
                          colors: const [Color(0xFFEC4899), Color(0xFFBE185D)],
                          icon: Icons.favorite_rounded,
                          onTap: () {
                            _searchController.text = 'Acoustic';
                            setState(() {});
                          },
                        ),
                        _SpotifyBrowseCard(
                          title: 'Bollywood',
                          colors: const [Color(0xFFA855F7), Color(0xFF7E22CE)],
                          icon: Icons.radio_rounded,
                          onTap: () {
                            _searchController.text = 'Bollywood';
                            setState(() {});
                          },
                        ),
                        _SpotifyBrowseCard(
                          title: 'Focus & Study',
                          colors: const [Color(0xFF06B6D4), Color(0xFF0E7490)],
                          icon: Icons.auto_stories_rounded,
                          onTap: () {
                            _searchController.text = 'Focus';
                            setState(() {});
                          },
                        ),
                        for (final cat in music.categories)
                          _SpotifyBrowseCard(
                            title: cat.name,
                            colors: const [
                              Color(0xFF6366F1),
                              Color(0xFF4338CA),
                            ],
                            icon: Icons.music_note_rounded,
                            onTap: () => _push(
                              context,
                              SongListScreen(
                                title: cat.name,
                                emptyText: 'No songs in this category.',
                                select: (m) => m.songsIn(cat.id),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spotify Library View
// ─────────────────────────────────────────────────────────────────────────────

class _SpotifyLibraryView extends StatelessWidget {
  const _SpotifyLibraryView();

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.only(bottom: 80),
      children: [
        const PersonalLibraryPanel(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          child: Row(
            children: [
              _Avatar(initials: music.profileInitials, size: 34),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Your Library',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Add category',
                icon: const Icon(Icons.add_rounded),
                onPressed: () => _createCategory(context),
              ),
            ],
          ),
        ),

        // LIKED SONGS HERO ITEM
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 4,
          ),
          leading: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF8B5CF6), Color(0xFF4C1D95)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.favorite_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          title: const Text(
            'Liked Songs',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          subtitle: Text(
            'Playlist · ${music.likedSongs.length} songs',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          onTap: () => _push(
            context,
            SongListScreen(
              title: 'Liked Songs',
              emptyText: 'Songs you like show up here.',
              select: (m) => m.likedSongs,
            ),
          ),
        ),

        // DOWNLOADS ITEM
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 4,
          ),
          leading: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF10B981), Color(0xFF064E3B)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.download_done_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          title: const Text(
            'Downloaded Music',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          subtitle: Text(
            'Playlist · ${music.downloadedSongs.length} songs offline',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          onTap: () => _push(
            context,
            SongListScreen(
              title: 'Downloads',
              emptyText: 'No downloaded songs.',
              select: (m) => m.downloadedSongs,
            ),
          ),
        ),

        // LOCAL DEVICE IMPORTS
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 4,
          ),
          leading: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF3B82F6), Color(0xFF1E3A8A)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.folder_copy_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          title: const Text(
            'Device Imports',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          subtitle: Text(
            'Local files · ${music.savedMedia.length} tracks',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          onTap: () => _push(context, const SharedImportScreen(source: '')),
        ),

        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            'Playlists & Categories',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
        ),

        for (final cat in music.categories)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 4,
            ),
            leading: Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.queue_music_rounded,
                color: NexMusic.violet,
                size: 26,
              ),
            ),
            title: Text(
              cat.name,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            subtitle: Text(
              'Playlist · ${music.songsIn(cat.id).length} songs',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.more_vert_rounded),
              onPressed: () => _categoryActions(context, cat),
            ),
            onTap: () => _push(
              context,
              SongListScreen(
                title: cat.name,
                emptyText: 'No songs in this category.',
                select: (m) => m.songsIn(cat.id),
              ),
            ),
          ),
      ],
    );
  }
}

class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.queue,
    this.trailing,
    this.selectionSongs,
  });
  final Song song;
  final List<Song> queue;
  final Widget? trailing;
  final List<Song>? selectionSongs;

  @override
  Widget build(BuildContext context) {
    final selection = context.watch<SongSelection?>();
    final tile = context
        .select<
          MusicController,
          ({
            bool active,
            bool playing,
            String source,
            bool offline,
            double? download,
            String? downloadState,
          })
        >(
          (music) => (
            active: music.current?.id == song.id,
            playing: music.playing,
            source: music.songSource(song),
            offline: music.isSongDownloaded(song),
            download: music.songDownloads[song.id],
            downloadState: switch (music.downloads.jobs[song.id]?.status) {
              MusicDownloadStatus.paused =>
                music.downloads.paused
                    ? 'Download paused'
                    : music.downloads.waitingForWifi
                    ? 'Waiting for Wi-Fi'
                    : 'Waiting for connection',
              MusicDownloadStatus.failed => 'Download failed',
              _ => null,
            },
          ),
        );
    final download = tile.download;
    final details = [
      tile.source,
      if (song.isVideo) 'Video',
      if (tile.downloadState != null)
        tile.downloadState!
      else if (download != null)
        'Downloading ${(download * 100).round()}%'
      else if (tile.offline)
        'Offline',
    ];
    return ListTile(
      selected: selection?.contains(song) ?? false,
      selectedTileColor: NexMusic.violet.withValues(alpha: 0.12),
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      leading: _Thumb(
        active: tile.active,
        imageUrl: song.artworkUrl,
        icon: tile.active && tile.playing
            ? Icons.graphic_eq_rounded
            : song.isVideo
            ? Icons.play_arrow_rounded
            : Icons.music_note_rounded,
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w500,
          color: tile.active ? NexMusic.violet : null,
        ),
      ),
      subtitle: Text(
        details.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: _muted(context), fontSize: 12),
      ),
      trailing: selection?.active == true
          ? _songCheckbox(context, song, selectionSongs ?? queue)
          : trailing ??
                IconButton(
                  tooltip: 'More',
                  onPressed: () => _songActions(context, song),
                  icon: Icon(Icons.more_vert_rounded, color: _muted(context)),
                ),
      onTap: () => _openSong(context, song, queue: queue),
      onLongPress: () => _selectSong(context, song, selectionSongs ?? queue),
    );
  }
}

Future<void> _songActions(BuildContext context, Song song) {
  final music = context.read<MusicController>();
  final liked = music.isLiked(song);
  final downloaded = music.isSongDownloaded(song);
  final downloading = music.songDownloads.containsKey(song.id);
  final job = music.downloads.jobs[song.id];
  final waiting = job?.status == MusicDownloadStatus.paused;
  final failed = job?.status == MusicDownloadStatus.failed;
  return _sheet(
    context,
    title: song.title,
    (sheetContext) => [
      ..._listeningSongActions(context, sheetContext, song),
      ListTile(
        leading: const Icon(Icons.radio_rounded, color: NexMusic.violet),
        title: const Text('Start Radio'),
        subtitle: const Text('Play similar recommended tracks like this'),
        onTap: () {
          Navigator.pop(sheetContext);
          music.startRadio(song);
        },
      ),
      if (!song.isProvider)
        ListTile(
          leading: Icon(
            liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          ),
          title: Text(liked ? 'Remove from liked' : 'Like'),
          onTap: () {
            Navigator.pop(sheetContext);
            music.toggleLike(song);
          },
        ),
      if (!kIsWeb)
        ListTile(
          leading: Icon(
            downloaded ? Icons.offline_pin_rounded : Icons.download_rounded,
          ),
          title: Text(
            downloading
                ? 'View download progress'
                : waiting
                ? 'Download waiting'
                : failed
                ? 'Retry download'
                : downloaded
                ? 'Remove download'
                : 'Download',
          ),
          subtitle: waiting || failed
              ? Text(job?.error ?? 'View Downloads to continue')
              : downloaded || downloading
              ? null
              : const Text('Play it without internet'),
          onTap: () async {
            Navigator.pop(sheetContext);
            if (downloading || waiting) {
              _push(context, const MusicDownloadsScreen());
            } else if (downloaded) {
              music.removeSongDownload(song);
            } else {
              await music.downloadSong(song);
              if (context.mounted) _push(context, const MusicDownloadsScreen());
            }
          },
        ),
      if (!song.isProvider) ...[
        // Anyone signed in can edit or delete any upload.
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Edit or move'),
          subtitle: const Text('Change the title or category'),
          onTap: () {
            Navigator.pop(sheetContext);
            _push(context, SongEditorScreen(song: song));
          },
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline_rounded),
          title: const Text('Delete'),
          onTap: () async {
            Navigator.pop(sheetContext);
            final confirmed = await _confirm(
              context,
              title: 'Delete "${song.title}"?',
              body: 'It will be removed for everyone.',
              action: 'Delete',
            );
            if (confirmed) await music.deleteSong(song);
          },
        ),
      ],
    ],
  );
}

Future<void> _categoryActions(
  BuildContext context,
  MusicCategory category,
) async {
  final music = context.read<MusicController>();
  if (!music.ownsCategory(category)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Only the person who created a category can change it.'),
      ),
    );
    return;
  }
  await _sheet(
    context,
    title: category.name,
    (sheetContext) => [
      ListTile(
        leading: const Icon(Icons.edit_outlined),
        title: const Text('Rename'),
        onTap: () {
          Navigator.pop(sheetContext);
          _renameCategory(context, category);
        },
      ),
      ListTile(
        leading: const Icon(Icons.delete_outline_rounded),
        title: const Text('Delete'),
        onTap: () {
          Navigator.pop(sheetContext);
          _deleteCategory(context, category);
        },
      ),
    ],
  );
}

Future<void> _renameCategory(
  BuildContext context,
  MusicCategory category,
) async {
  final music = context.read<MusicController>();
  final name = await _nameDialog(
    context,
    title: 'Rename category',
    action: 'Save',
    initialValue: category.name,
  );
  if (name != null) await music.renameCategory(category, name);
}

Future<void> _deleteCategory(
  BuildContext context,
  MusicCategory category,
) async {
  final music = context.read<MusicController>();
  final count = music.songsIn(category.id).length;
  final songs = '$count song${count == 1 ? '' : 's'}';
  final confirmed = await _confirm(
    context,
    title: count == 0
        ? 'Delete "${category.name}"?'
        : 'Delete "${category.name}" and its $songs?',
    body: count == 0
        ? 'The category will be removed for everyone.'
        : 'The category and all $songs in it will be removed for everyone. This cannot be undone.',
    action: count == 0 ? 'Delete' : 'Delete all',
  );
  if (!confirmed || !context.mounted) return;
  if (count > 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleting "${category.name}" and its $songs…')),
    );
  }
  await music.deleteCategory(category, withSongs: count > 0);
}

/// Every category with its song count. Categories this user created can be
/// renamed or deleted; the rest are read-only.
class CategoryManagerScreen extends StatelessWidget {
  const CategoryManagerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final categories = context.watch<MusicController>().categories;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Categories'),
        actions: [
          IconButton(
            tooltip: 'New category',
            onPressed: () => _createCategory(context),
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: categories.isEmpty
          ? const _EmptyState(
              icon: Icons.label_outline_rounded,
              title: 'No categories yet',
              subtitle: 'Tap + to create the first one.',
            )
          : ListView.builder(
              padding: const EdgeInsets.only(top: 4, bottom: 24),
              itemCount: categories.length,
              itemBuilder: (_, i) => _CategoryRow(category: categories[i]),
            ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.category});
  final MusicCategory category;

  @override
  Widget build(BuildContext context) {
    final music = context.read<MusicController>();
    final count = music.songsIn(category.id).length;
    final owner = music.ownsCategory(category);
    final songs = '$count song${count == 1 ? '' : 's'}';
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      title: Text(
        category.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        owner ? songs : '$songs · created by someone else',
        style: TextStyle(color: _muted(context), fontSize: 12),
      ),
      trailing: owner
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Rename',
                  onPressed: () => _renameCategory(context, category),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: () => _deleteCategory(context, category),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            )
          : Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Icon(
                Icons.lock_outline_rounded,
                size: 18,
                color: _muted(context),
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Upload & edit
// ─────────────────────────────────────────────────────────────────────────────

class UploadScreen extends StatefulWidget {
  const UploadScreen({
    super.key,
    this.initialPaths = const [],
    this.sharedLink,
  });
  final List<String> initialPaths;

  /// A YouTube link shared into nexMusic. The screen opens at once while a
  /// browser out of sight turns the link into audio, so the title and category
  /// can be filled in, and Upload pressed, before the audio arrives.
  final String? sharedLink;

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  late final MusicController _music;
  final _title = TextEditingController();
  final _artist = TextEditingController();
  final List<UploadItem> _picked = [];
  final List<String> _rejected = [];
  String? _categoryId;
  SharedAudioJob? _job;

  @override
  void initState() {
    super.initState();
    _music = context.read<MusicController>();
    for (final filePath in widget.initialPaths) {
      final file = File(filePath);
      _add(
        filePath,
        _fileName(filePath),
        !kIsWeb && file.existsSync() ? file.lengthSync() : 0,
      );
    }
    if (_picked.length == 1) _title.text = _picked.first.title;
    final link = widget.sharedLink;
    if (link != null) _startJob(link);
  }

  @override
  void dispose() {
    final job = _job;
    if (job != null) {
      job.removeListener(_onJob);
      // Without an upload waiting on it, nothing needs the audio any more.
      if (!job.uploadRequested) job.cancel();
    }
    // Picked files that were never uploaded leave copies in the cache. Clear
    // them only when no upload batch still needs its files.
    if (_picked.isNotEmpty && _music.uploads.isEmpty) {
      for (final item in _picked) {
        _music.discardPicked(item);
      }
      try {
        unawaited(FilePicker.clearTemporaryFiles().catchError((Object _) {}));
      } catch (_) {}
    }
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  void _startJob(String link) {
    _job?.removeListener(_onJob);
    _job = SharedAudioJob.start(link, _music)..addListener(_onJob);
  }

  /// Follows the hidden browser. Audio that arrives before Upload is pressed
  /// joins the selection like any picked file.
  void _onJob() {
    final job = _job;
    if (!mounted || job == null) return;
    setState(() {
      final filePath = job.filePath;
      if (filePath == null || job.uploadRequested) return;
      if (_picked.any((item) => item.path == filePath)) return;
      final file = File(filePath);
      _add(
        filePath,
        _fileName(filePath),
        file.existsSync() ? file.lengthSync() : 0,
      );
      if (_picked.length == 1 && _title.text.trim().isEmpty) {
        _title.text = _picked.first.title;
      }
    });
  }

  void _retryJob() {
    final link = widget.sharedLink;
    if (link != null) setState(() => _startJob(link));
  }

  /// Hands the converter to the listener when the hidden browser could not
  /// finish it.
  void _openInBrowser() {
    final link = widget.sharedLink;
    if (link == null) return;
    _push(
      context,
      NexBrowserScreen(sharedLink: 'youtube to mp3', pasteLink: link),
    );
  }

  /// Keeps an upload that is waiting for its audio in step with the title and
  /// category on screen.
  void _syncRequest() {
    final job = _job;
    final categoryId = _categoryId;
    if (job == null || !job.uploadRequested || categoryId == null) return;
    job.requestUpload(title: _title.text.trim(), categoryId: categoryId);
  }

  /// Adds a picked file, or notes why it cannot be uploaded.
  void _add(String filePath, String name, int sizeBytes) {
    if (_picked.any((item) => item.path == filePath)) return;
    final reason = uploadKindFor(name) == null
        ? 'file type not supported'
        : sizeBytes >= maxUploadBytes
        ? 'larger than 100 MB'
        // A size of -1 means the phone did not report one.
        : sizeBytes == 0
        ? 'empty or unreadable'
        : null;
    if (reason != null) {
      _rejected.add('$name · $reason');
      return;
    }
    final title = name.replaceAll(RegExp(r'\.[^.]+$'), '');
    _picked.add(
      UploadItem(
        path: filePath,
        name: name,
        sizeBytes: sizeBytes,
        title: title.length > 160 ? title.substring(0, 160) : title,
      ),
    );
  }

  static Future<int> _sizeOf(
    int? Function() known,
    Future<int> Function() read,
  ) async {
    try {
      return known() ?? await read();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _pickFiles() async {
    // Android: the native chooser returns content URIs and copies nothing, so
    // choosing hundreds of songs does not fill the phone (file_picker copied
    // every file up front and Android deleted some before they uploaded).
    final chosen = await _music.phone?.pickMedia();
    if (chosen != null) {
      if (!mounted || chosen.isEmpty) return;
      setState(() {
        _rejected.clear();
        for (final file in chosen) {
          _add(file.uri, file.name, file.size);
        }
        if (_picked.length == 1) _title.text = _picked.first.title;
      });
      return;
    }
    // Elsewhere, filter by media type, not extension: file_picker turns
    // extensions into exact MIME types (m4a → audio/mp4), and phones that
    // label a file differently (audio/x-m4a) grey it out. _add rejects the
    // rest.
    final files = await FilePicker.pickFiles(type: FileType.media);
    if (!mounted || files.isEmpty) return;
    final sizes = await Future.wait([
      for (final file in files) _sizeOf(file.lengthSync, file.length),
    ]);
    if (!mounted) return;
    setState(() {
      _rejected.clear();
      for (var i = 0; i < files.length; i++) {
        final filePath = files[i].path;
        if (filePath == null) {
          _rejected.add('${files[i].name} · could not be read');
        } else {
          _add(filePath, files[i].name, sizes[i]);
        }
      }
      if (_picked.length == 1) _title.text = _picked.first.title;
    });
  }

  void _remove(UploadItem item) => setState(() {
    _music.discardPicked(item);
    _picked.remove(item);
    if (_picked.length == 1) _title.text = _picked.first.title;
  });

  void _clear() => setState(() {
    for (final item in _picked) {
      _music.discardPicked(item);
    }
    _picked.clear();
    _rejected.clear();
    _title.clear();
  });

  Future<void> _trim(UploadItem item) async {
    if (_picked.length == 1) item.title = _title.text;
    final trimmed = await _trimUpload(context, item);
    if (trimmed && mounted) setState(() {});
  }

  void _undoTrim(UploadItem item) {
    final trimmedCopy = item.undoTrim();
    if (trimmedCopy != null) discardTemporaryCopy(trimmedCopy);
    setState(() {});
  }

  void _upload() {
    final categoryId = _categoryId;
    if (categoryId == null) return;
    final job = _job;
    if (_picked.isEmpty && job != null && job.waiting) {
      // The audio is still on its way. The job uploads it once it arrives, so
      // nobody has to wait here for the download.
      job.requestUpload(title: _title.text.trim(), categoryId: categoryId);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('The song uploads as soon as its audio is ready.'),
          ),
        );
      unawaited(Navigator.maybePop(context));
      return;
    }
    if (_picked.isEmpty) return;
    if (_picked.length == 1) _picked.first.title = _title.text;
    if (_artist.text.trim().isNotEmpty) {
      for (final item in _picked) {
        item.artist = _artist.text.trim();
      }
    }
    final items = List.of(_picked);
    unawaited(_music.startUploads(items, categoryId: categoryId));
    // The batch is queued synchronously; keep the selection if it was refused.
    if (_music.uploads.isNotEmpty &&
        identical(_music.uploads.first, items.first)) {
      setState(() {
        _picked.clear();
        _rejected.clear();
      });
    }
  }

  Future<void> _cancelUploads(MusicController music) async {
    final confirmed = await _confirm(
      context,
      title: 'Stop uploading?',
      body: 'Songs already uploaded stay in nexMusic. The rest are not sent.',
      action: 'Stop',
    );
    if (confirmed) music.cancelUploads();
  }

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    return music.uploads.isEmpty ? _pickerView(music) : _progressView(music);
  }

  Widget _pickerView(MusicController music) {
    final muted = _muted(context);
    final error = Theme.of(context).colorScheme.error;
    final count = _picked.length;
    final totalBytes = _picked.fold<int>(
      0,
      (total, item) => total + item.sizeBytes,
    );
    final job = _job;
    // The shared link is still being turned into audio.
    final fetching = count == 0 && job != null && job.waiting;
    final requested = job?.uploadRequested ?? false;
    final ready =
        !requested &&
        music.categories.any((category) => category.id == _categoryId) &&
        (fetching ||
            (count > 0 && (count > 1 || _title.text.trim().isNotEmpty)));

    return Scaffold(
      appBar: AppBar(title: const Text('Upload')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          if (count == 0 && job != null)
            _FetchBox(job: job, onRetry: _retryJob, onBrowser: _openInBrowser)
          else
            _FileBox(
              title: count == 0
                  ? 'Choose songs or videos'
                  : '$count file${count == 1 ? '' : 's'} · ${_fileSize(totalBytes)}',
              detail: count == 0
                  ? 'Pick one or many · up to 100 MB each'
                  : 'Tap to add more',
              onTap: _pickFiles,
              onClear: count == 0 ? null : _clear,
            ),
          for (final reason in _rejected)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(reason, style: TextStyle(color: error, fontSize: 12)),
            ),
          if (count == 1 || fetching) ...[
            const SizedBox(height: 20),
            TextField(
              controller: _title,
              maxLength: 160,
              onChanged: (_) {
                setState(() {});
                _syncRequest();
              },
              decoration: const InputDecoration(
                labelText: 'Title',
                counterText: '',
              ),
            ),
            if (count == 1 &&
                _canTrim &&
                uploadKindFor(_picked.first.name) == 'audio') ...[
              const SizedBox(height: 12),
              _TrimRow(
                item: _picked.first,
                onTrim: () => _trim(_picked.first),
                onUndo: () => _undoTrim(_picked.first),
              ),
            ],
          ] else if (count > 1) ...[
            const SizedBox(height: 8),
            for (final item in _picked.take(50))
              _PickedRow(
                item: item,
                onRemove: () => _remove(item),
                onTrim: _canTrim && uploadKindFor(item.name) == 'audio'
                    ? () => _trim(item)
                    : null,
              ),
            if (count > 50)
              Text(
                '+ ${count - 50} more',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            const SizedBox(height: 4),
            Text(
              'Titles come from the file names. You can edit them after uploading.',
              style: TextStyle(color: muted, fontSize: 12),
            ),
          ],
          if (count > 0) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _artist,
              maxLength: 160,
              decoration: InputDecoration(
                labelText: count > 1
                    ? 'Artist for selected songs (optional)'
                    : 'Artist (optional)',
                helperText: 'Leave blank to read the artist from each file.',
                counterText: '',
              ),
            ),
          ],
          const SizedBox(height: 20),
          _ChoicePicker(
            label: 'Category',
            options: [
              for (final category in music.categories)
                (id: category.id, name: category.name),
            ],
            selectedId: _categoryId,
            onChanged: (id) {
              setState(() => _categoryId = id);
              _syncRequest();
            },
            onCreate: () async => (await _createCategory(context))?.id,
            createLabel: 'New category',
            onManage: () => _push(context, const CategoryManagerScreen()),
          ),
          const SizedBox(height: 12),
          if (!music.uploadsConfigured)
            Text(
              'Uploads are not set up yet (Cloudinary).',
              style: TextStyle(color: error, fontSize: 12),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: ready ? _upload : null,
            child: Text(
              requested
                  ? 'Uploads when the audio is ready'
                  : fetching
                  ? 'Upload'
                  : count > 1
                  ? 'Upload $count files'
                  : 'Upload',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Everyone signed in to nexMusic can play your uploads.',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _progressView(MusicController music) {
    final uploads = music.uploads;
    final uploading = music.uploading;
    final failed = music.uploadsFailed;
    int count(UploadStatus status) =>
        uploads.where((item) => item.status == status).length;
    final summary = [
      '${count(UploadStatus.done)} uploaded',
      if (count(UploadStatus.skipped) > 0)
        '${count(UploadStatus.skipped)} already in nexMusic',
      if (failed > 0) '$failed failed',
      if (count(UploadStatus.cancelled) > 0)
        '${count(UploadStatus.cancelled)} cancelled',
    ].join(' · ');
    final paused = music.uploadsPaused;
    final waiting = music.uploadsWaiting;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          uploading
              ? (paused
                    ? 'Uploads paused'
                    : waiting
                    ? 'Waiting for connection'
                    : 'Uploading')
              : 'Upload finished',
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${music.uploadsFinished} of ${uploads.length} processed',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: music.uploadFraction,
                  minHeight: 4,
                ),
                const SizedBox(height: 8),
                Text(
                  uploading
                      ? waiting
                            ? music.uploadWaitMessage!
                            : paused
                            ? 'Paused. A song that was halfway starts again when you resume.'
                            : 'Keep nexMusic open until the uploads finish.'
                      : summary,
                  style: TextStyle(color: _muted(context), fontSize: 12),
                ),
                if (uploading) ...[
                  const SizedBox(height: 4),
                  Text(
                    summary,
                    style: TextStyle(color: _muted(context), fontSize: 12),
                  ),
                ],
                if (waiting || (uploading && failed > 0))
                  TextButton.icon(
                    onPressed: failed > 0
                        ? music.retryFailedUploads
                        : music.resumeUploads,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(
                      failed > 0 ? 'Retry failed ($failed)' : 'Retry now',
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: uploads.length,
              itemBuilder: (_, i) => _UploadRow(item: uploads[i]),
            ),
          ),
        ],
      ),
      // In the bottom bar, snackbars float above the buttons instead of
      // covering them.
      bottomNavigationBar: uploading
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _cancelUploads(music),
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: paused
                            ? () => unawaited(music.resumeUploads())
                            : music.pauseUploads,
                        icon: Icon(
                          paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                        ),
                        label: Text(paused ? 'Resume' : 'Pause'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    if (failed > 0) ...[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: music.retryFailedUploads,
                          child: Text('Retry failed ($failed)'),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          music.clearUploads();
                          Navigator.pop(context);
                        },
                        child: const Text('Done'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _FileBox extends StatelessWidget {
  const _FileBox({
    required this.title,
    required this.detail,
    required this.onTap,
    this.onClear,
  });
  final String title, detail;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            children: [
              Icon(
                onClear == null
                    ? Icons.upload_file_rounded
                    : Icons.library_music_outlined,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 2,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (onClear != null)
                IconButton(
                  tooltip: 'Clear selection',
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded),
                )
              else
                const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// How far a shared link has got while a hidden browser turns it into audio,
/// with a way forward if it could not.
class _FetchBox extends StatelessWidget {
  const _FetchBox({
    required this.job,
    required this.onRetry,
    required this.onBrowser,
  });
  final SharedAudioJob job;
  final VoidCallback onRetry, onBrowser;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = job.error;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (error == null)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(Icons.error_outline_rounded, color: scheme.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        error == null
                            ? 'Getting the audio'
                            : 'Could not get the audio',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        error ?? job.status,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onBrowser,
                      child: const Text('Open browser'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: onRetry,
                      child: const Text('Try again'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PickedRow extends StatelessWidget {
  const _PickedRow({required this.item, required this.onRemove, this.onTrim});
  final UploadItem item;
  final VoidCallback onRemove;
  final VoidCallback? onTrim;

  @override
  Widget build(BuildContext context) {
    final start = item.trimStart, end = item.trimEnd;
    return Row(
      children: [
        Expanded(
          child: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        Text(
          start != null && end != null
              ? '${_time(start)}–${_time(end)}'
              : _fileSize(item.sizeBytes),
          style: TextStyle(
            color: item.trimmed ? NexMusic.violet : _muted(context),
            fontSize: 12,
          ),
        ),
        if (onTrim != null)
          IconButton(
            tooltip: item.trimmed ? 'Trim again' : 'Trim',
            visualDensity: VisualDensity.compact,
            onPressed: onTrim,
            icon: Icon(
              Icons.content_cut_rounded,
              size: 18,
              color: item.trimmed ? NexMusic.violet : null,
            ),
          ),
        IconButton(
          tooltip: 'Remove',
          visualDensity: VisualDensity.compact,
          onPressed: onRemove,
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
      ],
    );
  }
}

class _TrimRow extends StatelessWidget {
  const _TrimRow({
    required this.item,
    required this.onTrim,
    required this.onUndo,
  });
  final UploadItem item;
  final VoidCallback onTrim, onUndo;

  @override
  Widget build(BuildContext context) {
    final start = item.trimStart, end = item.trimEnd;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onTrim,
            icon: const Icon(Icons.content_cut_rounded, size: 18),
            label: Text(
              start == null || end == null
                  ? 'Trim audio'
                  : 'Trimmed ${_time(start)} – ${_time(end)}',
            ),
          ),
        ),
        if (item.trimmed) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: onUndo, child: const Text('Undo')),
        ],
      ],
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.item});
  final UploadItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Widget icon, String status) = switch (item.status) {
      UploadStatus.queued => (
        Icon(Icons.schedule_rounded, color: scheme.onSurfaceVariant),
        item.error ?? 'Waiting',
      ),
      UploadStatus.uploading => (
        SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            value: item.progress,
          ),
        ),
        '${(item.progress * 100).round()}%',
      ),
      UploadStatus.done => (
        const Icon(Icons.check_circle_rounded, color: NexMusic.violet),
        'Uploaded',
      ),
      UploadStatus.skipped => (
        Icon(
          Icons.remove_circle_outline_rounded,
          color: scheme.onSurfaceVariant,
        ),
        'Already in nexMusic',
      ),
      UploadStatus.failed => (
        Icon(Icons.error_outline_rounded, color: scheme.error),
        'Failed · ${item.error ?? 'unknown error'}',
      ),
      UploadStatus.cancelled => (
        Icon(Icons.block_rounded, color: scheme.onSurfaceVariant),
        'Cancelled',
      ),
    };
    return ListTile(
      dense: true,
      leading: SizedBox(width: 28, child: Center(child: icon)),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$status · ${_fileSize(item.sizeBytes)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: item.status == UploadStatus.failed
              ? scheme.error
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Picks the part of a song to keep: play it and tap "Start here" and
/// "End here", or drag the handles.
class TrimScreen extends StatefulWidget {
  const TrimScreen({
    super.key,
    required this.source,
    required this.title,
    this.start,
    this.end,
  });
  final String source, title;
  final Duration? start, end;

  @override
  State<TrimScreen> createState() => _TrimScreenState();
}

class _TrimScreenState extends State<TrimScreen> {
  static const _minimum = Duration(seconds: 1);
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;
  Duration _duration = Duration.zero, _position = Duration.zero;
  late Duration _start = widget.start ?? Duration.zero;
  Duration? _end;
  bool _playing = false, _saving = false;
  String? _error;

  Duration get _selectionEnd => _end ?? _duration;

  @override
  void initState() {
    super.initState();
    context.read<MusicController>().pauseAudio();
    _positionSub = _player.positionStream.listen((position) {
      if (!mounted) return;
      // The preview stops at the end of the selection.
      if (_player.playing && position >= _selectionEnd) _player.pause();
      setState(() => _position = position);
    });
    _stateSub = _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(
        () => _playing =
            state.playing && state.processingState != ProcessingState.completed,
      );
    });
    _load();
  }

  Future<void> _load() async {
    try {
      // Files from the native chooser are content URIs, not paths.
      final length = widget.source.startsWith('content://')
          ? await _player.setUrl(widget.source)
          : await _player.setFilePath(widget.source);
      if (!mounted) return;
      if (length == null || length <= _minimum) {
        throw StateError('Unknown length');
      }
      final end = widget.end;
      setState(() {
        _duration = length;
        _end = end != null && end <= length ? end : length;
        if (_start + _minimum > _selectionEnd) _start = Duration.zero;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'This file could not be opened for trimming.');
      }
    }
  }

  Future<void> _togglePlay() async {
    if (_player.playing) {
      await _player.pause();
      return;
    }
    if (_position < _start || _position >= _selectionEnd) {
      await _player.seek(_start);
    }
    unawaited(_player.play());
  }

  void _setStart() {
    final latest = _selectionEnd - _minimum;
    setState(() => _start = _position > latest ? latest : _position);
  }

  void _setEnd() {
    final earliest = _start + _minimum;
    final value = _position < earliest ? earliest : _position;
    setState(() => _end = value > _duration ? _duration : value);
  }

  Future<void> _save() async {
    final end = _end;
    if (end == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    await _player.pause();
    try {
      final path = await _mediaTools
          .invokeMethod<String>('extractAndTrimAudio', {
            'source': widget.source,
            'startMs': _start.inMilliseconds,
            'endMs': end.inMilliseconds,
          });
      if (path == null) throw StateError('No trimmed file');
      if (!mounted) {
        discardTemporaryCopy(path);
        return;
      }
      Navigator.pop(context, (path: path, start: _start, end: end));
    } catch (error) {
      // The native reason ends up in logcat for debugging.
      debugPrint('Trim failed: $error');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            'This phone could not trim this audio. Upload it without trimming instead.';
      });
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = _muted(context);
    final ready = _end != null;
    final end = _selectionEnd;
    final small = TextStyle(color: muted, fontSize: 12);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trim'),
        actions: [
          if (ready)
            TextButton(
              onPressed: _saving
                  ? null
                  : () => setState(() {
                      _start = Duration.zero;
                      _end = _duration;
                    }),
              child: const Text('Reset'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          Text(
            widget.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            _error ??
                (ready
                    ? 'Keeping ${_time(_start)} – ${_time(end)} · ${_time(end - _start)} long'
                    : 'Loading…'),
            style: TextStyle(
              color: _error == null
                  ? muted
                  : Theme.of(context).colorScheme.error,
              fontSize: 13,
            ),
          ),
          if (ready) ...[
            const SizedBox(height: 28),
            RangeSlider(
              values: RangeValues(
                _start.inMilliseconds.toDouble(),
                end.inMilliseconds.toDouble(),
              ),
              max: math.max(1, _duration.inMilliseconds).toDouble(),
              onChanged: _saving
                  ? null
                  : (values) {
                      if (values.end - values.start < _minimum.inMilliseconds) {
                        return;
                      }
                      setState(() {
                        _start = Duration(milliseconds: values.start.round());
                        _end = Duration(milliseconds: values.end.round());
                      });
                    },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Text(_time(_start), style: small),
                  const Spacer(),
                  Text('Now ${_time(_position)}', style: small),
                  const Spacer(),
                  Text(_time(end), style: small),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Center(
              child: SizedBox.square(
                dimension: 72,
                child: IconButton.filled(
                  tooltip: _playing ? 'Pause' : 'Play selection',
                  iconSize: 36,
                  style: IconButton.styleFrom(
                    backgroundColor: NexMusic.violet,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _saving ? null : _togglePlay,
                  icon: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : _setStart,
                    child: const Text('Start here'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : _setEnd,
                    child: const Text('End here'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Play the song and tap Start here and End here, or drag the handles.',
              textAlign: TextAlign.center,
              style: small,
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: FilledButton(
            onPressed: ready && !_saving ? _save : null,
            child: Text(_saving ? 'Trimming…' : 'Use this part'),
          ),
        ),
      ),
    );
  }
}

class SongEditorScreen extends StatefulWidget {
  const SongEditorScreen({super.key, required this.song});
  final Song song;

  @override
  State<SongEditorScreen> createState() => _SongEditorScreenState();
}

class _SongEditorScreenState extends State<SongEditorScreen> {
  late final _title = TextEditingController(text: widget.song.title);
  late final _artist = TextEditingController(
    text:
        context.read<MusicController>().personal.songArtists[widget.song.id] ??
        widget.song.artist,
  );
  late String _categoryId = widget.song.categoryId;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final music = context.read<MusicController>();
    setState(() => _saving = true);
    final saved = await music.updateSong(
      widget.song,
      title: _title.text,
      categoryId: _categoryId,
      artist: _artist.text,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final categories = context.select<MusicController, List<MusicCategory>>(
      (music) => music.categories,
    );
    final valid =
        _title.text.trim().isNotEmpty &&
        categories.any((category) => category.id == _categoryId);
    return Scaffold(
      appBar: AppBar(title: const Text('Edit song')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          TextField(
            controller: _title,
            maxLength: 160,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Title',
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _artist,
            maxLength: 160,
            decoration: const InputDecoration(
              labelText: 'Artist',
              helperText: 'Artist tags group your songs on this device.',
              counterText: '',
            ),
          ),
          const SizedBox(height: 20),
          _ChoicePicker(
            label: 'Category',
            options: [
              for (final category in categories)
                (id: category.id, name: category.name),
            ],
            selectedId: _categoryId,
            onChanged: (id) => setState(() => _categoryId = id),
            onCreate: () async => (await _createCategory(context))?.id,
            createLabel: 'New category',
            onManage: () => _push(context, const CategoryManagerScreen()),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: valid && !_saving ? _save : null,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Players
// ─────────────────────────────────────────────────────────────────────────────

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context
        .select<
          MusicController,
          ({
            Song? song,
            bool playing,
            bool loading,
            Duration duration,
            String category,
          })
        >(
          (music) => (
            song: music.current,
            playing: music.playing,
            loading: music.loading,
            duration: music.duration,
            category: music.current == null || music.current!.isPrivate
                ? 'Private library'
                : music.categoryName(music.current!.categoryId),
          ),
        );
    final song = state.song;
    if (song == null) return const SizedBox.shrink();
    final music = context.read<MusicController>();
    final scheme = Theme.of(context).colorScheme;
    final isLiked = music.isLiked(song);

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openPlayer(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Row(
                  children: [
                    _Thumb(
                      icon: song.isVideo
                          ? Icons.play_arrow_rounded
                          : Icons.music_note_rounded,
                      imageUrl: song.artworkUrl,
                      size: 44,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artist.isNotEmpty
                                ? song.artist
                                : state.category,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!song.isProvider)
                      IconButton(
                        tooltip: isLiked ? 'Unlike' : 'Like',
                        iconSize: 20,
                        onPressed: () => music.toggleLike(song),
                        icon: Icon(
                          isLiked
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: isLiked
                              ? NexMusic.violet
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    if (song.providerId.startsWith('yt'))
                      IconButton(
                        tooltip: 'Watch Video',
                        iconSize: 22,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _openSongVideo(context, song),
                        icon: const Icon(
                          Icons.smart_display_rounded,
                          color: NexMusic.violet,
                        ),
                      ),
                    IconButton(
                      tooltip: state.playing ? 'Pause' : 'Play',
                      iconSize: 30,
                      onPressed: music.togglePlay,
                      icon: state.loading
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              state.playing
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_filled_rounded,
                              color: NexMusic.violet,
                            ),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<Duration>(
                valueListenable: music.positionListenable,
                builder: (_, position, _) {
                  final total = state.duration.inMilliseconds;
                  final value = total <= 0
                      ? 0.0
                      : (position.inMilliseconds / total).clamp(0.0, 1.0);
                  return LinearProgressIndicator(
                    value: value,
                    minHeight: 2.5,
                    backgroundColor: scheme.outlineVariant.withValues(
                      alpha: 0.3,
                    ),
                    valueColor: const AlwaysStoppedAnimation(NexMusic.violet),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context
        .select<
          MusicController,
          ({
            Song? song,
            bool playing,
            bool loading,
            bool shuffle,
            bool repeat,
            bool liked,
            Duration duration,
            String category,
          })
        >((music) {
          final song = music.current;
          return (
            song: song,
            playing: music.playing,
            loading: music.loading,
            shuffle: music.shuffle,
            repeat: music.repeat,
            liked: song != null && music.isLiked(song),
            duration: music.duration,
            category: song == null ? 'Music' : music.songSource(song),
          );
        });
    final music = context.read<MusicController>();
    final song = state.song;
    final muted = _muted(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        centerTitle: true,
        title: Text(
          'Now playing',
          style: TextStyle(fontSize: 14, color: muted),
        ),
        actions: [
          IconButton(
            tooltip: 'Play queue',
            icon: const Icon(Icons.queue_music),
            onPressed: () => _push(context, const MusicQueueScreen()),
          ),
          PopupMenuButton<String>(
            tooltip: 'Listening tools',
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'lyrics', child: Text('Lyrics')),
              PopupMenuItem(value: 'karaoke', child: Text('Sing along')),
              PopupMenuItem(value: 'sleep', child: Text('Sleep timer')),
              PopupMenuItem(value: 'sound', child: Text('Sound settings')),
              PopupMenuItem(value: 'cast', child: Text('Cast to a device')),
            ],
            onSelected: (v) {
              if (v == 'sleep') {
                _sleepTimerSheet(context);
              } else if (v == 'sound') {
                _push(context, const ListeningSettingsScreen());
              } else if (v == 'cast') {
                _castSong(context, song);
              } else if (song != null) {
                _push(
                  context,
                  MusicLyricsScreen(song: song, karaoke: v == 'karaoke'),
                );
              }
            },
          ),
          if (song != null && song.providerId.startsWith('yt'))
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: () => _openSongVideo(context, song),
                icon: const Icon(
                  Icons.smart_display_rounded,
                  size: 20,
                  color: NexMusic.violet,
                ),
                label: const Text(
                  'Video',
                  style: TextStyle(
                    color: NexMusic.violet,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: song == null
          ? const _EmptyState(
              icon: Icons.music_off_rounded,
              title: 'Nothing playing',
              subtitle: 'Pick a song to start listening.',
            )
          : SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final art = math
                      .min(
                        constraints.maxWidth - 48,
                        constraints.maxHeight * 0.4,
                      )
                      .clamp(96.0, 340.0);
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: math.max(0, constraints.maxHeight - 32),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _Thumb(
                            icon: Icons.music_note_rounded,
                            size: art,
                            imageUrl: song.artworkUrl,
                          ),
                          if (song.providerId.startsWith('yt')) ...[
                            const SizedBox(height: 16),
                            FilledButton.tonalIcon(
                              onPressed: () => _openSongVideo(context, song),
                              icon: const Icon(
                                Icons.smart_display_rounded,
                                size: 20,
                              ),
                              label: const Text(
                                'Watch Music Video',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: NexMusic.violet.withValues(
                                  alpha: 0.15,
                                ),
                                foregroundColor: NexMusic.violet,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24),
                                  side: const BorderSide(
                                    color: NexMusic.violet,
                                    width: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      song.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -0.3,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      state.category,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: muted),
                                    ),
                                  ],
                                ),
                              ),
                              if (!song.isPrivate)
                                IconButton(
                                  tooltip: state.liked ? 'Unlike' : 'Like',
                                  onPressed: () => music.toggleLike(song),
                                  icon: Icon(
                                    state.liked
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    color: state.liked ? NexMusic.violet : null,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ValueListenableBuilder<Duration>(
                            valueListenable: music.positionListenable,
                            builder: (context, position, _) {
                              final max = math
                                  .max(1, state.duration.inMilliseconds)
                                  .toDouble();
                              final value = position.inMilliseconds
                                  .clamp(0, max.toInt())
                                  .toDouble();
                              return Column(
                                children: [
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      overlayShape:
                                          SliderComponentShape.noOverlay,
                                    ),
                                    child: Slider(
                                      value: value,
                                      max: max,
                                      onChanged: (next) => music.seek(
                                        Duration(milliseconds: next.round()),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Text(
                                        _time(position),
                                        style: TextStyle(
                                          color: muted,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        _time(state.duration),
                                        style: TextStyle(
                                          color: muted,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                tooltip: 'Shuffle',
                                onPressed: music.toggleShuffle,
                                icon: Icon(
                                  Icons.shuffle_rounded,
                                  color: state.shuffle
                                      ? NexMusic.violet
                                      : muted,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Previous',
                                iconSize: 32,
                                onPressed: music.previous,
                                icon: const Icon(Icons.skip_previous_rounded),
                              ),
                              SizedBox.square(
                                dimension: 64,
                                child: IconButton.filled(
                                  tooltip: state.playing ? 'Pause' : 'Play',
                                  iconSize: 32,
                                  style: IconButton.styleFrom(
                                    backgroundColor: NexMusic.violet,
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: music.togglePlay,
                                  icon: state.loading
                                      ? const SizedBox.square(
                                          dimension: 24,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Icon(
                                          state.playing
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                        ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Next',
                                iconSize: 32,
                                onPressed: music.next,
                                icon: const Icon(Icons.skip_next_rounded),
                              ),
                              IconButton(
                                tooltip: 'Repeat',
                                onPressed: music.toggleRepeat,
                                icon: Icon(
                                  music.playback.queue.repeat == MusicRepeat.one
                                      ? Icons.repeat_one_rounded
                                      : Icons.repeat_rounded,
                                  color: state.repeat ? NexMusic.violet : muted,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class VideoScreen extends StatefulWidget {
  const VideoScreen({
    super.key,
    required this.song,
    this.httpHeaders = const {},
    this.initialPosition = Duration.zero,
    this.onClosed,
  });
  final Song song;
  final Map<String, String> httpHeaders;
  final Duration initialPosition;
  final void Function(Duration)? onClosed;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  late final VideoPlayerController _video;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    context.read<MusicController>().pauseAudio();
    final url = widget.song.url;
    _video = url.startsWith('file:')
        ? VideoPlayerController.file(File.fromUri(Uri.parse(url)))
        : VideoPlayerController.networkUrl(
            Uri.parse(url),
            httpHeaders: widget.httpHeaders,
          );
    _video.addListener(_refresh);
    // Streaming formats are not bundled with the app, see isStreamingLink.
    _failed = isStreamingLink(url);
    if (!_failed) _start();
  }

  Future<void> _start() async {
    try {
      await _video.initialize();
      if (widget.initialPosition > Duration.zero) {
        await _video.seekTo(widget.initialPosition);
      }
      await _video.play();
      if (mounted) context.read<MusicController>().recordVideoPlay(widget.song);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _toggle() => _video.value.isPlaying ? _video.pause() : _video.play();

  @override
  void dispose() {
    widget.onClosed?.call(_video.value.position);
    _video.removeListener(_refresh);
    _video.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _video.value;
    final failed = _failed || value.hasError;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (widget.onClosed != null)
            IconButton(
              tooltip: 'Switch to audio',
              icon: const Icon(Icons.headphones),
              onPressed: () => Navigator.pop(context),
            ),
        ],
        title: Text(
          widget.song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: failed
                    ? const Text(
                        'This video could not be played.',
                        style: TextStyle(color: Colors.white70),
                      )
                    : !value.isInitialized
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : GestureDetector(
                        onTap: _toggle,
                        child: AspectRatio(
                          aspectRatio: value.aspectRatio,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              VideoPlayer(_video),
                              if (!value.isPlaying)
                                const Icon(
                                  Icons.play_arrow_rounded,
                                  size: 64,
                                  color: Colors.white70,
                                ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
            if (value.isInitialized && !failed)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 12),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: value.isPlaying ? 'Pause' : 'Play',
                      color: Colors.white,
                      onPressed: _toggle,
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    Expanded(
                      child: VideoProgressIndicator(
                        _video,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        colors: const VideoProgressColors(
                          playedColor: NexMusic.violet,
                          bufferedColor: Colors.white24,
                          backgroundColor: Colors.white12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${_time(value.position)} / ${_time(value.duration)}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Profile & lists
// ─────────────────────────────────────────────────────────────────────────────

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, this.showAppBar = true});
  final bool showAppBar;

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    final content = ListView(
      padding: EdgeInsets.only(top: showAppBar ? 0 : 16, bottom: 32),
      children: [
        _NavRow(
          icon: Icons.tune,
          title: 'Listening settings',
          onTap: () => _push(context, const ListeningSettingsScreen()),
        ),
        _NavRow(
          icon: Icons.insights,
          title: 'Your listening week',
          onTap: () => _push(context, const ListeningStatsScreen()),
        ),
        if (!showAppBar)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 10, 20, 12),
            child: Text(
              'Profile',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Row(
            children: [
              _Avatar(initials: music.profileInitials, size: 52),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      music.profileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (music.profileEmail.isNotEmpty)
                      Text(
                        music.profileEmail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _muted(context), fontSize: 13),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        _NavRow(
          icon: Icons.cloud_upload_outlined,
          title: 'My uploads',
          trailing: '${music.myUploads.length}',
          onTap: () => _push(
            context,
            SongListScreen(
              title: 'My uploads',
              emptyText: 'Songs and videos you upload show up here.',
              select: (music) => music.myUploads,
            ),
          ),
        ),
        _NavRow(
          icon: Icons.favorite_border_rounded,
          title: 'Liked',
          trailing: '${music.likedSongs.length}',
          onTap: () => _push(
            context,
            SongListScreen(
              title: 'Liked',
              emptyText: 'Tap ⋮ on any song and choose Like.',
              select: (music) => music.likedSongs,
            ),
          ),
        ),
        _NavRow(
          icon: Icons.history_rounded,
          title: 'Recently played',
          onTap: () => _push(
            context,
            SongListScreen(
              title: 'Recently played',
              emptyText: 'Songs you play show up here.',
              select: (music) => music.recentSongs,
            ),
          ),
        ),
        if (!kIsWeb)
          _NavRow(
            icon: Icons.download_done_rounded,
            title: 'Downloads',
            trailing: '${music.downloadedSongs.length}',
            onTap: () => _push(
              context,
              SongListScreen(
                title: 'Downloads',
                emptyText:
                    'Tap ⋮ on a song and choose Download to play it without internet.',
                select: (music) => music.downloadedSongs,
              ),
            ),
          ),
        const Divider(),
        _NavRow(
          icon: Icons.lock_outline_rounded,
          title: 'Private library',
          trailing: '${music.savedMedia.length}',
          onTap: () => _push(context, const PrivateLibraryScreen()),
        ),
        _NavRow(
          icon: Icons.insights_rounded,
          title: 'Advance',
          subtitle: 'Cloudinary songs, storage & playback usage',
          onTap: () => _push(context, const AdvanceScreen()),
        ),
        const Divider(),
        if (music.phone != null)
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('Activity notifications'),
            subtitle: const Text('When someone uploads, edits or deletes'),
            value: music.pushEnabled,
            onChanged: music.setPushEnabled,
          ),
        SwitchListTile(
          secondary: const Icon(Icons.dark_mode_outlined),
          title: const Text('Dark mode'),
          value: music.darkMode,
          onChanged: music.setDarkMode,
        ),
        if (!kIsWeb)
          _NavRow(
            icon: Icons.system_update_rounded,
            title: 'Check for updates',
            subtitle: 'Tap to check · Long press to preview',
            trailing: 'v${music.installedVersion}',
            onTap: () => _manualCheckAppUpdate(context),
            onLongPress: () => _manualCheckAppUpdate(context, force: true),
          ),
        _NavRow(
          icon: Icons.logout_rounded,
          title: 'Sign out',
          showChevron: false,
          onTap: () {
            Navigator.of(context).popUntil((route) => route.isFirst);
            music.signOut();
          },
        ),
        const SizedBox(height: 24),
        Center(
          child: Text(
            'nexMusic v${music.installedVersion}',
            style: TextStyle(color: _muted(context), fontSize: 12),
          ),
        ),
      ],
    );
    if (!showAppBar) {
      return SafeArea(child: content);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('You')),
      body: content,
    );
  }
}

Future<void> _manualCheckAppUpdate(
  BuildContext context, {
  bool force = false,
}) async {
  final scaffold = ScaffoldMessenger.of(context);
  final music = context.read<MusicController>();
  scaffold.showSnackBar(
    SnackBar(
      content: Text(
        force ? 'Loading update preview…' : 'Checking for updates…',
      ),
      duration: const Duration(seconds: 1),
    ),
  );
  try {
    await music.preferences.remove('dismissed_update_tag');
    final update = await AppUpdateService().checkForUpdate(
      phone: music.phone,
      force: force,
    );
    if (!context.mounted) return;
    scaffold.hideCurrentSnackBar();
    if (update != null) {
      _showUpdateSheet(context, update);
    } else {
      scaffold.showSnackBar(
        SnackBar(
          content: Text('nexMusic is up to date (v${music.installedVersion})!'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  } catch (error) {
    if (!context.mounted) return;
    scaffold.hideCurrentSnackBar();
    scaffold.showSnackBar(
      const SnackBar(
        content: Text('Could not check for updates. Check connection.'),
      ),
    );
  }
}

class SongListScreen extends StatelessWidget {
  const SongListScreen({
    super.key,
    required this.title,
    required this.emptyText,
    required this.select,
  });
  final String title, emptyText;
  final List<Song> Function(MusicController music) select;

  @override
  Widget build(BuildContext context) {
    final songs = context.select<MusicController, List<Song>>(select);
    return _SongSelectionScaffold(
      songs: songs,
      appBar: AppBar(title: Text(title)),
      body: songs.isEmpty
          ? _EmptyState(
              icon: Icons.music_note_outlined,
              title: 'Nothing here yet',
              subtitle: emptyText,
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: songs.length,
              itemBuilder: (_, i) => SongTile(song: songs[i], queue: songs),
            ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private library
// ─────────────────────────────────────────────────────────────────────────────

class PrivateLibraryScreen extends StatefulWidget {
  const PrivateLibraryScreen({super.key});

  @override
  State<PrivateLibraryScreen> createState() => _PrivateLibraryScreenState();
}

class _PrivateLibraryScreenState extends State<PrivateLibraryScreen> {
  String? _folderId;

  Future<void> _newFolder() async {
    final folder = await _createFolder(context);
    if (!mounted || folder == null) return;
    setState(() => _folderId = folder.id);
  }

  @override
  Widget build(BuildContext context) {
    final music = context.watch<MusicController>();
    final folders = music.mediaFolders;
    final selected = folders.any((folder) => folder.id == _folderId)
        ? _folderId
        : null;
    final items = selected == null
        ? music.savedMedia
        : music.savedMedia.where((item) => item.folderId == selected).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Private library'),
        actions: [
          IconButton(
            tooltip: 'Add',
            onPressed: () => _showImportMenu(context),
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
              children: [
                _Pill(
                  label: 'All',
                  selected: selected == null,
                  onTap: () => setState(() => _folderId = null),
                ),
                for (final folder in folders)
                  _Pill(
                    label: folder.name,
                    selected: selected == folder.id,
                    onTap: () => setState(() => _folderId = folder.id),
                    onLongPress: () => _folderActions(context, folder),
                  ),
                _Pill(
                  icon: Icons.add_rounded,
                  label: 'Folder',
                  onTap: _newFolder,
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const _EmptyState(
                    icon: Icons.lock_outline_rounded,
                    title: 'Nothing saved yet',
                    subtitle:
                        'Save links or keep your own files here. Only you can see them.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: items.length,
                    itemBuilder: (context, i) => _PrivateTile(item: items[i]),
                  ),
          ),
        ],
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}

class _PrivateTile extends StatelessWidget {
  const _PrivateTile({required this.item});
  final SavedMedia item;

  @override
  Widget build(BuildContext context) {
    final music = context.read<MusicController>();
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      leading: _Thumb(icon: _mediaIcon(item)),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        _mediaSubtitle(music, item),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: _muted(context), fontSize: 12),
      ),
      trailing: IconButton(
        tooltip: 'More',
        onPressed: () => _privateActions(context, item),
        icon: Icon(Icons.more_vert_rounded, color: _muted(context)),
      ),
      onTap: () => _openPrivate(context, item),
    );
  }
}

Future<void> _openPrivate(BuildContext context, SavedMedia item) async {
  if (item.kind == 'link') {
    final url = item.sourceUrl;
    if (url == null) return;
    if (_webViewSupported) {
      _push(context, NexBrowserScreen(sharedLink: url));
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Link copied.')));
    return;
  }
  final song = await context.read<MusicController>().privateSong(item);
  if (song == null || !context.mounted) return;
  _openSong(context, song, queue: [song]);
}

Future<void> _privateActions(BuildContext context, SavedMedia item) {
  final music = context.read<MusicController>();
  final downloaded = music.isDownloaded(item);
  return _sheet(
    context,
    title: item.title,
    (sheetContext) => [
      if (item.kind != 'link')
        ListTile(
          leading: const Icon(Icons.playlist_add),
          title: const Text('Add to personal playlist'),
          onTap: () async {
            Navigator.pop(sheetContext);
            final track = await music.privateSong(item);
            if (track != null && context.mounted) {
              await _choosePlaylist(context, track);
            }
          },
        ),
      ListTile(
        leading: const Icon(Icons.edit_outlined),
        title: const Text('Edit or move'),
        onTap: () {
          Navigator.pop(sheetContext);
          _push(context, SavedMediaEditorScreen(item: item));
        },
      ),
      if (item.storagePath != null && !downloaded && !kIsWeb)
        ListTile(
          leading: const Icon(Icons.download_rounded),
          title: const Text('Download offline'),
          onTap: () {
            Navigator.pop(sheetContext);
            music.downloadMedia(item);
          },
        ),
      if (downloaded)
        ListTile(
          leading: const Icon(Icons.offline_pin_outlined),
          title: const Text('Remove offline copy'),
          onTap: () {
            Navigator.pop(sheetContext);
            music.removeDownload(item);
          },
        ),
      ListTile(
        leading: const Icon(Icons.delete_outline_rounded),
        title: const Text('Delete'),
        onTap: () async {
          Navigator.pop(sheetContext);
          final confirmed = await _confirm(
            context,
            title: 'Delete "${item.title}"?',
            body: item.storagePath == null
                ? 'This saved link will be removed.'
                : 'The cloud file and any offline copy will be removed.',
            action: 'Delete',
          );
          if (confirmed) await music.deleteMedia(item);
        },
      ),
    ],
  );
}

Future<void> _folderActions(BuildContext context, MediaFolder folder) {
  final music = context.read<MusicController>();
  final count = music.savedMedia
      .where((item) => item.folderId == folder.id)
      .length;
  final lastFolder = music.mediaFolders.length <= 1;
  return _sheet(
    context,
    title: folder.name,
    (sheetContext) => [
      ListTile(
        leading: const Icon(Icons.drive_file_rename_outline_rounded),
        title: const Text('Rename'),
        onTap: () async {
          Navigator.pop(sheetContext);
          final name = await _nameDialog(
            context,
            title: 'Rename folder',
            action: 'Save',
            initialValue: folder.name,
          );
          if (name != null) await music.updateMediaFolder(folder, name);
        },
      ),
      ListTile(
        enabled: count == 0 && !lastFolder,
        leading: const Icon(Icons.delete_outline_rounded),
        title: const Text('Delete'),
        subtitle: Text(
          count > 0
              ? 'Move its $count item(s) first'
              : lastFolder
              ? 'Keep at least one folder'
              : 'Folder is empty',
        ),
        onTap: () async {
          Navigator.pop(sheetContext);
          final confirmed = await _confirm(
            context,
            title: 'Delete "${folder.name}"?',
            body: 'This folder will be removed.',
            action: 'Delete',
          );
          if (confirmed) await music.deleteMediaFolder(folder);
        },
      ),
    ],
  );
}

void _showImportMenu(BuildContext context) {
  _sheet(
    context,
    title: 'Add to private library',
    (sheetContext) => [
      ListTile(
        leading: const Icon(Icons.link_rounded),
        title: const Text('Save a link'),
        subtitle: const Text('YouTube or any web page'),
        onTap: () {
          Navigator.pop(sheetContext);
          _push(context, const SharedImportScreen(source: ''));
        },
      ),
      ListTile(
        leading: const Icon(Icons.content_cut_rounded),
        title: const Text('Keep my own file'),
        subtitle: const Text('Trim audio or save the original privately'),
        onTap: () async {
          Navigator.pop(sheetContext);
          // Media types instead of extensions, as in UploadScreen._pickFiles.
          final file = await FilePicker.pickFile(type: FileType.media);
          final source = file?.path;
          if (!context.mounted || file == null || source == null) return;
          if (uploadKindFor(file.name) == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Choose an audio or video file.')),
            );
            return;
          }
          _push(
            context,
            OwnedMediaEditorScreen(source: source, suggestedName: file.name),
          );
        },
      ),
    ],
  );
}

class SharedImportScreen extends StatefulWidget {
  const SharedImportScreen({super.key, required this.source});
  final String source;

  @override
  State<SharedImportScreen> createState() => _SharedImportScreenState();
}

class _SharedImportScreenState extends State<SharedImportScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _titleController;
  String? _folderId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final incoming = widget.source.trim();
    final url =
        RegExp(
          r'https?://\S+',
        ).firstMatch(incoming)?.group(0)?.replaceAll(RegExp(r'[),.]+$'), '') ??
        incoming;
    _urlController = TextEditingController(text: url);
    _titleController = TextEditingController(
      text: incoming.isEmpty ? '' : 'Shared video',
    );
    if (incoming.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openInBrowser());
    }
  }

  Future<void> _openInBrowser() async {
    final value = _urlController.text.trim();
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid web link first.')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    if (_webViewSupported) {
      _push(context, NexBrowserScreen(sharedLink: value));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Link copied. The browser is available on mobile.'),
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _saveLink() async {
    final folderId = _folderId;
    if (_urlController.text.trim().isEmpty || folderId == null) return;
    setState(() => _saving = true);
    final saved = await context.read<MusicController>().saveSharedLink(
      url: _urlController.text.trim(),
      title: _titleController.text.trim(),
      folderId: folderId,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final folders = context.select<MusicController, List<MediaFolder>>(
      (music) => music.mediaFolders,
    );
    final folderValid = folders.any((folder) => folder.id == _folderId);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Save link'),
        actions: [
          IconButton(
            tooltip: 'Open in browser',
            onPressed: _openInBrowser,
            icon: const Icon(Icons.open_in_new_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Link'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 20),
          _ChoicePicker(
            label: 'Folder',
            options: [
              for (final folder in folders) (id: folder.id, name: folder.name),
            ],
            selectedId: _folderId,
            onChanged: (id) => setState(() => _folderId = id),
            onCreate: () async => (await _createFolder(context))?.id,
            createLabel: 'New folder',
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving || !folderValid ? null : _saveLink,
            child: Text(_saving ? 'Saving…' : 'Save link'),
          ),
        ],
      ),
    );
  }
}

class SavedMediaEditorScreen extends StatefulWidget {
  const SavedMediaEditorScreen({super.key, required this.item});
  final SavedMedia item;

  @override
  State<SavedMediaEditorScreen> createState() => _SavedMediaEditorScreenState();
}

class _SavedMediaEditorScreenState extends State<SavedMediaEditorScreen> {
  late final _titleController = TextEditingController(text: widget.item.title);
  late final _urlController = TextEditingController(
    text: widget.item.sourceUrl ?? '',
  );
  late String _folderId = widget.item.folderId;
  bool _saving = false;

  @override
  void dispose() {
    _titleController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final music = context.read<MusicController>();
    setState(() => _saving = true);
    final saved = await music.updateMedia(
      widget.item,
      title: _titleController.text,
      folderId: _folderId,
      sourceUrl: widget.item.kind == 'link' ? _urlController.text : null,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final folders = context.select<MusicController, List<MediaFolder>>(
      (music) => music.mediaFolders,
    );
    final isLink = widget.item.kind == 'link';
    final folderValid = folders.any((folder) => folder.id == _folderId);
    return Scaffold(
      appBar: AppBar(title: const Text('Edit')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          if (isLink) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Link'),
            ),
          ],
          const SizedBox(height: 20),
          _ChoicePicker(
            label: 'Folder',
            options: [
              for (final folder in folders) (id: folder.id, name: folder.name),
            ],
            selectedId: _folderId,
            onChanged: (id) => setState(() => _folderId = id),
            onCreate: () async => (await _createFolder(context))?.id,
            createLabel: 'New folder',
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving || !folderValid ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}

class OwnedMediaEditorScreen extends StatefulWidget {
  const OwnedMediaEditorScreen({
    super.key,
    required this.source,
    required this.suggestedName,
  });
  final String source, suggestedName;

  @override
  State<OwnedMediaEditorScreen> createState() => _OwnedMediaEditorScreenState();
}

class _OwnedMediaEditorScreenState extends State<OwnedMediaEditorScreen> {
  static const _mediaChannel = _mediaTools;
  final _preview = AudioPlayer();
  late final TextEditingController _titleController;
  StreamSubscription<Duration>? _positionSub;
  double _durationSeconds = 180, _startSeconds = 0, _endSeconds = 30;
  String? _folderId, _error;
  bool _permitted = false, _processing = false, _previewing = false;

  @override
  void initState() {
    super.initState();
    final baseName = widget.suggestedName.replaceAll(RegExp(r'\.[^.]+$'), '');
    _titleController = TextEditingController(text: baseName);
    _positionSub = _preview.positionStream.listen((position) {
      if (position.inMilliseconds >= _endSeconds * 1000 && _preview.playing) {
        _preview.pause();
        if (mounted) setState(() => _previewing = false);
      }
    });
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    try {
      final foundDuration = await _preview.setUrl(widget.source);
      if (!mounted || foundDuration == null) return;
      setState(() {
        _durationSeconds = math.max(1, foundDuration.inMilliseconds / 1000);
        _endSeconds = math.min(_durationSeconds, 30);
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Preview unavailable; extraction may still work on Android.',
        );
      }
    }
  }

  Future<void> _togglePreview() async {
    if (_preview.playing) {
      await _preview.pause();
      if (!mounted) return;
      setState(() => _previewing = false);
      return;
    }
    await _preview.seek(Duration(milliseconds: (_startSeconds * 1000).round()));
    if (!mounted) return;
    _preview.play();
    setState(() => _previewing = true);
  }

  Future<void> _processAndSave() async {
    final folderId = _folderId;
    if (!_permitted || folderId == null) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      await _preview.pause();
      final exportPath = await _mediaChannel
          .invokeMethod<String>('extractAndTrimAudio', {
            'source': widget.source,
            'startMs': (_startSeconds * 1000).round(),
            'endMs': (_endSeconds * 1000).round(),
          });
      if (exportPath == null) throw StateError('No export was created.');
      if (!mounted) return;
      final uploaded = await context.read<MusicController>().uploadOwnedAudio(
        filePath: exportPath,
        title: _titleController.text.trim().isEmpty
            ? 'Imported audio'
            : _titleController.text.trim(),
        folderId: folderId,
      );
      if (mounted && uploaded) Navigator.pop(context);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? e.code);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _uploadOriginal() async {
    final folderId = _folderId;
    if (!_permitted || folderId == null) return;
    final ext = widget.suggestedName.split('.').last.toLowerCase();
    final isVideo = const {'mp4', 'mov'}.contains(ext);
    final contentType = switch (ext) {
      'mov' => 'video/quicktime',
      'mp4' => 'video/mp4',
      'mp3' => 'audio/mpeg',
      'aac' => 'audio/aac',
      _ => 'audio/mp4',
    };
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      await _preview.pause();
      if (!mounted) return;
      final uploaded = await context.read<MusicController>().uploadOwnedMedia(
        filePath: widget.source,
        title: _titleController.text.trim().isEmpty
            ? 'Imported media'
            : _titleController.text.trim(),
        folderId: folderId,
        kind: isVideo ? 'video' : 'audio',
        contentType: contentType,
      );
      if (mounted && uploaded) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _preview.dispose();
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final folders = context.select<MusicController, List<MediaFolder>>(
      (music) => music.mediaFolders,
    );
    final canSave =
        _permitted &&
        !_processing &&
        folders.any((folder) => folder.id == _folderId);
    String at(double seconds) =>
        _time(Duration(milliseconds: (seconds * 1000).round()));
    return Scaffold(
      appBar: AppBar(title: const Text('Keep privately')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              const Text('Trim', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                '${at(_startSeconds)} – ${at(_endSeconds)}',
                style: TextStyle(color: _muted(context), fontSize: 13),
              ),
            ],
          ),
          RangeSlider(
            values: RangeValues(_startSeconds, _endSeconds),
            min: 0,
            max: _durationSeconds,
            divisions: math.max(1, _durationSeconds.round()),
            labels: RangeLabels(at(_startSeconds), at(_endSeconds)),
            onChanged: (values) => setState(() {
              _startSeconds = values.start;
              _endSeconds = values.end;
            }),
          ),
          OutlinedButton.icon(
            onPressed: _togglePreview,
            icon: Icon(
              _previewing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
            label: Text(_previewing ? 'Pause' : 'Preview selection'),
          ),
          const SizedBox(height: 24),
          _ChoicePicker(
            label: 'Folder',
            options: [
              for (final folder in folders) (id: folder.id, name: folder.name),
            ],
            selectedId: _folderId,
            onChanged: (id) => setState(() => _folderId = id),
            onCreate: () async => (await _createFolder(context))?.id,
            createLabel: 'New folder',
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _permitted,
            onChanged: (value) => setState(() => _permitted = value ?? false),
            title: const Text(
              'I own this media or have permission to process it',
              style: TextStyle(fontSize: 14),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: canSave ? _processAndSave : null,
            child: Text(_processing ? 'Processing…' : 'Trim & save audio'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: canSave ? _uploadOriginal : null,
            child: const Text('Save original file'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Browser
// ─────────────────────────────────────────────────────────────────────────────

/// What the one button at the bottom of the browser is for, in the order a
/// converter site walks through.
/// A shared YouTube link being turned into an audio file by a browser kept out
/// of sight behind the app, so the upload screen can be filled in meanwhile.
/// When Upload is pressed before the audio arrives, the job keeps the request
/// and uploads the file itself, so leaving the screen does not lose it.
class SharedAudioJob extends ChangeNotifier {
  SharedAudioJob._(this.link, this._music);

  /// Starts turning [link] into audio in a hidden browser.
  factory SharedAudioJob.start(String link, MusicController music) {
    final job = SharedAudioJob._(link, music);
    _jobs.add(job);
    _publish();
    // A converter that never finishes should not keep a browser running.
    job._deadline = Timer(const Duration(minutes: 3), () {
      job.fail('The converter took too long. Try again.');
    });
    return job;
  }

  /// Jobs whose hidden browsers are still at work.
  static final running = ValueNotifier<List<SharedAudioJob>>(const []);
  static final _jobs = <SharedAudioJob>[];

  /// Tells the host after the current frame. Jobs start in initState and stop
  /// in dispose, where rebuilding the host would throw.
  static void _publish() {
    scheduleMicrotask(() => running.value = List.unmodifiable(_jobs));
  }

  final String link;
  final MusicController _music;
  Timer? _deadline;
  bool _stopped = false;
  ({String title, String categoryId})? _request;

  /// What the hidden browser is doing, in words for the upload screen.
  String status = 'Finding a converter…';

  /// Share of the file downloaded, while the converter is handing it over.
  double? fraction;

  /// The title the listener gave the song, once Upload has been pressed.
  String? get requestTitle => _request?.title;

  /// The audio file, once the converter has handed it over.
  String? filePath;

  /// Why the job gave up, if it did.
  String? error;

  bool get waiting => filePath == null && error == null && !_stopped;
  bool get uploadRequested => _request != null;

  void report(String value, {double? fraction}) {
    if (!waiting || (value == status && fraction == this.fraction)) return;
    status = value;
    this.fraction = fraction;
    notifyListeners();
  }

  /// Uploads the audio with [title] into [categoryId] as soon as it arrives.
  /// Calling this again replaces the waiting request.
  void requestUpload({required String title, required String categoryId}) {
    if (!waiting) return;
    _request = (title: title, categoryId: categoryId);
    notifyListeners();
    // The home screen counts songs waiting on their audio.
    _publish();
  }

  void complete(String path) {
    if (!waiting) {
      discardTemporaryCopy(path);
      return;
    }
    filePath = path;
    status = 'Audio ready';
    _end();
    final request = _request;
    if (request != null) _upload(path, request);
    notifyListeners();
  }

  void fail(String message) {
    if (!waiting) return;
    error = message;
    _end();
    if (_request != null) {
      // The listener has likely left the upload screen, so say it wherever
      // they are now.
      _music.announce('A shared song could not be uploaded. $message');
    }
    notifyListeners();
  }

  /// Stops the hidden browser once nothing needs the audio any more.
  void cancel() {
    if (!waiting) return;
    _stopped = true;
    _end();
  }

  void _end() {
    _deadline?.cancel();
    _jobs.remove(this);
    _publish();
  }

  void _upload(String path, ({String title, String categoryId}) request) {
    final file = File(path);
    final name = _fileName(path);
    final size = file.existsSync() ? file.lengthSync() : 0;
    if (uploadKindFor(name) == null || size == 0 || size >= maxUploadBytes) {
      error = 'The converter sent a file nexMusic cannot upload.';
      _music.announce('A shared song could not be uploaded. $error');
      discardTemporaryCopy(path);
      return;
    }
    final named = request.title.isNotEmpty
        ? request.title
        : name.replaceAll(RegExp(r'\.[^.]+$'), '');
    final item = UploadItem(
      path: path,
      name: name,
      sizeBytes: size,
      title: named.length > 160 ? named.substring(0, 160) : named,
    );
    void start() =>
        unawaited(_music.startUploads([item], categoryId: request.categoryId));
    if (!_music.uploading) {
      start();
      return;
    }
    // Another batch is still going, and startUploads turns a new batch away
    // until it ends, so this song waits for its turn.
    void wait() {
      if (_music.uploading) return;
      _music.removeListener(wait);
      start();
    }

    _music.addListener(wait);
  }
}

/// Keeps the browsers of [SharedAudioJob]s running behind the whole app. A
/// converter page needs a real on-screen size to lay out and for its buttons
/// to be found, so each hidden browser fills the screen under the app's own
/// pages rather than being taken out of the widget tree.
class SharedAudioHost extends StatelessWidget {
  const SharedAudioHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      // One fixed layer, so the app above keeps its place and its state however
      // many hidden browsers come and go.
      IgnorePointer(
        child: ExcludeSemantics(
          child: ValueListenableBuilder<List<SharedAudioJob>>(
            valueListenable: SharedAudioJob.running,
            builder: (context, jobs, _) => Stack(
              fit: StackFit.expand,
              children: [
                for (final job in jobs)
                  NexBrowserScreen(
                    key: ObjectKey(job),
                    sharedLink: 'youtube to mp3',
                    pasteLink: job.link,
                    job: job,
                  ),
              ],
            ),
          ),
        ),
      ),
      child,
    ],
  );
}

enum _BrowserStep { opening, paste, convert, converting, download, downloading }

class NexBrowserScreen extends StatefulWidget {
  const NexBrowserScreen({
    super.key,
    required this.sharedLink,
    this.pasteLink = '',
    this.job,
  });
  final String sharedLink;

  /// When set, the browser runs out of sight for this job: it shows no
  /// controls or messages, and the finished file goes to the job instead of
  /// opening another upload screen.
  final SharedAudioJob? job;

  /// Link shared into nexMusic, offered as a one-tap paste on whichever site
  /// the listener opens.
  final String pasteLink;

  @override
  State<NexBrowserScreen> createState() => _NexBrowserScreenState();
}

class _NexBrowserScreenState extends State<NexBrowserScreen> {
  late final WebViewController _browser;
  late final MusicController _music;
  final _addressController = TextEditingController();
  late final TextEditingController _firstPillController;
  late final TextEditingController _secondPillController;
  var _progress = 0;
  bool _downloading = false;
  String? _currentPage, _userAgent;

  // Navigation and browser control states
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _autoOpenTopResult =
      false; // User chooses whether to auto-pick or click manually!
  bool _allowCrossDomain = true; // User can freely browse any website!
  bool _blockAds = true; // Blocks aggressive popups and redirect ads
  bool _isDesktopMode = false;
  bool _showSmartBar = true; // Floating converter helper bar
  double _zoomLevel = 1.0;

  /// Main-frame URLs requested without a page starting. The Android WebView
  /// hands a file download back as a repeat request for the same URL.
  final Map<String, int> _unstarted = {};

  /// True once an ordinary site, rather than a search page, has finished
  /// loading, so the paste and convert buttons belong on screen.
  bool _siteOpen = false;

  /// What the open site offers right now, read back from the page itself: a
  /// convert button, a download button ready to press, or work in progress.
  bool _hasConvert = false;
  bool _ready = false;
  bool _busy = false;

  /// How far the listener has got with this site.
  _BrowserStep _phase = _BrowserStep.paste;

  /// Readings in a row where a converting site reported neither work in
  /// progress nor a file.
  int _idleReads = 0;

  /// Adverts that took the place of the file.
  int _adRetries = 0;

  /// When the listener last asked for the file.
  DateTime? _downloadTapAt;

  /// True once the top search result has been opened for a shared link.
  bool _topResultOpened = false;
  bool _findingTopResult = false;

  /// Presses the app has made by itself on this page, per step.
  final Map<_BrowserStep, int> _autoTries = {};
  DateTime? _lastAutoAt;

  /// True once a file has started coming from this page.
  bool _fileTaken = false;
  bool _working = false;

  /// True while a page is still on its way in.
  bool _loading = false;

  /// Counts page loads.
  int _pageRun = 0;

  /// Re-reads the open site's buttons.
  Timer? _actionTimer;

  static bool _isAdHost(String host) {
    final lower = host.toLowerCase();
    const adKeywords = [
      'doubleclick.',
      'googleadservices.',
      'googlesyndication.',
      'adsterra.',
      'popcash.',
      'popads.',
      'propellerads.',
      'exoclick.',
      'betting',
      'casino',
      '1xbet',
      'adkeep',
      'trafficjunky',
      'adnxs.',
      'onclickmega',
      'yllix',
    ];
    return adKeywords.any((k) => lower.contains(k));
  }

  @override
  void initState() {
    super.initState();
    _music = context.read<MusicController>();
    _firstPillController = TextEditingController(
      text: _music.browserPillOne ?? widget.sharedLink,
    );
    _secondPillController = TextEditingController(
      text: _music.browserPillTwo ?? '',
    );
    _firstPillController.addListener(_saveFirstPill);
    _secondPillController.addListener(_saveSecondPill);
    _browser = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted && !_downloading) setState(() => _progress = value);
          },
          onPageStarted: (url) {
            _currentPage = url;
            _unstarted.remove(url);
            _pageRun++;
            _actionTimer?.cancel();
            _autoTries.clear();
            _lastAutoAt = DateTime.now();
            _fileTaken = false;
            if (mounted) {
              setState(() {
                _loading = true;
                _siteOpen = false;
                _hasConvert = false;
                _ready = false;
                _busy = false;
                _phase = _BrowserStep.paste;
                _idleReads = 0;
                _adRetries = 0;
                _downloadTapAt = null;
              });
            }
          },
          onPageFinished: _onPageFinished,
          onUrlChange: (change) {
            final url = change.url;
            if (url != null && !url.startsWith('data:')) {
              _addressController.text = url;
            }
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null ||
                (uri.scheme != 'https' && uri.scheme != 'http')) {
              if (request.isMainFrame &&
                  (uri?.scheme == 'blob' || uri?.scheme == 'data')) {
                widget.job?.fail(
                  'The converter builds its file in a way nexMusic cannot capture.',
                );
                _snack(
                  'This site builds its download inside the page, which nexMusic cannot capture. Try another site.',
                );
              }
              return NavigationDecision.prevent;
            }
            if (!request.isMainFrame) {
              if (_blockAds && _isAdHost(uri.host)) {
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            }

            if (widget.job != null) {
              // Headless background job keeps strict converter lock
              if (_siteOpen && !_loading && uploadKindFor(uri.path) == null) {
                String base(String host) {
                  final parts = host.toLowerCase().split('.');
                  if (parts.length < 2) return host.toLowerCase();
                  return parts.sublist(parts.length - 2).join('.');
                }

                final here = Uri.tryParse(_currentPage ?? '')?.host ?? '';
                if (here.isNotEmpty && base(here) != base(uri.host)) {
                  final asked = _downloadTapAt;
                  final wantsFile =
                      asked != null &&
                      DateTime.now().difference(asked) <
                          const Duration(seconds: 20);
                  if (wantsFile) {
                    unawaited(_saveDownload(uri, keepConverterOnWebPage: true));
                  }
                  return NavigationDecision.prevent;
                }
              }
            } else {
              // Interactive user browser:
              if (_blockAds && _isAdHost(uri.host)) {
                _snack('Redirect ad blocked: ${uri.host}');
                return NavigationDecision.prevent;
              }
              // If cross domain is disabled manually:
              if (!_allowCrossDomain &&
                  _siteOpen &&
                  !_loading &&
                  uploadKindFor(uri.path) == null) {
                String base(String host) {
                  final parts = host.toLowerCase().split('.');
                  if (parts.length < 2) return host.toLowerCase();
                  return parts.sublist(parts.length - 2).join('.');
                }

                final here = Uri.tryParse(_currentPage ?? '')?.host ?? '';
                if (here.isNotEmpty && base(here) != base(uri.host)) {
                  final asked = _downloadTapAt;
                  final wantsFile =
                      asked != null &&
                      DateTime.now().difference(asked) <
                          const Duration(seconds: 20);
                  if (wantsFile) {
                    unawaited(_saveDownload(uri, keepConverterOnWebPage: true));
                  } else {
                    _snack(
                      'That link led away from the converter; it was blocked.',
                    );
                  }
                  return NavigationDecision.prevent;
                }
              }
            }

            final attempts = _unstarted[request.url] =
                (_unstarted[request.url] ?? 0) + 1;
            if (attempts > 3) {
              _snack('This link could not be opened or downloaded.');
              return NavigationDecision.prevent;
            }
            if (attempts > 1 || uploadKindFor(uri.path) != null) {
              unawaited(_saveDownload(uri));
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );
    final incoming = widget.sharedLink.trim();
    if (incoming.isEmpty) {
      _browser.loadHtmlString(_startPage);
    } else {
      unawaited(_go(incoming));
    }
  }

  static const _startPage = '''
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <style>
    :root {
      --bg: #09090b;
      --card: #18181b;
      --border: #27272a;
      --text: #f4f4f5;
      --sub: #a1a1aa;
      --accent: #8b5cf6;
    }
    @media (prefers-color-scheme: light) {
      :root {
        --bg: #f8fafc;
        --card: #ffffff;
        --border: #e2e8f0;
        --text: #0f172a;
        --sub: #64748b;
        --accent: #7c3aed;
      }
    }
    body {
      margin: 0; min-height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: var(--bg); color: var(--text);
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      padding: 24px; box-sizing: border-box;
    }
    .brand {
      display: flex; align-items: center; gap: 12px; margin-bottom: 20px;
    }
    .logo-badge {
      width: 46px; height: 46px; border-radius: 12px;
      background: linear-gradient(135deg, #8b5cf6, #6366f1);
      display: grid; place-items: center; color: white; font-size: 22px; font-weight: 700;
    }
    h1 { margin: 0; font-size: 22px; font-weight: 700; letter-spacing: -0.5px; }
    p { margin: 6px 0 24px; color: var(--sub); font-size: 13px; text-align: center; max-width: 320px; line-height: 1.4; }
    .grid {
      display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; width: 100%; max-width: 360px;
    }
    .card {
      background: var(--card); border: 1px solid var(--border); border-radius: 14px;
      padding: 12px; text-decoration: none; color: inherit; display: flex; align-items: center; gap: 10px;
      transition: transform 0.1s, border-color 0.1s;
    }
    .card:active { transform: scale(0.97); }
    .icon {
      width: 36px; height: 36px; border-radius: 10px; display: grid; place-items: center; font-size: 16px;
    }
    .c-yt { background: #fee2e2; color: #dc2626; }
    .c-mp3 { background: #ede9fe; color: #7c3aed; }
    .c-ggl { background: #e0f2fe; color: #0284c7; }
    .c-sc { background: #ffedd5; color: #ea580c; }
    .title { font-weight: 600; font-size: 13px; line-height: 1.2; }
    .desc { font-size: 11px; color: var(--sub); margin-top: 2px; }
  </style>
</head>
<body>
  <div class="brand">
    <div class="logo-badge">⚡</div>
    <div>
      <h1>NexBrowser Pro</h1>
    </div>
  </div>
  <p>Search freely, choose any website to click, or convert online media into nexMusic.</p>
  <div class="grid">
    <a class="card" href="https://www.google.com">
      <div class="icon c-ggl">🔍</div>
      <div><div class="title">Google</div><div class="desc">Web search</div></div>
    </a>
    <a class="card" href="https://m.youtube.com">
      <div class="icon c-yt">▶</div>
      <div><div class="title">YouTube</div><div class="desc">Music & videos</div></div>
    </a>
    <a class="card" href="https://www.google.com/search?q=youtube+to+mp3+converter">
      <div class="icon c-mp3">🎵</div>
      <div><div class="title">MP3 Converters</div><div class="desc">Choose site</div></div>
    </a>
    <a class="card" href="https://m.soundcloud.com">
      <div class="icon c-sc">☁</div>
      <div><div class="title">SoundCloud</div><div class="desc">Audio streams</div></div>
    </a>
  </div>
</body>
</html>
''';

  Uri _destination(String input) {
    final text = input.trim();
    final parsed = Uri.tryParse(text);
    if (parsed != null &&
        (parsed.scheme == 'https' || parsed.scheme == 'http')) {
      return parsed;
    }
    return Uri.https('www.google.com', '/search', {'q': text});
  }

  Future<void> _go(String input) async {
    if (input.trim().isEmpty) return;
    final destination = _destination(input);
    _addressController.text = destination.toString();
    if (uploadKindFor(destination.path) != null) {
      await _saveDownload(destination);
      return;
    }
    await _browser.loadRequest(destination);
  }

  void _goHome() {
    _addressController.clear();
    _currentPage = '';
    _browser.loadHtmlString(_startPage);
  }

  Future<void> _toggleDesktopMode(bool enable) async {
    setState(() => _isDesktopMode = enable);
    const desktopUa =
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
    const mobileUa =
        'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';
    await _browser.setUserAgent(enable ? desktopUa : mobileUa);
    await _browser.reload();
  }

  void _changeZoom(double delta) {
    final next = (_zoomLevel + delta).clamp(0.5, 2.5);
    setState(() => _zoomLevel = double.parse(next.toStringAsFixed(2)));
    _browser.runJavaScript('document.body.style.zoom = "$_zoomLevel";');
  }

  void _resetZoom() {
    setState(() => _zoomLevel = 1.0);
    _browser.runJavaScript('document.body.style.zoom = "1.0";');
  }

  Future<void> _clearBrowsingData() async {
    await _browser.clearCache();
    await WebViewCookieManager().clearCookies();
    _snack('Browser cache & cookies cleared');
  }

  Future<void> _captureMediaFromPage() async {
    final current = _currentPage;
    if (current == null || current.isEmpty) return;
    final uri = Uri.tryParse(current);
    if (uri == null) return;
    _snack('Scanning page for downloadable audio/video…');

    const extractScript = r'''
(function(){
  var urls = [];
  var media = document.querySelectorAll('audio, video, source');
  for (var i = 0; i < media.length; i++) {
    var src = media[i].src || media[i].getAttribute('src') || '';
    if (src && /^https?:/.test(src)) urls.push(src);
  }
  var links = document.querySelectorAll('a[href]');
  for (var j = 0; j < links.length; j++) {
    var href = links[j].href || '';
    if (/\.(mp3|m4a|aac|flac|wav|mp4|webm|mkv|ogg)(\?|$)/i.test(href)) {
      urls.push(href);
    }
  }
  return JSON.stringify(urls);
})()
''';
    try {
      final res = _decodeJs(
        await _browser.runJavaScriptReturningResult(extractScript),
      );
      if (res is List && res.isNotEmpty) {
        final mediaUrl = Uri.tryParse(res.first.toString());
        if (mediaUrl != null) {
          unawaited(_saveDownload(mediaUrl));
          return;
        }
      }
    } catch (_) {}

    unawaited(_saveDownload(uri));
  }

  void _snack(String message) {
    if (!mounted) return;
    if (widget.job != null) {
      debugPrint('nexBrowser: $message');
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _readUserAgent() async {
    try {
      final value = await _browser.runJavaScriptReturningResult(
        'navigator.userAgent',
      );
      return '$value'.replaceAll(RegExp(r'^"|"$'), '');
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDownload(
    Uri url, {
    bool keepConverterOnWebPage = false,
  }) async {
    if (!mounted) return;
    if (_downloading) {
      _snack('A download is already running.');
      return;
    }
    setState(() {
      _downloading = true;
      _fileTaken = true;
      _progress = 1;
    });
    _snack('Downloading for nexMusic…');
    _userAgent ??= await _readUserAgent();
    final result = await downloadBrowserMedia(
      url,
      referer: _currentPage,
      userAgent: _userAgent,
      onProgress: (fraction) {
        final percent = (fraction * 100).round().clamp(1, 99);
        if (mounted && percent != _progress) {
          setState(() => _progress = percent);
        }
      },
    );
    if (!mounted) {
      final orphan = result.path;
      if (orphan != null) discardTemporaryCopy(orphan);
      return;
    }
    setState(() {
      _downloading = false;
      _progress = 0;
    });
    if (result.isWebPage) {
      if (keepConverterOnWebPage) {
        _retryAfterAdvert();
        return;
      }
      await _browser.loadRequest(url);
      return;
    }
    final filePath = result.path;
    if (filePath == null) {
      final message = result.error ?? 'Download failed.';
      widget.job?.fail(message);
      _snack(message);
      return;
    }
    _downloadTapAt = null;
    final job = widget.job;
    if (job != null) {
      job.complete(filePath);
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => UploadScreen(initialPaths: [filePath])),
    );
    if (!_music.uploads.any(
      (item) => item.path == filePath || item.original?.path == filePath,
    )) {
      discardTemporaryCopy(filePath);
    }
  }

  void _retryAfterAdvert() {
    final asked = _downloadTapAt;
    final stillWaiting =
        asked != null &&
        DateTime.now().difference(asked) < const Duration(seconds: 20);
    if (stillWaiting && _adRetries < 2) {
      _adRetries += 1;
      _snack('Advert blocked; asking for the file again.');
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (mounted) unawaited(_tapPageAction(_downloadWords));
      });
      return;
    }
    widget.job?.fail('The converter only offered adverts, not the file.');
    _snack('That link was not an audio or video download.');
  }

  static const _topResultScript = r'''
(function(){
  var heads=document.querySelectorAll('[role="heading"], h3');
  for(var i=0;i<heads.length;i++){
    var head=heads[i];
    if(head.getBoundingClientRect().height<=0) continue;
    var link=head.closest('a');
    if(!link) continue;
    var href=link.getAttribute('href')||'';
    var organic=/^\/(goto|url)\?/.test(href);
    if(!organic&&/^https?:/.test(href)){
      try{
        var host=new URL(href).hostname;
        organic=!/(^|\.)(google|googleadservices|doubleclick)\./.test(host);
      }catch(e){}
    }
    if(!organic) continue;
    link.click();
    return 'ok';
  }
  return 'none';
})()
''';

  static const _actionScript = r'''
(function(){
  var els=document.querySelectorAll('button,input[type=submit],input[type=button],a,[role=button]');
  var convert=false,download=false,ready=false,convertOff=false;
  for(var i=0;i<els.length;i++){
    var el=els[i];
    var label=((el.innerText||el.value||el.getAttribute('aria-label')||'')+'').toLowerCase();
    if(!label) continue;
    var off=el.disabled===true||el.getAttribute('aria-disabled')==='true';
    if(!off&&window.getComputedStyle){
      var style=window.getComputedStyle(el);
      if(style&&(style.pointerEvents==='none'||parseFloat(style.opacity||'1')<0.5)) off=true;
    }
    if(label.indexOf('convert')>-1&&label.indexOf('convert more')<0){
      convert=true;
      if(off) convertOff=true;
    }
    if(label.indexOf('download')>-1||label.indexOf('save mp3')>-1){
      download=true;
      if(!off) ready=true;
    }
  }
  var busy=(download&&!ready)||(convert&&convertOff&&!ready);
  return JSON.stringify({convert:convert,download:download,ready:ready,busy:busy});
})()
''';

  static const _pasteScript = r'''
(function(link){
  var boxes=[];
  function collect(root){
    if(!root||!root.querySelectorAll) return;
    var fields=root.querySelectorAll('input,textarea');
    for(var i=0;i<fields.length;i++){
      var type=(fields[i].getAttribute('type')||'text').toLowerCase();
      if(type==='hidden'||type==='checkbox'||type==='radio') continue;
      if(type==='submit'||type==='button'||type==='file') continue;
      boxes.push(fields[i]);
    }
    var all=root.querySelectorAll('*');
    for(var j=0;j<all.length;j++) if(all[j].shadowRoot) collect(all[j].shadowRoot);
  }
  collect(document);
  var best=null,bestScore=-1;
  for(var k=0;k<boxes.length;k++){
    var box=boxes[k];
    var rect=box.getBoundingClientRect();
    if(rect.width<60||rect.height<8) continue;
    var hint=((box.getAttribute('placeholder')||'')+' '+(box.getAttribute('name')||'')+' '+(box.id||'')+' '+(box.className||'')).toLowerCase();
    var score=rect.width;
    if(hint.indexOf('url')>-1||hint.indexOf('link')>-1) score+=10000;
    if(hint.indexOf('youtube')>-1||hint.indexOf('search')>-1) score+=10000;
    if(score>bestScore){bestScore=score;best=box;}
  }
  if(!best) return 'none';
  best.focus();
  var native=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(best),'value');
  if(native&&native.set) native.set.call(best,link); else best.value=link;
  best.dispatchEvent(new Event('input',{bubbles:true}));
  best.dispatchEvent(new Event('change',{bubbles:true}));
  return 'ok';
})(__LINK__)
''';

  static const _clickScript = r'''
(function(words){
  var els=document.querySelectorAll('button,input[type=submit],input[type=button],a,[role=button]');
  var here=location.hostname.replace(/^www\./,'');
  var best=null,bestScore=0;
  function hit(label,word){
    if(word.length<=3) return new RegExp('(^|[^a-z])'+word+'([^a-z]|$)').test(label);
    return label.indexOf(word)>-1;
  }
  for(var i=0;i<els.length;i++){
    var el=els[i];
    var label=((el.innerText||el.value||el.getAttribute('aria-label')||'')+'').trim().toLowerCase();
    if(!label) continue;
    if(el.disabled===true||el.getAttribute('aria-disabled')==='true') continue;
    var rect=el.getBoundingClientRect();
    if(rect.width<20||rect.height<10) continue;
    var rank=-1;
    for(var w=0;w<words.length;w++){ if(hit(label,words[w])){rank=w;break;} }
    if(rank<0) continue;
    var word=words[rank];
    var score=100+(words.length-rank)*200;
    if(label===word) score+=1000; else if(label.indexOf(word)===0) score+=500;
    if(label.length>28) score-=400;
    var tag=el.tagName.toLowerCase();
    if(tag==='button'||tag==='input') score+=500;
    else if(el.getAttribute('role')==='button') score+=300;
    if(tag==='a'){
      if(el.getAttribute('target')==='_blank') score-=300;
      var rel=(el.getAttribute('rel')||'').toLowerCase();
      if(rel.indexOf('sponsored')>-1||rel.indexOf('nofollow')>-1) score-=500;
      try{
        var host=new URL(el.getAttribute('href')||'',location.href).hostname.replace(/^www\./,'');
        if(host&&host!==here) score-=2000;
      }catch(e){}
    }
    if(score>bestScore){bestScore=score;best=el;}
  }
  if(!best) return 'none';
  best.click();
  return 'ok';
})(__WORDS__)
''';

  Object? _decodeJs(Object? value) {
    var decoded = value;
    for (var round = 0; round < 2; round++) {
      if (decoded is! String) break;
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return decoded;
      }
    }
    return decoded;
  }

  bool _isSearchPage(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    if (host.contains('google.') && path.startsWith('/search')) return true;
    if (host.contains('bing.') && path.startsWith('/search')) return true;
    return host.contains('duckduckgo.');
  }

  Future<void> _onPageFinished(String url) async {
    if (!mounted || url.startsWith('data:') || url.startsWith('about:')) return;
    final run = _pageRun;
    final canBack = await _browser.canGoBack();
    final canFwd = await _browser.canGoForward();

    if (mounted) {
      setState(() {
        _loading = false;
        _canGoBack = canBack;
        _canGoForward = canFwd;
      });
    }

    if (_isSearchPage(url)) {
      // Only auto-open if explicitly enabled by user or if in background job:
      if (_autoOpenTopResult || widget.job != null) {
        unawaited(_openTopResult());
      }
      return;
    }
    await _detectPageAction(run);
  }

  Future<void> _openTopResult() async {
    if (!_autoOpenTopResult && widget.job == null) return;
    if (_topResultOpened || _findingTopResult || widget.pasteLink.isEmpty) {
      return;
    }
    _findingTopResult = true;
    try {
      for (var attempt = 0; attempt < 10; attempt++) {
        if (!mounted || !_isSearchPage(_currentPage ?? '')) return;
        try {
          final decoded = _decodeJs(
            await _browser.runJavaScriptReturningResult(_topResultScript),
          );
          if (decoded == 'ok') {
            _topResultOpened = true;
            return;
          }
        } catch (error) {
          debugPrint('nexBrowser: top result failed: $error');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      widget.job?.fail('No converter site was found for this link.');
      _snack('No site found on this search; pick one yourself.');
    } finally {
      _findingTopResult = false;
    }
  }

  Future<void> _detectPageAction(int run) async {
    bool convert = false, ready = false, busy = false;
    try {
      final decoded = _decodeJs(
        await _browser.runJavaScriptReturningResult(_actionScript),
      );
      if (decoded is Map) {
        convert = decoded['convert'] == true;
        ready = decoded['ready'] == true;
        busy = decoded['busy'] == true;
      }
    } catch (error) {
      debugPrint('nexBrowser: action probe failed: $error');
    }
    if (!mounted || run != _pageRun || _loading) return;
    var phase = _phase;
    var idle = _idleReads;
    if (phase == _BrowserStep.converting) {
      if (ready) {
        phase = _BrowserStep.download;
        idle = 0;
      } else if (busy) {
        idle = 0;
      } else {
        idle += 1;
        if (idle >= 12) {
          phase = _BrowserStep.convert;
          idle = 0;
        }
      }
    }
    if (_siteOpen &&
        _hasConvert == convert &&
        _ready == ready &&
        _busy == busy &&
        _phase == phase &&
        _idleReads == idle) {
      _autoAdvance();
      _startActionWatch(run);
      return;
    }
    setState(() {
      _siteOpen = true;
      _hasConvert = convert;
      _ready = ready;
      _busy = busy;
      _phase = phase;
      _idleReads = idle;
    });
    _autoAdvance();
    _startActionWatch(run);
  }

  void _autoAdvance() {
    if (!mounted || widget.pasteLink.isEmpty) return;
    if (!_autoOpenTopResult && widget.job == null) return;
    if (!_siteOpen || _loading || _working || _downloading || _fileTaken) {
      return;
    }
    final step = _step;
    final limit = switch (step) {
      _BrowserStep.paste => 6,
      _BrowserStep.convert => 3,
      _BrowserStep.download => 2,
      _ => 0,
    };
    final tries = _autoTries[step] ?? 0;
    final gap = step == _BrowserStep.download
        ? const Duration(seconds: 4)
        : const Duration(milliseconds: 1200);
    final last = _lastAutoAt;
    final waited = last == null || DateTime.now().difference(last) >= gap;
    if (tries >= limit) {
      if (limit > 0 && waited) widget.job?.fail(_stepFailure(step));
      return;
    }
    if (!waited) return;
    _autoTries[step] = tries + 1;
    _lastAutoAt = DateTime.now();
    unawaited(_runStep(quiet: tries + 1 < limit));
  }

  void _startActionWatch(int run) {
    if (_actionTimer?.isActive ?? false) return;
    _actionTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) {
      if (!mounted || !_siteOpen || run != _pageRun) {
        timer.cancel();
        return;
      }
      unawaited(_detectPageAction(run));
    });
  }

  Future<void> _pasteSharedLink({bool quiet = false}) async {
    var link = widget.pasteLink.trim();
    if (link.isEmpty) {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      link = clipboard?.text?.trim() ?? '';
    }
    if (link.isEmpty) {
      _snack('There is no link to paste.');
      return;
    }
    try {
      final decoded = _decodeJs(
        await _browser.runJavaScriptReturningResult(
          _pasteScript.replaceFirst('__LINK__', jsonEncode(link)),
        ),
      );
      if (decoded == 'ok' && mounted) {
        setState(() => _phase = _BrowserStep.convert);
      }
      if (decoded == 'ok') {
        _snack('Link pasted.');
      } else if (!quiet) {
        _snack('No box found on this page; paste it by hand.');
      }
    } catch (_) {
      if (!quiet) _snack('This page would not take the link.');
    }
  }

  static const _convertWords = [
    'convert',
    'start',
    'submit',
    'continue',
    'proceed',
    'done',
    'go',
    'ok',
  ];

  static const _downloadWords = ['download', 'save', 'get link', 'direct'];

  Future<void> _tapPageAction(List<String> words, {bool quiet = false}) async {
    setState(() => _working = true);
    try {
      final decoded = _decodeJs(
        await _browser.runJavaScriptReturningResult(
          _clickScript.replaceFirst('__WORDS__', jsonEncode(words)),
        ),
      );
      if (decoded != 'ok' && !quiet) {
        _snack('No ${words.first} button found; use the site\'s own button.');
      }
    } catch (_) {
      if (!quiet) _snack('This page would not take the tap.');
    }
    if (mounted) setState(() => _working = false);
    await _detectPageAction(_pageRun);
  }

  _BrowserStep get _step {
    if (_downloading) return _BrowserStep.downloading;
    return _phase;
  }

  Future<void> _runStep({bool quiet = false}) async {
    switch (_step) {
      case _BrowserStep.paste:
        await _pasteSharedLink(quiet: quiet);
      case _BrowserStep.convert:
        setState(() {
          _phase = _BrowserStep.converting;
          _idleReads = 0;
        });
        await _tapPageAction(_convertWords, quiet: quiet);
      case _BrowserStep.download:
        _downloadTapAt = DateTime.now();
        setState(() => _phase = _BrowserStep.downloading);
        await _tapPageAction(_downloadWords, quiet: quiet);
        if (mounted && !_downloading) {
          setState(() => _phase = _BrowserStep.download);
        }
      case _BrowserStep.opening:
      case _BrowserStep.converting:
      case _BrowserStep.downloading:
        break;
    }
  }

  Widget _actionsBar() {
    final step = _step;
    final waiting =
        step == _BrowserStep.opening ||
        step == _BrowserStep.converting ||
        step == _BrowserStep.downloading;
    final label = switch (step) {
      _BrowserStep.opening => 'Opening…',
      _BrowserStep.paste => 'Paste',
      _BrowserStep.convert => 'Convert',
      _BrowserStep.converting => 'Converting…',
      _BrowserStep.download => 'Download',
      _BrowserStep.downloading => 'Downloading…',
    };
    final icon = switch (step) {
      _BrowserStep.paste => Icons.content_paste_rounded,
      _BrowserStep.convert => Icons.autorenew_rounded,
      _BrowserStep.download => Icons.download_rounded,
      _ => Icons.hourglass_top_rounded,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: waiting || _working ? null : _runStep,
              icon: waiting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(icon, size: 18),
              label: Text(label),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Hide assistant bar',
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => setState(() => _showSmartBar = false),
          ),
        ],
      ),
    );
  }

  void _saveFirstPill() =>
      _music.setBrowserPillText(1, _firstPillController.text);
  void _saveSecondPill() =>
      _music.setBrowserPillText(2, _secondPillController.text);

  void _runPill(BuildContext sheetContext, TextEditingController controller) {
    final value = controller.text.trim();
    if (value.isEmpty) return;
    Navigator.pop(sheetContext);
    _go(value);
  }

  void _showQuickPanel() {
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Shortcuts & Bookmarks',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                'Quick links to common music and converter portals.',
                style: TextStyle(color: _muted(sheetContext), fontSize: 13),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.search_rounded, size: 16),
                    label: const Text('Google'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _go('https://www.google.com');
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.play_arrow_rounded, size: 16),
                    label: const Text('YouTube'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _go('https://m.youtube.com');
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.audiotrack_rounded, size: 16),
                    label: const Text('MP3 Converters'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _go(
                        'https://www.google.com/search?q=youtube+to+mp3+converter',
                      );
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.cloud_queue_rounded, size: 16),
                    label: const Text('SoundCloud'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _go('https://m.soundcloud.com');
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Custom Shortcuts',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              for (final controller in [
                _firstPillController,
                _secondPillController,
              ]) ...[
                TextField(
                  controller: controller,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _runPill(sheetContext, controller),
                  decoration: InputDecoration(
                    hintText: 'Search or link',
                    suffixIcon: IconButton(
                      tooltip: 'Run',
                      onPressed: () => _runPill(sheetContext, controller),
                      icon: const Icon(Icons.arrow_forward_rounded),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showAdvancedControls() {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final currentHost = Uri.tryParse(_currentPage ?? '')?.host ?? '';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: ListView(
              shrinkWrap: true,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: NexMusic.violet.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.tune_rounded,
                        color: NexMusic.violet,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Browser Control Center',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            currentHost.isNotEmpty
                                ? currentHost
                                : 'Free Browsing Mode',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(),

                // CONTROL 1: Auto-select 1st link toggle
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.touch_app_rounded),
                  title: const Text('Auto-open first search link'),
                  subtitle: Text(
                    _autoOpenTopResult
                        ? 'Browser will auto-click the 1st search result'
                        : 'Manual: You choose which website to click',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: _autoOpenTopResult,
                  onChanged: (val) {
                    setState(() => _autoOpenTopResult = val);
                    setModalState(() {});
                  },
                ),

                // CONTROL 2: Free browsing / Cross-domain toggle
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.open_in_new_rounded),
                  title: const Text('Free Browsing Mode'),
                  subtitle: Text(
                    _allowCrossDomain
                        ? 'Enabled: Navigate freely to any site or link'
                        : 'Locked: Restrict navigation to converter host',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: _allowCrossDomain,
                  onChanged: (val) {
                    setState(() => _allowCrossDomain = val);
                    setModalState(() {});
                  },
                ),

                // CONTROL 3: Ad Blocker
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.shield_outlined),
                  title: const Text('Block Popups & Redirect Ads'),
                  subtitle: const Text(
                    'Blocks aggressive ad networks & unwanted popunders',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _blockAds,
                  onChanged: (val) {
                    setState(() => _blockAds = val);
                    setModalState(() {});
                  },
                ),

                // CONTROL 4: Desktop Site Mode
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.desktop_windows_rounded),
                  title: const Text('Desktop site'),
                  subtitle: const Text(
                    'Request desktop view of web pages',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _isDesktopMode,
                  onChanged: (val) {
                    Navigator.pop(sheetContext);
                    _toggleDesktopMode(val);
                  },
                ),

                // CONTROL 5: Smart Converter Bar
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.download_rounded),
                  title: const Text('Show Converter Assistant Bar'),
                  subtitle: const Text(
                    'Floating Paste / Convert / Download helper at bottom',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _showSmartBar,
                  onChanged: (val) {
                    setState(() => _showSmartBar = val);
                    setModalState(() {});
                  },
                ),

                const Divider(),

                // Zoom controls
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.zoom_in_rounded),
                          SizedBox(width: 14),
                          Text(
                            'Page Zoom',
                            style: TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          IconButton.filledTonal(
                            icon: const Icon(Icons.remove_rounded, size: 18),
                            onPressed: () {
                              _changeZoom(-0.1);
                              setModalState(() {});
                            },
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Text(
                              '${(_zoomLevel * 100).round()}%',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton.filledTonal(
                            icon: const Icon(Icons.add_rounded, size: 18),
                            onPressed: () {
                              _changeZoom(0.1);
                              setModalState(() {});
                            },
                          ),
                          if (_zoomLevel != 1.0)
                            TextButton(
                              onPressed: () {
                                _resetZoom();
                                setModalState(() {});
                              },
                              child: const Text(
                                'Reset',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                const Divider(),

                // Direct Action Buttons
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.file_download_outlined,
                    color: NexMusic.violet,
                  ),
                  title: const Text('Capture Media from this page'),
                  subtitle: const Text(
                    'Detect audio/video stream and save to nexMusic',
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _captureMediaFromPage();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('Copy Current URL'),
                  subtitle: Text(
                    _currentPage ?? 'None',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    final url = _currentPage;
                    if (url != null && url.isNotEmpty) {
                      Clipboard.setData(ClipboardData(text: url));
                      _snack('URL copied to clipboard');
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cleaning_services_rounded),
                  title: const Text('Clear Cache & Cookies'),
                  subtitle: const Text('Free up memory and reset site cookies'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _clearBrowsingData();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _actionTimer?.cancel();
    _addressController.dispose();
    _firstPillController.removeListener(_saveFirstPill);
    _secondPillController.removeListener(_saveSecondPill);
    _firstPillController.dispose();
    _secondPillController.dispose();
    super.dispose();
  }

  String _jobStatus() {
    if (!_siteOpen || _loading) {
      return _topResultOpened
          ? 'Opening the converter…'
          : 'Finding a converter…';
    }
    return switch (_step) {
      _BrowserStep.opening => 'Opening the converter…',
      _BrowserStep.paste => 'Pasting the link…',
      _BrowserStep.convert => 'Starting the conversion…',
      _BrowserStep.converting => 'Converting…',
      _BrowserStep.download => 'Getting the file…',
      _BrowserStep.downloading =>
        _progress > 1 ? 'Downloading $_progress%' : 'Downloading…',
    };
  }

  String _stepFailure(_BrowserStep step) => switch (step) {
    _BrowserStep.paste => 'The converter had no box to paste the link into.',
    _BrowserStep.convert => 'The converter did not start converting.',
    _BrowserStep.download => 'The converter did not hand over the file.',
    _ => 'The converter stopped responding.',
  };

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    if (job != null) {
      final status = _jobStatus();
      final fraction = _step == _BrowserStep.downloading && _progress > 1
          ? _progress / 100
          : null;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => job.report(status, fraction: fraction),
      );
      return WebViewWidget(controller: _browser);
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        automaticallyImplyLeading: false,
        leading: IconButton(
          tooltip: 'Close Browser',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: Container(
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outline.withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Icon(
                  _addressController.text.startsWith('https')
                      ? Icons.lock_rounded
                      : Icons.public_rounded,
                  size: 16,
                  color: _addressController.text.startsWith('https')
                      ? Colors.green
                      : Colors.grey,
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _addressController,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: _go,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search or enter address',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              if (_addressController.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear_rounded, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    _addressController.clear();
                    setState(() {});
                  },
                ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Browser Controls',
            icon: const Icon(Icons.tune_rounded),
            onPressed: _showAdvancedControls,
          ),
        ],
        bottom: _progress > 0 && _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2.5),
                child: LinearProgressIndicator(
                  value: _progress / 100,
                  minHeight: 2.5,
                  color: NexMusic.violet,
                ),
              )
            : null,
      ),
      body: PopScope(
        canPop: !_canGoBack,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (_canGoBack) {
            await _browser.goBack();
          }
        },
        child: WebViewWidget(controller: _browser),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showSmartBar && _siteOpen && !_loading) _actionsBar(),
            Container(
              height: 48,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 18,
                    ),
                    tooltip: 'Back',
                    onPressed: _canGoBack ? () => _browser.goBack() : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_ios_rounded, size: 18),
                    tooltip: 'Forward',
                    onPressed: _canGoForward
                        ? () => _browser.goForward()
                        : null,
                  ),
                  IconButton(
                    icon: Icon(
                      _loading ? Icons.close_rounded : Icons.refresh_rounded,
                      size: 20,
                    ),
                    tooltip: _loading ? 'Stop' : 'Reload',
                    onPressed: () {
                      if (_loading) {
                        _browser.runJavaScript('window.stop();');
                        setState(() => _loading = false);
                      } else {
                        _browser.reload();
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.home_rounded, size: 22),
                    tooltip: 'Home',
                    onPressed: _goHome,
                  ),
                  IconButton(
                    icon: const Icon(Icons.bookmark_border_rounded, size: 20),
                    tooltip: 'Shortcuts',
                    onPressed: _showQuickPanel,
                  ),
                  IconButton(
                    icon: const Icon(Icons.tune_rounded, size: 20),
                    tooltip: 'Controls',
                    onPressed: _showAdvancedControls,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
