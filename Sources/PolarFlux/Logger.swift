import Foundation

class Logger {
    static let shared = Logger()
    private let logFileURL: URL
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.sunaish.polarflux.logger")

    private init() {
        // Use a standard application support path for production logs
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDir = appSupport.appendingPathComponent("PolarFlux", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        
        self.logFileURL = logDir.appendingPathComponent("app.log")
        let path = logFileURL.path
        
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        
        do {
            self.fileHandle = try FileHandle(forWritingTo: logFileURL)
            self.fileHandle?.seekToEndOfFile()
        } catch {
            self.fileHandle = nil
        }
    }
    
    func log(_ message: String) {
        #if DEBUG
        queue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timestamp = formatter.string(from: Date())
            let logMessage = "[\(timestamp)] \(message)\n"
            
            if let data = logMessage.data(using: .utf8) {
                self.fileHandle?.write(data)
            }
            // Also print to console in debug
            print(logMessage, terminator: "")
        }
        #endif
    }
}
