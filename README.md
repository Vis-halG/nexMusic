# nexMusic

Flutter app for shared music, online songs and videos.
Signed-in listeners can upload songs and videos into shared categories. Files
are stored on Cloudinary; Firebase handles login and the shared listing.

Version `0.4.4+8027` has four tabs: Home, Stream, Library and Profile. Home
groups songs and videos into recently played/watched, liked, most played and
never played collections. Stream combines JioSaavn and YouTube Music with
Quick Picks, song radio and artist browsing. Available music videos open from
the song player. Library also groups songs by artist. Random Play uses every
source on Home, online songs on Stream, and saved/library songs on Library.

Stream now opens with **For you**, using persisted likes, listening time,
completed plays, recent history and early skips. Several distinct seed artists
drive song radio, with language affinity, recording de-duplication and artist
variety in ranking. Cross-provider radio verifies the seed recording rather
than blindly using the first search hit. Trending remains available separately.
Stream → a song's **⋮ → Upload to Library** prepares its audio, fills in title
and artist, and opens the existing category upload flow. Preparation supports
progress, cancellation, retry, Wi-Fi-only downloads and the 100 MB upload cap.
YouTube container audio extraction requires Android. Original downloads are
reused without being deleted or moved.

Uploads and downloads wait and automatically retry temporary socket/DNS errors
instead of failing the entire queue. Downloads show Wi-Fi waits and explicit
retry controls. Uploaded-file artist tags are read on Android; missing tags can
be set from song options. These supplemental tags stay with the account on this
device and do not require changes to the existing backend rules.

