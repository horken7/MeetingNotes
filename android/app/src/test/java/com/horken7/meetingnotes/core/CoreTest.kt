package com.horken7.meetingnotes.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant
import java.time.LocalDateTime

class TranscriptTest {
    @Test fun formatsDurationsLikeTheMac() {
        assertEquals("0:00", formatDuration(-3.0))
        assertEquals("0:07", formatDuration(7.9))
        assertEquals("12:05", formatDuration(725.0))
        assertEquals("1:00:00", formatDuration(3600.0))
        assertEquals("2:03:04", formatDuration(7384.0))
    }

    @Test fun writesTimestampedLines() {
        val segments = listOf(Segment(65.2, "Hej allihop."), Segment(3.0, "Välkomna."))
        val file = Transcript.file("Planering", Transcript.clean(segments))
        assertEquals("# Planering: transcript\n\n[0:03] Välkomna.\n\n[1:05] Hej allihop.\n", file)
    }

    @Test fun dropsNoiseAndRepeats() {
        val segments = listOf(Segment(0.0, " [Musik] "), Segment(1.0, "(skratt)"), Segment(2.0, "..."),
            Segment(3.0, "Okej."), Segment(4.0, "okej."), Segment(5.0, "Nästa punkt."), Segment(6.0, "*hosta*"))
        assertEquals(listOf("Okej.", "Nästa punkt."), Transcript.clean(segments).map { it.text })
        assertTrue(Transcript.isNoise("♪ ♪"))
        assertFalse(Transcript.isNoise("Ja"))
    }

    @Test fun stripsHeadingAndFindsTimestamps() {
        val md = "# Möte: transcript\n\n[0:03] A\n\n[12:40] B\n\n[1:02:03] C\n"
        val body = Transcript.stripHeading(md)
        assertEquals("[0:03] A\n\n[12:40] B\n\n[1:02:03] C", body)
        assertEquals("0:03", Transcript.firstTimestamp(body))
        assertEquals("1:02:03", Transcript.lastTimestamp(body))
        assertNull(Transcript.lastTimestamp("no stamps"))
    }

    @Test fun folderNamesMatchTheMac() {
        val date = LocalDateTime.of(2026, 11, 6, 9, 5)
        assertEquals("2026-11-06 0905 Weekly sync", Folders.name("Weekly sync", date))
        assertEquals("2026-11-06 0905 ab", Folders.name(" a/b: ", date))
        assertEquals("2026-11-06 0905 Meeting", Folders.name("???", date))
        val taken = setOf("x", "x 2")
        assertEquals("x 3", Folders.unique("x") { it in taken })
        assertEquals("y", Folders.unique("y") { it in taken })
    }

    @Test fun searchIgnoresCaseAccentsAndOrder() {
        val text = "Budget för Q3 och Malmö-kontoret"
        assertTrue(TextSearch.matches("malmo budget", text))
        assertTrue(TextSearch.matches("  ", text))
        assertFalse(TextSearch.matches("budget göteborg", text))
    }
}

class MetaTest {
    @Test fun roundTripsWithMacKeys() {
        val meta = Meta(title = "Styrelsemöte", created = Meta.timestamp(Instant.parse("2026-11-06T09:30:12.345Z")),
            status = Meta.DONE, lang = "sv", duration = 1830.5)
        val json = meta.encode()
        assertTrue(json.contains("\"created\": \"2026-11-06T09:30:12Z\""))
        assertFalse("nulls are left out", json.contains("null"))
        // Sorted keys, like the Mac's JSONEncoder with .sortedKeys.
        val keys = Regex("\"(\\w+)\":").findAll(json).map { it.groupValues[1] }.toList()
        assertEquals(keys.sorted(), keys)
        assertEquals(meta, Meta.parse(json))
        assertEquals(Instant.parse("2026-11-06T09:30:12Z"), meta.createdInstant)
    }

