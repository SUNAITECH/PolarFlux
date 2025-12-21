import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

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

class ScreenCapture {
    
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

    func captureAndProcess(display: SCDisplay, config: ZoneConfig, ledCount: Int, mode: SyncMode, orientation: ScreenOrientation, useDominantColor: Bool) async -> [UInt8] {
        do {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let streamConfig = SCStreamConfiguration()
            streamConfig.width = display.width
            streamConfig.height = display.height
            streamConfig.showsCursor = false
            
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: streamConfig)
            
            let width = image.width
            let height = image.height
            
            // Get pixel data
            guard let dataProvider = image.dataProvider,
                  let data = dataProvider.data,
                  let ptr = CFDataGetBytePtr(data) else { return [] }
            
            let bytesPerRow = image.bytesPerRow
            let bytesPerPixel = image.bitsPerPixel / 8
            
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
                
                let step = 4
                
                for y in stride(from: yStart, to: yStart + h, by: step) {
                    for x in stride(from: xStart, to: xStart + w, by: step) {
                        let offset = y * bytesPerRow + x * bytesPerPixel
                        let b = Double(ptr[offset])
                        let g = Double(ptr[offset + 1])
                        let r = Double(ptr[offset + 2])
                        
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
            
            // Helper to get dominant color using K-Means
            func getDominantColor(rect: CGRect) -> (r: UInt8, g: UInt8, b: UInt8) {
                let xStart = max(0, Int(rect.origin.x))
                let yStart = max(0, Int(rect.origin.y))
                let w = min(width - xStart, Int(rect.width))
                let h = min(height - yStart, Int(rect.height))
                
                if w <= 0 || h <= 0 { return (0,0,0) }
                
                // Collect pixels
                var pixels: [(r: Double, g: Double, b: Double)] = []
                let step = 8 // Sample less frequently for K-Means performance
                
                for y in stride(from: yStart, to: yStart + h, by: step) {
                    for x in stride(from: xStart, to: xStart + w, by: step) {
                        let offset = y * bytesPerRow + x * bytesPerPixel
                        let b = Double(ptr[offset])
                        let g = Double(ptr[offset + 1])
                        let r = Double(ptr[offset + 2])
                        pixels.append((r, g, b))
                    }
                }
                
                if pixels.isEmpty { return (0,0,0) }
                
                // K-Means Clustering
                let k = 3
                var centroids: [(r: Double, g: Double, b: Double)] = [
                    (0, 0, 0),       // Black
                    (255, 0, 0),     // Red
                    (255, 255, 255)  // White
                ]
                
                // Initialize centroids with random pixels if enough pixels
                if pixels.count >= k {
                    centroids = [pixels[0], pixels[pixels.count / 2], pixels[pixels.count - 1]]
                }
                
                for _ in 0..<3 { // 3 iterations is usually enough for rough dominant color
                    var clusters: [[(r: Double, g: Double, b: Double)]] = Array(repeating: [], count: k)
                    
                    for pixel in pixels {
                        var minDist = Double.greatestFiniteMagnitude
                        var clusterIndex = 0
                        
                        for i in 0..<k {
                            let dr = pixel.r - centroids[i].r
                            let dg = pixel.g - centroids[i].g
                            let db = pixel.b - centroids[i].b
                            let dist = dr*dr + dg*dg + db*db
                            
                            if dist < minDist {
                                minDist = dist
                                clusterIndex = i
                            }
                        }
                        clusters[clusterIndex].append(pixel)
                    }
                    
                    // Update centroids
                    for i in 0..<k {
                        if !clusters[i].isEmpty {
                            let sum = clusters[i].reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.r, $0.1 + $1.g, $0.2 + $1.b) }
                            let count = Double(clusters[i].count)
                            centroids[i] = (sum.0 / count, sum.1 / count, sum.2 / count)
                        }
                    }
                }
                
                // Find largest cluster (most common color)
                // But prefer colorful clusters over black/grey if possible?
                // Hyperion logic: just largest cluster.
                // Let's find the cluster with most pixels.
                
                // Re-assign pixels to final centroids to count
                var counts = [Int](repeating: 0, count: k)
                for pixel in pixels {
                    var minDist = Double.greatestFiniteMagnitude
                    var clusterIndex = 0
                    for i in 0..<k {
                        let dr = pixel.r - centroids[i].r
                        let dg = pixel.g - centroids[i].g
                        let db = pixel.b - centroids[i].b
                        let dist = dr*dr + dg*dg + db*db
                        if dist < minDist {
                            minDist = dist
                            clusterIndex = i
                        }
                    }
                    counts[clusterIndex] += 1
                }
                
                // Find best cluster using "Vibrancy Score"
                // We prioritize colorful clusters over large grey/white areas.
                // Score = Count * (Base + Saturation * Boost)
                
                var maxScore: Double = -1.0
                var bestIndex = 0
                
                for i in 0..<k {
                    let c = centroids[i]
                    let count = Double(counts[i])
                    
                    // Calculate Saturation & Brightness
                    let r = c.r
                    let g = c.g
                    let b = c.b
                    
                    let maxC = max(r, max(g, b))
                    let minC = min(r, min(g, b))
                    var saturation: Double = 0.0
                    if maxC > 0.001 {
                        saturation = (maxC - minC) / maxC
                    }
                    
                    let brightness = maxC / 255.0
                    
                    // Weighting Logic:
                    // 1. Penalize very dark clusters (noise/black bars)
                    // 2. Boost saturated clusters significantly
                    // 3. Reduce weight of grey/white
                    
                    let brightnessWeight = brightness > 0.05 ? 1.0 : 0.01
                    
                    // Base weight 0.15, Saturation adds up to 3.0.
                    // A fully saturated pixel is worth ~20x a grey pixel.
                    // This ensures even small colorful elements (like album art) are picked up.
                    let saturationWeight = 0.15 + (saturation * 3.0)
                    
                    let score = count * saturationWeight * brightnessWeight
                    
                    if score > maxScore {
                        maxScore = score
                        bestIndex = i
                    }
                }
                
                let c = centroids[bestIndex]
                return (UInt8(c.r), UInt8(c.g), UInt8(c.b))
            }
            
            // Helper to get average color of a rect (RMS)
            func getAverageColor(rect: CGRect) -> (r: UInt8, g: UInt8, b: UInt8) {
                let xStart = max(0, Int(rect.origin.x))
                let yStart = max(0, Int(rect.origin.y))
                let w = min(width - xStart, Int(rect.width))
                let h = min(height - yStart, Int(rect.height))
                
                if w <= 0 || h <= 0 { return (0,0,0) }
                
                var r: Double = 0
                var g: Double = 0
                var b: Double = 0
                var count: Int = 0
                
                // Optimization: Don't sample every pixel, sample every Nth pixel
                let step = 4 
                
                for y in stride(from: yStart, to: yStart + h, by: step) {
                    for x in stride(from: xStart, to: xStart + w, by: step) {
                        let offset = y * bytesPerRow + x * bytesPerPixel
                        
                        let blue = Double(ptr[offset])
                        let green = Double(ptr[offset + 1])
                        let red = Double(ptr[offset + 2])
                        
                        // Use Sum of Squares for RMS (Root Mean Square)
                        r += red * red
                        g += green * green
                        b += blue * blue
                        count += 1
                    }
                }
                
                if count == 0 { return (0, 0, 0) }
                
                // Calculate RMS: sqrt(sum / count)
                let rmsR = UInt8(sqrt(r / Double(count)))
                let rmsG = UInt8(sqrt(g / Double(count)))
                let rmsB = UInt8(sqrt(b / Double(count)))
                
                return (rmsR, rmsG, rmsB)
            }
            
            func getColor(rect: CGRect) -> (r: UInt8, g: UInt8, b: UInt8) {
                if useDominantColor {
                    return getDominantColor(rect: rect)
                } else {
                    return getAverageColor(rect: rect)
                }
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
            
        } catch {
            print("Screen capture error: \(error)")
            return []
        }
    }
}
