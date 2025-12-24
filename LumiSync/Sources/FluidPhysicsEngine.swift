import Foundation

struct SpringState {
    var r: Double
    var g: Double
    var b: Double
    var vr: Double
    var vg: Double
    var vb: Double
    
    static var zero: SpringState {
        return SpringState(r: 0, g: 0, b: 0, vr: 0, vg: 0, vb: 0)
    }
}

class FluidPhysicsEngine {
    private var states: [SpringState] = []
    private var flowPhase: Double = 0.0
    
    func process(targetColors: [(UInt8, UInt8, UInt8)], dt: Double, sceneIntensity: Double = 0.0) -> [(UInt8, UInt8, UInt8)] {
        // Initialize states if size mismatch
        if states.count != targetColors.count {
            states = targetColors.map { 
                SpringState(r: Double($0.0), g: Double($0.1), b: Double($0.2), vr: 0, vg: 0, vb: 0) 
            }
        }
        
        // Time Scaling (Normalize to 60 FPS)
        // If dt is very small (e.g. 0), default to 1.0 scale
        // Stability Fix: Clamp timeScale to max 2.5 to prevent explosion during lag spikes
        let rawScale = (dt > 0) ? (dt * 60.0) : 1.0
        let timeScale = min(rawScale, 2.5)
        
        // Update Flow Phase
        self.flowPhase += 0.05 * timeScale
        
        let count = targetColors.count
        var smoothedColors = [(UInt8, UInt8, UInt8)]()
        smoothedColors.reserveCapacity(count)
        
        // --- Patch Point 4: Advanced Physics Parameter Mapping ---
        
        // 1. Define Extreme Parameter Sets
        // Calm Scene: Low stiffness (soft), High damping (heavy/slow)
        let stiffness_low = 0.012
        let damping_high = 0.88
        
        // Intense Scene: High stiffness (tight), Low damping (fast/responsive)
        let stiffness_high = 0.18
        let damping_low = 0.32
        
        // 2. Response Curve (Smoothstep)
        // This ensures a non-linear transition that is stable at the ends and smooth in the middle.
        func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
            let t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
            return t * t * (3.0 - 2.0 * t)
        }
        
        let intensity = min(max(sceneIntensity, 0.0), 1.0)
        let mix = smoothstep(edge0: 0.0, edge1: 1.0, x: intensity)
        
        // 3. Interpolate Parameters
        let dynamicTension = stiffness_low + (stiffness_high - stiffness_low) * mix
        let dynamicFriction = damping_high + (damping_low - damping_high) * mix
        
        for i in 0..<count {
            let target = targetColors[i]
            var state = states[i]
            
            // Fluid Neighbors (Circular Buffer)
            let upstreamIdx = (i - 1 + count) % count
            let downstreamIdx = (i + 1) % count
            let upstream = states[upstreamIdx]
            let downstream = states[downstreamIdx]
            
            // 1. Dynamic Flow Field Generation
            let flowVector = 0.12 + sin(Double(i) * 0.15 + self.flowPhase) * 0.08
            
            // 2. Fluid Coupling Forces
            let advectionR = (upstream.r - state.r) * flowVector + (upstream.vr - state.vr) * flowVector * 0.6
            let advectionG = (upstream.g - state.g) * flowVector + (upstream.vg - state.vg) * flowVector * 0.6
            let advectionB = (upstream.b - state.b) * flowVector + (upstream.vb - state.vb) * flowVector * 0.6
            
            let dragFactor = 0.04
            let dragR = (downstream.r - state.r) * dragFactor
            let dragG = (downstream.g - state.g) * dragFactor
            let dragB = (downstream.b - state.b) * dragFactor
            
            // 3. Target Attraction (Adaptive Spring Physics)
            let tr = Double(target.0)
            let tg = Double(target.1)
            let tb = Double(target.2)
            
            let deltaR = tr - state.r
            let deltaG = tg - state.g
            let deltaB = tb - state.b
            let dist = sqrt(deltaR*deltaR + deltaG*deltaG + deltaB*deltaB)
            
            var tension: Double
            var friction: Double
            
            // Hybrid Physics: Combine Distance-Based Adaptive Physics with Scene-Intensity Dynamics
            if dist > 120.0 {
                // Snap logic for massive changes (e.g. scene cuts)
                tension = 0.45; friction = 0.35
            } else if dist < 5.0 {
                // Very close: Use dynamic parameters to settle perfectly
                tension = dynamicTension
                friction = dynamicFriction
            } else {
                // Interpolate between dynamic parameters and snap parameters based on distance
                let distT = min(max((dist - 5.0) / 115.0, 0.0), 1.0)
                let distMix = distT * distT // Quadratic for faster snap response
                
                tension = dynamicTension + (0.45 - dynamicTension) * distMix
                friction = dynamicFriction + (0.35 - dynamicFriction) * distMix
            }
            
            // 4. Integration (Euler)
            let forceR = (tension * deltaR) + advectionR + dragR
            state.vr = state.vr + (forceR * timeScale)
            state.vr *= pow(1.0 - friction, timeScale)
            state.r += state.vr * timeScale
            
            let forceG = (tension * deltaG) + advectionG + dragG
            state.vg = state.vg + (forceG * timeScale)
            state.vg *= pow(1.0 - friction, timeScale)
            state.g += state.vg * timeScale
            
            let forceB = (tension * deltaB) + advectionB + dragB
            state.vb = state.vb + (forceB * timeScale)
            state.vb *= pow(1.0 - friction, timeScale)
            state.b += state.vb * timeScale
            
            // Update State
            states[i] = state
            
            // Clamp and Assign
            let finalR = UInt8(min(max(state.r, 0), 255))
            let finalG = UInt8(min(max(state.g, 0), 255))
            let finalB = UInt8(min(max(state.b, 0), 255))
            
            smoothedColors.append((finalR, finalG, finalB))
        }
        
        return smoothedColors
    }
    
    func reset() {
        states.removeAll()
    }
}
