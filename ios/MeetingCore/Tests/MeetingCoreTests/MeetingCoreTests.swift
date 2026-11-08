import Foundation
import Testing
@testable import MeetingCore

@Suite struct TranscriptTests {
    @Test func formatsLikeTheMacApp() {
        let t = TranscriptFormatter.format([
            Segment(start: 0.4, end: 2, text: "Hej allihop."),
            Segment(start: 2.5, end: 4, text: "Ska vi börja?"),
            Segment(start: 9, end: 11, text: "Ja."),
            Segment(start: 3725, end: 3727, text: "Tack!"),
        ])
        #expect(t == """
        [0:00] **Speaker:** Hej allihop. Ska vi börja?

        [0:09] **Speaker:** Ja.

        [1:02:05] **Speaker:** Tack!
        """)
    }

    @Test func skipsNoiseAndSortsByTime() {
        let t = TranscriptFormatter.format([
            Segment(start: 5, end: 6, text: "second"),
            Segment(start: 1, end: 2, text: "[music]"),
            Segment(start: 0, end: 1, text: " first "),
            Segment(start: 2, end: 3, text: "..."),
        ], pause: 10)
        #expect(t == "[0:00] **Speaker:** first second")
    }

    @Test func splitsLongParagraphs() {
        let words = (0..<10).map { Segment(start: Double($0), end: Double($0) + 0.5, text: String(repeating: "a", count: 30)) }
        let lines = TranscriptFormatter.format(words, maxLength: 100).components(separatedBy: "\n\n")
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { $0.hasPrefix("[") })
    }

    @Test func plainText() {
        let t = "# Title: transcript\n\n[0:00] **Speaker:** Hello there.\n\n[1:05] **Speaker:** Bye."
        #expect(TranscriptFormatter.plainText(t) == "Hello there. Bye.")
    }

    @Test func durations() {
        #expect(formatDuration(0) == "0:00")
        #expect(formatDuration(65.9) == "1:05")
        #expect(formatDuration(3600) == "1:00:00")
        #expect(formatDuration(-3) == "0:00")
        #expect(formatLength(45) == "45 s")
        #expect(formatLength(1260) == "21 min")
        #expect(formatLength(3900) == "1 h 5 min")
        #expect(formatLength(7200) == "2 h")
    }

    @Test func languageGuess() {
        #expect(MeetingLanguage.guess(preferred: ["sv-SE", "en-US"]) == .swedish)
        #expect(MeetingLanguage.guess(preferred: ["de-DE", "da-DK"]) == .danish)
        #expect(MeetingLanguage.guess(preferred: ["fi-FI"]) == .english)
    }
}

@Suite struct StoreTests {
    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func metaRoundTrip() throws {
        let created = Date(timeIntervalSince1970: 1_780_000_000)
        let meta = Meta(title: "Planering", created: created, status: "done", lang: "sv", offsets: ["audio": 0, "audio-1": 61.5], duration: 120)
        let data = try MeetingStore.encode(meta)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"created\" : \"2026-05-28T"))   // ISO 8601, like the Mac app
        #expect(json.contains("\"title\" : \"Planering\""))

        let root = try tempRoot()
        MeetingStore.writeMeta(meta, to: root)
        #expect(MeetingStore.readMeta(root) == meta)
    }

    @Test func readsMacMeta() throws {
        let root = try tempRoot()
        let mac = #"{"app":"Zoom","created":"2026-03-01T09:30:00Z","lang":"en","offsets":{"me":0,"others":0.2},"status":"done","title":"Standup"}"#
        try mac.write(to: root.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        let m = try #require(MeetingStore.readMeta(root))
        #expect(m.title == "Standup")
        #expect(m.app == "Zoom")
        #expect(m.offsets?["others"] == 0.2)
    }

    @Test func foldersAndListing() throws {
        let store = MeetingStore(root: try tempRoot())
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let a = try store.newFolder(title: "Möte: budget/plan", date: date)
        let b = try store.newFolder(title: "Möte: budget/plan", date: date)
        #expect(a.lastPathComponent.hasSuffix(" Möte budgetplan"))
        #expect(b.lastPathComponent == a.lastPathComponent + " 2")

        MeetingStore.writeMeta(Meta(title: "Old", created: date), to: a)
        MeetingStore.writeMeta(Meta(title: "New", created: date.addingTimeInterval(60), status: "done"), to: b)
        try MeetingStore.writeNotes("## Summary\nOk", title: "Old", to: a)
        try Data().write(to: a.appendingPathComponent("audio-1.caf"))
        try Data().write(to: a.appendingPathComponent("audio.caf"))
        try Data().write(to: a.appendingPathComponent("audio-10.caf"))
        try Data().write(to: a.appendingPathComponent("audio-2.caf"))

        let all = store.loadAll()
        #expect(all.map(\.title) == ["New", "Old"])
        #expect(all[1].status == "done")   // no status, but has notes
        #expect(all[1].hasAudio)
        #expect(MeetingStore.audioFiles(a).map(\.lastPathComponent) == ["audio.caf", "audio-1.caf", "audio-2.caf", "audio-10.caf"])
    }

    /// The id the app opens after recording (the new folder's path) must be the id the list has for it.
    /// The temporary directory, like an iPhone's Documents folder, is under /var, a symlink to /private/var,
    /// and listing a directory can spell its children with the resolved path.
    @Test func newFolderIdMatchesListedId() throws {
        let store = MeetingStore(root: try tempRoot())
        let folder = try store.newFolder(title: "Meeting", date: Date())
        MeetingStore.writeMeta(Meta(title: "Meeting", created: Date(), status: "transcribing"), to: folder)
        let all = store.loadAll()
        #expect(all.map(\.id) == [folder.path])
        #expect(all.first?.status == "transcribing")
    }

    @Test func renameUpdatesHeadings() throws {
        let root = try tempRoot()
        MeetingStore.writeMeta(Meta(title: "Old"), to: root)
        try MeetingStore.writeNotes("## Summary\nText", title: "Old", to: root)
        try MeetingStore.writeTranscript("[0:00] **Speaker:** Hi", title: "Old", to: root)
        MeetingStore.rename(root, to: "New")
        #expect(MeetingStore.readMeta(root)?.title == "New")
        let notes = try String(contentsOf: root.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(notes.hasPrefix("# New\n\n## Summary"))
        #expect(MeetingStore.readBody(root, "transcript.md") == "[0:00] **Speaker:** Hi")
    }

    @Test func search() {
        #expect(matches("budget möte", in: ["Möte om budgeten"]))
        #expect(matches("mote", in: ["Möte"]))
        #expect(!matches("budget lunch", in: ["Möte om budgeten"]))
        #expect(matches("  ", in: []))
    }
}

@Suite struct NotesTests {
    @Test func defaultInstructionsFollowTheMacApp() {
        let i = NotesPrompt.defaultInstructions
        #expect(i.hasPrefix("Write the notes in the main language spoken in the meeting"))
        #expect(i.contains("Action items"))
        #expect(!i.contains("(3 to 5 sentences)"))   // small models copy hints in headings into the notes
        #expect(!i.contains("Others"))
        #expect(NotesPrompt.effectiveInstructions("  ") == i)
        #expect(NotesPrompt.effectiveInstructions("Just bullets") == "Just bullets")
    }

    @Test func prompts() {
        let sys = NotesPrompt.system(language: .danish)
        #expect(sys.contains("so write in Danish."))
        #expect(NotesPrompt.single(title: "T", instructions: "I", transcript: "X", language: .swedish)
            .hasSuffix("X\n\nWrite the notes in Swedish, headings included."))
        #expect(NotesPrompt.part(1, of: 2, language: .danish, transcript: "X").hasSuffix("Write the notes in Danish, headings included."))
        #expect(!NotesPrompt.single(title: "T", instructions: "I", transcript: "X").contains("headings included"))
        #expect(sys.contains("\"Speaker\""))
        #expect(!sys.contains("notes are for"))
        #expect(NotesPrompt.system(language: .english, name: "Anna").contains("The notes are for Anna, who recorded the meeting."))
        let p = NotesPrompt.single(title: "Q3", instructions: "INSTR", transcript: "TEXT")
        #expect(p.contains("Meeting title: Q3"))
        #expect(p.range(of: "INSTR")!.lowerBound < p.range(of: "TEXT")!.lowerBound)
        #expect(NotesPrompt.part(2, of: 5, language: .swedish, transcript: "x").contains("part 2 of 5"))
        let c = NotesPrompt.combine(title: "Q3", instructions: "INSTR", parts: ["a", "b"])
        #expect(c.contains("Notes for part 1:\na\n\nNotes for part 2:\nb"))
    }

    @Test func chunkingKeepsParagraphsAndLimit() {
        let paragraphs = (0..<20).map { "[0:\(String(format: "%02d", $0))] **Speaker:** " + String(repeating: "ord ", count: 20) }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = Chunker.chunks(text, maxChars: 500)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 500 })
        #expect(chunks.joined(separator: "\n\n") == paragraphs.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n\n"))
        #expect(chunks.allSatisfy { $0.hasPrefix("[") })   // never cut inside a paragraph here
    }

    @Test func chunkingSplitsHugeParagraphs() {
        let sentence = "Det här är en mening. "
        let text = String(repeating: sentence, count: 100) + String(repeating: "x", count: 300)
        let chunks = Chunker.chunks(text, maxChars: 120)
        #expect(chunks.allSatisfy { $0.count <= 120 })
        #expect(chunks.joined().filter { $0 == "x" }.count == 300)
        #expect(chunks.joined().components(separatedBy: "mening").count - 1 == 100)
    }

    @Test func budget() {
        #expect(NotesGenerator.maxChars(contextTokens: 4096) == 6240)
        #expect(NotesGenerator.maxChars(contextTokens: 100) == 1500)
    }

    actor Calls {
        var prompts: [String] = []
        func add(_ p: String) -> Int { prompts.append(p); return prompts.count }
    }

    @Test func theTranscriptReachesThePrompt() async throws {
        let calls = Calls()
        let gen = NotesGenerator(maxChars: 6000) { system, prompt in
            _ = await calls.add(system + "\n---\n" + prompt)
            return "## Sammanfattning\nOk"
        }
        let sentence = "Hej, jag heter Johan. Jag är 33 år och bor i Århus. Var bor du?"
        let transcript = (0..<4).map { "[0:\(String(format: "%02d", $0 * 10))] **Speaker:** \(sentence)" }.joined(separator: "\n\n")
        _ = try await gen.notes(transcript: transcript, title: "Möte", language: .swedish, instructions: NotesPrompt.defaultInstructions)
        let sent = await calls.prompts
        #expect(sent.count == 1)
        #expect(sent[0].contains(sentence))
        #expect(sent[0].contains("Swedish"))
        // No example meeting the model could copy.
        for word in ["marketing", "influencer", "Maria", "campaign"] { #expect(!sent[0].localizedCaseInsensitiveContains(word)) }
    }

    @Test func swedishNotesStartInSwedish() async throws {
        let calls = Calls()
        var gen = NotesGenerator(maxChars: 6000) { _, _ in "unused" }
        gen.generatePrefixed = { _, prompt, prefix in
            _ = await calls.add(prompt + "|PREFIX|" + prefix)
            return "Johan berättade om sig själv."
        }
        let line = "[0:00] **Speaker:** " + String(repeating: "Hej jag heter Johan och bor i Århus. ", count: 5)
        let notes = try await gen.notes(transcript: line, title: "Möte", language: .swedish, instructions: NotesPrompt.defaultInstructions)
        #expect(notes == "## Sammanfattning\nJohan berättade om sig själv.")
        let sent = await calls.prompts
        #expect(sent[0].hasSuffix("|PREFIX|## Sammanfattning\n"))
        #expect(sent[0].contains("Sammanfattning, Beslut, Att göra, Öppna frågor, Viktiga punkter"))
        #expect(!sent[0].contains("Summary, Decisions"))
        // Custom instructions: no prefix, nothing replaced.
        #expect(NotesPrompt.answerPrefix(.swedish, instructions: "Bara punkter") == nil)
        #expect(NotesPrompt.localized("Bara punkter", .swedish) == "Bara punkter")
        #expect(NotesPrompt.answerPrefix(.automatic, instructions: NotesPrompt.defaultInstructions) == nil)
    }

    @Test func tidyNotes() {
        let raw = """
        ## Beslut
        - [ ]  Identifiera Paleolitikum
        - [ ]  Identifiera paleolitikum
        - Undersöka A
        - Undersöka B
        - Undersöka C
        - Undersöka D
        - Undersöka E
        - Undersöka F

        ## Att göra (Checklista)
        - Skicka offerten
        - [x] Boka rum
        """
        #expect(NotesTidy.tidy(raw, language: .swedish) == """
        ## Beslut
        - Identifiera Paleolitikum
        - Undersöka A
        - Undersöka B
        - Undersöka C
        - Undersöka D
        - Undersöka E

        ## Att göra
        - [ ] Skicka offerten
        - [x] Boka rum
        """)
    }

    @Test func tidySummary() {
        let raw = "## Sammanfattning\nEtt. Två. Ett. Tre. Fyra. Fem. Sex.\n\n## Beslut\n- A"
        #expect(NotesTidy.tidy(raw, language: .swedish) == "## Sammanfattning\nEtt. Två. Tre. Fyra. Fem.\n\n## Beslut\n- A")
    }

    @Test func chatterIsRemoved() {
        let gen = NotesGenerator(maxChars: 1000) { _, _ in "" }
        let raw = "Okay, here are the notes based on the transcript.\n\n## Sammanfattning\nText.\n\n- punkt\n\nI have focused on the transcript."
        #expect(gen.clean(raw) == "## Sammanfattning\nText.\n\n- punkt")
        #expect(gen.clean("## Beslut\n- Inget nämndes") == "## Beslut\n- Inget nämndes")
    }

    @Test func aFewWordsSkipTheModel() async throws {
        let calls = Calls()
        let gen = NotesGenerator(maxChars: 6000) { _, prompt in _ = await calls.add(prompt); return "invented" }
        let notes = try await gen.notes(transcript: "[0:00] **Speaker:** Hej, jag heter Johan. Jag är 33 år och bor i Århus. Var bor du?",
                                        title: "Möte", language: .swedish, instructions: NotesPrompt.defaultInstructions)
        #expect(notes == NotesPrompt.tooLittle(.swedish))
        #expect(await calls.prompts.isEmpty)
    }

    @Test func shortTranscriptIsOneCall() async throws {
        let calls = Calls()
        let gen = NotesGenerator(maxChars: 1000) { _, prompt in
            _ = await calls.add(prompt)
            return "```markdown\n## Summary\nShort.\n```"
        }
        let transcript = "[0:00] **Speaker:** " + String(repeating: "hi ", count: 40)
        let notes = try await gen.notes(transcript: transcript, title: "T", language: .english, instructions: "I")
        #expect(notes == "## Summary\nShort.")
        #expect(await calls.prompts.count == 1)
    }

    @Test func tooShortTranscriptSkipsTheModel() async throws {
        let calls = Calls()
        let gen = NotesGenerator(maxChars: 1000) { _, prompt in
            _ = await calls.add(prompt)
            return "invented"
        }
        let transcript = "[0:00] **Speaker:** Hej, ska vi börja?\n\n[0:05] **Speaker:** Ja, tack."
        let notes = try await gen.notes(transcript: transcript, title: "T", language: .swedish, instructions: "I")
        #expect(notes == NotesPrompt.tooLittle(.swedish))
        #expect(try await gen.notes(transcript: "  ", title: "T", language: .english, instructions: "I") == NotesPrompt.tooLittle(.english))
        #expect(await calls.prompts.isEmpty)
        #expect(NotesPrompt.wordCount(transcript) == 6)
    }

    @Test func everyCallIsGrounded() async throws {
        let gen = NotesGenerator(maxChars: 1500) { system, _ in
            #expect(system.contains("Never invent names, numbers, dates, decisions or action items."))
            #expect(system.contains("Write in Swedish"))
            return "- ok"
        }
        let transcript = (0..<60).map { "[\($0):00] **Speaker:** " + String(repeating: "pratar ", count: 10) }.joined(separator: "\n\n")
        _ = try await gen.notes(transcript: transcript, title: "T", language: .swedish, instructions: "I")
        #expect(NotesPrompt.grounding(.automatic).contains("Swedish if the transcript is Swedish"))
        #expect(NotesPrompt.defaultInstructions.contains("Inget nämndes"))
        #expect(NotesPrompt.notMentioned(.swedish) == "Inget nämndes")
    }

    @Test func partsStaySmallForBigContexts() {
        #expect(NotesGenerator.maxChars(contextTokens: 8192) == NotesGenerator.maxPartChars)
    }

    @Test func longTranscriptIsMapReduced() async throws {
        let calls = Calls()
        let gen = NotesGenerator(maxChars: 1500) { system, prompt in
            #expect(system.contains("Swedish"))
            let n = await calls.add(prompt)
            return prompt.hasPrefix("Meeting title") ? "FINAL" : "- point \(n)"
        }
        let transcript = (0..<60).map { "[\($0):00] **Speaker:** " + String(repeating: "pratar ", count: 10) }.joined(separator: "\n\n")
        let notes = try await gen.notes(transcript: transcript, title: "T", language: .swedish, instructions: "I")
        #expect(notes == "FINAL")
        let prompts = await calls.prompts
        #expect(prompts.count >= 4)
        #expect(prompts.dropLast().allSatisfy { $0.contains("part") })
        #expect(prompts.last!.contains("Notes for part 1:\n- point 1"))
        #expect(prompts.allSatisfy { $0.count < 1500 + 800 })
    }

    @Test func partNotesAreMergedWhenTooLong() async throws {
        let calls = Calls()
        let gen = NotesGenerator(maxChars: 1500) { _, prompt in
            _ = await calls.add(prompt)
            if prompt.hasPrefix("Meeting title") { return "FINAL" }
            if prompt.hasPrefix("Below are notes") { return "- merged" }
            return String(repeating: "- long part note\n", count: 30)   // ~500 chars per part
        }
        let transcript = (0..<200).map { "[\($0):00] **Speaker:** " + String(repeating: "ord ", count: 10) }.joined(separator: "\n\n")
        let notes = try await gen.notes(transcript: transcript, title: "T", language: .english, instructions: "I")
        #expect(notes == "FINAL")
        let prompts = await calls.prompts
        #expect(prompts.contains { $0.hasPrefix("Below are notes") })
        #expect(prompts.last!.count < 1500 + 800)
    }

    @Test func retriesWithSmallerChunksWhenContextIsExceeded() async throws {
        let calls = Calls()
        let gen = NotesGenerator(maxChars: 4000) { _, prompt in
            _ = await calls.add(prompt)
            if prompt.count > 2500 { throw NotesError.contextExceeded }
            return "ok"
        }
        let transcript = (0..<40).map { "[\($0):00] **Speaker:** " + String(repeating: "ord ", count: 20) }.joined(separator: "\n\n")
        let notes = try await gen.notes(transcript: transcript, title: "T", language: .english, instructions: "I")
        #expect(notes == "ok")
    }
}

@Suite struct MarkdownTests {
    @Test func doubledCheckboxes() {
        #expect(MarkdownBlock.parse("*   [ ] [ ]  Skicka offerten") == [.checkbox(indent: 0, checked: false, text: "Skicka offerten")])
    }

    @Test func parsesNotes() {
        let md = """
        ## Sammanfattning
        Vi pratade om **budgeten**
        och planen.

        ## Att göra
        - [ ] Anna: skicka offerten
        - [x] Boka rum
        - Vanlig punkt
          - Underpunkt
        1. Först
        2) Sedan
        ---
        #hashtag
        """
        #expect(MarkdownBlock.parse(md) == [
            .heading(level: 2, text: "Sammanfattning"),
            .paragraph("Vi pratade om **budgeten** och planen."),
            .heading(level: 2, text: "Att göra"),
            .checkbox(indent: 0, checked: false, text: "Anna: skicka offerten"),
            .checkbox(indent: 0, checked: true, text: "Boka rum"),
            .bullet(indent: 0, text: "Vanlig punkt"),
            .bullet(indent: 1, text: "Underpunkt"),
            .numbered(indent: 0, number: "1", text: "Först"),
            .numbered(indent: 0, number: "2", text: "Sedan"),
            .rule,
            .paragraph("#hashtag"),
        ])
    }
}
