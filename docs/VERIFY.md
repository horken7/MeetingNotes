# Meeting Notes: verification brief for Claude Code

You are verifying a macOS app that has been written but **never compiled or run**. Your job: build it, fix any errors, test every feature end to end, and report what works. Fix bugs with minimal, targeted edits in `src/`; don't restyle or refactor. Rebuild with `bash install.sh` after changes.

## What the app does

A native SwiftUI menu bar + window app ("Meeting Notes", bundle id `se.frinkle.meetingnotes`) that:

1. Records a video call as two audio tracks: the microphone (`me.caf`) and system audio (`others.caf`), the mic via **AVAudioEngine** and system audio via a **Core Audio process tap** (`CATapDescription` + `AudioHardwareCreateProcessTap` in a private aggregate device, macOS 14.4+, excluding the app's own sound). No BlackHole, virtual driver or Screen Recording permission.
2. **Auto-detects calls**: polls Core Audio process objects every 2 s (`kAudioHardwarePropertyProcessObjectList` / `kAudioProcessPropertyIsRunningInput`, macOS 14.4+) to see which app has the mic open. After 4 s it shows a floating "Meeting detected" panel (Start notes / Not now / Never for this app), or starts automatically if that setting is on. Auto-stops 15 s after the triggering app releases the mic.
3. On stop: converts tracks to 16 kHz WAV with `afconvert`, transcribes each locally with **whisper.cpp** (`whisper-cli`, model `~/.meetnotes/ggml-large-v3-turbo.bin`, optional Silero VAD `~/.meetnotes/ggml-silero-v5.1.2.bin`), merges them into a timestamped transcript labelled with the user's name vs "Others" (using each track's start offset).
4. Writes notes by piping the transcript to **Claude Code**: `claude -p "<prompt>"` with `ANTHROPIC_API_KEY` removed from the environment so it uses the Claude subscription, not API billing.
5. Window: sidebar list of meetings, detail view with Notes / Transcript tabs, rename, copy, regenerate, redo, show in Finder, trash, status/progress and retry on failure. Settings sheet: name, language (auto/sv/da/en), auto-detect, auto-start, auto-stop, open at login (SMAppService), output folder, keep audio, ignored apps, dependency checks, links to privacy panes.

Output per meeting: `<repo>/Meetings/<yyyy-MM-dd HHmm> <title>/` (changeable in Settings) containing `meta.json` (title, created, status, error, app, lang, offsets, duration), `me.wav`, `others.wav`, `*.json` (whisper output), `transcript.md`, `notes.md`.

## Files

| File | Responsibility |
|---|---|
| `install.sh` | Checks deps, installs whisper-cpp (brew) and Claude Code if missing, downloads models, compiles with `swiftc -parse-as-library -swift-version 5 -target <arch>-apple-macos15.0`, builds the .app bundle + Info.plist + icon, ad-hoc codesigns, installs to /Applications, resets TCC entries, opens the app |
| `makeicon.swift` | Renders the app icon PNG (cosmetic; failure is ignored) |
| `src/App.swift` | `@main` app, `Window` + `MenuBarExtra` scenes, AppDelegate (keeps running when window closes; finishes recording safely on quit) |
| `src/Model.swift` | Settings keys/defaults, `Meta`/`Meeting`, `Store` (folder I/O), `AppModel` (start/stop, retry, rename, trash, detection tick loop) |
| `src/Recorder.swift` | AVAudioEngine mic + Core Audio process tap, writes `.caf` per track, returns track start offsets |
| `src/MicMonitor.swift` | Which processes are using the mic, helper-process grouping, system-process filtering |
| `src/Pipeline.swift` | Tool discovery (GUI apps lack shell PATH), process runner, afconvert, whisper, transcript merge, Claude summary |
| `src/Views.swift` | All SwiftUI views, Markdown renderer, settings, floating prompt panel |

## Verification steps

### 1. Build
- `bash install.sh` from the repository folder
- Fix any compile errors. Warnings about Sendable/concurrency are acceptable; errors are not.
- Confirm the app launches, the menu bar waveform icon appears, and the window opens.

### 2. Dependencies
- `whisper-cli --help` works; check whether it supports `--vad` and `-vm` (the pipeline falls back without VAD if that run fails, verify the fallback works).
- Model files exist in `~/.meetnotes/` with sensible sizes (~1.6 GB for the main model).
- `env -u ANTHROPIC_API_KEY claude -p "say OK"` works (logged in via subscription).
- In the app's Settings, all three dependency checks are green.

