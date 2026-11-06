package com.horken7.meetingnotes.core

/** Splits a transcript into parts that fit the notes model's context. */
object Chunker {
    /** The Mac app's estimate (2 tokens per 5 characters), on the safe side for Swedish and Danish. */
    fun estimateTokens(text: String): Int = text.length * 2 / 5 + 1

    /**
     * Groups the transcript's lines (blank-line separated) into parts of at most [maxTokens], never splitting a line
     * unless one line alone is too long; then it is split at sentence ends, or hard as a last resort.
     */
    fun split(text: String, maxTokens: Int, count: (String) -> Int = ::estimateTokens): List<String> {
        require(maxTokens > 0)
        val pieces = text.split(Regex("\n\\s*\n")).map { it.trim() }.filter { it.isNotEmpty() }
            .flatMap { splitLong(it, maxTokens, count) }
        val parts = ArrayList<String>()
        val current = StringBuilder()
        for (p in pieces) {
            val candidate = if (current.isEmpty()) p else "$current\n\n$p"
            if (current.isNotEmpty() && count(candidate) > maxTokens) {
                parts.add(current.toString())
                current.clear().append(p)
            } else {
                current.clear().append(candidate)
            }
        }
        if (current.isNotEmpty()) parts.add(current.toString())
        return parts
    }

    private fun splitLong(line: String, maxTokens: Int, count: (String) -> Int): List<String> {
        if (count(line) <= maxTokens) return listOf(line)
        val sentences = line.split(Regex("(?<=[.!?])\\s+"))
        val out = ArrayList<String>()
        val cur = StringBuilder()
        for (s in sentences) {
            val candidate = if (cur.isEmpty()) s else "$cur $s"
            if (count(candidate) <= maxTokens) { cur.clear().append(candidate); continue }
            if (cur.isNotEmpty()) out.add(cur.toString())
            cur.clear()
            if (count(s) <= maxTokens) cur.append(s) else out.addAll(hardSplit(s, maxTokens, count))
        }
        if (cur.isNotEmpty()) out.add(cur.toString())
        return out
    }

    private fun hardSplit(s: String, maxTokens: Int, count: (String) -> Int): List<String> {
        val out = ArrayList<String>()
        var rest = s
        while (rest.isNotEmpty()) {
            var n = rest.length
            while (n > 1 && count(rest.substring(0, n)) > maxTokens) n = n * 3 / 4
            // Cut between words when there's a space in the piece.
            if (n < rest.length) rest.lastIndexOf(' ', n).takeIf { it > 0 }?.let { n = it }
            out.add(rest.substring(0, n).trimEnd())
            rest = rest.substring(n).trimStart()
        }
        return out
    }
}

/**
 * Writes notes with a local model whose context is too small for long meetings: short transcripts in one go,
 * long ones as notes per part that are then combined (in rounds, if even the part notes don't fit together).
 */
class Summarizer(
    private val contextTokens: Int,
    private val generate: (system: String, user: String, maxTokens: Int) -> String,
    private val count: (String) -> Int = Chunker::estimateTokens,
    private val notesTokens: Int = 1200,
    private val partTokens: Int = 600,
    private val onStep: (done: Int, total: Int) -> Unit = { _, _ -> },
) {
    private var reminder = ""

    /** Room for the chat template's own tokens. */
    private val overhead = 64

    fun summarize(title: String, transcript: String, customInstructions: String?, language: String?): String {
        val system = Prompts.notesSystem(title, customInstructions, language)
        val budget = contextTokens - notesTokens - overhead
        reminder = Prompts.languageReminder(customInstructions, language)
        // Part notes are always in the meeting's language, whatever the instructions say.
        val partReminder = Prompts.languageName(language)?.let { "\n\nWrite in $it." } ?: ""
        val whole = Prompts.notesUser(transcript, reminder)
        if (count(system) + count(whole) <= budget) {
            onStep(0, 1)
            return clean(generate(system, whole, notesTokens)).also { onStep(1, 1) }
        }

        // Part notes, sized so each part plus its prompt and answer fits the context.
        val probe = Prompts.partSystem(title, 99, 99, language)
        val partBudget = contextTokens - partTokens - overhead - count(probe) - count(Prompts.partUser("", "0:00:00", "0:00:00", partReminder))
        require(partBudget > 200) { "The notes model's context is too small." }
        val parts = Chunker.split(transcript, partBudget, count)
        val total = parts.size + 1
        val notes = parts.mapIndexed { i, part ->
            onStep(i, total)
            clean(generate(
                Prompts.partSystem(title, i + 1, parts.size, language),
                Prompts.partUser(part, Transcript.firstTimestamp(part), Transcript.lastTimestamp(part), partReminder),
                partTokens,
            ))
        }.filter { it.isNotBlank() }
        onStep(parts.size, total)
        return clean(combine(system + Prompts.combineNote, notes, budget)).also { onStep(total, total) }
    }

    private fun combine(system: String, notes: List<String>, budget: Int): String {
        if (notes.size == 1) return generate(system, Prompts.combineUser(notes, reminder), notesTokens)
        val room = budget - count(system)
        if (count(Prompts.combineUser(notes, reminder)) <= room) return generate(system, Prompts.combineUser(notes, reminder), notesTokens)
        // Too many part notes for one prompt: merge neighbours in groups that fit, then merge those.
        val groups = ArrayList<MutableList<String>>()
        for (n in notes) {
            val last = groups.lastOrNull()
            if (last != null && count(Prompts.combineUser(last + n, reminder)) <= room) last.add(n) else groups.add(mutableListOf(n))
        }
        require(groups.size < notes.size) { "The notes for each part are too long to combine." }
        val merged = groups.map { if (it.size == 1) it[0] else clean(generate(system, Prompts.combineUser(it, reminder), partTokens * 2)) }
        return combine(system, merged, budget)
    }

    companion object {
        /**
         * Tidies a small model's answer: removes a code fence around it, and cuts it where the notes start over
         * (the first heading again), which small models do to add a translation or repeat themselves.
         */
        fun clean(text: String): String {
            var t = text.trim()
            if (t.startsWith("```")) {
                t = t.substringAfter('\n', "")
                if (t.trimEnd().endsWith("```")) t = t.trimEnd().removeSuffix("```")
            }
            val lines = t.trim().lines()
            val first = lines.indexOfFirst { it.trimStart().startsWith("#") }
            if (first >= 0) {
                val key = lines[first].trim().lowercase()
                val again = (first + 1 until lines.size).firstOrNull { lines[it].trim().lowercase() == key }
                if (again != null) {
                    var end = again
                    // Drop the rule and the "Translation:" line that usually introduce the repeat.
                    while (end > 0 && (lines[end - 1].isBlank() || lines[end - 1].trim().matches(Regex("""[-*_ ]{3,}""")) ||
                            (lines[end - 1].trim().endsWith(":") || lines[end - 1].trim().endsWith(":**")) && !lines[end - 1].trimStart().startsWith("#"))) end--
                    return lines.subList(0, end).joinToString("\n").trim()
                }
            }
            return t.trim()
        }
    }
}
