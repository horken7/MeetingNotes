import SwiftUI
import AppKit
import ServiceManagement
import ScreenCaptureKit

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
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start at login by default (once; it can be turned off in Settings), so calls are always detected.
        let offered = "loginItemOffered"
        if !UserDefaults.standard.bool(forKey: offered) {
            UserDefaults.standard.set(true, forKey: offered)
            try? SMAppService.mainApp.register()
        }
        AppModel.shared.launch()

        // Like a background service: no Dock icon while the window is closed.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { Self.updateDockIcon() }
            }
        }
        captureScreenshotsIfRequested()
        if launchedAtLogin {
            // Started at login: stay in the menu bar without opening the window.
            DispatchQueue.main.async {
                for w in Self.mainWindows() { w.close() }
                Self.updateDockIcon()
            }
        }
    }

    /// Opening the app (Finder, Spotlight, Dock) while it runs in the background shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let open = AppModel.shared.openMainWindow else { return true }
        open()
        return false
    }

    /// Development aid for the README screenshots, using the app's own Screen Recording permission:
    ///   open -a "Meeting Notes" --args -captureScreenshots <dir> [-outputDir <demo meetings>] [-screenshotAppearance dark]
    @MainActor private func captureScreenshotsIfRequested() {
        let d = UserDefaults.standard
        guard let dir = d.string(forKey: "captureScreenshots") else { return }
        let dark = d.string(forKey: "screenshotAppearance") == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        AppModel.shared.showDemoPrompt()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            for w in NSApp.windows { w.makeFirstResponder(nil) }
            try? await Task.sleep(for: .seconds(1))
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            for w in content.windows where w.owningApplication?.processID == getpid() && w.frame.height > 60 {
                let config = SCStreamConfiguration()
                config.width = Int(w.frame.width * 2)
                config.height = Int(w.frame.height * 2)
                config.showsCursor = false
                guard let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config) else { continue }
                let name = (w.frame.height < 300 ? "prompt" : "window") + (dark ? "-dark" : "") + ".png"
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                try? data?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }

    static func mainWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    static func updateDockIcon() {
        let policy: NSApplication.ActivationPolicy = mainWindows().isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
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
        Button("Open Meeting Notes") { model.openMainWindow?() }
        Divider()
        Button("Quit Meeting Notes") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu bar icon: a waveform when idle, a red dot while recording (a stop icon while auto-stop counts down),
/// and an hourglass while transcribing or writing notes. Details are in the menu.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon.onAppear {
            // The label is always alive, so it provides "open the window" to the app delegate and the menu.
            model.openMainWindow = {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate()
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let r = model.recording {
            Image(systemName: r.stopsAt == nil ? "record.circle.fill" : "stop.circle")
        } else if model.meetings.contains(where: { ["transcribing", "summarizing"].contains($0.status) }) {
            Image(systemName: "hourglass")
        } else {
            Image(systemName: "waveform")
        }
    }
}
