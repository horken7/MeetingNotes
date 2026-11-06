package com.horken7.meetingnotes.core

/** The small part of Markdown the notes use: headings, bullet and numbered lists, paragraphs, bold, italics, code. */
object Markdown {
    sealed interface Block
    data class Heading(val level: Int, val text: List<Span>) : Block
    /** [marker] is "•" for bullets or "1." for numbered items; [depth] 0 for top level. */
    data class Item(val depth: Int, val marker: String, val text: List<Span>) : Block
    data class Paragraph(val text: List<Span>) : Block
    data object Rule : Block

    data class Span(val text: String, val bold: Boolean = false, val italic: Boolean = false, val code: Boolean = false)

    private val heading = Regex("""^(#{1,6})\s+(.*?)\s*#*\s*$""")
    private val bullet = Regex("""^(\s*)[-*+]\s+(.*)$""")
    private val numbered = Regex("""^(\s*)(\d+)[.)]\s+(.*)$""")
    private val rule = Regex("""^\s*([-*_])(\s*\1){2,}\s*$""")

    fun parse(markdown: String): List<Block> {
        val blocks = ArrayList<Block>()
        val paragraph = ArrayList<String>()
        fun flush() {
            if (paragraph.isNotEmpty()) blocks.add(Paragraph(inline(paragraph.joinToString(" "))))
            paragraph.clear()
        }
        for (raw in markdown.lines()) {
            val line = raw.trimEnd()
            if (line.isBlank()) { flush(); continue }
            if (rule.matches(line)) { flush(); blocks.add(Rule); continue }
            heading.find(line)?.let { m ->
                flush(); blocks.add(Heading(m.groupValues[1].length, inline(m.groupValues[2]))); return@let
            } ?: bullet.find(line)?.let { m ->
                flush(); blocks.add(Item(depth(m.groupValues[1]), "•", inline(m.groupValues[2])))
            } ?: numbered.find(line)?.let { m ->
                flush(); blocks.add(Item(depth(m.groupValues[1]), "${m.groupValues[2]}.", inline(m.groupValues[3])))
            } ?: paragraph.add(line.trim())
        }
        flush()
        return blocks
    }

    private fun depth(indent: String): Int = indent.replace("\t", "    ").length / 2

    /** Splits `**bold**`, `*italic*` / `_italic_` and `` `code` `` into spans. Unclosed markers stay as text. */
    fun inline(text: String): List<Span> {
        val spans = ArrayList<Span>()
        val plain = StringBuilder()
        var bold = false
        var italic = false
        var i = 0
        fun emit() {
            if (plain.isNotEmpty()) spans.add(Span(plain.toString(), bold, italic))
            plain.clear()
        }
        while (i < text.length) {
            val c = text[i]
            when {
                c == '`' && text.indexOf('`', i + 1) > i -> {
                    emit()
                    val end = text.indexOf('`', i + 1)
                    spans.add(Span(text.substring(i + 1, end), bold, italic, code = true))
                    i = end + 1
                }
                text.startsWith("**", i) && (bold || text.indexOf("**", i + 2) > i) -> {
                    emit(); bold = !bold; i += 2
                }
                (c == '*' || c == '_') && (italic || closes(text, i, c)) && !(c == '_' && wordInside(text, i)) -> {
                    emit(); italic = !italic; i += 1
                }
                else -> { plain.append(c); i++ }
            }
        }
        emit()
        return merge(spans)
    }

    private fun closes(text: String, i: Int, c: Char): Boolean {
        if (i + 1 >= text.length || text[i + 1].isWhitespace()) return false
        val end = text.indexOf(c, i + 1)
        return end > i + 1
    }

    // snake_case words keep their underscores.
    private fun wordInside(text: String, i: Int): Boolean =
        i > 0 && text[i - 1].isLetterOrDigit() && i + 1 < text.length && text[i + 1].isLetterOrDigit()

    private fun merge(spans: List<Span>): List<Span> {
        val out = ArrayList<Span>()
        for (s in spans) {
            val last = out.lastOrNull()
            if (last != null && last.bold == s.bold && last.italic == s.italic && last.code == s.code) {
                out[out.size - 1] = last.copy(text = last.text + s.text)
            } else out.add(s)
        }
        return out
    }
}
