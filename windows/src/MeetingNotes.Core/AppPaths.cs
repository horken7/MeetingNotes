namespace MeetingNotes.Core;

/// Where the app keeps its files. Models and settings live in %LOCALAPPDATA%\MeetingNotes; the meetings
/// themselves go in Documents\Meetings unless changed in Settings.
public static class AppPaths
{
    public const string ModelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin";
    public const string VadModelUrl = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin";

    /// MEETINGNOTES_DATA overrides the data folder (used by the tests).
    public static string DataDir
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("MEETINGNOTES_DATA");
            if (!string.IsNullOrWhiteSpace(env)) return env;
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MeetingNotes");
        }
    }

    public static string SettingsFile => Path.Combine(DataDir, "settings.json");
    public static string Model => Path.Combine(DataDir, "ggml-large-v3-turbo.bin");
    public static string VadModel => Path.Combine(DataDir, "ggml-silero-v5.1.2.bin");
    public static bool ModelInstalled => File.Exists(Model);
    public static string McpExtension => Path.Combine(DataDir, "MeetingNotes.mcpb");
    public static string LogFile => Path.Combine(DataDir, "log.txt");

    /// The install folder (next to MeetingNotes.exe).
    public static string AppDir => AppContext.BaseDirectory;
    public static string Whisper => Path.Combine(AppDir, "whisper", "whisper-cli.exe");
    public static string McpServer => Path.Combine(AppDir, "meetingnotes-mcp.exe");
    public static string Icon => Path.Combine(AppDir, "icon.png");

    public static string DefaultMeetingsDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Meetings");

    /// "~\Meetings" and "%USERPROFILE%\Meetings" style paths, made absolute.
    public static string Expand(string path)
    {
        var p = Environment.ExpandEnvironmentVariables(path.Trim());
        if (p == "~" || p.StartsWith("~/") || p.StartsWith("~\\"))
            p = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), p.Length > 2 ? p[2..] : "");
        return Path.GetFullPath(p);
    }

    public static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(DataDir);
            var info = new FileInfo(LogFile);
            if (info.Exists && info.Length > 1_000_000) info.Delete();
            File.AppendAllText(LogFile, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}\n");
        }
        catch
        {
            // Logging must never break anything.
        }
    }
}
