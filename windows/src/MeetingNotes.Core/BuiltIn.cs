using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;

namespace MeetingNotes.Core;

/// The built-in notes model: Gemma 3 4B (Q4_K_M GGUF) run by llama.cpp's llama-server, both in the install folder.
/// No account, no download, nothing to set up. The server is started for one meeting's notes, listens on a random
/// loopback port with a random API key, and is stopped afterwards.
public static class BuiltIn
{
    public const string ModelFile = "gemma-3-4b-it-Q4_K_M.gguf";
    public const string ModelName = "Gemma 3 4B";
    /// Tokens per call. 12k fits about half an hour of conversation in one go; longer meetings are done in parts.
    public const int ContextTokens = 12_288;
    public const int NotesTokens = 1_200;
    public const int PartTokens = 600;

    /// The model to use: the installed one, else one copied to the data folder.
    public static string Model => AppPaths.ResolveModel(ModelFile, AppPaths.BundledModelDir, AppPaths.DataDir);
    public static string Server => Path.Combine(AppPaths.AppDir, "llama", "llama-server.exe");
    public static bool Installed => File.Exists(Model) && File.Exists(Server);

    /// What's missing, for the setup checks and errors; null when ready.
    public static string? Problem(string? server = null, string? model = null)
    {
        server ??= Server;
        model ??= Model;
        if (!File.Exists(server)) return "The built-in notes model's program (llama\\llama-server.exe) is missing. Reinstall Meeting Notes, or choose another notes provider in Settings > Notes.";
        if (!File.Exists(model)) return $"The built-in notes model ({ModelFile}) is missing. Reinstall Meeting Notes, or choose another notes provider in Settings > Notes.";
        return null;
    }

    /// One summary at a time: each run loads the 2.5 GB model.
    static readonly SemaphoreSlim Gate = new(1, 1);
    /// Set when the graphics card (Vulkan) failed once; later runs go straight to the CPU.
    static bool gpuFailed;

    /// `language` is a code from the settings or the meeting ("sv", "auto"…).
    public static async Task<string> SummarizeAsync(string transcript, Meta meta, AppSettings settings, string? language,
                                                    IProgress<string>? progress = null, CancellationToken cancel = default)
    {
        if (Problem() is { } problem) throw new PipelineException(problem);
        var lang = LocalPrompts.LanguageName(language) ?? Ollama.Language(transcript);
        if (LocalPrompts.WordCount(transcript) < LocalPrompts.MinimumWords) return LocalPrompts.TooLittle(lang);

        progress?.Report("Waiting for another meeting's notes…");
        await Gate.WaitAsync(cancel);
        LlamaServer? server = null;
        try
        {
            var useGpu = settings.BuiltInGpu && !gpuFailed;
            progress?.Report($"Loading the built-in model ({ModelName})…");
            server = await StartAsync(useGpu, cancel);
            string step = "";
            var summarizer = new Summarizer(ContextTokens, async (system, user, max, ct) =>
            {
                try
                {
                    return await server.ChatAsync(system, user, max, p => progress?.Report(step + p), ct);
                }
                catch (LlamaServerDiedException) when (server.Gpu && !ct.IsCancellationRequested)
                {
                    // The graphics driver crashed llama-server: do the rest on the CPU.
                    gpuFailed = true;
                    AppPaths.Log("llama-server died on the GPU; continuing on the CPU");
                    server.Dispose();
                    server = await StartAsync(false, ct);
                    return await server.ChatAsync(system, user, max, p => progress?.Report(step + p), ct);
                }
            }, notesTokens: NotesTokens, partTokens: PartTokens, onStep: (i, n) =>
            {
                step = n == 1 ? "Writing the notes on this PC" : i < n ? $"Notes for part {i} of {n - 1}" : "Combining the notes";
                progress?.Report(step + "…");
            });
            var notes = await summarizer.SummarizeAsync(meta, settings.MyName, transcript, settings.Instructions, lang, cancel);
            // Only the default format is tidied; custom instructions may want something else.
            return settings.Instructions == Prompt.DefaultInstructions ? Summarizer.TidyHeadings(notes) : notes;
        }
        finally
        {
            server?.Dispose();
            Gate.Release();
        }
    }

