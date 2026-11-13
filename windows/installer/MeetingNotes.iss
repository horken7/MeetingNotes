; Meeting Notes for Windows, built by windows\build.ps1. By default a per-user install (no administrator rights) to
; %LOCALAPPDATA%\Programs\MeetingNotes; the folder can be changed (another drive, say), and "Install for all users"
; (Program Files, needs administrator rights) is offered at the start. Updates reuse the folder and mode chosen the
; first time. Adds a Start menu entry. Unsigned for now, so Windows SmartScreen shows "Windows protected your PC" the
; first time: More info > Run anyway.
;
; Size: the speech model (1.6 GB) and the notes model (2.5 GB) make the setup over 4 GB. A single Setup.exe can hold at
; most about 4.2 GB (Inno Setup 6.5.2 and later; Windows can't start larger programs), so build.ps1 passes /DSpan=1
; when the files are bigger than that: then the data goes into MeetingNotes-Setup-1.bin next to a small
; MeetingNotes-Setup.exe (one slice, any size), and both must be in the same folder to install.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef NumericVersion
  #define NumericVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\artifacts\app"
#endif
#ifndef OutputDir
  #define OutputDir "..\artifacts"
#endif
#ifndef Span
  #define Span "0"
#endif

[Setup]
AppId={{8F3C2B71-5E0A-4F59-9C1E-2D7A6B4E9F10}
AppName=Meeting Notes
AppVersion={#AppVersion}
AppVerName=Meeting Notes {#AppVersion}
VersionInfoVersion={#NumericVersion}
AppPublisher=Meeting Notes
AppPublisherURL=https://github.com/horken7/MeetingNotes
AppSupportURL=https://github.com/horken7/MeetingNotes/issues
; {autopf} is %LOCALAPPDATA%\Programs for a per-user install and Program Files for all users.
DefaultDirName={autopf}\MeetingNotes
; The folder page is shown on the first install only; updates use the previous folder.
DisableDirPage=auto
UsePreviousAppDir=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
; The app's own per-user entries (start at sign-in) are HKCU on purpose, also for an all-users install.
UsedUserAreasWarning=no
OutputDir={#OutputDir}
OutputBaseFilename=MeetingNotes-Setup
SetupIconFile=..\src\MeetingNotes\Assets\app.ico
UninstallDisplayIcon={app}\MeetingNotes.exe
UninstallDisplayName=Meeting Notes
Compression=lzma2/max
SolidCompression=yes
#if Span == "1"
DiskSpanning=yes
DiskSliceSize=max
#endif
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "\models\*"; Flags: recursesubdirs ignoreversion
; The speech and notes models (about 4.1 GB) barely compress, so they're stored as they are: LZMA would take long and gain little.
Source: "{#SourceDir}\models\*"; DestDir: "{app}\models"; Flags: ignoreversion nocompression

[Icons]
Name: "{autoprograms}\Meeting Notes"; Filename: "{app}\MeetingNotes.exe"
Name: "{autodesktop}\Meeting Notes"; Filename: "{app}\MeetingNotes.exe"; Tasks: desktopicon

[Registry]
; The app adds itself here for "Start when I sign in"; remove it on uninstall.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "MeetingNotes"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\MeetingNotes.exe"; Description: "Open Meeting Notes"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\MeetingNotes.exe"; Parameters: "--uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "Cleanup"

[Code]
procedure StopApp();
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im MeetingNotes.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im meetingnotes-mcp.exe', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  // An update replaces the files of the running app (it runs in the background, in the notification area).
  // A llama-server.exe the app started for the notes ends with it (it's in a kill-on-close job object).
  StopApp();
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  StopApp();
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Data: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    Data := ExpandConstant('{localappdata}\MeetingNotes');
    if DirExists(Data) and not UninstallSilent() then
      // The installed speech model is removed with the app; this folder has the settings, the log and any model
      // that was downloaded separately because the installed one was missing.
      if MsgBox('Also delete your Meeting Notes settings (and any speech model downloaded separately)?' #13#10 #13#10 +
                'Your meetings (notes, transcripts, audio) are kept in their folder either way.',
                mbConfirmation, MB_YESNO) = IDYES then
        DelTree(Data, True, True, True);
  end;
end;
