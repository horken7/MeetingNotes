# Meeting Notes for Windows

A native Windows version of Meeting Notes (C#, .NET 8, WPF). It does what the Mac app does and writes the same
meeting folders (`meta.json`, `transcript.md`, `notes.md`, `me.wav`, `others.wav`), so the notes, the prompt and the
MCP server work the same way.

Install it with `MeetingNotes-Setup.exe` from the [GitHub Releases](https://github.com/horken7/MeetingNotes/releases)
page: a per-user install (no administrator rights) to `%LOCALAPPDATA%\Programs\MeetingNotes`. The installer isn't
signed yet, so Windows SmartScreen says "Windows protected your PC" the first time: click **More info**, then
**Run anyway**. On first launch a setup assistant downloads the speech model and helps install and sign in to the
notes provider, without the command line.

Requirements: Windows 10 (1809) or 11, x64 (Windows on Arm runs it emulated), about 2 GB of disk for the speech model.

## What's where

| Path | What it does |
|---|---|
| `src/MeetingNotes.Core` | Everything that isn't Windows UI or audio capture (plain `net8.0`, so it's tested on any OS): settings, meeting storage and `meta.json`, 16 kHz conversion, `whisper-cli` transcription, transcript merge, the notes prompt, `claude -p` / `codex exec` / Ollama, the mic-usage registry parsing, window-title meeting names, the Markdown subset, and the MCP server |
| `src/MeetingNotes` | The WPF app: notification-area icon, main window, settings, setup assistant, "Meeting detected" notification and panel, WASAPI recorder |
| `src/MeetingNotes.Mcp` | `meetingnotes-mcp.exe`, the read-only MCP server (stdio) for Claude Desktop and other AI apps |
| `tests/MeetingNotes.Tests` | xUnit tests for the Core parts, including JSON-RPC round trips through the built MCP server |
| `installer/MeetingNotes.iss` | Inno Setup script for `MeetingNotes-Setup.exe` |
| `build.ps1` | Tests, publishes (self-contained), bundles whisper.cpp, smoke-tests both executables, builds the installer |

## How it maps to the Mac app

| | Mac | Windows |
|---|---|---|
| Microphone ("me") | AVAudioEngine | WASAPI shared-mode capture of the default microphone |
| Call audio ("others") | Core Audio process tap, excluding the app | WASAPI loopback of the default speakers. The app plays no sound while recording, so there's nothing of its own to exclude. Loopback sends nothing during silence; the writer fills those gaps from the clock so timestamps stay right |
| If call audio fails | records the mic alone | the same; a device change (headset plugged in) starts a new segment (`me-1`, `others-1`…) like the Mac |
| Call detection | Core Audio process objects | the registry Windows keeps for the microphone privacy indicator (`HKCU\…\CapabilityAccessManager\ConsentStore\microphone`, `LastUsedTimeStop = 0` while in use), polled every 2 s; auto-stop 5 s after the app releases the mic (up to 60 s while it still plays sound, from its audio session) |
| Meeting name | AppleScript reads the browser's tabs | the call app's window titles (the active tab's title is in the browser window title), e.g. "Meet – Weekly sync - Google Chrome" becomes "Weekly sync" |
| Transcription | Homebrew `whisper-cli` | the official whisper.cpp Windows build (`b5454` = v1.9.5, CPU), bundled; models in `%LOCALAPPDATA%\MeetingNotes` |
| Notes | `claude -p`, `codex exec`, Ollama `/api/chat` | the same commands, flags, prompt and request (`ANTHROPIC_API_KEY` removed) |
| Settings | UserDefaults | `%LOCALAPPDATA%\MeetingNotes\settings.json`, same key names |
| Notifications | UNUserNotificationCenter | Windows toast notifications (buttons: Start notes, Not now, Never for this app) |
| Start at login | SMAppService | `HKCU\…\Run` entry with `--background` |
| Trash | Finder Trash | Recycle Bin |

The MCP server reads the meetings folder from `settings.json` (or `MEETINGNOTES_DIR`). **Settings > Setup > Add to
Claude Desktop** writes `%LOCALAPPDATA%\MeetingNotes\MeetingNotes.mcpb` (a Claude Desktop extension whose
`mcp_config.command` is the installed `meetingnotes-mcp.exe`, so updates need no reinstall) and opens it; **Other apps**
copies the Claude Code, Codex and VS Code commands and the JSON config.

## Development

You need the .NET 8 SDK. The Core library and tests run on macOS and Linux too; the app and installer need Windows.

```powershell
dotnet test windows\tests\MeetingNotes.Tests
powershell -ExecutionPolicy Bypass -File windows\build.ps1          # windows\artifacts\MeetingNotes-Setup.exe
dotnet run --project windows\src\MeetingNotes                        # run the app from source (needs whisper\ next to it to transcribe)
```

`dotnet build windows\MeetingNotes.sln` also compiles the WPF app on a Mac (`EnableWindowsTargeting`), which catches
compile errors but runs nothing. CI (`.github/workflows/windows.yml`, `windows-latest`) runs `build.ps1` on pull requests
that touch `windows/`, keeps the installer as an artifact, and uploads it to the GitHub Release on a `v*` tag.

The app writes a log to `%LOCALAPPDATA%\MeetingNotes\log.txt`.