    @Test fun readsMacFiles() {
        val mac = """
            {
              "app" : "Google Meet",
              "created" : "2026-10-01T08:00:00Z",
              "duration" : 600,
              "offsets" : { "me" : 0, "others" : 0.25 },
              "status" : "done",
              "title" : "Weekly sync",
              "futureKey" : true
            }
        """.trimIndent()
        val meta = Meta.parse(mac)!!
        assertEquals("Weekly sync", meta.title)
        assertEquals(0.25, meta.offsets!!["others"]!!, 0.0)
        assertEquals(600.0, meta.duration!!, 0.0)
        assertFalse(meta.isBusy)
        assertNull(Meta.parse("not json"))
    }
}

class PromptsTest {
    @Test fun defaultInstructionsMatchTheMac() {
        assertTrue(Prompts.defaultInstructions.startsWith("Write the notes in the main language spoken in the meeting"))
        assertTrue(Prompts.defaultInstructions.endsWith("Never use en dashes or em dashes."))
        assertEquals(Prompts.defaultInstructions, Prompts.instructions("  "))
        assertEquals("Bullets only.", Prompts.instructions(" Bullets only. "))
    }

    @Test fun namesTheLanguageAndHasNoSpeakerLabels() {
        val p = Prompts.notesSystem("Sprintplanering", null, "sv")
        assertTrue(p.contains("Meeting title: Sprintplanering"))
        assertTrue(p.contains("write the notes in Swedish, headings included"))
        assertTrue(p.contains("no speaker names"))
        assertFalse(p.contains("Others"))
        val custom = Prompts.notesSystem("X", "Short bullets.", "da")
        assertTrue(custom.contains("Short bullets."))
        assertTrue(custom.contains("The meeting was in Danish."))
        assertFalse(custom.contains("write the notes in Danish"))
        assertFalse(Prompts.notesSystem("X", null, "auto").contains("The meeting was in"))
    }

    @Test fun remindsOfTheLanguageAfterTheTranscript() {
        val r = Prompts.languageReminder(null, "sv")
        assertEquals("\n\nWrite the notes in Swedish, headings included.", r)
        assertTrue(Prompts.notesUser("[0:01] hej", r).endsWith("</transcript>$r"))
        assertEquals("", Prompts.languageReminder("Custom.", "sv"))
        assertEquals("", Prompts.languageReminder(null, null))
    }

    @Test fun languageNames() {
        assertEquals("Swedish", Prompts.languageName("sv"))
        assertEquals("Danish", Prompts.languageName("da"))
        assertEquals("English", Prompts.languageName("en"))
        assertNull(Prompts.languageName("auto"))
        assertNull(Prompts.languageName(null))
    }

    @Test fun wrapsTranscriptAsData() {
        val u = Prompts.partUser("[0:01] hi", "0:01", "9:59")
        assertTrue(u.contains("(from 0:01 to 9:59)"))
        assertTrue(u.contains("<transcript>\n[0:01] hi\n</transcript>"))
        val c = Prompts.combineUser(listOf(" a ", "b"))
        assertTrue(c.contains("<part number=\"1\">\na\n</part>\n\n<part number=\"2\">\nb\n</part>"))
    }
}

class ChunkerTest {
    private val words = { s: String -> s.split(Regex("\\s+")).count { it.isNotEmpty() } }

    @Test fun keepsLinesTogetherAndRespectsTheBudget() {
        val lines = (1..10).map { "[0:${"%02d".format(it)}] one two three four" }   // 5 words each
        val parts = Chunker.split(lines.joinToString("\n\n"), maxTokens = 12, count = words)
        assertEquals(5, parts.size)
        assertTrue(parts.all { words(it) <= 12 })
        assertEquals(lines, parts.flatMap { it.split("\n\n") })
    }

    @Test fun splitsAnOverlongLineAtSentences() {
        val line = "A b c. D e f. G h i. J k l."
        val parts = Chunker.split(line, maxTokens = 6, count = words)
        assertEquals(listOf("A b c. D e f.", "G h i. J k l."), parts)
    }

