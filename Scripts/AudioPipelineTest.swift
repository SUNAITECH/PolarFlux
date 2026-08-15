// AudioPipelineTest.swift
// Deterministic end-to-end test for PolarFlux's Music-mode DSP pipeline.
//
// Drives AudioProcessor.ingest() with synthesized PCM (no microphone, no
// ScreenCaptureKit permission needed) and asserts the FULL chain:
// ring buffer → Hann window → FFT → dB normalisation → AGC → log spectrum
// → peak-hold → beat detection.
//
// The regression this guards against: DSP resources (fftSetup/hannWindow)
// were historically only initialised on the microphone path, so the
// system-audio path silently produced degenerate flat frames (or, with a
// buffer-layout failure upstream, no frames at all) — dark LEDs in Music
// mode with system sound playing.
//
// Run via: ./Scripts/run.sh test

import Foundation
import Accelerate

// Watchdog: any deadlock in the analysis scheduler must fail, not hang CI.
DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
    FileHandle.standardError.write("FAIL: watchdog fired — audio pipeline deadlock\n".data(using: .utf8)!)
    exit(52)
}

final class FrameSink {
    private let l = NSLock()
    private var frames: [AudioFrame] = []
    func append(_ f: AudioFrame) { l.lock(); frames.append(f); l.unlock() }
    var count: Int { l.lock(); defer { l.unlock() }; return frames.count }
    var last: AudioFrame? { l.lock(); defer { l.unlock() }; return frames.last }
    var all: [AudioFrame] { l.lock(); defer { l.unlock() }; return frames }
}

func spectrumSpread(_ s: [Float]) -> Float {
    guard s.count > 1 else { return 0 }
    var mean: Float = 0
    vDSP_meanv(s, 1, &mean, vDSP_Length(s.count))
    var acc: Float = 0
    for v in s { let d = v - mean; acc += d * d }
    return sqrt(acc / Float(s.count))
}

// ---------------------------------------------------------------------------
// Test 1: system-audio path resources. Historically ensureDSPResources() was
// reachable only via setupAudio() (mic path); the system path produced flat
// fallback frames. A real FFT frame has significant spread across bins.
// ---------------------------------------------------------------------------
let processor = AudioProcessor()
let sink = FrameSink()
processor.onAudioFrame = { sink.append($0) }

// Simulate the system path exactly: no setupAudio(), just ensure the DSP
// resources exist and feed the ingest ring like SystemAudioCapture does.
processor.ensureDSPResources()

let sampleRate = 48000.0
let chunk = 512
var phase: Double = 0
// 2.5 seconds of a loud A4 (440 Hz) + bass fundamental (82 Hz).
var t: Double = 0
let totalSamples = Int(2.5 * sampleRate)
var generated = 0
while generated < totalSamples {
    var pcm = [Float](repeating: 0, count: chunk)
    pcm.withUnsafeMutableBufferPointer { buf in
        for i in 0..<chunk {
            let tt = t + Double(i) / sampleRate
            phase += (2 * .pi * 440.0) / sampleRate
            buf[i] = Float(0.30 * sin(phase) + 0.30 * sin(2 * .pi * 82.0 * tt))
        }
    }
    t += Double(chunk) / sampleRate
    generated += chunk
    pcm.withUnsafeBufferPointer { processor.ingest(samples: $0.baseAddress, count: chunk, sampleRate: sampleRate) }
    // Pace like a realtime device so the analysis queue keeps up.
    usleep(2000)
}

// Give the async analysis queue time to drain.
var waits = 0
while sink.count < 40 && waits < 100 { usleep(50_000); waits += 1 }

guard sink.count >= 40 else {
    print("FAIL: analysis produced only \(sink.count) frames — pipeline scheduler broken")
    exit(53)
}
guard let last = sink.last else { exit(53) }
let spread = spectrumSpread(last.spectrum)
guard spread > 0.02 else {
    print("FAIL: spectrum is degenerate (spread \(spread)) — FFT resources not initialised on system path")
    exit(54)
}
guard last.spectrum.max() ?? 0 > 0.2 else {
    print("FAIL: loud input yielded dark spectrum (max \(last.spectrum.max() ?? 0))")
    exit(55)
}
guard last.level > 0.1 else {
    print("FAIL: musical level \(last.level) too low for loud input")
    exit(56)
}
// Bass energy must dominate for this 82 Hz-heavy signal.
guard last.bass > last.treble else {
    print("FAIL: bass \(last.bass) did not dominate treble \(last.treble)")
    exit(57)
}
print("T1 PASS: system-path FFT live — frames=\(sink.count), spread=\(String(format: "%.3f", spread)), bass=\(String(format: "%.2f", last.bass))")

