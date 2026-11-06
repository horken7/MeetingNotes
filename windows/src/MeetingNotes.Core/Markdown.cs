using System.Text;
using System.Text.RegularExpressions;

namespace MeetingNotes.Core;

/// Small Markdown reader for the notes and transcript: headings, bullets, task lists and inline bold, italic,
/// code and links (the same subset as the Mac app's MarkdownView). The window turns these into WPF text.
public static class Markdown
{
    public enum Kind { Blank, Heading1, Heading2, Heading3, Bullet, Paragraph }

    public sealed record Block(Kind Kind, string Text, string? Bullet, int Indent);

    public sealed record Span(string Text, bool Bold = false, bool Italic = false, bool Code = false, string? Link = null);

    public sealed record Match(int Line, int Index);

    public static string[] Lines(string text) => text.Replace("\r\n", "\n").Split('\n');

    public static Block Parse(string raw)
    {
        var line = raw.Trim();
        var indent = raw.TakeWhile(c => c == ' ').Count() / 2;
        if (line.Length == 0) return new Block(Kind.Blank, "", null, 0);
        if (line.StartsWith("### ")) return new Block(Kind.Heading3, line[4..], null, 0);
        if (line.StartsWith("## ")) return new Block(Kind.Heading2, line[3..], null, 0);
        if (line.StartsWith("# ")) return new Block(Kind.Heading1, line[2..], null, 0);
        if (line.StartsWith("- ") || line.StartsWith("* "))
        {
            var item = line[2..];
            if (item.StartsWith("[ ] ")) return new Block(Kind.Bullet, item[4..], "☐", indent);
            if (item.StartsWith("[x] ", StringComparison.OrdinalIgnoreCase)) return new Block(Kind.Bullet, item[4..], "☑", indent);
            return new Block(Kind.Bullet, item, "•", indent);
        }
        var numbered = Regex.Match(line, @"^(\d+[.)]) (.*)$");
        if (numbered.Success) return new Block(Kind.Bullet, numbered.Groups[2].Value, numbered.Groups[1].Value, indent);
        return new Block(Kind.Paragraph, line, null, indent);
    }

    static readonly Regex InlinePattern = new(
        @"(?<code>`[^`]+`)|(?<bold>\*\*(?=\S)(?:[^*]|\*(?!\*))+?\*\*|__(?=\S).+?__)|(?<link>\[[^\]]+\]\([^)\s]+\))|(?<italic>(?<![\w*])\*(?=\S)[^*]+?\*(?!\*)|(?<![\w_])_(?=\S)[^_]+?_(?!\w))",
        RegexOptions.Compiled);

    public static List<Span> Inline(string s)
    {
        var spans = new List<Span>();
        var at = 0;
        foreach (System.Text.RegularExpressions.Match m in InlinePattern.Matches(s))
        {
            if (m.Index > at) spans.Add(new Span(s[at..m.Index]));
            var v = m.Value;
            if (m.Groups["code"].Success) spans.Add(new Span(v[1..^1], Code: true));
            else if (m.Groups["bold"].Success)
            {
                foreach (var inner in Inline(v[2..^2])) spans.Add(inner with { Bold = true });
            }
            else if (m.Groups["link"].Success)
            {
                var close = v.IndexOf("](", StringComparison.Ordinal);
                spans.Add(new Span(v[1..close], Link: v[(close + 2)..^1]));
            }
            else spans.Add(new Span(v[1..^1], Italic: true));
            at = m.Index + m.Length;
        }
        if (at < s.Length) spans.Add(new Span(s[at..]));
        return spans;
    }

    /// The text a line shows, without Markdown markers.
    public static string Plain(string raw)
    {
        var b = Parse(raw);
        var sb = new StringBuilder();
        foreach (var span in Inline(b.Text)) sb.Append(span.Text);
        return sb.ToString();
    }

    /// All matches of the query in the shown text (Markdown markers like ** don't count).
    public static List<Match> Matches(string query, string text)
    {
        var result = new List<Match>();
        if (query.Length == 0) return result;
        var lines = Lines(text);
        for (var n = 0; n < lines.Length; n++)
        {
            if (lines[n].Trim().Length == 0) continue;
            var count = TextSearch.Ranges(query, Plain(lines[n])).Count;
            for (var i = 0; i < count; i++) result.Add(new Match(n, i));
        }
        return result;
    }
}
