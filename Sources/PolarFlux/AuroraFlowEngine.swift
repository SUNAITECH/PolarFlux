import Foundation
import QuartzCore

/// AuroraFlow — generative "flowing light" renderer for Music mode.
///
/// The previous Music-mode renderer mapped each LED's *hue* directly to its
/// position (hue = f(position)) and used spectrum energy only for brightness.
/// That produced a static frequency meter: the warm (bass) end sat bright and
/// unmoved, the cool end wiggled slightly, and colors never travelled.
///
/// AuroraFlow instead synthesises a colour field that is a function of BOTH
/// position and time, driven by music features:
///
///   hue(u, t) = drift(t)                       slow global palette rotation
///             + u · span(t)                    gradient span (centroid-driven)
///             + Σ  A_band(t) · sin(k·u ± ω·t)  counter-propagating phase waves
///                                             (bass/mid/treble amplitudes)
///   V(u, t)   = ambient floor                  idle "screensaver" drift
///             + band glow                      slow loudness
///             + bass pulse (wave-aligned)      swelling tied to the main wave
///             + treble shimmer                 fine sparkle on the ripple wave
///             + beat flash                     onset impulse → white core
///             + mirrored spectrum underglow    subtle positional energy hint
///
/// Flow kinematics: the wave-field phase advances at
///   v = base drift + loudness coupling + beat kick + centroid bias,
/// so drum hits visibly *push* the light along the strip. The rendered field
/// is finally passed through the FluidPhysicsEngine, whose neighbour coupling
/// makes transitions propagate like fluid — PolarFlux's signature look.
///
/// Silence behaviour: after ~2.5 s of quiet the music layers fade out and the
/// engine settles into a slow, dim ambient drift instead of freezing or going
/// dark.
final class AuroraFlowEngine {

    // MARK: - State

    // render() runs on the audio analysis queue while reset() is invoked from
    // the main thread during mode switches; the lock closes that window.
    private let stateLock = NSLock()
    private var flowPhase: Double = 0        // wave-field phase (spatial motion)
    private var hueDrift: Double = 0.10      // global palette rotation [0..1)
    private var beatEnv: Double = 0          // beat envelope, fast attack / exp decay
    private var levelSlow: Double = 0        // slow loudness (glow coupling)
    private var idleTime: Double = 0         // consecutive silence duration
    private var lastRenderTime: Double = 0
    private var spectrumSmooth: [Double] = []
    private let physics = FluidPhysicsEngine()

    // Tuning constants (documented so the field can be revoiced safely).
    private let tauBeat = 0.25               // beat decay time constant (s)
    private let tauLevel = 0.6               // loudness smoothing (s)
    private let tauSpectrum = 0.12           // underglow smoothing (s)
    private let idleFadeTau = 2.5            // silence fade (s)
    private let idleLevelGate = 0.04

