import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selection: String? = "Connection"
    @State private var isCalibrationLocked: Bool = true
    @State private var initialLanguage: String?
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section(String(localized: "HARDWARE")) {
                    NavigationLink(value: "Connection") {
                        Label(String(localized: "CONNECTION"), systemImage: "cable.connector")
                    }
                    NavigationLink(value: "LED Layout") {
                        Label(String(localized: "LED_LAYOUT"), systemImage: "lightbulb.led")
                    }
                    NavigationLink(value: "SyncSettings") {
                        Label(String(localized: "SYNC_SETTINGS"), systemImage: "rectangle.inset.filled.and.person.filled")
                    }
                }
                
                Section(String(localized: "PROCESSING")) {
                    NavigationLink(value: "Audio") {
                        Label(String(localized: "AUDIO"), systemImage: "waveform")
                    }
                    NavigationLink(value: "Calibration") {
                        Label(String(localized: "CALIBRATION"), systemImage: "slider.horizontal.3")
                    }
                    NavigationLink(value: "Power") {
                        Label(String(localized: "POWER"), systemImage: "bolt.shield")
                    }
                    NavigationLink(value: "Performance") {
                        Label(String(localized: "PERFORMANCE_STATS"), systemImage: "gauge")
                    }
                }
                
                Section(String(localized: "APP")) {
                    NavigationLink(value: "General") {
                        Label(String(localized: "GENERAL"), systemImage: "gear")
                    }
                    NavigationLink(value: "About") {
                        Label(String(localized: "ABOUT"), systemImage: "info.circle")
                    }
                }
            }
            .listStyle(SidebarListStyle())
            .navigationTitle(String(localized: "SETTINGS"))
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
                            case "SyncSettings": syncSettings
                            case "Audio": audioSettings
                            case "Calibration": calibrationSettings
                            case "Power": powerSettings
                            case "Performance": performanceSettings
                            case "General": generalSettings
                            case "About": AboutView()
                            default: Text(String(localized: "SELECT_CATEGORY"))
                            }
                        } else {
                            Text(String(localized: "SELECT_CATEGORY"))
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
        .onAppear {
            if initialLanguage == nil {
                initialLanguage = appState.appLanguage
            }
        }
    }
    
    var audioSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            headerView(title: String(localized: "AUDIO"), subtitle: String(localized: "AUDIO_SUBTITLE"), icon: "waveform")
            
            GroupBox {
                VStack(alignment: .leading, spacing: 15) {
                    Picker(String(localized: "MICROPHONE"), selection: $appState.selectedMicrophoneUID) {
                        ForEach(appState.availableMicrophones, id: \.uid) { mic in
                            Text(mic.name).tag(mic.uid)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Button(action: { appState.refreshMicrophones() }) {
                        Label(String(localized: "REFRESH_PORTS"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
            }
        }
    }
    
    var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            headerView(title: String(localized: "CONNECTION"), subtitle: String(localized: "CONNECTION_SUBTITLE"), icon: "cable.connector")
            
            GroupBox {
                VStack(alignment: .leading, spacing: 15) {
                    Picker(String(localized: "SERIAL_PORT"), selection: $appState.selectedPort) {
                        if appState.availablePorts.isEmpty {
                            Text(String(localized: "NO_PORTS_FOUND")).tag("")
                        } else {
                            ForEach(appState.availablePorts, id: \.self) { port in
                                Text(port).tag(port)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Picker(String(localized: "BAUD_RATE"), selection: $appState.baudRate) {
                        ForEach(appState.availableBaudRates, id: \.self) { rate in
                            Text(rate).tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Button(action: { appState.refreshPorts() }) {
                        Label(String(localized: "REFRESH_PORTS"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
            }
        }
    }
    
    var ledSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            headerView(title: String(localized: "LED_LAYOUT"), subtitle: String(localized: "LED_LAYOUT_SUBTITLE"), icon: "lightbulb.led")
            
            GroupBox(String(localized: "ZONE_CONFIG")) {
                VStack(spacing: 12) {
                    HStack {
                        settingsRow(label: String(localized: "TOTAL_LEDS"), text: $appState.ledCount)
                        Button(String(localized: "AUTO_DETECT")) {
                            appState.autoDetectDevice()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Divider().padding(.vertical, 5)
                    settingsRow(label: String(localized: "TOP_ZONE"), text: $appState.topZone)
                    settingsRow(label: String(localized: "BOTTOM_ZONE"), text: $appState.bottomZone)
                    settingsRow(label: String(localized: "LEFT_ZONE"), text: $appState.leftZone)
                    settingsRow(label: String(localized: "RIGHT_ZONE"), text: $appState.rightZone)
                }
                .padding(10)
            }
        }
    }

    var syncSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            headerView(title: String(localized: "SYNC_SETTINGS"), subtitle: String(localized: "SYNC_SETTINGS_SUBTITLE"), icon: "rectangle.inset.filled.and.person.filled")

            GroupBox(String(localized: "SCREEN_SYNC_ORIENTATION")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(String(localized: "DIRECTION"), selection: $appState.screenOrientation) {
                        Text(String(localized: "STANDARD_CW")).tag(ScreenOrientation.standard)
                        Text(String(localized: "REVERSE_CCW")).tag(ScreenOrientation.reverse)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appState.screenOrientation) { _, _ in
                        if appState.isTestingOrientation {
                            appState.isTestingOrientation = false
                        }
                        if appState.isRunning && appState.currentMode == .sync {
                            appState.restartSync()
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.screenOrientation == .standard ? 
                             String(localized: "ORIENTATION_DESC_STANDARD") : 
                             String(localized: "ORIENTATION_DESC_REVERSE"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(String(localized: "ORIENTATION_TEST_NOTE"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .italic()
                    }
                    
                    Button(action: { appState.startOrientationTest() }) {
                        Label(String(localized: "RUN_ORIENTATION_TEST"), systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
            }
            
            GroupBox(String(localized: "CAPTURE_SETTINGS")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "TARGET_FPS"))
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

            GroupBox(String(localized: "PERSPECTIVE_ORIGIN")) {
                VStack(alignment: .leading, spacing: 15) {
                    Picker(String(localized: "ORIGIN_MODE"), selection: $appState.perspectiveOriginMode) {
                        ForEach(PerspectiveOriginMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appState.perspectiveOriginMode) { newMode, _ in
                        if appState.currentMode == .sync && appState.isRunning {
                            appState.restartSync()
                        }
                    }

                    Text(String(localized: "ORIGIN_DESC"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    OriginPreview(appState: appState)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))

                    if appState.perspectiveOriginMode == .manual {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(String(localized: "MANUAL_POSITION"))
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
            headerView(title: String(localized: "POWER_SAFETY"), subtitle: String(localized: "POWER_SAFETY_SUBTITLE"), icon: "bolt.shield")
            
            GroupBox {
                VStack(alignment: .leading, spacing: 20) {
                    Picker(String(localized: "SAFETY_MODE"), selection: $appState.powerMode) {
                        Text(String(localized: "SMART_PROTECTION")).tag(PowerMode.abl)
                        Text(String(localized: "SAFE_MODE")).tag(PowerMode.globalCap)
                        Text(String(localized: "AUTO_RECOVERY")).tag(PowerMode.smartFallback)
                    }
                    .pickerStyle(.radioGroup)
                    
                    Divider()
                    
                    if appState.powerMode == .abl {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(String(localized: "PROTECTION_LEVEL"))
                                Spacer()
                                Text("\(Int(appState.powerLimit * 100))%")
                                    .bold()
                            }
                            Slider(value: $appState.powerLimit, in: 0.5...1.0, step: 0.05)
                        }
                    } else if appState.powerMode == .globalCap {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(String(localized: "MAX_BRIGHTNESS_LIMIT"))
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
    
    var performanceSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            headerView(title: String(localized: "PERFORMANCE_STATS"), subtitle: String(localized: "SERIAL_TELEMETRY_DESC"), icon: "gauge")
            
            GroupBox(String(localized: "SERIAL_TELEMETRY")) {
                VStack(spacing: 12) {
                    HStack {
                        Text(String(localized: "DATA_RATE"))
                        Spacer()
                        Text(String(format: "%.2f KB/s", appState.performanceMetrics.dataRate))
                            .monospacedDigit()
                            .bold()
                    }
                    HStack {
                        Text(String(localized: "PACKETS_PER_SEC"))
                        Spacer()
                        Text(String(format: "%.1f PPS", appState.performanceMetrics.pps))
                            .monospacedDigit()
                    }
                    HStack {
                        Text(String(localized: "WRITE_LATENCY"))
                        Spacer()
                        Text(String(format: "%.3f ms", appState.performanceMetrics.serialLatency))
                            .monospacedDigit()
                            .foregroundColor(appState.performanceMetrics.serialLatency > 5.0 ? .orange : .secondary)
                    }
                    HStack {
                        Text(String(localized: "BUFFER_SIZE"))
                        Spacer()
                        Text(String(format: "%d B", appState.performanceMetrics.bufferSize))
                            .monospacedDigit()
                            .foregroundColor(appState.performanceMetrics.bufferSize > 256 ? .orange : .secondary)
                    }
                    HStack {
                        Text(String(localized: "WRITE_ERRORS"))
                        Spacer()
                        Text("\(appState.performanceMetrics.writeErrors)")
                            .monospacedDigit()
                            .foregroundColor(appState.performanceMetrics.writeErrors > 0 ? .red : .secondary)
                    }
                    HStack {
                        Text(String(localized: "RECONNECT_COUNT"))
                        Spacer()
                        Text("\(appState.performanceMetrics.reconnects)")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text(String(localized: "TOTAL_PACKETS"))
                        Spacer()
                        Text("\(appState.performanceMetrics.totalPackets)")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    
                    Divider().padding(.vertical, 4)
                    
                    HStack {
                        let sinceDate = appState.lastResetTime ?? appState.appStartTime
                        Text("\(String(localized: "DATA_SINCE")) \(sinceDate.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))\(String(localized: "DATA_SINCE_SUFFIX", defaultValue: ""))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        Button(action: { appState.resetStatistics() }) {
                            Label(String(localized: "RESET_STATS"), systemImage: "arrow.counterclockwise")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding()
            }
            
            GroupBox(String(localized: "SYSTEM_RESOURCE")) {
                VStack(spacing: 12) {
                    HStack {
                        Text(String(localized: "RAM_USAGE"))
                        Spacer()
                        Text(String(format: "%.1f MB", appState.performanceMetrics.ramUsage))
                            .monospacedDigit()
                    }
                }
                .padding()
            }
            
            GroupBox(String(localized: "HEALTH_CHECK")) {
                VStack(spacing: 8) {
                    ForEach(appState.healthChecks) { check in
                        HStack {
                            Text(check.name)
                            Spacer()
                            Text(check.message)
                                .foregroundColor(check.status ? .green : .red)
                            Image(systemName: check.status ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(check.status ? .green : .red)
                        }
                    }
                }
                .padding()
            }
        }
    }

    var calibrationSettings: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack {
                headerView(title: String(localized: "CALIBRATION"), subtitle: String(localized: "CALIBRATION_SUBTITLE"), icon: "slider.horizontal.3")
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
                    calibrationRow(label: String(localized: "RED_GAIN"), value: $appState.calibrationR, color: .red)
                    calibrationRow(label: String(localized: "GREEN_GAIN"), value: $appState.calibrationG, color: .green)
                    calibrationRow(label: String(localized: "BLUE_GAIN"), value: $appState.calibrationB, color: .blue)
                    
                    Divider().padding(.vertical, 5)
                    
                    calibrationRow(label: String(localized: "GAMMA"), value: $appState.gamma, range: 0.1...3.0)
                    calibrationRow(label: String(localized: "SATURATION"), value: $appState.saturation, range: 0.0...3.0)
                    
                    Button(String(localized: "RESET_DEFAULTS")) {
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
            headerView(title: String(localized: "GENERAL"), subtitle: String(localized: "GENERAL_SUBTITLE"), icon: "gear")
            
            GroupBox {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(String(localized: "LANGUAGE"))
                        Spacer()
                        Picker("", selection: $appState.appLanguage) {
                            ForEach(appState.availableLanguages, id: \.self) { lang in
                                Text(appState.languageName(for: lang)).tag(lang)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }

                    if let initial = initialLanguage, initial != appState.appLanguage {
                        Text(String(localized: "RESTART_REQUIRED"))
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.top, -10)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    
                    Divider()
                    
                    Toggle(String(localized: "LAUNCH_AT_LOGIN"), isOn: $appState.launchAtLogin)
                        .toggleStyle(.switch)
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label(String(localized: "QUIT_POLARFLUX"), systemImage: "power")
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
                    Text(String(localized: "ORIGIN"))
                        .font(.caption).bold()
                    Text(String(format: String(localized: "POSITION_PERCENT"), Int(currentOrigin * 100)))
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
