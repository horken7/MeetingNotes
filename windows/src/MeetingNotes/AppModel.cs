using System.IO;
using System.Windows.Threading;
using MeetingNotes.Core;

namespace MeetingNotes;

sealed class ActiveRecording
{
    public required string Folder { get; init; }
    public required string Title { get; set; }
    public required DateTime Start { get; init; }
    public string? TriggerKey { get; set; }
    public DateTime LastSeen { get; set; }      // last time the call app had the mic open
    public DateTime LastAudio { get; set; }     // last time it had the mic open or was playing sound
    public DateTime? StopsAt { get; set; }      // set while the call looks over and auto-stop is counting down
    public int Segments { get; set; }           // earlier segments, when capture failed and was restarted mid-meeting
    public double SegmentStart { get; set; }    // seconds from Start to the current segment
    public bool MicOnly { get; set; }           // recording only the microphone because system audio capture failed
}

/// Meetings, recording and call detection; a port of AppModel in src/Model.swift. Used on the UI thread only.
sealed class AppModel
{
    public static readonly AppModel Shared = new();

    public AppSettings Settings { get; private set; } = AppSettings.Load();
    public List<Meeting> Meetings { get; private set; } = new();
    public ActiveRecording? Recording { get; private set; }
    public bool Starting { get; private set; }
    public string? Banner { get; private set; }

    /// Something changed (meetings, recording state, banner); windows and the tray refresh.
    public event Action? Changed;
    /// Show this meeting in the window (after starting a recording or clicking a notification).
    public event Action<string>? SelectRequested;

