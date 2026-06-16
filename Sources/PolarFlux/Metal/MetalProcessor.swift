import Foundation
import Metal
import CoreVideo
import simd

struct PerceptualUniforms {
    var whitePoint: simd_float3
    var adaptedLuma: Float
}

class MetalProcessor {
    static var isSupported: Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }

    /// Loads the Metal shader library.
    ///
    /// In a packaged `.app` the script compiles `Shaders.metal` into
    /// `default.metallib`, so `makeDefaultLibrary()` succeeds. In SPM/dev builds
    /// (`swift run`) SPM only ships the `.metal` *source* as a resource and does
    /// not compile it, so `makeDefaultLibrary()` returns nil and the engine would
    /// silently fall back to the CPU path. To keep Metal active in both contexts,
    /// we fall back to runtime-compiling the bundled source.
    static func makeLibrary(device: MTLDevice) -> MTLLibrary? {
        // 1. Compiled metallib (packaged app).
        if let lib = try? device.makeDefaultLibrary() { return lib }

        // 2. Runtime-compile the bundled source (SPM/dev builds). Search every
        //    loaded bundle, the main bundle, and the SPM resource module bundle
        //    (named "<Product>_<Target>.bundle" beside the executable) so the
        //    shader is found regardless of how the resource was packaged.
        var bundles = Bundle.allBundles
        bundles.append(Bundle.main)
        let moduleURL = Bundle.main.bundleURL.appendingPathComponent("PolarFlux_PolarFlux.bundle")
        if let moduleBundle = Bundle(url: moduleURL) {
            bundles.append(moduleBundle)
        }

        for bundle in bundles {
            guard let url = bundle.url(forResource: "Shaders", withExtension: "metal"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let lib = try? device.makeLibrary(source: source, options: nil) {
                return lib
            }
        }
        return nil
    }
    
    private(set) var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    
    // Output Textures (Persistent)
    private var outAvgTexture: MTLTexture?
    private var outPeakTexture: MTLTexture?
    
    // Fixed Downsample Resolution (16:9)
    let outputWidth = 160
    let outputHeight = 90
    
    let isAvailable: Bool
    
    init() {
        // Create the device exactly once. `MTLCreateSystemDefaultDevice()` returns
        // nil on headless/unsupported systems — treat that as "Metal unavailable"
        // rather than crashing.
        guard let dev = MTLCreateSystemDefaultDevice() else {
            self.device = nil
            self.commandQueue = nil
            self.pipelineState = nil
            self.isAvailable = false
            return
        }

        self.device = dev

        guard let queue = dev.makeCommandQueue(),
              let library = MetalProcessor.makeLibrary(device: dev),
              let kernelFunction = library.makeFunction(name: "process_frame")
        else {
            Logger.shared.log("MetalProcessor: Failed to initialize Metal pipeline (CPU fallback)")
            self.commandQueue = dev.makeCommandQueue()
            self.pipelineState = nil
            self.isAvailable = false
            return
        }

        self.commandQueue = queue

        do {
            self.pipelineState = try dev.makeComputePipelineState(function: kernelFunction)

            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
            self.textureCache = cache

            // Pre-allocate output textures with Float32 for easier Swift interop
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: outputWidth, height: outputHeight, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]

            self.outAvgTexture = dev.makeTexture(descriptor: desc)
            self.outPeakTexture = dev.makeTexture(descriptor: desc)

            self.isAvailable = (outAvgTexture != nil && outPeakTexture != nil)
        } catch {
            print("MetalProcessor: Setup Failed: \(error)")
            self.pipelineState = nil
            self.isAvailable = false
        }
    }
    
    func process(pixelBuffer: CVPixelBuffer, whitePoint: SIMD3<Float>, adaptedLuma: Float) -> (avg: [Float], peak: [Float])? {
        guard isAvailable,
              let commandQueue = commandQueue,
              let textureCache = textureCache,
              let outAvg = outAvgTexture,
              let outPeak = outPeakTexture,
              let pipelineState = pipelineState
        else { return nil }
        
        var uniforms = PerceptualUniforms(whitePoint: whitePoint, adaptedLuma: adaptedLuma)
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm, 
            width,
            height,
            0,
            &cvTexture
        )
        
        guard result == kCVReturnSuccess,
              let cvTex = cvTexture,
              let inputTexture = CVMetalTextureGetTexture(cvTex)
        else { return nil }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outAvg, index: 1)
        encoder.setTexture(outPeak, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<PerceptualUniforms>.stride, index: 0)
        
        let w = pipelineState.threadExecutionWidth
        let h = pipelineState.maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        let threadsPerGrid = MTLSizeMake(outputWidth, outputHeight, 1)
        
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        
        commandBuffer.commit()
        let execStart = CFAbsoluteTimeGetCurrent()
        commandBuffer.waitUntilCompleted()
        PerformanceMonitor.shared.record(metric: .metalCompute, time: CFAbsoluteTimeGetCurrent() - execStart)
        
        return readTextures(outAvg: outAvg, outPeak: outPeak)
    }
    
    private func readTextures(outAvg: MTLTexture, outPeak: MTLTexture) -> ([Float], [Float]) {
        let start = CFAbsoluteTimeGetCurrent()
        let count = outputWidth * outputHeight * 4
        var avgBytes = [Float](repeating: 0, count: count)
        var peakBytes = [Float](repeating: 0, count: count)
        
        let region = MTLRegionMake2D(0, 0, outputWidth, outputHeight)
        let bytesPerRow = outputWidth * 16 // 4 bytes * 4 channels
        
        outAvg.getBytes(&avgBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        outPeak.getBytes(&peakBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        
        PerformanceMonitor.shared.record(metric: .metalTransfer, time: CFAbsoluteTimeGetCurrent() - start)
        return (avgBytes, peakBytes)
    }
}
