import Foundation
import SwiftUI

enum EffectType: String, CaseIterable, Identifiable {
    case rainbow = "Rainbow"
    case breathing = "Breathing"
    case marquee = "Marquee"
    case knightRider = "Knight Rider"
    case police = "Police Lights"
    case candle = "Candle Flicker"
    case plasma = "Plasma"
    case strobe = "Strobe"
    case atomic = "Atomic Swirl"
    case fire = "Fire"
    case matrix = "Matrix"
    case moodBlobs = "Mood Blobs"
    case pacman = "Pacman"
    case snake = "Snake"
    case sparks = "Sparks"
    case traces = "Traces"
    case trails = "Trails"
    case waves = "Waves"
    case collision = "Collision"
    case doubleSwirl = "Double Swirl"
    
    var id: String { self.rawValue }
}

class EffectEngine {
    private var timer: Timer?
    private var step: Int = 0
    private var currentEffect: EffectType = .rainbow
    
    // Physics Engine for smoothing effects
    private let physicsEngine = FluidPhysicsEngine()
    private var lastFrameTime: TimeInterval = 0
    
    var onFrame: (([UInt8]) -> Void)?
    
    func start(effect: EffectType, ledCount: Int, speed: Double, color: (r: UInt8, g: UInt8, b: UInt8)) {
        self.currentEffect = effect
        self.step = 0
        self.physicsEngine.reset()
        self.lastFrameTime = Date().timeIntervalSince1970
        
        // Speed: 1.0 = 0.05s interval. 2.0 = 0.025s. 0.5 = 0.1s.
        let interval = 0.016 // Run at 60 FPS for physics
        let stepIncrement = Int(speed * 3.0) // Adjust step speed based on user speed
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.generateFrame(ledCount: ledCount, color: color, stepIncrement: stepIncrement)
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    private func generateFrame(ledCount: Int, color: (r: UInt8, g: UInt8, b: UInt8), stepIncrement: Int) {
        var rawColors = [(UInt8, UInt8, UInt8)]()
        rawColors.reserveCapacity(ledCount)
        
        step += stepIncrement
        
        switch currentEffect {
        case .rainbow:
            for i in 0..<ledCount {
                let hue = Double((i * 5 + step) % 360) / 360.0
                let c = NSColor(hue: hue, saturation: 1.0, brightness: 1.0, alpha: 1.0)
                if let rgb = c.usingColorSpace(.deviceRGB) {
                    rawColors.append((UInt8(rgb.redComponent * 255), UInt8(rgb.greenComponent * 255), UInt8(rgb.blueComponent * 255)))
                } else {
                    rawColors.append((0,0,0))
                }
            }
            
        case .breathing:
            let intensity = (sin(Double(step) * 0.05) + 1.0) / 2.0
            let r = UInt8(Double(color.r) * intensity)
            let g = UInt8(Double(color.g) * intensity)
            let b = UInt8(Double(color.b) * intensity)
            for _ in 0..<ledCount { rawColors.append((r, g, b)) }
            
        case .marquee:
            let pos = (step / 5) % ledCount
            for i in 0..<ledCount {
                if i == pos { rawColors.append((color.r, color.g, color.b)) }
                else { rawColors.append((0, 0, 0)) }
            }
            
        case .knightRider:
            let width = ledCount
            let pos = (step / 2) % (width * 2)
            let activeIndex = pos < width ? pos : (width * 2 - pos - 1)
            for i in 0..<ledCount {
                let dist = abs(i - activeIndex)
                if dist < 4 {
                    let intensity = 1.0 - (Double(dist) / 4.0)
                    rawColors.append((UInt8(255 * intensity), 0, 0))
                } else { rawColors.append((0, 0, 0)) }
            }
            
        case .police:
            let phase = (step / 10) % 2
            for i in 0..<ledCount {
                if i < ledCount / 2 { rawColors.append(phase == 0 ? (255, 0, 0) : (0, 0, 0)) }
                else { rawColors.append(phase == 1 ? (0, 0, 255) : (0, 0, 0)) }
            }
            
        case .candle:
            for _ in 0..<ledCount {
                let flicker = Double.random(in: 0.6...1.0)
                rawColors.append((UInt8(255 * flicker), UInt8(140 * flicker), 0))
            }
            
        case .plasma:
            for i in 0..<ledCount {
                let v1 = sin(Double(i) * 0.1 + Double(step) * 0.05)
                let v2 = sin(Double(i) * 0.1 - Double(step) * 0.05 + 2.0)
                let v = (v1 + v2 + 2.0) / 4.0
                let c = NSColor(hue: v, saturation: 1.0, brightness: 1.0, alpha: 1.0)
                if let rgb = c.usingColorSpace(.deviceRGB) {
                    rawColors.append((UInt8(rgb.redComponent * 255), UInt8(rgb.greenComponent * 255), UInt8(rgb.blueComponent * 255)))
                } else { rawColors.append((0,0,0)) }
            }
            
        case .strobe:
            let on = (step / 2) % 2 == 0
            let c = on ? (255, 255, 255) : (0, 0, 0)
            for _ in 0..<ledCount { rawColors.append((UInt8(c.0), UInt8(c.1), UInt8(c.2))) }

        case .atomic:
            // Atomic Swirl: Multiple rotating color points
            for i in 0..<ledCount {
                let t = Double(step) * 0.02
                let v1 = sin(Double(i) * 0.2 + t)
                let v2 = cos(Double(i) * 0.3 - t * 1.5)
                let r = UInt8((v1 + 1.0) * 127)
                let g = UInt8((v2 + 1.0) * 127)
                let b = UInt8((sin(t) + 1.0) * 127)
                rawColors.append((r, g, b))
            }

        case .fire:
            // Fire: Flickering orange/red with occasional yellow sparks
            for _ in 0..<ledCount {
                let r = UInt8.random(in: 200...255)
                let g = UInt8.random(in: 40...100)
                let b = UInt8.random(in: 0...20)
                rawColors.append((r, g, b))
            }

        case .matrix:
            // Matrix: Falling green trails
            for i in 0..<ledCount {
                let t = Double(step + i * 10) * 0.1
                let v = max(0, sin(t))
                rawColors.append((0, UInt8(v * 255), 0))
            }

        case .moodBlobs:
            // Mood Blobs: Slow moving blobs of color
            for i in 0..<ledCount {
                let t = Double(step) * 0.01
                let hue = (sin(Double(i) * 0.05 + t) + 1.0) / 2.0
                let c = NSColor(hue: hue, saturation: 0.8, brightness: 0.8, alpha: 1.0)
                if let rgb = c.usingColorSpace(.deviceRGB) {
                    rawColors.append((UInt8(rgb.redComponent * 255), UInt8(rgb.greenComponent * 255), UInt8(rgb.blueComponent * 255)))
                } else { rawColors.append((0,0,0)) }
            }

        case .pacman:
            // Pacman: Yellow dot followed by ghosts
            let pos = (step / 3) % ledCount
            for i in 0..<ledCount {
                if i == pos { rawColors.append((255, 255, 0)) } // Pacman
                else if i == (pos - 5 + ledCount) % ledCount { rawColors.append((255, 0, 0)) } // Blinky
                else if i == (pos - 10 + ledCount) % ledCount { rawColors.append((255, 182, 255)) } // Pinky
                else { rawColors.append((0, 0, 0)) }
            }

        case .snake:
            // Snake: Moving trail
            let length = 10
            let head = (step / 2) % ledCount
            for i in 0..<ledCount {
                let dist = (head - i + ledCount) % ledCount
                if dist < length {
                    let intensity = 1.0 - (Double(dist) / Double(length))
                    rawColors.append((0, UInt8(255 * intensity), 0))
                } else { rawColors.append((0, 0, 0)) }
            }

        case .sparks:
            // Sparks: Random white flashes
            for _ in 0..<ledCount {
                if Double.random(in: 0...1) > 0.98 { rawColors.append((255, 255, 255)) }
                else { rawColors.append((0, 0, 0)) }
            }

        case .traces:
            // Traces: Multiple dots leaving fading trails
            for i in 0..<ledCount {
                let t1 = (step / 4 + i) % ledCount == 0
                let t2 = (step / 6 - i + ledCount) % ledCount == 0
                if t1 { rawColors.append((255, 0, 255)) }
                else if t2 { rawColors.append((0, 255, 255)) }
                else { rawColors.append((0, 0, 0)) }
            }

        case .trails:
            // Trails: Fast moving color streaks
            for i in 0..<ledCount {
                let t = Double(step) * 0.1 + Double(i) * 0.05
                let r = UInt8((sin(t) + 1.0) * 127)
                let g = UInt8((sin(t + 2.0) + 1.0) * 127)
                let b = UInt8((sin(t + 4.0) + 1.0) * 127)
                rawColors.append((r, g, b))
            }

        case .waves:
            // Waves: Overlapping sine waves
            for i in 0..<ledCount {
                let t = Double(step) * 0.05
                let v = sin(Double(i) * 0.1 + t) + sin(Double(i) * 0.15 - t * 0.8)
                let intensity = (v + 2.0) / 4.0
                rawColors.append((0, UInt8(intensity * 100), UInt8(intensity * 255)))
            }

        case .collision:
            // Collision: Two dots meeting and "exploding"
            let pos1 = (step / 2) % ledCount
            let pos2 = (ledCount - (step / 2) % ledCount) % ledCount
            for i in 0..<ledCount {
                if i == pos1 { rawColors.append((255, 0, 0)) }
                else if i == pos2 { rawColors.append((0, 0, 255)) }
                else if abs(pos1 - pos2) < 2 && abs(i - pos1) < 5 { rawColors.append((255, 255, 255)) }
                else { rawColors.append((0, 0, 0)) }
            }

        case .doubleSwirl:
            // Double Swirl: Two colors rotating in opposite directions
            for i in 0..<ledCount {
                let t = Double(step) * 0.05
                let v1 = sin(Double(i) * 0.1 + t)
                let v2 = sin(Double(i) * 0.1 - t)
                rawColors.append((UInt8((v1 + 1.0) * 127), 0, UInt8((v2 + 1.0) * 127)))
            }
        }
        
        // Apply Physics Smoothing
        let now = Date().timeIntervalSince1970
        let dt = now - lastFrameTime
        lastFrameTime = now
        
        let smoothedColors = physicsEngine.process(targetColors: rawColors, dt: dt)
        
        // Flatten to [UInt8]
        var data = [UInt8]()
        data.reserveCapacity(ledCount * 3)
        for color in smoothedColors {
            data.append(color.0)
            data.append(color.1)
            data.append(color.2)
        }
        
        onFrame?(data)
    }
}