    static async Task<LlamaServer> StartAsync(bool gpu, CancellationToken cancel)
    {
        if (gpu)
        {
            try
            {
                return await LlamaServer.StartAsync(Server, Model, ContextTokens, gpu: true, cancel);
            }
            catch (PipelineException e)
            {
                gpuFailed = true;
                AppPaths.Log($"llama-server failed with the GPU, trying the CPU: {e.Message}");
            }
        }
        return await LlamaServer.StartAsync(Server, Model, ContextTokens, gpu: false, cancel);
    }

    /// The chat request: notes need little creativity, so sampling is nearly greedy with a mild repeat penalty
    /// (the phone apps' settings).
    public static JsonObject ChatBody(string system, string user, int maxTokens, bool stream = true) => new()
    {
        ["messages"] = new JsonArray(
            new JsonObject { ["role"] = "system", ["content"] = system },
            new JsonObject { ["role"] = "user", ["content"] = user }),
        ["max_tokens"] = maxTokens,
        ["temperature"] = 0.2,
        ["top_p"] = 0.9,
        ["top_k"] = 40,
        ["repeat_penalty"] = 1.1,
        ["repeat_last_n"] = 64,
        ["stream"] = stream,
        // Streams how far it is through reading the prompt, which takes most of the time on a CPU.
        ["return_progress"] = stream,
        ["cache_prompt"] = false,
    };

    /// The command line for llama-server.
    public static List<string> ServerArgs(string model, int context, int port, string apiKey, bool gpu)
    {
        var args = new List<string>
        {
            "-m", model, "-c", context.ToString(), "--host", "127.0.0.1", "--port", port.ToString(),
            "--api-key", apiKey, "-np", "1", "--no-webui",
        };
        // Without a GPU (or when it failed), skip the Vulkan backend entirely.
        if (!gpu) args.AddRange(new[] { "--device", "none", "-ngl", "0" });
        return args;
    }

    /// One server-sent event from a streaming chat completion: the text it adds, prompt progress (0 to 1), an
    /// error message, or the end.
    public sealed record StreamEvent(string? Text = null, double? PromptProgress = null, string? Error = null, bool Done = false);

    public static StreamEvent? ParseEvent(string line)
    {
        if (!line.StartsWith("data:", StringComparison.Ordinal))
        {
            if (line.StartsWith("error:", StringComparison.Ordinal)) return new StreamEvent(Error: ErrorMessage(line[6..].Trim()) ?? line[6..].Trim());
            return null;
        }
        var data = line[5..].Trim();
        if (data == "[DONE]") return new StreamEvent(Done: true);
        JsonNode? n;
        try { n = JsonNode.Parse(data); } catch { return null; }
        if (n == null) return null;
        if (n["error"] != null) return new StreamEvent(Error: ErrorMessage(data) ?? "unknown error");
        double? fraction = null;
        if (n["prompt_progress"] is JsonObject pp && pp["total"] is JsonValue t && pp["processed"] is JsonValue d)
        {
            var total = t.GetValue<double>();
            if (total > 0) fraction = Math.Clamp(d.GetValue<double>() / total, 0, 1);
        }
        var choice = n["choices"]?.AsArray().FirstOrDefault();
        var text = choice?["delta"]?["content"] is JsonValue c && c.TryGetValue<string>(out var s) ? s : null;
        var finished = choice?["finish_reason"] is JsonValue f && f.TryGetValue<string>(out var reason) && reason.Length > 0;
        if (text == null && fraction == null && !finished) return null;
        return new StreamEvent(Text: text, PromptProgress: fraction, Done: false);
    }

    /// `{"error":{"message":"…"}}` or `{"error":"…"}`.
    public static string? ErrorMessage(string json)
    {
        try
        {
            var e = JsonNode.Parse(json)?["error"];
            if (e is JsonValue v && v.TryGetValue<string>(out var s)) return s;
            return e?["message"]?.GetValue<string>();
        }
        catch
        {
            return null;
        }
    }