### 3. Permissions
- On first launch the app should request Microphone; the first recording should request System Audio Recording (listed under Screen & System Audio Recording > System Audio Recording Only). Confirm both prompts appear, that Screen Recording is never requested, and that `others.caf` has sound after granting.
- Confirm denying permissions produces a clear banner rather than a crash or silent failure.

### 4. Recording + transcript
- Manual test: press Start, play speech from another app (e.g. a YouTube video or `say -v Alva "Hej, det här är ett test"` in Terminal) while also speaking into the mic, stop after ~60 s.
- Verify: `me.caf`/`others.caf` are created and non-empty during recording; after stop they become `me.wav`/`others.wav` (16 kHz mono); `transcript.md` contains lines for both the user's name and "Others" in the correct time order.
- Check the track offsets in `meta.json` are plausible and the merged timestamps make sense.
- Test Swedish, Danish and English speech; check auto language detection and the fixed-language setting.
- Verify the app's own sounds (prompt sound) are excluded from the recording (`excludesCurrentProcessAudio`).
- Check behaviour if the audio device changes mid-recording (e.g. plug/unplug headphones). Current code skips buffers whose format differs from the first; verify this doesn't silently lose the rest of the call. If it does, fix it (e.g. by resampling or rotating to a new file segment).

### 5. Notes
- `notes.md` is created with Summary / Decisions / Action items / Open questions / Key points, in the meeting's language, with no en or em dashes.
- Confirm Claude ran on the subscription (no API key used).
- Break it deliberately (e.g. temporarily point `claudePath` default at a non-existent file: `defaults write se.frinkle.meetingnotes claudePath /nope`) and confirm a "failed" status with a useful error and a working Retry. Restore with `defaults delete se.frinkle.meetingnotes claudePath` and rerun `install.sh` or retry.
- "Regenerate notes" reuses the transcript; "Redo transcript and notes" re-runs whisper. Note: after the first run the `.caf` files are deleted and only `.wav` remains; verify redo works from the `.wav` files.

### 6. Auto-detection
- With the app idle, join a real or test call in Zoom, Teams, Google Meet (Chrome and Safari), and FaceTime if available. The prompt should appear within ~6 s, naming the right app (Chrome helper processes should show as "Google Chrome").
- Check it does NOT trigger for: Siri/dictation, the app itself, apps on the ignored list.
- "Not now" should suppress the prompt until that app releases and reopens the mic.
- "Never for X" adds to the ignored list (visible and removable in Settings).
- Auto-start setting: recording starts without a prompt.
- Auto-stop: leave the call; recording should stop ~15 s later and processing should begin. Verify it doesn't stop early during a call if the app briefly toggles the mic (e.g. mute in Zoom/Teams: check whether muting makes `IsRunningInput` go false; if it does, auto-stop will end the recording on a long mute, so fix accordingly, e.g. longer grace period or also checking system audio activity).
- Manual stop while still in the call should not immediately re-prompt.

### 7. Robustness
- Quit the app during a recording: audio is saved, meeting shows "failed" with Retry, and Retry produces notes.
- Quit during transcription: on relaunch the meeting is marked interrupted with Retry.
- Long meeting (30+ min): memory stays reasonable, transcription time is acceptable, Claude handles the transcript length.
- Window closed: app keeps running in the menu bar; reopen from the menu.
- Open at login toggle works.
- Change output folder in Settings: list reloads from the new folder.
- Rename, copy, show in Finder, move to Trash all work.

### 8. UI review
- Light and dark mode both look right.
- Markdown renders headings, bullets, nested bullets and bold correctly.
- Progress states (Recording / Transcribing / Writing notes / Failed) update live in both sidebar and detail.

## Report back

A short list: what passed, what you fixed (file + one line each), and anything still broken or untestable.

### Provider selection (Claude and Codex)
- Install with `bash install.sh --provider codex`; confirm Claude is not required. Repeat with `--provider claude`.
- Settings > Notes: switch providers, close/reopen Settings, confirm the selection persists.
- Check the selected CLI installation status and optional custom executable path.
- Use a synthetic transcript to regenerate notes with each authenticated CLI. Confirm Markdown output and provider-specific errors when logged out.
- Codex uses existing CLI authentication; verify the intended ChatGPT/API account before a live run.
- Verify Settings scrolls to every section at the standard window size.
