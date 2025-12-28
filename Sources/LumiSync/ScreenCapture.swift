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
}

class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    
    private var stream: SCStream?
    private let processingQueue = DispatchQueue(label: "com.lumisync.processing", qos: .userInteractive)
    
    // Callback for sending data back to AppState
    var onFrameProcessed: (([UInt8]) -> Void)?
    
    // Physics Engine
    private let physicsEngine = FluidPhysicsEngine()
    private var lastFrameTime: TimeInterval = 0
    private var currentOriginPreference = OriginPreference(mode: .auto, manualNormalized: 0.5)
    
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
    
    func startStream(display: SCDisplay, config: ZoneConfig, ledCount: Int, orientation: ScreenOrientation, brightness: Double, targetFrameRate: Double, calibration: (r: Double, g: Double, b: Double), gamma: Double, saturation: Double, originPreference: OriginPreference) async {
        // Stop existing stream if any
        if let stream = stream {
            try? await stream.stopCapture()
        }
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfig = SCStreamConfiguration()
        
        // 1. Optimization: Downsample for Performance
        let scaleFactor = 360.0 / Double(display.height)
        streamConfig.width = Int(Double(display.width) * scaleFactor)
        streamConfig.height = 360
        streamConfig.showsCursor = false
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        streamConfig.queueDepth = 3
        
        do {
            let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
            
            // Patch Point 1: Synchronize state updates on the processing queue to prevent race conditions
            processingQueue.sync {
                self.currentConfig = config
                self.currentLedCount = ledCount
                self.currentOrientation = orientation
                self.currentBrightness = brightness
                self.currentTargetFrameRate = targetFrameRate
                self.currentCalibration = calibration
                self.currentGamma = gamma
                self.currentSaturation = saturation
                self.currentOriginPreference = originPreference
                
                self.zoneStates.removeAll()
                self.physicsEngine.reset()
                self.lastFrameTime = 0
                self.lastProcessTime = 0
                self.lastOutputColors.removeAll()
                self.currentSceneIntensity = 0.0
            }
            
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
            try await stream.startCapture()
            self.stream = stream
            
        } catch {
            // Stream start failed
        }
    }
    
    func stopStream() async {
        if let stream = stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
    }
    
    // Stored context for the stream delegate
    private var currentConfig: ZoneConfig = ZoneConfig(left:0, top:0, right:0, bottom:0)
    private var currentLedCount: Int = 0
    private var currentOrientation: ScreenOrientation = .standard
    private var currentBrightness: Double = 1.0
    private var currentTargetFrameRate: Double = 60.0
    private var currentCalibration: (r: Double, g: Double, b: Double) = (1.0, 1.0, 1.0)
    private var currentGamma: Double = 1.0
    private var currentSaturation: Double = 1.0
    private var lastProcessTime: TimeInterval = 0
    private var lastOutputColors: [(UInt8, UInt8, UInt8)] = []
    private var currentSceneIntensity: Double = 0.0
    
    // MARK: - SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stream stopped
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
            orientation: currentOrientation,
            dt: safeDt,
            brightness: currentBrightness
        )
        
        // Callback
        onFrameProcessed?(ledData)
    }
    
    private func processFrame(ptr: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, config: ZoneConfig, ledCount: Int, orientation: ScreenOrientation, dt: Double, brightness: Double) -> [UInt8] {
            
            // Safety Check
            if width <= 0 || height <= 0 { return [] }

            var ledData = [UInt8]()
            ledData.reserveCapacity(ledCount * 3)
            
            // --- Frontier Tech: Perceptual Color Engine ---
            
            struct Accumulator {
                var r: Double = 0
                var g: Double = 0
                var b: Double = 0
                var weight: Double = 0
                var peakR: Double = 0
                var peakG: Double = 0
                var peakB: Double = 0
                var peakSaliency: Double = -1.0
                var saliencySum: Double = 0
                var saliencySqSum: Double = 0
                var pixelCount: Double = 0
            }
            
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
                
                // Sigmoid-like mapping for Saturation (Center at 0.4, Slope 15)
                // We move the center up and increase slope to aggressively favor highly saturated colors.
                // This ensures that vibrant "peaks" dominate the sampling weight.
                let satWeight = 1.0 / (1.0 + exp(-15.0 * (saturation - 0.4)))
                
                // Brightness Weight (Linear is fine, but let's suppress very dark)
                let briWeight = (y > 1600) ? 1.0 : (y / 1600.0) // 1600 = 40^2, slightly lower threshold
                
                return satWeight * briWeight
            }
            
            // --- Execution Pipeline ---
            
            // 1. Setup Capture Area
            let xOffset = 0
            let yOffset = 0
            let capWidth = width
            let capHeight = height
            
            // 2. Perspective Origin (Golden Ratio Point on Vertical Center Line or manual override)
            let originX = Double(xOffset) + Double(capWidth) / 2.0
            let normalizedOriginY = normalizedOriginY(for: config)
            let originY = Double(yOffset) + normalizedOriginY * Double(capHeight)
            
            // 3. Generate Perimeter Boundary Points for LEDs (Always CW: BL -> TL -> TR -> BR -> BL)
            var boundaryPoints: [CGPoint] = []
            // Left: BL -> TL
            if config.left > 0 {
                for i in 0...config.left {
                    let y = Double(yOffset + capHeight) - Double(i) * (Double(capHeight) / Double(config.left))
                    boundaryPoints.append(CGPoint(x: Double(xOffset), y: y))
                }
            } else {
                boundaryPoints.append(CGPoint(x: Double(xOffset), y: Double(yOffset + capHeight)))
            }
            // Top: TL -> TR
            if config.top > 0 {
                if !boundaryPoints.isEmpty { boundaryPoints.removeLast() }
                for i in 0...config.top {
                    let x = Double(xOffset) + Double(i) * (Double(capWidth) / Double(config.top))
                    boundaryPoints.append(CGPoint(x: x, y: Double(yOffset)))
                }
            }
            // Right: TR -> BR
            if config.right > 0 {
                if !boundaryPoints.isEmpty { boundaryPoints.removeLast() }
                for i in 0...config.right {
                    let y = Double(yOffset) + Double(i) * (Double(capHeight) / Double(config.right))
                    boundaryPoints.append(CGPoint(x: Double(xOffset + capWidth), y: y))
                }
            }
            // Bottom: BR -> BL
            if config.bottom > 0 {
                if !boundaryPoints.isEmpty { boundaryPoints.removeLast() }
                for i in 0...config.bottom {
                    let x = Double(xOffset + capWidth) - Double(i) * (Double(capWidth) / Double(config.bottom))
                    boundaryPoints.append(CGPoint(x: x, y: Double(yOffset + capHeight)))
                }
            }
            
            let totalZones = config.left + config.top + config.right + config.bottom
            if totalZones <= 0 { return [] }
            
            // 4. Calculate Boundary Angles
            var boundaryAngles: [Double] = []
            for p in boundaryPoints {
                boundaryAngles.append(atan2(p.y - originY, p.x - originX))
            }
            
            // Normalize angles to be strictly increasing
            if !boundaryAngles.isEmpty {
                var lastA = boundaryAngles[0]
                for i in 1..<boundaryAngles.count {
                    while boundaryAngles[i] <= lastA {
                        boundaryAngles[i] += 2.0 * .pi
                    }
                    lastA = boundaryAngles[i]
                }
            }
            guard let lowerBound = boundaryAngles.first, var upperBound = boundaryAngles.last else {
                return []
            }
            if upperBound <= lowerBound {
                upperBound = lowerBound + 2.0 * .pi
            }
            
            // 5. Processing Loop (Polar Binning)
            var accumulators = Array(repeating: Accumulator(), count: totalZones)
            let maxRadialDistance = max(1.0, sqrt(Double(capWidth) * Double(capWidth) + Double(capHeight) * Double(capHeight)) / 2.0)
            let distanceCompensationFactor = 0.6
            
            for y in stride(from: yOffset, to: yOffset + capHeight, by: 2) {
                for x in stride(from: xOffset, to: xOffset + capWidth, by: 2) {
                    let offset = y * bytesPerRow + x * 4
                    if offset + 3 >= height * bytesPerRow { continue }
                    
                    let b = Double(ptr[offset])
                    let g = Double(ptr[offset + 1])
                    let r = Double(ptr[offset + 2])
                    
                    let saliency = calculatePerceptualSaliency(r: r, g: g, b: b)
                    
                    // Find LED index using angle
                    var pixelAngle = atan2(Double(y) - originY, Double(x) - originX)
                    while pixelAngle < lowerBound { pixelAngle += 2.0 * .pi }
                    while pixelAngle >= upperBound { pixelAngle -= 2.0 * .pi }
                    
                    // Binary search for index
                    var low = 0
                    var high = totalZones - 1
                    var index = 0
                    while low <= high {
                        let mid = (low + high) / 2
                        if boundaryAngles[mid] <= pixelAngle {
                            index = mid
                            low = mid + 1
                        } else {
                            high = mid - 1
                        }
                    }
                    
                    let dx = Double(x) - originX
                    let dy = Double(y) - originY
                    let radialDistance = sqrt(dx*dx + dy*dy)
                    let normalizedRadial = min(max(radialDistance / maxRadialDistance, 0.0), 1.0)
                    let distanceWeight = 1.0 + distanceCompensationFactor * normalizedRadial
                    let weightedSaliency = saliency * distanceWeight

                    // Accumulate
                    accumulators[index].r += r * weightedSaliency
                    accumulators[index].g += g * weightedSaliency
                    accumulators[index].b += b * weightedSaliency
                    accumulators[index].weight += weightedSaliency
                    
                    if saliency > accumulators[index].peakSaliency {
                        accumulators[index].peakSaliency = saliency
                        accumulators[index].peakR = r
                        accumulators[index].peakG = g
                        accumulators[index].peakB = b
                    }
                    
                    accumulators[index].saliencySum += weightedSaliency
                    accumulators[index].saliencySqSum += weightedSaliency * weightedSaliency
                    accumulators[index].pixelCount += 1
                }
            }
            
            // 6. State Initialization & Update
            if zoneStates.count != totalZones {
                zoneStates = Array(repeating: ZoneState(), count: totalZones)
            }
            
            var capturedColors: [(UInt8, UInt8, UInt8)] = []
            var zoneDistances: [Double] = []
            
            for i in 0..<totalZones {
                let acc = accumulators[i]
                var state = zoneStates[i]
                
                // Temporal Accumulation
                let alpha = state.alpha
                if acc.weight > 0 {
                    state.accR = (state.accR * (1.0 - alpha)) + (acc.r * alpha)
                    state.accG = (state.accG * (1.0 - alpha)) + (acc.g * alpha)
                    state.accB = (state.accB * (1.0 - alpha)) + (acc.b * alpha)
                    state.accWeight = (state.accWeight * (1.0 - alpha)) + (acc.weight * alpha)
                    
                    state.peakR = (state.peakR * (1.0 - alpha)) + (acc.peakR * alpha)
                    state.peakG = (state.peakG * (1.0 - alpha)) + (acc.peakG * alpha)
                    state.peakB = (state.peakB * (1.0 - alpha)) + (acc.peakB * alpha)
                    state.peakSaliency = (state.peakSaliency * (1.0 - alpha)) + (acc.peakSaliency * alpha)
                    
                    let frameMeanSaliency = acc.saliencySum / max(1, acc.pixelCount)
                    let frameVarSaliency = (acc.saliencySqSum / max(1, acc.pixelCount)) - (frameMeanSaliency * frameMeanSaliency)
                    
                    state.saliencyMeanAcc = (state.saliencyMeanAcc * (1.0 - alpha)) + (frameMeanSaliency * alpha)
                    state.saliencyVarAcc = (state.saliencyVarAcc * (1.0 - alpha)) + (max(0, frameVarSaliency) * alpha)
                }
                
                // Dynamic Hybrid Mixing
                var finalR: Double = 0
                var finalG: Double = 0
                var finalB: Double = 0
                
                if state.accWeight > 0 {
                    let smoothedMean = state.saliencyMeanAcc
                    let smoothedVar = state.saliencyVarAcc
                    let stdDev = sqrt(max(0, smoothedVar))
                    let cv = (smoothedMean > 0) ? (stdDev / smoothedMean) : 0
                    
                    let avgR = state.accR / state.accWeight
                    let avgG = state.accG / state.accWeight
                    let avgB = state.accB / state.accWeight
                    
                    let mixFactor = min(max((cv - 0.3) * 2.0, 0.0), 1.0)
                    
                    finalR = (avgR * (1.0 - mixFactor)) + (state.peakR * mixFactor)
                    finalG = (avgG * (1.0 - mixFactor)) + (state.peakG * mixFactor)
                    finalB = (avgB * (1.0 - mixFactor)) + (state.peakB * mixFactor)
                }
                
                // Adaptive Kalman Filter
                let predR = state.estR
                let predG = state.estG
                let predB = state.estB
                let predP = state.errorCov + state.q
                
                let resR = finalR - predR
                let resG = finalG - predG
                let resB = finalB - predB
                
                let residualMag = sqrt(resR*resR + resG*resG + resB*resB)
                let t = min(max((residualMag - 2.0) / 38.0, 0.0), 1.0)
                
                state.alpha = 0.2 + (t * 0.3)
                state.q = 0.1 + (t * 0.3)
                let adaptiveR = state.r / (1.0 + (residualMag * 0.1))
                let k = predP / (predP + adaptiveR)
                
                state.estR = predR + k * resR
                state.estG = predG + k * resG
                state.estB = predB + k * resB
                state.errorCov = (1.0 - k) * predP
                
                zoneStates[i] = state
                
                let r_out = state.estR
                let g_out = state.estG
                let b_out = state.estB
                
                // Distance for Scene Intensity (Feedback Coupling)
                var distance: Double = 0
                if i < lastOutputColors.count {
                    let lastOut = lastOutputColors[i]
                    let dr = r_out - Double(lastOut.0)
                    let dg = g_out - Double(lastOut.1)
                    let db = b_out - Double(lastOut.2)
                    distance = sqrt(dr*dr + dg*dg + db*db)
                } else {
                    let dr = r_out - state.lastR
                    let dg = g_out - state.lastG
                    let db = b_out - state.lastB
                    distance = sqrt(dr*dr + dg*dg + db*db)
                }
                zoneDistances.append(distance)
                
                // Tone Mapping & Calibration
                var r_cal = r_out
                var g_cal = g_out
                var b_cal = b_out
                
                if currentSaturation != 1.0 {
                    let gray = 0.299 * r_out + 0.587 * g_out + 0.114 * b_out
                    let boost = currentSaturation * 1.1
                    r_cal = max(0, gray + (r_out - gray) * boost)
                    g_cal = max(0, gray + (g_out - gray) * boost)
                    b_cal = max(0, gray + (b_out - gray) * boost)
                }
                
                r_cal *= currentCalibration.r
                g_cal *= currentCalibration.g
                b_cal *= currentCalibration.b
                
                if currentGamma != 1.0 {
                    r_cal = pow(r_cal / 255.0, currentGamma) * 255.0
                    g_cal = pow(g_cal / 255.0, currentGamma) * 255.0
                    b_cal = pow(b_cal / 255.0, currentGamma) * 255.0
                }
                
                let currentMax = max(r_cal, max(g_cal, b_cal))
                var finalR_out = r_cal
                var finalG_out = g_cal
                var finalB_out = b_cal
                
                if currentMax > 0 {
                    let targetMax = currentMax * brightness
                    let scale = (targetMax > 255) ? (255.0 / currentMax) : brightness
                    finalR_out *= scale
                    finalG_out *= scale
                    finalB_out *= scale
                }
                
                capturedColors.append((UInt8(min(finalR_out, 255)), UInt8(min(finalG_out, 255)), UInt8(min(finalB_out, 255))))
            }
            
            // 7. Scene Intensity Calculation
            if !zoneDistances.isEmpty {
                let sortedDistances = zoneDistances.sorted()
                let medianDistance = sortedDistances[sortedDistances.count / 2]
                let newIntensity = min(max(medianDistance / 120.0, 0.0), 1.0)
                
                if newIntensity > currentSceneIntensity {
                    currentSceneIntensity = newIntensity
                } else {
                    currentSceneIntensity = (currentSceneIntensity * 0.85) + (newIntensity * 0.15)
                }
                
                for i in 0..<totalZones {
                    zoneStates[i].lastR = zoneStates[i].estR
                    zoneStates[i].lastG = zoneStates[i].estG
                    zoneStates[i].lastB = zoneStates[i].estB
                }
            }
            
            // 8. Physics & Spatial Constraint
            var smoothedColors = physicsEngine.process(targetColors: capturedColors, dt: dt, sceneIntensity: currentSceneIntensity)
            
            // 9. Orientation Transformation (Standard is CW, Reverse is CCW)
            if orientation == .reverse {
                // Standard: [Left, Top, Right, Bottom]
                // Reverse: [Right_rev, Top_rev, Left_rev, Bottom_rev]
                // This is equivalent to reversing the entire array and shifting the Bottom segment to the end.
                smoothedColors.reverse()
                let bottomCount = config.bottom
                if bottomCount > 0 && bottomCount < smoothedColors.count {
                    let bottomSegment = Array(smoothedColors.prefix(bottomCount))
                    smoothedColors.removeFirst(bottomCount)
                    smoothedColors.append(contentsOf: bottomSegment)
                }
            }
            
            self.lastOutputColors = smoothedColors
            
            // 10. Spatial Consistency Constraint
            let count = smoothedColors.count
            if count > 2 {
                for i in 0..<count {
                    let prev = smoothedColors[(i - 1 + count) % count]
                    let curr = smoothedColors[i]
                    let next = smoothedColors[(i + 1) % count]
                    
                    func dist(_ c1: (UInt8, UInt8, UInt8), _ c2: (UInt8, UInt8, UInt8)) -> Double {
                        let dr = Double(c1.0) - Double(c2.0)
                        let dg = Double(c1.1) - Double(c2.1)
                        let db = Double(c1.2) - Double(c2.2)
                        return sqrt(dr*dr + dg*dg + db*db)
                    }
                    
                    if dist(curr, prev) > 50 && dist(curr, next) > 50 && dist(prev, next) < 50 {
                        let newR = (Double(prev.0) + Double(next.0)) / 2.0
                        let newG = (Double(prev.1) + Double(next.1)) / 2.0
                        let newB = (Double(prev.2) + Double(next.2)) / 2.0
                        smoothedColors[i] = (UInt8((Double(curr.0) + newR) / 2.0), UInt8((Double(curr.1) + newG) / 2.0), UInt8((Double(curr.2) + newB) / 2.0))
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
                    ledData.append(0); ledData.append(0); ledData.append(0)
                }
            } else if currentLeds > ledCount {
                ledData = Array(ledData.prefix(ledCount * 3))
            }
            
            return ledData
    }

    private func normalizedOriginY(for config: ZoneConfig) -> Double {
        let clampedManual = min(max(currentOriginPreference.manualNormalized, 0.0), 1.0)
        if currentOriginPreference.mode == .manual {
            return clampedManual
        }

        let goldenRatio = 0.618
        let sides: [(String, Int)] = [
            ("top", config.top),
            ("bottom", config.bottom),
            ("left", config.left),
            ("right", config.right)
        ]

        let missing = sides.filter { $0.1 == 0 }
        guard missing.count == 1 else { return 0.5 }

        switch missing[0].0 {
        case "top": return max(0.0, min(1.0, 1.0 - goldenRatio))
        case "bottom": return min(1.0, goldenRatio)
        default: return 0.5
        }
    }
}
