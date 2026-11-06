using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;
using MeetingNotes.Core;
using Xunit;

namespace MeetingNotes.Tests;

public class McpTests : IDisposable
{
    readonly TempDir dir = new();
    readonly McpServer server;

    public McpTests()
    {
        Meeting("2026-01-10 0900 Budget", "{\"title\":\"Budget\",\"created\":\"2026-01-10T08:00:00Z\",\"status\":\"done\",\"duration\":1805,\"app\":\"Microsoft Teams\"}",
            notes: "# Budget\n\n## Summary\nWe cut the travel budget by 10 percent.",
            transcript: "# Budget: transcript\n\n[0:00] **Anna:** Vi måste spara på resor.\n\n[0:05] **Others:** Ja, budgeten är för hög.");
        Meeting("2026-02-01 1400 Retro", "{\"title\":\"Retro\",\"created\":\"2026-02-01T13:00:00Z\",\"status\":\"summarizing\"}",
            notes: null, transcript: "# Retro: transcript\n\n" + new string('x', 150_000));
        Directory.CreateDirectory(Path.Combine(dir.Path, ".hidden"));
        File.WriteAllText(Path.Combine(dir.Path, "secret.txt"), "not a meeting");
        server = new McpServer(dir.Path);
    }

    void Meeting(string name, string meta, string? notes, string? transcript)
    {
        var f = dir.Sub(name);
        File.WriteAllText(Path.Combine(f, "meta.json"), meta);
        if (notes != null) File.WriteAllText(Path.Combine(f, "notes.md"), notes);
        if (transcript != null) File.WriteAllText(Path.Combine(f, "transcript.md"), transcript);
        File.WriteAllText(Path.Combine(f, "me.wav"), "audio");
    }

    public void Dispose() => dir.Dispose();

