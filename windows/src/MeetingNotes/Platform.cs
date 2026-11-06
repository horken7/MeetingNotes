using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using MeetingNotes.Core;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace MeetingNotes;

/// Which apps are using the microphone, from the registry Windows keeps for the privacy indicator.
static class MicMonitor
{
    static readonly Dictionary<string, string?> Descriptions = new(StringComparer.OrdinalIgnoreCase);

    public static List<MicUsageEntry> ReadRegistry()
    {
        var entries = new List<MicUsageEntry>();
        using var root = Registry.CurrentUser.OpenSubKey(MicUsage.RegistryPath);
        if (root == null) return entries;
        void Read(RegistryKey parent, string name, bool nonPackaged)
        {
            using var key = parent.OpenSubKey(name);
            if (key == null) return;
            entries.Add(new MicUsageEntry(name, nonPackaged, AsLong(key.GetValue("LastUsedTimeStart")), AsLong(key.GetValue("LastUsedTimeStop"))));
        }
        foreach (var name in root.GetSubKeyNames())
        {
            if (name == "NonPackaged")
            {
                using var np = root.OpenSubKey(name);
                if (np == null) continue;
                foreach (var app in np.GetSubKeyNames()) Read(np, app, true);
            }
            else Read(root, name, false);
        }
        return entries;
    }

    static long AsLong(object? v) => v switch { long l => l, int i => i, _ => -1 };

    public static List<MicUser> Users()
    {
        try
        {
            return MicUsage.ActiveUsers(ReadRegistry(), Environment.ProcessPath, IsRunning, Describe);
        }
        catch (Exception e)
        {
            AppPaths.Log($"mic monitor: {e.Message}");
            return new();
        }
    }

    static bool IsRunning(string exe)
    {
        var name = Path.GetFileNameWithoutExtension(exe);
        var ps = Process.GetProcessesByName(name);
        var running = ps.Length > 0;
        foreach (var p in ps) p.Dispose();
        return running;
    }

    static string? Describe(string exe)
    {
        lock (Descriptions)
        {
            if (Descriptions.TryGetValue(exe, out var d)) return d;
            try { d = FileVersionInfo.GetVersionInfo(exe).FileDescription; } catch { d = null; }
            Descriptions[exe] = d;
            return d;
        }
    }

    /// Is the app playing sound (a call app muted in-app may close the mic but keeps playing)?
    public static bool IsPlaying(MicUser user)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
            var sessions = device.AudioSessionManager.Sessions;
            for (var i = 0; i < sessions.Count; i++)
            {
                var s = sessions[i];
                if (s.State != AudioSessionState.AudioSessionStateActive) continue;
                if (ProcessPath((int)s.GetProcessID) is { } path && MicUsage.MatchesProcess(user, path)) return true;
            }
        }
        catch (Exception e)
        {
            AppPaths.Log($"audio sessions: {e.Message}");
        }
        return false;
    }

    public static string? ProcessPath(int pid)
    {
        if (pid <= 0) return null;
        var h = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            var sb = new StringBuilder(1024);
            var size = sb.Capacity;
            return Native.QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : null;
        }
        finally
        {
            Native.CloseHandle(h);
        }
    }

    /// "Let desktop apps access your microphone" (and microphone access as a whole) in Windows Settings.
    public static bool DesktopAccessAllowed()
    {
        static string? Value(string sub)
        {
            using var k = Registry.CurrentUser.OpenSubKey(sub);
            return k?.GetValue("Value") as string;
        }
        return Value(MicUsage.RegistryPath) != "Deny" && Value(MicUsage.RegistryPath + @"\NonPackaged") != "Deny";
    }
}

/// The meeting name from the call app's window titles.
static class WindowTitles
{
    public static List<string> Titles(MicUser user)
    {
        var titles = new List<string>();
        var paths = new Dictionary<uint, string?>();
        Native.EnumWindows((hwnd, _) =>
        {
            if (!Native.IsWindowVisible(hwnd)) return true;
            var length = Native.GetWindowTextLength(hwnd);
            if (length == 0) return true;
            Native.GetWindowThreadProcessId(hwnd, out var pid);
            if (!paths.TryGetValue(pid, out var path)) paths[pid] = path = MicMonitor.ProcessPath((int)pid);
            if (path == null || !MicUsage.MatchesProcess(user, path)) return true;
            var sb = new StringBuilder(length + 1);
            Native.GetWindowText(hwnd, sb, sb.Capacity);
            titles.Add(sb.ToString());
            return true;
        }, IntPtr.Zero);
        return titles;
    }

    public static string? MeetingName(MicUser user)
    {
        try { return CallInfo.FromWindowTitles(Titles(user)); }
        catch (Exception e)
        {
            AppPaths.Log($"window titles: {e.Message}");
            return null;
        }
    }
}

/// "Start at login" as a Run entry for the current user (no admin needed).
static class LoginItem
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "MeetingNotes";

    public static bool Enabled
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(Name) is string s && s.Length > 0;
        }
    }

    public static void Set(bool on)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) k.SetValue(Name, $"\"{Environment.ProcessPath}\" --background");
        else k.DeleteValue(Name, false);
    }
}

static class Shell
{
    public static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception e) { AppPaths.Log($"open {target}: {e.Message}"); }
    }

    public static void ShowInExplorer(string path) =>
        Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { "/select,", path }, UseShellExecute = false });

    /// Opens a console window that runs a command and stays open (for installers and sign-in).
    public static void Console(string command, string? workingDir = null)
    {
        var psi = new ProcessStartInfo(Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe")
        {
            UseShellExecute = true,
            Arguments = "/k " + command,
            WorkingDirectory = workingDir ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };
        Process.Start(psi);
    }

    /// Runs a PowerShell command in a visible window that stays open afterwards.
    public static void PowerShell(string command)
    {
        var psi = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = true,
            Arguments = $"-NoProfile -ExecutionPolicy Bypass -NoExit -Command \"{command}\"",
        };
        Process.Start(psi);
    }

    public static void MoveToRecycleBin(string folder) =>
        Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(folder,
            Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
}

/// Tells the recorder when the default microphone or speakers change (e.g. a headset is plugged in).
sealed class DeviceWatcher : IMMNotificationClient, IDisposable
{
    readonly MMDeviceEnumerator enumerator = new();
    readonly Action onChange;
    bool registered;

    public DeviceWatcher(Action onChange)
    {
        this.onChange = onChange;
        registered = enumerator.RegisterEndpointNotificationCallback(this) == 0;
    }

    public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
    {
        if (role == Role.Console) onChange();
    }

    public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
    public void OnDeviceAdded(string pwstrDeviceId) { }
    public void OnDeviceRemoved(string deviceId) { }
    public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }

    public void Dispose()
    {
        if (registered) enumerator.UnregisterEndpointNotificationCallback(this);
        registered = false;
        enumerator.Dispose();
    }
}

static class Native
{
    public const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
}
