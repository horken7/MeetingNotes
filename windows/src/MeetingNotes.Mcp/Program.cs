using System.Text;
using MeetingNotes.Core;

// Meeting Notes MCP server: one JSON-RPC message per line on stdin/stdout. See McpServer in MeetingNotes.Core.
// Connect with: claude mcp add --scope user meeting-notes -- "%LOCALAPPDATA%\Programs\MeetingNotes\meetingnotes-mcp.exe"
var utf8 = new UTF8Encoding(false);
using var input = new StreamReader(Console.OpenStandardInput(), utf8);
using var output = new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true };
new McpServer(McpServer.DefaultRoot()).Serve(input, output);
