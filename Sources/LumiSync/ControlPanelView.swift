import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LumiSync")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(appState.statusMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "settings")
                    }) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                    
                    Button(action: {
                        NSApplication.shared.terminate(nil)
                    }) {
                        Image(systemName: "power")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Quit")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            VStack(spacing: 20) {
                // Mode Selection (Compact & Rounded)
                HStack(spacing: 10) {
                    ModeIconButton(mode: .sync, currentMode: $appState.currentMode, icon: "sparkles.tv")
                    ModeIconButton(mode: .music, currentMode: $appState.currentMode, icon: "waveform.and.mic")
                    ModeIconButton(mode: .effect, currentMode: $appState.currentMode, icon: "wand.and.stars")
                    ModeIconButton(mode: .manual, currentMode: $appState.currentMode, icon: "hand.tap")
                }
                .padding(.top, 12)
                
                // Brightness Control
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: appState.currentMode == .sync ? "sparkles" : "sun.max.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("Brightness")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int((appState.currentMode == .sync ? appState.syncBrightness : appState.brightness) * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    if appState.currentMode == .sync {
                        Slider(value: $appState.syncBrightness, in: 0.1...2.5, step: 0.1) { _ in
                            appState.restartSync()
                        }
                        .accentColor(.purple)
                    } else {
                        Slider(value: $appState.brightness, in: 0.1...1.0, step: 0.05) { _ in
                            appState.restartSync()
                        }
                        .accentColor(appState.isPowerLimited ? .orange : .blue)
                    }
                }
                .padding(.horizontal, 16)
                
                // Mode Specific Quick Controls
                VStack(spacing: 0) {
                    if appState.currentMode == .effect {
                        VStack(spacing: 12) {
                            HStack {
                                Picker("", selection: $appState.selectedEffect) {
                                    ForEach(EffectType.allCases) { effect in
                                        Text(effect.rawValue).tag(effect)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .onChange(of: appState.selectedEffect) { newEffect, oldEffect in
                                    if appState.isRunning { appState.restartEffect() }
                                }
                                
                                if appState.selectedEffect == .breathing || appState.selectedEffect == .marquee {
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
                            
                            // Speed Control for Effects
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "gauge.with.needle")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text("Effect Speed")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                
                                Slider(value: Binding(
                                    get: { appState.effectSpeeds[appState.selectedEffect] ?? 1.0 },
                                    set: { 
                                        appState.effectSpeeds[appState.selectedEffect] = $0
                                        if appState.isRunning { appState.restartEffect() }
                                    }
                                ), in: 0.1...3.0)
                                .accentColor(.orange)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if appState.currentMode == .manual {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Color")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                ColorPicker("", selection: Binding(
                                    get: { appState.manualColor },
                                    set: { appState.setManualColor(color: $0) }
                                ))
                                .labelsHidden()
                            }
                            
                            VStack(spacing: 4) {
                                rgbSlider(label: "R", value: $appState.manualR, color: .red)
                                rgbSlider(label: "G", value: $appState.manualG, color: .green)
                                rgbSlider(label: "B", value: $appState.manualB, color: .blue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                        .transition(.opacity)
                    }
                }
                .clipped()
                
                // Main Action Button
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        appState.toggleRun()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: appState.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text(appState.isRunning ? "STOP SYNC" : "START SYNC")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        ZStack {
                            if appState.isRunning {
                                Color.red.opacity(0.8)
                            } else {
                                Color.blue.opacity(0.8)
                            }
                        }
                    )
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: (appState.isRunning ? Color.red : Color.blue).opacity(0.3), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                
                if appState.isPowerLimited {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text(appState.limitReason)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
            }
            .padding(.bottom, 20)
        }
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.currentMode)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.isRunning)
        .onChange(of: appState.currentMode) { newMode, _ in
            if appState.isRunning {
                appState.start() // Now handles mode switching internally in AppState
            }
        }
        .onDisappear {
            appState.saveSettings()
        }
    }
    
    private func rgbSlider(label: String, value: Binding<Double>, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 12)
            
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { 
                    value.wrappedValue = $0
                    appState.updateManualColorFromRGB()
                }
            ), in: 0...255, step: 1)
            .accentColor(color)
            
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 25, alignment: .trailing)
        }
    }
}

struct ModeIconButton: View {
    let mode: LightingMode
    @Binding var currentMode: LightingMode
    let icon: String
    
    var body: some View {
        Button(action: {
            withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.6)) {
                currentMode = mode
            }
        }) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: currentMode == mode ? .bold : .medium))
                Text(mode.rawValue.components(separatedBy: " ").first ?? "")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
            .frame(width: 62, height: 54)
            .background(
                ZStack {
                    if currentMode == mode {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    }
                }
            )
            .foregroundColor(currentMode == mode ? .accentColor : .secondary)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
