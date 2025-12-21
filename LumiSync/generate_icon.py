from PIL import Image, ImageDraw, ImageFilter
import os

def create_icon():
    size = 1024
    # macOS Big Sur+ style: Rounded Rectangle (Squircle)
    # Actually, macOS applies the mask automatically if we provide a square image, 
    # but for the iconset it's better to fill the square.
    # However, to look "professional", we usually design within the squircle shape.
    # Let's just make a nice background and let macOS handle the masking if we were using a proper asset catalog,
    # but for .icns, we usually provide the full image.
    
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # Background: Dark Grey/Black Gradient
    # Simple solid for now to be safe and clean
    rect_color = (30, 30, 35, 255)
    draw.rectangle([0, 0, size, size], fill=rect_color)
    
    # Draw a "Lightstrip" - A glowing rainbow curve or line
    # Let's do a diagonal rainbow gradient line
    
    margin = 200
    width = 120
    
    # Create a gradient
    gradient = Image.new('RGBA', (size, size), (0,0,0,0))
    g_draw = ImageDraw.Draw(gradient)
    
    colors = [
        (255, 0, 0, 255),    # Red
        (255, 165, 0, 255),  # Orange
        (255, 255, 0, 255),  # Yellow
        (0, 255, 0, 255),    # Green
        (0, 0, 255, 255),    # Blue
        (75, 0, 130, 255),   # Indigo
        (238, 130, 238, 255) # Violet
    ]
    
    # Draw diagonal strips
    step = (size - 2 * margin) / len(colors)
    
    # Draw a glowing "S" shape or just a diagonal line?
    # Let's do a simple diagonal line for "Sync"
    
    start_x = margin
    start_y = size - margin
    end_x = size - margin
    end_y = margin
    
    # Draw multiple lines to simulate gradient
    points = []
    for i in range(100):
        t = i / 100.0
        x = start_x + (end_x - start_x) * t
        y = start_y + (end_y - start_y) * t
        points.append((x, y))
        
    # Draw points with varying colors
    r = 60
    for i, (x, y) in enumerate(points):
        # Interpolate color
        color_idx = (i / len(points)) * (len(colors) - 1)
        c1 = colors[int(color_idx)]
        c2 = colors[min(int(color_idx) + 1, len(colors) - 1)]
        local_t = color_idx - int(color_idx)
        
        cr = int(c1[0] + (c2[0] - c1[0]) * local_t)
        cg = int(c1[1] + (c2[1] - c1[1]) * local_t)
        cb = int(c1[2] + (c2[2] - c1[2]) * local_t)
        
        draw.ellipse([x-r, y-r, x+r, y+r], fill=(cr, cg, cb, 255))

    # Add a "L" or "Sync" symbol? Maybe just the lightstrip is enough.
    # Let's add a blur to make it glow
    img = img.filter(ImageFilter.GaussianBlur(radius=2))
    
    # Save
    if not os.path.exists("LumiSync.iconset"):
        os.makedirs("LumiSync.iconset")
        
    # Generate sizes for iconset
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for s in sizes:
        resized = img.resize((s, s), Image.Resampling.LANCZOS)
        resized.save(f"LumiSync.iconset/icon_{s}x{s}.png")
        resized.save(f"LumiSync.iconset/icon_{s//2}x{s//2}@2x.png")

    print("Iconset created.")

if __name__ == "__main__":
    create_icon()
