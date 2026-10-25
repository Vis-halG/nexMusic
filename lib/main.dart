import 'package:audio_service/audio_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'branding_migration.dart';
import 'firebase_options.dart';
import 'music_controller.dart';
import 'music_ui.dart';
import 'phone_services.dart';
import 'personal_music.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (_) => const _NexMusicErrorView();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  if (!kIsWeb) {
    await GoogleSignIn.instance.initialize(
      clientId: defaultTargetPlatform == TargetPlatform.iOS
          ? DefaultFirebaseOptions.ios.iosClientId
          : null,
    );
  }
  await migrateWindowsBrandingSupportFiles();
  final preferences = await SharedPreferences.getInstance();
  final existingUser = FirebaseAuth.instance.currentUser;
  if (existingUser != null) {
    await migrateMusicAccount(preferences, existingUser.uid);
  }
  final player = AudioPlayer();
  NexAudioHandler? audioHandler;
  if (!kIsWeb) {
    try {
      audioHandler = await AudioService.init(
        builder: () => NexAudioHandler(player),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.thenex.nexmusic.playback',
          androidNotificationChannelName: 'Music playback',
          androidNotificationIcon: 'drawable/ic_notification',
          notificationColor: NexMusic.violet,
        ),
      );
    } catch (error) {
      debugPrint('Lock screen controls are unavailable: $error');
    }
  }
  runApp(
    ChangeNotifierProvider(
      create: (_) => MusicController(
        preferences,
        auth: FirebaseAuth.instance,
        firestore: FirebaseFirestore.instance,
        storage: FirebaseStorage.instance,
        player: player,
        audioHandler: audioHandler,
        phone: kIsWeb
            ? null
            : PhoneServices(
                auth: FirebaseAuth.instance,
                firestore: FirebaseFirestore.instance,
                messaging: FirebaseMessaging.instance,
              ),
      ),
      child: const NexMusic(),
    ),
  );
}

class _NexMusicErrorView extends StatelessWidget {
  const _NexMusicErrorView();

  @override
  Widget build(BuildContext context) => const Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: Color(0xFF0A0A0A),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'This screen could not load.\nGo back and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFA1A1AA),
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ),
      ),
    ),
  );
}

class NexMusic extends StatelessWidget {
  const NexMusic({super.key});

  /// The only accent colour. Everything else stays monochrome.
  static const violet = Color(0xFF7C3AED);

  static ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final canvas = dark ? const Color(0xFF0A0A0A) : Colors.white;
    final ink = dark ? const Color(0xFFFAFAFA) : const Color(0xFF0A0A0A);
    final muted = dark ? const Color(0xFFA1A1AA) : const Color(0xFF71717A);
    final fill = dark ? const Color(0xFF18181B) : const Color(0xFFF4F4F5);
    final line = dark ? const Color(0xFF27272A) : const Color(0xFFE4E4E7);
    final radius = BorderRadius.circular(12);
    const font = 'Poppins';
    final scheme = ColorScheme(
      brightness: brightness,
      primary: violet,
      onPrimary: Colors.white,
      secondary: ink,
      onSecondary: canvas,
      error: const Color(0xFFDC2626),
      onError: Colors.white,
      surface: canvas,
      onSurface: ink,
      onSurfaceVariant: muted,
      surfaceContainerLowest: canvas,
      surfaceContainerLow: fill,
      surfaceContainer: fill,
      surfaceContainerHigh: fill,
      surfaceContainerHighest: fill,
      outline: line,
      outlineVariant: line,
      inverseSurface: ink,
      onInverseSurface: canvas,
      surfaceTint: Colors.transparent,
    );
    WidgetStateProperty<Color> selected(Color on, Color off) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? on : off,
        );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      fontFamily: font,
      dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: canvas,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: font,
          color: ink,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fill,
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: radius,
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: radius,
        ),
        disabledBorder: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: radius,
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: violet, width: 1.5),
          borderRadius: radius,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        hintStyle: TextStyle(color: muted, fontFamily: font, fontSize: 14),
        labelStyle: TextStyle(color: muted, fontFamily: font),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: violet,
          foregroundColor: Colors.white,
          disabledBackgroundColor: fill,
          disabledForegroundColor: muted,
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: const TextStyle(
            fontFamily: font,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(64, 52),
          side: BorderSide(color: line),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: const TextStyle(
            fontFamily: font,
            fontWeight: FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ink,
          textStyle: const TextStyle(
            fontFamily: font,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: violet,
        foregroundColor: Colors.white,
        elevation: 2,
        highlightElevation: 4,
        shape: CircleBorder(),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: violet,
        inactiveTrackColor: line,
        thumbColor: violet,
        overlayColor: violet.withValues(alpha: 0.12),
        trackHeight: 3,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: violet,
        linearTrackColor: line,
        circularTrackColor: Colors.transparent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: selected(Colors.white, muted),
        trackColor: selected(violet, fill),
        trackOutlineColor: selected(violet, line),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: selected(violet, Colors.transparent),
        checkColor: const WidgetStatePropertyAll(Colors.white),
        side: BorderSide(color: muted, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ink,
        contentTextStyle: TextStyle(
          fontFamily: font,
          color: canvas,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: line,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: violet,
        selectionHandleColor: violet,
        selectionColor: violet.withValues(alpha: 0.24),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context
        .select<MusicController, ({bool dark, bool signedIn})>(
          (music) => (
            dark: music.darkMode,
            signedIn: music.signedIn || music.guestMode,
          ),
        );
    return MaterialApp(
      title: 'nexMusic',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: appState.dark ? ThemeMode.dark : ThemeMode.light,
      scrollBehavior: const NexMusicScrollBehavior(),
      // Browsers turning shared links into audio run behind every page, and
      // an update download shows its progress under every page.
      builder: (context, child) => SharedAudioHost(
        child: UpdateDownloadHost(child: child ?? const SizedBox.shrink()),
      ),
      home: appState.signedIn ? const MusicShell() : const WelcomeScreen(),
    );
  }
}

/// Keeps touch scrolling fluid while retaining mouse and trackpad dragging on
/// the desktop/web builds.
class NexMusicScrollBehavior extends MaterialScrollBehavior {
  const NexMusicScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}
