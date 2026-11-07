using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MeetingNotes.Core;

namespace MeetingNotes;

/// Settings: You, Notes, Automatic, Storage, Setup (same sections as the Mac app). Saved when closed.
sealed class SettingsWindow : Window
{
    readonly AppSettings s = AppModel.Shared.Settings.Clone();
    readonly StackPanel providerOptions = new();
    readonly ContentControl setupChecks = new();
    ProviderPanel? providerPanel;
    readonly StackPanel ignoredList = new();

    public SettingsWindow()
    {
        Title = "Meeting Notes Settings";
        Width = 640;
        Height = 760;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Brushes.White;
        var body = new StackPanel { Margin = new Thickness(24, 8, 24, 24) };

        // You
        body.Children.Add(Section("You"));
        var name = new TextBox { Text = s.MyName, Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        name.TextChanged += (_, _) => s.MyName = name.Text.Trim().Length == 0 ? "Me" : name.Text.Trim();
        body.Children.Add(Labeled("Your name in notes", name));
        var language = new ComboBox { Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var (id, label) in Languages) language.Items.Add(new ComboBoxItem { Content = label, Tag = id, IsSelected = id == s.Language });
        language.SelectionChanged += (_, _) => s.Language = (string)((ComboBoxItem)language.SelectedItem).Tag;
        body.Children.Add(Labeled("Meeting language", language));

        // Notes
        body.Children.Add(Section("Notes"));
        var provider = new ComboBox { Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var p in ProviderInfo.All) provider.Items.Add(new ComboBoxItem { Content = ProviderInfo.Label(p), Tag = p, IsSelected = p == s.Provider });
        provider.SelectionChanged += (_, _) =>
        {
            s.Provider = (NotesProvider)((ComboBoxItem)provider.SelectedItem).Tag;
            BuildProviderOptions();
            if (providerPanel != null) BuildChecks();
        };
        body.Children.Add(Labeled("Write notes with", provider));
        body.Children.Add(providerOptions);
        BuildProviderOptions();

        body.Children.Add(UI.Text("How the notes should look", 13, bold: true));
        var instructions = new TextBox
        {
            Text = s.Instructions, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 170,
            FontFamily = new FontFamily("Consolas"), FontSize = 12.5, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        var reset = UI.Button("Reset to default", () => instructions.Text = Prompt.DefaultInstructions);
        instructions.TextChanged += (_, _) =>
        {
            var t = instructions.Text.Replace("\r\n", "\n").Trim();
            s.NotesInstructions = t == Prompt.DefaultInstructions ? "" : t;
            reset.IsEnabled = s.NotesInstructions.Length > 0;
        };
        reset.IsEnabled = s.NotesInstructions.Length > 0;
        body.Children.Add(instructions);
        body.Children.Add(UI.Hint("Sections, length, style or language. Your name, who is who and the meeting title are added automatically. Headings, bullets and bold are shown nicely; tables aren't. Use Regenerate notes to apply changes to an existing meeting."));
        body.Children.Add(reset);

        // Automatic
        body.Children.Add(Section("Automatic"));
        var detect = Toggle("Detect calls when an app starts using the microphone", s.AutoDetect, v => s.AutoDetect = v);
        var autoStart = Toggle("Start recording without asking", s.AutoStart, v => s.AutoStart = v);
        body.Children.Add(detect);
        body.Children.Add(autoStart);
        var ask = new ComboBox { Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        ask.Items.Add(new ComboBoxItem { Content = "A notification", Tag = "notification", IsSelected = s.PromptStyle != "panel" });
        ask.Items.Add(new ComboBoxItem { Content = "A floating panel", Tag = "panel", IsSelected = s.PromptStyle == "panel" });
        ask.SelectionChanged += (_, _) => s.PromptStyle = (string)((ComboBoxItem)ask.SelectedItem).Tag;
        body.Children.Add(Labeled("Ask with", ask));
        body.Children.Add(UI.Hint("The floating panel is used instead while notifications are off (see Setup)."));
        body.Children.Add(Toggle("Stop automatically when the call ends", s.AutoStop, v => s.AutoStop = v));
        bool loginOn;
        try { loginOn = LoginItem.Enabled; } catch { loginOn = false; }
        body.Children.Add(Toggle("Start when I sign in to Windows and run in the background", loginOn, v =>
        {
            try { LoginItem.Set(v); }
            catch (Exception e) { AppModel.Shared.SetBanner($"Couldn't change the sign-in setting: {e.Message}"); }
        }));
        body.Children.Add(ignoredList);
        BuildIgnored();

        // Storage
        body.Children.Add(Section("Storage"));
        var folder = new TextBlock { Text = s.MeetingsDir, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 380, Margin = new Thickness(0, 0, 10, 0) };
        var choose = UI.Button("Choose…", () =>
        {
            using var dialog = new System.Windows.Forms.FolderBrowserDialog { SelectedPath = s.MeetingsDir, ShowNewFolderButton = true, Description = "Folder for your meetings" };
            if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
            {
                s.OutputDir = dialog.SelectedPath;
                folder.Text = s.MeetingsDir;
            }
        });
        body.Children.Add(Labeled("Folder", UI.Row(folder, choose)));
        body.Children.Add(Toggle("Keep audio recordings", s.KeepAudio, v => s.KeepAudio = v));
        body.Children.Add(UI.Text("When off, the audio is deleted as soon as the transcript is ready.", 12, color: (Brush)FindResource("Muted")));

        // Setup
        body.Children.Add(Section("Setup"));
        body.Children.Add(setupChecks);
        BuildChecks();

        var done = new Button { Content = "Done", IsDefault = true, Style = (Style)FindResource("Primary"), Margin = new Thickness(0) };
        done.Click += (_, _) => Close();
        var assistant = UI.Button("Open the setup assistant", () => { new SetupWindow { Owner = Owner }.Show(); Close(); });
        var footer = new DockPanel { Margin = new Thickness(16, 10, 16, 10), LastChildFill = false };
        DockPanel.SetDock(done, Dock.Right);
        footer.Children.Add(done);
        footer.Children.Add(assistant);
        var root = new DockPanel();
        var bottom = new Border { Child = footer, BorderBrush = (Brush)FindResource("Line"), BorderThickness = new Thickness(0, 1, 0, 0) };
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(bottom);
        root.Children.Add(new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = root;
        Closed += (_, _) => AppModel.Shared.SaveSettings(s);
    }

    static readonly (string Id, string Label)[] Languages = { ("auto", "Detect automatically"), ("sv", "Svenska"), ("da", "Dansk"), ("en", "English") };

    static TextBlock Section(string title) => new() { Text = title, Style = (Style)Application.Current.FindResource("Section") };

    static UIElement Labeled(string label, UIElement control)
    {
        var g = new Grid { Margin = new Thickness(0, 3, 0, 3) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var l = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
        g.Children.Add(l);
        Grid.SetColumn((UIElement)control, 1);
        g.Children.Add(control);
        return g;
    }

    static CheckBox Toggle(string label, bool value, Action<bool> set)
    {
        var c = new CheckBox { Content = label, IsChecked = value };
        c.Checked += (_, _) => set(true);
        c.Unchecked += (_, _) => set(false);
        return c;
    }

    void BuildProviderOptions()
    {
        providerOptions.Children.Clear();
        switch (s.Provider)
        {
            case NotesProvider.Claude:
                providerOptions.Children.Add(Labeled("Claude executable (optional)", PathBox(s.ClaudePath, v => s.ClaudePath = v)));
                break;
            case NotesProvider.Codex:
                providerOptions.Children.Add(Labeled("Codex executable (optional)", PathBox(s.CodexPath, v => s.CodexPath = v)));
                break;
            default:
                providerOptions.Children.Add(Labeled("Model", PathBox(s.OllamaModel, v => s.OllamaModel = v)));
                providerOptions.Children.Add(Labeled("Ollama address", PathBox(s.OllamaUrl, v => s.OllamaUrl = v)));
                break;
        }
        providerOptions.Children.Add(UI.Hint(ProviderInfo.LoginHint(s.Provider)));
        providerOptions.Children.Add(UI.Hint(s.Provider == NotesProvider.Ollama
            ? "The notes are written on this PC by the local model. Nothing leaves the computer (unless the address points to another computer)."
            : "The text transcript is sent to the selected provider. Audio stays on this PC."));
    }

    static TextBox PathBox(string value, Action<string> set)
    {
        var t = new TextBox { Text = value };
        t.TextChanged += (_, _) => set(t.Text.Trim());
        return t;
    }

    void BuildIgnored()
    {
        ignoredList.Children.Clear();
        foreach (var key in s.IgnoredApps.ToList())
        {
            var label = key.Contains('#') ? MicUsage.DesktopName(MicUsage.ExePath(key)) : MicUsage.PackageName(key);
            var remove = UI.Button("Remove", () => { s.IgnoredApps.Remove(key); BuildIgnored(); });
            ignoredList.Children.Add(UI.Row(new TextBlock { Text = $"Never detect {label}", Foreground = Brushes.Gray, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0), ToolTip = key }, remove));
        }
    }

    void BuildChecks()
    {
        var p = new StackPanel();
        p.Children.Add(SystemChecks.Whisper());
        p.Children.Add(new ModelPanel());
        p.Children.Add(SystemChecks.Microphone());
        p.Children.Add(UI.Text(ProviderInfo.Label(s.Provider), 13, bold: true));
        providerPanel = new ProviderPanel(s.Provider, () => s);
        p.Children.Add(providerPanel);
        p.Children.Add(SystemChecks.Notifications());
        p.Children.Add(SystemChecks.Mcp());
        setupChecks.Content = p;
    }
}
