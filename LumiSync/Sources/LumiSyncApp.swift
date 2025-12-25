import SwiftUI

@main
struct LumiSyncApp: App {
    @StateObject var appState = AppState()
    @Environment(\.openWindow) private var openWindow
    
    var body: some Scene {
        MenuBarExtra("LumiSync", systemImage: appState.isRunning ? "sparkles" : "sparkles.tv") {
            ControlPanelView(appState: appState)
                .frame(width: 300)
        }
        .menuBarExtraStyle(.window)
        
        Window("Settings", id: "settings") {
            SettingsView(appState: appState)
                .frame(width: 500, height: 600)
        }
        
        Settings {
            SettingsView(appState: appState)
        }
    }
}
