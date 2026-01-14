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
            
            // Background
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .border(Color.secondary.opacity(0.3), width: 1)
            
            // Draw Sectors
            Canvas { context, size in
                let totalZones = leftZone + topZone + rightZone + bottomZone
                guard totalZones > 0 else { return }
                
                // 1. Calculate Boundary Points on Perimeter
                var points: [CGPoint] = []
                
                // Left: Bottom-Left to Top-Left
                if leftZone > 0 {
                    for i in 0...leftZone {
                        let y = size.height - (Double(i) * (size.height / Double(leftZone)))
                        points.append(CGPoint(x: 0, y: y))
                    }
                } else {
                    points.append(CGPoint(x: 0, y: size.height))
                }
                
                // Top: Top-Left to Top-Right
                if topZone > 0 {
                    if !points.isEmpty { points.removeLast() }
                    for i in 0...topZone {
                        let x = Double(i) * (size.width / Double(topZone))
                        points.append(CGPoint(x: x, y: 0))
                    }
                } else {
                    // Start of top is end of left (0,0) - already added if left>0
                    // If left=0, the last point was (0,H). We need to get to (0,0) then (W,0) if top=0?
                    // Actually, if a side has 0 zones, it essentially has no "points" contributing to the sequence,
                    // but the perimeter continuity implies we just skip that corner?
                    // The ScreenCapture logic appends the corner if zones=0.
                    // Let's stick to the logic:
                    // If left=0, we added (0, H).
                    // If top=0, we append (W, 0).
                } 
                // Simplified Logic to match ScreenCapture exactly:
                
                // Re-init points to be safe
                points = []
                
                // Left
                if leftZone > 0 {
                    for i in 0...leftZone {
                        let y = size.height - (Double(i) * (size.height / Double(leftZone)))
                        points.append(CGPoint(x: 0, y: y))
                    }
                } else {
                    points.append(CGPoint(x: 0, y: size.height))
                }
                
                // Top
                if topZone > 0 {
                    if !points.isEmpty { points.removeLast() }
                    for i in 0...topZone {
                        let x = Double(i) * (size.width / Double(topZone))
                        points.append(CGPoint(x: x, y: 0))
                    }
                } else if topZone == 0 {
                    // Do not remove last
                    // If left added (0,0) as last, we are good?
                    // If left=0, points has [(0,H)]. We need to add Top-Left and Top-Right corner?
                    // No, ScreenCapture logic:
                    // if config.left > 0 { ... } else { append (xOffset, yOffset + capHeight) }
                    // if config.top > 0 { removeLast; for ... }
                    // If top=0, it does nothing? No, ScreenCapture logic has no 'else' for top/right/bottom if they are 0.
                    
                    // Let's look at ScreenCapture code again.
                    // if config.left > 0 { ... } else { append(bottom-left) }
                    // if config.top > 0 { ... }
                    // if config.right > 0 { ... }
                    // if config.bottom > 0 { ... }
                    
                    // This implies if top=0, no points are added for the top edge.
                    // This creates a gap in the boundary polygon?
                    // No, the boundary points define expectations for the angles.
                    // But for VISUALIZATION, we want to fill the whole screen.
                    // If top=0, the "sector" for the last Left LED would stretch to... where?
                    // In Polar Binning, if top=0, the angles jump from Top-Left to Top-Right?
                    // Effectively, the sector boundaries just don't have a point on the top edge.
                }
                
                // Right
                if rightZone > 0 {
                    if !points.isEmpty { points.removeLast() }
                    for i in 0...rightZone {
                        let y = Double(i) * (size.height / Double(rightZone))
                        points.append(CGPoint(x: size.width, y: y))
                    }
                }
                
                // Bottom
                if bottomZone > 0 {
                    if !points.isEmpty { points.removeLast() }
                    for i in 0...bottomZone {
                        let x = size.width - (Double(i) * (size.width / Double(bottomZone)))
                        points.append(CGPoint(x: x, y: size.height))
                    }
                }
                
                // 2. Map Points to Angles
                // However, for visualization, we can just draw triangles/quads using the points and the origin.
                // Between point[i] and point[i+1] is the outer edge of Zone i.
                // So Zone i is the polygon defined by: Origin -> point[i] -> point[i+1] -> Origin.
                // Note: The points list includes the "start" and "end" of each zone.
                // Total points should be totalZones + 1 (because it wraps around? No, it's a loop).
                // The last point of Bottom should close back to the start of Left?
                // The loop in ScreenCapture generates `boundaryPoints`.
                // Let's trace:
                // Left generates left+1 points. (0 to left).
                // Top removes 1, generates top+1 points.
                // Right removes 1, generates right+1 points.
                // Bottom removes 1, generates bottom+1 points.
                // Total points = (left+1) + top + right + bottom = totalZones + 1.
                // point[0] is Bottom-Left.
                // point[totalZones] is... Bottom-Left (x=0, y=size.height).
                // So yes, point[i] to point[i+1] defines the outer edge of zone i.
                
                let ledData = colors
                // Expected count = totalZones * 3
                
                // Orientation Handling for Color Indexing
                // Defines which 'index' of the ledData corresponds to zone 'i' in the standard CW loop.
                // Standard CW: Data[0] is Zone 0 (Bot-Left).
                // Reverse CCW: Data[0] is... usually Bottom-Right or Top-Left?
                // ScreenCapture.swift: if orientation == .reverse { smoothedColors.reverse(); shift... }
                // So if we have the FINAL ledData (processed), it's already in the order the user sees on the strip?
                // Or is ledData the "raw" mapping order?
                // If `colors` comes from `lastSentData`, it is the final output.
                // So we need to reverse the mapping if we want to show "Which LED lights up this sector".
                // If orientation is Standard: Zone i (CW) gets Color i.
                // If orientation is Reverse:
                // The code reverses the array and shifts bottom.
                // So Color 0 corresponds to the start of the strip.
                // In Reverse mode, where does the strip start? Usually "Standard" implies input is at Bottom-Left.
                // "Reverse" usually implies input is at Bottom-Right and goes CCW? Or Input is Bottom-Left but goes CCW?
                // Let's assume the visualization should show "What part of the screen drives LED #N".
                // We know Zone i (geometry) drives a specific LED.
                // In Standard: Zone i drives LED i.
                // In Reverse: Zone i (CW geometry) drives LED?
                // Let's map Zone Index -> Color.
                // We have `colors` array.
                // If Standard: color for Zone i is colors[i].
                // If Reverse: The colors array was constructed by `reverse()`ing the zone data.
                // So colors[0] comes from the LAST zone?
                // Let's look at ScreenCapture:
                // `smoothedColors` (order matches Zones 0..N)
                // if reverse: `smoothedColors.reverse()`
                // So `colors` (final output) has: index 0 = Zone N, index N = Zone 0.
                // So Color for Zone i = colors[count - 1 - i].
                // Also there is a shift for bottom count?
                // `smoothedColors.removeFirst(bottomCount); append(...)` after reverse.
                // This is complex to reverse-engineer perfectly for display without code duplication.
                // SIMPLIFICATION: We assume `colors` maps to the physical strip.
                // We want to show the color of the sector.
                // We should simulate the "Forward" pass.
                // We are drawing Zone i. What color is it?
                // If we display the "Input" colors (before reordering), it's easy: Zone i has Color i.
                // But `lastSentData` is Output.
                // Let's try to map Output -> Zone.
                // Standard: Output[i] = Zone[i].
                // Reverse:
                // 1. Zone Data -> Reverse -> Rotate Bottom -> Output.
                // So Output -> Ungroup Bottom -> Unreverse -> Zone Data.
                // Let's doing it:
                // Shift back: Take last `bottomCount` elements, move to front.
                // Reverse back: Reverse the array.
                // Result is Zone Data.
                
                var displayColors = [Color]()
                let byteCount = ledData.count
                let ledCount = byteCount / 3
                
                if ledCount == totalZones {
                     // Convert [UInt8] to [Color]
                     var zoneColors = [Color]()
                     // Reconstruct Zone Order from Output Order
                     // First, convert output to structured array
                     var outputStruct = [Color]()
                     for k in 0..<ledCount {
                         let r = Double(ledData[k*3]) / 255.0
                         let g = Double(ledData[k*3+1]) / 255.0
                         let b = Double(ledData[k*3+2]) / 255.0
                         outputStruct.append(Color(red: r, green: g, blue: b))
                     }
                     
                     if orientation == .reverse {
                         // Reverse the "reverse + shift" logic
                         // Forward: Reverse -> Shift(remove first B, append B)
                         // Wait, "removeFirst(bottomCount)" means taking from front (Left end after reverse?)
                         // Original: [Left, Top, Right, Bottom]
                         // Reverse: [Bottom, Right, Top, Left]
                         // Shift: removeFirst(BottomCount). If BottomCount is valid.
                         // The code:
                         // `let bottomSegment = Array(smoothedColors.prefix(bottomCount))` (Takes 'Bottom' part of reversed array?)
                         // `smoothedColors.removeFirst`
                         // `smoothedColors.append`
                         // So [Bottom, Right, Top, Left] -> becomes [Right, Top, Left, Bottom]
                         // So Output is [Right, Top, Left, Bottom].
                         // To restore [Left, Top, Right, Bottom]:
                         // 1. Take last `bottomCount` (which is Bottom), move to front -> [Bottom, Right, Top, Left]
                         // 2. Reverse -> [Left, Top, Right, Bottom].
                         
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
                    // Mismatch or empty, fallback to gray
                     displayColors = Array(repeating: Color.gray.opacity(0.2), count: totalZones)
                }
                
                // Draw
                for i in 0..<totalZones {
                    if i + 1 < points.count {
                        let p1 = points[i]
                        let p2 = points[i+1]
                        
                        var path = Path()
                        path.move(to: origin)
                        path.addLine(to: p1)
                        path.addLine(to: p2)
                        path.closeSubpath()
                        
                        let color = (i < displayColors.count) ? displayColors[i] : Color.gray.opacity(0.1)
                        context.fill(path, with: .color(color))
                        context.stroke(path, with: .color(Color.black.opacity(0.1)), lineWidth: 0.5)
                    }
                }
                
                // Draw Origin
                let originCircle = Path(ellipseIn: CGRect(x: origin.x - 4, y: origin.y - 4, width: 8, height: 8))
                context.fill(originCircle, with: .color(.white))
                context.stroke(originCircle, with: .color(.black), lineWidth: 1)
                
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .background(Color.black)
        .cornerRadius(8)
        .shadow(radius: 4)
    }
}
