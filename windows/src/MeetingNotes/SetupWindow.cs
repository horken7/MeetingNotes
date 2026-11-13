using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MeetingNotes.Core;

namespace MeetingNotes;

/// The first-run setup assistant: welcome and name, speech model download, notes provider, how to install and sign
/// in to it, and the background options. No command line needed. Also opened from Settings.
sealed class SetupWindow : Window
{
    readonly AppSettings s = AppModel.Shared.Settings.Clone();
    readonly ContentControl page = new();
    readonly Button back = new() { Content = "Back" };
    readonly Button next = new() { Content = "Next" };
    readonly TextBlock stepLabel = new() { Foreground = Brushes.Gray, VerticalAlignment = VerticalAlignment.Center };
    int step;
    /// The pages shown: the speech model page only when the installed model is missing, and the provider's setup
    /// page only for providers that need setting up (the built-in model doesn't, when it's installed).
    readonly bool modelMissing = !AppPaths.ModelInstalled;
    string[] pages => new[] { "welcome", modelMissing ? "model" : null, "provider",
                              s.Provider == NotesProvider.BuiltIn && BuiltIn.Installed ? null : "setup", "finish" }
        .Where(x => x != null).Select(x => x!).ToArray();
    int Steps => pages.Length;
    ModelPanel? modelPanel;
    ProviderPanel? providerPanel;
    bool loginOn = true;
    bool finished;

