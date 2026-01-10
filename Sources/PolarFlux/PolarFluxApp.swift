import SwiftUI

@main
struct PolarFluxApp: App {
    @StateObject var appState = AppState()
    @Environment(\.openWindow) private var openWindow
    
    var body: some Scene {
        MenuBarExtra("PolarFlux", systemImage: appState.isRunning ? "sparkles" : "sparkles.tv") {
            ControlPanelView(appState: appState)
                .frame(width: 300)
                .environment(\.locale, appState.currentLocale)
        }
        .menuBarExtraStyle(.window)
        
        Window(String(localized: "SETTINGS"), id: "settings") {
            SettingsView(appState: appState)
                .frame(minWidth: 560, minHeight: 660)
                .environment(\.locale, appState.currentLocale)
        }
        
        Settings {
            SettingsView(appState: appState)
                .environment(\.locale, appState.currentLocale)
        }
    }
}