The repository is now [Vis-halG/nexMusic](https://github.com/Vis-halG/nexMusic).
Public app names, desktop windows and release APKs use `nexMusic`. Registered
Android/iOS bundle IDs, signing keys, Firebase project, notification channels,
Cloudinary folders and existing device storage keys retain their original IDs
so this release updates existing installations and keeps their data.

Build 8018 also fixes the previous split-APK version mismatch. Flutter added
ABI offsets to older APKs (the published 4017 arm64 APK reports 6017), while
the updater compared the unadjusted release tag. All APKs now use the exact
pubspec build number, above the previous ABI-specific codes. CI checks the
packaged version and app label before publishing each release.

See [APK analysis and integration notes](docs/apk-analysis.md) for evidence,
provider limitations and live checks.

## Firebase project

- Account: `vishalgupta25989@gmail.com`
- App branding: `nexMusic`
- Project ID: `nexmusic-25989`
- Android: `com.thenex.nex_music`
- iOS: `com.thenex.nexMusic`
- Web app is registered

`lib/firebase_options.dart` and `android/app/google-services.json` were generated
for this project. Do not replace them with files from NexConnect or
TheNexSociety.

## Cloudinary

- Cloud name: `j0fu6gju`
- Unsigned upload preset: `nexmusic_unsigned` (folder `nexmusic`, overwrite off)

Both values live in `lib/music_controller.dart` and can be overridden with
`--dart-define=CLOUDINARY_CLOUD_NAME=…` and
`--dart-define=CLOUDINARY_UPLOAD_PRESET=…`. They are not secrets. Never put the
Cloudinary API key or API secret in the app.

The preset has no format or size restriction yet, so anyone who extracts it from
the APK could upload to the account. The app itself only sends audio or video
under 100 MB. Deleting a song in the app removes it from everyone's list; the
file stays on Cloudinary until it is removed from the Media Library.

Profile → **Advance** opens Cloudinary reporting: audio/media counts in the
`nexmusic` folder, account storage, remaining reported limits, rolling 30-day
bandwidth/credits/transformations, and the hourly Admin API quota. The web
browser remains available inside Advance on Android/iOS. Catalogue counts and
today's personal listening are shown separately from Cloudinary account usage.
Cloudinary's usage endpoint does not expose a live daily song-play allowance;
the screen labels this as unavailable rather than treating 30-day usage as today.
If a credit-based plan has no separate storage limit, the screen estimates the
additional storage budget at 1 GB per unused storage credit and labels the
budget as shared with bandwidth and transformations.

To connect account reporting, deploy the updated `push_worker` and configure
`CLOUDINARY_API_KEY` and `CLOUDINARY_API_SECRET` as Worker secrets. Set its
`CLOUDINARY_CLOUD_NAME` variable to `j0fu6gju` (the default), or the same cloud
name supplied to the app. Retain the existing `SERVICE_ACCOUNT` secret. The
authenticated `GET /cloudinary/status` route only returns reporting fields,
caches results for five minutes, and never sends credentials to the app.
Missing reporting configuration leaves app catalogue counts visible with an
explicit account-usage-unavailable message. No API credentials belong in Dart
defines or the APK.

Advance checks the account report every minute while visible and in the
foreground; automatic checks reuse the Worker report for up to five minutes.
Manual refresh requests a new report at most once per minute and shares
concurrent requests. Report fetch time and cached status are displayed.
**Uploads today** counts current catalogue entries created on the device's
local date. Open web browser from Advance and use **Cloudinary statistics**
in its toolbar to return to usage reporting. Cloudinary account usage is
periodically updated, not an instantaneous play counter. Deploy the updated
Worker to enable manual cache refresh and reporting freshness metadata.

```powershell
cd push_worker
npx wrangler secret put CLOUDINARY_API_KEY
npx wrangler secret put CLOUDINARY_API_SECRET
npx wrangler deploy
```

Reporting semantics follow the [Cloudinary Admin API](https://cloudinary.com/documentation/admin_api#usage)
and its [rolling credit usage documentation](https://cloudinary.com/documentation/developer_onboarding_faq_track_credits).

## Music expansion

Personal playlists, queue editing/restore, repeat modes, sleep timer, lyrics/translation, download manager, discovery controls, device music, listening stats, shared playlists/rooms, Cast/Auto hooks and long-form playback are included. See [feature setup and verified limitations](docs/music-expansion-setup.md) before enabling the cloud features. The new Worker and Firestore rules must be deployed to the existing backend. Song recognition/humming adapters require configured provider credentials.

## Features

- Long press a song or card to select multiple songs. Select all or clear the
  selection, then play/shuffle selected audio, queue songs in order, add them
  to a new or existing playlist, like/unlike, download, remove downloads, or
  share their audio files after downloading missing files (existing device and
  offline files are reused). Android extracts audio from video containers before
  sharing. Preparation shows progress, supports cancellation, and respects
  Wi-Fi-only downloads and the storage limit. Editable playlists support removing
  selected tracks. Back exits selection; switching tabs, filters or accounts
  resets it. Playlist drag handles keep reordering separate from selection.
- Google login through Firebase Authentication, plus guest access to device music and online discovery.
- Shared catalogue: any signed-in user creates categories and uploads files up
  to 100 MB each.
  - Audio: mp3, m4a, aac, wav, flac, ogg, oga, opus, amr, 3ga, mka, aiff and
    aif.
  - Video: mp4, m4v, mov, webm, mkv, 3gp, 3g2, avi, flv, wmv, mpg, mpeg, ts,
    mts, m2ts, ogv and mxf.
  - Phones cannot play AIFF, AVI, FLV, WMV, MPEG, TS, OGV, MXF and 3G2
    reliably, so their saved link asks Cloudinary for an MP3 or MP4 copy. The
    first play of a large converted video can take a while, and conversions
    use the Cloudinary plan's transformation quota.
  - WMA is not accepted because Cloudinary does not take it.
- Multi-select upload: pick many files, choose one category, upload three at a
  time with per-file progress, retry for failures, and skipping of files that
  are already in the catalogue (same title and size). A running batch can be
  paused, resumed or cancelled from the upload screen; a song that was halfway
  starts again from the beginning on resume, because Cloudinary takes each
  file in one request, and a song already sent to Cloudinary is left to finish
  so it is never stranded without its catalogue entry. On Android the chooser
  only keeps a link to each file; a file is copied into the cache just while
  it uploads, so choosing hundreds of songs does not fill the phone.
- A category must be picked before uploading. Anyone signed in can later
  rename any upload, move it to another category, or delete it. Songs show
  their category, never the uploader's name.
- Categories are added, renamed and deleted from the "Edit" button next to the
  category pills on the home, upload and song editor screens. Only a
  category's creator can rename or delete it. Deleting a category that has
  songs asks first, then removes the category and all its songs for everyone
  (the files stay on Cloudinary).
- Liked and recently played songs, stored on the device.
- Music keeps playing in the background, with play/pause/next controls on the
  lock screen and in the notification bar.
- Notifications: uploads and offline downloads show progress, and the other
  phones are notified when someone uploads, edits, moves or deletes a song or
  category (see "Activity notifications"). Profile → Activity notifications
  turns them off on one phone.
- Android home music widget: now playing, previous/play/next and three liked or recent shortcuts.
- Any song or video can be downloaded from its ⋮ menu and then plays from the
  phone without internet (Profile → Downloads). A download is removed when
  its uploader deletes the song.
- Sharing a YouTube link to nexMusic opens the upload screen straight away.
  Out of sight behind the app, the in-app browser searches "youtube to mp3",
  opens the top ordinary result (Google's adverts are skipped) and walks the
  converter through Paste, Convert and Download, while the upload screen shows
  how far it has got. The title and category can be chosen meanwhile, and
  pressing Upload returns to the home screen at once: the hidden browser's
  progress ("Converting…", "Downloading 40%") shows where upload progress
  does, and the song uploads the moment its audio arrives, waiting its turn if
  another batch is still uploading. If the audio cannot be fetched after the
  screen has closed, a message says so. Leaving without pressing Upload stops
  the hidden browser. Each step is tried a few times, and the whole fetch gives up
  after three minutes; the upload screen then offers "Try again", or "Open
  browser" to finish the converter by hand. The hidden browser fills the
  screen underneath the app's pages, because converter pages only lay out
  their buttons at a real size. It presses the site's own buttons, trying
  several labels ("Convert", "Start", "Go", "OK", …). Reading the page only
  ever carries a step from Converting to Download, and a file is fetched once
  per page. Links that would take the page off the converter's own domain are
  blocked, because adverts on these sites wear the same words as the real
  button; if the file has just been asked for, the download is asked for
  again. This only works as well as the site does: some converters answer
  every download press with an advert (ytmp3.cc did when this was written),
  so no file arrives from them. The browser has no back, forward or shortcut
  buttons. Other shared links open the "Save link" screen. nexMusic never
  contacts YouTube itself.
- A song or video downloaded inside the in-app browser is saved to the app
  cache and opens the upload screen with the file ready; a category still has
  to be chosen. Direct file links are captured; downloads a page builds in
  JavaScript (`blob:` links) are not.
- Any audio file can be trimmed before uploading (Android): play it, tap
  "Start here" and "End here" or drag the handles, then "Use this part". MP3
  stays MP3 and AAC/M4A is copied into M4A without re-encoding. Other formats
  the phone can decode (FLAC, WAV, Ogg, Opus, AMR, …) are converted to AAC in
  M4A, or saved as WAV on phones whose AAC encoder refuses to start (the
  Android 15 emulator's does). The original is kept so the trim can be redone
  or undone.
- Private library: saved links, in-app browser and Android share-sheet import.
  Keeping your own files privately (trim or original) and offline download use
  Firebase Storage, which needs the Blaze plan. Streaming links (`.m3u8`,
  `.mpd`, `rtsp://`) cannot be played.

### Keeping Firestore inside the free quota

The song listing is cached on each device (`catalog_cache_v1.json`) and only
documents whose `updatedAt` is newer than the last sync are read, so opening the
app does not re-read the whole catalogue. Songs are soft-deleted
(`deleted: true`) so other phones can sync removals the same way.

## Data model

| Location | Contents | Who can write |
| --- | --- | --- |
| Firestore `categories/{id}` | `name`, `ownerUid`, `createdAt` | any signed-in user creates; creator renames/deletes |
| Firestore `songs/{id}` | `title`, `kind`, `categoryId`, `url`, `publicId`, `sizeBytes`, `durationMs`, `ownerUid`, `ownerName`, `createdAt`, `updatedAt`, `deleted` | any signed-in user creates their own; anyone signed in can change `title`, `categoryId`, `deleted`, `updatedAt` |
| Firestore `pushTokens/{id}` | `uid`, `token`, `updatedAt` | that phone's user; read by the push Worker |
| Cloudinary `nexmusic/…` | public upload files | unsigned preset |
| Firestore `users/{uid}/folders`, `users/{uid}/media` | private library metadata | that user only |
| Storage `users/{uid}/…` | private library files (Blaze only) | that user only |

Songs and categories are readable by every signed-in user.

Publish `firestore.rules` in the Firebase console (Firestore Database → Rules),
or deploy with:

```powershell
firebase deploy --only firestore:rules --project nexmusic-25989 `
  --account vishalgupta25989@gmail.com
```

## Activity notifications

Firebase's free plan cannot run server code, so a free Cloudflare Worker
(`push_worker/worker.js`) sends the notifications:

1. Each signed-in phone saves its Firebase Cloud Messaging token in
   `pushTokens`.
2. After an upload, edit, move or delete, the app posts a title and text to
   the Worker with the user's Firebase ID token.
3. The Worker checks the token and sends the notification to every other
   phone, and forgets tokens of phones that uninstalled the app.

Setup:

1. Firebase console → Project settings → Service accounts → Generate new
   private key. Keep the JSON file private; it never goes into the app.
2. From `push_worker`, run `npx wrangler deploy` to bundle and deploy the Worker
   and its Cloudinary reporting module.
3. Worker → Settings → Variables and Secrets → add a secret named
   `SERVICE_ACCOUNT` whose value is the whole JSON file.
4. Put the Worker URL in `pushWorkerUrl` in `lib/phone_services.dart` (or pass
   `--dart-define=PUSH_WORKER_URL=…`) and rebuild the APK. It is currently
   `https://nexmusic-push.vishalgupta25989.workers.dev`.

A phone is never notified about its own user's actions, so testing delivery
needs two phones signed in with different Google accounts.

## Run on the Android emulator

1. Turn on Windows Developer Mode (`start ms-settings:developers`). Flutter
   needs symlinks to build plugins.
2. Register the debug keystore's SHA-1 and SHA-256 on the Android app in
   Firebase project settings, otherwise Google login fails with
   `[16] Account reauth failed`:

   ```powershell
   keytool -list -v -keystore $env:USERPROFILE\.android\debug.keystore -storepass android
   ```

3. Use a Google Play system image with a Google account added. For an AVD made
   with `avdmanager`, set `hw.keyboard = yes` and `PlayStore.enabled = yes` in
   its `config.ini` so the laptop keyboard works, then cold boot it.

Use `flutter emulators` to find your emulator ID, then replace
`your-emulator-id` below with that ID.

```powershell
flutter emulators --launch your-emulator-id
flutter run -d emulator-5554
```

Other targets: `flutter run -d chrome`.

## Build the APK to share

Test phones are short on storage, so the shared APK is kept as small as
possible:

```powershell
powershell -ExecutionPolicy Bypass -File tool\small_apk\build.ps1
```

It writes `build\nexMusic-arm64.apk`, which installs on arm64 phones only. The
script builds an obfuscated `android-arm64` release and recompresses the APK
with zopfli (Node.js is needed; `@gfx/zopfli` is installed on the first run).
It then runs `zipalign` and signs with the same debug key as the release build,
so the APK installs over earlier test builds. Keep `build\symbols` to decode
crash stack traces from that build.

`android/app/build.gradle.kts` does the rest:

- Native libraries are compressed inside the APK. Android unpacks them on
  install, so the installed app is larger than the APK.
- Plugin libraries for other ABIs, `.proto` sources, Kotlin reflection metadata
  and non-English library translations are left out.
- ExoPlayer's DASH, HLS, RTSP and SmoothStreaming modules are left out, so the
  app refuses `.m3u8`, `.mpd` and `rtsp://` links before playback.

`android/app/src/main/res/raw/keep.xml` keeps resources that libraries look
up by name, so resource shrinking does not remove them. Without it, Google
sign-in on a fresh install fails with "serverClientId must be provided on
Android", because `default_web_client_id` is stripped.

reCAPTCHA cannot be left out, because Firebase Auth loads it when it starts.
The Poppins fonts are subset to Latin characters, so Devanagari text uses the
system font, and the PNGs use 256-colour palettes. Check the APK size again
after adding a package or asset.

## Source layout

```text
lib/main.dart              Firebase bootstrap and the monochrome + violet theme
lib/firebase_options.dart  generated FlutterFire configuration
lib/music_data.dart        category, song, upload and private-library models
lib/music_controller.dart  playback, Auth, catalogue sync, Cloudinary uploads
lib/music_ui.dart          all screens and shared components
lib/app_update.dart        in-app GitHub releases checker, APK downloader & installer
lib/phone_services.dart    lock screen controls, widgets, notifications, push
android/.../MainActivity.kt  trim/extract channel and widget launch actions
android/.../NexPhone.kt    progress and activity notifications, native package version
push_worker/worker.js      Cloudflare Worker that sends activity notifications
tool/small_apk/            builds the small APK to share
.github/workflows/release.yml GitHub Actions pipeline that auto-builds & publishes APK releases
firestore.rules            catalogue and private metadata rules
storage.rules              private library file rules (Blaze only)
```

---

## 🚀 AI & Developer Guide: How to Make Changes & Trigger In-App Update Popup

> **CRITICAL RULE FOR ALL DEVELOPERS & AI ASSISTANTS**:
> Whenever you modify code, add features, or fix bugs in this project, you **MUST** follow this release & versioning procedure so that users receive the **"Update Available" in-app popup** on their devices.

### 1. How the In-App Update System Works
1. When the app starts up, `_checkAutoUpdate()` in `lib/music_ui.dart` queries the GitHub Releases API:
   `https://api.github.com/repos/Vis-halG/nexMusic/releases/latest`
2. It compares the **remote build number** from the GitHub release tag (e.g. `v0.2.9+4015` → build `4015`) against the device's **currently installed build number** (e.g. `4014`).
3. If `remote.build > installed.build`, the **"Update Available" popup** immediately appears on the user's screen.
4. Tapping **"Update Now"** downloads the APK matching the device architecture (`arm64-v8a`, `armeabi-v7a`, or `Universal`) with a real-time progress bar, and then invokes the native Android installer.
5. **Why the popup might NOT show**:
   - If GitHub's latest release build equals the installed build (e.g. `4014 == 4014`), the app is recognized as up-to-date and no popup will trigger.
   - For the popup to trigger, the build number published on GitHub **must be strictly greater** than the build installed on the user's phone.

---

### 2. Mandatory Steps for Every Change / Update

Whenever you or an AI agent make any changes to this repository, perform these steps in order:

#### Step 1: Bump the Version & Build Number
You must increment the **build number** (the integer after the `+`) in two files:

1. **`pubspec.yaml`**:
   ```yaml
   # Increment the build number by +1 (e.g., 4014 -> 4015)
   version: 0.2.9+4015
   ```
2. **`lib/app_update.dart`**:
   ```dart
   // Must match pubspec.yaml version exactly
   const String currentAppVersion = '0.2.9+4015';
   ```

#### Step 2: Validate the Project
Before pushing, ensure the codebase is healthy:
```powershell
flutter analyze lib/
flutter test
```

#### Step 3: Push to GitHub `master` Branch
Commit and push the changes to GitHub:
```powershell
git add .
git commit -m "feat/fix: describe your changes [bump version to 0.2.9+4015]"
git push origin master
```

#### Step 4: Automated GitHub Release (Hands-Off)
Once pushed to `master`, GitHub Actions (`.github/workflows/release.yml`) automatically:
- Reads the new version tag (e.g., `v0.2.9+4015`) from `pubspec.yaml`.
- Builds optimized APKs (`nexMusic-arm64-v8a.apk`, `nexMusic-armeabi-v7a.apk`, `nexMusic-Universal.apk`, `nexMusic.apk`).
- Signs the APKs with the release keystore.
- Publishes a new GitHub Release with the tag `v0.2.9+4015` and marks it as **Latest**.

#### Step 5: Verify on Device
- When users open their installed nexMusic app (which has build `4014`), the app contacts GitHub, sees build `4015`, and shows the **Update Available** popup.
- Users can also go to **Profile → Check for updates** to trigger the check manually.