    public SetupWindow()
    {
        Title = "Set up Meeting Notes";
        Width = 640;
        Height = 640;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Brushes.White;
        Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/Assets/app.ico"));
        try { loginOn = LoginItem.Enabled || !s.SetupDone; } catch { }

        next.Style = (Style)FindResource("Primary");
        next.Margin = new Thickness(0);
        back.Click += (_, _) => Go(step - 1);
        next.Click += (_, _) => { if (step == Steps - 1) Finish(); else Go(step + 1); };

        var footer = new DockPanel { Margin = new Thickness(20, 12, 20, 12), LastChildFill = false };
        DockPanel.SetDock(next, Dock.Right);
        DockPanel.SetDock(back, Dock.Right);
        footer.Children.Add(next);
        footer.Children.Add(back);
        footer.Children.Add(stepLabel);
        var bottom = new Border { Child = footer, BorderBrush = (Brush)FindResource("Line"), BorderThickness = new Thickness(0, 1, 0, 0) };
        var root = new DockPanel();
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(bottom);
        root.Children.Add(new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(28, 20, 28, 20) });
        Content = root;
        Closed += (_, _) =>
        {
            // Closing early keeps what was chosen; the assistant opens again next time until it's finished.
            if (!finished) AppModel.Shared.SaveSettings(s);
            if (finished) App.ShowMainWindow();
        };
        Go(0);
    }

    void Go(int target)
    {
        step = Math.Clamp(target, 0, Steps - 1);
        back.Visibility = step == 0 ? Visibility.Hidden : Visibility.Visible;
        next.Content = step == Steps - 1 ? "Finish" : "Next";
        stepLabel.Text = $"Step {step + 1} of {Steps}";
        page.Content = pages[step] switch
        {
            "welcome" => Welcome(),
            "model" => Model(),
            "provider" => Provider(),
            "setup" => ProviderSetup(),
            _ => Finishing(),
        };
    }

    static TextBlock Heading(string text) => new() { Text = text, FontSize = 22, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 10), TextWrapping = TextWrapping.Wrap };

    UIElement Welcome()
    {
        var p = new StackPanel();
        p.Children.Add(Heading("Welcome to Meeting Notes"));
        p.Children.Add(UI.Text("Meeting Notes records your video calls (your microphone and the other people's audio), turns them into a transcript on this PC, and writes meeting notes: a summary, decisions, action items and open questions.", 14));
        p.Children.Add(UI.Text("It notices when a call starts in Teams, Zoom, Google Meet or another app, and offers to take notes. It lives in the notification area near the clock.", 14));
        p.Children.Add(UI.Text("This takes a few minutes. You can close it and continue later.", 14, color: Brushes.Gray));
        p.Children.Add(new TextBlock { Text = "Your name (used in the notes and transcript)", Margin = new Thickness(0, 16, 0, 4) });
        var name = new TextBox { Text = s.MyName, Width = 280, HorizontalAlignment = HorizontalAlignment.Left, FontSize = 14 };
        name.TextChanged += (_, _) => s.MyName = name.Text.Trim().Length == 0 ? "Me" : name.Text.Trim();
        p.Children.Add(name);
        p.Children.Add(new TextBlock { Text = "Language of your meetings", Margin = new Thickness(0, 12, 0, 4) });
        var lang = new ComboBox { Width = 280, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var (id, label) in new[] { ("auto", "Detect automatically"), ("sv", "Svenska"), ("da", "Dansk"), ("en", "English") })
            lang.Items.Add(new ComboBoxItem { Content = label, Tag = id, IsSelected = id == s.Language });
        lang.SelectionChanged += (_, _) => s.Language = (string)((ComboBoxItem)lang.SelectedItem).Tag;
        p.Children.Add(lang);
        return p;
    }

    UIElement Model()
    {
        var p = new StackPanel();
        p.Children.Add(Heading("Download the speech model"));
        p.Children.Add(UI.Text("The transcript is made on this PC, so your audio never leaves it. That needs a speech recognition model. It normally comes with the installer; here it's missing, so it's downloaded once.", 14));
        modelPanel ??= new ModelPanel();
        if (modelPanel.Parent is Panel old) old.Children.Remove(modelPanel);
        p.Children.Add(modelPanel);
        if (!modelPanel.Installed && !modelPanel.Downloading) modelPanel.Start();
        p.Children.Add(UI.Hint("You can press Next while it downloads; it keeps going in the background, also after this assistant is closed."));
        return p;
    }

    UIElement Provider()
    {
        var p = new StackPanel();
        p.Children.Add(Heading("Who writes the notes?"));
        p.Children.Add(UI.Text("The transcript is turned into notes by an AI. Choose one; you can change it later in Settings.", 14));
        foreach (var (provider, description) in new[]
        {
            (NotesProvider.BuiltIn, "Gemma 3 4B, built into Meeting Notes. Free and fully private, nothing to install or sign in to. The notes take a few minutes on this PC and are simpler than Claude's."),
            (NotesProvider.Claude, "Claude Code with your Claude account (Pro or Max plan). Best notes. The text transcript is sent to Anthropic."),
            (NotesProvider.Codex, "Codex with your ChatGPT account. The text transcript is sent to OpenAI."),
            (NotesProvider.Ollama, "A local model on this PC with Ollama. Free and fully private, but needs a fast computer with 16 GB of memory, and the notes are simpler."),
        })
        {
            var radio = new RadioButton { GroupName = "provider", IsChecked = s.Provider == provider, Margin = new Thickness(0, 8, 0, 0) };
            var label = new StackPanel();
            label.Children.Add(new TextBlock { Text = ProviderInfo.Label(provider), FontWeight = FontWeights.SemiBold, FontSize = 14 });
            label.Children.Add(new TextBlock { Text = description, TextWrapping = TextWrapping.Wrap, Foreground = Brushes.DimGray, MaxWidth = 520 });
            radio.Content = label;
            radio.Checked += (_, _) => { s.Provider = provider; stepLabel.Text = $"Step {step + 1} of {Steps}"; };
            p.Children.Add(radio);
        }
        return p;
    }

    UIElement ProviderSetup()
    {
        var p = new StackPanel();
        p.Children.Add(Heading($"Set up {ProviderInfo.Label(s.Provider)}"));
        if (providerPanel == null) providerPanel = new ProviderPanel(s.Provider, () => s);
        else providerPanel.Show(s.Provider);
        if (providerPanel.Parent is Panel old) old.Children.Remove(providerPanel);
        p.Children.Add(providerPanel);
        p.Children.Add(UI.Hint("Done some steps already? Press Check again. You can also finish later from Settings > Setup."));
        return p;
    }

    UIElement Finishing()
    {
        var p = new StackPanel();
        p.Children.Add(Heading("Almost done"));
        var login = new CheckBox { Content = "Start Meeting Notes when I sign in to Windows (recommended, so calls are always noticed)", IsChecked = loginOn };
        login.Checked += (_, _) => loginOn = true;
        login.Unchecked += (_, _) => loginOn = false;
        p.Children.Add(login);
        var detect = new CheckBox { Content = "Offer to take notes when a call starts", IsChecked = s.AutoDetect };
        detect.Checked += (_, _) => s.AutoDetect = true;
        detect.Unchecked += (_, _) => s.AutoDetect = false;
        p.Children.Add(detect);
        p.Children.Add(UI.Text("How it works", 14, bold: true));
        p.Children.Add(UI.Text("• Join a call. After a few seconds, \"Meeting detected\" appears: press Start notes.", 13.5));
        p.Children.Add(UI.Text("• Or open Meeting Notes from the icon near the clock and press Start meeting.", 13.5));
        p.Children.Add(UI.Text("• When you leave the call, recording stops by itself. A notification tells you when the notes are ready.", 13.5));
        p.Children.Add(UI.Hint("Tip: Windows may hide the icon under the ^ arrow next to the clock. Drag it onto the taskbar to keep it visible."));
        if (s.Provider == NotesProvider.BuiltIn)
            p.Children.Add(UI.Text(BuiltIn.Problem() ??
                "The notes are written by the built-in model on this PC. Nothing to set up; Settings > Notes has other options.", 13,
                color: BuiltIn.Problem() == null ? Brushes.DimGray : Brushes.DarkOrange));
        if (!AppPaths.ModelInstalled)
            p.Children.Add(UI.Text("The speech model is still downloading (or missing). Meetings can be recorded meanwhile; they are transcribed once it's there (press Retry). Settings > Setup shows its progress.", 13, color: Brushes.DarkOrange));
        if (!Notifier.Allowed)
            p.Children.Add(UI.Text("Notifications are off for Meeting Notes, so calls are offered with a small panel instead. Turn them on in Windows Settings > System > Notifications.", 13, color: Brushes.DarkOrange));
        return p;
    }

    void Finish()
    {
        try { LoginItem.Set(loginOn); } catch (Exception e) { AppPaths.Log($"login item: {e.Message}"); }
        s.SetupDone = true;
        s.LoginItemOffered = true;
        AppModel.Shared.SaveSettings(s);
        finished = true;
        Close();
    }
}
