import MeetingCore
import SwiftUI

/// First launch: which language the meetings are usually in, and an optional better model for it.
/// The built-in models work right away, so the download is never required.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Keys.language) private var language = MeetingLanguage.automatic.rawValue
    @State private var step = 0
    var onDone: () -> Void

    private var choice: MeetingLanguage { MeetingLanguage(rawValue: language) ?? .automatic }

    var body: some View {
        NavigationStack {
            Form {
                if step == 0 {
                    Section {
                        Picker("Language", selection: $language) {
                            ForEach([MeetingLanguage.swedish, .danish, .english, .automatic]) { Text($0.label).tag($0.rawValue) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Which language are your meetings usually in?")
                    } footer: {
                        Text("Automatic hears which language is spoken. You can change this later in Settings.")
                    }
                } else if let better = Catalog.recommendedDownload(for: choice) {
                    Section {
                        Text("Meeting Notes works right away with its built-in speech model, offline. For \(choice.label), \(better.label) makes clearly fewer mistakes.")
                        ModelRow(model: better)
                    } footer: {
                        Text("Optional: \(Catalog.size(better.bytes)), downloaded once (Wi-Fi recommended). You can download or delete models later in Settings.")
                    }
                }
            }
            .navigationTitle("Welcome")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if step == 0, Catalog.recommendedDownload(for: choice) != nil {
                        Button("Next") { step = 1 }
                    } else if step == 1, let m = Catalog.recommendedDownload(for: choice), ModelStore.isReady(m) || model.downloads[m.id] != nil {
                        Button("Done") { onDone() }
                    } else if step == 1 {
                        Button("Use the built-in model") { onDone() }
                    } else {
                        Button("Done") { onDone() }
                    }
                }
            }
        }
    }
}

/// A model with its size and a Download / Stop / Delete control. Deleting asks first.
struct ModelRow: View {
    @Environment(AppModel.self) private var app
    let model: ModelFile
    @State private var confirmDelete = false

    var body: some View {
        let _ = app.modelsChanged
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.label).font(.headline)
                Spacer()
                Text(Catalog.size(model.bytes)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(model.detail).font(.footnote).foregroundStyle(.secondary)
            if let p = app.downloads[model.id] {
                HStack {
                    ProgressView(value: p)
                    Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                    Button("Stop") { app.cancelDownload(model) }.buttonStyle(.borderless)
                }
            } else if ModelStore.isBundled(model) {
                Label("Included in the app", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            } else if ModelStore.isReady(model) {
                HStack {
                    Label("Downloaded", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                    Spacer()
                    Button("Delete", role: .destructive) { confirmDelete = true }.buttonStyle(.borderless)
                }
            } else if !Catalog.fits(model, physicalMemory: ProcessInfo.processInfo.physicalMemory) {
                Label("This iPhone doesn't have enough memory for it.", systemImage: "memorychip").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Download", systemImage: "arrow.down.circle") { app.download(model) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Delete \(model.label)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete model", role: .destructive) { app.deleteModel(model) }
        } message: {
            Text("Frees \(Catalog.size(model.bytes)). You can download it again later.")
        }
    }
}