    /// A short, plain explanation for an error from llama-server.
    public static string Explain(string error)
    {
        var e = error.ToLowerInvariant();
        if (e.Contains("context") && (e.Contains("exceed") || e.Contains("too long") || e.Contains("size")))
            return "The transcript part was too long for the built-in model. Press Retry.";
        if (e.Contains("out of memory") || e.Contains("failed to allocate") || e.Contains("unable to allocate"))
            return "This PC ran out of memory for the built-in model (it needs about 4 GB free). Close some programs and press Retry, or choose another notes provider in Settings > Notes.";
        return $"The built-in model couldn't write the notes: {(error.Length > 300 ? error[..300] : error)}";
    }
}

/// llama-server ended while answering (a crash, usually in a graphics driver).
public sealed class LlamaServerDiedException(string message) : Exception(message);

/// A running llama-server process and its HTTP API.
public sealed class LlamaServer : IDisposable
{
    readonly Process process;
    readonly Uri baseUrl;
    readonly string apiKey;
    readonly StringBuilder log = new();
    readonly HttpClient client;
    readonly IDisposable? job;
    public bool Gpu { get; }

    /// Replaced in tests.
    public static HttpMessageHandler Handler { get; set; } = new SocketsHttpHandler();

    LlamaServer(Process process, Uri baseUrl, string apiKey, bool gpu, IDisposable? job)
    {
        this.process = process;
        this.baseUrl = baseUrl;
        this.apiKey = apiKey;
        this.job = job;
        Gpu = gpu;
        client = new HttpClient(Handler, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
    }

    string LogTail
    {
        get
        {
            lock (log)
            {
                var s = log.ToString().Trim();
                return s.Length > 600 ? s[^600..] : s;
            }
        }
    }

    public static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    /// Starts the server and waits until the model is loaded (up to 5 minutes: a slow disk and an antivirus scan
    /// of the 2.5 GB file can take a while the first time).
    public static async Task<LlamaServer> StartAsync(string exe, string model, int context, bool gpu, CancellationToken cancel)
    {
        var port = FreePort();
        var key = Guid.NewGuid().ToString("N");
        // llama-server reads its arguments in the Windows ANSI code page: use the short (8.3) path for a model in a
        // folder with non-ASCII letters (C:\Users\Åsa\…).
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(exe)!,
        };
        foreach (var a in BuiltIn.ServerArgs(Pipeline.ShortPath(model), context, port, key, gpu)) psi.ArgumentList.Add(a);
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        try
        {
            if (!p.Start()) throw new PipelineException("Couldn't start the built-in model (llama-server.exe).");
        }
        catch (System.ComponentModel.Win32Exception e)
        {
            throw new PipelineException($"Couldn't start the built-in model (llama-server.exe): {e.Message}");
        }
        // The server is killed with the app, even if the app crashes.
        var job = OperatingSystem.IsWindows() ? KillOnCloseJob.TryAssign(p) : null;
        var server = new LlamaServer(p, new Uri($"http://127.0.0.1:{port}"), key, gpu, job);
        p.OutputDataReceived += (_, e) => server.Append(e.Data);
        p.ErrorDataReceived += (_, e) => server.Append(e.Data);
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        AppPaths.Log($"llama-server started on port {port} ({(gpu ? "GPU if available" : "CPU")})");
        try
        {
            await server.WaitReadyAsync(TimeSpan.FromMinutes(5), cancel);
            return server;
        }
        catch
        {
            server.Dispose();
            throw;
        }
    }

    void Append(string? line)
    {
        if (line == null) return;
        lock (log)
        {
            log.AppendLine(line);
            if (log.Length > 20_000) log.Remove(0, log.Length - 10_000);
        }
    }

    async Task WaitReadyAsync(TimeSpan limit, CancellationToken cancel)
    {
        var until = DateTime.UtcNow + limit;
        using var probe = new HttpClient(Handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(5) };
        while (true)
        {
            cancel.ThrowIfCancellationRequested();
            if (process.HasExited)
            {
                AppPaths.Log($"llama-server exited with {process.ExitCode}: {LogTail}");
                throw new PipelineException(BuiltIn.Explain($"llama-server stopped while loading the model (exit code {process.ExitCode}). {LastLines(LogTail, 3)}"));
            }
            try
            {
                using var r = await probe.GetAsync(new Uri(baseUrl, "/health"), cancel);
                if (r.StatusCode == HttpStatusCode.OK) return;
            }
            catch (HttpRequestException) { }
            catch (TaskCanceledException) when (!cancel.IsCancellationRequested) { }
            if (DateTime.UtcNow > until) throw new PipelineException("The built-in model took over 5 minutes to load. Press Retry.");
            await Task.Delay(300, cancel);
        }
    }

