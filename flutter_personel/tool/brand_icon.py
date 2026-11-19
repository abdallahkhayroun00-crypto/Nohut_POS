"""Create Android launcher icons from Nohut's actual shop logo."""
from pathlib import Path
from PIL import Image, ImageOps

source = Image.open("assets/nohut-logo.webp").convert("RGBA")
for density, size in {
    "mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192,
}.items():
    canvas = Image.new("RGBA", (size, size), (18, 62, 48, 255))
    logo = ImageOps.contain(source, (round(size * 0.88), round(size * 0.88)))
    canvas.alpha_composite(
        logo, ((size-logo.width)//2, (size-logo.height)//2)
    )
    target = Path("android/app/src/main/res") / f"mipmap-{density}" / "ic_launcher.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(target, "PNG")
print("Nohut brand Android icons created")
