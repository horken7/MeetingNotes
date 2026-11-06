using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MeetingNotes.Core;

/// meta.json, the same format as the Mac app (ISO 8601 dates without fractions, keys sorted, nil fields left out).
public sealed class Meta
{
    [JsonPropertyName("app")] public string? App { get; set; }
    [JsonPropertyName("audioArchived")] public DateTimeOffset? AudioArchived { get; set; }
    [JsonPropertyName("created")] public DateTimeOffset? Created { get; set; }
    [JsonPropertyName("duration")] public double? Duration { get; set; }
    [JsonPropertyName("error")] public string? Error { get; set; }
    [JsonPropertyName("lang")] public string? Lang { get; set; }
    [JsonPropertyName("offsets")] public Dictionary<string, double>? Offsets { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }   // recording, transcribing, summarizing, done, failed
    [JsonPropertyName("title")] public string Title { get; set; } = "";

    public Meta() { }
    public Meta(string title) { Title = title; }
}

/// ISO 8601 like Swift's JSONEncoder `.iso8601`: "2026-01-31T09:30:00Z" (UTC, whole seconds).
public sealed class Iso8601Converter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var s = reader.GetString() ?? throw new JsonException("date expected");
        return DateTimeOffset.Parse(s, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(Format(value));

    public static string Format(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
}

public sealed record Meeting(string Folder, Meta Meta, DateTimeOffset Created, string Status, bool HasAudio)
{
    public string Id => Folder;
    public string Title => Meta.Title;
    public bool IsBusy => Status is "recording" or "transcribing" or "summarizing";
    /// The audio is gone (archived, or not kept), so the transcript can't be redone.
    public bool IsArchived => !HasAudio && !IsBusy;
}

public static class Store
{
    /// The meetings folder; the app sets it from Settings.
    public static string Root { get; set; } = AppPaths.DefaultMeetingsDir;

    static readonly JsonSerializerOptions MetaOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new Iso8601Converter() },
    };

    public static Meta? ReadMeta(string folder)
    {
        try
        {
            var path = Path.Combine(folder, "meta.json");
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<Meta>(File.ReadAllText(path), MetaOptions);
        }
        catch
        {
            return null;
        }
    }

    public static string Serialize(Meta meta)
    {
        // Sorted keys, also inside "offsets", like the Mac app.
        var copy = meta.Offsets == null ? meta : new Meta
        {
            App = meta.App, AudioArchived = meta.AudioArchived, Created = meta.Created, Duration = meta.Duration,
            Error = meta.Error, Lang = meta.Lang, Status = meta.Status, Title = meta.Title,
            Offsets = new SortedDictionary<string, double>(meta.Offsets, StringComparer.Ordinal)
                .ToDictionary(kv => kv.Key, kv => kv.Value),
        };
        return JsonSerializer.Serialize(copy, MetaOptions);
    }

    public static void WriteMeta(Meta meta, string folder)
    {
        try
        {
            var path = Path.Combine(folder, "meta.json");
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, Serialize(meta));
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e)
        {
            AppPaths.Log($"couldn't write meta.json in {folder}: {e.Message}");
        }
    }

    static readonly object MetaLock = new();

    public static void Update(string folder, Action<Meta> change)
    {
        lock (MetaLock)
        {
            var m = ReadMeta(folder) ?? new Meta(Path.GetFileName(folder));
            change(m);
            WriteMeta(m, folder);
        }
    }

    public static Meeting? Load(string dir)
    {
        var meta = ReadMeta(dir);
        if (meta == null) return null;
        DateTimeOffset created = meta.Created ?? SafeCreationTime(dir);
        var status = meta.Status ?? "";
        if (status.Length == 0) status = File.Exists(Path.Combine(dir, "notes.md")) ? "done" : "failed";
        return new Meeting(dir, meta, created, status, AudioFiles(dir).Count > 0);
    }

    static DateTimeOffset SafeCreationTime(string dir)
    {
        try { return new DateTimeOffset(Directory.GetCreationTime(dir)); }
        catch { return DateTimeOffset.MinValue; }
    }

    /// All meetings, newest first.
    public static List<Meeting> LoadAll(string? root = null)
    {
        root ??= Root;
        if (!Directory.Exists(root)) return new();
        IEnumerable<string> dirs;
        try { dirs = Directory.EnumerateDirectories(root).ToList(); }
        catch { return new(); }
        return dirs
            .Where(d => !Path.GetFileName(d).StartsWith('.'))
            .Select(Load)
            .Where(m => m != null)
            .Select(m => m!)
            .OrderByDescending(m => m.Created)
            .ToList();
    }

    /// The meeting's recordings: me/others as .capture.wav while recording, .wav after transcription
    /// (and .caf from a Mac-recorded meeting).
    public static List<string> AudioFiles(string folder)
    {
        try
        {
            return Directory.EnumerateFiles(folder)
                .Where(f => Path.GetExtension(f).ToLowerInvariant() is ".wav" or ".caf")
                .ToList();
        }
        catch
        {
            return new();
        }
    }

    /// Deletes the recordings but keeps the transcript, notes and meta.json.
    public static void ArchiveAudio(string folder)
    {
        foreach (var f in AudioFiles(folder))
        {
            try { File.Delete(f); } catch { }
        }
        Update(folder, m => m.AudioArchived = DateTimeOffset.UtcNow);
    }

    /// Ends a recording segment when capture has to restart mid-meeting: renames its tracks to me-N/others-N
    /// so the next segment can write me/others again, and returns their offsets from the meeting start.
    public static Dictionary<string, double> CloseSegment(string folder, int number, Dictionary<string, double> offsets, double start)
    {
        var result = new Dictionary<string, double>();
        foreach (var (track, offset) in offsets)
        {
            var name = $"{track}-{number}";
            try
            {
                File.Move(Path.Combine(folder, track + Transcript.CaptureExtension),
                          Path.Combine(folder, name + Transcript.CaptureExtension));
                result[name] = start + offset;
            }
            catch (Exception e)
            {
                AppPaths.Log($"couldn't keep segment {name}: {e.Message}");
            }
        }
        return result;
    }

    /// Characters Windows (and the Mac app) don't allow in folder names.
    public static string SafeName(string title)
    {
        var bad = "/:\\?%*|\"<>";
        var chars = title.Where(c => !bad.Contains(c) && !char.IsControl(c)).ToArray();
        var safe = new string(chars).Trim().TrimEnd('.', ' ');
        if (safe.Length > 120) safe = safe[..120].Trim();
        return safe.Length == 0 ? "Meeting" : safe;
    }

    public static string NewFolder(string title, DateTime localDate, string? root = null)
    {
        root ??= Root;
        var stamp = localDate.ToString("yyyy-MM-dd HHmm", CultureInfo.InvariantCulture);
        var safe = SafeName(title);
        var path = Path.Combine(root, $"{stamp} {safe}");
        var n = 2;
        while (Directory.Exists(path) || File.Exists(path))
        {
            path = Path.Combine(root, $"{stamp} {safe} {n}");
            n++;
        }
        Directory.CreateDirectory(path);
        return path;
    }

    /// notes.md or transcript.md without its first "# Title" line (the window shows the title already).
    public static string ReadBody(string folder, string file)
    {
        string text;
        try { text = File.ReadAllText(Path.Combine(folder, file)); }
        catch { return ""; }
        text = text.Replace("\r\n", "\n");
        if (text.StartsWith("# "))
        {
            var nl = text.IndexOf('\n');
            if (nl >= 0) return text[(nl + 1)..].Trim();
        }
        return text;
    }
}
