#include <metal_stdlib>
using namespace metal;

constant float3 kRec709Luma = float3(0.299, 0.587, 0.114);

// Helper function: Calculate Perceptual Saliency
// Matches the CPU implementation in ScreenCapture.swift
float calculateSaliency(float3 color) {
    // 1. Linearize (Approximate Gamma 2.2) 
    float3 linear = color * color;
    
    // 2. Luminance (Y)
    float y = dot(linear, kRec709Luma);
    
    // 3. Chromaticity (Distance from Grey)
    float avg = (color.r + color.g + color.b) / 3.0;
    float dev = abs(color.r - avg) + abs(color.g - avg) + abs(color.b - avg);
    
    float saturation = (avg > 0.001) ? (dev / avg) : 0.0;
    
    // 4. Saliency = Chroma * Luminance Weight
    // Sigmoid mapping for Saturation
    float satWeight = 1.0 / (1.0 + exp(-15.0 * (saturation - 0.4)));
    
    // Brightness Weight
    // CPU threshold 1600 (scale 255) -> ~0.0246 (scale 1.0)
    float threshold = 0.0246;
    float briWeight = (y > threshold) ? 1.0 : (y / threshold);
    
    return satWeight * briWeight;
}

// Kernel: Downsample and Saliency Analysis
// Reduces a large input texture into two smaller textures:
// 1. Average: Contains Sum(RGB * Saliency) and Sum(Saliency)
// 2. Peak: Contains RGB of max Saliency pixel and MaxSaliency value
kernel void process_frame(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outAvg [[texture(1)]],
    texture2d<float, access::write> outPeak [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    // Output dimensions (e.g. 128x72)
    uint outWidth = outAvg.get_width();
    uint outHeight = outAvg.get_height();
    
    if (gid.x >= outWidth || gid.y >= outHeight) return;
    
    // Input dimensions (e.g. 1920x1080)
    uint inWidth = inTexture.get_width();
    uint inHeight = inTexture.get_height();
    
    // Calculate input block range for this output pixel
    float scanX = (float)gid.x / (float)outWidth;
    float scanY = (float)gid.y / (float)outHeight;
    float stepX = 1.0 / (float)outWidth;
    float stepY = 1.0 / (float)outHeight;
    
    uint startX = uint(scanX * inWidth);
    uint startY = uint(scanY * inHeight);
    uint endX = uint((scanX + stepX) * inWidth);
    uint endY = uint((scanY + stepY) * inHeight);
    
    // Clamp
    endX = min(endX, inWidth);
    endY = min(endY, inHeight);
    
    float3 sumColor = float3(0.0);
    float totalWeight = 0.0;
    
    float maxSaliency = -1.0;
    float3 peakColor = float3(0.0);
    
    // Loop through the block
    // Stride 2 helps performance and matches "preview" quality (optional)
    for (uint y = startY; y < endY; y += 2) {
        for (uint x = startX; x < endX; x += 2) {
            float4 pixel = inTexture.read(uint2(x, y));
            float3 rgb = pixel.rgb;
            
            float saliency = calculateSaliency(rgb);
            
            // Peak Tracking
            if (saliency > maxSaliency) {
                maxSaliency = saliency;
                peakColor = rgb;
            }
            
            // Weighted Average Accumulation
            sumColor += rgb * saliency;
            totalWeight += saliency;
        }
    }
    
    // Write Outputs
    // outAvg: (SumR, SumG, SumB, WeightSum)
    // Note: This requires RGBA16Float or RGBA32Float texture to avoid clamping > 1.0
    outAvg.write(float4(sumColor, totalWeight), gid);
    
    // outPeak: (PeakR, PeakG, PeakB, MaxSaliency)
    // MaxSaliency is 0-1, RGB is 0-1.
    outPeak.write(float4(peakColor, maxSaliency), gid);
}
