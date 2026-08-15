import Foundation
import AVFoundation
import Accelerate
import CoreAudio
import ScreenCaptureKit
import CoreMedia

/// Where Music mode gets its signal from.
/// `.system` captures what the Mac is *playing* via ScreenCaptureKit loopback
/// (no microphone permission needed once Screen Recording is granted);
/// `.microphone` uses the classic AVAudioEngine input-tap path.
enum AudioSource: String, CaseIterable, Identifiable {
    case system = "AUDIO_SOURCE_SYSTEM"
    case microphone = "AUDIO_SOURCE_MICROPHONE"

    var id: String { rawValue }
    var localizedName: String {
        String(localized: String.LocalizationValue(self.rawValue))
    }
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

/// Frequency-band decomposition produced by the realtime FFT pipeline.
struct AudioFrame {
    /// Overall normalised loudness (0...1) — the legacy RMS level.
    let level: Float
    /// Bass / Mid / Treble energy (0...1), derived from an Accelerate FFT.
    let bass: Float
    let mid: Float
    let treble: Float
    /// Log-spaced magnitude spectrum, normalised to 0...1. Fixed length so the
    /// consumer (LED driver) can resample to its strip length.
    let spectrum: [Float]
    /// Sample rate used to produce the spectrum (Hz), for accurate band splits.
    let sampleRate: Double

    // --- Advanced DSP extensions (defaults keep legacy call sites compiling) ---
    /// 0...1 strength of the most recent detected beat (0 when none).
    var beatIntensity: Float = 0
    /// True on the frame where a beat onset was detected.
    var isBeat: Bool = false
    /// Log-normalised spectral centroid: 0 = bass-dominated, 1 = treble-dominated.
    var centroid: Float = 0.5
}

class AudioProcessor: NSObject {
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var systemAudio = SystemAudioCapture()

    // --- FFT pipeline ---
    private let fftSize = 1024
    private let log2n: UInt = 10
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []
    private var sampleRate: Double = 48000

    /// Number of log-spaced spectrum bins exposed to consumers.
    static let spectrumBins = 64

    // --- Realtime-safe sample ingestion ---
    // Producers (the AVAudioEngine tap runs on a realtime-ish render thread and
    // the ScreenCaptureKit audio queue) must never allocate or block. They only
    // copy into this preallocated ring buffer under a short-duration lock and
    // coalesce-schedule analysis on a private serial queue.
    private var ring = [Float](repeating: 0, count: 4096)
    private var ringWriteIndex = 0
    private var ringCount = 0
    private let ringLock = NSLock()
    private var analysisScheduled = false
    private let analysisQueue = DispatchQueue(label: "com.sunaish.polarflux.audio.analysis", qos: .userInteractive)

    // Scratch buffers reused by the analysis pass (analysis queue only).
    private var analysisWindow = [Float](repeating: 0, count: 1024)
    private var windowed = [Float](repeating: 0, count: 1024)
    private var realp = [Float](repeating: 0, count: 512)
    private var imagp = [Float](repeating: 0, count: 512)
    private var magnitudes = [Float](repeating: 0, count: 512)
    private var normalized = [Float](repeating: 0, count: 512)

    // --- Adaptive DSP state (analysis queue only) ---
    /// Slow-falling loudness ceiling for auto-gain (quiet tracks still light up).
    private var agcPeak: Float = 0.15
    /// Per-bin falling-peak memory: bars rise instantly, fall gracefully.
    private var peakHold = [Float](repeating: 0, count: AudioProcessor.spectrumBins)
    /// Rolling bass-energy history (~1s) for adaptive beat thresholds.
    private var bassHistory: [Float] = []
    private var lastBeatTime: Double = 0

    /// Provides full realtime analysis. Called on the internal analysis queue.
    var onAudioFrame: ((AudioFrame) -> Void)?
    /// Legacy single-level callback (kept for compatibility; mirrors `level`).
    var onAudioLevel: ((Float) -> Void)?
    /// Fired when system-audio capture could not start (permission/availability)
    /// and the processor fell back to the microphone.
    var onSystemAudioFallback: (() -> Void)?
    var currentDeviceID: AudioDeviceID?

