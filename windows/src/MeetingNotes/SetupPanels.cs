using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MeetingNotes.Core;

namespace MeetingNotes;

/// Building blocks shared by the setup assistant and Settings > Setup.
static class UI
{
    public static TextBlock Text(string text, double size = 13, bool bold = false, Brush? color = null) => new()
    {
        Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 4),
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, Foreground = color ?? Brushes.Black,
    };

    public static TextBlock Hint(string text) => new() { Text = text, Style = (Style)Application.Current.FindResource("Hint") };

    public static Button Button(string label, Action onClick, bool primary = false)
    {
        var b = new Button { Content = label, Margin = new Thickness(0, 4, 8, 4), HorizontalAlignment = HorizontalAlignment.Left };
        if (primary) b.Style = (Style)Application.Current.FindResource("Primary");
        b.Click += (_, _) => onClick();
        return b;
    }

    public static TextBlock Check(string label, bool? ok) => new()
    {
        Text = (ok switch { true => "✔  ", false => "✖  ", null => "…  " }) + label,
        Foreground = ok switch { true => new SolidColorBrush(Color.FromRgb(46, 125, 50)), false => new SolidColorBrush(Color.FromRgb(198, 40, 40)), null => Brushes.Gray },
        FontSize = 13, Margin = new Thickness(0, 4, 0, 2), TextWrapping = TextWrapping.Wrap,
    };

    public static StackPanel Row(params UIElement[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var c in children) p.Children.Add(c);
        return p;
    }

    public static Border Step(int number, string title, params UIElement[] content)
    {
        var inner = new StackPanel();
        inner.Children.Add(Text($"{number}. {title}", 13.5, bold: true));
        foreach (var c in content) inner.Children.Add(c);
        return new Border
        {
            Child = inner, Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 4, 0, 4), CornerRadius = new CornerRadius(6),
            Background = (Brush)Application.Current.FindResource("Box"),
        };
    }
}

/// Downloads the Whisper speech model (and the voice activity model) with a progress bar.
sealed class ModelPanel : StackPanel
{
    readonly ProgressBar bar = new() { Height = 14, Margin = new Thickness(0, 6, 0, 2), Visibility = Visibility.Collapsed };
    readonly TextBlock status = UI.Hint("");
    readonly Button download;
    CancellationTokenSource? cancel;
    public event Action? Completed;

    public ModelPanel()
    {
        download = UI.Button("Download the speech model (1.6 GB)", Start, primary: true);
        Refresh();
    }

    public bool Installed => AppPaths.ModelInstalled;
    public bool Downloading => cancel != null;

    void Refresh()
    {
        Children.Clear();
        if (Installed && !Downloading)
        {
            Children.Add(UI.Check(AppPaths.ModelBundled ? "Speech model installed" : "Speech model downloaded", true));
            Children.Add(UI.Hint("Whisper large-v3-turbo. Transcription runs on this PC; the audio never leaves it."));
            return;
        }
        Children.Add(UI.Check("Speech model", Downloading ? null : false));
        Children.Add(UI.Hint("Meeting Notes transcribes on this PC with the Whisper large-v3-turbo model. It normally comes with the installer, but isn't in the install folder, so download it once (about 1.6 GB; it continues where it stopped if interrupted), or reinstall Meeting Notes."));
        Children.Add(bar);
        Children.Add(status);
        download.Content = Downloading ? "Cancel" : "Download the speech model (1.6 GB)";
        Children.Add(download);
    }

