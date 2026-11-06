using System.Text.Json;
using System.Text.Json.Serialization;

namespace MeetingNotes.Core;

public enum NotesProvider { Claude, Codex, Ollama }

/// The app's settings, stored as JSON in %LOCALAPPDATA%\MeetingNotes\settings.json.
/// The keys match the Mac app's UserDefaults keys (myName, outputDir, notesProvider…).
public sealed class AppSettings
{
    public string MyName { get; set; } = DefaultName();
    public string Language { get; set; } = "auto";     // auto, sv, da, en
    public bool AutoDetect { get; set; } = true;
    public bool AutoStart { get; set; }
    public bool AutoStop { get; set; } = true;
    public bool KeepAudio { get; set; } = true;
    public string OutputDir { get; set; } = AppPaths.DefaultMeetingsDir;
    public List<string> IgnoredApps { get; set; } = new();
    public string ClaudePath { get; set; } = "";
    public string CodexPath { get; set; } = "";
    public string OllamaModel { get; set; } = Ollama.DefaultModel;
    public string OllamaUrl { get; set; } = Ollama.DefaultUrl;
    public string NotesProvider { get; set; } = "claude";
    /// Empty means the default instructions.
    public string NotesInstructions { get; set; } = "";
    public string PromptStyle { get; set; } = "notification";   // "notification" or "panel"
    public bool SetupDone { get; set; }
    public bool LoginItemOffered { get; set; }

    [JsonIgnore]
    public NotesProvider Provider
    {
        get => ProviderInfo.Parse(NotesProvider);
        set => NotesProvider = ProviderInfo.Id(value);
    }

    [JsonIgnore]
    public string Instructions => string.IsNullOrWhiteSpace(NotesInstructions)
        ? Prompt.DefaultInstructions
        : NotesInstructions.Trim();

    [JsonIgnore]
    public string MeetingsDir
    {
        get
        {
            try { return AppPaths.Expand(string.IsNullOrWhiteSpace(OutputDir) ? AppPaths.DefaultMeetingsDir : OutputDir); }
            catch { return AppPaths.DefaultMeetingsDir; }
        }
    }

    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static AppSettings Load(string? path = null)
    {
        path ??= AppPaths.SettingsFile;
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), JsonOptions) ?? new AppSettings();
        }
        catch (Exception e)
        {
            AppPaths.Log($"settings unreadable, using defaults: {e.Message}");
        }
        return new AppSettings();
    }

    public void Save(string? path = null)
    {
        path ??= AppPaths.SettingsFile;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, JsonOptions));
        File.Move(tmp, path, overwrite: true);
    }

    public AppSettings Clone() =>
        JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(this, JsonOptions), JsonOptions)!;

    static string DefaultName()
    {
        var user = Environment.UserName;
        if (string.IsNullOrWhiteSpace(user)) return "Me";
        var first = user.Split(' ', '.', '_')[0];
        return first.Length == 0 ? "Me" : char.ToUpperInvariant(first[0]) + first[1..];
    }
}