    @Test fun hardSplitsWhenThereAreNoSentences() {
        val line = (1..20).joinToString(" ") { "w$it" }
        val parts = Chunker.split(line, maxTokens = 7, count = words)
        assertTrue(parts.all { words(it) <= 7 })
        assertEquals(line.split(" "), parts.flatMap { it.split(" ") })
    }

    @Test fun estimatesLikeTheMac() {
        assertEquals(1, Chunker.estimateTokens(""))
        assertEquals(41, Chunker.estimateTokens("x".repeat(100)))
    }
}

class SummarizerTest {
    private val words = { s: String -> s.split(Regex("\\s+")).count { it.isNotEmpty() } }

    @Test fun shortTranscriptInOneCall() {
        val calls = ArrayList<String>()
        val s = Summarizer(contextTokens = 2000, generate = { sys, user, _ -> calls.add(sys); "```markdown\n## Summary\nOk\n```" }, count = words)
        assertEquals("## Summary\nOk", s.summarize("T", "[0:01] short", null, "en"))
        assertEquals(1, calls.size)
        assertFalse(calls[0].contains("part"))
    }

    @Test fun cutsWhereSmallModelsStartOver() {
        val answer = "## Sammanfattning\nMötet handlade om X.\n\n## Beslut\n* Y\n\n---\n\n**Translation of the transcript:**\n\n## Sammanfattning\nThe meeting was about X."
        assertEquals("## Sammanfattning\nMötet handlade om X.\n\n## Beslut\n* Y", Summarizer.clean(answer))
        assertEquals("## A\n- a\n## B\n- b", Summarizer.clean("```markdown\n## A\n- a\n## B\n- b\n```"))
        assertEquals("No headings: here.", Summarizer.clean("No headings: here."))
    }

    @Test fun longTranscriptInPartsThenCombined() {
        val transcript = (1..60).joinToString("\n\n") { "[$it:00] " + "ord ".repeat(20).trim() }
        val systems = ArrayList<String>()
        val users = ArrayList<String>()
        val steps = ArrayList<Pair<Int, Int>>()
        val s = Summarizer(contextTokens = 1000, notesTokens = 200, partTokens = 100, count = words,
            generate = { sys, user, max ->
                systems.add(sys); users.add(user)
                assertTrue("prompt fits", words(sys) + words(user) + max <= 1000)
                "- note ${systems.size}"
            },
            onStep = { d, t -> steps.add(d to t) })
        val notes = s.summarize("Lång", transcript, null, "sv")
        val partCalls = systems.count { it.startsWith("You are taking notes on part") }
        assertTrue(partCalls >= 2)
        assertTrue(systems.last().contains("Merge them into one set of notes"))
        assertTrue(users.last().contains("<part number=\"$partCalls\">"))
        assertTrue(users.first().endsWith("Write in Swedish."))
        assertTrue(users.last().endsWith("Write the notes in Swedish, headings included."))
        assertEquals("- note ${systems.size}", notes)
        assertEquals(partCalls + 1, steps.last().second)
        assertEquals(steps.last().first, steps.last().second)
    }

    @Test fun combinesInRoundsWhenPartNotesAreLong() {
        val transcript = (1..80).joinToString("\n\n") { "[$it:00] " + "ord ".repeat(20).trim() }
        var calls = 0
        val s = Summarizer(contextTokens = 700, notesTokens = 150, partTokens = 100, count = words,
            generate = { sys, user, max ->
                calls++
                assertTrue("prompt fits", words(sys) + words(user) + max <= 700)
                "lang ".repeat(90).trim()   // long part notes force several combining rounds
            })
        val notes = s.summarize("X", transcript, "Custom.", null)
        assertTrue(notes.isNotEmpty())
        assertTrue(calls > 5)
    }
}