    public async void Start()
    {
        if (cancel != null)
        {
            cancel.Cancel();
            return;
        }
        cancel = new CancellationTokenSource();
        bar.Visibility = Visibility.Visible;
        bar.IsIndeterminate = true;
        Refresh();
        try
        {
            if (!File.Exists(AppPaths.VadModel))
            {
                status.Text = "Downloading the voice activity model…";
                await Downloads.DownloadAsync(AppPaths.VadModelUrl, AppPaths.DownloadedVadModel, null, cancel.Token);
            }
            var progress = new Progress<(long Done, long? Total)>(p =>
            {
                if (p.Total is { } t && t > 0)
                {
                    bar.IsIndeterminate = false;
                    bar.Value = 100.0 * p.Done / t;
                    status.Text = $"Downloading… {Downloads.Size(p.Done)} of {Downloads.Size(t)}";
                }
                else status.Text = $"Downloading… {Downloads.Size(p.Done)}";
            });
            if (!AppPaths.ModelInstalled) await Downloads.DownloadAsync(AppPaths.ModelUrl, AppPaths.DownloadedModel, progress, cancel.Token);
            status.Text = "";
            cancel = null;
            Refresh();
            Completed?.Invoke();
            AppModel.Shared.Reload();
            return;
        }
        catch (OperationCanceledException)
        {
            status.Text = "Paused. Press Download to continue.";
        }
        catch (Exception e)
        {
            AppPaths.Log($"model download: {e}");
            status.Text = $"The download failed ({e.Message}). Check the internet connection and press Download to continue.";
        }
        cancel = null;
        bar.Visibility = Visibility.Collapsed;
        Refresh();
    }
}

/// How to install and sign in to the selected notes provider, in plain steps with buttons, plus "Check again".
sealed class ProviderPanel : StackPanel
{
    NotesProvider provider;
    readonly TextBlock result = UI.Hint("");
    readonly ProgressBar pullBar = new() { Height = 14, Margin = new Thickness(0, 6, 0, 2), Visibility = Visibility.Collapsed };
    readonly TextBlock pullStatus = UI.Hint("");
    bool checking;
    bool pulling;

    readonly Func<AppSettings> settings;

    public ProviderPanel(NotesProvider provider, Func<AppSettings>? settings = null)
    {
        this.settings = settings ?? (() => AppModel.Shared.Settings);
        Show(provider);
    }

    AppSettings Settings => settings();

    public void Show(NotesProvider p)
    {
        provider = p;
        result.Text = "";
        Build();
        if (p == NotesProvider.Ollama) _ = CheckOllama();
    }

    void Build()
    {
        Children.Clear();
        switch (provider)
        {
            case NotesProvider.Claude: BuildClaude(); break;
            case NotesProvider.Codex: BuildCodex(); break;
            default: BuildOllama(); break;
        }
    }

    static bool GitInstalled =>
        Tools.Find("git") != null || File.Exists(@"C:\Program Files\Git\bin\bash.exe")
        || File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Git", "bin", "bash.exe"));

    void BuildClaude()
    {
        var exe = Tools.Executable(NotesProvider.Claude, Settings);
        Children.Add(UI.Text("Claude Code writes the notes with your Claude account (a Pro or Max plan). Only the text transcript is sent; the audio stays on this PC.", 13));
        Children.Add(UI.Step(1, "Install Git for Windows",
            UI.Hint("Claude Code needs it. Download it, run the installer and keep the suggested options (Next, Next… Install)."),
            UI.Check(GitInstalled ? "Git for Windows is installed" : "Git for Windows not found yet", GitInstalled),
            UI.Button("Download Git for Windows", () => Shell.Open("https://git-scm.com/downloads/win"))));
        Children.Add(UI.Step(2, "Install Claude Code",
            UI.Hint("This opens a blue PowerShell window that runs Claude Code's official installer (from claude.ai). Wait until it says it's installed, then close the window."),
            UI.Check(exe != null ? "Claude Code is installed" : "Claude Code not found yet", exe != null),
            UI.Button("Install Claude Code", () => Shell.PowerShell("irm https://claude.ai/install.ps1 | iex"))));
        Children.Add(UI.Step(3, "Sign in",
            UI.Hint("This opens a window and your browser. Sign in with your Claude account in the browser and allow access. When the window says you're signed in, close it."),
            UI.Button("Sign in to Claude", () => SignIn(exe, " auth login"))));
        AddCheck();
    }

