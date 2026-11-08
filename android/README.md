# Meeting Notes for Android

Records meetings you attend **in person** with your phone's microphone and makes a transcript and meeting notes
**on the phone**. Nothing is uploaded: the speech recognition ([whisper.cpp](https://github.com/ggml-org/whisper.cpp))
and the notes model ([Gemma 3](https://ai.google.dev/gemma) running in [llama.cpp](https://github.com/ggml-org/llama.cpp))
both run on the phone, and the models are built into the app, so it works offline from the first meeting.

- Big Start/Stop button, timer and level meter. Keeps recording with the screen off; stop from the notification.
- If a phone call takes the microphone, the recording pauses and says so; if the app is closed or the phone runs out
  of battery, the audio recorded until then is kept and transcribed the next time you open the app.
- Swedish, Danish, English and other languages (automatic detection or chosen in Settings). Notes are written in
  the meeting's language: summary, decisions, action items, open questions and key points.
- Search, rename, delete (it asks first), regenerate notes, and share or save notes and transcripts (share sheet,
  Google Drive, Files).
- On first open it asks which language your meetings are usually in, and offers a better model for it if there is one.

## Install

You need an Android phone from about 2019 or later (Android 10 or newer) with at least 4 GB of memory and about
3 GB of free storage while installing (the app is 1.4 GB, because the speech and notes models are inside it).

From **Google Play** (once it's published), install it like any app; the models come with it.

Without the Play Store:

1. **On the phone**, open the [latest release](https://github.com/horken7/MeetingNotes/releases/latest) in the browser
   (for example Chrome) and tap **MeetingNotes.apk** to download it (1.4 GB, so use Wi-Fi).
2. Open the downloaded file (tap the notification, or find it in the **Files** app under Downloads).
3. Android asks whether to allow your browser (or Files) to **install unknown apps**. Tap **Settings**, turn on
   **Allow from this source**, and go back. This only lets that app install APKs; you can turn it off again afterwards.
4. Tap **Install**. If Google Play Protect warns that it doesn't know the app, choose **Install anyway**
   (the app isn't in the Play Store, so Play doesn't know it).
5. Open **Meeting Notes** and pick the language your meetings are usually in. For Swedish it offers KB-Whisper, a
   175 MB download that makes far fewer mistakes in Swedish; the built-in model also works, offline.
6. Tap **Start recording**, allow the microphone (and notifications, so you can see and stop the recording), and put
   the phone on the table between the people talking.

When you tap **Stop**, the app transcribes the meeting and then writes the notes. This takes a while on a phone: as a
rough guide on a recent phone, the built-in speech model takes about as long as the meeting itself; with KB-Whisper
(Swedish) or the faster model (other languages, see Settings) about a quarter of that. The notes take a few minutes more. You can lock the screen meanwhile; a
notification says when the notes are ready.

To update, download and install the new APK the same way; your meetings are kept. If Android says there isn't enough
storage, free some space first (don't uninstall the old version: that deletes your meetings).

## Settings

- **Language**: Automatic, or the language the meeting is in (more reliable for short meetings).
- **Speech recognition**: Whisper large-v3-turbo is built in and handles every language (and detects it, with
  Automatic). Optional downloads, used automatically once they're on the phone:
  - [KB-Whisper small](https://huggingface.co/KBLab/kb-whisper-small) for Swedish (175 MB), from the National Library of
    Sweden: far fewer mistakes in Swedish than OpenAI's own models, even whisper-large-v3, and about 4 times faster.
  - **Faster** for other languages: Whisper small (190 MB), about 4 times quicker, with more mistakes.
- **Notes model**: Gemma 3 1B (built in) or Gemma 3 4B (a 2.5 GB download, too big to build in; much better notes on
  phones with 8 GB of memory). Until 4B is downloaded, the built-in model is used.
- **Notes instructions**: the same default as the Mac app, editable.
- **Keep audio recordings**: needed to redo a transcript; about 115 MB per hour.

## Where the meetings are

In the app's private storage, one folder per meeting, laid out like the Mac app's: `meta.json`, `transcript.md`
(`[m:ss] text` lines, without speaker names since one microphone records the whole room), `notes.md` and
`audio.wav` (16 kHz mono). Use **Share…** to send the transcript to the Claude app (or another AI app) with a request to write the notes, so they’re written with your own subscription; it can also share the notes. Use **Share files** or **Save to Files or Drive** in a meeting's menu to copy them out.
Uninstalling the app deletes them.

## Licences

Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms.
By using the app you agree not to use Gemma for the restricted uses in Section 3.2 of those terms (the
[Gemma Prohibited Use Policy](https://ai.google.dev/gemma/prohibited_use_policy)) or against the law. Copies of both are
in the app (Settings > Licences) and in [`app/src/main/assets/legal/`](app/src/main/assets/legal/).

KB-Whisper: National Library of Sweden (KBLab), Apache License 2.0. Whisper: OpenAI, MIT License. Silero VAD: MIT License.
whisper.cpp and llama.cpp: the ggml authors, MIT License.

## For developers

- Kotlin and Jetpack Compose; `:app`, plus `:whisper` and `:llama`, which build whisper.cpp v1.9.5 and llama.cpp
  b11800 from source with the NDK (each with its own static, hidden copy of ggml). Only `arm64-v8a` is built, for
  ARMv8.2 with dot product and fp16 (the app checks the processor before loading them).
- minSdk 29 (Android 10), targetSdk 36. The models come from public Hugging Face repositories that need no login:
  `KBLab/kb-whisper-small`, `ggerganov/whisper.cpp`, `ggml-org/whisper-vad`, `ggml-org/gemma-3-1b-it-GGUF`,
  `ggml-org/gemma-3-4b-it-GGUF`.
- The built-in models (Whisper large-v3-turbo, Silero VAD, Gemma 3 1B: 1.38 GB) are listed with their size and SHA-256
  in [`bundled-models.txt`](bundled-models.txt). Gradle (`:models`) downloads them once into
  `models/src/main/assets/models/` (not in git), checks them, and they go into an **install-time asset pack**
  (Play Asset Delivery), so Play installs them with the app. The universal APK for GitHub releases is made from the
  same bundle with bundletool and has them inside.
- The models are stored uncompressed and read in place from whichever APK holds them (the base APK, or the asset
  pack's split APK on Play installs, found from the asset's file descriptor): whisper.cpp through a reader at the
  asset's offset, llama.cpp from a `FILE*` at that offset. Nothing is copied, except the 1 MB voice detection model,
  which whisper.cpp opens by path. Gemma is read into memory instead of memory-mapped when its data isn't 32-byte
  aligned in the APK.
- Build with JDK 17 and the Android SDK (NDK 27.1 and CMake 3.22.1 are installed by Gradle if missing):

  ```bash
  cd android
  ./gradlew :app:testDebugUnitTest -PnoBundledModels   # tests don't need the models
  ./gradlew :app:universalApk                           # app bundle + universal APK (downloads 1.4 GB the first time)
  ./gradlew :app:checkPlaySplits                        # what Play installs: sizes, limits, models uncompressed
  ```

  The app bundle is `app/build/outputs/bundle/release/app-release.aab` (for Google Play) and the universal APK
  `app/build/outputs/universal/MeetingNotes.apk`. `./gradlew assembleRelease` builds a small APK without the
  models, which then downloads them on first use.

  Both are signed with the release key when
  `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS` are set, otherwise with the debug key.
- CI (`.github/workflows/android.yml`) runs the unit tests, builds the bundle and the universal APK, uploads both as
  an artifact and, for `v*` tags, attaches `MeetingNotes.apk` to the GitHub release (the `.aab` is uploaded to Play by
  hand, see below). Set the repository secrets `ANDROID_KEYSTORE_BASE64`,
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (and `ANDROID_KEY_PASSWORD` if different) so every release is signed
  with the same key; otherwise each build has a different key and an update has to be installed after uninstalling the old version.

## Publishing on Google Play

- Upload `MeetingNotes.aab` (from the CI artifact of a tagged build, signed with the release key as Play's upload key;
  enrol in Play App Signing). Sizes: base module about 34 MB (Play's limit is 200 MB), the `models` install-time asset
  pack 1.38 GB (limit 1.5 GB), so the install is about 1.4 GB, all of it downloaded with the app.
- targetSdk 36 (Android 16), which Play requires for new apps and updates from August 2026; minSdk 29.
- Data safety form: no data collected and no data shared. Audio, transcripts and notes stay on the device; the only
  network use is downloading optional models from Hugging Face, which sends no user data. No account, no ads,
  no analytics.
- A privacy policy URL is still required because the app uses the microphone (`RECORD_AUDIO`); it can say the above.
- Foreground service declarations in the Play Console: `microphone` (recording a meeting the user started, with the
  screen off) and `dataSync` (transcribing and writing notes on the device, and downloading models).
- The Gemma notice and use restrictions are in the app (Settings > Licences) and the store listing should mention
  that notes are written by Gemma 3 under the Gemma Terms of Use.
