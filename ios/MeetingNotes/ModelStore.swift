import Foundation
import MeetingCore

/// The downloaded model files, in Application Support/Models (not backed up to iCloud, not shown in Files).
enum ModelStore {
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var u = url
            try? u.setResourceValues(values)
        }
        return url
    }

    /// The models that ship inside the app (ios/scripts/fetch-models.sh), read straight from the app bundle.
    static func bundled(_ m: ModelFile) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Models/\(m.fileName)"), size(url) == m.bytes else { return nil }
        return url
    }

    static func isBundled(_ m: ModelFile) -> Bool { bundled(m) != nil }

    static func downloadedURL(_ m: ModelFile) -> URL { folder.appendingPathComponent(m.fileName) }

    static func url(_ m: ModelFile) -> URL { bundled(m) ?? downloadedURL(m) }

    static func isReady(_ m: ModelFile) -> Bool { isBundled(m) || size(downloadedURL(m)) == m.bytes }

    static func delete(_ m: ModelFile) { try? FileManager.default.removeItem(at: downloadedURL(m)) }

    /// Frees the space of downloaded copies of models that now ship inside the app.
    static func removeDownloadedCopiesOfBundled() {
        for m in Catalog.all where isBundled(m) { delete(m) }
    }

    private static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    static var downloaded: [ModelFile] { Catalog.all.filter(isReady) }

    /// Downloads a model unless it's already there, reporting progress from 0 to 1.
    static func ensure(_ m: ModelFile, cancel: CancelFlag, progress: @escaping @Sendable (Double) -> Void) async throws {
        if isReady(m) { return }
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        if free < m.bytes + 200_000_000 {
            throw EngineError.failed("There isn't enough free space on this iPhone for \(m.label) (\(Catalog.size(m.bytes))). Free up some space and try again.")
        }
        let downloader = Downloader(progress: progress, cancel: cancel)
        let temp = try await downloader.download(m.url)
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0
        guard size == m.bytes else {
            try? FileManager.default.removeItem(at: temp)
            throw EngineError.failed("The download of \(m.label) was incomplete. Check the internet connection and try again.")
        }
        try? FileManager.default.removeItem(at: downloadedURL(m))
        try FileManager.default.moveItem(at: temp, to: downloadedURL(m))
    }
}

/// One file download with progress, cancellable.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let cancel: CancelFlag
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastReport = Date.distantPast

    init(progress: @escaping @Sendable (Double) -> Void, cancel: CancelFlag) {
        self.progress = progress
        self.cancel = cancel
    }

    func download(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if cancel.isCancelled { downloadTask.cancel(); return }
        guard totalBytesExpectedToWrite > 0, Date().timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = Date()
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw EngineError.failed("The model download failed (HTTP \(http.statusCode)). Try again later.")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let c = continuation else { return }
        continuation = nil
        c.resume(throwing: cancel.isCancelled ? EngineError.cancelled
                 : EngineError.failed("The model download failed: \(error.localizedDescription)"))
    }
}
