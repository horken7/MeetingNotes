import MeetingCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @AppStorage(Keys.name) private var name = ""
    @AppStorage(Keys.language) private var language = MeetingLanguage.automatic.rawValue
    @AppStorage(Keys.keepAudio) private var keepAudio = false
    @AppStorage(Keys.notesInstructions) private var instructions = ""
    @AppStorage(Keys.notesEngine) private var engine = NotesEngine.automatic.rawValue
    @State private var draft = ""

    private var meetingLanguage: MeetingLanguage { MeetingLanguage(rawValue: language) ?? .automatic }
    private var notesEngine: NotesEngine { NotesEngine(rawValue: engine) ?? .automatic }

    var body: some View {
        let _ = app.modelsChanged
        NavigationStack {
            Form {
                Section {
                    TextField("Your name (optional)", text: $name)
                        .textContentType(.name)
                    Picker("Meeting language", selection: $language) {
                        ForEach(MeetingLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } footer: {
                    Text("Automatic picks Swedish, Danish or English from what's said. Choose a language if it guesses wrong.")
                }

                Section {
                    LabeledContent("Speech recognition", value: speechModel.label)
                    Picker("Notes written by", selection: $engine) {
                        Text("Automatic (\(NotesEngine.automatic.gemma?.label ?? ""))").tag(NotesEngine.automatic.rawValue)
                        Text(NotesEngine.gemma1b.label).tag(NotesEngine.gemma1b.rawValue)
                        if (ModelStore.isReady(Catalog.gemma4b) && Catalog.fits(Catalog.gemma4b, physicalMemory: ProcessInfo.processInfo.physicalMemory))
                            || notesEngine == .gemma4b {
                            Text(NotesEngine.gemma4b.label).tag(NotesEngine.gemma4b.rawValue)
                        }
                        if AppleNotes.unavailableReason == nil || notesEngine == .apple {
                            Text(NotesEngine.apple.label).tag(NotesEngine.apple.rawValue)
                        }
                    }
                } header: {
                    Text("In use")
                } footer: {
                    Text(inUseFooter)
                }

                Section {
                    ForEach(Catalog.optional) { ModelRow(model: $0) }
                } header: {
                    Text("Better models (optional downloads)")
                } footer: {
                    Text("The app uses the best model you have for each language. Downloads come from Hugging Face; Wi-Fi recommended.")
                }

                Section("Built into the app") {
                    ForEach(Catalog.builtIn) { ModelRow(model: $0) }
                }

                Section {
                    Toggle("Keep audio recordings", isOn: $keepAudio)
                } footer: {
                    Text("When off, the audio is deleted as soon as the transcript is ready.")
                }

                Section {
                    TextEditor(text: $draft)
                        .font(.callout.monospaced())
                        .frame(minHeight: 220)
                        .onChange(of: draft) { _, new in
                            instructions = new.trimmingCharacters(in: .whitespacesAndNewlines) == NotesPrompt.defaultInstructions ? "" : new
                        }
                    Button("Reset to default") { draft = NotesPrompt.defaultInstructions }
                        .disabled(draft == NotesPrompt.defaultInstructions)
                } header: {
                    Text("Notes instructions")
                } footer: {
                    Text("How the notes should look. Used for every new or regenerated note.")
                }

                Section {
                    Text("Recordings, transcripts and notes stay on this iPhone, in Files > On My iPhone > Meeting Notes. Speech recognition (Whisper) and the notes (Gemma) run on the phone, offline. Your audio and text never leave it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NavigationLink("Licenses") { LicensesView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { draft = NotesPrompt.effectiveInstructions(instructions) }
        }
    }

    private var speechModel: ModelFile {
        Catalog.speechModel(for: meetingLanguage == .automatic ? .swedish : meetingLanguage, isReady: ModelStore.isReady)
    }

    private var inUseFooter: String {
        var lines: [String] = []
        if let better = Catalog.recommendedDownload(for: meetingLanguage), !ModelStore.isReady(better) {
            lines.append("For \(meetingLanguage.label), \(better.label) (\(Catalog.size(better.bytes))) makes clearly fewer mistakes; download it below.")
        }
        switch notesEngine {
        case .apple:
            lines.append(AppleNotes.unavailableReason ?? "Apple Intelligence writes the notes.")
        case .automatic:
            lines.append(ModelStore.isReady(Catalog.gemma4b) || !Catalog.fits(Catalog.gemma4b, physicalMemory: ProcessInfo.processInfo.physicalMemory)
                ? "Automatic uses the best Gemma model this iPhone has memory for."
                : "Gemma 3 4B writes much better notes; download it below.")
        default:
            lines.append(notesEngine.gemma?.detail ?? "")
        }
        return lines.joined(separator: " ")
    }
}

/// Licenses and terms of the bundled and downloadable models and libraries.
struct LicensesView: View {
    var body: some View {
        List {
            Section("Gemma") {
                Text("Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms. Use of Gemma is also subject to the Gemma Prohibited Use Policy at ai.google.dev/gemma/prohibited_use_policy.")
                Link("Gemma Terms of Use", destination: URL(string: "https://ai.google.dev/gemma/terms")!)
                Link("Gemma Prohibited Use Policy", destination: URL(string: "https://ai.google.dev/gemma/prohibited_use_policy")!)
            }
            Section("Speech models") {
                Text("Whisper by OpenAI, MIT License. KB-Whisper by KBLab, National Library of Sweden, Apache License 2.0. Silero VAD, MIT License.")
            }
            Section("Libraries") {
                Text("whisper.cpp and llama.cpp (ggml) by the ggml authors, MIT License.")
            }
        }
        .font(.callout)
        .navigationTitle("Licenses")
    }
}
