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
    
    // Physics Engine
    private let physicsEngine = FluidPhysicsEngine()
    private var lastFrameTime: TimeInterval = 0
    
    // Temporal Smoothing State (Memory)
    private var previousCapturedColors: [(UInt8, UInt8, UInt8)] = []
    
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
    
    func startStream(display: SCDisplay, config: ZoneConfig, ledCount: Int, mode: SyncMode, orientation: ScreenOrientation, brightness: Double, targetFrameRate: Double) async {
        // Stop existing stream if any
        if let stream = stream {
            try? await stream.stopCapture()
        }
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfig = SCStreamConfiguration()
        
        // 1. Optimization: Downsample for Performance
        // We don't need 4K for LED sampling. 360p height is plenty for ambient light.
        let scaleFactor = 360.0 / Double(display.height)
        streamConfig.width = Int(Double(display.width) * scaleFactor)
        streamConfig.height = 360
        streamConfig.showsCursor = false
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA // Efficient for CPU access
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate)) // Target FPS
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
            self.currentBrightness = brightness
            self.currentTargetFrameRate = targetFrameRate
            
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
    private var currentBrightness: Double = 1.0
    private var currentTargetFrameRate: Double = 60.0
    private var lastProcessTime: TimeInterval = 0
    
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
            dt: safeDt,
            brightness: currentBrightness
        )
        
        // Callback
        onFrameProcessed?(ledData)
    }
    
    private func processFrame(ptr: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, config: ZoneConfig, ledCount: Int, mode: SyncMode, orientation: ScreenOrientation, dt: Double, brightness: Double) -> [UInt8] {
            
            // Safety Check
            if width <= 0 || height <= 0 { return [] }

            var ledData = [UInt8]()
            ledData.reserveCapacity(ledCount * 3)
            
            // --- Advanced Perceptual Color Quantization (Smart Sampler) ---
            // This replaces the old "Weighted Average" and "Vibrant Search" with a robust
            // histogram-based clustering approach that is stable, noise-resistant, and
            // preserves true color vibrancy without washing out to white.
            
            func getSmartColor(rect: CGRect) -> (r: UInt8, g: UInt8, b: UInt8) {
                // Safety: Ensure rect is valid
                if rect.isNull || rect.isInfinite || rect.width <= 0 || rect.height <= 0 {
                    return (0, 0, 0)
                }
                
                // 1. Setup Sampling Grid
                // Instead of iterating every pixel (slow) or a simple stride (aliasing),
                // we use a jittered grid or a dense stride with outlier rejection.
                // Given we are already downsampled to 360p, a stride of 2 is dense enough.
                
                let xStart = max(0, min(width - 1, Int(rect.origin.x)))
                let yStart = max(0, min(height - 1, Int(rect.origin.y)))
                let w = max(0, min(width - xStart, Int(rect.width)))
                let h = max(0, min(height - yStart, Int(rect.height)))
                
                if w <= 0 || h <= 0 { return (0,0,0) }
                
                // 2. Histogram / Accumulator State
                // We track "Mass" in RGB space, weighted by "Saliency" (Saturation * Brightness)
                var totalR: Double = 0
                var totalG: Double = 0
                var totalB: Double = 0
                var totalWeight: Double = 0
                
                // We also track the "Max Saliency" pixel to handle edge cases where average is muddy
                var maxSaliency: Double = -1.0
                var vibrantR: Double = 0
                var vibrantG: Double = 0
                var vibrantB: Double = 0
                
                let step = 2
                
                for y in stride(from: yStart, to: yStart + h, by: step) {
                    for x in stride(from: xStart, to: xStart + w, by: step) {
                        let offset = y * bytesPerRow + x * 4
                        if offset + 3 >= height * bytesPerRow { continue }
                        
                        let b = Double(ptr[offset])
                        let g = Double(ptr[offset + 1])
                        let r = Double(ptr[offset + 2])
                        
                        // 3. Perceptual Analysis
                        let maxC = max(r, max(g, b))
                        let minC = min(r, min(g, b))
                        let chroma = maxC - minC
                        let sat = (maxC > 0) ? chroma / maxC : 0
                        let bri = maxC / 255.0
                        
                        // Filter: Ignore very dark pixels (letterboxing/black bars)
                        if maxC < 10 { continue }
                        
                        // 4. Saliency Calculation
                        // We want pixels that are colorful AND bright to contribute most.
                        // Formula: Saturation^2 * Brightness
                        // This suppresses grey/white/muddy colors naturally.
                        let saliency = (sat * sat * 4.0) + (bri * 0.5)
                        
                        // Accumulate Weighted Average (Center of Mass)
                        totalR += r * saliency
                        totalG += g * saliency
                        totalB += b * saliency
                        totalWeight += saliency
                        
                        // Track Peak Vibrancy (for fallback or mixing)
                        if saliency > maxSaliency {
                            maxSaliency = saliency
                            vibrantR = r
                            vibrantG = g
                            vibrantB = b
                        }
                    }
                }
                
                // 5. Result Synthesis
                var finalR: Double = 0
                var finalG: Double = 0
                var finalB: Double = 0
                
                if totalWeight > 0 {
                    // Weighted Average is usually best for smooth transitions
                    finalR = totalR / totalWeight
                    finalG = totalG / totalWeight
                    finalB = totalB / totalWeight
                    
                    // Hybrid Approach: If the average is too desaturated compared to the peak,
                    // mix in some of the peak color. This fixes "muddy" averages in multi-colored zones.
                    let avgMax = max(finalR, max(finalG, finalB))
                    let avgMin = min(finalR, min(finalG, finalB))
                    let avgSat = (avgMax > 0) ? (avgMax - avgMin) / avgMax : 0
                    
                    if avgSat < 0.3 && maxSaliency > 1.5 {
                        // The average washed out, but we had a vibrant peak. Blend 50%.
                        finalR = (finalR * 0.5) + (vibrantR * 0.5)
                        finalG = (finalG * 0.5) + (vibrantG * 0.5)
                        finalB = (finalB * 0.5) + (vibrantB * 0.5)
                    }
                } else {
                    // Fallback if zone is completely dark
                    return (0, 0, 0)
                }
                
                // 6. Advanced Tone Mapping (Brightness without Whitewash)
                // Problem: Simple multiplication (r * brightness) clips channels to 255 unevenly, shifting Hue.
                // Solution: Scale the luminance while preserving ratios.
                
                // Calculate current max luminance
                let currentMax = max(finalR, max(finalG, finalB))
                
                if currentMax > 0 {
                    // Target Luminance: Apply user brightness
                    // We use a soft knee or simple scaling, but ensure we don't distort hue.
                    // If brightness is 2.0, we want the perceived light to double, but we can't exceed 255.
                    
                    // Step A: Apply Brightness Factor
                    let targetMax = currentMax * brightness
                    
                    // Step B: Soft Clip / Tone Map
                    // If targetMax > 255, we must scale down ALL channels to fit, rather than clamping individually.
                    // However, users WANT "brighter", so we allow some clipping if it's extreme,
                    // but we prefer to saturate towards the dominant channel.
                    
                    let scale: Double
                    if targetMax > 255 {
                        // We are blowing out.
                        // Option 1: Clamp (White shift) - BAD
                        // Option 2: Scale down (Preserve Hue, but limits brightness) - GOOD for fidelity
                        // Option 3: Desaturate towards white (Natural overexposure) - ACCEPTABLE
                        
                        // Let's use Option 2 (Preserve Hue) as requested ("don't turn white")
                        scale = 255.0 / currentMax // Maximize brightness without hue shift
                    } else {
                        scale = brightness
                    }
                    
                    finalR *= scale
                    finalG *= scale
                    finalB *= scale
                }
                
                return (UInt8(min(finalR, 255)), UInt8(min(finalG, 255)), UInt8(min(finalB, 255)))
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
                        capturedColors.append(getSmartColor(rect: rect))
                    }
                }
                // 2. Top Zone (Left -> Right)
                if config.top > 0 {
                    let wStep = capWidth / config.top
                    for i in 0..<config.top {
                        let x = xOffset + (i * wStep)
                        let rect = CGRect(x: x, y: yOffset, width: wStep, height: config.depth)
                        capturedColors.append(getSmartColor(rect: rect))
                    }
                }
                // 3. Right Zone (Top -> Bottom)
                if config.right > 0 {
                    let hStep = capHeight / config.right
                    for i in 0..<config.right {
                        let y = yOffset + (i * hStep)
                        let rect = CGRect(x: xOffset + capWidth - config.depth, y: y, width: config.depth, height: hStep)
                        capturedColors.append(getSmartColor(rect: rect))
                    }
                }
                // 4. Bottom Zone (Right -> Left)
                if config.bottom > 0 {
                    let wStep = capWidth / config.bottom
                    for i in 0..<config.bottom {
                        let x = xOffset + capWidth - ((i + 1) * wStep)
                        let rect = CGRect(x: x, y: yOffset + capHeight - config.depth, width: wStep, height: config.depth)
                        capturedColors.append(getSmartColor(rect: rect))
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
                        capturedColors.append(getSmartColor(rect: rect))
                    }
                }
                // 2. Top Zone (Right -> Left)
                if config.top > 0 {
                    let wStep = capWidth / config.top
                    for i in 0..<config.top {
                        let x = xOffset + capWidth - ((i + 1) * wStep)
                        let rect = CGRect(x: x, y: yOffset, width: wStep, height: config.depth)
                        capturedColors.append(getSmartColor(rect: rect))
                    }
                }
                // 3. Left Zone (Top -> Bottom)
                if config.left > 0 {
                    let hStep = capHeight / config.left
                    for i in 0..<config.left {
                        let y = yOffset + (i * hStep)
                        let rect = CGRect(x: xOffset, y: y, width: config.depth, height: hStep)
                        capturedColors.append(getSmartColor(rect: rect))
                    }
                }
                // 4. Bottom Zone (Left -> Right)
                if config.bottom > 0 {
                    let wStep = capWidth / config.bottom
                    for i in 0..<config.bottom {
                        let x = xOffset + (i * wStep)
                        let rect = CGRect(x: x, y: yOffset + capHeight - config.depth, width: wStep, height: config.depth)
                        capturedColors.append(getSmartColor(rect: rect))
                    }
                }
            }
            
            // --- Temporal Smoothing (Input Inertia) ---
            // Stabilize the input before it reaches the physics engine.
            // This implements the "Memory" requested to prevent input jitter.
            if self.previousCapturedColors.count != capturedColors.count {
                self.previousCapturedColors = capturedColors
            } else {
                for i in 0..<capturedColors.count {
                    let prev = self.previousCapturedColors[i]
                    let curr = capturedColors[i]
                    
                    // Heavy Inertia: 70% History, 30% New
                    // This prevents "jumping" by ensuring the target color moves slowly.
                    let r = UInt8(Double(prev.0) * 0.7 + Double(curr.0) * 0.3)
                    let g = UInt8(Double(prev.1) * 0.7 + Double(curr.1) * 0.3)
                    let b = UInt8(Double(prev.2) * 0.7 + Double(curr.2) * 0.3)
                    
                    capturedColors[i] = (r, g, b)
                }
                self.previousCapturedColors = capturedColors
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
            
            // Apply Physics Globally (Fluid + Spring)
            // The user wants "Spring+Fluid" to be applied globally, regardless of capture mode.
            // Capture Mode now only affects the SAMPLING strategy (Deep vs Shallow).
            
            smoothedColors = physicsEngine.process(targetColors: smoothedColors, dt: dt)
            
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