class MarkdownTest {
    @Test fun parsesBlocks() {
        val md = "# Möte\n\n## Beslut\n- **Budget** godkänd\n  - detalj\n1. Första\n\nEn *viktig* rad\nfortsätter `kod`\n\n---"
        val b = Markdown.parse(md)
        assertEquals(Markdown.Heading(1, listOf(Markdown.Span("Möte"))), b[0])
        assertEquals(2, (b[1] as Markdown.Heading).level)
        val item = b[2] as Markdown.Item
        assertEquals("•", item.marker)
        assertEquals(Markdown.Span("Budget", bold = true), item.text[0])
        assertEquals(Markdown.Span(" godkänd"), item.text[1])
        assertEquals(1, (b[3] as Markdown.Item).depth)
        assertEquals("1.", (b[4] as Markdown.Item).marker)
        val p = b[5] as Markdown.Paragraph
        assertEquals(listOf(Markdown.Span("En "), Markdown.Span("viktig", italic = true), Markdown.Span(" rad fortsätter "),
            Markdown.Span("kod", code = true)), p.text)
        assertEquals(Markdown.Rule, b[6])
    }

    @Test fun leavesUnclosedMarkersAndSnakeCase() {
        assertEquals(listOf(Markdown.Span("2 * 3 = 6 and **open")), Markdown.inline("2 * 3 = 6 and **open"))
        assertEquals(listOf(Markdown.Span("file_name_here")), Markdown.inline("file_name_here"))
    }
}

class WavTest {
    @Test fun headerAndRepair() {
        val f = File.createTempFile("test", ".wav")
        try {
            val samples = ShortArray(16000) { (it % 100 * 100).toShort() }
            f.writeBytes(Wav.header(0) + Wav.toBytes(samples) + byteArrayOf(1))   // stale header, odd length
            Wav.repair(f)
            val bytes = f.readBytes()
            assertEquals(44 + 32000, bytes.size)
            assertEquals("RIFF", String(bytes, 0, 4))
            assertEquals(32000 + 36, le32(bytes, 4))
            assertEquals(16000, le32(bytes, 24))
            assertEquals(32000, le32(bytes, 40))
            assertEquals(1.0, Wav.durationSeconds(f), 1e-9)
            val read = Wav.read(f, 100, 10)
            assertEquals(samples[100] / 32768f, read[0], 1e-6f)
            assertEquals(10, read.size)
            assertEquals(0, Wav.read(f, 16000, 10).size)
        } finally { f.delete() }
    }

    @Test fun levelsAndDownsampling() {
        assertEquals(0f, Wav.meterLevel(0.0))
        assertEquals(1f, Wav.meterLevel(1.0))
        assertEquals(0f, Wav.meterLevel(0.001), 1e-3f)
        assertEquals(0.5f, Wav.meterLevel(0.0316), 1e-3f)
        assertEquals(listOf<Short>(2, 5), Wav.downsample3(shortArrayOf(1, 2, 3, 4, 5, 6, 7), 7).toList())
    }

    private fun le32(b: ByteArray, at: Int) =
        (b[at].toInt() and 0xFF) or ((b[at + 1].toInt() and 0xFF) shl 8) or ((b[at + 2].toInt() and 0xFF) shl 16) or ((b[at + 3].toInt() and 0xFF) shl 24)
}

class AudioBlocksTest {
    @Test fun cutsAtTheQuietestPointBeforeTheTarget() {
        // Loud everywhere except a quiet spot at sample 950..959.
        val energy = { start: Long, _: Long -> if (start == 950L) 0.0 else 1.0 }
        val blocks = AudioBlocks.plan(total = 2500, target = 1000, window = 100, step = 10, energy = energy)
        assertEquals(955L, blocks[0].last + 1)
        assertEquals(blocks[0].last + 1, blocks[1].first)
        assertEquals(2499L, blocks.last().last)
        // Contiguous and complete.
        assertEquals(2500L, blocks.sumOf { it.last - it.first + 1 })
    }

    @Test fun shortAudioIsOneBlock() {
        assertEquals(listOf(0L until 1040L), AudioBlocks.plan(1040, 1000, 100, 10) { _, _ -> 0.0 })
    }
}

