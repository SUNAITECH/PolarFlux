import SwiftUI

struct PerformanceSettingsView: View {
    @StateObject private var monitor = PerformanceMonitor.shared
    @State private var showingCopyFeedback = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "PERF_PANEL_TITLE"))
                        .font(.title2)
                    
                    Spacer()
                    
                    Button(action: copyMetricsToClipboard) {
                        Label(
                            showingCopyFeedback ? String(localized: "PERF_COPIED") : String(localized: "PERF_COPY_REPORT"),
                            systemImage: showingCopyFeedback ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                        .foregroundColor(showingCopyFeedback ? .green : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .disabled(monitor.metrics.isEmpty)
                }
                .padding(.bottom, 10)
                
                // Overview
                if let total = monitor.metrics[.totalFrame] {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(String(localized: "PERF_TOTAL_FRAME"))
                                .font(.headline)
                            Text(String(format: "%.2f ms", total))
                                .font(.system(.title, design: .monospaced))
                                .foregroundColor(colorForTime(total))
                        }
                        Spacer()
                        fpsView()
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                } else {
                    Text(String(localized: "PERF_WAITING_DATA"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                Text(String(localized: "PERF_BREAKDOWN"))
                    .font(.headline)
                
                // Detailed Bars
                VStack(spacing: 16) {
                    metricRow(type: .metalTotal)
                    // Indent children of Metal
                    if let metalVal = monitor.metrics[.metalTotal], metalVal > 0 {
                        VStack(spacing: 8) {
                            metricRow(type: .metalCompute, indent: true)
                            metricRow(type: .metalTransfer, indent: true)
                        }
                    }
                    
                    metricRow(type: .zoneMapping)
                    metricRow(type: .physicsSmoothing)
                    
                    if let cpuVal = monitor.metrics[.cpuPath], cpuVal > 0 {
                        Divider().padding(.vertical, 4)
                        metricRow(type: .cpuPath)
                    }
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    func metricRow(type: PerformanceMonitor.MetricType, indent: Bool = false) -> some View {
        if let val = monitor.metrics[type], val > 0.0001 { 
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    if indent {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 10)
                    }
                    Text(String(localized: String.LocalizationValue(type.localizationKey)))
                        .font(indent ? .caption : .subheadline)
                    Spacer()
                    Text(String(format: "%.3f ms", val))
                        .font(.system(indent ? .caption : .callout, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.leading, indent ? 10 : 0)
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(height: 6)
                            .cornerRadius(3)
                            
                        Rectangle()
                            .fill(indent ? Color.blue.opacity(0.6) : Color.blue)
                            // Scale relative to 16ms frame budget
                            .frame(width: min(geo.size.width, geo.size.width * (CGFloat(val) / 16.66)), height: 6)
                            .cornerRadius(3)
                    }
                }
                .frame(height: 6)
                .padding(.leading, indent ? 24 : 0)
            }
        }
    }
    
    func fpsView() -> some View {
        HStack(spacing: 15) {
            VStack {
                Text(String(localized: "PERF_ACTUAL_FPS"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(String(format: "%.0f", monitor.actualFPS))
                    .font(.title3)
                    .bold()
                    .foregroundColor(monitor.actualFPS < 40 ? .orange : .green)
            }
            
            Divider().frame(height: 30)
            
            if let total = monitor.metrics[.totalFrame] {
                let capacity = 1000.0 / max(total, 1.0)
                VStack {
                    Text(String(localized: "PERF_CAPACITY"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f", capacity))
                        .font(.title3)
                        .bold()
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    func colorForTime(_ ms: Double) -> Color {
        if ms < 10 { return .green }
        if ms < 16.6 { return .orange }
        return .red
    }
    
    // MARK: - Helper Actions
    
    private func copyMetricsToClipboard() {
        var report = "--- PolarFlux Performance Report ---\n"
        report += "Date: \(Date().formatted())\n"
        report += "OS: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        
        let sortedKeys = PerformanceMonitor.MetricType.allCases
        for type in sortedKeys {
            if let val = monitor.metrics[type] {
                let name = String(localized: String.LocalizationValue(type.localizationKey))
                report += "\(name): \(String(format: "%.3f ms", val))\n"
            }
        }
        
        if let total = monitor.metrics[.totalFrame] {
            report += "Actual FPS: \(String(format: "%.0f", monitor.actualFPS))\n"
            report += "Max Compute Capacity: \(String(format: "%.0f fps", 1000.0 / total))\n"
        }
        
        report += "\n--- End Report ---"
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        
        withAnimation {
            showingCopyFeedback = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showingCopyFeedback = false
            }
        }
    }
}
