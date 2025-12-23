import SwiftUI

struct ZoneSettingsView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 20) {
            // Text Description of Sampling Area
            VStack(spacing: 8) {
                Text("Sampling Configuration")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Text("Capturing \(appState.depth)px depth from edges")
                    .font(.caption)
                
                HStack(spacing: 16) {
                    VStack {
                        Text("Top")
                            .fontWeight(.bold)
                        Text("\(appState.topZone) LEDs")
                    }
                    VStack {
                        Text("Bottom")
                            .fontWeight(.bold)
                        Text("\(appState.bottomZone) LEDs")
                    }
                    VStack {
                        Text("Left")
                            .fontWeight(.bold)
                        Text("\(appState.leftZone) LEDs")
                    }
                    VStack {
                        Text("Right")
                            .fontWeight(.bold)
                        Text("\(appState.rightZone) LEDs")
                    }
                }
                .font(.caption)
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            .padding(.vertical, 5)
            
            // Inputs
            HStack(spacing: 10) {
                // Left Input
                VStack {
                    Text("L")
                        .font(.caption)
                        .fontWeight(.bold)
                    TextField("0", text: $appState.leftZone)
                        .frame(width: 40)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .multilineTextAlignment(.center)
                        .onChange(of: appState.leftZone) { _ in appState.restartSync() }
                }
                
                VStack(spacing: 10) {
                    // Top Input
                    HStack {
                        Text("Top")
                            .font(.caption)
                            .fontWeight(.bold)
                        TextField("0", text: $appState.topZone)
                            .frame(width: 50)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .multilineTextAlignment(.center)
                            .onChange(of: appState.topZone) { _ in appState.restartSync() }
                    }
                    
                    // Bottom Input
                    HStack {
                        Text("Bottom")
                            .font(.caption)
                            .fontWeight(.bold)
                        TextField("0", text: $appState.bottomZone)
                            .frame(width: 50)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .multilineTextAlignment(.center)
                            .onChange(of: appState.bottomZone) { _ in appState.restartSync() }
                    }
                }
                
                // Right Input
                VStack {
                    Text("R")
                        .font(.caption)
                        .fontWeight(.bold)
                    TextField("0", text: $appState.rightZone)
                        .frame(width: 40)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .multilineTextAlignment(.center)
                        .onChange(of: appState.rightZone) { _ in appState.restartSync() }
                }
            }
            .padding(.vertical, 10)
            
            Divider()
            
            // Advanced Settings
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Sync Mode")
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
                
                HStack {
                    Text("Capture Depth")
                    Spacer()
                    TextField("Depth", text: $appState.depth)
                        .frame(width: 50)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .multilineTextAlignment(.trailing)
                        .onChange(of: appState.depth) { _ in appState.restartSync() }
                    Text("px")
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Search Depth")
                        Spacer()
                        Text("\(Int(appState.searchDepth * 100))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $appState.searchDepth, in: 0.0...0.5) { _ in
                        appState.restartSync()
                    }
                    .accentColor(.purple)
                    Text("Scans inwards to find vibrant colors")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
}