    // MARK: - Sample ingestion (producer side)

    /// Copies `count` PCM samples into the analysis ring and schedules analysis.
    /// Safe to call from realtime-adjacent threads: no allocation, one short lock.
    func ingest(samples: UnsafePointer<Float>?, count: Int, sampleRate: Double) {
        guard let samples, count > 0, sampleRate > 0 else { return }

        ringLock.lock()
        if abs(sampleRate - self.sampleRate) > 1.0 {
            // Input changed (device switch): drop stale buffered audio.
            self.sampleRate = sampleRate
            ringCount = 0
            ringWriteIndex = 0
        }
        let capacity = ring.count
        for i in 0..<count {
            ring[ringWriteIndex] = samples[i]
            ringWriteIndex = (ringWriteIndex + 1) % capacity
        }
        ringCount = min(ringCount + count, capacity)

        if !analysisScheduled {
            analysisScheduled = true
            ringLock.unlock()
            analysisQueue.async { [weak self] in
                self?.runAnalysis()
            }
        } else {
            ringLock.unlock()
        }
    }

    // MARK: - Analysis (consumer side, serial queue)

    private func runAnalysis() {
        while true {
            let copied = consumeNewestSamples(&analysisWindow)
            if copied < fftSize {
                // Not enough for a full window: park the scheduler unless the
                // producer refilled the ring past the threshold meanwhile.
                ringLock.lock()
                let hasFullWindow = ringCount >= fftSize
                if !hasFullWindow {
                    analysisScheduled = false
                }
                ringLock.unlock()
                if !hasFullWindow { return }
                continue
            }

            let frame = analyze(window: analysisWindow)
            onAudioFrame?(frame)
            onAudioLevel?(frame.level)
        }
    }

    /// Consumes one full FFT window of the NEWEST samples if — and only if —
    /// enough have accumulated. Partial data is left in the ring to grow into
    /// the next window: consuming it would starve the FFT forever when the
    /// producer delivers chunks smaller than the window (ScreenCaptureKit
    /// typically delivers ~512-frame callbacks), which rendered Music mode
    /// completely dark. Stale excess beyond one window is dropped so analysis
    /// always runs on fresh audio.
    private func consumeNewestSamples(_ buffer: inout [Float]) -> Int {
        let wanted = min(buffer.count, fftSize)
        ringLock.lock()
        defer { ringLock.unlock() }

        guard ringCount >= wanted else { return 0 }

        let skip = ringCount - wanted
        let capacity = ring.count
        let start = ((ringWriteIndex - wanted) % capacity + capacity) % capacity
        if start + wanted <= capacity {
            for i in 0..<wanted { buffer[i] = ring[start + i] }
        } else {
            let first = capacity - start
            for i in 0..<first { buffer[i] = ring[start + i] }
            for i in 0..<(wanted - first) { buffer[first + i] = ring[i] }
        }
        // The window plus any skipped stale samples are all consumed.
        ringCount = 0
        return wanted
    }

