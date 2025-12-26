import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var isCalibrationLocked: Bool = true
    
    var body: some View {
        TabView {
            connectionSettings
                .tabItem {
                    Label("Connection", systemImage: "cable.connector")
                }
            
            ledSettings
                .tabItem {
                    Label("LED Layout", systemImage: "lightbulb.led")
                }
            
            audioSettings
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                }
            
            calibrationSettings
                .tabItem {
                    Label("Calibration", systemImage: "slider.horizontal.3")
                }
            
            powerSettings
                .tabItem {
                    Label("Power", systemImage: "bolt.shield")
                }
            
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
    .frame(minWidth: 540, minHeight: 640)
        .padding()
    }
    
    var audioSettings: some View {
        Form {
            Section(header: Text("Music Mode Settings").font(.headline)) {
                Picker("Microphone:", selection: $appState.selectedMicrophoneUID) {
                    ForEach(appState.availableMicrophones, id: \.uid) { mic in
                        Text(mic.name).tag(mic.uid)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                
                Button("Refresh Microphones") {
                    appState.refreshMicrophones()
                }
                .padding(.top, 10)
            }
        }
        .padding()
    }
    
    var connectionSettings: some View {
        Form {
            Section {
                Picker("Serial Port:", selection: $appState.selectedPort) {
                    if appState.availablePorts.isEmpty {
                        Text("No ports found").tag("")
                    } else {
                        ForEach(appState.availablePorts, id: \.self) { port in
                            Text(port).tag(port)
                        }
                    }
                }
                .pickerStyle(MenuPickerStyle())
                
                Picker("Baud Rate:", selection: $appState.baudRate) {
                    ForEach(appState.availableBaudRates, id: \.self) { rate in
                        Text(rate).tag(rate)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                
                Button("Refresh Ports") {
                    appState.refreshPorts()
                }
                .padding(.top, 10)
            }
        }
        .padding()
    }
    
    var ledSettings: some View {
        Form {
            Section(header: Text("Zone Configuration").font(.headline)) {
                VStack(spacing: 12) {
                    HStack {
                        settingsRow(label: "Total LEDs:", text: $appState.ledCount)
                        Button("Auto Detect") {
                            appState.autoDetectDevice()
                        }
                    }
                    Divider()
                    settingsRow(label: "Top Zone:", text: $appState.topZone)
                    settingsRow(label: "Bottom Zone:", text: $appState.bottomZone)
                    settingsRow(label: "Left Zone:", text: $appState.leftZone)
                    settingsRow(label: "Right Zone:", text: $appState.rightZone)
                }
            }
            
            Section(header: Text("Screen Sync Orientation").font(.headline)) {
                Picker("Direction:", selection: $appState.screenOrientation) {
                    Text("Standard (CW)").tag(ScreenOrientation.standard)
                    Text("Reverse (CCW)").tag(ScreenOrientation.reverse)
                }
                .pickerStyle(MenuPickerStyle())
                
                Text("Standard: Bottom-Left -> Top -> Right -> Bottom")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("Reverse: Bottom-Right -> Top -> Left -> Bottom")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button(action: {
                    appState.startOrientationTest()
                }) {
                    HStack {
                        Image(systemName: "play.circle")
                        Text("Run Orientation Test (Snake)")
                    }
                }
                
                if appState.isRunning && appState.statusMessage.contains("Testing") {
                    Text("A white light should move in the direction of your setup.")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            
            Section(header: Text("Capture Settings").font(.headline)) {
                Picker("Sync Mode:", selection: $appState.syncMode) {
                    ForEach(SyncMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .onChange(of: appState.syncMode) { _ in appState.restartSync() }
                
                Divider()
                
                settingsRow(label: "Capture Depth:", text: $appState.depth)
                
                Divider()
                
                VStack(alignment: .leading) {
                    HStack {
                        Text("Target FPS:")
                        Spacer()
                        Text("\(Int(appState.targetFrameRate))")
                            .monospacedDigit()
                    }
                    Slider(value: $appState.targetFrameRate, in: 15...120, step: 5) { _ in
                        if appState.isRunning && appState.currentMode == .sync {
                            appState.restartSync()
                        }
                    }
                }
            }

            Section(header: Text("Perspective Origin").font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Origin Mode:", selection: $appState.perspectiveOriginMode) {
                        ForEach(PerspectiveOriginMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: appState.perspectiveOriginMode) { _ in
                        if appState.currentMode == .sync && appState.isRunning {
                            appState.restartSync()
                        }
                    }

                    Text("Auto centers the origin when all sides have LEDs or snaps to the golden-ratio point closest to the missing side.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    OriginPreview(originPosition: $appState.manualOriginPosition, mode: appState.perspectiveOriginMode)
                        .frame(height: 140)
                        .padding(.vertical, 4)

                    if appState.perspectiveOriginMode == .manual {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Manual Position: \(Int(appState.manualOriginPosition * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Slider(value: $appState.manualOriginPosition, in: 0...1, step: 0.01) { editing in
                                if !editing && appState.currentMode == .sync && appState.isRunning {
                                    appState.restartSync()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }
    
    var powerSettings: some View {
        Form {
            Section(header: Text("Power Safety").font(.headline)) {
                Text("Prevents the lights from turning off unexpectedly when displaying bright colors.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 5)
                
                Picker("Safety Mode:", selection: $appState.powerMode) {
                    Text("Smart Protection (Recommended)").tag(PowerMode.abl)
                    Text("Safe Mode (Always Limit)").tag(PowerMode.globalCap)
                    Text("Auto-Recovery").tag(PowerMode.smartFallback)
                }
                .pickerStyle(RadioGroupPickerStyle())
                
                Divider()
                
                if appState.powerMode == .abl {
                    VStack(alignment: .leading) {
                        Text("Protection Level: \(Int(appState.powerLimit * 100))%")
                        Slider(value: $appState.powerLimit, in: 0.5...1.0, step: 0.05)
                        Text("Automatically dims the lights ONLY when they are too bright for your power supply. Most colors will remain at full brightness.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if appState.powerMode == .globalCap {
                    VStack(alignment: .leading) {
                        Text("Max Brightness Limit: \(Int(appState.powerLimit * 100))%")
                        Slider(value: $appState.powerLimit, in: 0.1...1.0, step: 0.05)
                        Text("Permanently limits the maximum brightness to this level.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if appState.powerMode == .smartFallback {
                    Text("If the lights turn off, the app will automatically restart them at a lower brightness.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
    
    var calibrationSettings: some View {
        Form {
            Section(header: HStack {
                Text("White Balance Calibration").font(.headline)
                Spacer()
                Button(action: {
                    isCalibrationLocked.toggle()
                }) {
                    Image(systemName: isCalibrationLocked ? "lock.fill" : "lock.open.fill")
                        .foregroundColor(isCalibrationLocked ? .secondary : .blue)
                }
                .buttonStyle(PlainButtonStyle())
                .help(isCalibrationLocked ? "Unlock to edit" : "Lock to prevent changes")
            }) {
                Text("Adjust these sliders if your white looks blue or red.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading) {
                    HStack {
                        Text("Red Gain")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $appState.calibrationR, in: 0.0...1.0)
                            .disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.calibrationR))
                            .frame(width: 40)
                    }
                    
                    HStack {
                        Text("Green Gain")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $appState.calibrationG, in: 0.0...1.0)
                            .disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.calibrationG))
                            .frame(width: 40)
                    }
                    
                    HStack {
                        Text("Blue Gain")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $appState.calibrationB, in: 0.0...1.0)
                            .disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.calibrationB))
                            .frame(width: 40)
                    }
                    
                    Divider().padding(.vertical)
                    
                    HStack {
                        Text("Gamma")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $appState.gamma, in: 0.1...3.0)
                            .disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.gamma))
                            .frame(width: 40)
                    }
                    Text("Controls brightness curve. Higher values (e.g. 2.2) are more accurate for LEDs.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("Saturation")
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $appState.saturation, in: 0.0...3.0)
                            .disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.saturation))
                            .frame(width: 40)
                    }
                    Text("Boosts color vibrancy. > 1.0 increases saturation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Divider().padding(.vertical)
                    
                    Toggle("Use Dominant Color Saliency", isOn: $appState.useDominantColor)
                        .disabled(isCalibrationLocked)
                    Text("When enabled, the engine prioritizes the most 'important' colors in each zone rather than a simple average.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("Reset Calibration") {
                        appState.calibrationR = 1.0
                        appState.calibrationG = 1.0
                        appState.calibrationB = 1.0
                        appState.gamma = 1.0
                        appState.saturation = 1.0
                    }
                    .padding(.top)
                    .disabled(isCalibrationLocked)
                }
            }
        }
        .padding()
    }
    
    var generalSettings: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                    .toggleStyle(CheckboxToggleStyle())
                
                Divider().padding(.vertical, 8)
                
                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack {
                        Image(systemName: "power")
                        Text("Quit LumiSync")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding()
    }
    
    func settingsRow(label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
        }
    }
}

struct OriginPreview: View {
    @Binding var originPosition: Double
    var mode: PerspectiveOriginMode

    private let goldenGuide: [Double] = [0.382, 0.618]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = max(geo.size.height, 1.0)
            let centerX = width / 2
            let clampedOrigin = min(max(originPosition, 0.0), 1.0)
            let originY = clampedOrigin * height

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)

                // Vertical center line
                Path { path in
                    path.move(to: CGPoint(x: centerX, y: 0))
                    path.addLine(to: CGPoint(x: centerX, y: height))
                }
                .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))

                // Golden ratio guide lines
                ForEach(goldenGuide, id: \.self) { point in
                    Path { path in
                        let y = CGFloat(point) * height
                        path.move(to: CGPoint(x: centerX - 12, y: y))
                        path.addLine(to: CGPoint(x: centerX + 12, y: y))
                    }
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                }

                // Origin indicator
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .position(x: centerX, y: originY)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Origin")
                        .font(.caption)
                        .foregroundColor(.primary)
                    Text("Position: \(Int(clampedOrigin * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }
            .contentShape(Rectangle())
                .gesture(mode == .manual ? DragGesture(minimumDistance: 0).onChanged { value in
                    let normalized = min(max(value.location.y / height, 0.0), 1.0)
                    originPosition = normalized
                } : nil)
        }
    }
}
