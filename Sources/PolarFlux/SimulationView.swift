import SwiftUI

struct SimulationView: View {
    var leftZone: Int
    var topZone: Int
    var rightZone: Int
    var bottomZone: Int
    var originY: Double // Normalized 0-1
    var colors: [UInt8] // RGB Data
    var orientation: ScreenOrientation
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let origin = CGPoint(x: width * 0.5, y: height * originY)
            
            // Modern "Monitor" Style Background
            ZStack {
                // Bezel / Frame
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                
                // Screen Area (Inner Dark)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black)
                    .padding(4)
                
                // Content Layer
                Canvas { context, size in
                    let totalZones = leftZone + topZone + rightZone + bottomZone
                    guard totalZones > 0 else { return }
                    
                    // 1. Calculate Boundary Points on Perimeter
                    var points: [CGPoint] = []
                    
                    // Inner padding for drawing (inside the 'screen' area)
                    let drawRect = CGRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8)
                    let minX = drawRect.minX
                    let maxX = drawRect.maxX
                    let minY = drawRect.minY
                    let maxY = drawRect.maxY
                    
                    // Left
                    if leftZone > 0 {
                        for i in 0...leftZone {
                            let y = maxY - (Double(i) * (drawRect.height / Double(leftZone)))
                            points.append(CGPoint(x: minX, y: y))
                        }
                    } else {
                        points.append(CGPoint(x: minX, y: maxY))
                    }
                    
                    // Top
                    if topZone > 0 {
                        if !points.isEmpty { points.removeLast() }
                        for i in 0...topZone {
                            let x = minX + Double(i) * (drawRect.width / Double(topZone))
                            points.append(CGPoint(x: x, y: minY))
                        }
                    } else if topZone == 0 {
                        // Handle corner continuity
                    }
                    
                    // Right
                    if rightZone > 0 {
                        if !points.isEmpty { points.removeLast() }
                        for i in 0...rightZone {
                            let y = minY + Double(i) * (drawRect.height / Double(rightZone))
                            points.append(CGPoint(x: maxX, y: y))
                        }
                    }
                    
                    // Bottom
                    if bottomZone > 0 {
                        if !points.isEmpty { points.removeLast() }
                        for i in 0...bottomZone {
                            let x = maxX - (Double(i) * (drawRect.width / Double(bottomZone)))
                            points.append(CGPoint(x: x, y: maxY))
                        }
                    }
                    
                    // Color Mapping Logic
                    let ledData = colors
                    var displayColors = [Color]()
                    let byteCount = ledData.count
                    let ledCount = byteCount / 3
                    
                    if ledCount == totalZones {
                         var zoneColors = [Color]()
                         var outputStruct = [Color]()
                         for k in 0..<ledCount {
                             let r = Double(ledData[k*3]) / 255.0
                             let g = Double(ledData[k*3+1]) / 255.0
                             let b = Double(ledData[k*3+2]) / 255.0
                             outputStruct.append(Color(red: r, green: g, blue: b))
                         }
                         
                         if orientation == .reverse {
                             var temp = outputStruct
                             if bottomZone > 0 && bottomZone < temp.count {
                                 let suffix = temp.suffix(bottomZone)
                                 temp.removeLast(bottomZone)
                                 temp.insert(contentsOf: suffix, at: 0)
                             }
                             temp.reverse()
                             zoneColors = temp
                         } else {
                             zoneColors = outputStruct
                         }
                         displayColors = zoneColors
                    } else {
                         displayColors = Array(repeating: Color.gray.opacity(0.15), count: totalZones)
                    }
                    
                    // 2. Main Sector Drawing (Subtle)
                    for i in 0..<totalZones {
                        if i + 1 < points.count {
                            let p1 = points[i]
                            let p2 = points[i+1]
                            
                            var path = Path()
                            path.move(to: origin)
                            path.addLine(to: p1)
                            path.addLine(to: p2)
                            path.closeSubpath()
                            
                            // Reduce opacity for "preview" feel, increase near edges?
                            // Uniform fill for now but smoother
                            let color = (i < displayColors.count) ? displayColors[i] : Color.gray.opacity(0.1)
                            context.fill(path, with: .color(color.opacity(0.6)))
                        }
                    }
                    
                    // 3. Edge Glow Effect (Simulate LED Strip)
                    // Draw a thick stroke around the perimeter with the LED color
                    // This creates the "Ambilight" look
                    context.addFilter(.blur(radius: 8)) // Soft bloom
                    
                    for i in 0..<totalZones {
                        if i + 1 < points.count {
                            let p1 = points[i]
                            let p2 = points[i+1]
                            
                            var edgePath = Path()
                            edgePath.move(to: p1)
                            edgePath.addLine(to: p2)
                            
                            let color = (i < displayColors.count) ? displayColors[i] : Color.clear
                            context.stroke(edgePath, with: .color(color), lineWidth: 6)
                        }
                    }
                }
                
                // Origin Indicator (Subtle overlay)
                Circle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 6, height: 6)
                    .position(x: width * 0.5, y: height * originY)
                    .shadow(color: .black, radius: 1)
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}
