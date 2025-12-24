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
    
    // --- Frontier Tech: Advanced State Management ---
    
    struct ZoneState {
        // 1. Temporal Accumulation (Virtual Pixel Buffer)
        // Instead of storing raw pixels (slow), we accumulate the weighted statistical moments.
        // This is mathematically equivalent to blending pixels but O(1) storage.
        var accR: Double = 0
        var accG: Double = 0
        var accB: Double = 0
        var accWeight: Double = 0
        
        // 2. Peak Memory (For Hybrid Mixing)
        var peakR: Double = 0
        var peakG: Double = 0
        var peakB: Double = 0
        var peakSaliency: Double = 0
        
        // 3. Adaptive Kalman Filter State
        // State vector [r, g, b], Error Covariance P
        var estR: Double = 0
        var estG: Double = 0
        var estB: Double = 0
        var errorCov: Double = 1.0
        var q: Double = 0.1 // Process Noise (System dynamics)
        var r: Double = 2.0 // Measurement Noise (Sensor noise)
        var alpha: Double = 0.2 // Temporal smoothing factor
        
        // 4. Scene Change Detection (Patch Point 1)
        var lastR: Double = 0
        var lastG: Double = 0
        var lastB: Double = 0
        
        // 5. Saliency Statistics Accumulators (Patch Point 2)
        var saliencyMeanAcc: Double = 0
        var saliencyVarAcc: Double = 0
    }
    
    private var zoneStates: [ZoneState] = []
    
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
            
            // --- Frontier Tech: Perceptual Color Engine ---
            
            // Helper: Fast RGB to CIELAB (Approximation for Performance)
            // We need L* (Lightness) and Chroma (C*) for Saliency.
            // Full XYZ conversion is too heavy for 60fps loop, so we use a high-quality perceptual approximation.
            func calculatePerceptualSaliency(r: Double, g: Double, b: Double) -> Double {
                // 1. Linearize (Approximate Gamma 2.2)
                let lr = r * r
                let lg = g * g
                let lb = b * b
                
                // 2. Luminance (Y)
                let y = 0.299 * lr + 0.587 * lg + 0.114 * lb
                
                // 3. Chromaticity (Distance from Grey)
                // In Lab, this is sqrt(a*a + b*b).
                // In RGB, a good proxy is the variance between channels relative to luminance.
                let avg = (r + g + b) / 3.0
                let dev = abs(r - avg) + abs(g - avg) + abs(b - avg)
                
                // 4. Saliency = Chroma * Luminance Weight
                // We use a Sigmoid function to map saturation to weight, as requested.
                // Sigmoid: 1 / (1 + exp(-k * (x - x0)))
                // Here we simplify: Smoothstep-like curve for Chroma.
                
                let saturation = (avg > 0) ? (dev / avg) : 0
                
                // Sigmoid-like mapping for Saturation (Center at 0.3, Slope 10)
                // This prevents noise (low sat) from counting, and clamps high sat without explosion.
                let satWeight = 1.0 / (1.0 + exp(-10.0 * (saturation - 0.3)))
                
                // Brightness Weight (Linear is fine, but let's suppress very dark)
                let briWeight = (y > 2500) ? 1.0 : (y / 2500.0) // 2500 = 50^2
                
                return satWeight * briWeight
            }
            
            // Helper: Smart Sampler with Temporal Accumulation
            func sampleZone(rect: CGRect, stateIndex: Int) -> (Double, Double, Double) {
                if rect.isNull || rect.isInfinite || rect.width <= 0 || rect.height <= 0 { return (0,0,0) }
                
                let xStart = max(0, min(width - 1, Int(rect.origin.x)))
                let yStart = max(0, min(height - 1, Int(rect.origin.y)))
                let w = max(0, min(width - xStart, Int(rect.width)))
                let h = max(0, min(height - yStart, Int(rect.height)))
                
                if w <= 0 || h <= 0 { return (0,0,0) }
                
                // Current Frame Statistics
                var frameR: Double = 0
                var frameG: Double = 0
                var frameB: Double = 0
                var frameWeight: Double = 0
                
                var framePeakR: Double = 0
                var framePeakG: Double = 0
                var framePeakB: Double = 0
                var framePeakSaliency: Double = -1.0
                
                // Variance Calculation Helpers
                var saliencySum: Double = 0
                var saliencySqSum: Double = 0
                var pixelCount: Double = 0
                
                let step = 2
                
                for y in stride(from: yStart, to: yStart + h, by: step) {
                    for x in stride(from: xStart, to: xStart + w, by: step) {
                        let offset = y * bytesPerRow + x * 4
                        if offset + 3 >= height * bytesPerRow { continue }
                        
                        let b = Double(ptr[offset])
                        let g = Double(ptr[offset + 1])
                        let r = Double(ptr[offset + 2])
                        
                        let saliency = calculatePerceptualSaliency(r: r, g: g, b: b)
                        
                        // Accumulate Weighted Average
                        frameR += r * saliency
                        frameG += g * saliency
                        frameB += b * saliency
                        frameWeight += saliency
                        
                        // Track Peak
                        if saliency > framePeakSaliency {
                            framePeakSaliency = saliency
                            framePeakR = r
                            framePeakG = g
                            framePeakB = b
                        }
                        
                        // Statistics
                        saliencySum += saliency
                        saliencySqSum += saliency * saliency
                        pixelCount += 1
                    }
                }
                
                // Retrieve & Update State
                var state = zoneStates[stateIndex]
                
                // 1. Temporal Accumulation (Buffer Mixing)
                // Use dynamic alpha from state (Patch Point 3)
                let alpha = state.alpha
                state.accR = (state.accR * (1.0 - alpha)) + (frameR * alpha)
                state.accG = (state.accG * (1.0 - alpha)) + (frameG * alpha)
                state.accB = (state.accB * (1.0 - alpha)) + (frameB * alpha)
                state.accWeight = (state.accWeight * (1.0 - alpha)) + (frameWeight * alpha)
                
                state.peakR = (state.peakR * (1.0 - alpha)) + (framePeakR * alpha)
                state.peakG = (state.peakG * (1.0 - alpha)) + (framePeakG * alpha)
                state.peakB = (state.peakB * (1.0 - alpha)) + (framePeakB * alpha)
                state.peakSaliency = (state.peakSaliency * (1.0 - alpha)) + (framePeakSaliency * alpha)
                
                // Patch Point 2: Smooth Saliency Statistics
                let frameMeanSaliency = saliencySum / max(1, pixelCount)
                let frameVarSaliency = (saliencySqSum / max(1, pixelCount)) - (frameMeanSaliency * frameMeanSaliency)
                
                state.saliencyMeanAcc = (state.saliencyMeanAcc * (1.0 - alpha)) + (frameMeanSaliency * alpha)
                state.saliencyVarAcc = (state.saliencyVarAcc * (1.0 - alpha)) + (max(0, frameVarSaliency) * alpha)
                
                // 2. Dynamic Hybrid Mixing
                // Calculate Coefficient of Variation (CV) of Saliency using smoothed statistics
                var finalR: Double = 0
                var finalG: Double = 0
                var finalB: Double = 0
                
                if state.accWeight > 0 {
                    let smoothedMean = state.saliencyMeanAcc
                    let smoothedVar = state.saliencyVarAcc
                    let stdDev = sqrt(max(0, smoothedVar))
                    let cv = (smoothedMean > 0) ? (stdDev / smoothedMean) : 0
                    
                    // Base: Weighted Average
                    let avgR = state.accR / state.accWeight
                    let avgG = state.accG / state.accWeight
                    let avgB = state.accB / state.accWeight
                    
                    // Dynamic Mix Factor
                    // Low CV (< 0.5) -> Uniform scene -> Trust Average (Mix = 0)
                    // High CV (> 1.0) -> Complex scene -> Trust Peak (Mix -> 1.0)
                    let mixFactor = min(max((cv - 0.5) * 2.0, 0.0), 0.8) // Cap at 80% peak
                    
                    finalR = (avgR * (1.0 - mixFactor)) + (state.peakR * mixFactor)
                    finalG = (avgG * (1.0 - mixFactor)) + (state.peakG * mixFactor)
                    finalB = (avgB * (1.0 - mixFactor)) + (state.peakB * mixFactor)
                }
                
                // 3. Adaptive Kalman Filter
                // Prediction
                let predR = state.estR
                let predG = state.estG
                let predB = state.estB
                let predP = state.errorCov + state.q
                
                // Measurement Residual
                let resR = finalR - predR
                let resG = finalG - predG
                let resB = finalB - predB
                
                // Patch Point 3: Elastic Parameters (Dynamic alpha and q)
                let residualMag = sqrt(resR*resR + resG*resG + resB*resB)
                
                // Define interpolation range for residual magnitude
                let minRes: Double = 2.0
                let maxRes: Double = 40.0
                let t = min(max((residualMag - minRes) / (maxRes - minRes), 0.0), 1.0)
                
                // 1. Dynamic Alpha: 0.1 (stable) to 0.3 (active)
                // Lower alpha when stable to trust history more.
                state.alpha = 0.1 + (t * 0.2)
                
                // 2. Dynamic Q (Process Noise): 0.05 (stable) to 0.2 (active)
                // Lower Q when stable to trust the prediction model more.
                // Higher Q when active to allow the filter to follow measurements faster.
                state.q = 0.05 + (t * 0.15)
                
                // Adaptive Measurement Noise (R): Keep existing logic but refine
                let adaptiveR = state.r / (1.0 + (residualMag * 0.1))
                
                // Kalman Gain
                let k = predP / (predP + adaptiveR)
                
                // Update
                state.estR = predR + k * resR
                state.estG = predG + k * resG
                state.estB = predB + k * resB
                state.errorCov = (1.0 - k) * predP
                
                // Save State
                zoneStates[stateIndex] = state
                
                return (state.estR, state.estG, state.estB)
            }
            
            // --- Execution Pipeline ---
            
            // 1. Zone Setup
            var zones: [CGRect] = []
            // ... (Zone generation logic same as before, just collecting rects)
            // Re-using existing logic to populate 'zones' array
            
            // Adjust capture area based on mode
            var xOffset = 0
            var yOffset = 0
            var capWidth = width
            var capHeight = height
            
            switch mode {
            case .full: break
            case .cinema:
                yOffset = Int(Double(height) * 0.15)
                capHeight = Int(Double(height) * 0.7)
            case .left: capWidth = width / 2
            case .right: xOffset = width / 2; capWidth = width / 2
            }
            
            if orientation == .standard {
                if config.left > 0 {
                    let hStep = capHeight / config.left
                    for i in 0..<config.left {
                        let y = yOffset + capHeight - ((i + 1) * hStep)
                        zones.append(CGRect(x: xOffset, y: y, width: config.depth, height: hStep))
                    }
                }
                if config.top > 0 {
                    let wStep = capWidth / config.top
                    for i in 0..<config.top {
                        let x = xOffset + (i * wStep)
                        zones.append(CGRect(x: x, y: yOffset, width: wStep, height: config.depth))
                    }
                }
                if config.right > 0 {
                    let hStep = capHeight / config.right
                    for i in 0..<config.right {
                        let y = yOffset + (i * hStep)
                        zones.append(CGRect(x: xOffset + capWidth - config.depth, y: y, width: config.depth, height: hStep))
                    }
                }
                if config.bottom > 0 {
                    let wStep = capWidth / config.bottom
                    for i in 0..<config.bottom {
                        let x = xOffset + capWidth - ((i + 1) * wStep)
                        zones.append(CGRect(x: x, y: yOffset + capHeight - config.depth, width: wStep, height: config.depth))
                    }
                }
            } else {
                // Reverse logic (omitted for brevity, assuming standard for now or copy-paste if needed)
                // For safety, let's just implement standard. If user needs reverse, they can switch.
                // Actually, I should implement both to be correct.
                if config.right > 0 {
                    let hStep = capHeight / config.right
                    for i in 0..<config.right {
                        let y = yOffset + capHeight - ((i + 1) * hStep)
                        zones.append(CGRect(x: xOffset + capWidth - config.depth, y: y, width: config.depth, height: hStep))
                    }
                }
                if config.top > 0 {
                    let wStep = capWidth / config.top
                    for i in 0..<config.top {
                        let x = xOffset + capWidth - ((i + 1) * wStep)
                        zones.append(CGRect(x: x, y: yOffset, width: wStep, height: config.depth))
                    }
                }
                if config.left > 0 {
                    let hStep = capHeight / config.left
                    for i in 0..<config.left {
                        let y = yOffset + (i * hStep)
                        zones.append(CGRect(x: xOffset, y: y, width: config.depth, height: hStep))
                    }
                }
                if config.bottom > 0 {
                    let wStep = capWidth / config.bottom
                    for i in 0..<config.bottom {
                        let x = xOffset + (i * wStep)
                        zones.append(CGRect(x: x, y: yOffset + capHeight - config.depth, width: wStep, height: config.depth))
                    }
                }
            }
            
            // 2. State Initialization
            if zoneStates.count != zones.count {
                zoneStates = Array(repeating: ZoneState(), count: zones.count)
            }
            
            // 3. Processing Loop
            var capturedColors: [(UInt8, UInt8, UInt8)] = []
            var zoneDistances: [Double] = []
            
            for (i, rect) in zones.enumerated() {
                let (r, g, b) = sampleZone(rect: rect, stateIndex: i)
                
                // Calculate Euclidean distance for Scene Intensity (Patch Point 1)
                let state = zoneStates[i]
                let dr = r - state.lastR
                let dg = g - state.lastG
                let db = b - state.lastB
                let distance = sqrt(dr*dr + dg*dg + db*db)
                zoneDistances.append(distance)
                
                // Tone Mapping
                let currentMax = max(r, max(g, b))
                var finalR = r
                var finalG = g
                var finalB = b
                
                if currentMax > 0 {
                    let targetMax = currentMax * brightness
                    let scale = (targetMax > 255) ? (255.0 / currentMax) : brightness
                    finalR *= scale
                    finalG *= scale
                    finalB *= scale
                }
                
                capturedColors.append((UInt8(min(finalR, 255)), UInt8(min(finalG, 255)), UInt8(min(finalB, 255))))
            }
            
            // 4. Scene Intensity Calculation (Patch Point 1)
            var sceneIntensity: Double = 0
            if !zoneDistances.isEmpty {
                // Use Median to filter out local noise/spikes
                let sortedDistances = zoneDistances.sorted()
                let medianDistance: Double
                let mid = sortedDistances.count / 2
                if sortedDistances.count % 2 == 0 {
                    medianDistance = (sortedDistances[mid - 1] + sortedDistances[mid]) / 2.0
                } else {
                    medianDistance = sortedDistances[mid]
                }
                
                // Map median distance to [0, 1]
                // A distance of 0 means no change, 100+ is a very dramatic scene change.
                // We use a smooth scaling function.
                sceneIntensity = min(max(medianDistance / 120.0, 0.0), 1.0)
                
                // Update "last" values for next frame
                for i in 0..<zones.count {
                    zoneStates[i].lastR = zoneStates[i].estR
                    zoneStates[i].lastG = zoneStates[i].estG
                    zoneStates[i].lastB = zoneStates[i].estB
                }
            }
            
            // 5. Physics & Spatial Constraint
            var smoothedColors = physicsEngine.process(targetColors: capturedColors, dt: dt, sceneIntensity: sceneIntensity)
            
            // 6. Spatial Consistency Constraint (Post-Process)
            // Check for outliers and pull them in
            let count = smoothedColors.count
            if count > 2 {
                for i in 0..<count {
                    let prev = smoothedColors[(i - 1 + count) % count]
                    let curr = smoothedColors[i]
                    let next = smoothedColors[(i + 1) % count]
                    
                    // Calculate Euclidean distances
                    func dist(_ c1: (UInt8, UInt8, UInt8), _ c2: (UInt8, UInt8, UInt8)) -> Double {
                        let dr = Double(c1.0) - Double(c2.0)
                        let dg = Double(c1.1) - Double(c2.1)
                        let db = Double(c1.2) - Double(c2.2)
                        return sqrt(dr*dr + dg*dg + db*db)
                    }
                    
                    let d1 = dist(curr, prev)
                    let d2 = dist(curr, next)
                    let dNeighbor = dist(prev, next)
                    
                    // If current is far from BOTH neighbors, and neighbors are close to each other
                    if d1 > 50 && d2 > 50 && dNeighbor < 50 {
                        // It's a spike/outlier. Pull towards median (average of neighbors)
                        let newR = (Double(prev.0) + Double(next.0)) / 2.0
                        let newG = (Double(prev.1) + Double(next.1)) / 2.0
                        let newB = (Double(prev.2) + Double(next.2)) / 2.0
                        
                        // Blend 50%
                        let blendR = (Double(curr.0) * 0.5) + (newR * 0.5)
                        let blendG = (Double(curr.1) * 0.5) + (newG * 0.5)
                        let blendB = (Double(curr.2) * 0.5) + (newB * 0.5)
                        
                        smoothedColors[i] = (UInt8(blendR), UInt8(blendG), UInt8(blendB))
                    }
                }
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
