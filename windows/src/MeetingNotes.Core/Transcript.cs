using System.Globalization;
using System.Text;
using System.Text.Json;

namespace MeetingNotes.Core;

public static class Format
{
    /// "4:05", or "1:02:03" from an hour on (as in the Mac app).
    public static string Duration(double seconds)
    {
        var t = Math.Max(0, (int)seconds);
        return t >= 3600
            ? $"{t / 3600}:{t / 60 % 60:00}:{t % 60:00}"
            : $"{t / 60}:{t % 60:00}";
    }
}

/// Track names, noise filtering, whisper output and the merged transcript (same rules as src/Pipeline.swift).
public static class Transcript
{
    /// The raw capture, at the device's sample rate; converted to "<track>.wav" (16 kHz mono) before transcribing.
    public const string CaptureExtension = ".capture.wav";

    /// "me" or "others" for a track name ("me", "others", "me-1"…), null for other files.
    public static string? Speaker(string track)
    {
        foreach (var s in new[] { "me", "others" })
        {
            if (track == s) return s;
            if (track.StartsWith(s + "-") && int.TryParse(track.AsSpan(s.Length + 1), NumberStyles.None, CultureInfo.InvariantCulture, out _))
                return s;
        }
        return null;
    }

    /// "me.capture.wav" -> "me", "others-1.wav" -> "others-1", "me.caf" -> "me".
    public static string TrackName(string file)
    {
        var name = file.Replace('\\', '/').Split('/')[^1];
        if (name.EndsWith(CaptureExtension, StringComparison.OrdinalIgnoreCase)) return name[..^CaptureExtension.Length];
        return Path.GetFileNameWithoutExtension(name);
    }

    /// The recorded tracks: "me" and "others", plus "me-1", "others-1"… for segments from before capture
    /// was restarted mid-meeting.
    public static List<string> Tracks(string folder) =>
        Store.AudioFiles(folder).Select(TrackName).Where(t => Speaker(t) != null)
            .Distinct().OrderBy(t => t, StringComparer.Ordinal).ToList();

    public static bool IsNoise(string t)
    {
        if (t.Length == 0) return true;
        if ((t.StartsWith('[') && t.EndsWith(']')) || (t.StartsWith('(') && t.EndsWith(')')) || (t.StartsWith('*') && t.EndsWith('*')))
            return true;
        return t.EnumerateRunes().All(r => Rune.IsWhiteSpace(r) || Rune.IsPunctuation(r) || Rune.IsSymbol(r));
    }

    public static string Merge(IEnumerable<(double Time, string Text)> me, IEnumerable<(double Time, string Text)> others, string myName)
    {
        var rows = me.Select(x => (x.Time, Who: myName, x.Text))
            .Concat(others.Select(x => (x.Time, Who: "Others", x.Text)))
            .OrderBy(x => x.Time)
            .ToList();
        var lines = new List<string>();
        string? last = null;
        foreach (var (t, who, text) in rows)
        {
            if (who == last && lines.Count > 0)
                lines[^1] += " " + text;
            else
            {
                lines.Add($"[{Format.Duration(t)}] **{who}:** {text}");
                last = who;
            }
        }
        return string.Join("\n\n", lines);
    }

    /// Segments from whisper-cli's `-oj` output, shifted by the track's start offset; noise left out.
    public static List<(double Time, string Text)> ParseWhisperJson(byte[] raw, double offset)
    {
        // whisper can emit broken UTF-8; decoding replaces it instead of failing.
        var text = new UTF8Encoding(false, false).GetString(raw);
        using var doc = JsonDocument.Parse(text);
        if (!doc.RootElement.TryGetProperty("transcription", out var items) || items.ValueKind != JsonValueKind.Array)
            throw new PipelineException("Couldn't read the transcription output.");
        var segments = new List<(double, string)>();
        foreach (var item in items.EnumerateArray())
        {
            var t = item.TryGetProperty("text", out var tx) && tx.ValueKind == JsonValueKind.String ? tx.GetString()!.Trim() : "";
            if (IsNoise(t)) continue;
            double fromMs = 0;
            if (item.TryGetProperty("offsets", out var o) && o.TryGetProperty("from", out var f) && f.ValueKind == JsonValueKind.Number)
                fromMs = f.GetDouble();
            segments.Add((fromMs / 1000 + offset, t));
        }
        return segments;
    }

