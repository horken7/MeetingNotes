# Builds the Windows app, runs the tests and makes the installer:
#   powershell -ExecutionPolicy Bypass -File windows\build.ps1 [-Version 1.2.3] [-SkipTests] [-ModelCache <folder>]
# Output: windows\artifacts\MeetingNotes-Setup.exe, with the speech models and the built-in notes model inside (no
# download at first run). The models make it over 4 GB, more than one Setup.exe can hold, so the data then goes into
# windows\artifacts\MeetingNotes-Setup-1.bin next to it (see installer\MeetingNotes.iss).
param(
    # Defaults to the repository's version.txt (kept by release-please); CI passes the tag's version.
    [string]$Version = (Get-Content (Join-Path $PSScriptRoot "..\version.txt") -Raw).Trim(),
    [switch]$SkipTests,
    # Downloaded models are kept here between builds (CI caches this folder). Never committed.
    [string]$ModelCache = (Join-Path $PSScriptRoot ".models")
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# whisper.cpp's official Windows build (CPU, x64; runs on Windows on Arm too, emulated). Pinned by hash.
$WhisperRelease = "b5454"   # = v1.9.5
$WhisperSha256 = "6ba69e3482d7826214f90a6a9c84ca07782aec1e1d0c6a7c30c994fd5d816ccb"

# llama.cpp's official Windows build for the built-in notes model: the Vulkan build, which is the CPU build (all the
# ggml-cpu-*.dll variants, picked at run time for the processor) plus ggml-vulkan.dll for graphics cards. Without a
# Vulkan driver, llama-server just uses the CPU. Pinned by hash.
$LlamaRelease = "b12012"
$LlamaZip = "llama-$LlamaRelease-bin-win-vulkan-x64.zip"
$LlamaSha256 = "3f0c32902d21c9167b9d92b28d8b39af09567c864e726fa395502f47249773b4"

# The models bundled in the installer, pinned to a Hugging Face commit and checked by SHA-256: the speech models and
# the notes model (Gemma 3 4B instruct, Q4_K_M, the same file as the Android app's 4B option).
$Models = @(
    @{ File = "ggml-large-v3-turbo.bin"; Size = 1624555275
       Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin"
       Sha256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69" },
    @{ File = "ggml-silero-v5.1.2.bin"; Size = 885098
       Url = "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin"
       Sha256 = "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf" },
    @{ File = "gemma-3-4b-it-Q4_K_M.gguf"; Size = 2489757856
       Url = "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/d0976223747697cb51e056d85c532013931fe52e/gemma-3-4b-it-Q4_K_M.gguf"
       Sha256 = "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863" }
)
# Inno Setup can put at most about 4.2 GB into one Setup.exe; above this the data goes into a .bin next to it.
$MaxSingleExeBytes = 3900000000

$root = $PSScriptRoot
$out = Join-Path $root "artifacts"
$app = Join-Path $out "app"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $app | Out-Null

function Run($exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe $($arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

$semver = $Version -replace '[^0-9.].*$', ''
if ($semver -notmatch '^\d+(\.\d+){1,3}$') { $semver = "1.0.0" }

if (-not $SkipTests) {
    Run dotnet @("test", (Join-Path $root "tests\MeetingNotes.Tests"), "-c", "Release", "--logger", "console;verbosity=normal")
}

# Both executables share one self-contained .NET runtime in the install folder.
foreach ($project in @("src\MeetingNotes\MeetingNotes.csproj", "src\MeetingNotes.Mcp\MeetingNotes.Mcp.csproj")) {
    Run dotnet @("publish", (Join-Path $root $project), "-c", "Release", "-r", "win-x64", "--self-contained", "true",
        "-p:Version=$semver", "-p:InformationalVersion=$Version", "-o", $app)
}
Get-ChildItem $app -Filter *.pdb | Remove-Item

# whisper-cli.exe and its DLLs
$zip = Join-Path $out "whisper.zip"
Invoke-WebRequest "https://github.com/ggml-org/whisper.cpp/releases/download/$WhisperRelease/whisper-bin-x64.zip" -OutFile $zip -MaximumRetryCount 5 -RetryIntervalSec 15
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $WhisperSha256) { throw "whisper-bin-x64.zip has hash $hash, expected $WhisperSha256" }
$unpacked = Join-Path $out "whisper-unpacked"
Expand-Archive $zip -DestinationPath $unpacked
$release = Get-ChildItem $unpacked -Recurse -Filter whisper-cli.exe | Select-Object -First 1
if (-not $release) { throw "whisper-cli.exe not found in the whisper.cpp release" }
$whisper = New-Item -ItemType Directory -Force (Join-Path $app "whisper")
Copy-Item $release.FullName $whisper
Get-ChildItem $release.DirectoryName -Filter *.dll | Where-Object { $_.Name -match '^(whisper|ggml.*)\.dll$' } | Copy-Item -Destination $whisper
Invoke-WebRequest "https://raw.githubusercontent.com/ggml-org/whisper.cpp/$WhisperRelease/LICENSE" -OutFile (Join-Path $whisper "LICENSE.txt") -MaximumRetryCount 5 -RetryIntervalSec 15
Copy-Item (Join-Path $root "..\LICENSE") (Join-Path $app "LICENSE.txt")

# llama-server.exe and its DLLs (in their own folder: they have their own ggml*.dll, newer than whisper's)
$zip = Join-Path $out "llama.zip"
Invoke-WebRequest "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaRelease/$LlamaZip" -OutFile $zip -MaximumRetryCount 5 -RetryIntervalSec 15
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $LlamaSha256) { throw "$LlamaZip has hash $hash, expected $LlamaSha256" }
$unpacked = Join-Path $out "llama-unpacked"
Expand-Archive $zip -DestinationPath $unpacked
$server = Get-ChildItem $unpacked -Recurse -Filter llama-server.exe | Select-Object -First 1
if (-not $server) { throw "llama-server.exe not found in the llama.cpp release" }
$llama = New-Item -ItemType Directory -Force (Join-Path $app "llama")
# llama-server.exe is a small launcher for llama-server-impl.dll; the server needs the llama, ggml (all backends),
# mtmd and OpenMP DLLs. The other tools (llama-cli, llama-bench…) aren't needed.
Copy-Item $server.FullName $llama
Get-ChildItem $server.DirectoryName -Filter *.dll |
    Where-Object { $_.Name -match '^(llama|llama-common|llama-server-impl|mtmd|libomp|ggml.*)\.dll$' } | Copy-Item -Destination $llama
Get-ChildItem $server.DirectoryName -Filter "LICENSE*" | Copy-Item -Destination $llama
Invoke-WebRequest "https://raw.githubusercontent.com/ggml-org/llama.cpp/$LlamaRelease/LICENSE" -OutFile (Join-Path $llama "LICENSE.txt") -MaximumRetryCount 5 -RetryIntervalSec 15
foreach ($dll in @("llama-server-impl.dll", "llama.dll", "ggml-base.dll", "ggml-cpu-x64.dll", "ggml-vulkan.dll")) {
    if (-not (Test-Path (Join-Path $llama $dll))) { throw "$dll is missing from the llama.cpp release" }
}

# The speech models, from the cache or downloaded (and verified) into it.
New-Item -ItemType Directory -Force $ModelCache | Out-Null
$modelDir = New-Item -ItemType Directory -Force (Join-Path $app "models")
foreach ($m in $Models) {
    $cached = Join-Path $ModelCache $m.File
    $ok = (Test-Path $cached) -and ((Get-Item $cached).Length -eq $m.Size) -and
          ((Get-FileHash $cached -Algorithm SHA256).Hash.ToLowerInvariant() -eq $m.Sha256)
    if (-not $ok) {
        Write-Host "Downloading $($m.File)"
        $part = "$cached.part"
        # curl.exe ships with Windows 10+ and is much faster than Invoke-WebRequest for a 1.6 GB file.
        Run curl.exe @("-fL", "--retry", "5", "--retry-all-errors", "-o", $part, $m.Url)
        $hash = (Get-FileHash $part -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $m.Sha256) { throw "$($m.File) has hash $hash, expected $($m.Sha256)" }
        Move-Item -Force $part $cached
    }
    Copy-Item $cached $modelDir
}
# Gemma's terms ask for a copy of them with the model.
@"
The built-in notes model is Gemma 3 4B instruct (gemma-3-4b-it-Q4_K_M.gguf, from
https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF, converted from https://huggingface.co/google/gemma-3-4b-it).

Gemma is provided under and subject to the Gemma Terms of Use found at https://ai.google.dev/gemma/terms
and its Prohibited Use Policy at https://ai.google.dev/gemma/prohibited_use_policy.
"@ | Out-File -Encoding utf8 (Join-Path $modelDir "GEMMA-NOTICE.txt")

# Smoke test: the bundled whisper-cli starts (all DLLs present).
& (Join-Path $whisper "whisper-cli.exe") --help *> (Join-Path $out "whisper-help.txt")
if ($LASTEXITCODE -ne 0) { Get-Content (Join-Path $out "whisper-help.txt") | Select-Object -First 20; throw "whisper-cli.exe --help failed ($LASTEXITCODE)" }
if (-not (Select-String -Path (Join-Path $out "whisper-help.txt") -Pattern "--vad" -Quiet)) { throw "whisper-cli.exe has no --vad option" }

# Smoke test: whisper-cli transcribes 2 s of silence with the bundled models (loads both, writes JSON).
$wav = Join-Path $out "silence.wav"
$samples = 32000
$bytes = New-Object byte[] (44 + $samples * 2)
$w = New-Object System.IO.BinaryWriter([System.IO.MemoryStream]::new($bytes))
$w.Write([Text.Encoding]::ASCII.GetBytes("RIFF")); $w.Write([int](36 + $samples * 2)); $w.Write([Text.Encoding]::ASCII.GetBytes("WAVEfmt "))
$w.Write([int]16); $w.Write([int16]1); $w.Write([int16]1); $w.Write([int]16000); $w.Write([int]32000); $w.Write([int16]2); $w.Write([int16]16)
$w.Write([Text.Encoding]::ASCII.GetBytes("data")); $w.Write([int]($samples * 2)); $w.Flush()
[System.IO.File]::WriteAllBytes($wav, $bytes)
Push-Location $out
try {
    $cli = Join-Path $whisper "whisper-cli.exe"
    $model = Join-Path $modelDir "ggml-large-v3-turbo.bin"
    & $cli -m $model -f "silence.wav" -l en -t 4 -oj -of silence -np *> (Join-Path $out "whisper-run.txt")
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $out "silence.json"))) {
        Get-Content (Join-Path $out "whisper-run.txt") | Select-Object -Last 30
        throw "whisper-cli.exe couldn't transcribe with the bundled model ($LASTEXITCODE)"
    }
    & $cli -m $model -f "silence.wav" -l en -t 4 -oj -of silence-vad -np --vad -vm (Join-Path $modelDir "ggml-silero-v5.1.2.bin") *> (Join-Path $out "whisper-vad.txt")
    if ($LASTEXITCODE -ne 0) {
        Get-Content (Join-Path $out "whisper-vad.txt") | Select-Object -Last 30
        throw "whisper-cli.exe failed with the bundled voice activity model ($LASTEXITCODE)"
    }
} finally { Pop-Location }

