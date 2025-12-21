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
    
    func start(effect: EffectType, ledCount: Int) {
        self.currentEffect = effect
        self.step = 0
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.generateFrame(ledCount: ledCount)
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    private func generateFrame(ledCount: Int) {
        var data = [UInt8]()
        data.reserveCapacity(ledCount * 3)
        
        step += 1
        
        switch currentEffect {
        case .rainbow:
            // Moving rainbow
            for i in 0..<ledCount {
                let hue = Double((i * 5 + step * 2) % 360) / 360.0
                let color = NSColor(hue: hue, saturation: 1.0, brightness: 1.0, alpha: 1.0)
                if let rgb = color.usingColorSpace(.deviceRGB) {
                    data.append(UInt8(rgb.redComponent * 255))
                    data.append(UInt8(rgb.greenComponent * 255))
                    data.append(UInt8(rgb.blueComponent * 255))
                } else {
                    data.append(contentsOf: [0,0,0])
                }
            }
            
        case .breathing:
            // Red breathing
            let intensity = (sin(Double(step) * 0.1) + 1.0) / 2.0
            let val = UInt8(intensity * 255)
            for _ in 0..<ledCount {
                data.append(val) // R
                data.append(0)   // G
                data.append(0)   // B
            }
            
        case .marquee:
            // Running white dot
            let pos = step % ledCount
            for i in 0..<ledCount {
                if i == pos {
                    data.append(contentsOf: [255, 255, 255])
                } else {
                    data.append(contentsOf: [0, 0, 0])
                }
            }
        }
        
        onFrame?(data)
    }
}
