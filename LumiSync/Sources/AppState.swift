import SwiftUI
import Combine
import ScreenCaptureKit

enum LightingMode: String, CaseIterable, Identifiable {
    case sync = "Screen Sync"
    case music = "Music Mode"
    case effect = "Effects"
    case manual = "Manual"
    
    var id: String { self.rawValue }
}

enum PowerMode: String, CaseIterable, Identifiable {
    case abl = "Auto Brightness Limiter"
    case globalCap = "Global Brightness Cap"
    case smartFallback = "Smart Fallback"
    
    var id: String { self.rawValue }
}

enum ScreenOrientation: String, CaseIterable, Identifiable {
    case standard = "Standard (CW from Bottom-Left)"
    case reverse = "Reverse (CCW from Bottom-Right)"
    
    var id: String { self.rawValue }
}

class AppState: ObservableObject {
    @Published var selectedPort: String = ""
    @Published var availablePorts: [String] = []
    @Published var baudRate: String = "115200"
    let availableBaudRates = ["9600", "19200", "38400", "57600", "115200", "230400", "460800", "500000", "921600"]
    
    @Published var ledCount: String = "100"
    @Published var leftZone: String = "20"
    @Published var topZone: String = "60"
    @Published var rightZone: String = "20"
    @Published var bottomZone: String = "0"
    @Published var depth: String = "100"
    
    @Published var brightness: Double = 1.0
    @Published var statusMessage: String = "Ready"
    
    // Power Management
    @Published var powerMode: PowerMode = .abl
    @Published var powerLimit: Double = 0.9 // 90% default
    @Published var isPowerLimited: Bool = false
    @Published var limitReason: String = ""
    
    // Modes
    @Published var currentMode: LightingMode = .manual
    @Published var isRunning: Bool = false
    
    // Sync Settings
    @Published var syncMode: SyncMode = .full
    @Published var screenOrientation: ScreenOrientation = .standard
    
    // Effect Settings
    @Published var selectedEffect: EffectType = .rainbow
    @Published var effectSpeeds: [EffectType: Double] = [
        .rainbow: 1.0,
        .breathing: 1.0,
        .marquee: 1.0
    ]
    @Published var effectColors: [EffectType: Color] = [
        .rainbow: .red, // Not used for rainbow
        .breathing: .blue,
        .marquee: .green
    ]
    
    // Manual Settings
    @Published var manualColor: Color = .white
    @Published var manualR: Double = 255
    @Published var manualG: Double = 255
    @Published var manualB: Double = 255
    
    // Calibration
    @Published var calibrationR: Double = 1.0
    @Published var calibrationG: Double = 1.0
    @Published var calibrationB: Double = 1.0
    @Published var gamma: Double = 1.0
    @Published var saturation: Double = 1.0
    @Published var useDominantColor: Bool = true
    
    // Audio Settings
    @Published var availableMicrophones: [AudioInputDevice] = []
    @Published var selectedMicrophoneUID: String = "" {
        didSet {
            updateMicrophone()
        }
    }
    
    // Auto Start
    @Published var launchAtLogin: Bool = LaunchAtLogin.isEnabled {
        didSet {
            LaunchAtLogin.setEnabled(launchAtLogin)
        }
    }
    
    // Persistence
    @Published var wasRunning: Bool = false
    
    private var isSending = false
    private var isCapturing = false
    private var cachedDisplay: SCDisplay?
    private var serialPort = SerialPort()
    private var screenCapture = ScreenCapture()
    private var audioProcessor = AudioProcessor()
    private var effectEngine = EffectEngine()
    
    private var loopTimer: AnyCancellable?
    private var currentColor: (r: UInt8, g: UInt8, b: UInt8)?
    
    private var lastSentData: [UInt8]?
    private var keepAliveTimer: Timer?
    private var lastConnectionAttempt: Date = .distantPast
    
    init() {
        refreshPorts()
        refreshMicrophones()
        loadSettings()
        
        // Setup Audio Callback
        audioProcessor.onAudioLevel = { [weak self] level in
            self?.processAudioFrame(level: level)
        }
        
        // Setup Effect Callback
        effectEngine.onFrame = { [weak self] data in
            self?.sendData(data)
        }
        
        // Setup Serial Disconnect Callback
        serialPort.onDisconnect = { [weak self] in
            Logger.shared.log("Serial port disconnected unexpectedly")
            self?.handleDisconnection()
        }
    }
    
