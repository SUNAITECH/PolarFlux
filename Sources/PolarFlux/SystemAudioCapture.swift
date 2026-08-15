import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import QuartzCore

/// Captures the audio a Mac is *playing* (system output loopback) using
/// ScreenCaptureKit — no microphone permission and no virtual audio driver
/// required. Screen Recording permission is needed (shared with Sync mode).
///
/// The captured PCM is handed to the consumer via `onAudio` on SCK's own
/// delivery queue; heavy analysis must be performed elsewhere (the
/// `AudioProcessor` ingests it into its realtime-safe ring buffer).
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    /// PCM float samples (mono mixdown), delivered on SCK's queue.
    var onAudio: ((UnsafePointer<Float>?, Int, Double) -> Void)?

    private var stream: SCStream?
    private let streamLock = NSLock()

    // Scratch mixdown buffer reused per callback (SCK queue only).
    private var mixdown = [Float](repeating: 0, count: 4096)

    var isRunning: Bool {
        streamLock.lock()
        defer { streamLock.unlock() }
        return stream != nil
    }

    /// Starts capturing system audio at SCK's preferred rate.
    /// Throws when screen-recording permission is missing or no display exists.
    func start() async throws {
        stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "PolarFlux.SystemAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for audio capture"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48000
        // Never feed our own (silent) output back into analysis.
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)

        try await stream.startCapture()

        setStream(stream)
        Logger.shared.log("SystemAudioCapture: started (loopback via ScreenCaptureKit)")
    }

    func stop() {
        let current = takeStream()

        guard let current = current else { return }
        Task {
            try? await current.stopCapture()
        }
    }

    // Lock-scoped accessors (synchronous only, so they stay Swift-6 clean).
    private func setStream(_ stream: SCStream) {
        streamLock.lock()
        self.stream = stream
        streamLock.unlock()
    }

    private func takeStream() -> SCStream? {
        streamLock.lock()
        defer { streamLock.unlock() }
        let current = stream
        stream = nil
        return current
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamLock.lock()
        let wasActive = self.stream != nil
        self.stream = nil
        streamLock.unlock()

        if wasActive {
            Logger.shared.log("SystemAudioCapture stopped: \(error.localizedDescription)")
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        deliverPCM(from: sampleBuffer)
    }

    // Pipeline diagnostics: counts at every stage so a silent failure anywhere
    // (permission, buffer layout, empty data) is visible in the log.
    private var cbCount = 0
    private var deliveredFrames = 0
    private var lastDiagTime: Double = 0

    private func deliverPCM(from sampleBuffer: CMSampleBuffer) {
        cbCount += 1

        // Query the buffer-list size SCK actually needs. Passing a fixed
        // MemoryLayout<AudioBufferList>.size fails with
        // kCMSampleBufferError_ArrayTooSmall whenever the stream delivers more
        // than one AudioBuffer, silently producing zero audio.
        var neededSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, neededSize > 0 else {
            diagnoseIfNeeded { Logger.shared.log("SystemAudioCapture: cannot query audio layout (status \(status))") }
            return
        }

        let rate = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
            ?? 48000

        var listStorage = [UInt8](repeating: 0, count: neededSize)
        var blockBuffer: CMBlockBuffer?
        var deliveredFramesThisCall = 0

        // All pointer use stays inside withUnsafeMutableBytes: the borrowed
        // pointer is only valid for the closure's scope.
        listStorage.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let listPtr = base.assumingMemoryBound(to: AudioBufferList.self)

            var extractStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: listPtr,
                bufferListSize: neededSize,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard extractStatus == noErr else {
                status = extractStatus
                return
            }

            let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
            for buffer in buffers where buffer.mNumberChannels > 0 && buffer.mData != nil && buffer.mDataByteSize > 0 {
                let pcm = buffer.mData!.assumingMemoryBound(to: Float.self)
                let totalSamples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let channels = Int(buffer.mNumberChannels)

                if channels >= 2 {
                    // Interleaved multi-channel → mono mixdown (first two channels).
                    let frames = totalSamples / channels
                    guard frames > 0 else { continue }
                    if mixdown.count < frames { mixdown = [Float](repeating: 0, count: frames) }
                    for i in 0..<frames {
                        mixdown[i] = (pcm[i * channels] + pcm[i * channels + 1]) * 0.5
                    }
                    mixdown.withUnsafeBufferPointer { buf in
                        onAudio?(buf.baseAddress, frames, rate)
                    }
                    deliveredFramesThisCall = frames
                } else {
                    onAudio?(pcm, totalSamples, rate)
                    deliveredFramesThisCall = totalSamples
                }
                // Only the first non-empty buffer is consumed (SCK delivers interleaved PCM).
                break
            }
        }

        guard deliveredFramesThisCall > 0 else {
            diagnoseIfNeeded { Logger.shared.log("SystemAudioCapture: audio extraction produced no PCM (status \(status))") }
            return
        }
        deliveredFrames += deliveredFramesThisCall
        diagnoseIfNeeded { [deliveredFrames, cbCount] in
            Logger.shared.log("SystemAudioCapture: healthy — \(cbCount) callbacks, \(deliveredFrames) frames total")
        }
    }

    /// Logs a stage diagnostic at most ~1x per 5s to keep the log readable.
    private func diagnoseIfNeeded(_ message: @escaping () -> Void) {
        let now = CACurrentMediaTime()
        if now - lastDiagTime > 5.0 {
            lastDiagTime = now
            message()
        }
    }
}
