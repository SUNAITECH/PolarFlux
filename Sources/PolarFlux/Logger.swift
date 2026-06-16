import Foundation
import os

/// Centralised logging facility.
///
/// Uses the unified `os.Logger` for efficient, always-on structured logging, and
/// additionally mirrors messages to a rolling file under Application Support for
/// diagnostics. File output is capped to `maxFileBytes`; once exceeded the older
/// half of the file is discarded so it can never grow unbounded.
final class Logger {
    static let shared = Logger()

    private let osLogger: os.Logger
    private let logFileURL: URL
    private let queue = DispatchQueue(label: "com.sunaish.polarflux.logger")
    private let maxFileBytes: Int64 = 2 * 1024 * 1024 // 2 MB rolling cap

    // Access to `fileHandle` is serialised on `queue`.
    private var fileHandle: FileHandle?

    private init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sunaish.polarflux"
        self.osLogger = os.Logger(subsystem: bundleID, category: "PolarFlux")

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let logDir = appSupport.appendingPathComponent("PolarFlux", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        self.logFileURL = logDir.appendingPathComponent("app.log")

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        // Roll the file if it grew too large since the last run.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? Int64, size > maxFileBytes {
            Logger.trimFileHead(at: logFileURL)
        }

        do {
            self.fileHandle = try FileHandle(forWritingTo: logFileURL)
            self.fileHandle?.seekToEndOfFile()
        } catch {
            self.fileHandle = nil
        }
    }

    func log(_ message: String) {
        // Always emit to the unified logging system (cheap and structured).
        osLogger.info("\(message, privacy: .public)")
        #if DEBUG
        print(message)
        #endif

        queue.async { [weak self] in
            self?.writeToFile(message)
        }
    }

    private func writeToFile(_ message: String) {
        guard let fileHandle = fileHandle else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }

        fileHandle.write(data)

        if let offset = try? fileHandle.offset(), offset > maxFileBytes {
            rollFile()
        }
    }

    /// Trims the oldest ~50% of the file and reopens the handle at the end.
    private func rollFile() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        Logger.trimFileHead(at: logFileURL)
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    private static func trimFileHead(at url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let keepFrom = data.count / 2
        guard keepFrom < data.count else { return }
        var start = keepFrom
        // Begin at the next newline to avoid a partial first line.
        if let nlRange = data.range(of: Data([0x0A]), in: keepFrom..<data.count) {
            start = nlRange.upperBound
        }
        let trimmed = data.subdata(in: start..<data.count)
        try? trimmed.write(to: url)
    }
}