# Smoke test: llama-server starts with the bundled notes model and the app's client code writes notes with it
# (LlamaServerIntegrationTests, on the CPU: the runner has no GPU).
if (-not $SkipTests) {
    $env:MEETINGNOTES_LLAMA_SERVER = Join-Path $llama "llama-server.exe"
    $env:MEETINGNOTES_LLAMA_MODEL = Join-Path $modelDir "gemma-3-4b-it-Q4_K_M.gguf"
    $env:MEETINGNOTES_DATA = Join-Path $out "test-data"
    try {
        Run dotnet @("test", (Join-Path $root "tests\MeetingNotes.Tests"), "-c", "Release", "--filter", "Category=LlamaIntegration",
            "--logger", "console;verbosity=detailed")
    } finally {
        Remove-Item Env:MEETINGNOTES_LLAMA_SERVER, Env:MEETINGNOTES_LLAMA_MODEL, Env:MEETINGNOTES_DATA -ErrorAction SilentlyContinue
        $log = Join-Path $out "test-data\log.txt"
        if (Test-Path $log) { Get-Content $log | Select-Object -Last 20 }
    }
}

# Smoke test: the published MCP server answers initialize.
$reply = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | & (Join-Path $app "meetingnotes-mcp.exe")
if ($reply -notmatch '"meeting-notes"') { throw "meetingnotes-mcp.exe didn't answer: $reply" }

