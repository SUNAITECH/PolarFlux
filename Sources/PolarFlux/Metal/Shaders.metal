#include <metal_stdlib>
using namespace metal;

constant float3 kRec709Luma = float3(0.2126, 0.7152, 0.0722);

struct PerceptualUniforms {
    float3 whitePoint;
    float adaptedLuma;
};

// --- CIE-Based Perceptual Enhancement Pipeline ---

float3 applyPerceptualEnhancement(float3 rgb, PerceptualUniforms u) {
    // 1. Von Kries Chromatic Adaptation
    // Maps colors relative to the inferred scene white point
    float3 enhanced = rgb / max(u.whitePoint, float3(0.01));
    
    // 2. Luminance Adaptation (Simulating Human Contrast Sensitivity)
    // S-curve response: L_out = L^k / (L^k + L_adapted^k)
    // We use k=1.2 to slightly expand contrast relative to the scene average
    float luma = dot(enhanced, kRec709Luma);
    float k = 1.25; 
    float l_adapted = max(u.adaptedLuma, 0.1); 
    float l_enhanced = pow(max(luma, 0.001), k) / (pow(max(luma, 0.001), k) + pow(l_adapted, k));
    
    // Apply contrast gain
    enhanced *= (luma > 0.001) ? (l_enhanced / luma) : 1.0;
    
    // 3. Helmholtz-Kohlrausch Effect (H-K Effect)
    // Saturated colors are perceived as brighter.
    float maxVal = max(enhanced.r, max(enhanced.g, enhanced.b));
    float minVal = min(enhanced.r, min(enhanced.g, enhanced.b));
    float saturation = (maxVal > 0.001) ? (maxVal - minVal) / maxVal : 0.0;
    
    // Boost perceived luminance based on saturation
    enhanced *= (1.0 + 0.45 * saturation * saturation);
    
    // 4. Hunt Effect (Luminance-Induced Saturation)
    // Colors appear more saturated as luminance increases.
    float3 gray = dot(enhanced, kRec709Luma);
    enhanced = mix(gray, enhanced, 1.0 + 0.35 * l_enhanced);
    
    return enhanced;
}

// Helper function: Calculate Perceptual Saliency
float calculateSaliency(float3 color) {
    float3 linearColor = color * color;
    float y = dot(linearColor, kRec709Luma);
    
    float maxVal = max(max(color.r, color.g), color.b);
    float minVal = min(min(color.r, color.g), color.b);
    float saturation = (maxVal > 0.0) ? (maxVal - minVal) / maxVal : 0.0;
    
    float hueWeight = 1.0;
    if (color.r > color.b && (color.r > color.g * 0.5)) {
        hueWeight = 1.35; 
    }
    
    float vividness = saturation * sqrt(maxVal); 
    float expBoost = exp(vividness * 2.8); 
    
    float purity = saturation * maxVal; 
    float sigmoid = 1.0 / (1.0 + exp(-12.0 * (purity - 0.4))); 
    
    if (saturation < 0.2 && maxVal > 0.7) {
        sigmoid *= 0.05; 
    }
    
    float t = clamp((y - 0.02) / 0.38, 0.0, 1.0);
    float briWeight = t * t * (3.0 - 2.0 * t);
    
    return sigmoid * expBoost * hueWeight * briWeight;
}

// Kernel: Downsample and Saliency Analysis
kernel void process_frame(
    texture2d<float, access::read> inTexture [[texture(0)]],
    texture2d<float, access::write> outAvg [[texture(1)]],
    texture2d<float, access::write> outPeak [[texture(2)]],
    constant PerceptualUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint outWidth = outAvg.get_width();
    uint outHeight = outAvg.get_height();
    
    if (gid.x >= outWidth || gid.y >= outHeight) return;
    
    uint inWidth = inTexture.get_width();
    uint inHeight = inTexture.get_height();
    
    float scanX = (float)gid.x / (float)outWidth;
    float scanY = (float)gid.y / (float)outHeight;
    float stepX = 1.0 / (float)outWidth;
    float stepY = 1.0 / (float)outHeight;
    
    uint startX = uint(scanX * inWidth);
    uint startY = uint(scanY * inHeight);
    uint endX = uint((scanX + stepX) * inWidth);
    uint endY = uint((scanY + stepY) * inHeight);
    
    endX = min(endX, inWidth);
    endY = min(endY, inHeight);
    
    float3 sumColor = float3(0.0);
    float totalWeight = 0.0;
    
    float maxSaliency = -1.0;
    float3 peakColor = float3(0.0);
    
    for (uint y = startY; y < endY; y++) {
        for (uint x = startX; x < endX; x++) {
            float4 pixel = inTexture.read(uint2(x, y));
            float3 rgb = pixel.rgb;
            
            // Apply Computational Color Science Enhancement
            float3 enhanced = applyPerceptualEnhancement(rgb, u);
            
            float saliency = calculateSaliency(enhanced);
            
            if (saliency > maxSaliency) {
                maxSaliency = saliency;
                peakColor = enhanced;
            }
            
            // Critical Scale Fix: CPU path expects 0-255 values in accumulators
            sumColor += (enhanced * 255.0) * saliency;
            totalWeight += saliency;
        }
    }
    
    outAvg.write(float4(sumColor, totalWeight), gid);
    outPeak.write(float4(peakColor * 255.0, maxSaliency), gid);
}
