using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MeetingNotes.Core;

/// Meeting Notes MCP server: a read-only stdio server (JSON-RPC 2.0, one message per line) that lets Claude Desktop,
/// Claude Code and other MCP clients list, search and read your meetings. A port of mcp/main.swift.
/// It only reads meta.json, notes.md and transcript.md; it never writes and never touches audio files.
public sealed class McpServer
{
    public const string ServerVersion = "1.0";
    public static readonly string[] ProtocolVersions = { "2025-06-18", "2025-03-26", "2024-11-05" };
    public const int MaxText = 100_000;   // characters per get_notes / get_transcript call; use offset for the rest
    public const string Instructions = "Read-only access to the user's recorded meetings from the Meeting Notes app. Use list_meetings or search_meetings to find a meeting id, then get_notes (summary, decisions, action items) or get_transcript (what was said).";

    readonly string root;

    public McpServer(string root)
    {
        this.root = Path.GetFullPath(root);
    }

    /// The app's meetings folder: MEETINGNOTES_DIR (used by the tests), else the app's setting, else the default.
    public static string DefaultRoot()
    {
        var env = Environment.GetEnvironmentVariable("MEETINGNOTES_DIR");
        if (!string.IsNullOrWhiteSpace(env)) return AppPaths.Expand(env);
        return AppSettings.Load().MeetingsDir;
    }

    // MARK: Meetings on disk

    sealed record Entry(string Id, string Folder, Meta Meta, DateTimeOffset Created, string Status)
    {
        public string NotesPath => Path.Combine(Folder, "notes.md");
        public string TranscriptPath => Path.Combine(Folder, "transcript.md");
    }

    static Entry? LoadMeeting(string dir)
    {
        var m = Store.Load(dir);
        return m == null ? null : new Entry(Path.GetFileName(dir), dir, m.Meta, m.Created, m.Status);
    }

    List<Entry> LoadAll()
    {
        if (!Directory.Exists(root)) return new();
        return Directory.EnumerateDirectories(root)
            .Where(d => !Path.GetFileName(d).StartsWith('.'))
            .Select(LoadMeeting).Where(m => m != null).Select(m => m!)
            .OrderByDescending(m => m.Created).ToList();
    }

    /// A meeting by folder name. Rejects anything that isn't a plain folder name inside the meetings folder.
    Entry? Meeting(string id)
    {
        if (id.Length == 0 || id.StartsWith('.') || id.IndexOfAny(new[] { '/', '\\', '\0', ':' }) >= 0) return null;
        return LoadMeeting(Path.Combine(root, id));
    }

    static string? Read(string path)
    {
        try { return File.Exists(path) ? File.ReadAllText(path) : null; }
        catch { return null; }
    }

    // MARK: Formatting

