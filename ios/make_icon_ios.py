# -*- coding: utf-8 -*-
"""生成 iOS App 图标（1024 方形，砂岩工业风：奶油纸底 + 墨黑边框 + 信号黄括标 + 记字）。"""
import os
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Resources",
                   "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
S = 1024

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
# 奶油纸底
d.rectangle([0, 0, S - 1, S - 1], fill=(230, 225, 213, 255))
# 外框（墨黑直角）
d.rectangle([40, 40, S - 40, S - 40], outline=(21, 20, 16, 255), width=40)
# 内细框
d.rectangle([120, 120, S - 120, S - 120], outline=(200, 192, 173, 255), width=10)
# 左上信号黄直角括标
d.rectangle([70, 70, 300, 110], fill=(224, 174, 5, 255))
d.rectangle([70, 70, 110, 300], fill=(224, 174, 5, 255))
# 右下青碧短线
d.rectangle([S - 300, S - 110, S - 70, S - 70], fill=(11, 111, 108, 255))

try:
    font = ImageFont.truetype(r"C:\Windows\Fonts\msyhbd.ttc", 520)
except Exception:
    font = ImageFont.load_default()
ch = "记"
bb = d.textbbox((0, 0), ch, font=font)
w, h = bb[2] - bb[0], bb[3] - bb[1]
d.text(((S - w) / 2 - bb[0], (S - h) / 2 - bb[1] - 30), ch, font=font, fill=(21, 20, 16, 255))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
# iOS 图标不能带 alpha 通道（actool 会警告/报错）→ 转成 RGB 再存
img.convert("RGB").save(OUT, format="PNG")
print("written", OUT, os.path.getsize(OUT), "bytes", img.size, "mode=RGB")
