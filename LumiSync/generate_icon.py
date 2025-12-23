from PIL import Image, ImageDraw
import os

def create_icon():
    size = 1024
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # 1. Background: Dark Rounded Rect
    bg_color = (20, 20, 25, 255)
    r = 220
    rect = [50, 50, 974, 974]
    
    # Draw rounded rect
    # Fallback for older Pillow if rounded_rectangle doesn't exist
    if hasattr(draw, 'rounded_rectangle'):
        draw.rounded_rectangle(rect, radius=r, fill=bg_color)
    else:
        draw.rectangle(rect, fill=bg_color)
    
    # 2. RGB Ring
    center = (512, 512)
    radius = 320
    width = 60
    
    # Red (Top-Right)
    draw.arc([center[0]-radius, center[1]-radius, center[0]+radius, center[1]+radius], 
             -60, 60, fill=(255, 60, 60, 255), width=width)
             
    # Green (Bottom)
    draw.arc([center[0]-radius, center[1]-radius, center[0]+radius, center[1]+radius], 
             60, 180, fill=(60, 255, 60, 255), width=width)
             
    # Blue (Top-Left)
    draw.arc([center[0]-radius, center[1]-radius, center[0]+radius, center[1]+radius], 
             180, 300, fill=(60, 60, 255, 255), width=width)
             
    # 3. Center Symbol: "Play" Triangle (White)
    # Points: (400, 350), (400, 674), (700, 512)
    triangle_color = (240, 240, 240, 255)
    draw.polygon([(420, 380), (420, 644), (650, 512)], fill=triangle_color)
    
    # Save
    if not os.path.exists('LumiSync.iconset'):
        os.makedirs('LumiSync.iconset')
        
    img.save('LumiSync.iconset/icon_512x512@2x.png')
    
    sizes = [16, 32, 128, 256, 512]
    for s in sizes:
        resized = img.resize((s, s), Image.Resampling.LANCZOS)
        resized.save(f'LumiSync.iconset/icon_{s}x{s}.png')
        resized.save(f'LumiSync.iconset/icon_{s//2}x{s//2}@2x.png')

if __name__ == "__main__":
    create_icon()
