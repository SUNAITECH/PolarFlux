import SwiftUI
import AppKit

/// Lossless conversion to an 8-bit channel value. `cgColor` components and other
/// floating-point sources can exceed 1.0 (e.g. wide-gamut / extended color spaces),
/// and the standard `UInt8(_:)` initialiser traps on overflow. This clamps instead.
@inlinable
func clampU8(_ value: Double) -> UInt8 {
    UInt8(min(max(value.rounded(), 0), 255))
}

@inlinable
func clampU8(_ value: CGFloat) -> UInt8 {
    UInt8(min(max(value.rounded(), 0), 255))
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }
    
    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}
