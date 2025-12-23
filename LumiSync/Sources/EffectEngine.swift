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
            // Moving rainbow
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
            // Breathing with custom color
            let intensity = (sin(Double(step) * 0.05) + 1.0) / 2.0
            let r = UInt8(Double(color.r) * intensity)
            let g = UInt8(Double(color.g) * intensity)
            let b = UInt8(Double(color.b) * intensity)
            
            for _ in 0..<ledCount {
                rawColors.append((r, g, b))
            }
            
        case .marquee:
            // Running dot with custom color
            let pos = (step / 5) % ledCount // Slow down the movement relative to step
            for i in 0..<ledCount {
                if i == pos {
                    rawColors.append((color.r, color.g, color.b))
                } else {
                    rawColors.append((0, 0, 0))
                }
            }
            
        case .knightRider:
            // Knight Rider (Cylon) Effect
            // Red scanner moving back and forth
            let width = ledCount
            let pos = (step / 2) % (width * 2)
            let activeIndex = pos < width ? pos : (width * 2 - pos - 1)
            
            for i in 0..<ledCount {
                let dist = abs(i - activeIndex)
                if dist < 4 {
                    let intensity = 1.0 - (Double(dist) / 4.0)
                    rawColors.append((UInt8(255 * intensity), 0, 0))
                } else {
                    rawColors.append((0, 0, 0))
                }
            }
            
        case .police:
            // Police Lights (Red/Blue Strobe)
            let phase = (step / 10) % 2
            for i in 0..<ledCount {
                if i < ledCount / 2 {
                    // Left Side: Red
                    rawColors.append(phase == 0 ? (255, 0, 0) : (0, 0, 0))
                } else {
                    // Right Side: Blue
                    rawColors.append(phase == 1 ? (0, 0, 255) : (0, 0, 0))
                }
            }
            
        case .candle:
            // Candle Flicker
            // Random intensity variations on orange/red
            for _ in 0..<ledCount {
                let flicker = Double.random(in: 0.6...1.0)
                let r = UInt8(255 * flicker)
                let g = UInt8(140 * flicker) // Orange-ish
                rawColors.append((r, g, 0))
            }
            
        case .plasma:
            // Plasma Effect (Sinusoidal waves)
            for i in 0..<ledCount {
                let v1 = sin(Double(i) * 0.1 + Double(step) * 0.05)
                let v2 = sin(Double(i) * 0.1 - Double(step) * 0.05 + 2.0)
                let v = (v1 + v2 + 2.0) / 4.0 // Normalize 0-1
                
                let c = NSColor(hue: v, saturation: 1.0, brightness: 1.0, alpha: 1.0)
                if let rgb = c.usingColorSpace(.deviceRGB) {
                    rawColors.append((UInt8(rgb.redComponent * 255), UInt8(rgb.greenComponent * 255), UInt8(rgb.blueComponent * 255)))
                } else {
                    rawColors.append((0,0,0))
                }
            }
            
        case .strobe:
            // Strobe Light
            let on = (step / 2) % 2 == 0
            let c = on ? (255, 255, 255) : (0, 0, 0)
            for _ in 0..<ledCount {
                rawColors.append((UInt8(c.0), UInt8(c.1), UInt8(c.2)))
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
