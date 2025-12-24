import SwiftUI

struct ZoneSettingsView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 16) {
            // Status Summary
            HStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Active Zones")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(appState.topZone)T \(appState.bottomZone)B \(appState.leftZone)L \(appState.rightZone)R")
                        .font(.system(.body, design: .monospaced))
                }
                
                Divider().frame(height: 30)
                
                VStack(alignment: .leading) {
                    Text("Depth")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(appState.depth)px")
                        .font(.system(.body, design: .monospaced))
                }
                
                Spacer()
                
                NavigationLink(destination: SettingsView(appState: appState)) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(12)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
            
            // Sync Mode Picker (Still useful to have quick access)
            HStack {
                Text("Sync Mode")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $appState.syncMode) {
                    ForEach(SyncMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(width: 140)
                .onChange(of: appState.syncMode) { _ in appState.restartSync() }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
}
