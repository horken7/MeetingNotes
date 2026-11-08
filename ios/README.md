# Meeting Notes for iPhone

Records in-person meetings with the iPhone microphone and makes the transcript and the notes on the phone,
offline, on any iPhone with iOS 26. Nothing leaves the device: speech recognition runs
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) with KBLab's Swedish
[KB-Whisper](https://huggingface.co/KBLab/kb-whisper-medium) (OpenAI Whisper for English and Danish), and the notes are
written by Google's Gemma 3 through [llama.cpp](https://github.com/ggml-org/llama.cpp), both on the phone's GPU.
Apple Intelligence can write the notes instead on iPhones that have it.

- **Record**: tap Record, lock the screen if you like; recording carries on in the background. A phone call
  pauses it and it resumes afterwards (each part is saved as its own file, so nothing is lost if the app is closed).
- **Transcript**: Swedish, Danish or English, chosen automatically or in Settings. The app includes about 1 GB of
  models (Whisper small for every language, Silero voice detection, Gemma 3 1B for the notes), so it works offline
  right after install. Better models are optional downloads in Settings (asked about once on first launch):
  KB-Whisper medium (540 MB) or large (1.1 GB) for Swedish, Whisper large-v3-turbo (570 MB) for English and Danish,
  and Gemma 3 4B (2.5 GB) for much better notes on iPhones with 8 GB of memory. Keep the app open while it works:
  iOS only lets apps use the GPU while they're on screen.
- **Audio**: deleted as soon as the transcript is ready, unless you turn on Keep audio recordings in Settings
  (needed to redo a transcript or make it in another language).
- **Notes**: summary, decisions, action items (as checkboxes), open questions and key points, in the meeting's
  language. Long meetings are summarized in parts and then combined. Edit the instructions in Settings.
- **Files**: every meeting is a folder in Files > On My iPhone > Meeting Notes, with the same layout as the Mac
  app (`meta.json`, `transcript.md`, `notes.md`, audio). Share or "Save to Files" (e.g. iCloud Drive) from a meeting.

## Requirements

- An iPhone with iOS 26 or later and about 1.5 GB of free space. Tested on an iPhone 13 Pro Max (6 GB).
- A Mac with Xcode 26 (free from the App Store), its iOS 26 platform (Xcode > Settings > Components) and
  CMake (`brew install cmake`).

## Install on your iPhone for free

You don't need a paid Apple Developer account. A free Apple ID works, but iOS lets the app run for **7 days**;
after that, plug in the phone and press Run in Xcode again (your meetings are kept). The first install copies the
1 GB app over the cable (about a minute); later installs only copy what changed.

1. **Build the speech and notes engines and fetch the built-in models** once (about 5 minutes plus a 1 GB download):
   `bash ios/scripts/build-native.sh` and `bash ios/scripts/fetch-models.sh`.
   **Open the project**: double-click `ios/MeetingNotes.xcodeproj`.
2. **Sign in**: Xcode > Settings > Accounts > **+** > Apple ID, and sign in with your Apple ID.
3. **Pick your team**: click the blue *MeetingNotes* project at the top left, then the *MeetingNotes* target >
   *Signing & Capabilities* > Team: *Your Name (Personal Team)*. If Xcode says the bundle identifier is taken,
   change it to something unique, e.g. `io.github.yourname.meetingnotes`.
4. **Plug in the iPhone** with a cable, unlock it and tap **Trust** on the phone.
5. **Turn on Developer Mode** on the phone: Settings > Privacy & Security > Developer Mode > on, then restart
   the phone and confirm. (The option appears after the phone has been connected to Xcode once.)
6. **Run**: choose your iPhone at the top of the Xcode window and press ▶ (Run).
7. **Trust the developer** the first time: on the phone, Settings > General > VPN & Device Management >
   your Apple ID > Trust.

From the command line, once a team is set up (find the team id in Xcode's Signing settings):

```bash
xcodebuild -project ios/MeetingNotes.xcodeproj -scheme MeetingNotes -destination 'platform=iOS,name=<your iPhone name>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<team id> build
```

## Develop

```bash
bash ios/scripts/build-native.sh
```

```bash
bash ios/scripts/fetch-models.sh
```

```bash
swift test --package-path ios/MeetingCore
```

```bash
cd ios && xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`build-native.sh` builds whisper.cpp and llama.cpp (pinned versions, one shared ggml with Metal) into
`ios/Native/MeetingNative.xcframework`, and `fetch-models.sh` downloads the bundled models into `ios/Models/`
(checked against SHA-256); neither is checked in. Without the models the app still builds (CI does this) and
downloads them when first needed. `MeetingCore` holds the parts that don't need a phone
(storage, transcript format, chunking, prompts, model catalog, Markdown) and its unit tests. The app is in `MeetingNotes/`.

To time the models on a phone, put a meeting folder with an `audio.caf` into the app's Documents and launch the app
with `-benchmark`: it processes the newest untranscribed meeting and writes `timings.json` (speed per audio minute,
peak memory) next to it.

The models are too slow to be useful in the iOS Simulator. Launch the app with the `-demo`
argument (Xcode: Product > Scheme > Edit Scheme > Run > Arguments) to fill it with two sample meetings.
