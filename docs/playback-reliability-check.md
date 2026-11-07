# Playback reliability checks

Checked on 7 November 2026. Application version: 0.4.15+8038.

## Results

| Check | Result |
| --- | --- |
| Full Flutter unit and widget suite | 220 passed, 0 failed |
| Backend unit suite | 23 passed, 0 failed |
| Firestore rules and community integration suite | 14 passed, 0 failed |
| Real Android playback scenarios | 19 passed, 0 failed |
| Live downloads from JioSaavn, YouTube Music and Cloudinary | All three sources completed in the live transfer test |
| Full Flutter analysis | No issues |
| Normal Android debug APK | Built successfully |

The Android device was emulator-5554, Android 15 / API 35, x86_64. Tests used the actual just_audio Android decoder and the same audio_service configuration as the normal app. The test target does not require sign-in or change saved account preferences.

The measured device results are in [playback-device-results.json](playback-device-results.json). An earlier device run also passed all 17 scenarios before the two actual provider playback checks were added.

## Changes

- Automatic queue advancement tries the remaining queued songs when a source is unavailable, with a limit of one traversal per advance.
- A runtime playback error reloads a freshly resolved source once, preserving its position. A repeated failure tries the next queued song. This is bounded; it does not retry forever.
- Playback futures have error handlers, including the incoming player during a crossfade.
- Pause cancels pending track switches, automatic radio starts and pending recovery. It resets both sides of an active crossfade so a rapid resume cannot select paused incoming audio.
- Crossfade handoff restores the chosen volume and handles completion around the handoff. A failed standby player is released and the outgoing audio remains usable.
- Queue snapshots copy traversal lists so failed switches can restore previous history correctly.
- Android retains its foreground media service during decoder pauses and temporary interruptions. Explicit stop still ends playback. While manually paused, the playback notification can remain until the player is closed.
- The navigation test now expects the previously requested Downloads destination.

Fifteen focused regression tests cover these cases in `test/playback_reliability_test.dart`. The player factory parameter allows crossfade tests to control the incoming decoder without replacing real device verification.

## Device scenarios

- Local generated WAV files advance in order without preloading and deliberately stop at the end of the queue.
- Gapless repeat completes twelve native transitions.
- Crossfade completes eight handoffs and retains the chosen volume.
- Pause followed immediately by resume during a real crossfade continues playback.
- An HTTP 404 song is skipped and the following song starts.
- A deliberately truncated HTTP stream followed by HTTP 403 responses triggers one fresh source resolution and resumes playback.
- Sleep after the current track pauses intentionally.
- Actual JioSaavn and YouTube Music songs play from the start, after seeking to the middle, and through the ending.
- Sequential, gapless and crossfade playback continue after pressing Home and while the screen is locked.
- Notification pause and resume work while locked, with the foreground service retained during pause.
- Stream recovery works while locked.
- Separate 60 second locked runs complete 30 gapless transitions and 39 crossfade transitions. The app process remains the same and its media service stays in the foreground.

No Android fatal crash or unhandled Dart exception was recorded during these checks. Expected player errors were generated deliberately by the HTTP failure tests and were handled.

## Reproduce

```powershell
flutter analyze --no-pub
flutter test --no-pub
npm --prefix test_backend test
flutter test --no-pub tool/transfer_live_test.dart
```

For the rules suite, start a local Firestore emulator on 127.0.0.1:8086 using `firestore.rules`, then run:

```powershell
npm --prefix test_backend run test:rules
```

These rules checks used Firestore emulator 1.19.8 with Java 17. Only local demo projects were used.

For real device playback, run the dedicated target in one terminal and its driver in another. ADB must be installed under `%LOCALAPPDATA%\Android\sdk\platform-tools`; set `PLAYBACK_DEVICE` if the device ID differs.

```powershell
flutter run --no-pub -d emulator-5554 -t tool/playback_device_check.dart
node tool/run_playback_device_check.mjs 60
```

Restart the test target before rerunning its driver. Restore the normal app after the checks:

```powershell
flutter run --no-pub -d emulator-5554 -t lib/main.dart
```

## Limits

This is measured confidence for the tested cases, not a promise of uninterrupted playback on every device or network. Physical phones, manufacturer battery restrictions, prolonged connectivity loss, operating system termination and user force-stop were not verified. An exhausted queue, a sleep timer or an unavailable stream with no playable successor can still stop playback intentionally or necessarily.
