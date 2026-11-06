import Foundation

/// The Markdown the notes use, as blocks to render: headings, bullets, numbered items, checkboxes and paragraphs.
/// Inline formatting (bold, italics, code, links) stays in `text` for `AttributedString(markdown:)`.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case numbered(indent: Int, number: String, text: String)
    case checkbox(indent: Int, checked: Bool, text: String)
    case paragraph(String)
    case rule

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let leading = raw.prefix { $0 == " " || $0 == "\t" }
            let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let rest = line.dropFirst(hashes)
                if hashes <= 6, rest.first == " " {
                    flush()
                    blocks.append(.heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
                flush()
                let item = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                let lower = item.lowercased()
                if lower.hasPrefix("[ ] ") || lower == "[ ]" {
                    blocks.append(.checkbox(indent: indent, checked: false, text: String(item.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                } else if lower.hasPrefix("[x] ") || lower == "[x]" {
                    blocks.append(.checkbox(indent: indent, checked: true, text: String(item.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                } else {
                    blocks.append(.bullet(indent: indent, text: item))
                }
                continue
            }
            let digits = line.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 3 {
                let rest = line.dropFirst(digits.count)
                if let dot = rest.first, dot == "." || dot == ")", rest.dropFirst().first == " " {
                    flush()
                    blocks.append(.numbered(indent: indent, number: String(digits), text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }
}
