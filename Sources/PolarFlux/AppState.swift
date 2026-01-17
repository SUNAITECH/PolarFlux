import SwiftUI
import Combine
import ScreenCaptureKit
import AppKit
import Darwin

struct PerformanceMetrics {
    var ramUsage: Double = 0.0
    var fps: Double = 0.0
    var metalEnabled: Bool = false
    
    // Serial Telemetry
    var totalPackets: UInt64 = 0
    var dataRate: Double = 0.0 // KB/s
    var serialLatency: Double = 0.0 // ms
    var pps: Double = 0.0 // Packets Per Second
    var writeErrors: Int = 0
    var reconnects: Int = 0
    var bufferSize: Int = 0
}

struct HealthCheckItem: Identifiable {
    let id = UUID()
    let name: String
    let status: Bool // true = good
    let message: String
}

enum LightingMode: String, CaseIterable, Identifiable {
    case sync = "SCREEN_SYNC"
    case music = "MUSIC_MODE"
    case effect = "EFFECTS"
    case manual = "MANUAL"
    
    var id: String { self.rawValue }
    var localizedName: String {
        String(localized: String.LocalizationValue(self.rawValue))
    }
}

enum PowerMode: String, CaseIterable, Identifiable {
    case abl = "AUTO_BRIGHTNESS_LIMITER"
    case globalCap = "GLOBAL_BRIGHTNESS_CAP"
    case smartFallback = "SMART_FALLBACK"
    
    var id: String { self.rawValue }
    var localizedName: String {
        String(localized: String.LocalizationValue(self.rawValue))
    }
}

enum ScreenOrientation: String, CaseIterable, Identifiable {
    case standard = "STANDARD_CW_FULL"
    case reverse = "REVERSE_CCW_FULL"
    
    var id: String { self.rawValue }
    var localizedName: String {
        String(localized: String.LocalizationValue(self.rawValue))
    }
}

class AppState: ObservableObject {
    @Published var selectedPort: String = "" {
        didSet {
            lastBaudDetectionResult = nil
        }
    }
    @Published var availablePorts: [String] = []
    @Published var baudRate: String = "115200"
    let availableBaudRates = ["9600", "19200", "38400", "57600", "115200", "230400", "460800", "500000", "921600"]
    
    @Published var ledCount: String = "100"
    @Published var leftZone: String = "20"
    @Published var topZone: String = "60"
    @Published var rightZone: String = "20"
    @Published var bottomZone: String = "0"
    
    @Published var brightness: Double = 1.0
    @Published var statusMessage: String = String(localized: "READY")
    
    // Performance & Health
    @Published var useMetal: Bool = true {
        didSet {
            screenCapture.useMetal = useMetal
        }
    }
    @Published var performanceMetrics = PerformanceMetrics()
    @Published var healthChecks: [HealthCheckItem] = []
    @Published var lastResetTime: Date?
    let appStartTime = Date() // DEPRECATED
    @Published var appLanguage: String = "System" {
        didSet {
            UserDefaults.standard.set(appLanguage, forKey: "appLanguage")
            updateLocale()
            // Immediately update the most visible status strings
            statusMessage = String(localized: "READY", locale: currentLocale)
        }
    }
    @Published var currentLocale: Locale = .current
    
    // Debug & Frontier
    @Published var isDebugMode: Bool = false
    @Published var forceCPU: Bool = false {
        didSet {
            screenCapture.forceCPU = forceCPU
        }
    }
    // Simulation / VIS
    @Published var lastFrameColors: [UInt8] = []
    
    private var healthTimer: Timer?
    
    // Telemetry Baselines
    private var lastBytes: UInt64 = 0
    private var lastPackets: UInt64 = 0
    private var lastMetricTime: Double = CACurrentMediaTime()
    
    // Power Management
    @Published var powerMode: PowerMode = .abl
    @Published var powerLimit: Double = 0.9 // 90% default
    @Published var isPowerLimited: Bool = false
    @Published var limitReason: String = ""
    
    // Baud Rate Detection
    @Published var isProbingBaud: Bool = false
    @Published var lastBaudDetectionResult: Bool? = nil
    
    // Modes
    @Published var currentMode: LightingMode = .manual
    @Published var isRunning: Bool = false
    
