using System.Text.RegularExpressions;

namespace MeetingNotes.Core;

/// An app that is using the microphone.
/// `Key` is the app's registry key name (a package family name, or the exe path with '#' for '\'), which is
/// what "Never for this app" stores.
public sealed record MicUser(string Key, string Name, string? ExePath, bool Packaged);

/// One app's entry under HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone
/// (or its NonPackaged subkey for desktop apps). Windows sets LastUsedTimeStop to 0 while the app has the mic open.
public sealed record MicUsageEntry(string KeyName, bool NonPackaged, long LastUsedTimeStart, long LastUsedTimeStop);

public static class MicUsage
{
    public const string RegistryPath = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    /// Windows' own voice features (Cortana, voice access, live captions) aren't calls.
    static readonly string[] SystemPackages =
    {
        "Microsoft.549981C3F5F10", "Microsoft.Windows.Cortana", "MicrosoftWindows.Client.CBS", "MicrosoftWindows.Client.Core",
        "Microsoft.Windows.ShellExperienceHost", "MicrosoftWindows.LKG", "Microsoft.Windows.CloudExperienceHost",
    };

    static readonly Dictionary<string, string> KnownExes = new(StringComparer.OrdinalIgnoreCase)
    {
        ["chrome"] = "Google Chrome", ["msedge"] = "Microsoft Edge", ["firefox"] = "Firefox", ["brave"] = "Brave",
        ["opera"] = "Opera", ["vivaldi"] = "Vivaldi", ["arc"] = "Arc", ["zoom"] = "Zoom", ["ms-teams"] = "Microsoft Teams",
        ["teams"] = "Microsoft Teams (classic)", ["slack"] = "Slack", ["discord"] = "Discord", ["webex"] = "Webex",
        ["ciscocollabhost"] = "Webex", ["atmgr"] = "Webex", ["skype"] = "Skype", ["whatsapp"] = "WhatsApp",
        ["signal"] = "Signal", ["telegram"] = "Telegram", ["gotomeeting"] = "GoTo Meeting", ["g2mcomm"] = "GoTo Meeting",
    };

    static readonly Dictionary<string, string> KnownPackages = new(StringComparer.OrdinalIgnoreCase)
    {
        ["MSTeams"] = "Microsoft Teams", ["MicrosoftTeams"] = "Microsoft Teams (classic)", ["Microsoft.SkypeApp"] = "Skype",
        ["5319275A.WhatsAppDesktop"] = "WhatsApp", ["Microsoft.WindowsSoundRecorder"] = "Sound Recorder",
        ["Microsoft.WindowsCamera"] = "Camera", ["Zoom.Zoom"] = "Zoom", ["Microsoft.Teams"] = "Microsoft Teams",
    };

    /// "C:#Program Files#Google#Chrome#Application#chrome.exe" -> "C:\Program Files\Google\Chrome\Application\chrome.exe".
    public static string ExePath(string keyName) => keyName.Replace('#', '\\');

    /// The apps that have the mic open right now. `isRunning` filters out entries left at 0 by an app that crashed;
    /// `describe` gives a desktop app's friendly name from its exe (file description), when known.
    public static List<MicUser> ActiveUsers(IEnumerable<MicUsageEntry> entries, string? ownExe = null,
                                            Func<string, bool>? isRunning = null, Func<string, string?>? describe = null)
    {
        var result = new List<MicUser>();
        foreach (var e in entries)
        {
            if (e.LastUsedTimeStop != 0 || e.LastUsedTimeStart == 0) continue;
            if (e.NonPackaged)
            {
                var exe = ExePath(e.KeyName);
                if (ownExe != null && string.Equals(exe, ownExe, StringComparison.OrdinalIgnoreCase)) continue;
                if (IsWindowsComponent(exe)) continue;
                if (isRunning != null && !isRunning(exe)) continue;
                result.Add(new MicUser(e.KeyName, DesktopName(exe, describe), exe, false));
            }
            else
            {
                if (SystemPackages.Any(p => e.KeyName.StartsWith(p, StringComparison.OrdinalIgnoreCase))) continue;
                result.Add(new MicUser(e.KeyName, PackageName(e.KeyName), null, true));
            }
        }
        // The most recently started first, like the newest call.
        return result
            .OrderByDescending(u => entries.First(x => x.KeyName == u.Key).LastUsedTimeStart)
            .ToList();
    }