    /// Local time with its offset, like Swift's ISO8601DateFormatter with the current time zone.
    public static string IsoLocal(DateTimeOffset d)
    {
        var local = d.ToLocalTime();
        return local.Offset == TimeSpan.Zero
            ? local.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)
            : local.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture);
    }

    static JsonObject Summary(Entry m)
    {
        var o = new JsonObject
        {
            ["id"] = m.Id, ["title"] = m.Meta.Title, ["status"] = m.Status,
            ["has_notes"] = File.Exists(m.NotesPath), ["has_transcript"] = File.Exists(m.TranscriptPath),
        };
        if (m.Created != DateTimeOffset.MinValue) o["date"] = IsoLocal(m.Created);
        if (m.Meta.Duration is { } d) o["duration"] = Format.Duration(d);
        if (m.Meta.App is { } app) o["app"] = app;
        return o;
    }

    static readonly JsonSerializerOptions Compact = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    static readonly JsonSerializerOptions Pretty = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, WriteIndented = true };

    /// JSON with sorted keys and without escaping slashes or non-ASCII letters.
    public static string Json(JsonNode? value, bool pretty = false) =>
        value == null ? "null" : Sorted(value)!.ToJsonString(pretty ? Pretty : Compact);

    static JsonNode? Sorted(JsonNode? node) => node switch
    {
        JsonObject o => new JsonObject(o.OrderBy(kv => kv.Key, StringComparer.Ordinal)
            .Select(kv => KeyValuePair.Create(kv.Key, Sorted(kv.Value)))),
        JsonArray a => new JsonArray(a.Select(Sorted).ToArray()),
        null => null,
        _ => node.DeepClone(),
    };

    /// Up to `limit` one-line snippets around each case- and accent-insensitive match of `query` in `text`.
    public static List<string> Snippets(string text, string query, int limit = 3)
    {
        var output = new List<string>();
        var from = 0;
        var compare = CultureInfo.InvariantCulture.CompareInfo;
        const CompareOptions options = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;
        while (output.Count < limit && from < text.Length)
        {
            var i = compare.IndexOf(text.AsSpan(from), query.AsSpan(), options, out var length);
            if (i < 0) break;
            var lower = from + i;
            var upper = lower + length;
            var start = Math.Max(0, lower - 80);
            var end = Math.Min(text.Length, upper + 120);
            var s = string.Join(" ", text[start..end].Split('\n', '\r')).Trim(' ', '\t');
            if (start != 0) s = "…" + s;
            if (end != text.Length) s += "…";
            output.Add(s);
            from = end;
        }
        return output;
    }

    /// A slice of a long text (counted in characters as shown), with a note on how to read the rest.
    public static string Page(string text, int offset)
    {
        var starts = StringInfo.ParseCombiningCharacters(text);
        var count = starts.Length;
        var start = Math.Min(Math.Max(0, offset), count);
        var end = Math.Min(start + MaxText, count);
        int Pos(int c) => c >= count ? text.Length : starts[c];
        var output = text[Pos(start)..Pos(end)];
        if (end < count)
            output += $"\n\n[Truncated: showing characters {start}–{end} of {count}. Call again with offset {end} for more.]";
        return output;
    }

    // MARK: Tools

    sealed class ToolError(string message) : Exception(message);
    sealed class RpcError(int code, string message) : Exception(message) { public int Code { get; } = code; }

    static JsonObject Prop(string type, string description) => new() { ["type"] = type, ["description"] = description };

    public static JsonArray ToolList() => new(
        new JsonObject
        {
            ["name"] = "list_meetings",
            ["description"] = "List recorded meetings, newest first, with id, title, date, duration, status and call app. Use the id with get_notes or get_transcript.",
            ["inputSchema"] = new JsonObject
            {
                ["type"] = "object",
                ["properties"] = new JsonObject
                {
                    ["from"] = Prop("string", "Only meetings on or after this date (YYYY-MM-DD)."),
                    ["to"] = Prop("string", "Only meetings on or before this date (YYYY-MM-DD)."),
                    ["limit"] = Prop("integer", "Maximum number of meetings (default 50, max 500)."),
                },
            },
            ["annotations"] = new JsonObject { ["readOnlyHint"] = true },
        },
        new JsonObject
        {
            ["name"] = "search_meetings",
            ["description"] = "Case-insensitive text search across meeting titles, notes and transcripts. Returns matching meetings with snippets.",
            ["inputSchema"] = new JsonObject
            {
                ["type"] = "object",
                ["properties"] = new JsonObject
                {
                    ["query"] = Prop("string", "Text to search for."),
                    ["limit"] = Prop("integer", "Maximum number of meetings (default 20, max 100)."),
                },
                ["required"] = new JsonArray("query"),
            },
            ["annotations"] = new JsonObject { ["readOnlyHint"] = true },
        },
        new JsonObject
        {
            ["name"] = "get_notes",
            ["description"] = "The meeting notes (Markdown: summary, decisions, action items, open questions, key points) for a meeting id.",
            ["inputSchema"] = new JsonObject
            {
                ["type"] = "object",
                ["properties"] = new JsonObject
                {
                    ["id"] = Prop("string", "Meeting id from list_meetings or search_meetings."),
                    ["offset"] = Prop("integer", "Character offset to continue a truncated result."),
                },
                ["required"] = new JsonArray("id"),
            },
            ["annotations"] = new JsonObject { ["readOnlyHint"] = true },
        },
        new JsonObject
        {
            ["name"] = "get_transcript",
            ["description"] = "The full transcript (Markdown, timestamped, with speaker names) for a meeting id. Long transcripts are returned in parts; use offset to continue.",
            ["inputSchema"] = new JsonObject
            {
                ["type"] = "object",
                ["properties"] = new JsonObject
                {
                    ["id"] = Prop("string", "Meeting id from list_meetings or search_meetings."),
                    ["offset"] = Prop("integer", "Character offset to continue a truncated result."),
                },
                ["required"] = new JsonArray("id"),
            },
            ["annotations"] = new JsonObject { ["readOnlyHint"] = true },
        });

    static readonly string[] ToolNames = { "list_meetings", "search_meetings", "get_notes", "get_transcript" };

    static int? Number(JsonObject args, string key) =>
        args[key] is JsonValue v && v.TryGetValue<double>(out var d) && !double.IsNaN(d) ? (int)Math.Clamp(d, int.MinValue, int.MaxValue) : null;

    static int IntArg(JsonObject args, string key, int value, int upper) =>
        Math.Min(Math.Max(1, Number(args, key) ?? value), upper);

    static string? StringArg(JsonObject args, string key) =>
        args[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    static DateTime? DayArg(JsonObject args, string key)
    {
        var s = StringArg(args, key);
        if (string.IsNullOrEmpty(s)) return null;
        if (!DateTime.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var d))
            throw new ToolError($"{key} must be a date like 2026-01-31.");
        return d;
    }

    Entry RequiredMeeting(JsonObject args)
    {
        var id = StringArg(args, "id");
        if (string.IsNullOrEmpty(id)) throw new ToolError("id is required.");
        return Meeting(id) ?? throw new ToolError($"No meeting with id \"{id}\". Use list_meetings to find ids.");
    }

    string CallTool(string name, JsonObject args)
    {
        switch (name)
        {
            case "list_meetings":
            {
                var from = DayArg(args, "from");
                var to = DayArg(args, "to")?.AddDays(1);
                var limit = IntArg(args, "limit", 50, 500);
                var all = LoadAll().Where(m =>
                    (from == null || m.Created.LocalDateTime >= from) && (to == null || m.Created.LocalDateTime < to)).ToList();
                var output = new JsonObject
                {
                    ["meetings"] = new JsonArray(all.Take(limit).Select(m => (JsonNode)Summary(m)).ToArray()),
                    ["total"] = all.Count,
                };
                if (all.Count > limit) output["note"] = $"Showing the newest {limit} of {all.Count}. Narrow the dates or raise limit.";
                return Json(output, pretty: true);
            }
            case "search_meetings":
            {
                var query = (StringArg(args, "query") ?? "").Trim();
                if (query.Length == 0) throw new ToolError("query is required.");
                var limit = IntArg(args, "limit", 20, 100);
                var results = new JsonArray();
                foreach (var m in LoadAll())
                {
                    if (results.Count >= limit) break;
                    var matches = new JsonArray();
                    foreach (var (field, text) in new[] { ("title", (string?)m.Meta.Title), ("notes", Read(m.NotesPath)), ("transcript", Read(m.TranscriptPath)) })
                    {
                        if (text == null) continue;
                        foreach (var s in Snippets(text, query)) matches.Add(new JsonObject { ["in"] = field, ["text"] = s });
                    }
                    if (matches.Count > 0)
                    {
                        var r = Summary(m);
                        r["matches"] = matches;
                        results.Add(r);
                    }
                }
                return Json(new JsonObject { ["query"] = query, ["results"] = results }, pretty: true);
            }
            case "get_notes":
            case "get_transcript":
            {
                var m = RequiredMeeting(args);
                var notes = name == "get_notes";
                var text = Read(notes ? m.NotesPath : m.TranscriptPath)
                    ?? throw new ToolError($"\"{m.Meta.Title}\" has no {(notes ? "notes" : "transcript")} yet (status: {m.Status}).");
                var header = $"# {m.Meta.Title}\n{(m.Created == DateTimeOffset.MinValue ? "" : IsoLocal(m.Created) + "\n")}\n";
                return header + Page(text, Number(args, "offset") ?? 0);
            }
            default:
                throw new ToolError($"Unknown tool: {name}");
        }
    }

    // MARK: Resources (notes and transcripts of recent meetings)

    static string ResourceUri(Entry m, string file) => $"meetingnotes://meetings/{Uri.EscapeDataString(m.Id)}/{file}";

    JsonArray ListResources()
    {
        var output = new JsonArray();
        foreach (var m in LoadAll().Take(100))
        {
            if (File.Exists(m.NotesPath))
                output.Add(new JsonObject { ["uri"] = ResourceUri(m, "notes.md"), ["name"] = $"{m.Meta.Title} – notes", ["mimeType"] = "text/markdown" });
            if (File.Exists(m.TranscriptPath))
                output.Add(new JsonObject { ["uri"] = ResourceUri(m, "transcript.md"), ["name"] = $"{m.Meta.Title} – transcript", ["mimeType"] = "text/markdown" });
        }
        return output;
    }

    string? ReadResource(string uri)
    {
        const string prefix = "meetingnotes://meetings/";
        if (!uri.StartsWith(prefix, StringComparison.Ordinal)) return null;
        var parts = uri[prefix.Length..].Split('/');
        if (parts.Length != 2 || (parts[1] != "notes.md" && parts[1] != "transcript.md")) return null;
        string id;
        try { id = Uri.UnescapeDataString(parts[0]); } catch { return null; }
        var m = Meeting(id);
        if (m == null) return null;
        var text = Read(Path.Combine(m.Folder, parts[1]));
        return text == null ? null : Page(text, 0);
    }

    // MARK: JSON-RPC

    JsonNode Handle(string method, JsonObject p)
    {
        switch (method)
        {
            case "initialize":
                var requested = StringArg(p, "protocolVersion") ?? "";
                return new JsonObject
                {
                    ["protocolVersion"] = ProtocolVersions.Contains(requested) ? requested : ProtocolVersions[0],
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject(), ["resources"] = new JsonObject() },
                    ["serverInfo"] = new JsonObject { ["name"] = "meeting-notes", ["version"] = ServerVersion },
                    ["instructions"] = Instructions,
                };
            case "ping":
                return new JsonObject();
            case "tools/list":
                return new JsonObject { ["tools"] = ToolList() };
            case "tools/call":
                var name = StringArg(p, "name");
                if (name == null || !ToolNames.Contains(name))
                    throw new RpcError(-32602, $"Unknown tool: {name ?? p["name"]?.ToJsonString() ?? ""}");
                try
                {
                    var text = CallTool(name, p["arguments"] as JsonObject ?? new JsonObject());
                    return new JsonObject { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text }), ["isError"] = false };
                }
                catch (ToolError e)
                {
                    return new JsonObject { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = e.Message }), ["isError"] = true };
                }
            case "resources/list":
                return new JsonObject { ["resources"] = ListResources() };
            case "resources/templates/list":
                return new JsonObject { ["resourceTemplates"] = new JsonArray() };
            case "resources/read":
                var uri = StringArg(p, "uri") ?? "";
                var content = ReadResource(uri) ?? throw new RpcError(-32002, $"Resource not found: {uri}");
                return new JsonObject
                {
                    ["contents"] = new JsonArray(new JsonObject { ["uri"] = uri, ["mimeType"] = "text/markdown", ["text"] = content }),
                };
            default:
                throw new RpcError(-32601, $"Method not found: {method}");
        }
    }

    /// One incoming line to the reply line, or null when no reply is due (notifications, responses, blank lines).
    public string? HandleLine(string line)
    {
        if (line.Trim().Length == 0) return null;
        JsonObject? msg;
        try { msg = JsonNode.Parse(line) as JsonObject; }
        catch (JsonException) { msg = null; }
        if (msg == null)
            return Json(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = null, ["error"] = new JsonObject { ["code"] = -32700, ["message"] = "Parse error" } });
        if (StringArg(msg, "method") is not { } method) return null;   // a response to us; we send no requests
        if (!msg.ContainsKey("id")) return null;                          // a notification, e.g. notifications/initialized
        var id = msg["id"]?.DeepClone();
        try
        {
            var result = Handle(method, msg["params"] as JsonObject ?? new JsonObject());
            return Json(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result });
        }
        catch (RpcError e)
        {
            return Json(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["error"] = new JsonObject { ["code"] = e.Code, ["message"] = e.Message } });
        }
        catch (Exception e)
        {
            return Json(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["error"] = new JsonObject { ["code"] = -32603, ["message"] = e.Message } });
        }
    }

    public void Serve(TextReader input, TextWriter output)
    {
        while (input.ReadLine() is { } line)
        {
            if (HandleLine(line) is { } reply)
            {
                output.Write(reply);
                output.Write('\n');
                output.Flush();
            }
        }
    }
}

