#!/usr/bin/python3
"""生成 App 图标：暖白纸张底 + 深青色书签 + 「拾」字。用系统自带 PIL（/usr/bin/python3）。
输出 App/Resources/AppIcon.icns（经 iconutil）。"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "App", "Resources", "AppIcon.icns")
FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"

def draw(size):
    S = 1024
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # macOS 图标网格：824 内容区居中，圆角约 185
    pad, r = 100, 185
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((pad, pad + 14, S - pad, S - pad + 14), r, fill=(0, 0, 0, 90))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(18)))
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(base)
    # 纸张渐变
    top, bot = (252, 249, 241), (238, 231, 214)
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / S
        gd.line([(0, y), (S, y)], fill=tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)) + (255,))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((pad, pad, S - pad, S - pad), r, fill=255)
    base.paste(grad, (0, 0), mask)
    # 右上角书签
    teal = (22, 110, 112, 255)
    bx0, bx1, by0, by1 = 668, 784, pad, 372
    d.polygon([(bx0, by0), (bx1, by0), (bx1, by1), ((bx0 + bx1) // 2, by1 - 60), (bx0, by1)], fill=(196, 120, 46, 255))
    # 「拾」
    font = ImageFont.truetype(FONT, 500, index=2)  # W6
    text = "拾"
    bbox = d.textbbox((0, 0), text, font=font)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text(((S - w) / 2 - bbox[0] - 44, (S - h) / 2 - bbox[1] + 44), text, font=font, fill=teal)
    img = Image.alpha_composite(img, base)
    return img.resize((size, size), Image.LANCZOS)

def main():
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for pt in (16, 32, 128, 256, 512):
            draw(pt).save(os.path.join(iconset, f"icon_{pt}x{pt}.png"))
            draw(pt * 2).save(os.path.join(iconset, f"icon_{pt}x{pt}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT], check=True)
        os.makedirs(os.path.join(ROOT, "build"), exist_ok=True); draw(512).save(os.path.join(ROOT, "build", "icon-preview.png"))
    print("写入", OUT)

if __name__ == "__main__":
    main()