class CatalogTest {
    private val gb = 1_000_000_000L

    @Test fun builtInModelsByDefault() {
        assertEquals(Catalog.gemma1b, Catalog.notesModel("auto", 12 * gb))
        assertEquals(Catalog.gemma1b, Catalog.notesModel("auto", 4 * gb))
        assertEquals(Catalog.gemma4b, Catalog.notesModel("gemma3-4b", 8 * gb))
        assertNull(Catalog.notesModel("auto", 2 * gb))
        assertTrue(Catalog.gemma1b.bundled && !Catalog.gemma4b.bundled)
        assertEquals(Catalog.whisperMultilingual, Catalog.speechModel("sv"))
        assertEquals(Catalog.whisperSwedish, Catalog.speechModel("sv", swedish = true))
        assertEquals(Catalog.whisperSwedish, Catalog.betterSpeechModel("sv"))
        assertNull(Catalog.betterSpeechModel("da"))
        assertEquals(Catalog.whisperMultilingual, Catalog.speechModel("da"))
        assertEquals(Catalog.whisperMultilingual, Catalog.speechModel("auto"))
        assertEquals(Catalog.whisperFast, Catalog.speechModel("en", fast = true))
        assertEquals(Catalog.whisperSwedish, Catalog.speechModel("sv", swedish = true, fast = true))
        assertEquals(Catalog.whisperFast, Catalog.speechModel("sv", fast = true))
        assertFalse(Catalog.whisperSwedish.bundled)
        assertFalse(Catalog.whisperFast.bundled)
        assertEquals("175 MB", Catalog.size(Catalog.whisperSwedish.bytes))
        assertEquals("2.5 GB", Catalog.size(Catalog.gemma4b.bytes))
    }

    @Test fun bundledModelsMatchTheBuildList() {
        // ../bundled-models.txt is what the build puts in the APK; the app must expect the same files and sizes.
        val listed = java.io.File("../bundled-models.txt").readLines().map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .map { it.split(Regex("\\s+")).let { p -> p[0] to p[1].toLong() } }.toSet()
        val expected = Catalog.all.filter { it.bundled }.map { it.fileName to it.bytes }.toSet()
        assertEquals(expected, listed)
        // Play allows 1.5 GB per asset pack (and GitHub 2 GiB per release file, with room for the app itself).
        assertTrue(listed.sumOf { it.second } < 1_500_000_000L)
        // Every language works out of the box: a multilingual speech model, voice detection and a notes model.
        assertTrue(Catalog.speechModels.all { it.bundled } && Catalog.gemma1b.bundled)
    }

    @Test fun votesForTheLanguage() {
        assertEquals("sv", LanguageVote.pick(listOf("no" to 0.5f, "sv" to 0.4f, "sv" to 0.6f)))
        assertEquals("da", LanguageVote.pick(listOf("da" to 0.9f)))
        assertNull(LanguageVote.pick(emptyList()))
    }
}

class ShareTest {
    @Test fun startsWithThePromptThenTheTranscript() {
        val text = Share.transcriptForNotes("Planering", "# Planering: transcript\n\n[0:03] Välkomna.\n\n[1:05] Hej allihop.\n")
        assertEquals("Write meeting notes for this transcript: summary, decisions, action items with owners.\n\n" +
            "Meeting: Planering\n\n[0:03] Välkomna.\n\n[1:05] Hej allihop.\n", text)
    }

    @Test fun keepsATranscriptWithoutHeading() {
        assertTrue(Share.transcriptForNotes("X", "[0:00] Hi.").endsWith("Meeting: X\n\n[0:00] Hi.\n"))
    }

    @Test fun sharedTranscriptHasNoRequest() {
        val text = Share.transcript("Planering", "# Planering: transcript\n\n[0:03] Välkomna.\n")
        assertEquals("# Planering: transcript\n\n[0:03] Välkomna.\n", text)
        assertFalse(text.contains(Share.PROMPT))
    }
}
