using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace MeetingNotes;

/// The floating "Meeting detected" panel, used when notifications are off or "Ask with: a floating panel" is chosen.
sealed class PromptWindowHost
{
    Window? window;

    public void Show(string appName, string? meetingName, Action onStart, Action onDismiss, Action onNever)
    {
        Hide();
        var title = new TextBlock { Text = meetingName ?? "Meeting detected", FontSize = 15, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        var subtitle = new TextBlock { Text = $"{appName} is using the microphone", Foreground = Brushes.DimGray, Margin = new Thickness(0, 2, 0, 12) };
        var start = new Button { Content = "Start notes", IsDefault = true, Style = (Style)Application.Current.FindResource("Primary") };
        var notNow = new Button { Content = "Not now" };
        var never = new Button
        {
            Content = $"Never for {appName}", Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            Foreground = Brushes.DimGray, FontSize = 11, Margin = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Right,
        };
        start.Click += (_, _) => onStart();
        notNow.Click += (_, _) => onDismiss();
        never.Click += (_, _) => onNever();
        var buttons = new DockPanel { LastChildFill = false };
        buttons.Children.Add(start);
        buttons.Children.Add(notNow);
        DockPanel.SetDock(never, Dock.Right);
        buttons.Children.Add(never);
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(title);
        panel.Children.Add(subtitle);
        panel.Children.Add(buttons);

        var w = new Window
        {
            Content = new Border { Child = panel, BorderBrush = new SolidColorBrush(Color.FromRgb(200, 200, 200)), BorderThickness = new Thickness(1), Background = Brushes.White },
            Width = 380, SizeToContent = SizeToContent.Height, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize,
            Topmost = true, ShowInTaskbar = false, ShowActivated = false, Title = "Meeting detected",
        };
        w.MouseLeftButtonDown += (_, e) => { if (e.ButtonState == System.Windows.Input.MouseButtonState.Pressed) w.DragMove(); };
        w.Loaded += (_, _) =>
        {
            var area = SystemParameters.WorkArea;
            w.Left = area.Right - w.ActualWidth - 16;
            w.Top = area.Bottom - w.ActualHeight - 16;
        };
        w.Show();
        System.Media.SystemSounds.Asterisk.Play();
        window = w;
    }

    public void Hide()
    {
        window?.Close();
        window = null;
    }
}
