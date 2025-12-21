import Foundation
import AVFoundation
import Accelerate

class AudioProcessor: NSObject {
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var fftSetup: vDSP_DFT_Setup?
    private let fftSize = 1024
    
    var onAudioLevel: ((Float) -> Void)?
    
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
        
        let format = input.inputFormat(forBus: 0)
        
        // Validate format
        if format.sampleRate == 0 || format.channelCount == 0 {
            print("Error: Invalid audio input format. Check microphone settings.")
            return
        }
        
        // Remove any existing tap just in case
        input.removeTap(onBus: 0)
        
        // Install tap
        input.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: format) { [weak self] (buffer, time) in
            self?.processAudio(buffer: buffer)
        }
        
        do {
            try engine.start()
        } catch {
            print("Audio engine start error: \(error)")
        }
    }
    
    private func processAudio(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        
        // Calculate RMS (Root Mean Square) for volume/energy
        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
        
        // Normalize a bit (experimental)
        let level = min(max(rms * 5, 0), 1.0)
        
        DispatchQueue.main.async {
            self.onAudioLevel?(level)
        }
    }
}