    /// Runs the full pipeline on a filled window: RMS → Hann → FFT → dB →
    /// auto-gain → bands → log spectrum → peak-hold → beat detection → centroid.
    private func analyze(window: [Float]) -> AudioFrame {
        let half = fftSize / 2

        // Snapshot the rate under the ring lock: producers may switch input
        // devices (and thus the rate) concurrently on their own thread.
        ringLock.lock()
        let rate = sampleRate
        ringLock.unlock()

        // Overall RMS for the legacy level value.
        var rms: Float = 0
        vDSP_rmsqv(window, 1, &rms, vDSP_Length(window.count))
        let level = min(max(rms * 5, 0), 1.0)

        guard let setup = fftSetup else {
            let flat = [Float](repeating: level, count: Self.spectrumBins)
            return AudioFrame(level: level, bass: level, mid: level, treble: level,
                              spectrum: flat, sampleRate: rate)
        }

        // Apply Hann window.
        vDSP_vmul(window, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack the real windowed signal into a split-complex buffer
        // (even samples -> realp, odd samples -> imagp). This replaces the
        // deprecated vDSP_ctoz with a small, dependency-free loop.
        for i in 0..<half {
            realp[i] = windowed[i * 2]
            imagp[i] = windowed[i * 2 + 1]
        }

        magnitudes.withUnsafeMutableBufferPointer { magBuf in
            realp.withUnsafeMutableBufferPointer { realBuf in
                imagp.withUnsafeMutableBufferPointer { imagBuf in
                    guard let realBase = realBuf.baseAddress,
                          let imagBase = imagBuf.baseAddress,
                          let magBase = magBuf.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, magBase, 1, vDSP_Length(half))
                }
            }
        }

        // Perceptual mapping: dB -> clamped to [minDB, 0] -> normalised 0...1.
        let minDB: Float = -80
        for i in 0..<half {
            let db = 20 * log10(max(magnitudes[i], 1e-7))
            let clamped = min(max(db, minDB), 0)
            normalized[i] = (clamped - minDB) / -minDB // 0 (quiet) ... 1 (loud)
        }

        // --- Auto Gain Control ---
        // Track a slow-falling ceiling of frame loudness and boost quiet input,
        // so both whisper-level and party-level volumes drive the LEDs well.
        var framePeak: Float = 0
        vDSP_maxv(normalized, 1, &framePeak, vDSP_Length(half))
        agcPeak = max(framePeak, agcPeak * 0.9995)
        let gain = min(0.85 / max(agcPeak, 0.02), 6.0)
        if gain > 1.01 {
            var g = gain
            var lo: Float = 0
            var hi: Float = 1
            vDSP_vsmul(normalized, 1, &g, &normalized, 1, vDSP_Length(half))
            vDSP_vclip(normalized, 1, &lo, &hi, &normalized, 1, vDSP_Length(half))
        }

        // Band edges (Hz).
        let binHz = rate / Double(fftSize)
        func bin(_ hz: Double) -> Int { min(max(Int(hz / binHz), 1), half - 1) }
        let bassEnd = bin(200.0)
        let midEnd = bin(2000.0)

        var bass: Float = 0, mid: Float = 0, treble: Float = 0
        for i in 0..<bassEnd { bass += normalized[i] }
        for i in bassEnd..<midEnd { mid += normalized[i] }
        for i in midEnd..<half { treble += normalized[i] }
        bass /= Float(max(bassEnd, 1))
        mid /= Float(max(midEnd - bassEnd, 1))
        treble /= Float(max(half - midEnd, 1))

        // --- Spectral centroid (log-normalised) ---
        var num: Float = 0, den: Float = 0
        for i in 1..<half {
            let f = Float(i) * Float(binHz)
            num += f * normalized[i]
            den += normalized[i]
        }
        let centroidHz = den > 1e-6 ? num / den : 1000
        let centroidNorm = (log(max(Double(centroidHz), 80)) - log(80)) / (log(12000) - log(80))

        // --- Beat detection (adaptive energy threshold on the bass band) ---
        bassHistory.append(bass)
        if bassHistory.count > 50 { bassHistory.removeFirst(bassHistory.count - 50) }
        var mean: Float = 0
        for v in bassHistory { mean += v }
        mean /= Float(max(bassHistory.count, 1))
        var varAcc: Float = 0
        for v in bassHistory { let d = v - mean; varAcc += d * d }
        let std = sqrt(varAcc / Float(max(bassHistory.count, 1)))
        let threshold = mean + 1.45 * std

        let now = CACurrentMediaTime()
        var isBeat = false
        var beatIntensity: Float = 0
        if bass > threshold, bass > 0.18, bassHistory.count >= 12,
           now - lastBeatTime > 0.16 {
            isBeat = true
            beatIntensity = min(max((bass - threshold) / max(threshold, 0.05), 0), 1)
            lastBeatTime = now
        }

        // --- Log spectrum + falling peak-hold (analyser-style decay) ---
        var spectrum = makeLogSpectrum(normalized: normalized, half: half, rate: rate)
        let dtFrames = Float(fftSize) / Float(max(rate, 1))
        let fall = 1.1 * dtFrames
        for i in 0..<spectrum.count {
            peakHold[i] = max(spectrum[i], peakHold[i] - fall)
            spectrum[i] = peakHold[i]
        }

        // Level estimate from band presence (more musical than pure RMS).
        let musicalLevel = min(max(0.4 * bass + 0.4 * mid + 0.2 * treble, 0), 1)

        return AudioFrame(level: musicalLevel, bass: bass, mid: mid, treble: treble,
                          spectrum: spectrum, sampleRate: rate,
                          beatIntensity: beatIntensity, isBeat: isBeat,
                          centroid: Float(min(max(centroidNorm, 0), 1)))
    }

