using System.Diagnostics;
using System.IO;
using MeetingNotes.Core;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace MeetingNotes;

/// Records the microphone ("me") and the computer's sound ("others") as two tracks with WASAPI: the default
/// microphone in shared mode, and loopback of the default speakers. With `systemAudio: false` only the microphone.
///
/// Meeting Notes plays no sounds of its own (the "Meeting detected" and "Notes ready" sounds are played by
/// Windows' notification system, before and after recording), so the loopback doesn't need to exclude this app.
sealed class Recorder : IDisposable
{
    readonly string folder;
    readonly bool systemAudio;
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly Dictionary<string, TrackWriter> tracks = new();
    readonly List<IWaveIn> captures = new();
    readonly List<TaskCompletionSource> stoppedSignals = new();
    DeviceWatcher? watcher;
    volatile bool stopping;
    int errorRaised;

    /// Capture stopped mid-recording (device unplugged or changed). Raised once, on a background thread.
    public event Action<Recorder, string>? Failed;
    public bool MicOnly => !systemAudio;

    public Recorder(string folder, bool systemAudio)
    {
        this.folder = folder;
        this.systemAudio = systemAudio;
    }

    public void Start()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var mic = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
            Add("me", new WasapiCapture(mic, true, 100));
            if (systemAudio)
            {
                var speakers = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console);
                Add("others", new WasapiLoopbackCapture(speakers));
            }
            foreach (var c in captures) c.StartRecording();
            // Follow a new default device (e.g. a headset plugged in mid-call) by restarting the capture.
            watcher = new DeviceWatcher(() =>
            {
                // Windows sends several notifications per change; the first seconds belong to the previous one.
                if (clock.Elapsed.TotalSeconds > 2) Fail("The audio device changed");
            });
        }
        catch
        {
            Abort();
            throw;
        }
    }

    void Add(string track, IWaveIn capture)
    {
        var writer = new TrackWriter(Path.Combine(folder, track + Transcript.CaptureExtension));
        tracks[track] = writer;
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        stoppedSignals.Add(stopped);
        capture.DataAvailable += (_, e) =>
        {
            if (stopping || e.BytesRecorded == 0) return;
            try { writer.Write(e.Buffer, e.BytesRecorded, capture.WaveFormat, clock.Elapsed.TotalSeconds); }
            catch (Exception ex) { AppPaths.Log($"audio write error ({track}): {ex.Message}"); }
        };
        capture.RecordingStopped += (_, e) =>
        {
            stopped.TrySetResult();
            if (!stopping) Fail(e.Exception?.Message ?? $"The {(track == "me" ? "microphone" : "speaker")} capture stopped");
        };
        captures.Add(capture);
    }

    void Fail(string message)
    {
        if (stopping || Interlocked.Exchange(ref errorRaised, 1) == 1) return;
        Failed?.Invoke(this, message);
    }

    /// Stops capture, closes the files and returns each track's start offset in seconds.
    public async Task<Dictionary<string, double>> StopAsync()
    {
        stopping = true;
        watcher?.Dispose();
        watcher = null;
        foreach (var c in captures)
        {
            try { c.StopRecording(); } catch { }
        }
        await Task.WhenAny(Task.WhenAll(stoppedSignals.Select(s => s.Task)), Task.Delay(3000));
        var starts = new Dictionary<string, double>();
        foreach (var (key, writer) in tracks)
        {
            writer.Close();
            if (writer.StartTime is { } t) starts[key] = t;
        }
        foreach (var c in captures) c.Dispose();
        captures.Clear();
        return Transcript.Offsets(starts);
    }

    void Abort()
    {
        stopping = true;
        watcher?.Dispose();
        foreach (var c in captures)
        {
            try { c.StopRecording(); } catch { }
            try { c.Dispose(); } catch { }
        }
        captures.Clear();
        foreach (var w in tracks.Values) w.Close();
        // A failed start leaves no empty files behind.
        foreach (var w in tracks.Values)
            if (File.Exists(w.Path) && w.StartTime == null) { try { File.Delete(w.Path); } catch { } }
    }

    public void Dispose() => Abort();
}
