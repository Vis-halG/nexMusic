# nexMusic 0.4.0 music expansion

The app keeps the existing Firebase project (`nexmusic-25989`), Android package, Cloudinary uploads and Cloudflare Worker (`nexmusic-push`). Secrets are never bundled in the APK. The build does not publish itself or alter the live backend.

## Built flows

- Library: personal playlists across uploads, private files, device music and provider tracks; rename, emoji covers, reorder, duplicate, bulk download and delete. JSON import/export preserves stable references. CSV import offers recording review for ambiguous search matches.
- Player: editable/restored queue and position, play next, shuffle with traversal history, repeat off/all/one, radio autoplay, sleep timer, preloading/gapless, adjustable crossfade, Android EQ/bass with device-saved preferences, Wi-Fi/mobile/download quality.
- Lyrics: LRCLIB lookup/cache, manual LRC/text import, synced highlighting and tap-to-seek, sing-along view. Android ML Kit identifies the language, downloads translation models on Wi-Fi and translates locally. Translation accuracy and lyric availability vary by source.
- Downloads: persisted queue, pause/resume/cancel/retry, individual and playlist downloads, Wi-Fi-only policy, storage budget, downloaded-only playback, opt-in smart downloads. A partially downloaded file restarts on retry; only completed files enter the offline library.
- Discovery: mood/language filters, hide song/artist, completed/skip-aware ranking with recommendation explanations, artist/album pages, deterministic prompt-to-playlist search and vertical 30-second previews. Previews use the source's preview URL when supplied, otherwise the first 30 seconds of an available stream. Prompt parsing is a rules-based feature, without an LLM dependency.
- Local/long form: guest access, Android MediaStore scan, file import, local artist/album/folder views, HTTPS RSS/Atom podcast import, audiobooks, speed and device-saved resume.
- Activity: meaningful listened time, completed/skipped events and a weekly shareable text recap with top tracks and artists. Account-owned likes, recents, playlists, activity and settings sync after the new rules are deployed; binaries and local file paths stay on the device. Concurrent playlist changes recover a separate copy instead of silently discarding the newer cloud revision.
- Social: private/public playlists, editor/viewer invite links and QR codes, owner-managed roles and invite-link revocation, rooms with requests/votes, host-only controls, optional guest playback following, opt-in shared likes for group mixes. Each device resolves its own stream; playback follows within a few seconds, not sample-accurate synchronization.
- Android integration: home music widget, outbound sharing/deep links with browser fallback, Cast receiver picker/load/play/pause/disconnect, Android Auto browse/play hooks. Video/audio switching transfers position for the same YouTube recording.

## Existing backend deployment

Review and deploy `firestore.rules` to the existing project before using cloud activity, collaborative playlists or rooms:

```powershell
firebase deploy --only firestore:rules --project nexmusic-25989
```

Review and deploy the Worker from `push_worker`. Its existing `SERVICE_ACCOUNT` secret must remain configured. `keep_vars` preserves deployed variables; Worker secrets remain server-side.

```powershell
cd push_worker
npx wrangler deploy
```

New routes are `GET /capabilities`, `GET /share/*`, `GET /.well-known/assetlinks.json`, authenticated `GET /cloudinary/status` and authenticated `POST /recognize`. Cloudinary reporting needs the `CLOUDINARY_API_KEY` and `CLOUDINARY_API_SECRET` Worker secrets; see the README for setup and reporting periods. Existing activity notification POST behavior is retained. Sharing pages escape metadata, contain no third-party scripts and do not expose private file URLs.

For verified Android App Links set `APP_SHA256` to the release signing certificate's SHA-256 fingerprint (comma-separated fingerprints are supported). The custom `nexmusic://share/...` scheme works independently. If `PUSH_WORKER_URL` is overridden, update the Android manifest host and the associated domain too.

## Recognition configuration still required

No song-recognition or humming provider credential was present in the existing project configuration. The UI checks capabilities before recording. The actual microphone, WAV upload and authenticated backend adapters are built; recognition is unavailable until a real provider is configured.

- `AUDD_API_TOKEN`: a Worker secret for AudD song recognition, submitted using its documented multipart API. Configure a paid/trial account separately; the app does not purchase one.
- Humming uses the existing Worker as a gateway. Configure `HUMMING_ENDPOINT` (HTTPS) and the `HUMMING_API_TOKEN` secret for a provider-compatible adapter accepting raw WAV and returning `{title, artist, album}`. AudD song recognition is not presented as humming recognition.
- The Worker requires a valid Firebase ID token and WAV input up to 2 MB, enforces a 20-per-UID daily allowance through Firestore atomic write preconditions and returns bounded metadata. Audio is sent only when the user starts recognition; it is not retained by this code.

## Verification and limits

Run Flutter analysis/tests, Worker tests and the Firestore emulator authorization suite. The new room/playlist rules exercise outsider denial, valid invites, viewer/editor restrictions, ownership, votes and host controls. Invite tokens stay in account-private join records; they are never written into public playlist documents. Revoked links cannot authorize another join.

```powershell
flutter analyze
flutter test
node --test test_backend/worker.test.mjs
cd test_backend
npm ci
cd ..
firebase emulators:exec --only firestore --project demo-nexmusic "node --test test_backend/firestore.test.mjs"
flutter build apk --release --target-platform android-arm64
```

Physical Cast hardware, Android Auto head units, device-specific audio effects, microphone matching with provider credentials, translation model downloads and background crossfade require device/service validation. An APK build or unit test does not establish those hardware results.

Lossless/spatial catalogues, beat-aware AutoMix, reliable loudness normalization, karaoke vocal separation/stems and external Spotify/Apple account imports depend on suitable media, analysis pipelines or supported external account integrations. They are not represented by cosmetic toggles in this release. Playlist import accepts JSON/CSV metadata; it does not log in to competitors' accounts.

Sources used for native adapters: [ML Kit translation](https://developers.google.com/ml-kit/language/translation/android), [language identification](https://developers.google.com/ml-kit/language/identification/android), [Cast integration](https://developers.google.com/cast/docs/android_sender/integrate), [AudD API](https://docs.audd.io/).

For the exact local validation results and APK details, see [release verification](release-verification-0.4.0.md).
