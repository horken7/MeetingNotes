import SwiftUI
import AppKit

@main
struct MeetingNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() {
        registerDefaults()
    }

    var body: some Scene {
        Window("Meeting Notes", id: "main") {
            MainView().environmentObject(model)
        }
        .defaultSize(width: 1000, height: 660)

        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.launch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.recording != nil else { return .terminateNow }
        Task { @MainActor in
            await AppModel.shared.stopForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let r = model.recording {
            Text("Recording: \(r.title) · \(formatDuration(model.now.timeIntervalSince(r.start)))")
            if let at = r.stopsAt {
                Text("Call ended. Stopping in \(max(0, Int(at.timeIntervalSince(model.now)))) s")
            }
            Button("Stop and take notes") { model.stop() }
        } else {
            Button("Start meeting notes") { model.start() }
                .disabled(model.starting)
        }
        ForEach(model.meetings.filter { ["transcribing", "summarizing"].contains($0.status) }) { m in
            Text("\(m.status == "transcribing" ? "Transcribing" : "Writing notes"): \(m.title)")
        }
        Divider()
        Button("Open Meeting Notes") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Quit Meeting Notes") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu bar icon: a waveform when idle, a red dot while recording (a stop icon while auto-stop counts down),
/// and an hourglass while transcribing or writing notes. Details are in the menu.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let r = model.recording {
            Image(systemName: r.stopsAt == nil ? "record.circle.fill" : "stop.circle")
        } else if model.meetings.contains(where: { ["transcribing", "summarizing"].contains($0.status) }) {
            Image(systemName: "hourglass")
        } else {
            Image(systemName: "waveform")
        }
    }
}
