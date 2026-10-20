import Foundation

/// Finds the meeting's name from the browser tab that holds the call (e.g. "Meet – Weekly sync").
/// Uses AppleScript, so macOS asks once for permission to read the browser's tabs.
enum CallInfo {
    /// Browsers with the Chromium AppleScript dictionary (tabs have `URL` and `title`).
    static let chromium = ["com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser",
                           "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

    static let callSites = ["meet.google.com/", "teams.microsoft.com", "teams.live.com",
                            "zoom.us/wc", "zoom.us/j/", "whereby.com/", "meet.jit.si/"]

    static func meetingName(for user: MicUser) async -> String? {
        let script: String
        if chromium.contains(user.key) {
            script = """
            set out to ""
            set sep to tab -- outside the tell block, where "tab" means a tab character, not a browser tab
            set nl to linefeed
            tell application id "\(user.key)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (URL of t) & sep & (title of t) & nl
                    end repeat
                end repeat
            end tell
            return out
            """
        } else if user.key.hasPrefix("com.apple.WebKit") || user.key == "com.apple.Safari" {
            script = """
            set out to ""
            set sep to tab -- outside the tell block, where "tab" means a tab character, not a browser tab
            set nl to linefeed
            tell application id "com.apple.Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (URL of t) & sep & (name of t) & nl
                    end repeat
                end repeat
            end tell
            return out
            """
        } else {
            return nil
        }
        let r = await runProcess("/usr/bin/osascript", ["-e", script])
        guard r.status == 0 else { return nil }
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, callSites.contains(where: { parts[0].contains($0) }) else { continue }
            if let name = cleanTitle(parts[1]) { return name }
        }
        return nil
    }

    /// "Meet – Weekly sync" -> "Weekly sync"; "Meet - abc-defg-hij" and other generic titles -> nil.
    static func cleanTitle(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }   // "(2) " unread badge
        for prefix in ["Meet – ", "Meet - ", "Google Meet – ", "Google Meet - "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        for suffix in [" | Microsoft Teams", " - Microsoft Teams", " - Zoom", " | Zoom", " - Google Meet", " | Whereby", " - Jitsi Meet"]
        where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil { return nil }   // Meet code
        let generic = ["", "Meet", "Google Meet", "Microsoft Teams", "Teams", "Zoom", "Whereby", "Jitsi Meet",
                       "Calendar", "Chat", "Activity", "Meeting"]
        return generic.contains(t) ? nil : t
    }
}
