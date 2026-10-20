import Foundation
import AppKit
import CoreAudio

/// An app that is currently using a microphone.
struct MicUser: Equatable {
    let pid: pid_t
    let bundleID: String
    let name: String

    /// Groups helper processes with their app (com.google.Chrome.helper -> com.google.Chrome).
    var key: String {
        if let r = bundleID.range(of: ".helper", options: .caseInsensitive) {
            return String(bundleID[..<r.lowerBound])
        }
        return bundleID
    }

    /// System services (Siri, dictation, the capture daemon) and this app itself.
    var isSystem: Bool {
        if pid == getpid() || bundleID.isEmpty || bundleID == Bundle.main.bundleIdentifier { return true }
        if bundleID.hasPrefix("com.apple.") {
            let allowed = ["com.apple.FaceTime", "com.apple.WebKit", "com.apple.Safari"]
            return !allowed.contains { bundleID.hasPrefix($0) }
        }
        return false
    }
}

enum MicMonitor {
    /// Uses Core Audio's per-process objects (macOS 14.4+) to see which apps have the mic open.
    /// With `orPlaying`, also includes apps playing audio (a call app muted in-app may close the mic but keeps playing).
    static func users(orPlaying: Bool = false) -> [MicUser] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        var result: [MicUser] = []
        for id in ids {
            let input: UInt32 = read(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0
            let output: UInt32 = orPlaying ? (read(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) : 0
            guard input != 0 || output != 0 else { continue }
            let pid: pid_t = read(id, kAudioProcessPropertyPID, pid_t(0)) ?? 0
            var bundle = ""
            if let ref: Unmanaged<CFString>? = read(id, kAudioProcessPropertyBundleID, Optional<Unmanaged<CFString>>.none),
               let r = ref {
                bundle = r.takeRetainedValue() as String
            }
            result.append(MicUser(pid: pid, bundleID: bundle, name: displayName(pid: pid, bundle: bundle)))
        }
        return result
    }

    private static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? value : nil
    }

    private static func displayName(pid: pid_t, bundle: String) -> String {
        if bundle.hasPrefix("com.apple.WebKit") { return "Safari" }
        // Helper processes (com.google.Chrome.helper) aren't registered apps, so name them after their parent app.
        let key = MicUser(pid: pid, bundleID: bundle, name: "").key
        var name = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: key).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: key)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? key.split(separator: ".").last.map(String.init)
            ?? "An app"
        for marker in [" Helper", " Web Content", " Graphics and Media"] {
            if let r = name.range(of: marker) { name = String(name[..<r.lowerBound]) }
        }
        return name
    }
}
