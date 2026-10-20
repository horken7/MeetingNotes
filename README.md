# Meeting Notes

A small native macOS app that records your video calls, transcribes them **on your Mac** with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp), and writes structured meeting notes with
[Claude Code](https://claude.com/claude-code) using your Claude subscription.

- **Two tracks, no virtual audio driver.** Your microphone and the call audio are captured separately with
  ScreenCaptureKit, so the transcript knows who said what (your name vs "Others").
- **Detects calls automatically.** When an app such as Google Meet (in any browser), Zoom, Teams or FaceTime starts
  using the microphone, a small prompt offers to take notes, and recording stops a few seconds after you leave the call.
- **Names meetings for you.** In browsers it reads the call tab's title (e.g. "Meet – Weekly sync" becomes "Weekly sync").
- **Private by default.** Audio never leaves your Mac. Only the text transcript is sent to Claude to write the notes.
- **Runs in the background.** It starts at login without a window, lives in the menu bar, and sends a notification
  when the notes for a meeting are ready.
- **Swedish, Danish and English** (or automatic language detection). Notes are written in the meeting's language.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/window-dark.png">
    <img src="docs/images/window.png" alt="Meeting notes in the main window" width="800">
  </picture>
</p>
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/prompt-dark.png">
    <img src="docs/images/prompt.png" alt="The prompt shown when a call is detected" width="380">
  </picture>
</p>

Each meeting gets its own folder with `transcript.md`, `notes.md` (Summary, Decisions, Action items, Open questions,
Key points), the audio as 16 kHz WAV, and `meta.json`.

## Requirements

- macOS 15 (Sequoia) or newer, Apple silicon or Intel
- Xcode command line tools (`xcode-select --install`)
- [Homebrew](https://brew.sh)
- A Claude account for Claude Code (the installer installs Claude Code if it's missing)
- About 2 GB of disk space for the speech model

## Install

```bash
git clone https://github.com/horken7/MeetingNotes.git
cd MeetingNotes
bash install.sh
```

The installer:

1. installs `whisper-cpp` with Homebrew and Claude Code if needed,
2. downloads the Whisper `large-v3-turbo` model (about 1.6 GB) and the Silero voice activity model to `~/.meetnotes/`,
3. compiles the app with `swiftc`, signs it ad hoc and installs it to `/Applications/Meeting Notes.app`,
4. opens it.

On first launch, allow **Microphone** and **Screen & System Audio Recording** (that is how the app hears the other
people on the call; no video is saved). macOS may ask you to quit and reopen the app. The first time a meeting is
detected in a browser, macOS also asks to let Meeting Notes read the browser's tabs, which is used only for the
meeting name.

If Claude Code isn't logged in yet, run `claude` in Terminal once and log in.

> Each build is signed ad hoc, so macOS asks for the permissions again after every reinstall.

## Use

- Join a call. A "Meeting detected" prompt appears after a few seconds: **Start notes**, **Not now**, or
  **Never for this app**. You can also press **Start meeting** in the window or the menu bar.
- The menu bar icon shows the state: waveform (idle), red dot (recording), hourglass (transcribing / writing notes).
- When the notes are ready you get a notification; click it to open the meeting. macOS refuses notification
  permission for ad hoc signed apps, so in that case the alert is sent through Script Editor instead (allow Script
  Editor under System Settings > Notifications). Settings > Setup shows the status and has a **Send test** button.
- Closing the window keeps the app running in the menu bar (no Dock icon). Open it again from the menu bar or
  by opening the app. It starts at login by default; turn that off in Settings.
- Leave the call and recording stops on its own about 5 seconds later. Transcription takes roughly a minute per
  10 minutes of call, then Claude writes the notes.
- In the window you can rename meetings, copy notes or the transcript, regenerate notes, redo the transcript,
  show the folder in Finder, or move a meeting to the Trash (right-click or ⌘⌫).

Meetings are saved in `Meetings/` inside this folder (ignored by git). Change the folder, your name, language,
automatic start/stop, open at login and whether audio is kept in **Settings**.

## How it works

| File | What it does |
|---|---|
| `src/App.swift` | App entry point, main window and menu bar item |
| `src/Model.swift` | Settings, meeting storage, start/stop, call detection and auto-stop |
| `src/Recorder.swift` | ScreenCaptureKit capture of mic and system audio into two `.caf` files |
| `src/MicMonitor.swift` | Which apps are using the microphone or playing sound (Core Audio process objects) |
| `src/CallInfo.swift` | Meeting name from the browser's call tab |
| `src/Pipeline.swift` | `afconvert` to 16 kHz WAV, `whisper-cli` transcription, transcript merge, notes via `claude -p` |
| `src/Views.swift` | SwiftUI views, Markdown rendering, settings, the meeting prompt |

Claude Code is run with `ANTHROPIC_API_KEY` removed from its environment, so it always uses your Claude
subscription rather than API billing.

## Development

```bash
bash tests/run.sh     # builds the app and runs the unit tests
bash install.sh       # builds and installs the app
```

The tests are a small runner in `tests/main.swift` (no XCTest needed, so the command line tools are enough). They cover
the transcript merge, noise filtering, meeting folders and metadata, call-app grouping, meeting title parsing and the
Claude environment. CI runs the same script on GitHub Actions (`macos-15`).

To refresh the README screenshots (uses the app's own Screen Recording permission):

```bash
open -a "Meeting Notes" --args -captureScreenshots "$PWD/docs/images" -outputDir /path/to/demo/meetings \
    [-screenshotAppearance dark]
```

`docs/VERIFY.md` is the manual end-to-end checklist (permissions, recording, languages, auto-detection, robustness).

## License

MIT, see [LICENSE](LICENSE).
