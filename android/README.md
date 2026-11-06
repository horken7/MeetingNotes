# Meeting Notes for Android

Records meetings you attend **in person** with your phone's microphone and makes a transcript and meeting notes
**on the phone**. Nothing is uploaded: the speech recognition ([whisper.cpp](https://github.com/ggml-org/whisper.cpp))
and the notes model ([Gemma 3](https://ai.google.dev/gemma) running in [llama.cpp](https://github.com/ggml-org/llama.cpp))
both run on the phone. The internet is only used once, to download those models.

- Big Start/Stop button, timer and level meter. Keeps recording with the screen off; stop from the notification.
- If a phone call takes the microphone, the recording pauses and says so; if the app is closed or the phone runs out
  of battery, the audio recorded until then is kept and transcribed the next time you open the app.
- Swedish, Danish, English and other languages (automatic detection or chosen in Settings). Notes are written in
  the meeting's language: summary, decisions, action items, open questions and key points.
- Search, rename, delete, regenerate notes, and share or save notes and transcripts (share sheet, Google Drive, Files).

## Install (no app store needed)

You need an Android phone from about 2019 or later (Android 10 or newer). For notes, the phone needs at least
4 GB of memory; 8 GB gives clearly better notes.

1. **On the phone**, open the [latest release](https://github.com/horken7/MeetingNotes/releases/latest) in the browser
   (for example Chrome) and tap **MeetingNotes.apk** to download it.
2. Open the downloaded file (tap the notification, or find it in the **Files** app under Downloads).
3. Android asks whether to allow your browser (or Files) to **install unknown apps**. Tap **Settings**, turn on
   **Allow from this source**, and go back. This only lets that app install APKs; you can turn it off again afterwards.
4. Tap **Install**. If Google Play Protect warns that it doesn't know the app, choose **Install anyway**
   (the app isn't in the Play Store, so Play doesn't know it).
5. Open **Meeting Notes**. On the first screen, tap **Download** to fetch the models once, ideally on Wi-Fi:
   - the speech model, 190 MB, and
   - the notes model: 0.8 GB (Gemma 3 1B) on phones with less than 8 GB of memory, 2.5 GB (Gemma 3 4B) otherwise.

   You can keep using the phone while it downloads. If you skip this, the models are downloaded after your first recording.
6. Tap **Start recording**, allow the microphone (and notifications, so you can see and stop the recording), and put
   the phone on the table between the people talking.

When you tap **Stop**, the app transcribes the meeting and then writes the notes. This takes a while on a phone: as a
rough guide, a few minutes per 10 minutes of meeting, depending on the phone. You can lock the screen meanwhile; a
notification says when the notes are ready.

To update, download and install the new APK the same way; your meetings are kept.

## Settings

- **Language**: Automatic, or the language the meeting is in (more reliable for short meetings).
- **Speech recognition**: Fast (Whisper base, 60 MB), Balanced (Whisper small, 190 MB, default) or Best
  (Whisper large-v3-turbo, 574 MB). Small is the default because base makes many more mistakes in Swedish and Danish,
  and large-v3-turbo is several times slower on a phone and needs over 1 GB of memory.
- **Notes model**: Automatic (by the phone's memory), Gemma 3 1B or Gemma 3 4B.
- **Notes instructions**: the same default as the Mac app, editable.
- **Keep audio recordings**: needed to redo a transcript; about 115 MB per hour.

## Where the meetings are

In the app's private storage, one folder per meeting, laid out like the Mac app's: `meta.json`, `transcript.md`
(`[m:ss] text` lines, without speaker names since one microphone records the whole room), `notes.md` and
`audio.wav` (16 kHz mono). Use **Share files** or **Save to Files or Drive** in a meeting's menu to copy them out.
Uninstalling the app deletes them.

## For developers

- Kotlin and Jetpack Compose; `:app`, plus `:whisper` and `:llama`, which build whisper.cpp v1.9.5 and llama.cpp
  b11800 from source with the NDK (each with its own static, hidden copy of ggml). Only `arm64-v8a` is built, for
  ARMv8.2 with dot product and fp16 (the app checks the processor before loading them).
- minSdk 29 (Android 10), targetSdk 35. Models are downloaded from public Hugging Face repositories that need no
  login: `ggerganov/whisper.cpp`, `ggml-org/whisper-vad`, `ggml-org/gemma-3-1b-it-GGUF`, `ggml-org/gemma-3-4b-it-GGUF`.
  Google's own LiteRT/MediaPipe Gemma files (`litert-community/...`, Kaggle) need an account and accepting the licence
  first, so they're not used. Gemini Nano (ML Kit GenAI) isn't used either: it's only on some recent phones and its
  summarization API doesn't support Swedish or Danish.
- Build with JDK 17 and the Android SDK (NDK 27.1 and CMake 3.22.1 are installed by Gradle if missing):

  ```bash
  cd android
  ./gradlew :app:testDebugUnitTest assembleRelease
  ```

  The APK is `app/build/outputs/apk/release/app-release.apk`. It's signed with the release key when
  `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS` are set, otherwise with the debug key.
- CI (`.github/workflows/android.yml`) runs the unit tests, builds the APK, uploads it as an artifact and, for `v*`
  tags, attaches `MeetingNotes.apk` to the GitHub release. Set the repository secrets `ANDROID_KEYSTORE_BASE64`,
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (and `ANDROID_KEY_PASSWORD` if different) so every release is signed
  with the same key; otherwise each build has a different key and an update has to be installed after uninstalling the old version.
