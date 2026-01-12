import Foundation
import Combine

class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    
    // Config
    private let sampleInterval: Int = 30 // Update UI every 30 frames
    
    // State
    @Published var metrics: [MetricType: Double] = [:]
    @Published var actualFPS: Double = 0
    
    private var frameCount: Int = 0
    private var lastFlushTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var accumulations: [MetricType: Double] = [:]
    private var accumulationCounts: [MetricType: Int] = [:]
    private let queue = DispatchQueue(label: "com.sunaish.polarflux.perf", attributes: .concurrent)
    
    enum MetricType: String, CaseIterable, Identifiable {
        case totalFrame = "Total Frame Time"
        case cpuPath = "CPU Path"
        case metalTotal = "Metal Total"
        case metalCompute = "Metal Compute (GPU)"
        case metalTransfer = "Metal Data Transfer"
        case zoneMapping = "Zone Mapping"
        case colorEnhancement = "Color Enhancement" // CPU side if utilized
        case physicsSmoothing = "Physics Smoothing"
        
        var id: String { rawValue }
        
        var localizationKey: String {
            switch self {
            case .totalFrame: return "PERF_TOTAL_FRAME"
            case .cpuPath: return "PERF_CPU_PATH"
            case .metalTotal: return "PERF_METAL_TOTAL"
            case .metalCompute: return "PERF_METAL_COMPUTE"
            case .metalTransfer: return "PERF_METAL_TRANSFER"
            case .zoneMapping: return "PERF_ZONE_MAPPING"
            case .colorEnhancement: return "PERF_COLOR_ENHANCE"
            case .physicsSmoothing: return "PERF_PHYSICS"
            }
        }
    }
    
    // MARK: - API
    
    func record(metric: MetricType, time: TimeInterval) {
        queue.async(flags: .barrier) {
            self.accumulations[metric, default: 0] += time
            self.accumulationCounts[metric, default: 0] += 1
        }
    }
    
    func tickFrame() {
        queue.async(flags: .barrier) {
            self.frameCount += 1
            
            if self.frameCount >= self.sampleInterval {
                self.flushMetrics()
            }
        }
    }
    
    private func flushMetrics() {
        let currentTime = CFAbsoluteTimeGetCurrent()
        let elapsed = currentTime - lastFlushTime
        let currentFPS = Double(frameCount) / max(elapsed, 0.001)
        
        var newMetrics: [MetricType: Double] = [:]
        
        for (key, totalTime) in accumulations {
            let count = accumulationCounts[key] ?? 1
            if count > 0 {
                newMetrics[key] = (totalTime / Double(count)) * 1000.0 // Convert to ms
            }
        }
        
        // Reset
        accumulations.removeAll()
        accumulationCounts.removeAll()
        frameCount = 0
        lastFlushTime = currentTime
        
        // Publish on Main Thread
        DispatchQueue.main.async {
            self.metrics = newMetrics
            self.actualFPS = currentFPS
        }
    }
}
