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

    func captureAndProcess(display: SCDisplay, config: ZoneConfig, ledCount: Int, mode: SyncMode, orientation: ScreenOrientation) async -> [UInt8] {
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
            
            // Helper to get average color of a rect
            func getAverageColor(rect: CGRect) -> (r: UInt8, g: UInt8, b: UInt8) {
                let xStart = max(0, Int(rect.origin.x))
                let yStart = max(0, Int(rect.origin.y))
                let w = min(width - xStart, Int(rect.width))
                let h = min(height - yStart, Int(rect.height))
                
                if w <= 0 || h <= 0 { return (0,0,0) }
                
                var r: Int = 0
                var g: Int = 0
                var b: Int = 0
                var count: Int = 0
                
                // Optimization: Don't sample every pixel, sample every Nth pixel
                let step = 4 
                
                for y in stride(from: yStart, to: yStart + h, by: step) {
                    for x in stride(from: xStart, to: xStart + w, by: step) {
                        let offset = y * bytesPerRow + x * bytesPerPixel
                        
                        let blue = Int(ptr[offset])
                        let green = Int(ptr[offset + 1])
                        let red = Int(ptr[offset + 2])
                        
                        r += red
                        g += green
                        b += blue
                        count += 1
                    }
                }
                
                if count == 0 { return (0, 0, 0) }
                return (UInt8(r / count), UInt8(g / count), UInt8(b / count))
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
            
            if orientation == .standard {
                // Standard: Clockwise from Bottom-Left
                // 1. Left Zone (Bottom -> Top)
                if config.left > 0 {
                    let hStep = capHeight / config.left
                    for i in 0..<config.left {
                        let y = yOffset + capHeight - ((i + 1) * hStep)
                        let rect = CGRect(x: xOffset, y: y, width: config.depth, height: hStep)
                        let color = getAverageColor(rect: rect)
                        ledData.append(color.r); ledData.append(color.g); ledData.append(color.b)
                    }
                }
                // 2. Top Zone (Left -> Right)
                if config.top > 0 {
                    let wStep = capWidth / config.top
                    for i in 0..<config.top {
                        let x = xOffset + (i * wStep)
                        let rect = CGRect(x: x, y: yOffset, width: wStep, height: config.depth)
                        let color = getAverageColor(rect: rect)
                        ledData.append(color.r); ledData.append(color.g); ledData.append(color.b)
                    }
                }
                // 3. Right Zone (Top -> Bottom)
                if config.right > 0 {
                    let hStep = capHeight / config.right
                    for i in 0..<config.right {
                        let y = yOffset + (i * hStep)
                        let rect = CGRect(x: xOffset + capWidth - config.depth, y: y, width: config.depth, height: hStep)
                        let color = getAverageColor(rect: rect)
                        ledData.append(color.r); ledData.append(color.g); ledData.append(color.b)
                    }
                }
                // 4. Bottom Zone (Right -> Left)
                if config.bottom > 0 {
                    let wStep = capWidth / config.bottom
                    for i in 0..<config.bottom {
                        let x = xOffset + capWidth - ((i + 1) * wStep)
                        let rect = CGRect(x: x, y: yOffset + capHeight - config.depth, width: wStep, height: config.depth)
                        let color = getAverageColor(rect: rect)
                        ledData.append(color.r); ledData.append(color.g); ledData.append(color.b)
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
                        let color = getAverageColor(rect: rect)
                        ledData.append(color.r); ledData.append(color.g); ledData.append(color.b)
                    }
                }
                // 2. Top Zone (Right -> Left)
                if config.top > 0 {
                    let wStep = capWidth / config.top
                    for i in 0..<config.top {
                        let x = xOffset + capWidth - ((i + 1) * wStep)
                        let rect = CGRect(x: x, y: yOffset, width: wStep, height: config.depth)
                        let color = getAverageColor(rect: rect)
                        ledData.append(color.r); ledData.append(color.g); ledData.append(color.b)
                    }
                }
                // 3. Left Zone (Top -> Bottom)
                if config.left > 0 {
                    let hStep = capHeight / config.left
                    for i in 0..<config.left {
                        let y = yOffset + (i * hStep)
                        let rect = CGRect(x: xOffset, y: y, width: config.depth, height: hStep)
                        let color = getAverageColor(rect: rect)
                        ledData.append(color.r); ledData.append(color.g); ledData.append(color.b)
                    }
                }
                // 4. Bottom Zone (Left -> Right)
                if config.bottom > 0 {
                    let wStep = capWidth / config.bottom
                    for i in 0..<config.bottom {
                        let x = xOffset + (i * wStep)
                        let rect = CGRect(x: x, y: yOffset + capHeight - config.depth, width: wStep, height: config.depth)
                        let color = getAverageColor(rect: rect)
                        ledData.append(color.r); ledData.append(color.g); ledData.append(color.b)
                    }
                }
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
