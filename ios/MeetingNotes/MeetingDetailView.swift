import MeetingCore
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String

    enum Tab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }
    @State private var tab: Tab = .notes
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @State private var audioGone = false
    @State private var exporting = false
    @State private var exportDocument = MarkdownFile(text: "")
    @State private var exportName = ""

    var body: some View {
        if let m = model.meeting(id: id) {
            content(m)
        } else {
            ContentUnavailableView("Meeting not found", systemImage: "questionmark.folder")
        }
    }

    private func content(_ m: Meeting) -> some View {
        let notes = MeetingStore.readBody(m.folder, MeetingStore.notesFile)
        let transcript = MeetingStore.readBody(m.folder, MeetingStore.transcriptFile)
        let busy = model.progress[m.id] != nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(m)
                if let p = model.progress[m.id] {
                    VStack(alignment: .leading, spacing: 8) {
                        Banner(icon: nil, text: p + ". Keep the app open.", tint: .blue)
                        Button("Stop", role: .cancel) { model.cancelProcessing(m.id) }
                            .buttonStyle(.bordered)
                    }
                } else if m.status == "failed", let error = m.meta.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Banner(icon: "exclamationmark.triangle", text: error, tint: .orange)
                        retryButton(m, hasTranscript: !transcript.isEmpty)
                    }
                }
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                let text = tab == .notes ? notes : transcript
                if text.isEmpty {
                    Text(tab == .notes
                         ? (busy ? "The notes will appear here." : "No notes yet.")
                         : (busy ? "The transcript will appear here." : "No transcript yet."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    MarkdownView(markdown: text)
                }
            }
            .padding()
        }
        .navigationTitle(m.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let url = shareFile(m, tab == .notes ? notes : transcript) {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                menu(m, notes: notes, transcript: transcript, busy: busy)
            }
        }
        .alert("Rename meeting", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.rename(m, to: newTitle) }
        }
        .alert("The audio was deleted", isPresented: $audioGone) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The audio was deleted when the transcript was made, so the transcript can't be redone or made in another language. To keep the audio of future meetings, turn on Keep audio recordings in Settings.")
        }
        .confirmationDialog("Delete \"\(m.title)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete meeting", role: .destructive) {
                model.delete(m)
                dismiss()
            }
        } message: {
            Text("The notes, transcript and audio are deleted from this iPhone.")
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: MarkdownFile.markdown,
                      defaultFilename: exportName) { _ in }
    }

    private func header(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.title).font(.title2.bold())
            HStack(spacing: 6) {
                Text(m.created, format: .dateTime.weekday().day().month().year().hour().minute())
                if let d = m.meta.duration { Text("· \(formatLength(d))") }
                if let l = m.meta.lang.flatMap(MeetingLanguage.init(rawValue:)) { Text("· \(l.label)") }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func retryButton(_ m: Meeting, hasTranscript: Bool) -> some View {
        if hasTranscript {
            Button("Write notes", systemImage: "sparkles") { model.process(m.folder, notesOnly: true) }
                .buttonStyle(.borderedProminent)
        } else if m.hasAudio {
            Button("Make transcript", systemImage: "waveform") { model.process(m.folder) }
                .buttonStyle(.borderedProminent)
        }
    }

    private func menu(_ m: Meeting, notes: String, transcript: String, busy: Bool) -> some View {
        Menu {
            Button("Rename", systemImage: "pencil") { newTitle = m.title; renaming = true }
            Button("Regenerate notes", systemImage: "sparkles") { model.process(m.folder, notesOnly: true) }
                .disabled(busy || transcript.isEmpty)
            if m.hasAudio {
                Menu("Redo transcript", systemImage: "waveform") {
                    ForEach(MeetingLanguage.allCases) { l in
                        Button(l.label) { model.process(m.folder, language: l) }
                    }
                }
                .disabled(busy)
            } else if !transcript.isEmpty {
                // Shown so it's clear why the transcript can't be redone.
                Button("Redo transcript", systemImage: "waveform") { audioGone = true }
            }
            Divider()
            Button("Save notes to Files", systemImage: "folder") { export(m, "notes", notes) }
                .disabled(notes.isEmpty)
            Button("Save transcript to Files", systemImage: "folder") { export(m, "transcript", transcript) }
                .disabled(transcript.isEmpty)
            if m.hasAudio {
                Button("Delete audio", systemImage: "waveform.slash") { model.deleteAudio(m) }
                    .disabled(busy)
            }
            Divider()
            Button("Delete meeting", systemImage: "trash", role: .destructive) { confirmDelete = true }
                .disabled(busy || model.recorder?.folder == m.folder)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    private func export(_ m: Meeting, _ kind: String, _ body: String) {
        exportDocument = MarkdownFile(text: document(m, kind, body))
        exportName = "\(MeetingStore.folderName(title: m.title, date: m.created)) \(kind).md"
        exporting = true
    }

    private func document(_ m: Meeting, _ kind: String, _ body: String) -> String {
        "# \(m.title)\(kind == "transcript" ? ": transcript" : "")\n\n\(body)\n"
    }

    /// A Markdown copy of what's on screen, named after the meeting, for the share sheet
    /// (Mail, Messages, Notes, "Save to Files"…).
    private func shareFile(_ m: Meeting, _ body: String) -> URL? {
        guard !body.isEmpty else { return nil }
        let kind = tab == .notes ? "notes" : "transcript"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(MeetingStore.folderName(title: m.title, date: m.created)) \(kind).md")
        do {
            try document(m, kind, body).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

struct Banner: View {
    var icon: String?
    var text: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon { Image(systemName: icon) } else { ProgressView() }
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct MarkdownFile: FileDocument {
    static let markdown = UTType("net.daringfireball.markdown") ?? .plainText
    static var readableContentTypes: [UTType] { [markdown, .plainText] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Renders the notes' Markdown: headings, bullets, numbered items, checkboxes, and inline bold/italics/links.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                row(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 10 : 4)
        case .bullet(let indent, let text):
            item(indent: indent, marker: Text("•"), text: text)
        case .numbered(let indent, let number, let text):
            item(indent: indent, marker: Text("\(number).").monospacedDigit(), text: text)
        case .checkbox(let indent, let checked, let text):
            item(indent: indent, marker: Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.green : Color.secondary), text: text)
        case .paragraph(let text):
            inline(text)
        case .rule:
            Divider()
        }
    }

    private func item(indent: Int, marker: some View, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.frame(minWidth: 16, alignment: .trailing)
            inline(text)
        }
        .padding(.leading, CGFloat(indent) * 20)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: text, options: options) { return Text(a) }
        return Text(text)
    }
}
