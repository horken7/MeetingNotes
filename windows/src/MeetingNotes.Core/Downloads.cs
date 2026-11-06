using System.Net.Http.Headers;

namespace MeetingNotes.Core;

/// Downloads the speech models on first run, resuming a partial download.
public static class Downloads
{
    public static HttpMessageHandler Handler { get; set; } = new SocketsHttpHandler();

    /// Progress is (bytes so far, total bytes or null).
    public static async Task DownloadAsync(string url, string destination, IProgress<(long Done, long? Total)>? progress,
                                           CancellationToken cancel = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var part = destination + ".part";
        using var client = new HttpClient(Handler, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("MeetingNotes/1.0");
        long existing = File.Exists(part) ? new FileInfo(part).Length : 0;
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (existing > 0) request.Headers.Range = new RangeHeaderValue(existing, null);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
        if (response.StatusCode == System.Net.HttpStatusCode.RequestedRangeNotSatisfiable)
        {
            // The partial file is already complete.
            File.Move(part, destination, overwrite: true);
            return;
        }
        response.EnsureSuccessStatusCode();
        var resumed = response.StatusCode == System.Net.HttpStatusCode.PartialContent;
        if (!resumed) existing = 0;
        long? total = response.Content.Headers.ContentLength is { } len ? len + existing : null;
        await using (var output = new FileStream(part, resumed ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, true))
        await using (var input = await response.Content.ReadAsStreamAsync(cancel))
        {
            var buffer = new byte[1 << 16];
            var done = existing;
            var lastReport = DateTime.MinValue;
            int read;
            while ((read = await input.ReadAsync(buffer, cancel)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, read), cancel);
                done += read;
                if ((DateTime.UtcNow - lastReport).TotalMilliseconds > 200)
                {
                    progress?.Report((done, total));
                    lastReport = DateTime.UtcNow;
                }
            }
            progress?.Report((done, total));
            if (total is { } t && done < t) throw new IOException("The download was interrupted. Try again to continue it.");
        }
        File.Move(part, destination, overwrite: true);
    }

    public static string Size(long bytes) => bytes >= 1_000_000_000
        ? $"{bytes / 1e9:0.00} GB"
        : $"{bytes / 1e6:0} MB";
}