    /// Each track's start relative to the earliest one, in seconds.
    public static Dictionary<string, double> Offsets(Dictionary<string, double> starts)
    {
        if (starts.Count == 0) return new();
        var first = starts.Values.Min();
        return starts.ToDictionary(kv => kv.Key, kv => Math.Max(0, kv.Value - first));
    }
}

public sealed class PipelineException(string message) : Exception(message);

public static class Prompt
{
    /// The default "how the notes should look" instructions, editable in Settings.
    public const string DefaultInstructions =
        "Write the notes in the main language spoken in the meeting (translate the section headings too), as Markdown with these sections:\n" +
        "## Summary (3 to 5 sentences)\n" +
        "## Decisions\n" +
        "## Action items (who, what, deadline if mentioned)\n" +
        "## Open questions\n" +
        "## Key points (grouped by topic)\n" +
        "\n" +
        "Be concise and concrete. Only include what the transcript supports; leave out a section if it would be empty.\n" +
        "Use headings and bullet lists only, no tables. Never use en dashes or em dashes.";

    /// The fixed context (who is who, title) plus the editable instructions from Settings.
    public static string NotesPrompt(Meta meta, string myName, string instructions) =>
        $"You are writing meeting notes for {myName}. In the transcript, lines marked \"{myName}\" are {myName} and lines marked \"Others\" are the other people on the call (possibly several people).\n" +
        "The transcript comes from automatic speech recognition and contains errors; fix obvious mistakes from context.\n" +
        $"Meeting title: {meta.Title}{(meta.App != null ? "\nCall app: " + meta.App : "")}\n" +
        "\n" +
        $"{instructions}\n" +
        "\n" +
        "Output only the notes.";

    /// Recognizes "not logged in" / "session expired" failures from Claude Code and Codex.
    public static bool IsLoginError(string text)
    {
        var t = text.ToLowerInvariant();
        return new[] { "failed to authenticate", "oauth", "/login", "not logged in", "invalid api key",
                       "401 unauthorized", "authentication_error", "please run codex login" }.Any(t.Contains);
    }

    /// First paragraph of the notes (the summary), shortened for the notification.
    public static string? Summary(string notes)
    {
        var line = notes.Replace("\r\n", "\n").Split('\n').Select(l => l.Trim())
            .FirstOrDefault(l => l.Length > 0 && !l.StartsWith('#'));
        if (line == null) return null;
        if (line.StartsWith("- ") || line.StartsWith("* ")) line = line[2..];
        line = line.Replace("**", "");
        return line.Length > 180 ? line[..179] + "…" : line;
    }
}

public static class TextSearch
{
    const CompareOptions Options = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;
    static CompareInfo Compare => CultureInfo.InvariantCulture.CompareInfo;

    /// True when every word of the query appears somewhere in the text (in any order).
    public static bool Matches(string query, string text) =>
        query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .All(w => Compare.IndexOf(text, w, Options) >= 0);

    /// Every occurrence of the query in the text (start, length), case- and accent-insensitive.
    public static List<(int Start, int Length)> Ranges(string query, string text)
    {
        var result = new List<(int, int)>();
        if (query.Length == 0) return result;
        var from = 0;
        while (from < text.Length)
        {
            var i = Compare.IndexOf(text.AsSpan(from), query.AsSpan(), Options, out var length);
            if (i < 0 || length == 0) break;
            result.Add((from + i, length));
            from += i + length;
        }
        return result;
    }
}
