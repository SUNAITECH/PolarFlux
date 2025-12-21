import Foundation

class Logger {
    static let shared = Logger()
    private let logFileURL: URL
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.lumisync.logger")

    private init() {
        // Use a fixed path in the project directory for easy access as requested
        let path = "/Users/Jaden/Downloads/lightstrip/LumiSync/debug.log"
        self.logFileURL = URL(fileURLWithPath: path)
        
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        
        do {
            self.fileHandle = try FileHandle(forWritingTo: logFileURL)
            self.fileHandle?.seekToEndOfFile()
        } catch {
            print("Failed to open log file: \(error)")
            self.fileHandle = nil
        }
        
        log("Logger initialized. Log file: \(path)")
    }
    
    func log(_ message: String) {
        queue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let timestamp = formatter.string(from: Date())
            let logMessage = "[\(timestamp)] \(message)\n"
            
            if let data = logMessage.data(using: .utf8) {
                self.fileHandle?.write(data)
            }
            // Also print to console
            print(logMessage, terminator: "")
        }
    }
}