    private func makeLogSpectrum(normalized: [Float], half: Int, rate: Double) -> [Float] {
        let bins = Self.spectrumBins
        var spectrum = [Float](repeating: 0, count: bins)
        let startHz = 30.0
        let endHz = rate / 2.0
        let logStart = log(startHz)
        let logEnd = log(endHz)
        let binHz = rate / Double(fftSize)
        for i in 0..<bins {
            let f0 = exp(logStart + (Double(i) / Double(bins)) * (logEnd - logStart))
            let f1 = exp(logStart + (Double(i + 1) / Double(bins)) * (logEnd - logStart))
            let lo = max(Int(f0 / binHz), 1)
            let hi = min(Int(f1 / binHz), half - 1)
            if hi <= lo {
                spectrum[i] = normalized[min(lo, half - 1)]
                continue
            }
            var sum: Float = 0
            for j in lo..<hi { sum += normalized[j] }
            spectrum[i] = sum / Float(hi - lo)
        }
        return spectrum
    }

    // MARK: - Device enumeration (microphones)

    func getAvailableInputs() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        let status2 = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        guard status2 == noErr else { return [] }

        var devices: [AudioInputDevice] = []

        for id in deviceIDs {
            // Check if input channels > 0
            var inputChannels: UInt32 = 0
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var size = UInt32(0)
            if AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0 {
                let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
                if AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr {
                    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                    for buffer in buffers {
                        inputChannels += buffer.mNumberChannels
                    }
                }
                bufferList.deallocate()
            }

            if inputChannels > 0 {
                // Get Name
                var name: String = String(localized: "UNKNOWN")
                var nameSize = UInt32(MemoryLayout<CFString>.size)
                var nameAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var nameRef: Unmanaged<CFString>?
                if AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr {
                    if let ref = nameRef {
                        name = ref.takeRetainedValue() as String
                    }
                }

                // Get UID
                var uid: String = "\(id)"
                var uidSize = UInt32(MemoryLayout<CFString>.size)
                var uidAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var uidRef: Unmanaged<CFString>?
                if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr {
                    if let ref = uidRef {
                        uid = ref.takeRetainedValue() as String
                    }
                }

                devices.append(AudioInputDevice(id: id, name: name, uid: uid))
            }
        }

        return devices
    }

    func setDevice(id: AudioDeviceID) {
        if currentDeviceID != id {
            currentDeviceID = id
            // Restart if running
            if engine != nil {
                setupAudio()
            }
        }
    }

    // MARK: - Lifecycle

    /// Monotonic token serialising async start sequences. A start that began
    /// earlier must never clobber the state of a newer one (e.g. system-audio
    /// fallback racing a user source switch mid-startup).
    private var startGeneration = 0

