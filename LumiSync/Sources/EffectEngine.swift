import Foundation
import SwiftUI

enum EffectType: String, CaseIterable, Identifiable {
    case rainbow = "Rainbow"
    case breathing = "Breathing"
    case marquee = "Marquee"
    
    var id: String { self.rawValue }
}

class EffectEngine {
    private var timer: Timer?
    private var step: Int = 0
    private var currentEffect: EffectType = .rainbow
    
    var onFrame: (([UInt8]) -> Void)?
    
    func start(effect: EffectType, ledCount: Int, speed: Double, color: (r: UInt8, g: UInt8, b: UInt8)) {
        self.currentEffect = effect
        self.step = 0
        
        // Speed: 1.0 = 0.05s interval. 2.0 = 0.025s. 0.5 = 0.1s.
        let interval = 0.05 / speed
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.generateFrame(ledCount: ledCount, color: color)
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    private func generateFrame(ledCount: Int, color: (r: UInt8, g: UInt8, b: UInt8)) {
        var data = [UInt8]()
        data.reserveCapacity(ledCount * 3)
        
        step += 1
        
        switch currentEffect {
        case .rainbow:
            // Moving rainbow
            for i in 0..<ledCount {
                let hue = Double((i * 5 + step * 2) % 360) / 360.0
                let c = NSColor(hue: hue, saturation: 1.0, brightness: 1.0, alpha: 1.0)
                if let rgb = c.usingColorSpace(.deviceRGB) {
                    data.append(UInt8(rgb.redComponent * 255))
                    data.append(UInt8(rgb.greenComponent * 255))
                    data.append(UInt8(rgb.blueComponent * 255))
                } else {
                    data.append(contentsOf: [0,0,0])
                }
            }
            
        case .breathing:
            // Breathing with custom color
            let intensity = (sin(Double(step) * 0.1) + 1.0) / 2.0
            let r = UInt8(Double(color.r) * intensity)
            let g = UInt8(Double(color.g) * intensity)
            let b = UInt8(Double(color.b) * intensity)
            
            for _ in 0..<ledCount {
                data.append(r)
                data.append(g)
                data.append(b)
            }
            
        case .marquee:
            // Running dot with custom color
            let pos = step % ledCount
            for i in 0..<ledCount {
                if i == pos {
                    data.append(color.r)
                    data.append(color.g)
                    data.append(color.b)
                } else {
                    data.append(contentsOf: [0, 0, 0])
                }
            }
        }
        
        onFrame?(data)
    }
}
