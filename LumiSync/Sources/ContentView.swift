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
                            VStack(alignment: .leading, spacing: 10) {
                                Picker("Sync Area", selection: $appState.syncMode) {
                                    Text("Full Screen").tag(SyncMode.full)
                                    Text("Cinema (Bars)").tag(SyncMode.cinema)
                                    Text("Left Half").tag(SyncMode.left)
                                    Text("Right Half").tag(SyncMode.right)
                                }
                                .pickerStyle(MenuPickerStyle())
                                
                                Text("Configure orientation in Settings (⌘,)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if appState.currentMode == .music {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Microphone")
                                        .font(.subheadline)
                                    Spacer()
                                    Picker("", selection: $appState.selectedMicrophoneUID) {
                                        ForEach(appState.availableMicrophones, id: \.uid) { mic in
                                            Text(mic.name).tag(mic.uid)
                                        }
                                    }
                                    .pickerStyle(MenuPickerStyle())
                                    .frame(maxWidth: 200)
                                }
                                
                                Button(action: { appState.refreshMicrophones() }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help("Refresh Microphones")
                            }
                        } else if appState.currentMode == .effect {
                            VStack(alignment: .leading, spacing: 10) {
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
                                
                                Divider()
                                
                                HStack {
                                    Image(systemName: "tortoise.fill")
                                        .foregroundColor(.secondary)
                                    
                                    Slider(value: Binding(
                                        get: { appState.effectSpeeds[appState.selectedEffect] ?? 1.0 },
                                        set: { 
                                            appState.effectSpeeds[appState.selectedEffect] = $0
                                            if appState.isRunning { appState.restartEffect() }
                                        }
                                    ), in: 0.1...3.0)
                                    
                                    Image(systemName: "hare.fill")
                                        .foregroundColor(.secondary)
                                }
                                
                                if appState.selectedEffect == .breathing || appState.selectedEffect == .marquee {
                                    HStack {
                                        Text("Color")
                                            .font(.subheadline)
                                        Spacer()
                                        ColorPicker("", selection: Binding(
                                            get: { appState.effectColors[appState.selectedEffect] ?? .red },
                                            set: { 
                                                appState.effectColors[appState.selectedEffect] = $0
                                                if appState.isRunning { appState.restartEffect() }
                                            }
                                        ))
                                        .labelsHidden()
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    
                    // Brightness Control
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Brightness")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(appState.brightness * 100))%")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Image(systemName: "sun.min")
                                .foregroundColor(.secondary)
                            
                            // Custom Slider with Ticks
                            VStack(spacing: 4) {
                                Slider(value: $appState.brightness, in: 0.1...1.0, step: 0.05)
                                    .accentColor(appState.isPowerLimited ? .orange : .blue)
                            }
                            
                            Image(systemName: "sun.max")
                                .foregroundColor(.secondary)
                        }
                        
                        if appState.isPowerLimited {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(appState.limitReason)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            .padding(.top, 4)
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
                            Text("Manual Color")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            HStack(alignment: .center, spacing: 20) {
                                // Color Picker
                                VStack {
                                    ColorPicker("Pick a color", selection: Binding(
                                        get: { appState.manualColor },
                                        set: { appState.setManualColor(color: $0) }
                                    ))
                                    .labelsHidden()
                                    .scaleEffect(1.5)
                                    .padding()
                                }
                                .frame(width: 60)
                                
                                Divider()
                                    .frame(height: 80)
                                
                                // RGB Sliders
                                VStack(spacing: 8) {
                                    rgbSlider(label: "R", value: $appState.manualR, color: .red)
                                    rgbSlider(label: "G", value: $appState.manualG, color: .green)
                                    rgbSlider(label: "B", value: $appState.manualB, color: .blue)
                                }
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
    
    func rgbSlider(label: String, value: Binding<Double>, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(color)
                .frame(width: 15)
            
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { 
                    value.wrappedValue = $0
                    appState.updateManualColorFromRGB()
                }
            ), in: 0...255, step: 1)
            .accentColor(color)
            
            Text("\(Int(value.wrappedValue))")
                .font(.caption)
                .frame(width: 30, alignment: .trailing)
                .monospacedDigit()
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
