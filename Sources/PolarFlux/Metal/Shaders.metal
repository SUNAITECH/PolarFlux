#include <metal_stdlib>
using namespace metal;

constant float3 kRec709Luma = float3(0.2126, 0.7152, 0.0722);

// Helper function: Calculate Perceptual Saliency
float calculateSaliency(float3 color) {
    // 1. Non-linear Brightness (Gamma 2.0 approximation)
    // We use the square of the color values to approximate the non-linear response
    float3 linearColor = color * color;
    float y = dot(linearColor, kRec709Luma);
    
    // 2. Efficient Saturation (HSV approximation)
    float maxVal = max(max(color.r, color.g), color.b);
    float minVal = min(min(color.r, color.g), color.b);
    float delta = maxVal - minVal;
    float saturation = (maxVal > 0.0) ? (delta / maxVal) : 0.0;
    
    // 3. Hue-Specific Enhancement
    // We want to boost warm colors (Red, Orange, Yellow) which are high impact.
    // Hue estimation without full atan2:
    // Warm colors have high Red component relative to Blue.
    float hueWeight = 1.0;
    if (color.r > color.b && (color.r > color.g * 0.5)) {
        // Boost Red/Orange/Yellow spectrum
        hueWeight = 1.2; 
    }
    
    // 4. Exponential Boosting for Vivid Areas
    // Combined metric of Saturation and Brightness
    float vividness = saturation * sqrt(maxVal); 
    float expBoost = exp(vividness * 2.5); // Strong non-linear boost for vivid pixels
    
    // 5. Sigmoid Compression
    // Center around 0.5 input, steep curve
    // To further suppress whitish colors, we penalize low saturation more aggressively
    float purity = saturation * maxVal; 
    float sigmoid = 1.0 / (1.0 + exp(-15.0 * (purity - 0.45))); // Center shifted higher and slope steepened
    
    // Additional "White Core" suppression:
    // If color is very bright and saturation is low, heavily penalize the weight.
    if (saturation < 0.2 && maxVal > 0.7) {
        sigmoid *= 0.1; 
    }
    
    // Final Saliency Weight
    // Base brightness weight ensures we don't boost dark noise
    float briWeight = smoothstep(0.05, 0.35, y); 
    
    return sigmoid * expBoost * hueWeight * briWeight;
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
