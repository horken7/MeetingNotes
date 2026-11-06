package com.horken7.meetingnotes.core

import java.text.Normalizer
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** "m:ss", or "h:mm:ss" from an hour, like the Mac app. */
fun formatDuration(seconds: Double): String {
    val t = maxOf(0, seconds.toLong())
    return if (t >= 3600) String.format(Locale.ROOT, "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    else String.format(Locale.ROOT, "%d:%02d", t / 60, t % 60)
}

/** A piece of transcribed speech, [start] in seconds from the beginning of the meeting. */
data class Segment(val start: Double, val text: String)

object Transcript {
    /** Whisper's non-speech output: "[Music]", "(laughs)", "*cough*", or only punctuation and symbols. */
    fun isNoise(text: String): Boolean {
        val t = text.trim()
        if (t.isEmpty()) return true
        if ((t.startsWith("[") && t.endsWith("]")) || (t.startsWith("(") && t.endsWith(")")) ||
            (t.startsWith("*") && t.endsWith("*"))) return true
        return t.all { !it.isLetterOrDigit() }
    }

    /** Drops noise and the same text repeated back to back (a common whisper loop on silence). */
    fun clean(segments: List<Segment>): List<Segment> {
        val out = ArrayList<Segment>()
        for (s in segments.sortedBy { it.start }) {
            val text = s.text.trim()
            if (isNoise(text)) continue
            if (out.isNotEmpty() && out.last().text.equals(text, ignoreCase = true)) continue
            out.add(Segment(s.start, text))
        }
        return out
    }

    /** The body: one `[m:ss] text` line per segment, a blank line between them. */
    fun body(segments: List<Segment>): String =
        segments.joinToString("\n\n") { "[${formatDuration(it.start)}] ${it.text}" }

    /** The whole `transcript.md`. */
    fun file(title: String, segments: List<Segment>): String = "# $title: transcript\n\n${body(segments)}\n"

    /** The transcript without its `# Title` heading, for the notes model and the Transcript tab. */
    fun stripHeading(markdown: String): String {
        val lines = markdown.lines()
        return if (lines.firstOrNull()?.startsWith("# ") == true) lines.drop(1).joinToString("\n").trim() else markdown.trim()
    }

    private val timestamp = Regex("""^\[(\d+(?::\d{2}){1,2})]""")

    /** The last `[m:ss]` timestamp in a transcript, e.g. "42:10". */
    fun lastTimestamp(text: String): String? =
        text.lines().asReversed().firstNotNullOfOrNull { timestamp.find(it.trim())?.groupValues?.get(1) }

    fun firstTimestamp(text: String): String? =
        text.lines().firstNotNullOfOrNull { timestamp.find(it.trim())?.groupValues?.get(1) }
}

object Folders {
    private val stamp = DateTimeFormatter.ofPattern("yyyy-MM-dd HHmm", Locale.ROOT)

    /** The Mac's folder name: "2026-11-06 0930 Weekly sync", without characters that are unsafe in file names. */
    fun name(title: String, date: LocalDateTime): String {
        var safe = title.filterNot { it in "/:\\?%*|\"<>" }.trim()
        if (safe.isEmpty()) safe = "Meeting"
        return "${stamp.format(date)} $safe"
    }

    /** [base], or "[base] 2", "[base] 3"… when a folder with that name exists. */
    fun unique(base: String, exists: (String) -> Boolean): String {
        if (!exists(base)) return base
        var n = 2
        while (exists("$base $n")) n++
        return "$base $n"
    }
}

object TextSearch {
    private fun fold(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT)

    /** True when every word of the query appears in the text, ignoring case and accents, in any order. */
    fun matches(query: String, text: String): Boolean {
        val words = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return true
        val folded = fold(text)
        return words.all { folded.contains(fold(it)) }
    }
}