    // MARK: - Lifecycle

    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        flowPhase = 0
        hueDrift = 0.10
        beatEnv = 0
        levelSlow = 0
        idleTime = 0
        lastRenderTime = 0
        spectrumSmooth.removeAll()
        physics.reset()
    }

    // MARK: - Render

    func render(frame: AudioFrame, ledCount: Int, mirror: Bool) -> [(UInt8, UInt8, UInt8)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard ledCount > 0 else { return [] }

        let now = CACurrentMediaTime()
        let dt = (lastRenderTime == 0) ? 0.021 : min(max(now - lastRenderTime, 0.001), 0.2)
        lastRenderTime = now

        let bass = Double(min(max(frame.bass, 0), 1))
        let mid = Double(min(max(frame.mid, 0), 1))
        let treble = Double(min(max(frame.treble, 0), 1))
        let level = Double(min(max(frame.level, 0), 1))
        let centroid = Double(min(max(frame.centroid, 0), 1))

        // --- Beat envelope: instant attack, musical exponential decay ---
        if frame.isBeat {
            beatEnv = max(beatEnv, 0.55 + 0.45 * Double(min(max(frame.beatIntensity, 0), 1)))
        } else {
            beatEnv *= exp(-dt / tauBeat)
            if beatEnv < 1e-3 { beatEnv = 0 }
        }

        // --- Slow loudness coupling ---
        levelSlow += (level - levelSlow) * (1 - exp(-dt / tauLevel))

        // --- Idle detection & graceful fade ---
        if level < idleLevelGate && !frame.isBeat {
            idleTime += dt
        } else {
            idleTime = 0
        }
        let idleFade = exp(-idleTime / idleFadeTau)

        // --- Underglow spectrum smoothing ---
        if spectrumSmooth.count != frame.spectrum.count {
            spectrumSmooth = frame.spectrum.map { Double(min(max($0, 0), 1)) }
        } else if !frame.spectrum.isEmpty {
            let a = 1 - exp(-dt / tauSpectrum)
            for i in 0..<spectrumSmooth.count {
                spectrumSmooth[i] += (Double(min(max(frame.spectrum[i], 0), 1)) - spectrumSmooth[i]) * a
            }
        }

        // --- Flow kinematics ---
        // Base drift keeps the field alive at all times; loudness and beats
        // push it faster; brighter material (centroid) flows a touch quicker.
        let flowVelocity = 0.045 + 0.10 * levelSlow + 0.50 * beatEnv + 0.05 * centroid
        flowPhase += dt * flowVelocity

        // Palette rotation: slow, accelerated briefly by beats; centroid pulls
        // the drift direction warm (negative) or cool (positive).
        hueDrift = wrap01(hueDrift + dt * (0.012 + 0.05 * beatEnv + 0.02 * (centroid - 0.5)))

        // Gradient span: bass-heavy content keeps a cohesive warm band,
        // bright content spreads the full rainbow across the strip.
        let gradientSpan = 0.75 + 0.45 * centroid

        // Wave amplitudes per band. Idle fade keeps a reduced residual so the
        // ambient drift stays gently undulating rather than perfectly flat.
        let music = 0.35 + 0.65 * idleFade
        let ampBass = (0.05 + 0.14 * bass) * music
        let ampMid = (0.04 + 0.11 * mid) * music
        let ampTreble = (0.015 + 0.07 * treble) * music

        var colors: [(UInt8, UInt8, UInt8)] = []
        colors.reserveCapacity(ledCount)
        let specCount = spectrumSmooth.count

        for i in 0..<ledCount {
            let u = Double(i) / Double(max(ledCount - 1, 1))

            // Three counter-propagating phase waves: a broad swell (bass), a
            // mid-band counter-flow, and a fine ripple (treble shimmer).
            let w1 = sin(2 * .pi * (u * 1.5 + flowPhase))
            let w2 = sin(2 * .pi * (u * 2.7 - flowPhase * 0.72) + 2.1)
            let w3 = sin(2 * .pi * (u * 6.0 + flowPhase * 1.7) + 4.2)

            var hue = hueDrift + u * gradientSpan + w1 * ampBass + w2 * ampMid + w3 * ampTreble
            hue = wrap01(hue)

            // Luminance stack.
            let ambient = 0.055 * 255
            let bandGlow = (0.14 + 0.30 * levelSlow) * idleFade
            let bassPulse = bass * 0.34 * max(0, 0.55 + 0.45 * w1) * idleFade
            let shimmer = treble * 0.22 * max(0, w3) * idleFade
            let beatFlash = beatEnv * 0.30 * idleFade

            var underglow = 0.0
            if specCount > 0 {
                let t = mirror ? abs(2 * u - 1) : u
                let curved = pow(t, 0.85)
                let idx = min(Int(curved * Double(specCount)), specCount - 1)
                underglow = 0.10 * spectrumSmooth[idx] * idleFade
            }

            var v = ambient + (bandGlow + bassPulse + shimmer + beatFlash + underglow) * 255
            // Soft-knee clip: gentle saturation toward full brightness so
            // stacked layers never hard-clip into flat white.
            v = v < 200 ? v : 200 + 55 * (1 - exp(-(v - 200) / 40.0))
            v = min(max(v, 0), 255)

            // Beat flash leans toward a white core; ambient keeps colour identity.
            let sat = max(0.35, 0.88 - 0.33 * beatEnv)

            colors.append(AuroraFlowEngine.hsvToRgb(h: hue, s: sat, v: v / 255.0))
        }

        // Neighbour-coupled fluid smoothing: transitions propagate along the
        // strip instead of snapping — the "flowing" quality.
        return physics.process(targetColors: colors, dt: dt, sectorIntensities: nil)
    }

    // MARK: - Helpers

    @inline(__always)
    private func wrap01(_ x: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: 1.0)
        return r < 0 ? r + 1 : r
    }

    /// Self-contained HSV→RGB (hue 0..1, sat 0..1, value 0..1) so the engine
    /// can be unit-tested without app dependencies.
    static func hsvToRgb(h: Double, s: Double, v: Double) -> (UInt8, UInt8, UInt8) {
        let c = v * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        var (r1, g1, b1) = (0.0, 0.0, 0.0)
        switch h * 6 {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (UInt8(min(max((r1 + m) * 255, 0), 255)),
                UInt8(min(max((g1 + m) * 255, 0), 255)),
                UInt8(min(max((b1 + m) * 255, 0), 255)))
    }
}
