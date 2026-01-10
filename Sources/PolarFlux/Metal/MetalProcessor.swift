import Foundation
import Metal
import CoreVideo

class MetalProcessor {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
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
        // Safe Initialization
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue(),
              let library = dev.makeDefaultLibrary(),
              let kernelFunction = library.makeFunction(name: "process_frame")
        else {
            print("MetalProcessor: Failed to initialize Metal")
            // Provide dummy values to satisfy compiler init rules, but flag as unavailable
            self.device = MTLCreateSystemDefaultDevice() ?? MTLCreateSystemDefaultDevice()! 
            self.commandQueue = self.device.makeCommandQueue()!
            self.pipelineState = nil
            self.isAvailable = false
            return
        }
        
        
        self.device = dev
        self.commandQueue = queue
        
        do {
            self.pipelineState = try dev.makeComputePipelineState(function: kernelFunction)
            
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
            self.textureCache = cache
            
            // Pre-allocate output textures with Float32 for easier Swift interop
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 160, height: 90, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            
            self.outAvgTexture = dev.makeTexture(descriptor: desc)
            self.outPeakTexture = dev.makeTexture(descriptor: desc)
            
            self.isAvailable = true
        } catch {
            print("MetalProcessor: Setup Failed: \(error)")
            self.pipelineState = nil
            self.isAvailable = false
        }
    }
    
    func process(pixelBuffer: CVPixelBuffer) -> (avg: [Float], peak: [Float])? {
        guard isAvailable,
              let textureCache = textureCache,
              let outAvg = outAvgTexture,
              let outPeak = outPeakTexture,
              let pipelineState = pipelineState
        else { return nil }
        
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
        
        let w = pipelineState.threadExecutionWidth
        let h = pipelineState.maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        let threadsPerGrid = MTLSizeMake(outputWidth, outputHeight, 1)
        
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        return readTextures(outAvg: outAvg, outPeak: outPeak)
    }
    
    private func readTextures(outAvg: MTLTexture, outPeak: MTLTexture) -> ([Float], [Float]) {
        let count = outputWidth * outputHeight * 4
        var avgBytes = [Float](repeating: 0, count: count)
        var peakBytes = [Float](repeating: 0, count: count)
        
        let region = MTLRegionMake2D(0, 0, outputWidth, outputHeight)
        let bytesPerRow = outputWidth * 16 // 4 bytes * 4 channels
        
        outAvg.getBytes(&avgBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        outPeak.getBytes(&peakBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        
        return (avgBytes, peakBytes)
    }
}