    void BuildCodex()
    {
        var exe = Tools.Executable(NotesProvider.Codex, Settings);
        Children.Add(UI.Text("Codex writes the notes with your ChatGPT account (or an OpenAI API key, which is billed per use). Only the text transcript is sent; the audio stays on this PC.", 13));
        var install = UI.Button(installing ? "Downloading…" : "Install Codex (about 200 MB)", InstallCodex);
        install.IsEnabled = !installing;
        Children.Add(UI.Step(1, "Install Codex",
            UI.Hint("Downloads the official Codex program from OpenAI's GitHub releases into your user folder. No administrator rights needed."),
            UI.Check(exe != null ? "Codex is installed" : "Codex not found yet", exe != null),
            installBar, installStatus, install));
        Children.Add(UI.Step(2, "Sign in",
            UI.Hint("This opens a window that runs `codex login` and your browser. Sign in with ChatGPT in the browser, then close the window."),
            UI.Button("Sign in to Codex", () => SignIn(exe, " login"))));
        AddCheck();
    }

    readonly ProgressBar installBar = new() { Height = 14, Margin = new Thickness(0, 6, 0, 2), Visibility = Visibility.Collapsed };
    readonly TextBlock installStatus = UI.Hint("");
    bool installing;

    /// The standalone Codex for Windows from https://github.com/openai/codex/releases, into %USERPROFILE%\.local\bin.
    async void InstallCodex()
    {
        installing = true;
        installBar.Visibility = Visibility.Visible;
        installBar.IsIndeterminate = true;
        Build();
        var arch = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "aarch64" : "x86_64";
        var asset = $"codex-{arch}-pc-windows-msvc.exe";
        var bin = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin");
        var zip = Path.Combine(Path.GetTempPath(), asset + ".zip");
        try
        {
            await Downloads.DownloadAsync($"https://github.com/openai/codex/releases/latest/download/{asset}.zip", zip,
                new Progress<(long Done, long? Total)>(p =>
                {
                    if (p.Total is { } t && t > 0) { installBar.IsIndeterminate = false; installBar.Value = 100.0 * p.Done / t; }
                    installStatus.Text = $"Downloading… {Downloads.Size(p.Done)}" + (p.Total is { } total ? $" of {Downloads.Size(total)}" : "");
                }));
            await Task.Run(() =>
            {
                Directory.CreateDirectory(bin);
                using var archive = System.IO.Compression.ZipFile.OpenRead(zip);
                var entry = archive.Entries.FirstOrDefault(e => e.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                    ?? throw new IOException("The download has no codex.exe in it.");
                System.IO.Compression.ZipFileExtensions.ExtractToFile(entry, Path.Combine(bin, "codex.exe"), overwrite: true);
            });
            installStatus.Text = "Installed.";
        }
        catch (Exception e)
        {
            AppPaths.Log($"codex install: {e}");
            installStatus.Text = $"Couldn't install Codex ({e.Message}). Check the internet connection and try again.";
        }
        finally
        {
            try { File.Delete(zip); } catch { }
        }
        installing = false;
        installBar.Visibility = Visibility.Collapsed;
        Build();
    }

    void BuildOllama()
    {
        var installed = Tools.OllamaInstalled;
        var model = string.IsNullOrWhiteSpace(Settings.OllamaModel) ? Ollama.DefaultModel : Settings.OllamaModel.Trim();
        Children.Add(UI.Text("A local model writes the notes on this PC with Ollama. Nothing leaves the computer and no account is needed, but it needs about 8 GB of disk and works best with 16 GB of memory.", 13));
        Children.Add(UI.Step(1, "Install Ollama",
            UI.Hint("Download OllamaSetup.exe and run it. Ollama then starts by itself and runs in the background (a llama icon near the clock)."),
            UI.Check(installed ? "Ollama is installed" : "Ollama not found yet", installed),
            UI.Button("Download Ollama", () => Shell.Open("https://ollama.com/download/windows"))));
        var pull = UI.Button(pulling ? "Downloading…" : $"Download {model}", () => Pull(model));
        pull.IsEnabled = !pulling;
        Children.Add(UI.Step(2, "Download the model",
            UI.Hint($"{model} is about 8 GB. If Ollama isn't running, start it from the Start menu first."),
            pullBar, pullStatus, pull));
        AddCheck();
    }

    void AddCheck()
    {
        var label = provider == NotesProvider.Ollama ? "Check again" : "Check again (sends a short test message)";
        var b = UI.Button(checking ? "Checking…" : label, () => _ = Check(), primary: true);
        b.IsEnabled = !checking;
        Children.Add(UI.Row(b));
        Children.Add(result);
    }

    void SignIn(string? exe, string args)
    {
        if (exe == null)
        {
            result.Text = $"{ProviderInfo.Label(provider)} isn't installed yet. Do step 2 first, then press Check again.";
            return;
        }
        Shell.Console($"\"\"{exe}\"{args}\"");
    }

    public bool Ready { get; private set; }
    public event Action? ReadyChanged;

    public async Task Check()
    {
        if (provider == NotesProvider.Ollama)
        {
            await CheckOllama();
            return;
        }
        checking = true;
        Build();
        result.Text = "Checking…";
        var exe = Tools.Executable(provider, Settings);
        if (exe == null)
        {
            Finish(false, $"{ProviderInfo.Label(provider)} isn't installed yet. Follow the steps above, then press Check again.");
            return;
        }
        var (args, input, _) = Pipeline.Invocation(provider, "Reply with the single word OK.", "(This is a test from the Meeting Notes setup.)");
        var work = Path.Combine(Path.GetTempPath(), "meetingnotes-check");
        Directory.CreateDirectory(work);
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(120));
            var r = await Task.Run(() => ProcessRunner.Shared.RunAsync(exe, args, input, work, timeout.Token));
            Pipeline.CheckNotes(provider, r);
            Finish(true, $"✔ {ProviderInfo.Label(provider)} works and is signed in.");
        }
        catch (OperationCanceledException)
        {
            Finish(false, $"{ProviderInfo.Label(provider)} didn't answer within 2 minutes. Sign in (step 3), then press Check again.");
        }
        catch (Exception e)
        {
            Finish(false, e.Message.Replace(" Then press Retry; the transcript is kept.", " Then press Check again."));
        }
    }

    async Task CheckOllama()
    {
        checking = true;
        Build();
        result.Text = "Checking Ollama…";
        var model = string.IsNullOrWhiteSpace(Settings.OllamaModel) ? Ollama.DefaultModel : Settings.OllamaModel.Trim();
        var url = string.IsNullOrWhiteSpace(Settings.OllamaUrl) ? Ollama.DefaultUrl : Settings.OllamaUrl.Trim();
        var status = await Ollama.StatusAsync(model, url);
        Finish(status == Ollama.Status.Ready, status switch
        {
            Ollama.Status.Ready => $"✔ Ollama is running and {model} is downloaded.",
            Ollama.Status.ModelMissing => Ollama.MissingModelMessage(model),
            _ => Ollama.NotRunningMessage(url),
        });
    }

    void Finish(bool ok, string message)
    {
        checking = false;
        Ready = ok;
        Build();
        result.Text = message;
        result.Foreground = ok ? new SolidColorBrush(Color.FromRgb(46, 125, 50)) : new SolidColorBrush(Color.FromRgb(198, 40, 40));
        ReadyChanged?.Invoke();
    }

    async void Pull(string model)
    {
        pulling = true;
        pullBar.Visibility = Visibility.Visible;
        pullBar.IsIndeterminate = true;
        Build();
        var url = string.IsNullOrWhiteSpace(Settings.OllamaUrl) ? Ollama.DefaultUrl : Settings.OllamaUrl.Trim();
        try
        {
            await Ollama.PullAsync(model, url, new Progress<(string Status, double? Fraction)>(p =>
            {
                if (p.Fraction is { } f)
                {
                    pullBar.IsIndeterminate = false;
                    pullBar.Value = f * 100;
                    pullStatus.Text = $"{p.Status} {f:P0}";
                }
                else pullStatus.Text = p.Status;
            }));
            pullStatus.Text = "Downloaded.";
        }
        catch (Exception e)
        {
            pullStatus.Text = e.Message;
        }
        pulling = false;
        pullBar.Visibility = Visibility.Collapsed;
        Build();
        await CheckOllama();
    }
}