    /// Is this process (by its exe path) the app? Desktop apps match by path; packaged apps by their install folder,
    /// "…\WindowsApps\MSTeams_25031.805.3440.5290_x64__8wekyb3d8bbwe\ms-teams.exe" for "MSTeams_8wekyb3d8bbwe".
    public static bool MatchesProcess(MicUser user, string processPath)
    {
        if (!user.Packaged) return string.Equals(user.ExePath, processPath, StringComparison.OrdinalIgnoreCase);
        var us = user.Key.IndexOf('_');
        if (us <= 0) return false;
        var name = user.Key[..us];
        var publisher = user.Key[(us + 1)..];
        return processPath.Split('\\', '/').Any(seg =>
            seg.StartsWith(name + "_", StringComparison.OrdinalIgnoreCase) &&
            seg.EndsWith("__" + publisher, StringComparison.OrdinalIgnoreCase));
    }

    static bool IsWindowsComponent(string exe)
    {
        var win = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        return exe.StartsWith(win.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)
            || exe.StartsWith(@"C:\Windows\", StringComparison.OrdinalIgnoreCase);
    }

    public static string DesktopName(string exe, Func<string, string?>? describe = null)
    {
        var file = System.IO.Path.GetFileNameWithoutExtension(exe.Replace('\\', '/').Split('/').Last());
        if (KnownExes.TryGetValue(file, out var known)) return known;
        var described = describe?.Invoke(exe);
        if (!string.IsNullOrWhiteSpace(described)) return described.Trim();
        return file.Length == 0 ? "An app" : char.ToUpperInvariant(file[0]) + file[1..];
    }

    /// "MSTeams_8wekyb3d8bbwe" -> "Microsoft Teams"; "Contoso.CallApp_abc" -> "CallApp".
    public static string PackageName(string familyName)
    {
        var name = familyName.Split('_')[0];
        if (KnownPackages.TryGetValue(name, out var known)) return known;
        var last = name.Split('.').Last();
        return last.Length == 0 ? "An app" : last;
    }
}

/// The meeting's name from the call window's title (e.g. "Meet – Weekly sync - Google Chrome" -> "Weekly sync").
/// Windows has no AppleScript for browser tabs, so this reads window titles: the call tab's title is in the title
/// of its browser window while that tab is showing.
public static class CallInfo
{
    static readonly string[] BrowserSuffixes =
    {
        " - Google Chrome", " - Microsoft\u200b Edge", " - Microsoft Edge", " — Mozilla Firefox", " - Mozilla Firefox",
        " - Brave", " - Opera", " - Vivaldi", " - Arc", " - Chromium",
    };

    static readonly string[] CallPrefixes = { "Meet – ", "Meet - ", "Google Meet – ", "Google Meet - " };
    static readonly string[] CallSuffixes = { " | Microsoft Teams", " - Microsoft Teams", " - Zoom", " | Zoom", " - Google Meet", " | Whereby", " - Jitsi Meet" };

    /// "Meet – Weekly sync" -> "Weekly sync"; "Meet - abc-defg-hij" and other generic titles -> null.
    public static string? CleanTitle(string raw)
    {
        var t = raw.Trim();
        t = Regex.Replace(t, @"^\(\d+\)\s*", "");   // "(2) " unread badge
        foreach (var prefix in CallPrefixes)
            if (t.StartsWith(prefix, StringComparison.Ordinal)) t = t[prefix.Length..];
        foreach (var suffix in CallSuffixes)
            if (t.EndsWith(suffix, StringComparison.Ordinal)) t = t[..^suffix.Length];
        t = t.Trim();
        if (Regex.IsMatch(t, "^[a-z]{3}-[a-z]{4}-[a-z]{3}$")) return null;   // Meet code
        var generic = new[] { "", "Meet", "Google Meet", "Microsoft Teams", "Teams", "Zoom", "Whereby", "Jitsi Meet",
                              "Calendar", "Chat", "Activity", "Meeting", "Zoom Meeting", "Zoom Workplace" };
        return generic.Contains(t) ? null : t;
    }

    /// The meeting name in a window title, or null when the window isn't a call (or the title is generic).
    public static string? FromWindowTitle(string title)
    {
        var t = title.Trim();
        foreach (var suffix in BrowserSuffixes)
        {
            var i = t.LastIndexOf(suffix, StringComparison.Ordinal);
            if (i > 0) { t = t[..i]; break; }   // also drops a profile name after it ("… - Google Chrome - Work")
        }
        // Edge adds the profile ("Meet – Sync - Personal - Microsoft Edge") and "and 2 more pages".
        t = Regex.Replace(t, @" - (Personal|Work|Profile \d+)$", "");
        t = Regex.Replace(t, @" and \d+ more pages?$", "");
        var isCall = CallPrefixes.Any(p => Regex.Replace(t, @"^\(\d+\)\s*", "").StartsWith(p, StringComparison.Ordinal))
            || CallSuffixes.Any(s => t.EndsWith(s, StringComparison.Ordinal));
        return isCall ? CleanTitle(t) : null;
    }

    public static string? FromWindowTitles(IEnumerable<string> titles) =>
        titles.Select(FromWindowTitle).FirstOrDefault(n => n != null);
}