    /// Idempotently creates every DSP resource the analysis pass needs.
    ///
    /// Historically these lived inside `setupAudio()` (microphone path only),
    /// which meant the system-audio path ran with `fftSetup == nil` and silently
    /// degraded to flat-level frames. Both paths now call this.
    /// Internal-for-testing: the audio pipeline regression test drives the
    /// system-audio path shape directly (resources + ring ingest, no capture).
    func ensureDSPResources() {
        ringLock.lock()
        let rate = sampleRate
        ringLock.unlock()

        if fftSetup == nil {
            fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
            if fftSetup == nil {
                Logger.shared.log("AudioProcessor: FAILED to create FFT setup — spectrum analysis unavailable")
            }
        }
        if hannWindow.isEmpty {
            var window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            hannWindow = window
        }
        _ = rate // (rate is read under lock purely for future per-rate windows)
    }

    func start(source: AudioSource = .microphone) {
        startGeneration += 1
        let generation = startGeneration

        switch source {
        case .system:
            Task { [weak self] in
                guard let self = self else { return }
                let ok = await self.startSystemAudio()
                guard generation == self.startGeneration else { return }
                if !ok {
                    Logger.shared.log("System audio unavailable — falling back to microphone.")
                    self.onSystemAudioFallback?()
                    guard generation == self.startGeneration else { return }
                    self.requestPermission { [weak self] granted in
                        guard let self = self, granted else { return }
                        guard generation == self.startGeneration else { return }
                        self.setupAudio()
                    }
                }
            }
        case .microphone:
            requestPermission { [weak self] granted in
                guard let self = self, granted else { return }
                guard generation == self.startGeneration else { return }
                self.setupAudio()
            }
        }
    }

    private func startSystemAudio() async -> Bool {
        stop()
        ensureDSPResources()
        systemAudio.onAudio = { [weak self] samples, count, rate in
            self?.ingest(samples: samples, count: count, sampleRate: rate)
        }
        do {
            try await systemAudio.start()
            Logger.shared.log("AudioProcessor: system-audio capture active")
            return true
        } catch {
            Logger.shared.log("SystemAudioCapture failed to start: \(error.localizedDescription)")
            systemAudio.onAudio = nil
            return false
        }
    }

    func stop() {
        // Invalidate any in-flight async start: if startSystemAudio() is
        // suspended at an await when stop() runs, its post-resume guards
        // must fail instead of re-activating engines the user just stopped.
        startGeneration += 1
        if let input = inputNode {
            input.removeTap(onBus: 0)
        }
        engine?.stop()
        engine = nil
        inputNode = nil
        systemAudio.stop()
        systemAudio.onAudio = nil

        ringLock.lock()
        ringCount = 0
        ringWriteIndex = 0
        ringLock.unlock()

        // Reset adaptive DSP state so a fresh session doesn't inherit old filters.
        bassHistory.removeAll()
        for i in 0..<peakHold.count { peakHold[i] = 0 }
        agcPeak = 0.15
    }

    private func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    private func setupAudio() {
        // Ensure previous engine is cleaned up
        stop()

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        self.inputNode = input

        // Set Device if specified
        if let deviceID = currentDeviceID {
            if let inputUnit = input.audioUnit {
                var id = deviceID
                let error = AudioUnitSetProperty(inputUnit,
                                     kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global,
                                     0,
                                     &id,
                                     UInt32(MemoryLayout<AudioDeviceID>.size))
                if error != noErr {
                    Logger.shared.log("Failed to set audio device: \(error)")
                }
            }
        }

        let format = input.outputFormat(forBus: 0)

        // Validate format
        if format.sampleRate == 0 || format.channelCount == 0 {
            Logger.shared.log("Error: Invalid audio input format. Check microphone settings.")
            return
        }

        self.sampleRate = format.sampleRate
        ensureDSPResources()

        // Remove any existing tap just in case
        input.removeTap(onBus: 0)

        // Install tap. The closure only copies samples into the preallocated
        // ring buffer — FFT work happens on the dedicated analysis queue.
        input.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: format) { [weak self] (buffer, _) in
            guard let self = self, let channelData = buffer.floatChannelData?[0] else { return }
            self.ingest(samples: channelData,
                        count: Int(buffer.frameLength),
                        sampleRate: buffer.format.sampleRate)
        }

        do {
            try engine.start()
        } catch {
            Logger.shared.log("Audio engine start error: \(error)")
        }
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }
}
