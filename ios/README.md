# Meeting Notes for iPhone

Records in-person meetings with the iPhone microphone and makes the transcript and the notes on the phone,
offline. Nothing leaves the device: speech recognition uses Apple's on-device SpeechAnalyzer, and the notes
are written by Apple Intelligence's on-device model (Foundation Models).

- **Record**: tap Record, lock the screen if you like; recording carries on in the background. A phone call
  pauses it and it resumes afterwards (each part is saved as its own file, so nothing is lost if the app is closed).
- **Transcript**: Swedish, Danish or English, chosen automatically or by you. The first time a language is used,
  iOS downloads its speech model from Apple (only the model is downloaded; your audio stays on the phone).
- **Notes**: summary, decisions, action items (as checkboxes), open questions and key points, in the meeting's
  language. Long meetings are summarized in parts and then combined. Edit the instructions in Settings.
- **Files**: every meeting is a folder in Files > On My iPhone > Meeting Notes, with the same layout as the Mac
  app (`meta.json`, `transcript.md`, `notes.md`, audio). Share or "Save to Files" (e.g. iCloud Drive) from a meeting.

## Requirements

- An iPhone with iOS 26 or later. Notes need an iPhone that supports Apple Intelligence (iPhone 15 Pro or newer)
  with Apple Intelligence turned on in Settings. On other iPhones you still get the transcript.
- A Mac with Xcode 26 (free from the App Store) and its iOS 26 platform (Xcode > Settings > Components).

## Install on your iPhone for free

You don't need a paid Apple Developer account. A free Apple ID works, but iOS lets the app run for **7 days**;
after that, plug in the phone and press Run in Xcode again (your meetings are kept).

1. **Open the project**: double-click `ios/MeetingNotes.xcodeproj`.
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
swift test --package-path ios/MeetingCore
```

```bash
cd ios && xcodebuild test -project MeetingNotes.xcodeproj -scheme MeetingNotes -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`MeetingCore` holds the parts that don't need a phone (storage, transcript format, chunking, prompts, Markdown)
and its unit tests. The app is in `MeetingNotes/`.

Speech recognition and Apple Intelligence don't run in the iOS Simulator. Launch the app with the `-demo`
argument (Xcode: Product > Scheme > Edit Scheme > Run > Arguments) to fill it with two sample meetings.
