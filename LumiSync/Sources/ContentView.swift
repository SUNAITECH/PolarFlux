import SwiftUI
import Combine

struct ContentView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                }
                Text("LumiSync")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.1)))
            }
            .padding()
            .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
            
            Divider()
            
            ScrollView {
                VStack(spacing: 24) {
                    
                    // Mode Selection
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mode")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Picker("Mode", selection: $appState.currentMode) {
                            ForEach(LightingMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .onChange(of: appState.currentMode) { _ in
                            if appState.isRunning {
                                appState.stop()
                                appState.start()
                            }
                        }
                        
                        // Mode Specific Controls
                        if appState.currentMode == .sync {
                            Picker("Sync Area", selection: $appState.syncMode) {
                                Text("Full Screen").tag(SyncMode.full)
                                Text("Cinema (Bars)").tag(SyncMode.cinema)
                                Text("Left Half").tag(SyncMode.left)
                                Text("Right Half").tag(SyncMode.right)
                            }
                            .pickerStyle(MenuPickerStyle())
                        } else if appState.currentMode == .effect {
                            Picker("Effect", selection: $appState.selectedEffect) {
                                ForEach(EffectType.allCases) { effect in
                                    Text(effect.rawValue).tag(effect)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .onChange(of: appState.selectedEffect) { _ in
                                if appState.isRunning {
                                    appState.restartEffect()
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    
                    // Brightness Control
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Brightness")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Image(systemName: "sun.min")
                                .foregroundColor(.secondary)
                            Slider(value: $appState.brightness, in: 0.1...1.0)
                                .accentColor(.blue)
                            Image(systemName: "sun.max")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    
                    // Main Action Button
                    Button(action: appState.toggleRun) {
                        HStack {
                            Image(systemName: appState.isRunning ? "stop.fill" : "play.fill")
                            Text(appState.isRunning ? "Stop" : "Start")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .foregroundColor(.white)
                        .background(appState.isRunning ? Color.red.opacity(0.8) : Color.blue.opacity(0.8))
                        .cornerRadius(12)
                        .shadow(radius: 2)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Manual Colors (Only in Manual Mode)
                    if appState.currentMode == .manual {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Color Selection")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            HStack {
                                Spacer()
                                VStack {
                                    ColorPicker("Pick a color", selection: Binding(
                                        get: { appState.manualColor },
                                        set: { appState.setManualColor(color: $0) }
                                    ))
                                    .labelsHidden()
                                    .scaleEffect(1.5)
                                    .padding()
                                    
                                    Text("Click circle to choose color")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(12)
                    }
                    
                    Spacer()
                    
                    Text("Configure ports and LEDs in Settings (⌘,)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        .onDisappear {
            appState.saveSettings()
        }
    }
}

struct ColorButton: View {
    var color: Color
    var isSelected: Bool
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 40, height: 40)
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.primary : Color.clear, lineWidth: isSelected ? 3 : 0)
                )
                .shadow(radius: 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }
    
    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}
