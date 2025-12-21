import Foundation
import ServiceManagement

class LaunchAtLogin {
    static func setEnabled(_ enabled: Bool) {
        // For non-sandboxed apps, we can use the old LSSharedFileList API or just write a LaunchAgent plist.
        // Since we are building a standalone app, writing a plist is robust.
        
        let label = "com.jaden.lumisync.launcher"
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        
        if enabled {
            guard let appPath = Bundle.main.executablePath else { return }
            
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            
            do {
                try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to write launch agent: \(error)")
            }
        } else {
            try? FileManager.default.removeItem(at: plistPath)
        }
    }
    
    static var isEnabled: Bool {
        let label = "com.jaden.lumisync.launcher"
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        return FileManager.default.fileExists(atPath: plistPath.path)
    }
}
