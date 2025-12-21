import Foundation
import AVFoundation
import Accelerate
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

class AudioProcessor: NSObject {
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var fftSetup: vDSP_DFT_Setup?
    private let fftSize = 1024
    
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
                var name: String = "Unknown"
                var nameSize = UInt32(MemoryLayout<CFString>.size)
                var nameAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var nameRef: CFString = "" as CFString
                if AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr {
                    name = nameRef as String
                }
                
                // Get UID
                var uid: String = "\(id)"
                var uidSize = UInt32(MemoryLayout<CFString>.size)
                var uidAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var uidRef: CFString = "" as CFString
                if AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr {
                    uid = uidRef as String
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
                    print("Failed to set audio device: \(error)")
                }
            }
        }
        
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
