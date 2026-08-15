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
// Budget is 60s because the test's own bounded wall-clock sections sum to
// ~21s+ (pacing sleeps + bounded waits) and CI macOS VMs run 2-3x slower
// than a dev machine. A real deadlock hangs forever, so a generous watchdog
// still catches it; a tight one only kills healthy runs on slow runners.
DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
    FileHandle.standardError.write("FAIL: watchdog fired — audio pipeline deadlock\n".data(using: .utf8)!)
    exit(52)
}

/// Elapsed-time marker for diagnosing watchdog trips: each section prints its
// own timestamp so a future failure pinpoints the slow/hung stage.
let testStart = Date()
func section(_ name: String) {
    print("[+\(String(format: "%5.1f", Date().timeIntervalSince(testStart)))s] \(name)")
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
section("T1 pass"); print("T1 PASS: system-path FFT live — frames=\(sink.count), spread=\(String(format: "%.3f", spread)), bass=\(String(format: "%.2f", last.bass))")

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
section("T2 pass"); print("T2 PASS: AGC lifts quiet input — spectrum max \(String(format: "%.2f", quiet.spectrum.max() ?? 0))")

// ---------------------------------------------------------------------------
// Test 3: beat detection fires on a percussive onset (silence → bass thump).
// ---------------------------------------------------------------------------
let sink3 = FrameSink()
processor.onAudioFrame = { sink3.append($0) }
var sawBeat = false
for cycle in 0..<6 {
    // 300 ms near-silence
    let silence = [Float](repeating: 0, count: Int(0.3 * sampleRate))
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
section("T3 pass"); print("T3 PASS: beat detection fires on percussive onsets")

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
section("T4 pass"); print("T4 PASS: scheduler survives stop/start churn (frames=\(sink4.count))")

print("PASS: audio pipeline end-to-end")

// ---------------------------------------------------------------------------
// AuroraFlow visual-quality regression tests. These encode the product
// requirements for Music mode's flowing-light render:
//   T5: color at a FIXED LED position must evolve over time (no static
//       warm/cool ends pinned to the strip).
//   T6: colors must differ ACROSS the strip at any instant (rainbow spread,
//       not a uniform wash).
//   T7: silence fades to a dim ambient drift — never freezes, never goes dark.
//   T8: beats must visibly lift brightness (light "pulses" with the music).
// ---------------------------------------------------------------------------
import Foundation

func frame(_ level: Float, _ bass: Float, _ mid: Float, _ treble: Float,
           beat: Bool = false, beatIntensity: Float = 0, centroid: Float = 0.5,
           spectrum: [Float]? = nil) -> AudioFrame {
    AudioFrame(level: level, bass: bass, mid: mid, treble: treble,
               spectrum: spectrum ?? [Float](repeating: level, count: 64),
               sampleRate: 48000,
               beatIntensity: beatIntensity, isBeat: beat, centroid: centroid)
}

func avgBrightness(_ colors: [(UInt8, UInt8, UInt8)]) -> Double {
    guard !colors.isEmpty else { return 0 }
    var acc = 0.0
    for c in colors { acc += Double(max(c.0, max(c.1, c.2))) }
    return acc / Double(colors.count)
}

func rgbDist(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> Double {
    let dr = Double(a.0) - Double(b.0), dg = Double(a.1) - Double(b.1), db = Double(a.2) - Double(b.2)
    return (dr*dr + dg*dg + db*db).squareRoot()
}

let aurora = AuroraFlowEngine()
let LEDS = 100
let frameIntervalUs = useconds_t(21_000)

// --- T5: temporal evolution at fixed positions over 3 s of music ---
aurora.reset()
var snapshots: [[(UInt8, UInt8, UInt8)]] = []
var auroraPhase: Double = 0
for step in 0..<143 {
    let t = Double(step) * 0.021
    auroraPhase += 0.9
    let wobble = 0.5 + 0.5 * sin(t * 2.1)
    let f = frame(Float(0.5 + 0.2 * wobble), Float(0.6 + 0.3 * wobble), 0.4,
                  Float(0.2 + 0.2 * wobble),
                  beat: step % 24 == 0, beatIntensity: 0.8,
                  centroid: Float(0.35 + 0.2 * wobble))
    let colors = aurora.render(frame: f, ledCount: LEDS, mirror: true)
    if step % 12 == 0 { snapshots.append(colors) }
    usleep(frameIntervalUs)
}
guard snapshots.count >= 10 else { print("FAIL: T5 insufficient snapshots"); exit(61) }

// At each of three fixed positions, total color travel must be substantial.
let probes = [10, 50, 90]
var allTravel = 0.0
for p in probes {
    var travel = 0.0
    for s in 1..<snapshots.count {
        travel += rgbDist(snapshots[s-1][p], snapshots[s][p])
    }
    allTravel += travel
    guard travel > 40 else {
        print("FAIL: T5 LED[\(p)] color travel \(travel) — static hue pinning regressed")
        exit(62)
    }
}

// --- T6: spatial diversity in a single frame ---
var pairDist = 0.0
var pairs = 0
let spatial = snapshots[snapshots.count / 2]
for i in stride(from: 0, to: LEDS - 10, by: 10) {
    pairDist += rgbDist(spatial[i], spatial[i + 10])
    pairs += 1
}
let meanPair = pairDist / Double(max(pairs, 1))
guard meanPair > 20 else {
    print("FAIL: T6 spatial diversity \(meanPair) — strip renders as uniform wash")
    exit(63)
}

// --- T7: silence → dim ambient drift, still alive ---
aurora.reset()
for _ in 0..<80 { _ = aurora.render(frame: frame(0.02, 0.01, 0.01, 0.01), ledCount: LEDS, mirror: true); usleep(frameIntervalUs) }
let idleColors1 = aurora.render(frame: frame(0.0, 0.0, 0.0, 0.0), ledCount: LEDS, mirror: true)
let idleBright = avgBrightness(idleColors1)
guard idleBright < 60, idleBright > 3 else {
    print("FAIL: T7 idle brightness \(idleBright) — expected dim ambient (3..60)")
    exit(64)
}
for _ in 0..<96 { _ = aurora.render(frame: frame(0.0, 0.0, 0.0, 0.0), ledCount: LEDS, mirror: true); usleep(frameIntervalUs) }
let idleColors2 = aurora.render(frame: frame(0.0, 0.0, 0.0, 0.0), ledCount: LEDS, mirror: true)
var idleTravel = 0.0
for i in 0..<LEDS { idleTravel += rgbDist(idleColors1[i], idleColors2[i]) }
idleTravel /= Double(LEDS)
guard idleTravel > 0.5 else {
    print("FAIL: T7 idle field frozen (travel \(idleTravel)) — ambient drift must persist")
    exit(65)
}

// --- T8: beat lift ---
// The beat flash is designed to swell through the fluid engine over ~100 ms
// (not a single-frame strobe), so we measure peak brightness across the
// envelope's decay window — matching what a viewer actually perceives.
aurora.reset()
for _ in 0..<60 { _ = aurora.render(frame: frame(0.3, 0.3, 0.2, 0.2), ledCount: LEDS, mirror: true); usleep(frameIntervalUs) }
let preBeat = aurora.render(frame: frame(0.3, 0.3, 0.2, 0.2), ledCount: LEDS, mirror: true)
let baseline = avgBrightness(preBeat)
var peak = baseline
_ = aurora.render(frame: frame(0.8, 0.9, 0.3, 0.3, beat: true, beatIntensity: 1.0), ledCount: LEDS, mirror: true)
for _ in 0..<6 {
    let during = aurora.render(frame: frame(0.35, 0.35, 0.25, 0.25), ledCount: LEDS, mirror: true)
    peak = max(peak, avgBrightness(during))
    usleep(frameIntervalUs)
}
let lift = peak - baseline
guard lift > 20 else {
    print("FAIL: T8 beat lift \(lift) — beats must visibly push the light")
    exit(66)
}

section("T5 pass"); print("T5 PASS: fixed-position color travel avg \(String(format: "%.0f", allTravel / 3))")
section("T6 pass"); print("T6 PASS: spatial diversity \(String(format: "%.1f", meanPair))")
section("T7 pass"); print("T7 PASS: idle = dim ambient drift (brightness \(String(format: "%.1f", idleBright)), drift \(String(format: "%.1f", idleTravel))")
section("T8 pass"); print("T8 PASS: beat lift \(String(format: "%.1f", lift))")

print("PASS: all audio + aurora tests")
exit(0)
