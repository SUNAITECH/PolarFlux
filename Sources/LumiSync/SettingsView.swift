import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selection: String? = "Connection"
    @State private var isCalibrationLocked: Bool = true
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: "Connection") {
                    Label("Connection", systemImage: "cable.connector")
                }
                NavigationLink(value: "LED Layout") {
                    Label("LED Layout", systemImage: "lightbulb.led")
                }
                NavigationLink(value: "Audio") {
                    Label("Audio", systemImage: "waveform")
                }
                NavigationLink(value: "Calibration") {
                    Label("Calibration", systemImage: "slider.horizontal.3")
                }
                NavigationLink(value: "Power") {
                    Label("Power", systemImage: "bolt.shield")
                }
                NavigationLink(value: "General") {
                    Label("General", systemImage: "gear")
                }
                NavigationLink(value: "About") {
                    Label("About", systemImage: "info.circle")
                }
            }
            .listStyle(SidebarListStyle())
            .navigationTitle("Settings")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let selection = selection {
                        switch selection {
                        case "Connection": connectionSettings
                        case "LED Layout": ledSettings
                        case "Audio": audioSettings
                        case "Calibration": calibrationSettings
                        case "Power": powerSettings
                        case "General": generalSettings
                        case "About": AboutView()
                        default: Text("Select a category")
                        }
                    } else {
                        Text("Select a category")
                    }
                }
                .padding(30)
                .frame(maxWidth: 600, alignment: .leading)
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 800, minHeight: 600)
    }
    
    var audioSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Music Mode Settings").font(.title2).bold()
            
            Form {
                Picker("Microphone:", selection: $appState.selectedMicrophoneUID) {
                    ForEach(appState.availableMicrophones, id: \.uid) { mic in
                        Text(mic.name).tag(mic.uid)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                
                Button("Refresh Microphones") {
                    appState.refreshMicrophones()
                }
            }
        }
    }
    
    var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connection").font(.title2).bold()
            
            Form {
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
            }
        }
    }
    
    var ledSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("LED Layout").font(.title2).bold()
            
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
                
                Button(action: {
                    appState.startOrientationTest()
                }) {
                    HStack {
                        Image(systemName: "play.circle")
                        Text("Run Orientation Test (Snake)")
                    }
                }
            }
            
            Section(header: Text("Capture Settings").font(.headline)) {
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
                    .onChange(of: appState.perspectiveOriginMode) { newMode, _ in
                        if appState.currentMode == .sync && appState.isRunning {
                            appState.restartSync()
                        }
                    }

                    Text("Auto centers the origin when all sides have LEDs or snaps to the golden-ratio point closest to the missing side.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    OriginPreview(appState: appState)
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
    }
    
    var powerSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Power Safety").font(.title2).bold()
            
            Form {
                Picker("Safety Mode:", selection: $appState.powerMode) {
                    Text("Smart Protection").tag(PowerMode.abl)
                    Text("Safe Mode").tag(PowerMode.globalCap)
                    Text("Auto-Recovery").tag(PowerMode.smartFallback)
                }
                .pickerStyle(RadioGroupPickerStyle())
                
                Divider()
                
                if appState.powerMode == .abl {
                    VStack(alignment: .leading) {
                        Text("Protection Level: \(Int(appState.powerLimit * 100))%")
                        Slider(value: $appState.powerLimit, in: 0.5...1.0, step: 0.05)
                    }
                } else if appState.powerMode == .globalCap {
                    VStack(alignment: .leading) {
                        Text("Max Brightness Limit: \(Int(appState.powerLimit * 100))%")
                        Slider(value: $appState.powerLimit, in: 0.1...1.0, step: 0.05)
                    }
                }
            }
        }
    }
    
    var calibrationSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Calibration").font(.title2).bold()
                Spacer()
                Button(action: {
                    isCalibrationLocked.toggle()
                }) {
                    Image(systemName: isCalibrationLocked ? "lock.fill" : "lock.open.fill")
                        .foregroundColor(isCalibrationLocked ? .secondary : .blue)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            Form {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text("Red Gain").frame(width: 80, alignment: .leading)
                        Slider(value: $appState.calibrationR, in: 0.0...1.0).disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.calibrationR)).frame(width: 40)
                    }
                    HStack {
                        Text("Green Gain").frame(width: 80, alignment: .leading)
                        Slider(value: $appState.calibrationG, in: 0.0...1.0).disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.calibrationG)).frame(width: 40)
                    }
                    HStack {
                        Text("Blue Gain").frame(width: 80, alignment: .leading)
                        Slider(value: $appState.calibrationB, in: 0.0...1.0).disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.calibrationB)).frame(width: 40)
                    }
                    
                    Divider()
                    
                    HStack {
                        Text("Gamma").frame(width: 80, alignment: .leading)
                        Slider(value: $appState.gamma, in: 0.1...3.0).disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.gamma)).frame(width: 40)
                    }
                    HStack {
                        Text("Saturation").frame(width: 80, alignment: .leading)
                        Slider(value: $appState.saturation, in: 0.0...3.0).disabled(isCalibrationLocked)
                        Text(String(format: "%.2f", appState.saturation)).frame(width: 40)
                    }
                    
                    Button("Reset Calibration") {
                        appState.calibrationR = 1.0
                        appState.calibrationG = 1.0
                        appState.calibrationB = 1.0
                        appState.gamma = 1.0
                        appState.saturation = 1.0
                    }
                    .disabled(isCalibrationLocked)
                }
            }
        }
    }
    
    var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General").font(.title2).bold()
            
            Form {
                Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                
                Divider().padding(.vertical, 10)
                
                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack {
                        Image(systemName: "power")
                        Text("Quit LumiSync")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
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
    @ObservedObject var appState: AppState

    private let goldenGuide: [Double] = [0.382, 0.618]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = max(geo.size.height, 1.0)
            let centerX = width / 2
            let currentOrigin = appState.currentOriginY
            let originY = currentOrigin * height

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.05)))

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
                    .shadow(radius: 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Origin")
                        .font(.caption).bold()
                    Text("Position: \(Int(currentOrigin * 100))%")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }
            .contentShape(Rectangle())
            .gesture(appState.perspectiveOriginMode == .manual ? DragGesture(minimumDistance: 0).onChanged { value in
                let normalized = min(max(value.location.y / height, 0.0), 1.0)
                appState.manualOriginPosition = normalized
            } : nil)
        }
    }
}
