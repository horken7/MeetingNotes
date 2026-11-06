# Builds the Windows app, runs the tests and makes the installer:
#   powershell -ExecutionPolicy Bypass -File windows\build.ps1 [-Version 1.2.3] [-SkipTests]
# Output: windows\artifacts\MeetingNotes-Setup.exe
param(
    [string]$Version = "1.0.0",
    [switch]$SkipTests
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# whisper.cpp's official Windows build (CPU, x64; runs on Windows on Arm too, emulated). Pinned by hash.
$WhisperRelease = "b5454"   # = v1.9.5
$WhisperSha256 = "6ba69e3482d7826214f90a6a9c84ca07782aec1e1d0c6a7c30c994fd5d816ccb"

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
Invoke-WebRequest "https://github.com/ggml-org/whisper.cpp/releases/download/$WhisperRelease/whisper-bin-x64.zip" -OutFile $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $WhisperSha256) { throw "whisper-bin-x64.zip has hash $hash, expected $WhisperSha256" }
$unpacked = Join-Path $out "whisper-unpacked"
Expand-Archive $zip -DestinationPath $unpacked
$release = Get-ChildItem $unpacked -Recurse -Filter whisper-cli.exe | Select-Object -First 1
if (-not $release) { throw "whisper-cli.exe not found in the whisper.cpp release" }
$whisper = New-Item -ItemType Directory -Force (Join-Path $app "whisper")
Copy-Item $release.FullName $whisper
Get-ChildItem $release.DirectoryName -Filter *.dll | Where-Object { $_.Name -match '^(whisper|ggml.*)\.dll$' } | Copy-Item -Destination $whisper
Invoke-WebRequest "https://raw.githubusercontent.com/ggml-org/whisper.cpp/$WhisperRelease/LICENSE" -OutFile (Join-Path $whisper "LICENSE.txt")
Copy-Item (Join-Path $root "..\LICENSE") (Join-Path $app "LICENSE.txt")

# Smoke test: the bundled whisper-cli starts (all DLLs present).
& (Join-Path $whisper "whisper-cli.exe") --help *> (Join-Path $out "whisper-help.txt")
if ($LASTEXITCODE -ne 0) { Get-Content (Join-Path $out "whisper-help.txt") | Select-Object -First 20; throw "whisper-cli.exe --help failed ($LASTEXITCODE)" }
if (-not (Select-String -Path (Join-Path $out "whisper-help.txt") -Pattern "--vad" -Quiet)) { throw "whisper-cli.exe has no --vad option" }

# Smoke test: the published MCP server answers initialize.
$reply = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | & (Join-Path $app "meetingnotes-mcp.exe")
if ($reply -notmatch '"meeting-notes"') { throw "meetingnotes-mcp.exe didn't answer: $reply" }

# Installer (Inno Setup)
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
Run $iscc @("/Qp", "/DAppVersion=$Version", "/DNumericVersion=$semver", "/DSourceDir=$app", "/DOutputDir=$out", (Join-Path $root "installer\MeetingNotes.iss"))
Get-Item (Join-Path $out "MeetingNotes-Setup.exe") | Format-Table Name, Length