    Recorder? recorder;
    bool switching;          // replacing a failed capture; Stop() waits for it
    bool stopAfterSwitch;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(2) };
    readonly PromptWindowHost prompt = new();
    MicUser? candidate;
    DateTime candidateSince = DateTime.Now;
    string? dismissedKey;
    MicUser? promptUser;   // the call being asked about (panel or notification)
    readonly Dictionary<string, string?> names = new();   // meeting name per call app key, from its window title
    readonly Dictionary<string, string> searchCache = new();
    readonly Pipeline pipeline = new();

    public void Launch()
    {
        Store.Root = Settings.MeetingsDir;
        Notifier.SetUp();
        Notifier.CallAction += (action, key) => PromptAction(action, key);
        Notifier.OpenMeeting += folder =>
        {
            Reload();
            App.ShowMainWindow();
            if (folder != null) SelectRequested?.Invoke(folder);
        };
        MarkInterrupted();
        Reload();
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    public void SaveSettings(AppSettings updated)
    {
        var folderChanged = updated.MeetingsDir != Settings.MeetingsDir;
        Settings = updated;
        try { Settings.Save(); }
        catch (Exception e) { SetBanner($"Couldn't save the settings: {e.Message}"); }
        Store.Root = Settings.MeetingsDir;
        if (folderChanged) Reload(); else Changed?.Invoke();
    }

    public void Reload()
    {
        Meetings = Store.LoadAll();
        searchCache.Clear();
        Changed?.Invoke();
    }

    public void SetBanner(string? text)
    {
        Banner = text;
        Changed?.Invoke();
    }

    /// Meetings whose title, notes or transcript contain every word of the query.
    public List<Meeting> MeetingsMatching(string query)
    {
        var q = query.Trim();
        if (q.Length == 0) return Meetings;
        return Meetings.Where(m =>
        {
            if (!searchCache.TryGetValue(m.Id, out var text))
            {
                var parts = new List<string> { m.Title };
                foreach (var f in new[] { "notes.md", "transcript.md" })
                {
                    try { parts.Add(File.ReadAllText(Path.Combine(m.Folder, f))); } catch { }
                }
                searchCache[m.Id] = text = string.Join("\n", parts);
            }
            return TextSearch.Matches(q, text);
        }).ToList();
    }

    void MarkInterrupted()
    {
        foreach (var m in Store.LoadAll().Where(m => m.IsBusy))
            Store.Update(m.Folder, x => { x.Status = "failed"; x.Error = "Interrupted because the app was closed. Press Retry."; });
    }

    // MARK: Recording

    public async void Start(string? title = null, MicUser? trigger = null)
    {
        if (Recording != null || Starting) return;
        Starting = true;
        HidePrompt();
        // Don't offer or auto-start again for this app until it releases the mic
        // (prevents a retry loop if starting fails).
        if (trigger != null) dismissedKey = trigger.Key;
        Changed?.Invoke();
        try
        {
            var now = DateTime.Now;
            // The meeting name is looked up when the call is detected, so starting isn't delayed.
            var callName = trigger != null && names.TryGetValue(trigger.Key, out var n) ? n : null;
            var name = title ?? callName ?? (trigger != null ? $"{trigger.Name} call" : "Meeting");
            string folder;
            try
            {
                folder = Store.NewFolder(name, now);
            }
            catch (Exception e)
            {
                SetBanner($"Couldn't create the meeting folder: {e.Message}");
                return;
            }
            Store.WriteMeta(new Meta(name) { Created = now, Status = "recording", App = trigger?.Name, Lang = Settings.Language }, folder);
            var micOnly = false;
            var rec = MakeRecorder(folder, systemAudio: true);
            try
            {
                rec.Start();
                recorder = rec;
            }
            catch (Exception e)
            {
                AppPaths.Log($"full capture failed: {e}");
                // The other people's audio can't be captured: record the microphone alone rather than nothing.
                var mic = StartMicOnly(folder);
                if (mic == null)
                {
                    try { Directory.Delete(folder, true); } catch { }
                    SetBanner($"Couldn't start recording ({e.Message}). Check that a microphone is connected and that desktop apps may use it under Windows Settings > Privacy & security > Microphone.");
                    Reload();
                    return;
                }
                recorder = mic;
                micOnly = true;
                SetBanner($"Recording only your microphone, because the call audio couldn't be captured ({e.Message}). Check your speakers or headset under Windows Settings > System > Sound.");
            }
            Recording = new ActiveRecording
            {
                Folder = folder, Title = name, Start = now, TriggerKey = trigger?.Key, LastSeen = now, LastAudio = now, MicOnly = micOnly,
            };
            Reload();
            SelectRequested?.Invoke(folder);
            // Not looked up yet (e.g. auto-start): fill in the meeting name when it arrives.
            if (title == null && callName == null && trigger != null)
            {
                var found = await Task.Run(() => WindowTitles.MeetingName(trigger));
                if (found != null && Recording?.Folder == folder)
                {
                    Store.Update(folder, m => m.Title = found);
                    Recording.Title = found;
                    Reload();
                }
            }
        }
        finally
        {
            Starting = false;
            Changed?.Invoke();
        }
    }

    public async void Stop()
    {
        var active = Recording;
        if (active == null) return;
        if (switching)
        {
            stopAfterSwitch = true;
            return;
        }
        var rec = recorder;
        recorder = null;
        Recording = null;
        // If the call app still has the mic (manual stop), don't immediately prompt/auto-start again.
        if (active.TriggerKey != null) dismissedKey = active.TriggerKey;
        Changed?.Invoke();
        var offsets = await FinishSegment(rec, active);
        Store.Update(active.Folder, m =>
        {
            m.Offsets = offsets;
            m.Duration = (DateTime.Now - active.Start).TotalSeconds;
            m.Status = "transcribing";
        });
        Reload();
        await RunPipeline(active.Folder, notesOnly: false);
    }

    /// Called when the app quits or Windows signs out: keep what was recorded so Retry can finish it.
    public async Task StopForQuit()
    {
        var active = Recording;
        if (active == null) return;
        var rec = recorder;
        recorder = null;
        Recording = null;
        var offsets = await FinishSegment(rec, active);
        Store.Update(active.Folder, m =>
        {
            m.Offsets = offsets;
            m.Duration = (DateTime.Now - active.Start).TotalSeconds;
            m.Status = "failed";
            m.Error = "The app was closed before the notes were written. Press Retry.";
        });
    }

    Recorder MakeRecorder(string folder, bool systemAudio)
    {
        var rec = new Recorder(folder, systemAudio);
        rec.Failed += (r, message) => App.OnUi(() => RecordingFailed(message, r));
        return rec;
    }

    Recorder? StartMicOnly(string folder)
    {
        var mic = MakeRecorder(folder, systemAudio: false);
        try
        {
            mic.Start();
            return mic;
        }
        catch (Exception e)
        {
            AppPaths.Log($"mic capture failed: {e}");
            return null;
        }
    }

    /// Stops the current capture and returns the offsets of every track recorded in this meeting.
    static async Task<Dictionary<string, double>> FinishSegment(Recorder? rec, ActiveRecording active)
    {
        var current = rec == null ? new Dictionary<string, double>() : await rec.StopAsync();
        var all = Store.ReadMeta(active.Folder)?.Offsets ?? new Dictionary<string, double>();
        foreach (var (k, v) in current) all[k] = v + active.SegmentStart;
        return all;
    }

    /// Capture stopped mid-meeting (e.g. the headset was unplugged). Keep what was recorded as a segment and carry
    /// on: with full capture again if it starts, otherwise with the microphone alone. Only if neither works does the
    /// recording stop.
    async void RecordingFailed(string message, Recorder failed)
    {
        if (recorder != failed || Recording is not { } active || switching) return;
        AppPaths.Log($"capture stopped: {message}");
        switching = true;
        try
        {
            var offsets = await failed.StopAsync();
            var number = active.Segments + 1;
            var kept = Store.CloseSegment(active.Folder, number, offsets, active.SegmentStart);
            Store.Update(active.Folder, m =>
            {
                m.Offsets ??= new();
                foreach (var (k, v) in kept) m.Offsets[k] = v;
            });
            var segmentStart = (DateTime.Now - active.Start).TotalSeconds;
            // Try full capture again, unless it only just failed (then it would likely keep failing).
            Recorder? next = null;
            if (segmentStart - active.SegmentStart > 30 || message == "The audio device changed")
            {
                next = MakeRecorder(active.Folder, systemAudio: !active.MicOnly || segmentStart - active.SegmentStart > 30);
                try { next.Start(); }
                catch { next = null; }
            }
            if (next != null)
            {
                recorder = next;
                active.MicOnly = next.MicOnly;
            }
            else if (StartMicOnly(active.Folder) is { } mic)
            {
                recorder = mic;
                active.MicOnly = true;
                SetBanner($"The call audio stopped being captured ({message}). Recording continues with only your microphone.");
            }
            else
            {
                recorder = null;
                SetBanner($"Recording stopped: {message}");
                stopAfterSwitch = true;
            }
            active.Segments = number;
            active.SegmentStart = segmentStart;
        }
        finally
        {
            switching = false;
        }
        if (stopAfterSwitch)
        {
            stopAfterSwitch = false;
            Stop();
        }
        Changed?.Invoke();
    }

    async Task RunPipeline(string folder, bool notesOnly)
    {
        var settings = Settings.Clone();
        await Task.Run(() => pipeline.RunAsync(folder, settings, notesOnly, () => App.OnUi(Reload)));
        Reload();
        NotifyFinished(folder);
    }

    void NotifyFinished(string folder)
    {
        var meta = Store.ReadMeta(folder);
        if (meta == null) return;
        if (meta.Status == "done")
        {
            var notes = Store.ReadBody(folder, "notes.md");
            Notifier.Post($"Notes ready: {meta.Title}", Prompt.Summary(notes) ?? "Your meeting notes are ready.", folder);
        }
        else if (meta.Status == "failed")
        {
            Notifier.Post($"Couldn't finish {meta.Title}", meta.Error ?? "Open Meeting Notes and press Retry.", folder);
        }
    }

    // MARK: Meeting actions

    public async void Retry(Meeting m, bool notesOnly)
    {
        Store.Update(m.Folder, x => { x.Status = notesOnly ? "summarizing" : "transcribing"; x.Error = null; });
        Reload();
        await RunPipeline(m.Folder, notesOnly);
    }

    public void Rename(Meeting m, string newTitle)
    {
        var t = newTitle.Trim();
        if (t.Length == 0 || t == m.Title) return;
        Store.Update(m.Folder, x => x.Title = t);
        if (Recording?.Folder == m.Folder) Recording.Title = t;
        Reload();
    }

    public void ArchiveAudio(Meeting m)
    {
        if (m.IsBusy) return;
        Store.ArchiveAudio(m.Folder);
        Reload();
    }

    public void Trash(Meeting m)
    {
        try { Shell.MoveToRecycleBin(m.Folder); }
        catch (Exception e) { SetBanner($"Couldn't move \"{m.Title}\" to the Recycle Bin: {e.Message}"); }
        Reload();
    }

    // MARK: Meeting detection

    void Tick()
    {
        var s = Settings;
        var ignored = new HashSet<string>(s.IgnoredApps, StringComparer.OrdinalIgnoreCase);
        var users = MicMonitor.Users().Where(u => !ignored.Contains(u.Key)).ToList();
        var now = DateTime.Now;

        if (Recording is { } active)
        {
            if (!s.AutoStop) return;
            if (active.TriggerKey == null && users.FirstOrDefault() is { } first) active.TriggerKey = first.Key;
            if (active.TriggerKey is not { } key) return;
            // Stop 5 s after the call app goes quiet (mic closed and no sound playing). Sound playing keeps it going
            // for apps that close the mic on mute, but at most 60 s, so a call app left open still stops.
            if (users.FirstOrDefault(u => u.Key == key) is { } seen)
            {
                lastTrigger = seen;
                active.LastSeen = now;
                active.LastAudio = now;
            }
            else if (TriggerPlaying(key))
            {
                active.LastAudio = now;
            }
            var stopAt = Min(active.LastAudio.AddSeconds(5), active.LastSeen.AddSeconds(60));
            if (now >= stopAt)
            {
                Stop();
                return;
            }
            active.StopsAt = (now - active.LastSeen).TotalSeconds > 3 ? stopAt : null;
            Changed?.Invoke();
            return;
        }

        if (!s.AutoDetect || Starting)
        {
            HidePrompt();
            return;
        }
        if (users.FirstOrDefault() is not { } u)
        {
            candidate = null;
            dismissedKey = null;
            HidePrompt();
            return;
        }
        if (dismissedKey != null && !users.Any(x => x.Key == dismissedKey)) dismissedKey = null;
        if (promptUser != null && !users.Any(x => x.Key == promptUser.Key)) HidePrompt();
        if (candidate?.Key != u.Key)
        {
            candidate = u;
            candidateSince = now;
            names.Remove(u.Key);
            var user = u;
            Task.Run(() => WindowTitles.MeetingName(user)).ContinueWith(t => App.OnUi(() => names[user.Key] = t.Result));
            return;
        }
        if (u.Key == dismissedKey || (now - candidateSince).TotalSeconds < 4 || promptUser != null) return;

        if (s.AutoStart) Start(trigger: u);
        else ShowPrompt(u);
    }

    MicUser? lastTrigger;

    bool TriggerPlaying(string key)
    {
        // The registry entry is gone from `users` once the mic closes, so remember who the trigger was.
        var user = lastTrigger?.Key == key ? lastTrigger : null;
        if (user == null)
        {
            var exe = key.Contains('#') ? MicUsage.ExePath(key) : null;
            user = new MicUser(key, "", exe, exe == null);
        }
        lastTrigger = user;
        return MicMonitor.IsPlaying(user);
    }

    static DateTime Min(DateTime a, DateTime b) => a < b ? a : b;

    // MARK: Call prompt

    /// Asks with a notification when allowed (and chosen in Settings), otherwise with the floating panel.
    void ShowPrompt(MicUser u)
    {
        promptUser = u;
        names.TryGetValue(u.Key, out var meetingName);
        if (Settings.PromptStyle != "panel" && Notifier.PostCallPrompt(u.Name, meetingName, u.Key)) return;
        prompt.Show(u.Name, meetingName,
            onStart: () => PromptAction("start", u.Key),
            onDismiss: () => PromptAction("notNow", u.Key),
            onNever: () => PromptAction("never", u.Key));
    }

    void HidePrompt()
    {
        prompt.Hide();
        if (promptUser != null) Notifier.RemoveCallPrompt();
        promptUser = null;
    }

    /// Answer from the panel or the notification. Ignored if that call is no longer being asked about.
    public void PromptAction(string action, string? key)
    {
        if (promptUser is not { } u || u.Key != key) return;
        switch (action)
        {
            case "start":
                Start(trigger: u);
                break;
            case "notNow":
                dismissedKey = u.Key;
                HidePrompt();
                break;
            case "never":
                var s = Settings.Clone();
                if (!s.IgnoredApps.Contains(u.Key)) s.IgnoredApps.Add(u.Key);
                SaveSettings(s);
                HidePrompt();
                break;
        }
    }
}