    func handleDisconnection() {
        if isRunning {
            if powerMode == .smartFallback {
                // Smart Fallback Logic
                Logger.shared.log("Smart Fallback triggered. Reducing brightness.")
                
                // Reduce brightness by 10%
                let newBrightness = max(0.1, brightness - 0.1)
                brightness = newBrightness
                
                // Stop current run
                stop()
                statusMessage = "Power Limit Reached - Reducing Brightness"
                
                // Attempt to restart after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if !self.isRunning {
                        self.statusMessage = "Auto-restarting with brightness \(Int(self.brightness * 100))%"
                        self.start()
                    }
                }
            } else {
                stop()
                statusMessage = "Connection Lost"
            }
        }
    }
    
    func refreshPorts() {
        availablePorts = serialPort.listPorts()
        if selectedPort.isEmpty, let first = availablePorts.first {
            selectedPort = first
        }
    }
    
    func toggleRun() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }
    
    func start() {
        if isRunning { return }
        
        statusMessage = "Connecting..."
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if self.connectSerial() {
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.statusMessage = "Running: \(self.currentMode.rawValue)"
                    Logger.shared.log("Starting mode: \(self.currentMode.rawValue)")
                    
                    self.startKeepAlive()
                    
                    switch self.currentMode {
                    case .sync:
                        self.startSync()
                    case .music:
                        self.startMusic()
                    case .effect:
                        self.startEffect()
                    case .manual:
                        self.startManual()
                    }
                }
            }
        }
    }
    
    func stop() {
        Logger.shared.log("Stopping")
        isRunning = false
        statusMessage = "Stopped"
        
        loopTimer?.cancel()
        loopTimer = nil
        cachedDisplay = nil
        
        // Stop Stream
        Task {
            await screenCapture.stopStream()
        }
        
        audioProcessor.stop()
        effectEngine.stop()
        
        // Send black
        let count = Int(ledCount) ?? 100
        let black = [UInt8](repeating: 0, count: count * 3)
        serialPort.sendSkydimo(rgbData: black)
        
        stopKeepAlive()
    }
    
    // MARK: - Sync Mode
    private func startSync() {
        // Check permission first
        Task {
            if await !ScreenCapture.checkPermission() {
                DispatchQueue.main.async {
                    self.statusMessage = "Screen Recording Permission Denied"
                    self.stop()
                }
                return
            }
            
            // Permission granted, start stream
            DispatchQueue.main.async {
                self.startSyncStream()
            }
        }
    }
    
    private func startSyncStream() {
        let config = ZoneConfig(
            left: Int(leftZone) ?? 0,
            top: Int(topZone) ?? 0,
            right: Int(rightZone) ?? 0,
            bottom: Int(bottomZone) ?? 0,
            depth: Int(depth) ?? 100
        )
        let totalLeds = Int(ledCount) ?? 100
        let orientation = self.screenOrientation
        let useDominant = self.useDominantColor
        let mode = self.syncMode
        
        // Setup Callback
        screenCapture.onFrameProcessed = { [weak self] data in
            self?.sendData(data)
        }
        
        Task {
            if self.cachedDisplay == nil {
                self.cachedDisplay = await self.screenCapture.getDisplay()
            }
            
            guard let display = self.cachedDisplay else {
                DispatchQueue.main.async {
                    self.statusMessage = "No Display Found"
                    self.stop()
                }
                return
            }
            
            await self.screenCapture.startStream(
                display: display,
                config: config,
                ledCount: totalLeds,
                mode: mode,
                orientation: orientation,
                useDominantColor: useDominant
            )
        }
    }
    
    // MARK: - Music Mode
    private func startMusic() {
        audioProcessor.start()
    }
    
    private func processAudioFrame(level: Float) {
        guard isRunning, currentMode == .music else { return }
        
        let totalLeds = Int(ledCount) ?? 100
        var data = [UInt8]()
        data.reserveCapacity(totalLeds * 3)
        
        // Simple VU Meter effect from center
        let litCount = Int(Float(totalLeds) * level)
        let center = totalLeds / 2
        let halfLit = litCount / 2
        
        for i in 0..<totalLeds {
            let dist = abs(i - center)
            if dist < halfLit {
                // Color based on intensity (Green -> Red)
                let intensity = Float(dist) / Float(totalLeds/2)
                let r = UInt8(min(255, intensity * 510))
                let g = UInt8(min(255, (1.0 - intensity) * 510))
                data.append(r)
                data.append(g)
                data.append(0)
            } else {
                data.append(0)
                data.append(0)
                data.append(0)
            }
        }
        
        sendData(data)
    }
    
    // MARK: - Effect Mode
    private func startEffect() {
        let totalLeds = Int(ledCount) ?? 100
        // Convert Color to RGB
        var r: UInt8 = 255
        var g: UInt8 = 0
        var b: UInt8 = 0
        
        let color = effectColors[selectedEffect] ?? .red
        let speed = effectSpeeds[selectedEffect] ?? 1.0
        
        if let rgb = color.cgColor?.components {
            if rgb.count >= 3 {
                r = UInt8(rgb[0] * 255)
                g = UInt8(rgb[1] * 255)
                b = UInt8(rgb[2] * 255)
            }
        }
        
        effectEngine.start(effect: selectedEffect, ledCount: totalLeds, speed: speed, color: (r, g, b))
    }
    
    func restartEffect() {
        if isRunning && currentMode == .effect {
            startEffect() // Restart with new params
        }
    }
    
    // MARK: - Manual Mode
    func setManualColor(color: Color) {
        manualColor = color
        if let rgb = color.cgColor?.components {
            // Handle different color spaces
            var r: UInt8 = 0
            var g: UInt8 = 0
            var b: UInt8 = 0
            
            if rgb.count >= 3 {
                r = UInt8(rgb[0] * 255)
                g = UInt8(rgb[1] * 255)
                b = UInt8(rgb[2] * 255)
            } else if rgb.count == 2 {
                // Grayscale
                r = UInt8(rgb[0] * 255)
                g = UInt8(rgb[0] * 255)
                b = UInt8(rgb[0] * 255)
            }
            
            // Update individual components without triggering loop
            self.manualR = Double(r)
            self.manualG = Double(g)
            self.manualB = Double(b)
            
            setManualColor(r: r, g: g, b: b)
        }
    }
    
    func updateManualColorFromRGB(preview: Bool = true) {
        let r = UInt8(manualR)
        let g = UInt8(manualG)
        let b = UInt8(manualB)
        
        // Update Color object
        self.manualColor = Color(red: manualR/255.0, green: manualG/255.0, blue: manualB/255.0)
        
        setManualColor(r: r, g: g, b: b, preview: preview)
    }
    
    func setManualColor(r: UInt8, g: UInt8, b: UInt8, preview: Bool = true) {
        currentColor = (r, g, b)
        
        if !preview {
            // Just update state, don't start or send data
            return
        }
        
        if isRunning && currentMode == .manual {
            // Update immediately if not busy, to feel responsive
            if !isSending {
                let count = Int(ledCount) ?? 100
                var data = [UInt8]()
                data.reserveCapacity(count * 3)
                for _ in 0..<count {
                    data.append(r)
                    data.append(g)
                    data.append(b)
                }
                sendData(data)
            }
        } else {
            // Switch to manual and start
            currentMode = .manual
            if !isRunning {
                start()
            } else {
                // Restart to switch mode logic
                stop()
                start()
            }
        }
    }
    
    private func startManual() {
        // Ensure currentColor is set from manualColor if nil
        if currentColor == nil {
            if let rgb = manualColor.cgColor?.components {
                var r: UInt8 = 0
                var g: UInt8 = 0
                var b: UInt8 = 0
                
                if rgb.count >= 3 {
                    r = UInt8(rgb[0] * 255)
                    g = UInt8(rgb[1] * 255)
                    b = UInt8(rgb[2] * 255)
                } else if rgb.count == 2 {
                    r = UInt8(rgb[0] * 255)
                    g = UInt8(rgb[0] * 255)
                    b = UInt8(rgb[0] * 255)
                }
                currentColor = (r, g, b)
            } else {
                // Fallback to white
                currentColor = (255, 255, 255)
            }
        }

        // Heartbeat
        loopTimer = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let color = self.currentColor else { return }
                
                // Don't pile up if busy
                if self.isSending { return }
                
                let count = Int(self.ledCount) ?? 100
                var data = [UInt8]()
                data.reserveCapacity(count * 3)
                for _ in 0..<count {
                    data.append(color.r)
                    data.append(color.g)
                    data.append(color.b)
                }
                self.sendData(data)
            }
    }
    
    // MARK: - Helper
    private func sendData(_ data: [UInt8]) {
        // Double check busy state to prevent flooding
        if isSending { return }
        isSending = true
        
        // Store original data for keep-alive to prevent recursive dimming
        self.lastSentData = data
        
        var finalData = data
        
        // Apply Saturation Boost
        if saturation != 1.0 {
            for i in stride(from: 0, to: finalData.count, by: 3) {
                if i + 2 < finalData.count {
                    let r = Double(finalData[i]) / 255.0
                    let g = Double(finalData[i+1]) / 255.0
                    let b = Double(finalData[i+2]) / 255.0
                    
                    // RGB to HSV
                    let maxC = max(r, max(g, b))
                    let minC = min(r, min(g, b))
                    let delta = maxC - minC
                    
                    var h: Double = 0
                    var s: Double = 0
                    let v: Double = maxC
                    
                    if delta != 0 {
                        s = delta / maxC
                        
                        if r == maxC {
                            h = (g - b) / delta
                        } else if g == maxC {
                            h = 2 + (b - r) / delta
                        } else {
                            h = 4 + (r - g) / delta
                        }
                        h *= 60
                        if h < 0 { h += 360 }
                    }
                    
                    // Apply Saturation Gain
                    s = min(max(s * saturation, 0), 1.0)
                    
                    // HSV to RGB
                    let c = v * s
                    let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
                    let m = v - c
                    
                    var r1 = 0.0, g1 = 0.0, b1 = 0.0
                    if h < 60 { r1 = c; g1 = x; b1 = 0 }
                    else if h < 120 { r1 = x; g1 = c; b1 = 0 }
                    else if h < 180 { r1 = 0; g1 = c; b1 = x }
                    else if h < 240 { r1 = 0; g1 = x; b1 = c }
                    else if h < 300 { r1 = x; g1 = 0; b1 = c }
                    else { r1 = c; g1 = 0; b1 = x }
                    
                    finalData[i] = UInt8((r1 + m) * 255)
                    finalData[i+1] = UInt8((g1 + m) * 255)
                    finalData[i+2] = UInt8((b1 + m) * 255)
                }
            }
        }
        
        // Apply Gamma Correction
        if gamma != 1.0 {
            for i in 0..<finalData.count {
                let normalized = Double(finalData[i]) / 255.0
                let corrected = pow(normalized, gamma) * 255.0
                finalData[i] = UInt8(min(max(corrected, 0), 255))
            }
        }
        
        // Apply Calibration
        if calibrationR != 1.0 || calibrationG != 1.0 || calibrationB != 1.0 {
            for i in stride(from: 0, to: finalData.count, by: 3) {
                if i + 2 < finalData.count {
                    finalData[i] = UInt8(min(Double(finalData[i]) * calibrationR, 255.0))
                    finalData[i+1] = UInt8(min(Double(finalData[i+1]) * calibrationG, 255.0))
                    finalData[i+2] = UInt8(min(Double(finalData[i+2]) * calibrationB, 255.0))
                }
            }
        }
        
        // Apply Power Management Logic
        switch powerMode {
        case .abl:
            // Automatic Brightness Limiter
            // Calculate total brightness sum
            var totalSum: Double = 0
            for byte in finalData {
                totalSum += Double(byte)
            }
            
            // Max possible sum (all white)
            let maxPossible = Double(finalData.count) * 255.0
            let threshold = maxPossible * powerLimit
            
            if totalSum > threshold {
                let scale = threshold / totalSum
                for i in 0..<finalData.count {
                    finalData[i] = UInt8(Double(finalData[i]) * scale)
                }
                
                DispatchQueue.main.async {
                    if !self.isPowerLimited {
                        self.isPowerLimited = true
                        self.limitReason = "Brightness reduced by Smart Protection"
                    }
                }
            } else {
                DispatchQueue.main.async {
                    if self.isPowerLimited {
                        self.isPowerLimited = false
                        self.limitReason = ""
                    }
                }
            }
            
            // Apply user brightness on top
            if brightness < 1.0 {
                for i in 0..<finalData.count {
                    finalData[i] = UInt8(Double(finalData[i]) * brightness)
                }
            }
            
        case .globalCap:
            // Global Cap: Limit the maximum output brightness
            // Effective brightness is min(userBrightness, powerLimit)
            let effectiveBrightness = min(brightness, powerLimit)
            
            if brightness > powerLimit {
                DispatchQueue.main.async {
                    if !self.isPowerLimited {
                        self.isPowerLimited = true
                        self.limitReason = "Capped by Safe Mode"
                    }
                }
            } else {
                DispatchQueue.main.async {
                    if self.isPowerLimited {
                        self.isPowerLimited = false
                        self.limitReason = ""
                    }
                }
            }
            
            if effectiveBrightness < 1.0 {
                for i in 0..<finalData.count {
                    finalData[i] = UInt8(Double(finalData[i]) * effectiveBrightness)
                }
            }
            
        case .smartFallback:
            // Smart Fallback: Just apply user brightness normally
            DispatchQueue.main.async {
                if self.isPowerLimited {
                    self.isPowerLimited = false
                    self.limitReason = ""
                }
            }
            // Fallback logic is handled in handleDisconnection
            if brightness < 1.0 {
                for i in 0..<finalData.count {
                    finalData[i] = UInt8(Double(finalData[i]) * brightness)
                }
            }
        }
        
        serialPort.sendSkydimo(rgbData: finalData) { [weak self] in
            DispatchQueue.main.async {
                self?.isSending = false
            }
        }
    }
    
    private func connectSerial() -> Bool {
        // Prevent flooding connection attempts
        let now = Date()
        if now.timeIntervalSince(lastConnectionAttempt) < 1.0 && !serialPort.isConnected {
            Logger.shared.log("Throttling connection attempt")
            return false
        }
        lastConnectionAttempt = now

        if !serialPort.isConnected {
            let baud = Int(baudRate) ?? 115200
            Logger.shared.log("Connecting to \(selectedPort) at \(baud)")
            if serialPort.connect(path: selectedPort, baudRate: baud) {
                // Wait for device to settle (Arduino reset etc)
                usleep(1500000) // 1.5s
                
                // Handshake / Auto-detect
                if let info = serialPort.getDeviceInfo() {
                    Logger.shared.log("Device connected: \(info)")
                    print("Device connected: \(info)")
                    let parts = info.split(separator: ",")
                    if let model = parts.first.map({ String($0) }) {
                        DispatchQueue.main.async {
                            self.applyModelConfig(modelName: model)
                            self.statusMessage = "Connected: \(model)"
                        }
                    }
                }
                
                return true
            } else {
                Logger.shared.log("Connection Failed")
                DispatchQueue.main.async {
                    self.statusMessage = "Connection Failed"
                }
                return false
            }
        }
        return true
    }
    
    func saveSettings() {
        UserDefaults.standard.set(selectedPort, forKey: "selectedPort")
        UserDefaults.standard.set(baudRate, forKey: "baudRate")
        UserDefaults.standard.set(ledCount, forKey: "ledCount")
        UserDefaults.standard.set(leftZone, forKey: "leftZone")
        UserDefaults.standard.set(topZone, forKey: "topZone")
        UserDefaults.standard.set(rightZone, forKey: "rightZone")
        UserDefaults.standard.set(bottomZone, forKey: "bottomZone")
        UserDefaults.standard.set(depth, forKey: "depth")
        UserDefaults.standard.set(brightness, forKey: "brightness")
        UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        UserDefaults.standard.set(powerMode.rawValue, forKey: "powerMode")
        UserDefaults.standard.set(powerLimit, forKey: "powerLimit")
        UserDefaults.standard.set(currentMode.rawValue, forKey: "currentMode")
        UserDefaults.standard.set(isRunning, forKey: "wasRunning")
        UserDefaults.standard.set(selectedEffect.rawValue, forKey: "selectedEffect")
        
        // Save Effect Speeds
        let speeds = effectSpeeds.reduce(into: [String: Double]()) { $0[$1.key.rawValue] = $1.value }
        UserDefaults.standard.set(speeds, forKey: "effectSpeeds")
        
        // Save Effect Colors
        let colors = effectColors.reduce(into: [String: [CGFloat]]()) {
            if let components = $1.value.cgColor?.components {
                $0[$1.key.rawValue] = components
            }
        }
        UserDefaults.standard.set(colors, forKey: "effectColors")
        
        UserDefaults.standard.set(screenOrientation.rawValue, forKey: "screenOrientation")
        
        // Save Manual Color
        UserDefaults.standard.set(manualR, forKey: "manualR")
        UserDefaults.standard.set(manualG, forKey: "manualG")
        UserDefaults.standard.set(manualB, forKey: "manualB")
        
        // Save Calibration
        UserDefaults.standard.set(calibrationR, forKey: "calibrationR")
        UserDefaults.standard.set(calibrationG, forKey: "calibrationG")
        UserDefaults.standard.set(calibrationB, forKey: "calibrationB")
        UserDefaults.standard.set(gamma, forKey: "gamma")
        UserDefaults.standard.set(saturation, forKey: "saturation")
        UserDefaults.standard.set(useDominantColor, forKey: "useDominantColor")
        
        UserDefaults.standard.set(selectedMicrophoneUID, forKey: "selectedMicrophoneUID")
    }
    
    func loadSettings() {
        if let p = UserDefaults.standard.string(forKey: "selectedPort") { selectedPort = p }
        if let b = UserDefaults.standard.string(forKey: "baudRate") { baudRate = b }
        if let l = UserDefaults.standard.string(forKey: "ledCount") { ledCount = l }
        if let lz = UserDefaults.standard.string(forKey: "leftZone") { leftZone = lz }
        if let tz = UserDefaults.standard.string(forKey: "topZone") { topZone = tz }
        if let rz = UserDefaults.standard.string(forKey: "rightZone") { rightZone = rz }
        if let bz = UserDefaults.standard.string(forKey: "bottomZone") { bottomZone = bz }
        if let d = UserDefaults.standard.string(forKey: "depth") { depth = d }
        let br = UserDefaults.standard.double(forKey: "brightness")
        if br > 0 { brightness = br }
        launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        
        if let pm = UserDefaults.standard.string(forKey: "powerMode"), let mode = PowerMode(rawValue: pm) {
            powerMode = mode
        }
        let pl = UserDefaults.standard.double(forKey: "powerLimit")
        if pl > 0 { powerLimit = pl }
        
        // Load Calibration
        let cR = UserDefaults.standard.double(forKey: "calibrationR")
        if cR > 0 { calibrationR = cR }
        let cG = UserDefaults.standard.double(forKey: "calibrationG")
        if cG > 0 { calibrationG = cG }
        let cB = UserDefaults.standard.double(forKey: "calibrationB")
        if cB > 0 { calibrationB = cB }
        let g = UserDefaults.standard.double(forKey: "gamma")
        if g > 0 { gamma = g }
        let sat = UserDefaults.standard.double(forKey: "saturation")
        if sat > 0 { saturation = sat }
        if UserDefaults.standard.object(forKey: "useDominantColor") != nil {
            useDominantColor = UserDefaults.standard.bool(forKey: "useDominantColor")
        }
        
        if let modeStr = UserDefaults.standard.string(forKey: "currentMode"), let mode = LightingMode(rawValue: modeStr) {
            currentMode = mode
        }
        
        wasRunning = UserDefaults.standard.bool(forKey: "wasRunning")
        
        if let effStr = UserDefaults.standard.string(forKey: "selectedEffect"), let eff = EffectType(rawValue: effStr) {
            selectedEffect = eff
        }
        
        // Load Effect Speeds
        if let speeds = UserDefaults.standard.dictionary(forKey: "effectSpeeds") as? [String: Double] {
            for (key, value) in speeds {
                if let type = EffectType(rawValue: key) {
                    effectSpeeds[type] = value
                }
            }
        }
        
        // Load Effect Colors
        if let colors = UserDefaults.standard.dictionary(forKey: "effectColors") as? [String: [CGFloat]] {
            for (key, components) in colors {
                if let type = EffectType(rawValue: key), components.count >= 3 {
                    effectColors[type] = Color(red: components[0], green: components[1], blue: components[2])
                }
            }
        }
        
        if let orientStr = UserDefaults.standard.string(forKey: "screenOrientation"), let orient = ScreenOrientation(rawValue: orientStr) {
            screenOrientation = orient
        }
        
        let mr = UserDefaults.standard.double(forKey: "manualR")
        let mg = UserDefaults.standard.double(forKey: "manualG")
        let mb = UserDefaults.standard.double(forKey: "manualB")
        // Only load if they are not all 0 (unless user really wanted black, but default is 255)
        if mr > 0 || mg > 0 || mb > 0 {
            manualR = mr
            manualG = mg
            manualB = mb
            updateManualColorFromRGB(preview: false)
        }
        
        if let micUID = UserDefaults.standard.string(forKey: "selectedMicrophoneUID") {
            selectedMicrophoneUID = micUID
        }
        
        // Auto-start if was running
        if wasRunning {
            // Delay slightly to allow UI to load
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.start()
            }
        }
    }
    
    // MARK: - Auto Detect
    
    struct SkydimoModel {
        let layout: Int // 0: Strip, 1: Sides, 2: Perimeter 3, 3: Perimeter 4
        let zones: [Int] // LED counts for each zone
        let total: Int
    }
    
    let skydimoModels: [String: SkydimoModel] = [
        // 2-zone
        "SK0201": SkydimoModel(layout: 1, zones: [20, 20], total: 40),
        "SK0202": SkydimoModel(layout: 1, zones: [30, 30], total: 60),
        "SK0204": SkydimoModel(layout: 1, zones: [25, 25], total: 50),
        
        // 3-zone (Perimeter 3: Right, Top, Left)
        "SK0121": SkydimoModel(layout: 2, zones: [13, 25, 13], total: 51),
        "SK0124": SkydimoModel(layout: 2, zones: [14, 26, 14], total: 54),
        "SK0127": SkydimoModel(layout: 2, zones: [17, 31, 17], total: 65),
        "SK0132": SkydimoModel(layout: 2, zones: [20, 37, 20], total: 77),
        "SK0134": SkydimoModel(layout: 2, zones: [15, 41, 15], total: 71),
        "SK0149": SkydimoModel(layout: 2, zones: [19, 69, 19], total: 107),
        
        // 4-zone (Perimeter 4: Right, Top, Left, Bottom)
        "SK0L21": SkydimoModel(layout: 3, zones: [13, 25, 13, 25], total: 76),
        "SK0L24": SkydimoModel(layout: 3, zones: [14, 26, 14, 26], total: 80),
        "SK0L27": SkydimoModel(layout: 3, zones: [17, 31, 17, 31], total: 96),
        "SK0L32": SkydimoModel(layout: 3, zones: [20, 37, 20, 37], total: 114),
        "SK0L34": SkydimoModel(layout: 3, zones: [15, 41, 15, 41], total: 112),
        
        // SKA series (3-zone)
        "SKA124": SkydimoModel(layout: 2, zones: [18, 34, 18], total: 70),
        "SKA127": SkydimoModel(layout: 2, zones: [20, 41, 20], total: 81),
        "SKA132": SkydimoModel(layout: 2, zones: [25, 45, 25], total: 95),
        "SKA134": SkydimoModel(layout: 2, zones: [21, 51, 21], total: 93),
        
        // Single Strip
        "SK0402": SkydimoModel(layout: 0, zones: [72], total: 72),
        "SK0403": SkydimoModel(layout: 0, zones: [96], total: 96),
        "SK0404": SkydimoModel(layout: 0, zones: [144], total: 144),
        "SK0J01": SkydimoModel(layout: 0, zones: [120], total: 120),
        "SK0K01": SkydimoModel(layout: 0, zones: [120], total: 120),
        "SK0N01": SkydimoModel(layout: 0, zones: [256], total: 256),
        "SK0N02": SkydimoModel(layout: 0, zones: [1024], total: 1024)
    ]
    
    func autoDetectDevice() {
        Logger.shared.log("Starting auto-detection")
        guard connectSerial() else {
            statusMessage = "Connect first to detect"
            return
        }
        
        // Pause sending if running
        let wasRunning = isRunning
        if wasRunning { stop() }
        
        DispatchQueue.global(qos: .userInitiated).async {
            if let response = self.serialPort.getDeviceInfo() {
                Logger.shared.log("Auto-detect response: \(response)")
                // Response format: "Model,Serial"
                let parts = response.split(separator: ",")
                if let modelName = parts.first.map({ String($0) }) {
                    DispatchQueue.main.async {
                        self.applyModelConfig(modelName: modelName)
                        self.statusMessage = "Detected: \(modelName)"
                        if wasRunning { self.start() }
                    }
                    return
                }
            } else {
                Logger.shared.log("Auto-detect failed: No response")
            }
            
            DispatchQueue.main.async {
                self.statusMessage = "Detection failed"
                if wasRunning { self.start() }
            }
        }
    }
    
    func applyModelConfig(modelName: String) {
        guard let config = skydimoModels[modelName] else {
            statusMessage = "Unknown model: \(modelName)"
            return
        }
        
        self.ledCount = "\(config.total)"
        
        switch config.layout {
        case 0: // Strip
            self.leftZone = "0"
            self.topZone = "\(config.total)"
            self.rightZone = "0"
            self.bottomZone = "0"
            
        case 1: // Sides (Left/Right)
            // Config says Z1, Z2. Usually Left, Right or Right, Left.
            // SkydimoDeviceConfig says: Z1=Left(Bottom->Top), Z2=Right(Top->Bottom) for SIDES_2
            if config.zones.count >= 2 {
                self.leftZone = "\(config.zones[0])"
                self.rightZone = "\(config.zones[1])"
                self.topZone = "0"
                self.bottomZone = "0"
            }
            
        case 2: // Perimeter 3 (Right, Top, Left)
            // SkydimoDeviceConfig: Z1=Right, Z2=Top, Z3=Left
            if config.zones.count >= 3 {
                self.rightZone = "\(config.zones[0])"
                self.topZone = "\(config.zones[1])"
                self.leftZone = "\(config.zones[2])"
                self.bottomZone = "0"
            }
            
        case 3: // Perimeter 4 (Right, Top, Left, Bottom)
            // SkydimoDeviceConfig: Z1=Right, Z2=Top, Z3=Left, Z4=Bottom
            if config.zones.count >= 4 {
                self.rightZone = "\(config.zones[0])"
                self.topZone = "\(config.zones[1])"
                self.leftZone = "\(config.zones[2])"
                self.bottomZone = "\(config.zones[3])"
            }
            
        default:
            break
        }
    }
    
    // MARK: - Test Mode
    func startOrientationTest() {
        // Save current state
        let previousState = isRunning
        
        // Stop any running loop
        stop()
        
        statusMessage = "Connecting for Test..."
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if self.connectSerial() {
                DispatchQueue.main.async {
                    self.statusMessage = "Testing Orientation..."
                    self.isRunning = true // Mark as running so stop button works
                    
                    var position = 0
                    var cycles = 0
                    let totalLeds = Int(self.ledCount) ?? 100
                    
                    self.loopTimer = Timer.publish(every: 0.05, on: .main, in: .common)
                        .autoconnect()
                        .sink { [weak self] _ in
                            guard let self = self else { return }
                            
                            var data = [UInt8](repeating: 0, count: totalLeds * 3)
                            
                            // Draw a "Snake" of 10 pixels
                            let snakeLength = 10
                            for i in 0..<snakeLength {
                                let pixelIndex = (position - i + totalLeds) % totalLeds
                                // Head is white, tail fades to blue
                                if i == 0 {
                                    data[pixelIndex * 3] = 255
                                    data[pixelIndex * 3 + 1] = 255
                                    data[pixelIndex * 3 + 2] = 255
                                } else {
                                    let brightness = Double(snakeLength - i) / Double(snakeLength)
                                    data[pixelIndex * 3] = 0
                                    data[pixelIndex * 3 + 1] = 0
                                    data[pixelIndex * 3 + 2] = UInt8(255 * brightness)
                                }
                            }
                            
                            self.sendData(data)
                            position += 1
                            
                            // Check for completion (2 full loops)
                            if position >= totalLeds {
                                position = 0
                                cycles += 1
                                if cycles >= 2 {
                                    self.stop()
                                    self.statusMessage = "Test Complete"
                                    
                                    // Restore previous state if it was running
                                    if previousState {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                            self.start()
                                        }
                                    }
                                }
                            }
                        }
                }
            }
        }
    }
    
    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            
            // If we have data and haven't sent anything recently (handled by isSending flag logic implicitly if we wanted,
            // but here we just want to ensure the device doesn't timeout.
            // The C++ code sends last_colors every 250ms regardless of updates if the thread is running.
            // However, we don't want to flood if we are already sending high FPS sync data.
            // A simple approach is to just resend the last data if we are in a static mode or if the stream is idle.
            // But for now, let's just replicate the C++ behavior: send if we have data.
            
            if let data = self.lastSentData {
                // We use a separate send method or just sendData but we need to be careful about thread safety/queueing.
                // sendData uses the serial queue, so it's safe.
                // But sendData sets isSending = true.
                
                if !self.isSending {
                    self.sendData(data)
                }
            }
        }
    }
    
    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }
    
    func refreshMicrophones() {
        availableMicrophones = audioProcessor.getAvailableInputs()
        // If selected UID is empty or not found, select default (first)
        if selectedMicrophoneUID.isEmpty, let first = availableMicrophones.first {
            selectedMicrophoneUID = first.uid
        } else if !availableMicrophones.contains(where: { $0.uid == selectedMicrophoneUID }), let first = availableMicrophones.first {
            selectedMicrophoneUID = first.uid
        }
        updateMicrophone()
    }
    
    private func updateMicrophone() {
        if let device = availableMicrophones.first(where: { $0.uid == selectedMicrophoneUID }) {
            audioProcessor.setDevice(id: device.id)
        }
    }
}