/// How AI apps connect to the MCP server: the Claude Desktop extension and the commands/config for other apps.
public static class McpSetup
{
    public static string ClaudeCodeCommand(string exe) => $"claude mcp add --scope user meeting-notes -- \"{exe}\"";
    public static string CodexCommand(string exe) => $"codex mcp add meeting-notes -- \"{exe}\"";

    /// For Command Prompt or PowerShell 7 (forward slashes, so the JSON needs no backslash escapes).
    public static string VsCodeCommand(string exe)
    {
        var json = McpServer.Json(new JsonObject { ["name"] = "meeting-notes", ["command"] = exe.Replace('\\', '/') });
        return $"code --add-mcp \"{json.Replace("\"", "\\\"")}\"";
    }

    public static string ConfigJson(string exe) => McpServer.Json(new JsonObject
    {
        ["mcpServers"] = new JsonObject { ["meeting-notes"] = new JsonObject { ["command"] = exe } },
    }, pretty: true);

    /// The extension's manifest. It runs the installed meetingnotes-mcp.exe, so app updates reach Claude Desktop
    /// without reinstalling the extension (like the Mac launcher script).
    public static string Manifest(string exe, bool withIcon)
    {
        var m = new JsonObject
        {
            ["manifest_version"] = "0.3",
            ["name"] = "meeting-notes",
            ["display_name"] = "Meeting Notes",
            ["version"] = "1.0.0",
            ["description"] = "Read-only access to the meetings recorded by the Meeting Notes app: list, search and read notes and transcripts.",
            ["long_description"] = "Lets Claude look up your meetings from the Meeting Notes app. It reads meta.json, notes.md and transcript.md in your meetings folder (the one set in the app's Settings), never audio files, and can't change or delete anything.",
            ["author"] = new JsonObject { ["name"] = "Meeting Notes", ["url"] = "https://github.com/horken7/MeetingNotes" },
            ["homepage"] = "https://github.com/horken7/MeetingNotes",
            ["repository"] = new JsonObject { ["type"] = "git", ["url"] = "https://github.com/horken7/MeetingNotes" },
            ["license"] = "MIT",
            ["server"] = new JsonObject
            {
                ["type"] = "binary",
                ["entry_point"] = "server/meetingnotes-mcp.cmd",
                ["mcp_config"] = new JsonObject { ["command"] = exe, ["args"] = new JsonArray() },
            },
            ["tools"] = new JsonArray(
                new JsonObject { ["name"] = "list_meetings", ["description"] = "List recorded meetings, newest first, with id, title, date, duration, status and call app." },
                new JsonObject { ["name"] = "search_meetings", ["description"] = "Case-insensitive text search across meeting titles, notes and transcripts, with snippets." },
                new JsonObject { ["name"] = "get_notes", ["description"] = "The meeting notes (summary, decisions, action items, open questions, key points) for a meeting." },
                new JsonObject { ["name"] = "get_transcript", ["description"] = "The full timestamped transcript for a meeting." }),
            ["keywords"] = new JsonArray("meetings", "notes", "transcripts"),
            ["compatibility"] = new JsonObject { ["platforms"] = new JsonArray("win32") },
        };
        if (withIcon) m["icon"] = "icon.png";
        var options = new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        return m.ToJsonString(options);
    }

    /// Writes MeetingNotes.mcpb (a zip with manifest.json) that Claude Desktop installs on double-click.
    public static void WriteExtension(string output, string exe, string? icon)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        var tmp = output + ".tmp";
        if (File.Exists(tmp)) File.Delete(tmp);
        using (var zip = System.IO.Compression.ZipFile.Open(tmp, System.IO.Compression.ZipArchiveMode.Create))
        {
            var withIcon = icon != null && File.Exists(icon);
            void Add(string name, string text)
            {
                using var w = new StreamWriter(zip.CreateEntry(name).Open(), new UTF8Encoding(false));
                w.Write(text);
            }
            Add("manifest.json", Manifest(exe, withIcon));
            // The entry point the manifest names; Claude Desktop starts the exe from mcp_config directly.
            Add("server/meetingnotes-mcp.cmd", $"@\"{exe}\" %*\r\n");
            if (withIcon) System.IO.Compression.ZipFileExtensions.CreateEntryFromFile(zip, icon!, "icon.png");
        }
        File.Move(tmp, output, overwrite: true);
    }
}
