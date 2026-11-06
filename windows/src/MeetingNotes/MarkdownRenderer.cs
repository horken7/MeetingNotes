using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using MeetingNotes.Core;

namespace MeetingNotes;

/// Builds a FlowDocument from the notes or transcript (headings, bullets, bold, italic, code, links), with
/// find-in-note highlights: every match yellow, the current one orange.
static class MarkdownRenderer
{
    static readonly Brush HighlightBrush = new SolidColorBrush(Color.FromArgb(115, 255, 220, 0));
    static readonly Brush CurrentBrush = new SolidColorBrush(Color.FromRgb(255, 160, 40));

    /// `currentRun` is the run holding the current match, for scrolling it into view.
    public static FlowDocument Build(string text, string highlight, Markdown.Match? current, out TextElement? currentRun)
    {
        currentRun = null;
        var doc = new FlowDocument
        {
            PagePadding = new Thickness(20),
            FontFamily = new FontFamily("Segoe UI"),
            FontSize = 14,
            LineHeight = 21,
        };
        var lines = Markdown.Lines(text);
        for (var n = 0; n < lines.Length; n++)
        {
            var block = Markdown.Parse(lines[n]);
            if (block.Kind == Markdown.Kind.Blank) continue;
            var p = new Paragraph { Margin = new Thickness(block.Indent * 18, 0, 0, 6) };
            switch (block.Kind)
            {
                case Markdown.Kind.Heading1:
                    p.FontSize = 22; p.FontWeight = FontWeights.Bold; p.Margin = new Thickness(0, 12, 0, 6);
                    break;
                case Markdown.Kind.Heading2:
                    p.FontSize = 18; p.FontWeight = FontWeights.SemiBold; p.Margin = new Thickness(0, 14, 0, 6);
                    break;
                case Markdown.Kind.Heading3:
                    p.FontSize = 15; p.FontWeight = FontWeights.SemiBold; p.Margin = new Thickness(0, 8, 0, 4);
                    break;
                case Markdown.Kind.Bullet:
                    p.Margin = new Thickness(block.Indent * 18 + 18, 0, 0, 4);
                    p.TextIndent = -16;
                    p.Inlines.Add(new Run(block.Bullet + "  ") { Foreground = Brushes.Gray });
                    break;
            }
            var spans = Markdown.Inline(block.Text);
            var plain = string.Concat(spans.Select(s => s.Text));
            var ranges = highlight.Length > 0 ? TextSearch.Ranges(highlight, plain) : new();
            var offset = 0;
            foreach (var span in spans)
            {
                foreach (var (piece, rangeIndex) in Split(span.Text, offset, ranges))
                {
                    var run = new Run(piece);
                    if (span.Bold) run.FontWeight = FontWeights.Bold;
                    if (span.Italic) run.FontStyle = FontStyles.Italic;
                    if (span.Code) { run.FontFamily = new FontFamily("Consolas"); run.Background = new SolidColorBrush(Color.FromRgb(240, 240, 240)); }
                    if (rangeIndex is { } ri)
                    {
                        var isCurrent = current != null && current.Line == n && current.Index == ri;
                        run.Background = isCurrent ? CurrentBrush : HighlightBrush;
                        if (isCurrent && currentRun == null) currentRun = run;
                    }
                    if (span.Link is { } link && Uri.TryCreate(link, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https")
                    {
                        var h = new Hyperlink(run) { NavigateUri = uri };
                        h.RequestNavigate += (_, e) => Shell.Open(e.Uri.AbsoluteUri);
                        p.Inlines.Add(h);
                    }
                    else p.Inlines.Add(run);
                }
                offset += span.Text.Length;
            }
            doc.Blocks.Add(p);
        }
        return doc;
    }

    /// Cuts a span's text at the highlight ranges; each piece carries the index of the match it belongs to.
    static IEnumerable<(string Text, int? Range)> Split(string text, int offset, List<(int Start, int Length)> ranges)
    {
        var at = 0;
        while (at < text.Length)
        {
            var abs = offset + at;
            var inside = ranges.FindIndex(r => abs >= r.Start && abs < r.Start + r.Length);
            if (inside >= 0)
            {
                var end = Math.Min(text.Length, ranges[inside].Start + ranges[inside].Length - offset);
                yield return (text[at..end], inside);
                at = end;
            }
            else
            {
                var next = ranges.Where(r => r.Start > abs).Select(r => r.Start - offset).DefaultIfEmpty(text.Length).Min();
                var end = Math.Min(text.Length, next);
                yield return (text[at..end], null);
                at = end;
            }
        }
    }
}
