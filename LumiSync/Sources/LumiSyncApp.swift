import SwiftUI

@main
struct LumiSyncApp: App {
    @StateObject var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 300, minHeight: 400)
        }
        
        Settings {
            SettingsView(appState: appState)
        }
    }
}
