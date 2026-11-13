# Meeting Notes for Windows

A native Windows version of Meeting Notes (C#, .NET 8, WPF). It does what the Mac app does and writes the same
meeting folders (`meta.json`, `transcript.md`, `notes.md`, `me.wav`, `others.wav`), so the notes, the prompt and the
MCP server work the same way.

## Install

The installer has everything inside: the app, whisper.cpp with the speech models, and llama.cpp with the built-in notes
model, so nothing is downloaded at first run and notes work without an account. That makes it about 4.2 GB, which is
more than one Setup.exe can hold, so it comes as two files: **MeetingNotes-Setup.exe** (small) and
**MeetingNotes-Setup-1.bin** (the data). It is also over GitHub's 2 GB limit for a release file, so the
[latest release](https://github.com/horken7/MeetingNotes/releases/latest) links to where it's hosted (the CI artifact
`MeetingNotes-Setup` is a zip with both files).

1. Download both files (or the zip, and extract it) into the same folder.
2. Run **MeetingNotes-Setup.exe**. The installer isn't signed yet, so Windows SmartScreen says "Windows protected your
   PC" the first time: click **More info**, then **Run anyway**.
3. Choose **Install for me only** (the default, no administrator rights) or **Install for all users** (needs
   administrator rights, installs to Program Files).
4. Choose the folder. The default is `%LOCALAPPDATA%\Programs\MeetingNotes` (for all users: `C:\Program Files\MeetingNotes`);
   pick another drive if C: is short of space. Updates install into the same folder without asking again.
5. On first launch a short setup assistant asks your name and the meeting language. Notes are written by the built-in
   model unless you choose Claude Code, Codex or Ollama, which the assistant helps install and sign in to.

Requirements: Windows 10 (1809) or 11, x64 (Windows on Arm runs it emulated), about 5 GB of disk, and 8 GB of memory
for the built-in notes model (it uses about 4 GB while it writes). Your settings and log stay in
`%LOCALAPPDATA%\MeetingNotes` and your meetings in `Documents\Meetings`, wherever the app is installed.

## Notes providers

| Provider | What it needs | |
|---|---|---|
| **Built-in (Gemma 3 4B, on this PC)**, the default | Nothing: comes with the installer | Google's Gemma 3 4B instruct ([`ggml-org/gemma-3-4b-it-GGUF`](https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF), Q4_K_M, 2.5 GB, pinned by SHA-256) run by llama.cpp's `llama-server` (`b12012`, the official Vulkan build, which includes all the CPU variants). It uses the graphics card through Vulkan when there is one (Settings > Notes can turn that off) and falls back to the processor. Nothing leaves the PC. A one-hour meeting takes several minutes on a laptop processor |
| Claude Code | a Claude Pro or Max plan, Git for Windows | Best notes. The text transcript is sent to Anthropic |
| Codex | a ChatGPT account (or OpenAI API key) | The text transcript is sent to OpenAI |
| Ollama | Ollama and an 8 GB model (`gemma3:12b`), 16 GB of memory | Local, like the built-in model but bigger and slower |

Existing installs keep the provider they had; new installs start with the built-in model. Gemma is provided under and
subject to the [Gemma Terms of Use](https://ai.google.dev/gemma/terms) (a copy of the notice is installed next to the
model, `models\GEMMA-NOTICE.txt`).

How the built-in model writes the notes (ported from the phone apps, `android/…/core/Summarizer.kt` and
`ios/MeetingCore/…/Grounding.swift`): the same prompt and your **How the notes should look** instructions as the other
providers, plus rules against inventing names, numbers and decisions, and the meeting's language named again after the
transcript (small models otherwise drift into English). Under 30 spoken words it writes "Too little was said…" instead
of calling the model. The context is 12,288 tokens; a longer meeting (over about half an hour) is split at speaker turns
into parts, each part gets short notes, and these are combined (in rounds if needed). The app starts `llama-server` on a
random local port with a random API key for each meeting's notes and stops it afterwards (it's also stopped if the app
quits or crashes). The meeting shows which step is running, and **Stop** cancels it (Retry starts again).

## What's where

| Path | What it does |
|---|---|
| `src/MeetingNotes.Core` | Everything that isn't Windows UI or audio capture (plain `net8.0`, so it's tested on any OS): settings, meeting storage and `meta.json`, 16 kHz conversion, `whisper-cli` transcription, transcript merge, the notes prompt, the built-in model (`BuiltIn.cs`: `llama-server`; `LocalNotes.cs`: prompts, chunking and combining), `claude -p` / `codex exec` / Ollama, the mic-usage registry parsing, window-title meeting names, the Markdown subset, and the MCP server |
| `src/MeetingNotes` | The WPF app: notification-area icon, main window, settings, setup assistant, "Meeting detected" notification and panel, WASAPI recorder |
| `src/MeetingNotes.Mcp` | `meetingnotes-mcp.exe`, the read-only MCP server (stdio) for Claude Desktop and other AI apps |
| `tests/MeetingNotes.Tests` | xUnit tests for the Core parts, including JSON-RPC round trips through the built MCP server, and one test that writes notes with the real `llama-server` and model when `MEETINGNOTES_LLAMA_SERVER` and `MEETINGNOTES_LLAMA_MODEL` point to them |
| `installer/MeetingNotes.iss` | Inno Setup script for `MeetingNotes-Setup.exe` (and `-1.bin`) |
| `build.ps1` | Tests, publishes (self-contained), bundles whisper.cpp, llama.cpp and the models (downloaded once into `windows\.models`, pinned by SHA-256, never committed), smoke-tests whisper and the built-in notes model with them and the MCP server, and builds the installer (needs Inno Setup 6.5.2 or later; it installs it with Chocolatey if missing) |