    JsonObject Call(string method, JsonObject? p = null, int id = 1)
    {
        var request = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method };
        if (p != null) request["params"] = p;
        var line = server.HandleLine(request.ToJsonString());
        Assert.NotNull(line);
        Assert.DoesNotContain("\n", line);   // one message per line
        return JsonNode.Parse(line!)!.AsObject();
    }

    (string Text, bool IsError) Tool(string name, JsonObject? args = null)
    {
        var r = Call("tools/call", new JsonObject { ["name"] = name, ["arguments"] = args ?? new JsonObject() })["result"]!;
        return ((string)r["content"]![0]!["text"]!, (bool)r["isError"]!);
    }

    [Fact]
    public void Initializes()
    {
        var r = Call("initialize", new JsonObject { ["protocolVersion"] = "2025-03-26" });
        Assert.Equal("2.0", (string?)r["jsonrpc"]);
        Assert.Equal(1, (int)r["id"]!);
        Assert.Equal("2025-03-26", (string?)r["result"]!["protocolVersion"]);
        Assert.Equal("meeting-notes", (string?)r["result"]!["serverInfo"]!["name"]);
        Assert.Equal("2025-06-18", (string?)Call("initialize", new JsonObject { ["protocolVersion"] = "1999-01-01" })["result"]!["protocolVersion"]);
        Assert.NotNull(Call("ping")["result"]);
    }

    [Fact]
    public void ListsTools()
    {
        var tools = Call("tools/list")["result"]!["tools"]!.AsArray();
        Assert.Equal(new[] { "list_meetings", "search_meetings", "get_notes", "get_transcript" }, tools.Select(t => (string)t!["name"]!));
        Assert.All(tools, t => Assert.True((bool)t!["annotations"]!["readOnlyHint"]!));
    }

    [Fact]
    public void ListsMeetingsNewestFirstWithDates()
    {
        var (text, isError) = Tool("list_meetings");
        Assert.False(isError);
        var r = JsonNode.Parse(text)!;
        Assert.Equal(2, (int)r["total"]!);
        var first = r["meetings"]![0]!;
        Assert.Equal("2026-02-01 1400 Retro", (string?)first["id"]);
        Assert.Equal("summarizing", (string?)first["status"]);
        Assert.False((bool)first["has_notes"]!);
        var budget = r["meetings"]![1]!;
        Assert.Equal("30:05", (string?)budget["duration"]);
        Assert.Equal("Microsoft Teams", (string?)budget["app"]);
        Assert.Equal(DateTimeOffset.Parse("2026-01-10T08:00:00Z"), DateTimeOffset.Parse((string)budget["date"]!));

        var (filtered, _) = Tool("list_meetings", new JsonObject { ["from"] = "2026-01-01", ["to"] = "2026-01-31" });
        Assert.Equal(1, (int)JsonNode.Parse(filtered)!["total"]!);
        var (limited, _) = Tool("list_meetings", new JsonObject { ["limit"] = 1 });
        Assert.Contains("Showing the newest 1 of 2", limited);
        var (bad, badError) = Tool("list_meetings", new JsonObject { ["from"] = "January" });
        Assert.True(badError);
        Assert.Equal("from must be a date like 2026-01-31.", bad);
    }

    [Fact]
    public void SearchesTitlesNotesAndTranscripts()
    {
        var (text, _) = Tool("search_meetings", new JsonObject { ["query"] = "BUDGETEN" });
        var results = JsonNode.Parse(text)!["results"]!.AsArray();
        var hit = Assert.Single(results)!;
        Assert.Equal("Budget", (string?)hit["title"]);
        var matches = hit["matches"]!.AsArray();
        Assert.Contains(matches, m => (string?)m!["in"] == "transcript" && ((string)m["text"]!).Contains("budgeten är för hög"));
        // Accent-insensitive.
        var (accent, _) = Tool("search_meetings", new JsonObject { ["query"] = "maste spara" });
        Assert.Single(JsonNode.Parse(accent)!["results"]!.AsArray());
        Assert.True(Tool("search_meetings", new JsonObject { ["query"] = "  " }).IsError);
    }

    [Fact]
    public void ReadsNotesAndPagesLongTranscripts()
    {
        var (notes, _) = Tool("get_notes", new JsonObject { ["id"] = "2026-01-10 0900 Budget" });
        Assert.StartsWith("# Budget\n2026-01-10T", notes);
        Assert.Contains("travel budget", notes);

        var (part, _) = Tool("get_transcript", new JsonObject { ["id"] = "2026-02-01 1400 Retro" });
        Assert.Contains("[Truncated: showing characters 0–100000 of 150021. Call again with offset 100000 for more.]", part);
        var (rest, _) = Tool("get_transcript", new JsonObject { ["id"] = "2026-02-01 1400 Retro", ["offset"] = 100_000 });
        Assert.DoesNotContain("Truncated", rest);

        var (none, isError) = Tool("get_notes", new JsonObject { ["id"] = "2026-02-01 1400 Retro" });
        Assert.True(isError);
        Assert.Equal("\"Retro\" has no notes yet (status: summarizing).", none);
    }

    [Theory]
    [InlineData("..")]
    [InlineData("../x")]
    [InlineData("..\\x")]
    [InlineData("C:\\Windows")]
    [InlineData(".hidden")]
    [InlineData("secret.txt")]
    [InlineData("")]
    public void RejectsPathsOutsideTheMeetingsFolder(string id)
    {
        var (text, isError) = Tool("get_transcript", new JsonObject { ["id"] = id });
        Assert.True(isError);
        Assert.True(text.StartsWith("No meeting with id") || text == "id is required.", text);
    }

    [Fact]
    public void ListsAndReadsResources()
    {
        var resources = Call("resources/list")["result"]!["resources"]!.AsArray();
        Assert.Equal(3, resources.Count);
        var uri = (string)resources.First(r => ((string)r!["uri"]!).EndsWith("notes.md"))!["uri"]!;
        Assert.Equal("meetingnotes://meetings/2026-01-10%200900%20Budget/notes.md", uri);
        var content = Call("resources/read", new JsonObject { ["uri"] = uri })["result"]!["contents"]![0]!;
        Assert.Contains("travel budget", (string)content["text"]!);
        var missing = Call("resources/read", new JsonObject { ["uri"] = "meetingnotes://meetings/..%2F/notes.md" });
        Assert.Equal(-32002, (int)missing["error"]!["code"]!);
        Assert.Empty(Call("resources/templates/list")["result"]!["resourceTemplates"]!.AsArray());
    }

    [Fact]
    public void JsonRpcErrorsAndNotifications()
    {
        Assert.Equal(-32601, (int)Call("nope")["error"]!["code"]!);
        Assert.Equal(-32602, (int)Call("tools/call", new JsonObject { ["name"] = "delete_everything" })["error"]!["code"]!);
        var parse = JsonNode.Parse(server.HandleLine("{oops")!)!;
        Assert.Equal(-32700, (int)parse["error"]!["code"]!);
        Assert.Null(parse["id"]);
        Assert.Null(server.HandleLine("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"));
        Assert.Null(server.HandleLine("   "));
        Assert.Null(server.HandleLine("{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}"));
        // String ids come back as strings.
        Assert.Equal("abc", (string?)JsonNode.Parse(server.HandleLine("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"ping\"}")!)!["id"]);
    }

    [Fact]
    public void JsonKeepsLettersAndSlashes()
    {
        var json = McpServer.Json(new JsonObject { ["b"] = "Möte/å", ["a"] = 1 });
        Assert.Equal("{\"a\":1,\"b\":\"Möte/å\"}", json);
    }

    /// The real meetingnotes-mcp executable over stdin/stdout, as Claude Desktop runs it.
    [Fact]
    public async Task ExecutableRoundTrip()
    {
        var dll = Path.Combine(AppContext.BaseDirectory, "meetingnotes-mcp.dll");
        Assert.True(File.Exists(dll), dll);
        var dotnet = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet";
        var psi = new ProcessStartInfo(dotnet)
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false,
            StandardOutputEncoding = new UTF8Encoding(false), StandardInputEncoding = new UTF8Encoding(false),
        };
        psi.ArgumentList.Add(dll);
        psi.Environment["MEETINGNOTES_DIR"] = dir.Path;
        using var p = Process.Start(psi)!;
        await p.StandardInput.WriteLineAsync("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}");
        await p.StandardInput.WriteLineAsync("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
        await p.StandardInput.WriteLineAsync("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"search_meetings\",\"arguments\":{\"query\":\"resor\"}}}");
        p.StandardInput.Close();
        var output = await p.StandardOutput.ReadToEndAsync();
        await p.WaitForExitAsync();
        var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(2, lines.Length);
        Assert.Equal("meeting-notes", (string?)JsonNode.Parse(lines[0])!["result"]!["serverInfo"]!["name"]);
        var text = (string)JsonNode.Parse(lines[1])!["result"]!["content"]![0]!["text"]!;
        Assert.Contains("Vi måste spara på resor.", text);
    }
}

