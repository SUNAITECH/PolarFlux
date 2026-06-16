import Foundation
import AVFoundation
import Accelerate
import CoreAudio

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
}

class AudioProcessor: NSObject {
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    // --- FFT pipeline ---
    // The README documents a Bass/Mid/Treble spectral decomposition, but the
    // previous implementation only computed an RMS level. This realises the
    // documented design using Accelerate's hardware-accelerated radix-2 FFT.
    private let fftSize = 1024
    private let log2n: UInt = 10
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float] = []
    private var sampleRate: Double = 48000
    private var sampleBuffer = [Float]()

    /// Number of log-spaced spectrum bins exposed to consumers.
    static let spectrumBins = 64

    /// Provides full realtime analysis. Replaces the legacy single-value callback.
    var onAudioFrame: ((AudioFrame) -> Void)?
    /// Legacy single-level callback (kept for compatibility; mirrors `level`).
    var onAudioLevel: ((Float) -> Void)?
    var currentDeviceID: AudioDeviceID?

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

    func start() {
        requestPermission { [weak self] granted in
            guard granted else { return }
            self?.setupAudio()
        }
    }

    func stop() {
        if let input = inputNode {
            input.removeTap(onBus: 0)
        }
        engine?.stop()
        engine = nil
        inputNode = nil
        sampleBuffer.removeAll(keepingCapacity: true)
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
        if self.fftSetup == nil {
            self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        }
        if self.hannWindow.isEmpty {
            var window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            self.hannWindow = window
        }

        // Remove any existing tap just in case
        input.removeTap(onBus: 0)

        // Install tap
        input.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: format) { [weak self] (buffer, _) in
            self?.processAudio(buffer: buffer)
        }

        do {
            try engine.start()
        } catch {
            Logger.shared.log("Audio engine start error: \(error)")
        }
    }

    private func processAudio(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)

        // Overall RMS for the legacy level value.
        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
        let level = min(max(rms * 5, 0), 1.0)

        // Accumulate samples until we have a full FFT window.
        sampleBuffer.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameLength))
        guard sampleBuffer.count >= fftSize else {
            // Not enough samples yet — emit the plain level so Music mode still reacts.
            let frame = AudioFrame(level: level, bass: level, mid: level, treble: level,
                                   spectrum: [Float](repeating: level, count: Self.spectrumBins),
                                   sampleRate: sampleRate)
            DispatchQueue.main.async { [weak self] in
                self?.onAudioFrame?(frame)
                self?.onAudioLevel?(level)
            }
            return
        }

        // Keep only the newest fftSize samples.
        if sampleBuffer.count > fftSize {
            let overflow = sampleBuffer.count - fftSize
            sampleBuffer.removeFirst(overflow)
        }

        let frame = analyzeSpectrum(fallbackLevel: level)
        DispatchQueue.main.async { [weak self] in
            self?.onAudioFrame?(frame)
            self?.onAudioLevel?(frame.level)
        }
    }

    /// Window the latest samples, run a real-input FFT, and reduce to bands + a
    /// normalised log-spaced spectrum. Falls back to `fallbackLevel` when the FFT
    /// setup is unavailable.
    private func analyzeSpectrum(fallbackLevel: Float) -> AudioFrame {
        let half = fftSize / 2

        guard let setup = fftSetup else {
            return AudioFrame(level: fallbackLevel, bass: fallbackLevel, mid: fallbackLevel,
                              treble: fallbackLevel,
                              spectrum: [Float](repeating: fallbackLevel, count: Self.spectrumBins),
                              sampleRate: sampleRate)
        }

        // Apply Hann window.
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(sampleBuffer, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack the real windowed signal into a split-complex buffer
        // (even samples -> realp, odd samples -> imagp). This replaces the
        // deprecated vDSP_ctoz with a small, dependency-free loop.
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        for i in 0..<half {
            realp[i] = windowed[i * 2]
            imagp[i] = windowed[i * 2 + 1]
        }

        var magnitudes = [Float](repeating: 0, count: half)
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                guard let realBase = realBuf.baseAddress,
                      let imagBase = imagBuf.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Magnitudes of the first `half` bins (pointers remain valid here).
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Perceptual mapping: dB -> clamped to [minDB, 0] -> normalised 0...1.
        let minDB: Float = -80
        var normalized = [Float](repeating: 0, count: half)
        for i in 0..<half {
            let db = 20 * log10(max(magnitudes[i], 1e-7))
            let clamped = min(max(db, minDB), 0)
            normalized[i] = (clamped - minDB) / -minDB // 0 (quiet) ... 1 (loud)
        }

        // Band edges (Hz).
        let binHz = sampleRate / Double(fftSize)
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

        // Log-spaced spectrum of `spectrumBins` bins spanning ~30Hz..nyquist.
        let spectrum = makeLogSpectrum(normalized: normalized, half: half)

        // Level estimate from band presence (more musical than pure RMS).
        let musicalLevel = min(max(0.4 * bass + 0.4 * mid + 0.2 * treble, 0), 1)

        return AudioFrame(level: musicalLevel, bass: bass, mid: mid, treble: treble,
                          spectrum: spectrum, sampleRate: sampleRate)
    }

    private func makeLogSpectrum(normalized: [Float], half: Int) -> [Float] {
        let bins = Self.spectrumBins
        var spectrum = [Float](repeating: 0, count: bins)
        let startHz = 30.0
        let endHz = sampleRate / 2.0
        let logStart = log(startHz)
        let logEnd = log(endHz)
        let binHz = sampleRate / Double(fftSize)
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

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }
}