/// Settings > Setup rows that aren't about the notes provider: microphone, notifications, transcription, MCP.
static class SystemChecks
{
    public static UIElement Microphone()
    {
        var ok = MicMonitor.DesktopAccessAllowed();
        var p = new StackPanel();
        p.Children.Add(UI.Check(ok ? "Microphone access for desktop apps is on" : "Microphone access for desktop apps is off", ok));
        if (!ok) p.Children.Add(UI.Hint("Turn on \"Microphone access\" and \"Let desktop apps access your microphone\" in Windows Settings."));
        p.Children.Add(UI.Button("Microphone privacy settings…", () => Shell.Open("ms-settings:privacy-microphone")));
        return p;
    }

    public static UIElement Whisper()
    {
        var ok = File.Exists(AppPaths.Whisper);
        return UI.Check(ok ? "Whisper (transcription on this PC)" : "whisper-cli.exe is missing; reinstall Meeting Notes", ok);
    }

    public static UIElement Notifications()
    {
        var ok = Notifier.Allowed;
        var p = new StackPanel();
        p.Children.Add(UI.Check(ok ? "Notifications" : "Notifications are off (calls are offered with a floating panel instead)", ok));
        p.Children.Add(UI.Row(
            UI.Button("Notification settings…", () => Shell.Open("ms-settings:notifications")),
            UI.Button("Send test", () => Notifier.Post("Meeting Notes", "Notifications are working.", null))));
        p.Children.Add(UI.Hint("Turn off Do not disturb during calls if you want the \"Meeting detected\" notification to appear."));
        return p;
    }

