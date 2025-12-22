import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit
import CoreMedia
import VideoToolbox

struct ZoneConfig {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int
    var depth: Int
}

enum SyncMode: String, CaseIterable, Identifiable {
    case full = "Full Screen"
    case cinema = "Cinema (Letterbox)"
    case left = "Left Half"
    case right = "Right Half"
    
    var id: String { self.rawValue }
}

class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    
    private var stream: SCStream?
    private let processingQueue = DispatchQueue(label: "com.lumisync.processing", qos: .userInteractive)
    
    // Callback for sending data back to AppState
    var onFrameProcessed: (([UInt8]) -> Void)?
    
    // Store (Value, Velocity) for R, G, B
    // (r, g, b, vr, vg, vb)
    private var springStates: [(r: Double, g: Double, b: Double, vr: Double, vg: Double, vb: Double)] = []
    private var flowPhase: Double = 0.0
    private var lastFrameTime: TimeInterval = 0
    
    // Check permission once
    static func checkPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }
    
    func getDisplay() async -> SCDisplay? {
        do {
            let content = try await SCShareableContent.current
            return content.displays.first
        } catch {
            return nil
        }
    }
    
    func startStream(display: SCDisplay, config: ZoneConfig, ledCount: Int, mode: SyncMode, orientation: ScreenOrientation, useDominantColor: Bool) async {
        // Stop existing stream if any
        if let stream = stream {
            try? await stream.stopCapture()
        }
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfig = SCStreamConfiguration()
        
        // 1. Optimization: Downsample for Performance
        // We don't need 4K for LED sampling. 480p height is plenty.
        let scaleFactor = 480.0 / Double(display.height)
        streamConfig.width = Int(Double(display.width) * scaleFactor)
        streamConfig.height = 480
        streamConfig.showsCursor = false
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA // Efficient for CPU access
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 60) // Target 60 FPS
        streamConfig.queueDepth = 3 // Keep buffer small to reduce latency
        
        do {
            let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
            try await stream.startCapture()
            self.stream = stream
            
            // Store config for processing
            self.currentConfig = config
            self.currentLedCount = ledCount
            self.currentMode = mode
            self.currentOrientation = orientation
            self.currentUseDominant = useDominantColor
            
        } catch {
            print("Failed to start stream: \(error)")
        }
    }
    
    func stopStream() async {
        if let stream = stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
    }
    
    // Stored context for the stream delegate
    private var currentConfig: ZoneConfig = ZoneConfig(left:0, top:0, right:0, bottom:0, depth:0)
    private var currentLedCount: Int = 0
    private var currentMode: SyncMode = .full
    private var currentOrientation: ScreenOrientation = .standard
    private var currentUseDominant: Bool = true
    
    // MARK: - SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error.localizedDescription)")
    }
    
    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        
        // Calculate Delta Time
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let dt = (lastFrameTime == 0) ? 0.016 : (timestamp - lastFrameTime)
        lastFrameTime = timestamp
        
        // Cap dt to prevent explosion on pause (max 0.1s)
        let safeDt = min(max(dt, 0.001), 0.1)
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        
        // Process Frame
        let ledData = processFrame(
            ptr: ptr,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            config: currentConfig,
            ledCount: currentLedCount,
            mode: currentMode,
            orientation: currentOrientation,
            useDominantColor: currentUseDominant,
            dt: safeDt
        )
        
        // Callback
        onFrameProcessed?(ledData)
    }
    
    private func processFrame(ptr: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, config: ZoneConfig, ledCount: Int, mode: SyncMode, orientation: ScreenOrientation, useDominantColor: Bool, dt: Double) -> [UInt8] {
            
            var ledData = [UInt8]()
            ledData.reserveCapacity(ledCount * 3)
            
            // --- Advanced Sampling Logic (Vibrant Search + Inwards Scan) ---
            
            func getVibrantColor(rect: CGRect) -> (r: UInt8, g: UInt8, b: UInt8) {
                let centerX = Double(width) / 2.0
                let centerY = Double(height) / 2.0
                let rectCenterX = rect.midX
                let rectCenterY = rect.midY
                
                // Vector towards center
                let dx = centerX - rectCenterX
                let dy = centerY - rectCenterY
                
                var bestColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
                var bestScore: Double = -1.0
                
                // Search Inwards Loop (Deep Search)
                // We search up to 80% towards the center to find ANY vibrant color.
                let maxSteps = 8
                
                for step in 0..<maxSteps {
                    let factor = Double(step) * 0.10 // 0%, 10%, 20% ... 70%
                    let offsetX = dx * factor
                    let offsetY = dy * factor
                    
                    let searchRect = rect.offsetBy(dx: offsetX, dy: offsetY)
                    let (r, g, b) = sampleRectWeighted(rect: searchRect)
                    
                    let score = calculateVibrancyScore(r: r, g: g, b: b)
                    
                    // If this step is significantly better, take it.
                    // We prefer outer steps if scores are similar, so we require a small improvement to switch inwards.
                    if score > bestScore + 0.1 {
                        bestScore = score
                        bestColor = (r, g, b)
                    }
                    
                    // Stop Condition: Found a very vibrant color (High Saturation)
                    // Score > 2.5 means Saturation is likely > 0.7
                    if score > 2.5 { break }
                }
                
                // Post-Processing: Auto-Brightness Boost
                // If we found a color that has hue (Sat > 0.3) but is dark (Bri < 100), boost it!
                let (r, g, b) = bestColor
                let rd = Double(r), gd = Double(g), bd = Double(b)
                let maxC = max(rd, max(gd, bd))
                let minC = min(rd, min(gd, bd))
                let sat = (maxC > 0) ? (maxC - minC) / maxC : 0
                
                if sat > 0.3 && maxC < 150 && maxC > 10 {
                    // It's colorful but dark. Boost to at least 150 brightness.
                    let boost = 150.0 / maxC
                    let newR = min(rd * boost, 255)
                    let newG = min(gd * boost, 255)
                    let newB = min(bd * boost, 255)
                    return (UInt8(newR), UInt8(newG), UInt8(newB))
                }
                
                return bestColor
            }
            
            func sampleRectWeighted(rect: CGRect) -> (UInt8, UInt8, UInt8) {
                let xStart = max(0, Int(rect.origin.x))
                let yStart = max(0, Int(rect.origin.y))
                let w = min(width - xStart, Int(rect.width))
                let h = min(height - yStart, Int(rect.height))
                
                if w <= 0 || h <= 0 { return (0,0,0) }
                
                var totalR: Double = 0
                var totalG: Double = 0
                var totalB: Double = 0
                var totalWeight: Double = 0
                
                let step = 2 // Sample every 2nd pixel (since we are already downsampled)
                
                for y in stride(from: yStart, to: yStart + h, by: step) {
                    for x in stride(from: xStart, to: xStart + w, by: step) {
                        let offset = y * bytesPerRow + x * 4 // 4 bytes per pixel (BGRA)
                        let b = Double(ptr[offset])
                        let g = Double(ptr[offset + 1])
                        let r = Double(ptr[offset + 2])
                        // Alpha is offset + 3, ignored
                        
                        let maxC = max(r, max(g, b))
                        let minC = min(r, min(g, b))
                        let sat = (maxC > 0) ? (maxC - minC) / maxC : 0
                        let bri = maxC / 255.0
                        
                        // Weight formula: Saturation^3 (Very Aggressive) + Brightness
                        // We want to almost ignore grey/white if there is ANY color.
                        let weight = (sat * sat * sat * 5.0) + (bri * 0.2) + 0.01
                        
                        totalR += r * weight
                        totalG += g * weight
                        totalB += b * weight
                        totalWeight += weight
                    }
                }
                
                if totalWeight > 0 {
                    return (UInt8(totalR / totalWeight), UInt8(totalG / totalWeight), UInt8(totalB / totalWeight))
                } else {
                    return (0,0,0)
                }
            }
            
            func calculateVibrancyScore(r: UInt8, g: UInt8, b: UInt8) -> Double {
                let rd = Double(r)
                let gd = Double(g)
                let bd = Double(b)
                let maxC = max(rd, max(gd, bd))
                let minC = min(rd, min(gd, bd))
                let sat = (maxC > 0) ? (maxC - minC) / maxC : 0
                let bri = maxC / 255.0
                
                // Score: Heavily favor Saturation.
                // Pure Red: 3.0 + 0.5 = 3.5
                // White: 0 + 0.5 = 0.5
                // Grey: 0 + 0.25 = 0.25
                return (sat * 3.0) + (bri * 0.5)
            }
            
            // Adjust capture area based on mode
            var xOffset = 0
            var yOffset = 0
            var capWidth = width
            var capHeight = height
            
            switch mode {
            case .full:
                break
            case .cinema:
                // Ignore top/bottom 15%
                yOffset = Int(Double(height) * 0.15)
                capHeight = Int(Double(height) * 0.7)
            case .left:
                capWidth = width / 2
            case .right:
                xOffset = width / 2
                capWidth = width / 2
            }
            
            // Standard: Clockwise from Bottom-Left (Left -> Top -> Right -> Bottom)
            // Reverse: Counter-Clockwise from Bottom-Right (Right -> Top -> Left -> Bottom)
            
            var capturedColors: [(UInt8, UInt8, UInt8)] = []
            
            if orientation == .standard {
                // Standard: Clockwise from Bottom-Left
                // 1. Left Zone (Bottom -> Top)
                if config.left > 0 {
                    let hStep = capHeight / config.left
                    for i in 0..<config.left {
                        let y = yOffset + capHeight - ((i + 1) * hStep)
                        let rect = CGRect(x: xOffset, y: y, width: config.depth, height: hStep)
                        capturedColors.append(getVibrantColor(rect: rect))
                    }
                }
                // 2. Top Zone (Left -> Right)
                if config.top > 0 {
                    let wStep = capWidth / config.top
                    for i in 0..<config.top {
                        let x = xOffset + (i * wStep)
                        let rect = CGRect(x: x, y: yOffset, width: wStep, height: config.depth)
                        capturedColors.append(getVibrantColor(rect: rect))
                    }
                }
                // 3. Right Zone (Top -> Bottom)
                if config.right > 0 {
                    let hStep = capHeight / config.right
                    for i in 0..<config.right {
                        let y = yOffset + (i * hStep)
                        let rect = CGRect(x: xOffset + capWidth - config.depth, y: y, width: config.depth, height: hStep)
                        capturedColors.append(getVibrantColor(rect: rect))
                    }
                }
                // 4. Bottom Zone (Right -> Left)
                if config.bottom > 0 {
                    let wStep = capWidth / config.bottom
                    for i in 0..<config.bottom {
                        let x = xOffset + capWidth - ((i + 1) * wStep)
                        let rect = CGRect(x: x, y: yOffset + capHeight - config.depth, width: wStep, height: config.depth)
                        capturedColors.append(getVibrantColor(rect: rect))
                    }
                }
            } else {
                // Reverse: Counter-Clockwise from Bottom-Right
                // 1. Right Zone (Bottom -> Top)
                if config.right > 0 {
                    let hStep = capHeight / config.right
                    for i in 0..<config.right {
                        let y = yOffset + capHeight - ((i + 1) * hStep)
                        let rect = CGRect(x: xOffset + capWidth - config.depth, y: y, width: config.depth, height: hStep)
                        capturedColors.append(getVibrantColor(rect: rect))
                    }
                }
                // 2. Top Zone (Right -> Left)
                if config.top > 0 {
                    let wStep = capWidth / config.top
                    for i in 0..<config.top {
                        let x = xOffset + capWidth - ((i + 1) * wStep)
                        let rect = CGRect(x: x, y: yOffset, width: wStep, height: config.depth)
                        capturedColors.append(getVibrantColor(rect: rect))
                    }
                }
                // 3. Left Zone (Top -> Bottom)
                if config.left > 0 {
                    let hStep = capHeight / config.left
                    for i in 0..<config.left {
                        let y = yOffset + (i * hStep)
                        let rect = CGRect(x: xOffset, y: y, width: config.depth, height: hStep)
                        capturedColors.append(getVibrantColor(rect: rect))
                    }
                }
                // 4. Bottom Zone (Left -> Right)
                if config.bottom > 0 {
                    let wStep = capWidth / config.bottom
                    for i in 0..<config.bottom {
                        let x = xOffset + (i * wStep)
                        let rect = CGRect(x: x, y: yOffset + capHeight - config.depth, width: wStep, height: config.depth)
                        capturedColors.append(getVibrantColor(rect: rect))
                    }
                }
            }
            
            // --- Spatial Interpolation (Smoothing) ---
            var smoothedColors = capturedColors
            let n = capturedColors.count
            if n > 2 {
                for i in 0..<n {
                    let prev = capturedColors[(i - 1 + n) % n]
                    let curr = capturedColors[i]
                    let next = capturedColors[(i + 1) % n]
                    
                    let r = (Double(prev.0) * 0.25) + (Double(curr.0) * 0.5) + (Double(next.0) * 0.25)
                    let g = (Double(prev.1) * 0.25) + (Double(curr.1) * 0.5) + (Double(next.1) * 0.25)
                    let b = (Double(prev.2) * 0.25) + (Double(curr.2) * 0.5) + (Double(next.2) * 0.25)
                    
                    smoothedColors[i] = (UInt8(r), UInt8(g), UInt8(b))
                }
            }
            
            // --- Fluid Dynamics & Spring Physics Integration ---
            
            // Time Scaling (Normalize to 60 FPS)
            let timeScale = dt * 60.0
            
            // Update Flow Phase (The "Director" of the fluid)
            self.flowPhase += 0.05 * timeScale
            
            // Initialize springStates if size mismatch
            if self.springStates.count != smoothedColors.count {
                self.springStates = smoothedColors.map { 
                    (Double($0.0), Double($0.1), Double($0.2), 0.0, 0.0, 0.0) 
                }
            }
            
            let count = smoothedColors.count
            
            for i in 0..<count {
                let target = smoothedColors[i]
                var state = self.springStates[i]
                
                // Fluid Neighbors (Circular Buffer)
                let upstreamIdx = (i - 1 + count) % count
                let downstreamIdx = (i + 1) % count
                let upstream = self.springStates[upstreamIdx]
                let downstream = self.springStates[downstreamIdx]
                
                // 1. Dynamic Flow Field Generation
                // Create a "Flow Map" using Sine Wave to simulate liquid pulsing
                // This controls how strongly the fluid flows at this specific LED
                let flowVector = 0.12 + sin(Double(i) * 0.15 + self.flowPhase) * 0.08
                
                // 2. Fluid Coupling Forces
                
                // Advection: Upstream injects momentum and color into Downstream
                // "Upstream velocity and position inject into downstream"
                // We blend a portion of the upstream velocity/position difference
                let advectionR = (upstream.r - state.r) * flowVector + (upstream.vr - state.vr) * flowVector * 0.6
                let advectionG = (upstream.g - state.g) * flowVector + (upstream.vg - state.vg) * flowVector * 0.6
                let advectionB = (upstream.b - state.b) * flowVector + (upstream.vb - state.vb) * flowVector * 0.6
                
                // Viscosity/Drag: Downstream resistance pulls back
                // "Downstream resistance affects upstream"
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
                
                if dist > 100.0 {
                    tension = 0.45; friction = 0.35
                } else if dist < 5.0 {
                    tension = 0.015; friction = 0.60
                } else {
                    let t = (dist - 5.0) / 95.0
                    tension = 0.02 + (t * 0.43)
                    friction = 0.60 - (t * 0.25)
                }
                
                // 4. Integration (Euler)
                // Total Force = Spring Force + Advection + Drag
                
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
                self.springStates[i] = state
                
                // Clamp and Assign
                let finalR = UInt8(min(max(state.r, 0), 255))
                let finalG = UInt8(min(max(state.g, 0), 255))
                let finalB = UInt8(min(max(state.b, 0), 255))
                
                smoothedColors[i] = (finalR, finalG, finalB)
            }
            
            for color in smoothedColors {
                ledData.append(color.0)
                ledData.append(color.1)
                ledData.append(color.2)
            }
            
            // Padding or Truncating
            let currentLeds = ledData.count / 3
            if currentLeds < ledCount {
                let remaining = ledCount - currentLeds
                for _ in 0..<remaining {
                    ledData.append(0)
                    ledData.append(0)
                    ledData.append(0)
                }
            } else if currentLeds > ledCount {
                // Truncate if we have more data than the configured total
                let maxBytes = ledCount * 3
                if ledData.count > maxBytes {
                    ledData = Array(ledData.prefix(maxBytes))
                }
            }
            
            return ledData
    }
    
    // Old method kept for compatibility but unused
    func captureAndProcess(display: SCDisplay, config: ZoneConfig, ledCount: Int, mode: SyncMode, orientation: ScreenOrientation, useDominantColor: Bool) async -> [UInt8] {
        return []
    }
}
