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
- Search, rename, delete, regenerate notes, and share or save notes and transcripts (share sheet, Google Drive, Files).

## Install (no app store needed)

You need an Android phone from about 2019 or later (Android 10 or newer) with at least 4 GB of memory and about
3.5 GB of free storage while installing (the app is 1.6 GB, because the speech and notes models are inside it).

1. **On the phone**, open the [latest release](https://github.com/horken7/MeetingNotes/releases/latest) in the browser
   (for example Chrome) and tap **MeetingNotes.apk** to download it (1.6 GB, so use Wi-Fi).
2. Open the downloaded file (tap the notification, or find it in the **Files** app under Downloads).
3. Android asks whether to allow your browser (or Files) to **install unknown apps**. Tap **Settings**, turn on
   **Allow from this source**, and go back. This only lets that app install APKs; you can turn it off again afterwards.
4. Tap **Install**. If Google Play Protect warns that it doesn't know the app, choose **Install anyway**
   (the app isn't in the Play Store, so Play doesn't know it).
5. Open **Meeting Notes**, tap **Start recording**, allow the microphone (and notifications, so you can see and stop the recording), and put
   the phone on the table between the people talking.

When you tap **Stop**, the app transcribes the meeting and then writes the notes. This takes a while on a phone: as a
rough guide on a recent phone, a Swedish meeting takes about a quarter of its length to transcribe, and a meeting in
another language about as long as the meeting itself (or a quarter with the faster model, see Settings); the notes take a
few minutes more. You can lock the screen meanwhile; a
notification says when the notes are ready.

To update, download and install the new APK the same way; your meetings are kept. If Android says there isn't enough
storage, free some space first (don't uninstall the old version: that deletes your meetings).

## Settings

- **Language**: Automatic, or the language the meeting is in (more reliable for short meetings).
- **Speech recognition** (built in): [KB-Whisper small](https://huggingface.co/KBLab/kb-whisper-small) from the
  National Library of Sweden for Swedish, which makes far fewer mistakes in Swedish than OpenAI's own models (even
  whisper-large-v3), and Whisper large-v3-turbo for Danish, English and other languages. With Automatic, the language is
  detected first. **Faster** downloads Whisper small (190 MB) for languages other than Swedish: about 4 times quicker,
  with more mistakes.
- **Notes model**: Gemma 3 1B (built in) or Gemma 3 4B (a 2.5 GB download, too big to build in; much better notes on
  phones with 8 GB of memory). Until 4B is downloaded, the built-in model is used.
- **Notes instructions**: the same default as the Mac app, editable.
- **Keep audio recordings**: needed to redo a transcript; about 115 MB per hour.

## Where the meetings are

In the app's private storage, one folder per meeting, laid out like the Mac app's: `meta.json`, `transcript.md`
(`[m:ss] text` lines, without speaker names since one microphone records the whole room), `notes.md` and
`audio.wav` (16 kHz mono). Use **Share files** or **Save to Files or Drive** in a meeting's menu to copy them out.
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
- minSdk 29 (Android 10), targetSdk 35. The models come from public Hugging Face repositories that need no login:
  `KBLab/kb-whisper-small`, `ggerganov/whisper.cpp`, `ggml-org/whisper-vad`, `ggml-org/gemma-3-1b-it-GGUF`,
  `ggml-org/gemma-3-4b-it-GGUF`.
- The built-in models are listed with their size and SHA-256 in [`bundled-models.txt`](bundled-models.txt). Gradle
  downloads them once into `model-cache/` (not in git), checks them, and packs them uncompressed into the APK's
  `assets/models/`. The app reads them in place from the installed APK (whisper.cpp through a reader at the asset's
  offset, llama.cpp from a `FILE*` at that offset), so nothing is copied; only the 1 MB voice detection model is
  extracted, because whisper.cpp opens it by path. Gemma is read into memory instead of memory-mapped when its data
  isn't 32-byte aligned in the APK. Total, 1.6 GB, under GitHub's 2 GB limit for release files; CI fails if it isn't.
  Google's own LiteRT/MediaPipe Gemma files (`litert-community/...`, Kaggle) need an account and accepting the licence
  first, so they're not used. Gemini Nano (ML Kit GenAI) isn't used either: it's only on some recent phones and its
  summarization API doesn't support Swedish or Danish.
- Build with JDK 17 and the Android SDK (NDK 27.1 and CMake 3.22.1 are installed by Gradle if missing):

  ```bash
  cd android
  ./gradlew :app:testDebugUnitTest -PnoBundledModels   # tests don't need the models
  ./gradlew assembleRelease                             # with the models (downloads 1.6 GB the first time)
  ```

  `-PnoBundledModels` builds a small APK without the models, which then downloads them on first use.

  The APK is `app/build/outputs/apk/release/app-release.apk`. It's signed with the release key when
  `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS` are set, otherwise with the debug key.
- CI (`.github/workflows/android.yml`) runs the unit tests, builds the APK, uploads it as an artifact and, for `v*`
  tags, attaches `MeetingNotes.apk` to the GitHub release. Set the repository secrets `ANDROID_KEYSTORE_BASE64`,
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (and `ANDROID_KEY_PASSWORD` if different) so every release is signed
  with the same key; otherwise each build has a different key and an update has to be installed after uninstalling the old version.
