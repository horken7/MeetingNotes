using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace MeetingNotes.Core;

public static class ProviderInfo
{
    public static readonly NotesProvider[] All = { NotesProvider.BuiltIn, NotesProvider.Claude, NotesProvider.Codex, NotesProvider.Ollama };

    /// Unknown ids are Claude Code, the only provider older versions had by default.
    public static NotesProvider Parse(string? id) => id switch
    {
        "builtin" => NotesProvider.BuiltIn,
        "codex" => NotesProvider.Codex,
        "ollama" => NotesProvider.Ollama,
        _ => NotesProvider.Claude,
    };

    public static string Id(NotesProvider p) => p switch
    {
        NotesProvider.BuiltIn => "builtin",
        NotesProvider.Codex => "codex",
        NotesProvider.Ollama => "ollama",
        _ => "claude",
    };

    public static string Label(NotesProvider p) => p switch
    {
        NotesProvider.BuiltIn => "Built-in (Gemma 3 4B, on this PC)",
        NotesProvider.Codex => "Codex (OpenAI)",
        NotesProvider.Ollama => "Local model (Ollama)",
        _ => "Claude Code",
    };

    public static string LoginHint(NotesProvider p) => p switch
    {
        NotesProvider.BuiltIn => "No account and nothing to set up: the model comes with Meeting Notes and runs on this PC.",
        NotesProvider.Codex => "Sign in once with the Sign in button under Settings > Setup (it runs `codex login`).",
        NotesProvider.Ollama => $"No account needed. Install Ollama from ollama.com, then download the model ({Ollama.DefaultModel} by default) under Settings > Setup.",
        _ => "Sign in once with the Sign in button under Settings > Setup (it runs `claude auth login`).",
    };

    public static string ReloginHint(NotesProvider p) => p switch
    {
        NotesProvider.BuiltIn => "Reinstall Meeting Notes if the built-in model is missing.",
        NotesProvider.Codex => "Open Settings > Setup and press Sign in (or run `codex login` in a terminal).",
        NotesProvider.Ollama => "Start Ollama from the Start menu.",
        _ => "Open Settings > Setup and press Sign in (or run `claude auth login` in a terminal).",
    };
}

public sealed record RunResult(int Status, string Out, string Err);

public interface IProcessRunner
{
    Task<RunResult> RunAsync(string exe, IReadOnlyList<string> args, string? input = null, string? cwd = null,
                             CancellationToken cancel = default);
}

/// Finds the external programs and runs them without a console window.
public static class Tools
{
    static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    static string AppData => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    static string LocalAppData => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    /// Folders where the official installers put the CLIs, searched before PATH.
    public static IEnumerable<string> ExtraDirs()
    {
        yield return Path.Combine(Home, ".local", "bin");                   // Claude Code native installer
        yield return Path.Combine(AppData, "npm");                          // npm install -g
        yield return Path.Combine(LocalAppData, "Programs", "Ollama");      // OllamaSetup.exe
        yield return Path.Combine(LocalAppData, "Microsoft", "WinGet", "Links");
        yield return Path.Combine(Home, ".claude", "local");
    }

