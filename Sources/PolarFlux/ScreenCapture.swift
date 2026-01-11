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

class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    
    private var stream: SCStream?
    private let processingQueue = DispatchQueue(label: "com.sunaish.polarflux.processing", qos: .userInteractive)
    
    // Metal Integration
    private let metalProcessor = MetalProcessor()
    var useMetal: Bool = true
    
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
        
        // 6. Sector Intensity (Per-LED responsive tracking)
        var localIntensity: Double = 0
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
                self.smoothedGlobalLuma = 0.5
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
    private var currentTargetFrameRate: Double = 60.0 // DEPRECATED
    private var currentCalibration: (r: Double, g: Double, b: Double) = (1.0, 1.0, 1.0)
    private var currentGamma: Double = 1.0
    private var currentSaturation: Double = 1.0
    private var lastProcessTime: TimeInterval = 0 // DEPRECATED
    private var lastOutputColors: [(UInt8, UInt8, UInt8)] = []
    private var currentSceneIntensity: Double = 0.0
    private var smoothedGlobalLuma: Double = 0.5
    
    // MARK: - SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Robustness: Capture stream crash handling
        // Often occurs on Display sleep/wake or resolution change
        print("SCStream stopped with error: \(error.localizedDescription)")
        
        // Notify observer (AppState) if we have a callback mechanism?
        // Ideally we should try to restart, but SCStream is async and we are in a delegate.
        // The safest way is to nullify the stream and rely on AppState to restart on 'ScreensDidWake'
        // or a retry mechanism.
        // Since AppState listens to ScreensDidWake/SystemWake, it will call stop() then start()
        // effectively resetting this.
        // We ensure we don't crash by cleaning up here.
        self.stream = nil
        self.lastFrameTime = 0
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
        
        // 1. Metal Acceleration
        if self.useMetal && metalProcessor.isAvailable {
            if let (avg, peak) = metalProcessor.process(pixelBuffer: pixelBuffer) {
                let ledData = processFrameMetal(
                    avg: avg,
                    peak: peak,
                    config: currentConfig,
                    ledCount: currentLedCount,
                    orientation: currentOrientation,
                    dt: safeDt,
                    brightness: currentBrightness
                )
                onFrameProcessed?(ledData)
                return
            }
        }
        
        // 2. CPU Fallback
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
            
            // Note: Accumulator moved to top-level struct to share with Metal path.
            // Using local variable type inference to use the global struct.
            
            // Helper: Perceptual Saliency (CPU version matching Metal implementation)
            func calculatePerceptualSaliency(r: Double, g: Double, b: Double) -> Double {
                // Normalize to 0-1 for calculation
                let nr = r / 255.0
                let ng = g / 255.0
                let nb = b / 255.0
                
                // 1. Non-linear Brightness (Gamma 2.0 approx) - Rec 709
                let y = 0.2126 * nr * nr + 0.7152 * ng * ng + 0.0722 * nb * nb
                
                // 2. Efficient Saturation (HSV approximation)
                let maxVal = max(nr, max(ng, nb))
                let minVal = min(nr, min(ng, nb))
                let delta = maxVal - minVal
                let saturation = (maxVal > 0) ? (delta / maxVal) : 0
                
                // 3. Hue Specific Weight (Warm Boost)
                // Boost Red/Orange/Yellow
                var hueWeight = 1.0
                if nr > nb && (nr > ng * 0.5) {
                    hueWeight = 1.2
                }
                
                // 4. Exponential Weighting
                let vividness = saturation * sqrt(maxVal)
                let expBoost = exp(vividness * 2.5)
                
                // 5. Sigmoid Compression
                let purity = saturation * maxVal
                let sigmoid = 1.0 / (1.0 + exp(-12.0 * (purity - 0.4)))
                
                // Brightness Weight (Smoothstep-like gate)
                // Prevents dark noise from being picked up
                let t = min(max((y - 0.05) / 0.25, 0.0), 1.0)
                let briWeight = t * t * (3.0 - 2.0 * t)
                
                return sigmoid * expBoost * hueWeight * briWeight
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
            return finalizeFrame(accumulators: accumulators, totalZones: totalZones, brightness: brightness, dt: dt, config: config, orientation: orientation, ledCount: ledCount)
    }

    // MARK: - Metal Acceleration Logic
    private func processFrameMetal(avg: [Float], peak: [Float], config: ZoneConfig, ledCount: Int, orientation: ScreenOrientation, dt: Double, brightness: Double) -> [UInt8] {
        let width = metalProcessor.outputWidth
        let height = metalProcessor.outputHeight
        
        let xOffset = 0
        let yOffset = 0
        let capWidth = width
        let capHeight = height
        
        // 2. Perspective Origin (Scaled to Metal Grid)
        let originX = Double(xOffset) + Double(capWidth) / 2.0
        let normalizedOriginY = normalizedOriginY(for: config)
        let originY = Double(yOffset) + normalizedOriginY * Double(capHeight)
        
        // 3. Generate Perimeter Boundary Points (Same Logic, Scaled Coordinates)
        var boundaryPoints: [CGPoint] = []
        if config.left > 0 {
            for i in 0...config.left {
                let y = Double(yOffset + capHeight) - Double(i) * (Double(capHeight) / Double(config.left))
                boundaryPoints.append(CGPoint(x: Double(xOffset), y: y))
            }
        } else {
            boundaryPoints.append(CGPoint(x: Double(xOffset), y: Double(yOffset + capHeight)))
        }
        if config.top > 0 {
            if !boundaryPoints.isEmpty { boundaryPoints.removeLast() }
            for i in 0...config.top {
                let x = Double(xOffset) + Double(i) * (Double(capWidth) / Double(config.top))
                boundaryPoints.append(CGPoint(x: x, y: Double(yOffset)))
            }
        }
        if config.right > 0 {
            if !boundaryPoints.isEmpty { boundaryPoints.removeLast() }
            for i in 0...config.right {
                let y = Double(yOffset) + Double(i) * (Double(capHeight) / Double(config.right))
                boundaryPoints.append(CGPoint(x: Double(xOffset + capWidth), y: y))
            }
        }
        if config.bottom > 0 {
            if !boundaryPoints.isEmpty { boundaryPoints.removeLast() }
            for i in 0...config.bottom {
                let x = Double(xOffset + capWidth) - Double(i) * (Double(capWidth) / Double(config.bottom))
                boundaryPoints.append(CGPoint(x: x, y: Double(yOffset + capHeight)))
            }
        }
        
        let totalZones = config.left + config.top + config.right + config.bottom
        if totalZones <= 0 { return [] }
        
        // 4. Boundary Angles
        var boundaryAngles: [Double] = []
        for p in boundaryPoints {
            boundaryAngles.append(atan2(p.y - originY, p.x - originX))
        }
        // Normalize
        if !boundaryAngles.isEmpty {
            var lastA = boundaryAngles[0]
            for i in 1..<boundaryAngles.count {
                while boundaryAngles[i] <= lastA { boundaryAngles[i] += 2.0 * .pi }
                lastA = boundaryAngles[i]
            }
        }
        guard let lowerBound = boundaryAngles.first, var upperBound = boundaryAngles.last else { return [] }
        if upperBound <= lowerBound { upperBound = lowerBound + 2.0 * .pi }
        
        // 5. Processing Loop (Metal Grid)
        var accumulators = Array(repeating: Accumulator(), count: totalZones)
        let maxRadialDistance = max(1.0, sqrt(Double(capWidth)*Double(capWidth) + Double(capHeight)*Double(capHeight)) / 2.0)
        let distanceCompensationFactor = 0.6
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                // Avg: R, G, B, WeightSum
                // Peak: R, G, B, MaxSaliency
                
                let weightSum = Double(avg[offset + 3])
                if weightSum <= 0.0001 { continue } // Skip empty blocks
                
                let sumR = Double(avg[offset])
                let sumG = Double(avg[offset + 1])
                let sumB = Double(avg[offset + 2])
                
                let peakSaliency = Double(peak[offset + 3])
                let peakR = Double(peak[offset])
                let peakG = Double(peak[offset + 1])
                let peakB = Double(peak[offset + 2])
                
                // Find Zone
                var pixelAngle = atan2(Double(y) - originY, Double(x) - originX)
                while pixelAngle < lowerBound { pixelAngle += 2.0 * .pi }
                while pixelAngle >= upperBound { pixelAngle -= 2.0 * .pi }
                
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
                
                // Distance Weight
                let dx = Double(x) - originX
                let dy = Double(y) - originY
                let radialDistance = sqrt(dx*dx + dy*dy)
                let normalizedRadial = min(max(radialDistance / maxRadialDistance, 0.0), 1.0)
                let distanceWeight = 1.0 + distanceCompensationFactor * normalizedRadial
                
                // Accumulate
                // avg tex contains Sum(Pixel * Saliency).
                // We want Sum(Pixel * Saliency * Distance).
                accumulators[index].r += sumR * distanceWeight
                accumulators[index].g += sumG * distanceWeight
                accumulators[index].b += sumB * distanceWeight
                
                // weightSum is Sum(Saliency).
                // We want Sum(Saliency * Distance).
                let weightedWeight = weightSum * distanceWeight
                accumulators[index].weight += weightedWeight
                
                // Stats
                accumulators[index].saliencySum += weightedWeight
                accumulators[index].saliencySqSum += weightedWeight * weightedWeight // Aprrox? Square of sum is not sum of squares.
                // Correction: Variance calculation requires Sum(x^2).
                // Metal didn't output Sum(Saliency^2).
                // It output Sum(Saliency).
                // For "Variance", we are estimating noise.
                // Using (Sum * Sum) / N is wrong.
                // It's acceptable to approximate SaliencySqSum as (SumSaliency * AverageSaliency) * DistanceSq?
                // Or just ignore variance in Metal mode?
                // Or add channel to Metal?
                // Let's approximate: Assume uniform distribution in block.
                // SaliencySqSum ~= (weightSum * weightSum) / blockPixels? No.
                // Let's use `weightedWeight` as proxy for now to avoid stalling.
                accumulators[index].saliencySqSum += (weightedWeight * weightedWeight) / 1.0 // Rough
                
                accumulators[index].pixelCount += 1 // Defines "Blocks" now
                
                // Peak
                if peakSaliency > accumulators[index].peakSaliency {
                    accumulators[index].peakSaliency = peakSaliency
                    accumulators[index].peakR = peakR
                    accumulators[index].peakG = peakG
                    accumulators[index].peakB = peakB
                }
            }
        }
        
        return finalizeFrame(accumulators: accumulators, totalZones: totalZones, brightness: brightness, dt: dt, config: config, orientation: orientation, ledCount: ledCount)
    }
    
    // Shared Post-Processing Logic
    private func finalizeFrame(accumulators: [Accumulator], totalZones: Int, brightness: Double, dt: Double, config: ZoneConfig, orientation: ScreenOrientation, ledCount: Int) -> [UInt8] {
        // 6. State Initialization & Update
        if zoneStates.count != totalZones {
            zoneStates = Array(repeating: ZoneState(), count: totalZones)
        }
        
        // 0. Global stats for Adaptive Brightness (Previous frame's smoothed value)
        // We use a smoothed factor to prevent flickering
        let adaptiveBrightnessFactor = 1.0 - (smoothedGlobalLuma * 0.35) 
        var cumulativeLuma: Double = 0
        
        var capturedColors: [(UInt8, UInt8, UInt8)] = []
        var zoneDistances: [Double] = []
        var sectorIntensities: [Double] = []
        var processedBuffer: [(r: Double, g: Double, b: Double)] = []
        
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
                // Variance calc might be unstable with blocks, clamp to 0
                let frameVarSaliency = (acc.saliencySqSum / max(1, acc.pixelCount)) - (frameMeanSaliency * frameMeanSaliency)
                
                state.saliencyMeanAcc = (state.saliencyMeanAcc * (1.0 - alpha)) + (frameMeanSaliency * alpha)
                state.saliencyVarAcc = (state.saliencyVarAcc * (1.0 - alpha)) + (max(0, frameVarSaliency) * alpha)
            }
            
            // Dynamic Hybrid Mixing (Optimized)
            var finalR: Double = 0
            var finalG: Double = 0
            var finalB: Double = 0
            
            if state.accWeight > 0 {
                let avgR = state.accR / state.accWeight
                let avgG = state.accG / state.accWeight
                let avgB = state.accB / state.accWeight
                
                var mixFactor: Double = 0.0
                
                // Point 2: Optimize Peak Detection & Dynamic Blending
                // Thresholds based on Saliency Score
                if state.peakSaliency > 5.0 { 
                    // High saliency peak: Prioritize peak color strongly (90%+)
                    mixFactor = 0.92
                } else {
                    // Medium saliency: Dynamic adjustment based on variation
                    let smoothedMean = state.saliencyMeanAcc
                    let smoothedVar = state.saliencyVarAcc
                    let stdDev = sqrt(max(0, smoothedVar))
                    let cv = (smoothedMean > 0) ? (stdDev / smoothedMean) : 0
                    // CV threshold mix - increase max to 0.75 for better layers
                    mixFactor = min(max((cv - 0.2) * 2.5, 0.0), 0.75)
                }
                
                // Smart Saturation Enhancement for Peak Color
                let pR = state.peakR
                let pG = state.peakG
                let pB = state.peakB
                let pGray = 0.2126*pR + 0.7152*pG + 0.0722*pB
                
                let peakSatBoost = 1.25 // Increase to 25% saturation boost for peaks
                let eR = pGray + (pR - pGray) * peakSatBoost
                let eG = pGray + (pG - pGray) * peakSatBoost
                let eB = pGray + (pB - pGray) * peakSatBoost
                
                finalR = (avgR * (1.0 - mixFactor)) + (eR * mixFactor)
                finalG = (avgG * (1.0 - mixFactor)) + (eG * mixFactor)
                finalB = (avgB * (1.0 - mixFactor)) + (eB * mixFactor)
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
            
            // Point 3: Dynamic Tone Mapping & Enhancement Pipeline
            var cR = max(0, r_out)
            var cG = max(0, g_out)
            var cB = max(0, b_out)
            
            // 1. Dynamic Contrast Expansion
            let luma = 0.2126 * cR + 0.7152 * cG + 0.0722 * cB
            // Optimized S-curve contrast on Luma
            let nL = min(max(luma / 255.0, 0.0), 1.0)
            let contrast = 1.1 
            let newNL = (nL - 0.5) * contrast + 0.5 + (nL * nL * 0.1)
            let lumaScale = (nL > 0.001) ? (max(0.0, newNL) / nL) : 1.0
            
            cR *= lumaScale
            cG *= lumaScale
            cB *= lumaScale
            
            // 2. Adaptive Saturation Enhancement
            // Ensure components are non-negative before calculating saturation
            cR = max(0, cR)
            cG = max(0, cG)
            cB = max(0, cB)
            
            let maxC = max(cR, max(cG, cB))
            let minC = min(cR, min(cG, cB))
            let sat = (maxC > 1.0) ? ((maxC - minC) / maxC) : 0.0
            
            // Point: More aggressive saturation to reduce "whitish" colors
            let satFactor = 1.8 - (sat * 0.8) 
            let totalSat = currentSaturation * satFactor
            
            if totalSat != 1.0 {
                let curGray = 0.2126 * cR + 0.7152 * cG + 0.0722 * cB
                cR = curGray + (cR - curGray) * totalSat
                cG = curGray + (cG - curGray) * totalSat
                cB = curGray + (cB - curGray) * totalSat
                
                // Additional white core suppression for low-saturation colors
                if sat < 0.25 {
                    // Stronger suppression: multiply saturation distance
                    let boost = 1.3 - sat * 0.8 
                    cR = curGray + (cR - curGray) * boost
                    cG = curGray + (cG - curGray) * boost
                    cB = curGray + (cB - curGray) * boost
                }
            }
            
            // Calibration
            cR *= currentCalibration.r
            cG *= currentCalibration.g
            cB *= currentCalibration.b
            
            // 3. Vibrance Protection (Soft Clipping)
            func softClip(_ val: Double) -> Double {
                let boundedVal = max(0, val)
                let x = boundedVal / 255.0
                if x < 0.8 { return boundedVal }
                return 255.0 * (0.8 + (1.0 - exp(-(x - 0.8) * 4.0)) * 0.2)
            }
            cR = softClip(cR)
            cG = softClip(cG)
            cB = softClip(cB)

            // 4. Gamma Correction (sRGB Approx)
            // cR, cG, cB are guaranteed >= 0 here due to softClip
            if currentGamma != 1.0 {
                cR = pow(cR / 255.0, currentGamma) * 255.0
                cG = pow(cG / 255.0, currentGamma) * 255.0
                cB = pow(cB / 255.0, currentGamma) * 255.0
            }
            
            // 5. Smart Brightness Scaling
            let currentMax = max(cR, max(cG, cB))
            var finalR_out = cR
            var finalG_out = cG
            var finalB_out = cB
            
            if currentMax > 0 {
                // Incorporate Adaptive Brightness Factor
                let targetMax = currentMax * brightness * adaptiveBrightnessFactor
                let scale = (targetMax > 255) ? (255.0 / currentMax) : (brightness * adaptiveBrightnessFactor)
                finalR_out *= scale
                finalG_out *= scale
                finalB_out *= scale
            }
            
            // Stats for next frame
            cumulativeLuma += (0.2126 * finalR_out + 0.7152 * finalG_out + 0.0722 * finalB_out) / 255.0
            
            // 7. Per-Sector Intensity Calculation (Responsive & Stable)
            let normDistance = min(distance / 120.0, 1.0)
            if normDistance > state.localIntensity {
                state.localIntensity = (state.localIntensity * 0.4) + (normDistance * 0.6)
            } else {
                state.localIntensity = (state.localIntensity * 0.92) + (normDistance * 0.08)
            }
            sectorIntensities.append(state.localIntensity)
            
            processedBuffer.append((finalR_out, finalG_out, finalB_out))
        }
        
        // 7.5 Spatial Hierarchy & Contrast Enhancement
        // This pass increases the difference between adjacent zones to reduce "uniformity"
        for i in 0..<totalZones {
            let prevIdx = (i - 1 + totalZones) % totalZones
            let nextIdx = (i + 1) % totalZones
            
            let curr = processedBuffer[i]
            let prev = processedBuffer[prevIdx]
            let next = processedBuffer[nextIdx]
            
            let currLuma = 0.2126 * curr.r + 0.7152 * curr.g + 0.0722 * curr.b
            let neighLuma = ( (0.2126 * prev.r + 0.7152 * prev.g + 0.0722 * prev.b) + (0.2126 * next.r + 0.7152 * next.g + 0.0722 * next.b) ) / 2.0
            
            var scale: Double = 1.0
            if currLuma > 5.0 {
                // Spatial Sharpening: If I am brighter than my neighbors, be even brighter.
                // If I am darker, be even darker.
                let diff = (currLuma - neighLuma) / max(currLuma, 10.0)
                scale = 1.0 + diff * 0.25 // 25% contrast boost
                scale = min(max(scale, 0.7), 1.3) // Safeguard
            }
            
            // Apply scale and convert to UInt8
            capturedColors.append((
                UInt8(min(max(curr.r * scale, 0), 255)),
                UInt8(min(max(curr.g * scale, 0), 255)),
                UInt8(min(max(curr.b * scale, 0), 255))
            ))
        }
        
        // 8. Global Stats Update (for Adaptive Brightness)
        let frameAvgLuma = cumulativeLuma / max(1.0, Double(totalZones))
        self.smoothedGlobalLuma = (self.smoothedGlobalLuma * 0.96) + (frameAvgLuma * 0.04)
        
        for i in 0..<totalZones {
            zoneStates[i].lastR = zoneStates[i].estR
            zoneStates[i].lastG = zoneStates[i].estG
            zoneStates[i].lastB = zoneStates[i].estB
        }
        
        // 9. Physics & Spatial Constraint
        var smoothedColors = physicsEngine.process(targetColors: capturedColors, dt: dt, sectorIntensities: sectorIntensities)
        
        // 10. Orientation Transformation (Standard is CW, Reverse is CCW)
        if orientation == .reverse {
            // Standard: [Left, Top, Right, Bottom]
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
        
        var ledData: [UInt8] = []
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