    // Sync Settings
    @Published var screenOrientation: ScreenOrientation = .standard
    @Published var targetFrameRate: Double = 60.0
    @Published var searchDepth: Double = 0.8 // DEPRECATED: 80% inwards search
    @Published var syncBrightness: Double = 1.0 // Separate brightness for Sync
    @Published var perspectiveOriginMode: PerspectiveOriginMode = .auto
    @Published var manualOriginPosition: Double = 0.5
    
    // Computed property for the actual origin used in sampling
    var currentOriginY: Double {
        if perspectiveOriginMode == .manual {
            return manualOriginPosition
        }
        
        let goldenRatio = 0.618
        let top = Int(topZone) ?? 0
        let bottom = Int(bottomZone) ?? 0
        let left = Int(leftZone) ?? 0
        let right = Int(rightZone) ?? 0
        
        let sides: [(String, Int)] = [
            ("top", top),
            ("bottom", bottom),
            ("left", left),
            ("right", right)
        ]
        
        let missing = sides.filter { $0.1 == 0 }
        if missing.count == 1 {
            switch missing[0].0 {
            case "top": return 1.0 - goldenRatio
            case "bottom": return goldenRatio
            default: return 0.5
            }
        }
        return 0.5
    }
    
    // Effect Settings
    @Published var selectedEffect: EffectType = .rainbow
    @Published var effectSpeeds: [EffectType: Double] = [
        .rainbow: 1.0, .breathing: 1.0, .marquee: 1.0, .knightRider: 1.0,
        .police: 1.0, .candle: 1.0, .plasma: 1.0, .strobe: 2.0,
        .atomic: 1.0, .fire: 1.0, .matrix: 1.0, .moodBlobs: 1.0,
        .pacman: 1.0, .snake: 1.0, .sparks: 1.0, .traces: 1.0,
        .trails: 1.0, .waves: 1.0, .collision: 1.0, .doubleSwirl: 1.0
    ]
    @Published var effectColors: [EffectType: Color] = [
        .rainbow: .red, .breathing: .blue, .marquee: .green, .knightRider: .red,
        .police: .blue, .candle: .orange, .plasma: .purple, .strobe: .white,
        .atomic: .cyan, .fire: .orange, .matrix: .green, .moodBlobs: .blue,
        .pacman: .yellow, .snake: .green, .sparks: .white, .traces: .blue,
        .trails: .red, .waves: .blue, .collision: .red, .doubleSwirl: .purple
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
    
    @Published var hasAutoDetected: Bool = false
    
    // Persistence
    @Published var wasRunning: Bool = false
    
    private enum ResumeTrigger {
        case none
        case afterSleep
        case afterDisplaySleep
        case afterLock
    }

    private var pendingResumeTrigger: ResumeTrigger = .none
    private var autoResumeScheduled = false

    let availableLanguages = [
        "System", "en", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru", "ja", "ko"
    ]
    
    func languageName(for code: String) -> String {
        switch code {
        case "System": return String(localized: "SYSTEM_LANGUAGE", locale: currentLocale)
        case "en": return "English"
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "de": return "Deutsch"
        case "fr": return "Français"
        case "es": return "Español"
        case "ru": return "Русский"
        case "ja": return "日本語"
        case "ko": return "한국어"
        default: return code
        }
    }
    
    private func updateLocale() {
        if appLanguage == "System" {
            currentLocale = .current
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            currentLocale = Locale(identifier: appLanguage)
            // Force the system to use the selected language on next launch
            UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
        }
    }
    
    private var isSending = false
    private let sendLock = NSLock()
    private var isCapturing = false // DEPRECATED
    private var cachedDisplay: SCDisplay?
    private var serialPort = SerialPort()
    private var screenCapture = ScreenCapture()
    private var audioProcessor = AudioProcessor()
    private var effectEngine = EffectEngine()
    
    private var loopTimer: AnyCancellable?
    private var currentColor: (r: UInt8, g: UInt8, b: UInt8)?
    
    private var lastSentData: [UInt8]?
    private var lastUIUpdateTime: TimeInterval = 0
    private var lastTransmitTime: TimeInterval = 0
    private var keepAliveTimer: Timer?
    private var lastConnectionAttempt: Date = .distantPast
    
    init() {
        let metalSupported = MetalProcessor.isSupported
        self.useMetal = metalSupported
        self.screenCapture.useMetal = metalSupported
        
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
        
        // Start Monitoring
        startHealthMonitor()

        // Setup Sleep/Wake Observers
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleScreensDidSleep()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleScreensDidWake()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSessionLocked()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSessionUnlocked()
        }
    }

