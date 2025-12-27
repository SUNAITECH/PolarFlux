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
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            ZStack {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
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
                                .font(.title)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 30)
                    .frame(maxWidth: 650, alignment: .leading)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 650)
    }
    
    var audioSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            headerView(title: "Audio Input", subtitle: "Configure microphone for Music Mode", icon: "waveform")
            
            GroupBox {
                VStack(alignment: .leading, spacing: 15) {
                    Picker("Microphone:", selection: $appState.selectedMicrophoneUID) {
                        ForEach(appState.availableMicrophones, id: \.uid) { mic in
                            Text(mic.name).tag(mic.uid)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Button(action: { appState.refreshMicrophones() }) {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
            }
        }
    }
    
    var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            headerView(title: "Connection", subtitle: "Serial port and communication settings", icon: "cable.connector")
            
            GroupBox {
                VStack(alignment: .leading, spacing: 15) {
                    Picker("Serial Port:", selection: $appState.selectedPort) {
                        if appState.availablePorts.isEmpty {
                            Text("No ports found").tag("")
                        } else {
                            ForEach(appState.availablePorts, id: \.self) { port in
                                Text(port).tag(port)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Picker("Baud Rate:", selection: $appState.baudRate) {
                        ForEach(appState.availableBaudRates, id: \.self) { rate in
                            Text(rate).tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Button(action: { appState.refreshPorts() }) {
                        Label("Refresh Ports", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
            }
        }
    }
    
    var ledSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            headerView(title: "LED Layout", subtitle: "Configure your LED strip zones", icon: "lightbulb.led")
            
            GroupBox("Zone Configuration") {
                VStack(spacing: 12) {
                    HStack {
                        settingsRow(label: "Total LEDs:", text: $appState.ledCount)
                        Button("Auto Detect") {
                            appState.autoDetectDevice()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Divider().padding(.vertical, 5)
                    settingsRow(label: "Top Zone:", text: $appState.topZone)
                    settingsRow(label: "Bottom Zone:", text: $appState.bottomZone)
                    settingsRow(label: "Left Zone:", text: $appState.leftZone)
                    settingsRow(label: "Right Zone:", text: $appState.rightZone)
                }
                .padding(10)
            }
            
            GroupBox("Screen Sync Orientation") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Direction:", selection: $appState.screenOrientation) {
                        Text("Standard (CW)").tag(ScreenOrientation.standard)
                        Text("Reverse (CCW)").tag(ScreenOrientation.reverse)
                    }
                    .pickerStyle(.segmented)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.screenOrientation == .standard ? 
                             "Standard: Bottom-Left → Top → Right → Bottom" : 
                             "Reverse: Bottom-Right → Top → Left → Bottom")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("The test will run a 'snake' light effect twice. Ensure the light starts from the bottom corner and moves along the strip in the correct direction.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .italic()
                    }
                    
                    Button(action: { appState.startOrientationTest() }) {
                        Label("Run Orientation Test", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
            }
            
            GroupBox("Capture Settings") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Target FPS")
                        Spacer()
                        Text("\(Int(appState.targetFrameRate))")
                            .monospacedDigit()
                            .bold()
                    }
                    Slider(value: $appState.targetFrameRate, in: 15...120, step: 5) { _ in
                        if appState.isRunning && appState.currentMode == .sync {
                            appState.restartSync()
                        }
                    }
                }
                .padding(10)
            }

            GroupBox("Perspective Origin") {
                VStack(alignment: .leading, spacing: 15) {
                    Picker("Origin Mode:", selection: $appState.perspectiveOriginMode) {
                        ForEach(PerspectiveOriginMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appState.perspectiveOriginMode) { newMode, _ in
                        if appState.currentMode == .sync && appState.isRunning {
                            appState.restartSync()
                        }
                    }

                    Text("Auto centers the origin when all sides have LEDs or snaps to the golden-ratio point closest to the missing side.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    OriginPreview(appState: appState)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))

                    if appState.perspectiveOriginMode == .manual {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Manual Position")
                                Spacer()
                                Text("\(Int(appState.manualOriginPosition * 100))%")
                                    .monospacedDigit()
                            }
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
                .padding(10)
            }
        }
    }
    
    var powerSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            headerView(title: "Power Safety", subtitle: "Protect your hardware and power supply", icon: "bolt.shield")
            
            GroupBox {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Safety Mode:", selection: $appState.powerMode) {
                        Text("Smart Protection").tag(PowerMode.abl)
                        Text("Safe Mode").tag(PowerMode.globalCap)
                        Text("Auto-Recovery").tag(PowerMode.smartFallback)
                    }
                    .pickerStyle(.radioGroup)
                    
                    Divider()
                    
                    if appState.powerMode == .abl {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Protection Level")
                                Spacer()
                                Text("\(Int(appState.powerLimit * 100))%")
                                    .bold()
                            }
                            Slider(value: $appState.powerLimit, in: 0.5...1.0, step: 0.05)
                        }
                    } else if appState.powerMode == .globalCap {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Max Brightness Limit")
                                Spacer()
                                Text("\(Int(appState.powerLimit * 100))%")
                                    .bold()
                            }
                            Slider(value: $appState.powerLimit, in: 0.1...1.0, step: 0.05)
                        }
                    }
                }
                .padding(10)
            }
        }
    }
    
    var calibrationSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack {
                headerView(title: "Calibration", subtitle: "Fine-tune color accuracy and gamma", icon: "slider.horizontal.3")
                Spacer()
                Button(action: { isCalibrationLocked.toggle() }) {
                    Image(systemName: isCalibrationLocked ? "lock.fill" : "lock.open.fill")
                        .foregroundColor(isCalibrationLocked ? .secondary : .blue)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            
            GroupBox {
                VStack(alignment: .leading, spacing: 15) {
                    calibrationRow(label: "Red Gain", value: $appState.calibrationR, color: .red)
                    calibrationRow(label: "Green Gain", value: $appState.calibrationG, color: .green)
                    calibrationRow(label: "Blue Gain", value: $appState.calibrationB, color: .blue)
                    
                    Divider().padding(.vertical, 5)
                    
                    calibrationRow(label: "Gamma", value: $appState.gamma, range: 0.1...3.0)
                    calibrationRow(label: "Saturation", value: $appState.saturation, range: 0.0...3.0)
                    
                    Button("Reset to Defaults") {
                        appState.calibrationR = 1.0
                        appState.calibrationG = 1.0
                        appState.calibrationB = 1.0
                        appState.gamma = 1.0
                        appState.saturation = 1.0
                    }
                    .disabled(isCalibrationLocked)
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .disabled(isCalibrationLocked)
            }
        }
    }
    
    var generalSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            headerView(title: "General", subtitle: "Application behavior and startup", icon: "gear")
            
            GroupBox {
                VStack(alignment: .leading, spacing: 20) {
                    Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                        .toggleStyle(.switch)
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label("Quit LumiSync", systemImage: "power")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(10)
            }
        }
    }
    
    func headerView(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.accentColor)
                .frame(width: 45)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2)
                    .bold()
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.bottom, 10)
    }
    
    func calibrationRow(label: String, value: Binding<Double>, color: Color? = nil, range: ClosedRange<Double> = 0.0...1.0) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            .font(.caption)
            
            Slider(value: value, in: range)
                .accentColor(color ?? .accentColor)
        }
    }
    
    func settingsRow(label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 100, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
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
