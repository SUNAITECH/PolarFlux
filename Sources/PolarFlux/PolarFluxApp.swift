import SwiftUI

@main
struct PolarFluxApp: App {
    @StateObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    init() {
        // Essential patch: Pre-load language before any localization-dependent UI is initialized.
        // This ensures the whole app process (including MenuBar and Window titles) honors the choice.
        if let lang = UserDefaults.standard.string(forKey: "appLanguage") {
            if lang == "System" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([lang], forKey: "AppleLanguages")
            }
        }
        _appState = StateObject(wrappedValue: AppState())
    }
    
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