public class McpSetupTests
{
    const string Exe = @"C:\Users\Anna\AppData\Local\Programs\MeetingNotes\meetingnotes-mcp.exe";

    [Fact]
    public void ManifestRunsTheInstalledServer()
    {
        var m = JsonNode.Parse(McpSetup.Manifest(Exe, withIcon: false))!;
        Assert.Equal("0.3", (string?)m["manifest_version"]);
        Assert.Equal("binary", (string?)m["server"]!["type"]);
        Assert.Equal(Exe, (string?)m["server"]!["mcp_config"]!["command"]);
        Assert.Equal("win32", (string?)m["compatibility"]!["platforms"]![0]);
        Assert.Null(m["icon"]);
        Assert.Equal(4, m["tools"]!.AsArray().Count);
    }

    [Fact]
    public void WritesTheExtension()
    {
        using var dir = new TempDir();
        var icon = Path.Combine(dir.Path, "icon.png");
        File.WriteAllBytes(icon, new byte[] { 1, 2, 3 });
        var output = Path.Combine(dir.Path, "out", "MeetingNotes.mcpb");
        McpSetup.WriteExtension(output, Exe, icon);
        using var zip = ZipFile.OpenRead(output);
        Assert.Equal(new[] { "icon.png", "manifest.json", "server/meetingnotes-mcp.cmd" }, zip.Entries.Select(e => e.FullName).OrderBy(n => n));
        using var reader = new StreamReader(zip.GetEntry("manifest.json")!.Open());
        Assert.Equal("icon.png", (string?)JsonNode.Parse(reader.ReadToEnd())!["icon"]);
    }

    [Fact]
    public void CommandsForOtherApps()
    {
        Assert.Equal($"claude mcp add --scope user meeting-notes -- \"{Exe}\"", McpSetup.ClaudeCodeCommand(Exe));
        Assert.Equal($"codex mcp add meeting-notes -- \"{Exe}\"", McpSetup.CodexCommand(Exe));
        Assert.Equal("code --add-mcp \"{\\\"command\\\":\\\"C:/Users/Anna/AppData/Local/Programs/MeetingNotes/meetingnotes-mcp.exe\\\",\\\"name\\\":\\\"meeting-notes\\\"}\"",
            McpSetup.VsCodeCommand(Exe));
        var config = JsonNode.Parse(McpSetup.ConfigJson(Exe))!;
        Assert.Equal(Exe, (string?)config["mcpServers"]!["meeting-notes"]!["command"]);
    }
}
