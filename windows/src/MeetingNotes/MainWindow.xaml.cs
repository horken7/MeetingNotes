using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using MeetingNotes.Core;

namespace MeetingNotes;

public partial class MainWindow : Window
{
    readonly AppModel model = AppModel.Shared;
    readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };
    string? selected;          // folder of the shown meeting
    string notes = "", transcript = "";
    string? loadedFor;
    int current;               // index of the selected find match
    List<Markdown.Match> matches = new();
    bool refreshingList;
    string? listSignature;

    public MainWindow()
    {
        InitializeComponent();
        model.Changed += OnModelChanged;
        model.SelectRequested += Select;
        Closed += (_, _) =>
        {
            model.Changed -= OnModelChanged;
            model.SelectRequested -= Select;
            clock.Stop();
        };
        clock.Tick += (_, _) => UpdateRecording();
        clock.Start();

        InputBindings.Add(new KeyBinding(new Command(OpenFind), Key.F, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new Command(() => { SearchBox.Focus(); SearchBox.SelectAll(); }), Key.F, ModifierKeys.Control | ModifierKeys.Shift));
        InputBindings.Add(new KeyBinding(new Command(() => Copy_Click(this, new RoutedEventArgs())), Key.C, ModifierKeys.Control | ModifierKeys.Shift));
        InputBindings.Add(new KeyBinding(new Command(() => Step(1)), Key.F3, ModifierKeys.None));
        InputBindings.Add(new KeyBinding(new Command(() => Step(-1)), Key.F3, ModifierKeys.Shift));
        InputBindings.Add(new KeyBinding(new Command(() => { TitleBox.Focus(); TitleBox.SelectAll(); }), Key.F2, ModifierKeys.None));

        selected = model.Meetings.FirstOrDefault()?.Id;
        Refresh();
    }

    sealed class Command(Action run) : ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => run();
    }

    Meeting? Current => model.Meetings.FirstOrDefault(m => m.Id == selected);

    void OnModelChanged() => Refresh();

    void Select(string folder)
    {
        selected = folder;
        if (!model.MeetingsMatching(SearchBox.Text).Any(m => m.Id == folder)) SearchBox.Text = "";
        loadedFor = null;
        Refresh();
    }

    // MARK: Refresh

    void Refresh()
    {
        UpdateRecording();
        UpdateBanners();
        UpdateList();
        UpdateDetail();
    }

    void UpdateRecording()
    {
        if (model.Recording is { } r)
        {
            RecordingPanel.Visibility = Visibility.Visible;
            StartButton.Visibility = Visibility.Collapsed;
            var text = Format.Duration((DateTime.Now - r.Start).TotalSeconds);
            if (r.StopsAt is { } at) text += $"  (stopping in {Math.Max(0, (int)(at - DateTime.Now).TotalSeconds)} s)";
            RecordingClock.Text = text;
        }
        else
        {
            RecordingPanel.Visibility = Visibility.Collapsed;
            StartButton.Visibility = Visibility.Visible;
            StartButton.IsEnabled = !model.Starting;
            StartButton.Content = model.Starting ? "Starting…" : "● Start meeting";
        }
    }

    void UpdateBanners()
    {
        Banners.Children.Clear();
        if (model.Banner is { } msg) Banners.Children.Add(Banner(msg, Color.FromRgb(255, 243, 224), () => model.SetBanner(null)));
        if (!AppPaths.ModelInstalled)
            Banners.Children.Add(Banner("The speech model is missing, so meetings can't be transcribed. Reinstall Meeting Notes, or download it in the setup assistant.",
                Color.FromRgb(255, 235, 238), null, "Open setup", () => new SetupWindow { Owner = this }.Show()));
    }

    static Border Banner(string text, Color color, Action? onClose, string? action = null, Action? onAction = null)
    {
        var dock = new DockPanel();
        if (onClose != null)
        {
            var close = new Button { Content = "✕", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(6, 2, 6, 2), Background = Brushes.Transparent, BorderThickness = new Thickness(0) };
            close.Click += (_, _) => onClose();
            DockPanel.SetDock(close, Dock.Right);
            dock.Children.Add(close);
        }
        if (action != null && onAction != null)
        {
            var b = new Button { Content = action, Margin = new Thickness(8, 0, 0, 0) };
            b.Click += (_, _) => onAction();
            DockPanel.SetDock(b, Dock.Right);
            dock.Children.Add(b);
        }
        dock.Children.Add(new TextBox { Text = "⚠  " + text, TextWrapping = TextWrapping.Wrap, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent, VerticalAlignment = VerticalAlignment.Center });
        return new Border { Background = new SolidColorBrush(color), Padding = new Thickness(12, 8, 12, 8), Child = dock };
    }

    void UpdateList()
    {
        var shown = model.MeetingsMatching(SearchBox.Text);
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        // Rebuild only when something shown changed, so the list keeps its scroll position.
        var signature = string.Join("\n", shown.Select(m => $"{m.Id}|{m.Title}|{m.Status}|{m.Meta.Duration}|{m.HasAudio}")) + "\n" + selected;
        if (signature == listSignature) return;
        listSignature = signature;
        refreshingList = true;
        MeetingList.Items.Clear();
        foreach (var m in shown) MeetingList.Items.Add(Row(m));
        MeetingList.SelectedItem = MeetingList.Items.Cast<ListBoxItem>().FirstOrDefault(i => (string)i.Tag == selected);
        refreshingList = false;
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyList.Visibility = shown.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyList.Text = model.Meetings.Count == 0
            ? "No meetings yet.\n\nPress Start meeting when a call begins, or just join a call and Meeting Notes will offer to take notes."
            : $"No meetings match \"{SearchBox.Text}\".";
    }

    static ListBoxItem Row(Meeting m)
    {
        var title = new TextBlock { Text = m.Title, FontWeight = FontWeights.SemiBold, FontSize = 14, TextTrimming = TextTrimming.CharacterEllipsis };
        var info = new DockPanel { LastChildFill = true };
        var status = StatusLabel(m);
        if (status != null)
        {
            DockPanel.SetDock(status, Dock.Right);
            info.Children.Add(status);
        }
        var when = m.Created == DateTimeOffset.MinValue ? "" : m.Created.LocalDateTime.ToString("d MMM HH:mm", CultureInfo.CurrentCulture);
        if (m.Meta.Duration is { } d) when += $" · {Format.Duration(d)}";
        if (m.IsArchived && m.Status == "done") when += " · audio archived";
        info.Children.Add(new TextBlock { Text = when, Foreground = Brushes.Gray, FontSize = 12 });
        var panel = new StackPanel { Margin = new Thickness(4, 4, 4, 4) };
        panel.Children.Add(title);
        panel.Children.Add(info);
        return new ListBoxItem { Content = panel, Tag = m.Id, Padding = new Thickness(6, 3, 6, 3) };
    }

    static TextBlock? StatusLabel(Meeting m) => m.Status switch
    {
        "recording" => new TextBlock { Text = "● Recording", Foreground = Brushes.Firebrick, FontSize = 12 },
        "transcribing" => new TextBlock { Text = "Transcribing", Foreground = Brushes.Gray, FontSize = 12 },
        "summarizing" => new TextBlock { Text = "Writing notes", Foreground = Brushes.Gray, FontSize = 12 },
        "failed" => new TextBlock { Text = "⚠ Failed", Foreground = Brushes.DarkOrange, FontSize = 12 },
        _ => null,
    };

    void UpdateDetail()
    {
        var m = Current;
        if (m == null)
        {
            Detail.Visibility = Visibility.Collapsed;
            NoSelection.Visibility = Visibility.Visible;
            return;
        }
        Detail.Visibility = Visibility.Visible;
        NoSelection.Visibility = Visibility.Collapsed;
        if (!TitleBox.IsKeyboardFocused) TitleBox.Text = m.Title;
        var parts = new List<string>();
        if (m.Created != DateTimeOffset.MinValue) parts.Add(m.Created.LocalDateTime.ToString("dddd d MMMM yyyy HH:mm", CultureInfo.CurrentCulture));
        if (m.Meta.Duration is { } d) parts.Add(Format.Duration(d));
        if (m.Meta.App is { } app) parts.Add(app);
        if (m.IsArchived) parts.Add("Audio archived");
        Subtitle.Text = string.Join(" · ", parts);
        Subtitle.ToolTip = m.IsArchived ? "The audio files were deleted, so the transcript can't be redone." : null;

        var newMeeting = loadedFor != m.Id;
        var oldNotes = notes;
        var oldTranscript = transcript;
        notes = Store.ReadBody(m.Folder, "notes.md");
        transcript = Store.ReadBody(m.Folder, "transcript.md");
        if (newMeeting)
        {
            loadedFor = m.Id;
            var q = SearchBox.Text.Trim();
            if (q.Length > 0)
            {
                // Opened from a search: show the find bar with the search, on the tab where it matched.
                FindBox.Text = q;
                FindBar.Visibility = Visibility.Visible;
                if (Markdown.Matches(q, notes).Count == 0 && Markdown.Matches(q, transcript).Count > 0) TranscriptTab.IsChecked = true;
                else NotesTab.IsChecked = true;
            }
            else
            {
                NotesTab.IsChecked = true;
            }
        }
        UpdateStatus(m);
        UpdateMenu(m);
        if (newMeeting || oldNotes != notes || oldTranscript != transcript) RefreshMatches();
    }

    void UpdateStatus(Meeting m)
    {
        StatusBox.Visibility = Visibility.Visible;
        StatusProgress.Visibility = Visibility.Collapsed;
        StatusButton.Visibility = Visibility.Collapsed;
        StatusButton.Style = null;
        switch (m.Status)
        {
            case "recording":
                StatusText.Text = model.Recording?.MicOnly == true
                    ? "Recording your microphone only (the call audio couldn't be captured). Press stop when the call ends."
                    : "Recording. Press stop when the call ends, or it stops by itself when the call app releases the microphone.";
                StatusButton.Content = "Stop and take notes";
                StatusButton.Style = (Style)FindResource("Danger");
                StatusButton.Visibility = Visibility.Visible;
                break;
            case "transcribing":
                StatusText.Text = "Transcribing on your PC. Roughly a minute or two per 10 minutes of call, depending on the computer.";
                StatusProgress.Visibility = Visibility.Visible;
                break;
            case "summarizing":
                StatusText.Text = "Writing the notes…";
                StatusProgress.Visibility = Visibility.Visible;
                break;
            case "failed":
                StatusText.Text = "⚠  " + (m.Meta.Error ?? "Something went wrong.");
                StatusButton.Content = "Retry";
                StatusButton.Visibility = Visibility.Visible;
                break;
            default:
                StatusBox.Visibility = Visibility.Collapsed;
                break;
        }
    }

    void UpdateMenu(Meeting m)
    {
        CopyNotesItem.IsEnabled = notes.Length > 0;
        CopyTranscriptItem.IsEnabled = transcript.Length > 0;
        RegenerateItem.IsEnabled = !m.IsBusy && transcript.Length > 0;
        RedoItem.IsEnabled = !m.IsBusy && !m.IsArchived;
        ArchiveItem.IsEnabled = !m.IsBusy && m.HasAudio;
        TrashItem.IsEnabled = m.Status != "recording";
        ListTrashItem.IsEnabled = m.Status != "recording";
    }

    bool ShowingNotes => NotesTab.IsChecked == true;
    string ShownText => ShowingNotes ? notes : transcript;

    void RenderText()
    {
        var m = Current;
        var text = ShownText;
        CopyButton.Content = ShowingNotes ? "Copy notes" : "Copy transcript";
        CopyButton.IsEnabled = text.Length > 0;
        if (text.Length == 0)
        {
            Viewer.Document = new FlowDocument();
            Placeholder.Visibility = Visibility.Visible;
            Placeholder.Text = m?.Status switch
            {
                "recording" => "Notes appear here after the meeting.",
                "transcribing" or "summarizing" => "Working on it…",
                _ => ShowingNotes ? "No notes yet." : "No transcript yet.",
            };
            return;
        }
        Placeholder.Visibility = Visibility.Collapsed;
        var finding = FindBar.Visibility == Visibility.Visible;
        Markdown.Match? match = matches.Count == 0 ? null : matches[Math.Min(current, matches.Count - 1)];
        // Keep the scroll position when the same text is redrawn (e.g. the status changed).
        Viewer.Document = MarkdownRenderer.Build(text, finding ? FindBox.Text : "", match, out var run);
        if (run != null) Dispatcher.BeginInvoke(() => run.BringIntoView(), DispatcherPriority.Background);
        var n = matches.Count;
        FindCount.Text = FindBox.Text.Length == 0 ? "" : n == 0 ? "No matches" : $"{Math.Min(current, n - 1) + 1} of {n}";
    }

    void RefreshMatches()
    {
        current = 0;
        matches = FindBar.Visibility == Visibility.Visible ? Markdown.Matches(FindBox.Text, ShownText) : new();
        RenderText();
    }

    void Step(int delta)
    {
        var n = matches.Count;
        if (n == 0) return;
        current = ((Math.Min(current, n - 1) + delta) % n + n) % n;
        RenderText();
    }

    void OpenFind()
    {
        if (Current == null) return;
        FindBar.Visibility = Visibility.Visible;
        FindBox.Focus();
        FindBox.SelectAll();
        RefreshMatches();
    }

    // MARK: Events

    void Start_Click(object sender, RoutedEventArgs e) => model.Start();
    void Stop_Click(object sender, RoutedEventArgs e) => model.Stop();
    void Settings_Click(object sender, RoutedEventArgs e) => new SettingsWindow { Owner = this }.ShowDialog();

    void SearchBox_TextChanged(object sender, TextChangedEventArgs e) => UpdateList();

    void MeetingList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (refreshingList || MeetingList.SelectedItem is not ListBoxItem item) return;
        if ((string)item.Tag == selected) return;
        CommitRename();
        selected = (string)item.Tag;
        FindBar.Visibility = Visibility.Collapsed;
        UpdateDetail();
    }

    void MeetingList_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Delete) Trash_Click(sender, e);
    }

    void TitleBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { CommitRename(); Keyboard.ClearFocus(); }
        else if (e.Key == Key.Escape) { TitleBox.Text = Current?.Title ?? ""; Keyboard.ClearFocus(); }
    }

    void TitleBox_LostFocus(object sender, KeyboardFocusChangedEventArgs e) => CommitRename();

    void CommitRename()
    {
        if (Current is { } m && TitleBox.Text.Trim() != m.Title && TitleBox.Text.Trim().Length > 0) model.Rename(m, TitleBox.Text);
    }

    void StatusButton_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { } m) return;
        if (m.Status == "recording") model.Stop();
        else if (m.Status == "failed") model.Retry(m, notesOnly: transcript.Length > 0);
    }

    void Tab_Checked(object sender, RoutedEventArgs e)
    {
        if (IsLoaded) RefreshMatches();
    }

    void More_Click(object sender, RoutedEventArgs e)
    {
        MoreMenu.PlacementTarget = MoreButton;
        MoreMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        MoreMenu.IsOpen = true;
    }

    void Copy_Click(object sender, RoutedEventArgs e) => CopyText(ShownText, CopyButton);
    void CopyNotes_Click(object sender, RoutedEventArgs e) => CopyText(notes, null);
    void CopyTranscript_Click(object sender, RoutedEventArgs e) => CopyText(transcript, null);

    async void CopyText(string text, Button? button)
    {
        if (text.Length == 0) return;
        try { Clipboard.SetText(text); } catch { return; }
        if (button == null) return;
        var label = button.Content;
        button.Content = "✓ Copied";
        await Task.Delay(1500);
        button.Content = label;
        RenderText();
    }

    void ShowInExplorer_Click(object sender, RoutedEventArgs e)
    {
        if (Current is { } m) Shell.ShowInExplorer(m.Folder);
    }

    void Regenerate_Click(object sender, RoutedEventArgs e)
    {
        if (Current is { } m) model.Retry(m, notesOnly: true);
    }

    void Redo_Click(object sender, RoutedEventArgs e)
    {
        if (Current is { } m) model.Retry(m, notesOnly: false);
    }

    void Archive_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { } m || m.IsBusy || !m.HasAudio) return;
        var ok = MessageBox.Show(this,
            "The recordings are deleted for good. The notes and transcript are kept, but the transcript can no longer be redone.",
            $"Archive the audio for \"{m.Title}\"?", MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel);
        if (ok == MessageBoxResult.OK) model.ArchiveAudio(m);
    }

    void Trash_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { } m || m.Status == "recording") return;
        var ok = MessageBox.Show(this, "The meeting's folder (notes, transcript and audio) goes to the Recycle Bin.",
            $"Move \"{m.Title}\" to the Recycle Bin?", MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (ok != MessageBoxResult.OK) return;
        selected = null;
        model.Trash(m);
    }

    void FindBox_TextChanged(object sender, TextChangedEventArgs e) => RefreshMatches();

    void FindBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { Step(Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? -1 : 1); e.Handled = true; }
        else if (e.Key == Key.Escape) { FindDone_Click(sender, e); e.Handled = true; }
    }

    void FindPrev_Click(object sender, RoutedEventArgs e) => Step(-1);
    void FindNext_Click(object sender, RoutedEventArgs e) => Step(1);

    void FindDone_Click(object sender, RoutedEventArgs e)
    {
        FindBar.Visibility = Visibility.Collapsed;
        RefreshMatches();
    }
}