    static string LastLines(string text, int n) =>
        string.Join(" ", text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).TakeLast(n));

    /// Sends one chat request and streams the answer. `progress` gets short status texts.
    public async Task<string> ChatAsync(string system, string user, int maxTokens, Action<string>? progress, CancellationToken cancel)
    {
        var body = BuiltIn.ChatBody(system, user, maxTokens);
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(baseUrl, "/v1/chat/completions"))
        {
            Content = new StringContent(Ollama.Json(body), Encoding.UTF8, "application/json"),
        };
        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
        }
        catch (HttpRequestException e)
        {
            throw Died(e.Message);
        }
        using (response)
        {
            if (response.StatusCode != HttpStatusCode.OK)
            {
                var data = await response.Content.ReadAsStringAsync(cancel);
                throw new PipelineException(BuiltIn.Explain(BuiltIn.ErrorMessage(data) ?? $"HTTP {(int)response.StatusCode} {data}"));
            }
            var answer = new StringBuilder();
            var lastReport = DateTime.MinValue;
            var words = 0;
            try
            {
                using var stream = await response.Content.ReadAsStreamAsync(cancel);
                using var reader = new StreamReader(stream, Encoding.UTF8);
                while (await reader.ReadLineAsync(cancel) is { } line)
                {
                    if (line.Length == 0) continue;
                    var ev = BuiltIn.ParseEvent(line);
                    if (ev == null) continue;
                    if (ev.Error != null) throw new PipelineException(BuiltIn.Explain(ev.Error));
                    if (ev.Done) break;
                    if (ev.Text != null)
                    {
                        answer.Append(ev.Text);
                        words += ev.Text.Count(c => c == ' ' || c == '\n');
                    }
                    if (DateTime.UtcNow - lastReport > TimeSpan.FromSeconds(1))
                    {
                        lastReport = DateTime.UtcNow;
                        if (ev.PromptProgress is { } f && answer.Length == 0) progress?.Invoke($" (reading the transcript, {f:P0})");
                        else if (answer.Length > 0) progress?.Invoke($" ({words} words written)");
                    }
                }
            }
            catch (IOException e) when (!cancel.IsCancellationRequested)
            {
                throw Died(e.Message);
            }
            catch (HttpRequestException e) when (!cancel.IsCancellationRequested)
            {
                throw Died(e.Message);
            }
            var text = answer.ToString().Trim();
            if (text.Length == 0) throw new PipelineException("The built-in model returned no notes. Press Retry.");
            return text;
        }
    }

    Exception Died(string detail)
    {
        try { process.WaitForExit(2000); } catch { }
        AppPaths.Log($"llama-server request failed ({detail}): {LogTail}");
        if (process.HasExited)
            return new LlamaServerDiedException(BuiltIn.Explain($"llama-server stopped (exit code {process.ExitCode}). {LastLines(LogTail, 3)}"));
        return new PipelineException($"Couldn't reach the built-in model: {detail}");
    }

    public void Dispose()
    {
        client.Dispose();
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
        try { process.WaitForExit(5000); } catch { }
        process.Dispose();
        job?.Dispose();
    }
}

/// A Windows job object that kills its processes when the app's handle to it closes (also when the app crashes).
static class KillOnCloseJob
{
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters { public ulong a, b, c, d, e, f; }

    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits
    {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, int length);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

    sealed class Handle(IntPtr h) : IDisposable
    {
        IntPtr h = h;
        public void Dispose()
        {
            if (h != IntPtr.Zero) CloseHandle(h);
            h = IntPtr.Zero;
        }
    }

    public static IDisposable? TryAssign(Process p)
    {
        try
        {
            var job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return null;
            var info = new ExtendedLimits { Basic = new BasicLimits { LimitFlags = 0x2000 } };   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(job, 9, ref info, Marshal.SizeOf<ExtendedLimits>()) || !AssignProcessToJobObject(job, p.Handle))
            {
                CloseHandle(job);
                return null;
            }
            return new Handle(job);
        }
        catch
        {
            return null;
        }
    }
}