// ---------------------------------------------------------------------------
// Test 2: quiet input after AGC adaptation must still light up.
// ---------------------------------------------------------------------------
let sink2 = FrameSink()
processor.onAudioFrame = { sink2.append($0) }
var generated2 = 0
while generated2 < Int(2.0 * sampleRate) {
    var pcm = [Float](repeating: 0, count: chunk)
    pcm.withUnsafeMutableBufferPointer { buf in
        for i in 0..<chunk {
            phase += (2 * .pi * 440.0) / sampleRate
            buf[i] = Float(0.02 * sin(phase))
        }
    }
    generated2 += chunk
    pcm.withUnsafeBufferPointer { processor.ingest(samples: $0.baseAddress, count: chunk, sampleRate: sampleRate) }
    usleep(2000)
}
var waits2 = 0
while sink2.count < 30 && waits2 < 100 { usleep(50_000); waits2 += 1 }
guard let quiet = sink2.last, (quiet.spectrum.max() ?? 0) > 0.15 else {
    print("FAIL: AGC did not lift quiet input (max \(sink2.last?.spectrum.max() ?? -1))")
    exit(58)
}
print("T2 PASS: AGC lifts quiet input — spectrum max \(String(format: "%.2f", quiet.spectrum.max() ?? 0))")

// ---------------------------------------------------------------------------
// Test 3: beat detection fires on a percussive onset (silence → bass thump).
// ---------------------------------------------------------------------------
let sink3 = FrameSink()
processor.onAudioFrame = { sink3.append($0) }
var sawBeat = false
for cycle in 0..<6 {
    // 300 ms near-silence
    var silence = [Float](repeating: 0, count: Int(0.3 * sampleRate))
    silence.withUnsafeBufferPointer { processor.ingest(samples: $0.baseAddress, count: silence.count, sampleRate: sampleRate) }
    usleep(320_000)
    // 300 ms strong low-frequency thump
    var thump = [Float](repeating: 0, count: Int(0.3 * sampleRate))
    thump.withUnsafeMutableBufferPointer { buf in
        for i in 0..<buf.count {
            let envelope = Double(i) / Double(buf.count)
            buf[i] = Float(0.6 * sin(2 * .pi * 70.0 * Double(i) / sampleRate) * (1.0 - envelope))
        }
    }
    thump.withUnsafeBufferPointer { processor.ingest(samples: $0.baseAddress, count: thump.count, sampleRate: sampleRate) }
    usleep(320_000)
    if sink3.all.contains(where: { $0.isBeat }) { sawBeat = true; break }
    _ = cycle
}
guard sawBeat else {
    print("FAIL: no beat detected across 6 percussive onsets")
    exit(59)
}
print("T3 PASS: beat detection fires on percussive onsets")

// ---------------------------------------------------------------------------
// Test 4: stop()/start() churn must not wedge the scheduler (mode switching).
// ---------------------------------------------------------------------------
for _ in 0..<20 {
    processor.stop()
    processor.ensureDSPResources()
    var pcm = [Float](repeating: 0, count: 2048)
    pcm.withUnsafeMutableBufferPointer { buf in
        for i in 0..<buf.count {
            phase += (2 * .pi * 200.0) / sampleRate
            buf[i] = Float(0.3 * sin(phase))
        }
    }
    pcm.withUnsafeBufferPointer { processor.ingest(samples: $0.baseAddress, count: 2048, sampleRate: sampleRate) }
}
let sink4 = FrameSink()
processor.onAudioFrame = { sink4.append($0) }
var pcm = [Float](repeating: 0, count: 8192)
pcm.withUnsafeMutableBufferPointer { buf in
    for i in 0..<buf.count {
        phase += (2 * .pi * 300.0) / sampleRate
        buf[i] = Float(0.3 * sin(phase))
    }
}
pcm.withUnsafeBufferPointer { processor.ingest(samples: $0.baseAddress, count: 8192, sampleRate: sampleRate) }
var waits4 = 0
while sink4.count == 0 && waits4 < 60 { usleep(50_000); waits4 += 1 }
guard sink4.count > 0 else {
    print("FAIL: scheduler wedged after stop/start churn — no frames")
    exit(60)
}
print("T4 PASS: scheduler survives stop/start churn (frames=\(sink4.count))")

print("PASS: audio pipeline end-to-end")
exit(0)