    /// The current PATH, plus the user and machine PATH from the registry: a CLI installed while the app runs
    /// is only in the registry, not in this process's environment.
    public static List<string> SearchPath()
    {
        var parts = new List<string>();
        void Add(string? value)
        {
            if (string.IsNullOrEmpty(value)) return;
            foreach (var p in value.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                string dir;
                try { dir = Environment.ExpandEnvironmentVariables(p.Trim('"')); } catch { continue; }
                if (!parts.Contains(dir, StringComparer.OrdinalIgnoreCase)) parts.Add(dir);
            }
        }
        foreach (var d in ExtraDirs()) Add(d);
        if (OperatingSystem.IsWindows())
        {
            Add(Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User));
            Add(Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Machine));
        }
        Add(Environment.GetEnvironmentVariable("PATH"));
        return parts;
    }

    public static string? Find(string name, string? preferred = null)
    {
        if (!string.IsNullOrWhiteSpace(preferred))
        {
            var p = preferred.Trim().Trim('"');
            if (File.Exists(p)) return p;
        }
        var exts = OperatingSystem.IsWindows() ? new[] { ".exe", ".cmd", ".bat" } : new[] { "" };
        foreach (var dir in SearchPath())
            foreach (var ext in exts)
            {
                var candidate = Path.Combine(dir, name + ext);
                if (File.Exists(candidate)) return candidate;
            }
        return null;
    }

    public static string? Executable(NotesProvider p, AppSettings s) => p switch
    {
        NotesProvider.Claude => Find("claude", s.ClaudePath),
        NotesProvider.Codex => Find("codex", s.CodexPath),
        _ => null,
    };

    public static bool OllamaInstalled =>
        Find("ollama") != null || File.Exists(Path.Combine(LocalAppData, "Programs", "Ollama", "ollama app.exe"));

    public static string? Node => Find("node");

    /// The environment for child processes: a fresh PATH and no ANTHROPIC_API_KEY, so Claude Code always uses the
    /// Claude subscription rather than API billing.
    public static Dictionary<string, string> ChildEnvironment(string? exeDir = null)
    {
        var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry e in System.Environment.GetEnvironmentVariables())
            env[(string)e.Key] = (string?)e.Value ?? "";
        env.Remove("ANTHROPIC_API_KEY");
        var path = SearchPath();
        if (exeDir != null) path.Insert(0, exeDir);   // npm-installed CLIs need node.exe beside their launcher
        env["PATH"] = string.Join(Path.PathSeparator, path);
        return env;
    }

    /// npm's `.cmd` launchers can't take a multi-line argument (cmd.exe ends the command at the first newline),
    /// so run the script they point to with node directly. Returns null when the file isn't an npm shim.
    public static (string Exe, List<string> Args)? ResolveNpmShim(string shimPath, string shimText, Func<string?>? findNode = null)
    {
        var dir = Path.GetDirectoryName(shimPath) ?? "";
        var m = Regex.Matches(shimText, "\"%(?:~)?dp0%?\\\\?([^\"]+\\.(?:js|mjs|cjs|exe))\"", RegexOptions.IgnoreCase)
            .FirstOrDefault(x => !x.Groups[1].Value.EndsWith("node.exe", StringComparison.OrdinalIgnoreCase));
        if (m == null) return null;
        var relative = m.Groups[1].Value.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        var target = Path.GetFullPath(Path.Combine(new[] { dir }.Concat(relative).ToArray()));
        if (target.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return (target, new List<string>());
        var node = Path.Combine(dir, "node.exe");
        if (!File.Exists(node)) node = (findNode ?? (() => Node))() ?? "node";
        return (node, new List<string> { target });
    }
}

public sealed class ProcessRunner : IProcessRunner
{
    public static readonly ProcessRunner Shared = new();

    public async Task<RunResult> RunAsync(string exe, IReadOnlyList<string> args, string? input = null, string? cwd = null,
                                          CancellationToken cancel = default)
    {
        var file = exe;
        var allArgs = new List<string>(args);
        if (exe.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || exe.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))
        {
            string text = "";
            try { text = await File.ReadAllTextAsync(exe, cancel); } catch { }
            if (Tools.ResolveNpmShim(exe, text) is { } shim)
            {
                file = shim.Exe;
                allArgs.InsertRange(0, shim.Args);
            }
            else
            {
                file = System.Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
                allArgs.InsertRange(0, new[] { "/d", "/c", exe });
            }
        }
        var psi = new ProcessStartInfo(file)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = input != null,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        if (input != null) psi.StandardInputEncoding = new UTF8Encoding(false);
        foreach (var a in allArgs) psi.ArgumentList.Add(a);
        if (cwd != null) psi.WorkingDirectory = cwd;
        psi.Environment.Clear();
        foreach (var (k, v) in Tools.ChildEnvironment(Path.GetDirectoryName(exe))) psi.Environment[k] = v;

        using var p = new Process { StartInfo = psi };
        try
        {
            if (!p.Start()) return new RunResult(-1, "", $"Couldn't start {exe}");
        }
        catch (Exception e)
        {
            return new RunResult(-1, "", e.Message);
        }
        var outTask = p.StandardOutput.ReadToEndAsync(cancel);
        var errTask = p.StandardError.ReadToEndAsync(cancel);
        if (input != null)
        {
            try
            {
                await p.StandardInput.WriteAsync(input.AsMemory(), cancel);
                p.StandardInput.Close();
            }
            catch (IOException)
            {
                // The process exited before reading everything; its error output says why.
            }
        }
        try
        {
            await p.WaitForExitAsync(cancel);
        }
        catch (OperationCanceledException)
        {
            try { p.Kill(entireProcessTree: true); } catch { }
            throw;
        }
        return new RunResult(p.ExitCode, await outTask, await errTask);
    }
}