    public static UIElement Mcp()
    {
        var exe = AppPaths.McpServer;
        var installed = File.Exists(exe);
        var p = new StackPanel();
        p.Children.Add(UI.Check("Ask AI apps about your meetings (MCP server)", installed));
        var copied = UI.Hint(installed
            ? "Claude Desktop and other AI apps can then list, search and read your notes and transcripts. Never audio, and they can't change anything."
            : "meetingnotes-mcp.exe is missing; reinstall Meeting Notes.");
        var add = UI.Button("Add to Claude Desktop", () =>
        {
            try
            {
                McpSetup.WriteExtension(AppPaths.McpExtension, exe, File.Exists(AppPaths.Icon) ? AppPaths.Icon : null);
                Shell.Open(AppPaths.McpExtension);
                copied.Text = "Claude Desktop opens the Meeting Notes extension: press Install. (If nothing happens, install Claude Desktop from claude.ai/download first.)";
            }
            catch (Exception e)
            {
                copied.Text = $"Couldn't create the extension: {e.Message}";
            }
        });
        add.IsEnabled = installed;
        var other = new Button { Content = "Other apps ▾", Margin = new Thickness(0, 4, 8, 4), IsEnabled = installed };
        var menu = new ContextMenu();
        void Item(string label, string text, string what)
        {
            var mi = new MenuItem { Header = label };
            mi.Click += (_, _) =>
            {
                try { Clipboard.SetText(text); copied.Text = $"Copied the {what}. Paste it where that app expects it."; } catch { }
            };
            menu.Items.Add(mi);
        }
        Item("Claude Code command", McpSetup.ClaudeCodeCommand(exe), "Claude Code command (run it in a terminal)");
        Item("Codex command", McpSetup.CodexCommand(exe), "Codex command (run it in a terminal)");
        Item("VS Code command", McpSetup.VsCodeCommand(exe), "VS Code command (run it in Command Prompt)");
        Item("JSON config (Cursor, LM Studio, others)", McpSetup.ConfigJson(exe), "JSON config (paste it into the app's MCP settings)");
        Item("Server path", exe, "server path");
        other.Click += (_, _) => { menu.PlacementTarget = other; menu.IsOpen = true; };
        p.Children.Add(UI.Row(add, other));
        p.Children.Add(copied);
        return p;
    }
}
