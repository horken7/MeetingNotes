using System.Windows;
using System.Windows.Threading;
using MeetingNotes.Core;
using Microsoft.Toolkit.Uwp.Notifications;

namespace MeetingNotes;

public partial class App : Application
{
    static Mutex? single;
    static EventWaitHandle? showSignal;
    static MainWindow? main;
    Tray? tray;
    bool quitting;

    public static void OnUi(Action action)
    {
        var d = Current?.Dispatcher;
        if (d == null) return;
        if (d.CheckAccess()) action(); else d.BeginInvoke(action);
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var user = Environment.UserName;
        single = new Mutex(true, $"MeetingNotes.SingleInstance.{user}", out var first);
        showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, $"MeetingNotes.Show.{user}");
        if (!first)
        {
            // Already running (in the tray): show its window instead of starting twice.
            if (!ToastNotificationManagerCompat.WasCurrentProcessToastActivated()) showSignal.Set();
            Shutdown();
            return;
        }
        ThreadPool.RegisterWaitForSingleObject(showSignal, (_, _) => OnUi(ShowMainWindow), null, -1, false);

        DispatcherUnhandledException += (_, ex) =>
        {
            AppPaths.Log($"unhandled: {ex.Exception}");
            ex.Handled = true;
        };
        if (e.Args.Contains("--uninstall"))
        {
            // Run by the uninstaller: forget the notification registration and the login entry.
            Notifier.Uninstall();
            LoginItem.Set(false);
            Shutdown();
            return;
        }

        var model = AppModel.Shared;
        // Start at login by default (once; it can be turned off in Settings), so calls are always detected.
        if (!model.Settings.LoginItemOffered)
        {
            var s = model.Settings.Clone();
            s.LoginItemOffered = true;
            try { LoginItem.Set(true); } catch (Exception ex) { AppPaths.Log($"login item: {ex.Message}"); }
            model.SaveSettings(s);
        }
        model.Launch();
        tray = new Tray(model, Quit);
        SessionEnding += async (_, _) => await model.StopForQuit();

        var background = e.Args.Contains("--background");
        if (!model.Settings.SetupDone)
            new SetupWindow().Show();
        else if (!background && !ToastNotificationManagerCompat.WasCurrentProcessToastActivated())
            ShowMainWindow();
    }

    public static void ShowMainWindow()
    {
        if (main == null)
        {
            main = new MainWindow();
            main.Closed += (_, _) => main = null;
        }
        main.Show();
        if (main.WindowState == WindowState.Minimized) main.WindowState = WindowState.Normal;
        main.Activate();
    }

    async void Quit()
    {
        if (quitting) return;
        quitting = true;
        await AppModel.Shared.StopForQuit();
        tray?.Dispose();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        tray?.Dispose();
        base.OnExit(e);
    }
}