## How it maps to the Mac app

| | Mac | Windows |
|---|---|---|
| Microphone ("me") | AVAudioEngine | WASAPI shared-mode capture of the default microphone |
| Call audio ("others") | Core Audio process tap, excluding the app | WASAPI loopback of the default speakers. The app plays no sound while recording, so there's nothing of its own to exclude. Loopback sends nothing during silence; the writer fills those gaps from the clock so timestamps stay right |
| If call audio fails | records the mic alone | the same; a device change (headset plugged in) starts a new segment (`me-1`, `others-1`…) like the Mac |
| Call detection | Core Audio process objects | the registry Windows keeps for the microphone privacy indicator (`HKCU\…\CapabilityAccessManager\ConsentStore\microphone`, `LastUsedTimeStop = 0` while in use), polled every 2 s; auto-stop 5 s after the app releases the mic (up to 60 s while it still plays sound, from its audio session) |
| Meeting name | AppleScript reads the browser's tabs | the call app's window titles (the active tab's title is in the browser window title), e.g. "Meet – Weekly sync - Google Chrome" becomes "Weekly sync" |
| Transcription | Homebrew `whisper-cli` | the official whisper.cpp Windows build (`b5454` = v1.9.5, CPU), bundled, with `ggml-large-v3-turbo.bin` and the Silero VAD model in the install folder's `models\` (only if those are missing, the app offers to download them to `%LOCALAPPDATA%\MeetingNotes`) |
| Notes | `claude -p`, `codex exec`, Ollama `/api/chat` | the same commands, flags, prompt and request (`ANTHROPIC_API_KEY` removed), plus the built-in Gemma 3 4B in llama.cpp (the default), like the phone apps |
| Settings | UserDefaults | `%LOCALAPPDATA%\MeetingNotes\settings.json`, same key names |
| Notifications | UNUserNotificationCenter | Windows toast notifications (buttons: Start notes, Not now, Never for this app) |
| Start at login | SMAppService | `HKCU\…\Run` entry with `--background` |
| Trash | Finder Trash | Recycle Bin |

The MCP server reads the meetings folder from `settings.json` (or `MEETINGNOTES_DIR`). **Settings > Setup > Add to
Claude Desktop** writes `%LOCALAPPDATA%\MeetingNotes\MeetingNotes.mcpb` (a Claude Desktop extension whose
`mcp_config.command` is the installed `meetingnotes-mcp.exe`, so updates need no reinstall) and opens it; **Other apps**
copies the Claude Code, Codex and VS Code commands and the JSON config. They all use the path of the running app's
install folder, so they're right wherever Meeting Notes was installed.

## Development

You need the .NET 8 SDK. The Core library and tests run on macOS and Linux too; the app and installer need Windows.

```powershell
dotnet test windows\tests\MeetingNotes.Tests
powershell -ExecutionPolicy Bypass -File windows\build.ps1          # windows\artifacts\MeetingNotes-Setup.exe
dotnet run --project windows\src\MeetingNotes                        # run the app from source (needs whisper\ next to it to transcribe)
```

`dotnet build windows\MeetingNotes.sln` also compiles the WPF app on a Mac (`EnableWindowsTargeting`), which catches
compile errors but runs nothing. The built-in model's client can be tried on a Mac too, with llama.cpp's macOS build of
the same release and the same GGUF:

```sh
MEETINGNOTES_LLAMA_SERVER=/path/to/llama-b12012/llama-server MEETINGNOTES_LLAMA_MODEL=/path/to/gemma-3-4b-it-Q4_K_M.gguf \
  dotnet test windows/tests/MeetingNotes.Tests --filter Category=LlamaIntegration --logger "console;verbosity=detailed"
```

CI (`.github/workflows/windows.yml`, `windows-latest`) runs `build.ps1` on pull requests that touch `windows/` and
keeps the installer as the `MeetingNotes-Setup` artifact for 30 days. On a `v*` tag it also uploads it to the GitHub
Release, but only if every file is under GitHub's 2 GiB asset limit (with the notes model inside, the `.bin` isn't, so
the job leaves a notice instead and the installer is hosted by hand).

Single file or two: a Setup.exe can hold at most about 4.2 GB (Inno Setup 6.5.2 and later; Windows won't start a
larger program), and the files to install are about 4.4 GB (the installer compresses them to 4.19 GB: a 2 MB Setup.exe and a 4.18 GB .bin). So `build.ps1` turns on disk spanning
(`DiskSpanning=yes`, `DiskSliceSize=max`) when they're over 3.9 GB, which gives one small `MeetingNotes-Setup.exe` and
one `MeetingNotes-Setup-1.bin` of any size. Below that (smaller models) it makes a single Setup.exe as before.

The app writes a log to `%LOCALAPPDATA%\MeetingNotes\log.txt`.
