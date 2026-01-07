import Foundation
import ServiceManagement
import os

class LaunchAtLogin {
    private static let logger = os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.sunaish.polarflux", category: "LaunchAtLogin")
    
    // Identifier used for the old manual plist approach
    private static let legacyLabel = "com.sunaish.polarflux.launcher"
    
    static func setEnabled(_ enabled: Bool) {
        // Always try to clean up the legacy plist to avoid dual-launch or conflicts.
        // This ensures that if the user previously used the broken/old implementation, it gets cleaned up.
        removeLegacyPlist()
        
        // Use SMAppService for macOS 13+ (Ventura and later)
        // This leverages the modern Login Items API which is safer and "approved" by the system.
        let service = SMAppService.mainApp
        
        if enabled {
            // Only register if not already enabled to avoid unnecessary errors
            if service.status == .enabled {
                logger.info("Launch at login is already enabled.")
                return
            }
            
            do {
                try service.register()
                logger.info("Successfully registered SMAppService for launch at login.")
            } catch {
                logger.error("Failed to enable launch at login: \(error.localizedDescription)")
            }
        } else {
            do {
                try service.unregister()
                logger.info("Successfully unregistered SMAppService for launch at login.")
            } catch {
                logger.error("Failed to disable launch at login: \(error.localizedDescription)")
            }
        }
    }
    
    static var isEnabled: Bool {
        // SMAppService provides the source of truth for the login item status.
        return SMAppService.mainApp.status == .enabled
    }
    
    // MARK: - Legacy Cleanup
    
    private static func removeLegacyPlist() {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
        
        if FileManager.default.fileExists(atPath: plistPath.path) {
            do {
                try FileManager.default.removeItem(at: plistPath)
                logger.info("Removed legacy LaunchAgent plist to migrate to SMAppService.")
            } catch {
                logger.error("Failed to remove legacy LaunchAgent plist: \(error.localizedDescription)")
            }
        }
    }
}