    private func handleSleep() {
        pauseLighting(for: .afterSleep,
                      logMessage: "System going to sleep. Stopping lights.",
                      statusText: String(localized: "SYSTEM_SLEEPING"))
    }

    private func handleWake() {
        // Robustness: Force a delay to ensure USB subsystem and Displays are fully awake.
        // We also explicitly re-verify the serial connection status.
        Logger.shared.log("System woke up. Scheduling robust resume sequence.")
        
        // 1. Cancel any pending operations
        autoResumeScheduled = false
        
        // 2. Schedule tiered resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            
            // Check hardware health
            if !self.serialPort.isConnected || !self.serialPort.checkConnection() {
                Logger.shared.log("Wake: Serial port invalid. Attempting auto-reconnect.")
                // Trigger port refresh and reconnect logic if applicable
                // For now, we rely on the user or the existing 'start' logic to pick up the port,
                // but we should ensure internal state is clean.
                self.serialPort.disconnect() 
                
                // If we were running, let's try to restore the port connection if name persists
                if !self.selectedPort.isEmpty {
                     // small delay for port re-enumeration
                     DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                         _ = self.connectSerial()
                     }
                }
            }
            
            // Resume Capture Logic
            if self.wasRunning {
                // Ensure we clear the pending trigger so scheduleResumeIfNeeded doesn't conflict
                self.pendingResumeTrigger = .none
                
                Logger.shared.log("Wake: Resuming lighting...")
                self.start()
            }
        }
    }

    private func handleScreensDidSleep() {
        pauseLighting(for: .afterDisplaySleep,
                      logMessage: "Displays dimmed — pausing LEDs.",
                      statusText: String(localized: "DISPLAYS_SLEEPING"))
    }

    private func handleScreensDidWake() {
        scheduleResumeIfNeeded(after: .afterDisplaySleep,
                               resumeText: String(localized: "DISPLAYS_WAKING"))
    }

    private func handleSessionLocked() {
        pauseLighting(for: .afterLock,
                      logMessage: "Session locked. Keeping LEDs off.",
                      statusText: String(localized: "SESSION_LOCKED"))
    }

    private func handleSessionUnlocked() {
        scheduleResumeIfNeeded(after: .afterLock,
                               resumeText: String(localized: "SESSION_UNLOCKED"))
    }

    private func pauseLighting(for reason: ResumeTrigger, logMessage: String, statusText: String) {
        guard isRunning else { return }
        pendingResumeTrigger = reason
        wasRunning = true
        Logger.shared.log(logMessage)
        stop()
        statusMessage = statusText
    }

    private func scheduleResumeIfNeeded(after reason: ResumeTrigger, resumeText: String) {
        guard pendingResumeTrigger == reason else { return }
        pendingResumeTrigger = .none
        autoResumeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            guard self.autoResumeScheduled else { return }
            self.autoResumeScheduled = false
            guard self.wasRunning, !self.isRunning else { return }
            Logger.shared.log(resumeText)
            self.statusMessage = resumeText
            self.start()
            self.wasRunning = false
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
                statusMessage = String(localized: "SMART_FALLBACK_TRIGGERED")
                
                // Attempt to restart after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if !self.isRunning {
                        self.statusMessage = String(format: String(localized: "AUTO_RESTARTING"), Int(self.brightness * 100))
                        self.start()
                    }
                }
            } else {
                stop()
                statusMessage = String(localized: "CONNECTION_LOST")
            }
        }
    }
    
    func refreshPorts() {
        availablePorts = serialPort.listPorts()
        if selectedPort.isEmpty, let first = availablePorts.first {
            selectedPort = first
        }
    }
    
    func autoDetectBaudRate() {
        guard !selectedPort.isEmpty && selectedPort != "None" else { return }
        
        isProbingBaud = true
        lastBaudDetectionResult = nil
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Preferred order: Highest to lowest for better performance
            let ratesToTry = self.availableBaudRates.reversed()
            var detectedRate: String? = nil
            
            for rateStr in ratesToTry {
                if let rateInt = Int(rateStr) {
                    // Probing uses a non-blocking local session to verify handshake
                    if self.serialPort.probeBaudRate(path: self.selectedPort, baudRate: rateInt) {
                        detectedRate = rateStr
                        break
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.isProbingBaud = false
                if let rate = detectedRate {
                    self.baudRate = rate
                    self.lastBaudDetectionResult = true
                    
                    // Apply immediately if already running
                    if self.isRunning {
                        self.stop()
                        self.start()
                    }
                } else {
                    self.lastBaudDetectionResult = false
                }
            }
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
        if isRunning { 
            // If already running, just switch the mode logic
            switchMode()
            return 
        }
        
        // Critical UX: If starting in Sync mode, check permission BEFORE connecting hardware.
        // This prevents the "Flash -> Prompt" issue where the serial port opens (flashing LEDs)
        // while the user is still staring at a permission prompt.
        if currentMode == .sync {
            Task {
                // If we don't have permission and the system might prompt, do not connect yet.
                // Note: on some macOS versions, checking this might trigger the prompt.
                // We want the prompt to happen, but we want to wait for the result before flashing the hardware.
                let granted = await ScreenCapture.checkPermission()
                
                await MainActor.run {
                    if !granted {
                        self.statusMessage = String(localized: "PERMISSION_DENIED")
                        // Do not proceed to connectSerial
                    } else {
                        // Permission granted, now we can safely connect without UX jank
                        self.continueStart()
                    }
                }
            }
            return
        }
        
        continueStart()
    }
    
    private func continueStart() {
        statusMessage = String(localized: "CONNECTING")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if self.connectSerial() {
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.switchMode()
                }
            }
        }
    }
    
    private func switchMode() {
        self.statusMessage = String(format: String(localized: "RUNNING_MODE"), self.currentMode.localizedName)
        Logger.shared.log("Switching to mode: \(self.currentMode.rawValue)")
        
        // 1. Stop all current mode-specific engines and clear callbacks
        loopTimer?.cancel()
        loopTimer = nil
        
        sendLock.lock()
        lastSentData = nil // Clear last sent data to prevent keep-alive from sending old mode data
        sendLock.unlock()
        
        // Clear screen capture callback immediately to prevent old frames from being sent
        screenCapture.onFrameProcessed = nil
        
        Task {
            await self.screenCapture.stopStream()
        }
        
        self.audioProcessor.stop()
        self.effectEngine.stop()
        
        // 2. Small delay to ensure previous mode's last packets are cleared from serial buffer
        // and to allow async stopStream to progress.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isRunning else { return }
            
            // startKeepAlive() removed from here to prevent sending data before mode is ready/authorized
            
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
    
    func stop() {
        Logger.shared.log("Stopping")
        if autoResumeScheduled {
            autoResumeScheduled = false
        }
        isRunning = false
        statusMessage = String(localized: "STOPPED")
        
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
    
    // Restart Sync if settings change
    func restartSync() {
        if isRunning && currentMode == .sync {
            Task {
                await screenCapture.stopStream()
                startSync()
            }
        }
    }
    
    // MARK: - Sync Mode
    private func startSync() {
        // Check permission first
        Task {
            if await !ScreenCapture.checkPermission() {
                DispatchQueue.main.async {
                    self.statusMessage = String(localized: "PERMISSION_DENIED")
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
        guard isRunning && currentMode == .sync else { return }
        self.startKeepAlive()
        
        let config = ZoneConfig(
            left: Int(leftZone) ?? 0,
            top: Int(topZone) ?? 0,
            right: Int(rightZone) ?? 0,
            bottom: Int(bottomZone) ?? 0
        )
        let totalLeds = Int(ledCount) ?? 100
        let orientation = self.screenOrientation
        
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
                    self.statusMessage = String(localized: "NO_DISPLAY_FOUND")
                    self.stop()
                }
                return
            }
            
            await self.screenCapture.startStream(
                display: display,
                config: config,
                ledCount: totalLeds,
                orientation: orientation,
                brightness: self.syncBrightness,
                targetFrameRate: self.targetFrameRate,
                calibration: (self.calibrationR, self.calibrationG, self.calibrationB),
                gamma: self.gamma,
                saturation: self.saturation,
                originPreference: OriginPreference(mode: self.perspectiveOriginMode, manualNormalized: self.manualOriginPosition)
            )
        }
    }
    
    // MARK: - Music Mode
    private func startMusic() {
        guard isRunning && currentMode == .music else { return }
        self.startKeepAlive()
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
        guard isRunning && currentMode == .effect else { return }
        self.startKeepAlive()
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
        
        effectEngine.start(effect: selectedEffect, ledCount: totalLeds, speed: speed, color: (r, g, b), fps: targetFrameRate)
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
            start() // start() now handles switching logic if already running
        }
    }
    
    private func startManual() {
        guard isRunning && currentMode == .manual else { return }
        self.startKeepAlive()
        
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
        guard isRunning else { return }
        
        sendLock.lock()
        // Double check busy state to prevent flooding
        if isSending {
            sendLock.unlock()
            return
        }
        
        // Data Deduplication: Optimization for Transmit Buffer
        // If data is identical to last sent frame, skip sending to save bandwidth.
        // We only skip if the previous send actually succeeded and this is not a forced heartbeat.
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastSentData, last == data {
            // Heartbeat Logic: Force send if > 0.5s has passed since last transmit
            // This ensures lights don't time out during static scenes while avoiding bus flooding.
            if now - lastTransmitTime < 0.5 {
                sendLock.unlock()
                return
            }
        }
        
        isSending = true
        lastTransmitTime = now
        
        // Store original data for keep-alive to prevent recursive dimming
        self.lastSentData = data
        
        // Throttled UI Update (approx 30fps) - Only active if Debug Mode is enabled (Visualizer)
        if self.isDebugMode {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastUIUpdateTime > 0.033 {
                 lastUIUpdateTime = now
                 DispatchQueue.main.async { [data] in 
                     self.lastFrameColors = data 
                 }
            } else {
                 // Fallback for low framerates or initial state
                 if self.lastFrameColors.isEmpty {
                     lastUIUpdateTime = now
                     DispatchQueue.main.async { [data] in self.lastFrameColors = data }
                 }
            }
        }
        
        sendLock.unlock()
        
        var finalData = data
        
        // --- Patch Point 4: Unified Pipeline ---
        // If we are in Sync mode, Calibration, Gamma, and Saturation have already been applied 
        // in the ScreenCapture engine (before tone mapping) for better accuracy.
        // We only apply them here for non-sync modes.
        
        if currentMode != .sync {
            // 1. Apply Saturation Boost
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
            
            // 2. Apply Gamma Correction
            if gamma != 1.0 {
                for i in 0..<finalData.count {
                    let normalized = Double(finalData[i]) / 255.0
                    let corrected = pow(normalized, gamma) * 255.0
                    finalData[i] = UInt8(min(max(corrected, 0), 255))
                }
            }
            
            // 3. Apply Calibration
            if calibrationR != 1.0 || calibrationG != 1.0 || calibrationB != 1.0 {
                for i in stride(from: 0, to: finalData.count, by: 3) {
                    if i + 2 < finalData.count {
                        finalData[i] = UInt8(min(Double(finalData[i]) * calibrationR, 255.0))
                        finalData[i+1] = UInt8(min(Double(finalData[i+1]) * calibrationG, 255.0))
                        finalData[i+2] = UInt8(min(Double(finalData[i+2]) * calibrationB, 255.0))
                    }
                }
            }
        }
        
        // 4. Apply Power Management & Brightness (Always applied at the end)
        let effectiveBrightness = (currentMode == .sync) ? 1.0 : brightness // Sync brightness is already applied in ScreenCapture
        
        switch powerMode {
        case .abl:
            // Automatic Brightness Limiter
            var totalSum: Double = 0
            for byte in finalData {
                totalSum += Double(byte)
            }
            
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
                        self.limitReason = String(localized: "POWER_LIMITED_SMART")
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
            
        case .globalCap:
            let capBrightness = min(effectiveBrightness, powerLimit)
            
            if effectiveBrightness > powerLimit {
                DispatchQueue.main.async {
                    if !self.isPowerLimited {
                        self.isPowerLimited = true
                        self.limitReason = String(localized: "POWER_LIMITED_SAFE")
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
            
            if capBrightness < 1.0 {
                for i in 0..<finalData.count {
                    finalData[i] = UInt8(Double(finalData[i]) * capBrightness)
                }
            }
            
        case .smartFallback:
            DispatchQueue.main.async {
                if self.isPowerLimited {
                    self.isPowerLimited = false
                    self.limitReason = ""
                }
            }
            if effectiveBrightness < 1.0 {
                for i in 0..<finalData.count {
                    finalData[i] = UInt8(Double(finalData[i]) * effectiveBrightness)
                }
            }
        }
        
        serialPort.sendSkydimo(rgbData: finalData) { [weak self] in
            // Ensure we are back on main to update UI/State flags
            // Robustness: check if self still exists prevents crash in dealloc
            guard let self = self else { return }
            self.sendLock.lock()
            self.isSending = false
            self.sendLock.unlock()
        }
    }
    
    private func findValidBaudRate(for path: String) -> Int? {
        // 1. Try current baud rate first
        if let current = Int(baudRate), serialPort.probeBaudRate(path: path, baudRate: current) {
            return current
        }
        
        // 2. Scan available rates (High to Low for performance)
        for rateStr in availableBaudRates.reversed() {
            if let rateInt = Int(rateStr) {
                if serialPort.probeBaudRate(path: path, baudRate: rateInt) {
                    return rateInt
                }
            }
        }
        return nil
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
            // 1. Try the selected port first with current baud (Fast Path)
            if !selectedPort.isEmpty {
                let currentBaud = Int(baudRate) ?? 115200
                Logger.shared.log("Attempting direct connection to \(selectedPort) at \(currentBaud)")
                if serialPort.connect(path: selectedPort, baudRate: currentBaud) {
                    if handleSuccessfulConnection() { return true }
                }

                // 2. Fallback to probing if direct connection failed
                Logger.shared.log("Direct connection failed. Probing for valid baud on \(selectedPort)...")
                if let validBaud = findValidBaudRate(for: selectedPort) {
                    if serialPort.connect(path: selectedPort, baudRate: validBaud) {
                        if handleSuccessfulConnection() {
                            DispatchQueue.main.async { self.baudRate = String(validBaud) }
                            return true 
                        }
                    }
                }
            }
            
            // 3. If selected port failed or was empty, try auto-discovery
            Logger.shared.log("Target port unresponsive. Starting full auto-discovery...")
            let ports = serialPort.listPorts()
            for port in ports {
                if port == selectedPort { continue } // Already tried
                
                Logger.shared.log("Trying auto-discovery on \(port)")
                if let validBaud = findValidBaudRate(for: port) {
                    if serialPort.connect(path: port, baudRate: validBaud) {
                        if handleSuccessfulConnection() {
                            DispatchQueue.main.async {
                                self.selectedPort = port
                                self.baudRate = String(validBaud)
                                self.availablePorts = self.serialPort.listPorts()
                            }
                            return true
                        }
                    }
                }
            }
            
            Logger.shared.log("Connection Failed - No valid device found")
            DispatchQueue.main.async {
                self.statusMessage = String(localized: "CONNECTION_FAILED")
            }
            return false
        }
        return true
    }
    
    private func handleSuccessfulConnection() -> Bool {
        // Wait for device to settle (Arduino reset etc)
        usleep(1500000) // 1.5s
        
        // Handshake / Auto-detect
        if let info = serialPort.getDeviceInfo() {
            let parts = info.split(separator: ",")
            if let model = parts.first.map({ String($0) }) {
                DispatchQueue.main.async {
                    self.applyModelConfig(modelName: model)
                    self.statusMessage = String(format: String(localized: "CONNECTED"), model)
                }
                return true
            }
        }
        
        // If we connected but didn't get valid info, it might not be our device
        serialPort.disconnect()
        return false
    }
    
    func saveSettings() {
        UserDefaults.standard.set(selectedPort, forKey: "selectedPort")
        UserDefaults.standard.set(baudRate, forKey: "baudRate")
        UserDefaults.standard.set(ledCount, forKey: "ledCount")
        UserDefaults.standard.set(leftZone, forKey: "leftZone")
        UserDefaults.standard.set(topZone, forKey: "topZone")
        UserDefaults.standard.set(rightZone, forKey: "rightZone")
        UserDefaults.standard.set(bottomZone, forKey: "bottomZone")
        UserDefaults.standard.set(brightness, forKey: "brightness")
        UserDefaults.standard.set(syncBrightness, forKey: "syncBrightness")
        UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
        UserDefaults.standard.set(hasAutoDetected, forKey: "hasAutoDetected")
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
        UserDefaults.standard.set(perspectiveOriginMode.rawValue, forKey: "perspectiveOriginMode")
        UserDefaults.standard.set(manualOriginPosition, forKey: "manualOriginPosition")
        
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
        
        UserDefaults.standard.set(selectedMicrophoneUID, forKey: "selectedMicrophoneUID")
    }
    
    func loadSettings() {
        if let p = UserDefaults.standard.string(forKey: "selectedPort") { selectedPort = p }
        if let b = UserDefaults.standard.string(forKey: "baudRate") { baudRate = b }
        if let lang = UserDefaults.standard.string(forKey: "appLanguage") { 
            appLanguage = lang 
            updateLocale()
        }
        if let l = UserDefaults.standard.string(forKey: "ledCount") { ledCount = l }
        if let lz = UserDefaults.standard.string(forKey: "leftZone") { leftZone = lz }
        if let tz = UserDefaults.standard.string(forKey: "topZone") { topZone = tz }
        if let rz = UserDefaults.standard.string(forKey: "rightZone") { rightZone = rz }
        if let bz = UserDefaults.standard.string(forKey: "bottomZone") { bottomZone = bz }
        let br = UserDefaults.standard.double(forKey: "brightness")
        if br > 0 { brightness = br }
        let sbr = UserDefaults.standard.double(forKey: "syncBrightness")
        if sbr > 0 { syncBrightness = sbr }
        launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        hasAutoDetected = UserDefaults.standard.bool(forKey: "hasAutoDetected")
        
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

        if let originModeStr = UserDefaults.standard.string(forKey: "perspectiveOriginMode"), let originMode = PerspectiveOriginMode(rawValue: originModeStr) {
            perspectiveOriginMode = originMode
        }
        let manualOrigin = UserDefaults.standard.double(forKey: "manualOriginPosition")
        if manualOrigin >= 0 && manualOrigin <= 1 {
            manualOriginPosition = manualOrigin
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
                if !self.hasAutoDetected {
                    self.autoDetectDevice()
                    self.hasAutoDetected = true
                    self.saveSettings()
                } else {
                    self.start()
                }
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
            statusMessage = String(localized: "CONNECT_FIRST")
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
                        self.hasAutoDetected = true
                        self.saveSettings()
                        self.statusMessage = String(format: String(localized: "DETECTED"), modelName)
                        if wasRunning { self.start() }
                    }
                    return
                }
            } else {
                Logger.shared.log("Auto-detect failed: No response")
            }
            
            DispatchQueue.main.async {
                self.statusMessage = String(localized: "DETECTION_FAILED")
                if wasRunning { self.start() }
            }
        }
    }
    
    func applyModelConfig(modelName: String) {
        guard let config = skydimoModels[modelName] else {
            statusMessage = String(format: String(localized: "UNKNOWN_MODEL"), modelName)
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
    @Published var isTestingOrientation: Bool = false
    
    func startOrientationTest() {
        // Save current state
        let previousState = isRunning
        
        // Stop any running loop
        stop()
        isTestingOrientation = true
        
        statusMessage = String(localized: "CONNECTING")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if self.connectSerial() {
                DispatchQueue.main.async {
                    self.statusMessage = String(localized: "TESTING_ORIENTATION")
                    self.isRunning = true // Mark as running so stop button works
                    
                    var position = 0
                    var cycles = 0
                    let totalLeds = Int(self.ledCount) ?? 100
                    
                    self.loopTimer = Timer.publish(every: 0.05, on: .main, in: .common)
                        .autoconnect()
                        .sink { [weak self] _ in
                            guard let self = self else { return }
                            
                            if !self.isTestingOrientation {
                                self.stop()
                                return
                            }
                            
                            var data = [UInt8](repeating: 0, count: totalLeds * 3)
                            
                            // Draw a "Snake" of 10 pixels
                            let snakeLength = 10
                            for i in 0..<snakeLength {
                                let pixelIndex = (position - i + totalLeds) % totalLeds
                                // Head is white, tail fades to blue
                                if i == 0 {
                                    data[pixelIndex * 3] = UInt8(255 * self.calibrationR)
                                    data[pixelIndex * 3 + 1] = UInt8(255 * self.calibrationG)
                                    data[pixelIndex * 3 + 2] = UInt8(255 * self.calibrationB)
                                } else {
                                    let brightness = Double(snakeLength - i) / Double(snakeLength)
                                    data[pixelIndex * 3] = 0
                                    data[pixelIndex * 3 + 1] = 0
                                    data[pixelIndex * 3 + 2] = UInt8(255 * brightness * self.calibrationB)
                                }
                            }
                            
                            self.sendData(data)
                            position += 1
                            
                            // Check for completion (2 full loops)
                            if position >= totalLeds {
                                position = 0
                                cycles += 1
                                if cycles >= 2 {
                                    self.isTestingOrientation = false
                                    self.stop()
                                    self.statusMessage = String(localized: "TEST_COMPLETE")
                                    
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
            } else {
                DispatchQueue.main.async {
                    self.isTestingOrientation = false
                }
            }
        }
    }
    
    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        // Run keep-alive on the main thread loop but enforce thread safety in the closure
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            // Robustness: Strongly check self and lifecycle state
            // Often timers fire after deallocation if invalidate isn't atomic
            guard let self = self else { return }
            
            // Critical check: Do not execute if app thinks it's stopped
            guard self.isRunning else {
                return
            }
            
            // Check connection health before attempting to send
            if !self.serialPort.isConnected {
                 return
            }

            // Sync: Access shared state carefully
            // We use sendLock to safely access lastSentData and isSending from the main thread timer
            self.sendLock.lock()
            let dataToSend = self.lastSentData
            let currentlySending = self.isSending
            self.sendLock.unlock()
            
            if let data = dataToSend {
                // Prevent re-entry if the port is busy
                if !currentlySending {
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

    // MARK: - Health & Performance
    func resetStatistics() {
        serialPort.resetCounters()
        lastBytes = 0
        lastPackets = 0
        lastResetTime = Date()
        updateMetrics()
        Logger.shared.log("Performance statistics reset.")
    }

    private func startHealthMonitor() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateMetrics()
        }
    }
    
    private func updateMetrics() {
        let now = CACurrentMediaTime()
        let deltaTime = now - lastMetricTime
        lastMetricTime = now
        
        // RAM (Resident Size using Mach TASK_BASIC_INFO_64)
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let _ = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let ram = Double(taskInfo.resident_size) / 1024.0 / 1024.0
        
        // Serial Telemetry
        let currentBytes = serialPort.totalBytesSent
        let currentPackets = serialPort.totalPacketsSent
        
        let deltaBytes = (currentBytes >= lastBytes) ? (currentBytes - lastBytes) : 0
        let deltaPackets = (currentPackets >= lastPackets) ? (currentPackets - lastPackets) : 0
        
        lastBytes = currentBytes
        lastPackets = currentPackets
        
        let dataRateCalculation = (deltaTime > 0) ? (Double(deltaBytes) / 1024.0 / deltaTime) : 0.0
        let ppsCalculation = (deltaTime > 0) ? (Double(deltaPackets) / deltaTime) : 0.0
        
        let reportedFPS: Double
        if screenCapture.isStreaming && self.isRunning {
             // If we are actually capturing, report the target rate or calculate real time
             // For now, let's report the target rate unless we have a real counter from ScreenCapture
             // Since we don't have a public fps counter on ScreenCapture, we approximate.
             // But wait! If we rely on ScreenCaptureKit's adaptive rate, we might see 60 even if screen is static 
             // because we force it via minimumFrameInterval?
             reportedFPS = (ppsCalculation > 0) ? min(ppsCalculation, self.targetFrameRate) : 0
        } else {
             reportedFPS = 0
        }
        
        self.performanceMetrics = PerformanceMetrics(
            ramUsage: ram,
            fps: reportedFPS, // More accurate real-world FPS based on processed packets
            metalEnabled: self.useMetal,
            totalPackets: currentPackets,
            dataRate: dataRateCalculation,
            serialLatency: serialPort.lastWriteLatency * 1000.0, // to ms
            pps: ppsCalculation,
            writeErrors: serialPort.writeErrorCount,
            reconnects: serialPort.reconnectCount,
            bufferSize: serialPort.outputQueueSize
        )
        
        // Health Checks
        var checks: [HealthCheckItem] = []
        checks.append(HealthCheckItem(name: String(localized: "CHECK_SERIAL"), status: self.serialPort.isConnected, message: self.serialPort.isConnected ? String(localized: "HEALTH_GOOD") : String(localized: "HEALTH_ERROR")))
        checks.append(HealthCheckItem(name: String(localized: "CHECK_METAL"), status: self.useMetal, message: self.useMetal ? String(localized: "HEALTH_GOOD") : String(localized: "HEALTH_ERROR")))
        
        self.healthChecks = checks
    }
    
    // Process CPU time logic removed due to platform-specific accounting discrepancies
    
}

extension AppState: @unchecked Sendable {}
