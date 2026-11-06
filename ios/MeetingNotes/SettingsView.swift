import MeetingCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Keys.name) private var name = ""
    @AppStorage(Keys.language) private var language = MeetingLanguage.automatic.rawValue
    @AppStorage(Keys.keepAudio) private var keepAudio = true
    @AppStorage(Keys.notesInstructions) private var instructions = ""
    @State private var draft = ""

    var body: some View {
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
                    Toggle("Keep audio after the notes are written", isOn: $keepAudio)
                } footer: {
                    Text("Keeping the audio lets you redo the transcript later. An hour of audio takes about 115 MB.")
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

                Section("Apple Intelligence") {
                    if let reason = NotesWriter.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Label("Ready to write notes on this iPhone", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                }

                Section {
                    Text("Recordings, transcripts and notes stay on this iPhone, in Files > On My iPhone > Meeting Notes. Speech recognition and notes run on the device; only the speech model for a language is downloaded from Apple the first time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
}
