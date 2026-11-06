using MeetingNotes.Core;
using Microsoft.Toolkit.Uwp.Notifications;
using Windows.UI.Notifications;

namespace MeetingNotes;

/// Windows notifications: "Meeting detected" with Start notes / Not now / Never for this app, and "Notes ready"
/// (clicking it opens the meeting). The toolkit registers the app for notifications without an installer step.
static class Notifier
{
    const string CallTag = "callDetected";
    public static event Action<string, string?>? CallAction;   // (action, key)
    public static event Action<string?>? OpenMeeting;           // folder

    public static void SetUp()
    {
        ToastNotificationManagerCompat.OnActivated += e =>
        {
            var args = ToastArguments.Parse(e.Argument);
            args.TryGetValue("action", out var action);
            args.TryGetValue("key", out var key);
            args.TryGetValue("folder", out var folder);
            App.OnUi(() =>
            {
                if (action is "start" or "notNow" or "never") CallAction?.Invoke(action, key);
                else OpenMeeting?.Invoke(folder);
            });
        };
        RemoveCallPrompt();   // left over from a previous run
    }

    /// Notifications are turned on for this app (Windows Settings > System > Notifications).
    public static bool Allowed
    {
        get
        {
            try { return ToastNotificationManagerCompat.CreateToastNotifier().Setting == NotificationSetting.Enabled; }
            catch { return false; }
        }
    }

    /// Posts "Meeting detected". False when notifications are off, so the caller shows the panel instead.
    public static bool PostCallPrompt(string appName, string? meetingName, string key)
    {
        if (!Allowed) return false;
        try
        {
            new ToastContentBuilder()
                .AddArgument("action", "start").AddArgument("key", key)   // clicking the notification starts too
                .AddText(meetingName ?? "Meeting detected")
                .AddText($"{appName} is using the microphone. Start notes?")
                .AddButton(new ToastButton().SetContent("Start notes").AddArgument("action", "start").AddArgument("key", key))
                .AddButton(new ToastButton().SetContent("Not now").AddArgument("action", "notNow").AddArgument("key", key))
                .AddButton(new ToastButton().SetContent("Never for this app").AddArgument("action", "never").AddArgument("key", key))
                .SetToastScenario(ToastScenario.Reminder)   // stays on screen until answered
                .Show(t =>
                {
                    t.Tag = CallTag;
                    t.ExpirationTime = DateTimeOffset.Now.AddMinutes(10);
                });
            return true;
        }
        catch (Exception e)
        {
            AppPaths.Log($"call notification: {e.Message}");
            return false;
        }
    }

    public static void RemoveCallPrompt()
    {
        try { ToastNotificationManagerCompat.History.Remove(CallTag); } catch { }
    }

    public static void Post(string title, string body, string? folder)
    {
        try
        {
            var b = new ToastContentBuilder().AddText(title).AddText(body);
            b.AddArgument("action", "open");
            if (folder != null) b.AddArgument("folder", folder);
            b.Show();
        }
        catch (Exception e)
        {
            AppPaths.Log($"notification: {e.Message}");
        }
    }

    public static void Uninstall()
    {
        try { ToastNotificationManagerCompat.Uninstall(); } catch { }
    }
}