# Installer (Inno Setup)
# Inno Setup 6.5.2 or later is needed (DiskSliceSize=max); older ones stop with an error on that line. ISCC.exe's
# file version info reads 0.0.0, so Chocolatey says which version it is.
$iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    Write-Host "Installing Inno Setup"
    Run choco @("install", "innosetup", "-y", "--no-progress")
    $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
}
if (Get-Command choco -ErrorAction SilentlyContinue) { choco list innosetup --exact --limit-output | Write-Host }
$payload = (Get-ChildItem $app -Recurse -File | Measure-Object -Property Length -Sum).Sum
$span = if ($payload -gt $MaxSingleExeBytes) { "1" } else { "0" }
"Files to install: {0:N0} bytes ({1:N2} GB); disk spanning: {2}" -f $payload, ($payload / 1e9), $span | Write-Host
Run $iscc @("/Qp", "/DAppVersion=$Version", "/DNumericVersion=$semver", "/DSourceDir=$app", "/DOutputDir=$out", "/DSpan=$span", (Join-Path $root "installer\MeetingNotes.iss"))
$files = @(Get-ChildItem $out -File | Where-Object { $_.Name -match '^MeetingNotes-Setup(-\d+)?\.(exe|bin)$' } | Sort-Object Name)
if (-not ($files | Where-Object Name -eq "MeetingNotes-Setup.exe")) { throw "ISCC made no MeetingNotes-Setup.exe" }
if ($span -eq "1" -and -not ($files | Where-Object Name -eq "MeetingNotes-Setup-1.bin")) { throw "ISCC made no MeetingNotes-Setup-1.bin" }
$files | Format-Table Name, Length
$total = ($files | Measure-Object -Property Length -Sum).Sum
"Installer size: {0:N0} bytes ({1:N2} GB) in {2} file(s): {3}" -f $total, ($total / 1e9), $files.Count, (($files | ForEach-Object Name) -join ", ") | Write-Host
if ($env:GITHUB_STEP_SUMMARY) {
    foreach ($f in $files) {
        "- {0}: {1:N0} bytes ({2:N2} GB)" -f $f.Name, $f.Length, ($f.Length / 1e9) | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY
    }
}
