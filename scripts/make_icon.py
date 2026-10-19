# Vẽ icon app (1024×1024). Cần font Bangers (Google Fonts, giấy phép OFL):
#   python3 scripts/make_icon.py <thư mục chứa FeVQS0BTqb0h60ACL5k.ttf> MangaTrans/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import math, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

FONTS = sys.argv[1]
OUT = sys.argv[2]
S = 2048  # vẽ gấp đôi rồi thu nhỏ cho mịn
BANGERS = f"{FONTS}/FeVQS0BTqb0h60ACL5k.ttf"

RED = (226, 44, 42)
RED_DARK = (170, 18, 30)
INK = (17, 17, 17)
PAPER = (255, 255, 255)
PAPER_BACK = (236, 236, 232)
YELLOW = (255, 212, 38)

img = Image.new("RGB", (S, S), RED)
d = ImageDraw.Draw(img)

# Nền đỏ chuyển sắc chéo
for y in range(S):
    t = y / S
    for_row = tuple(int(RED[i] * (1 - t * 0.45) + RED_DARK[i] * t * 0.45) for i in range(3))
    d.line([(0, y), (S, y)], fill=for_row)

# Đường tập trung (focus lines) kiểu manga, toả ra từ tâm bóng thoại
cx, cy = S * 0.56, S * 0.58
lines = Image.new("L", (S, S), 0)
ld = ImageDraw.Draw(lines)
n = 64
for i in range(n):
    a = 2 * math.pi * i / n + (0.03 if i % 2 else 0)
    w = 0.018 if i % 3 else 0.03
    r1, r2 = S * 0.42, S * 1.2
    p = [
        (cx + math.cos(a - w) * r2, cy + math.sin(a - w) * r2),
        (cx + math.cos(a) * r1, cy + math.sin(a) * r1),
        (cx + math.cos(a + w) * r2, cy + math.sin(a + w) * r2),
    ]
    ld.polygon(p, fill=255)
img.paste(Image.new("RGB", (S, S), (255, 120, 100)), (0, 0), lines.point(lambda v: v * 0.22))

# Chấm lưới (screentone) góc trên phải
tone = Image.new("L", (S, S), 0)
td = ImageDraw.Draw(tone)
step = 56
for gy in range(0, S, step):
    for gx in range(0, S, step):
        ox = gx + (step / 2 if (gy // step) % 2 else 0)
        dist = math.hypot(ox - S, gy - 0) / S
        r = max(0, 18 * (1 - dist / 0.75))
        if r > 1:
            td.ellipse([ox - r, gy - r, ox + r, gy + r], fill=255)
img.paste(Image.new("RGB", (S, S), (255, 160, 140)), (0, 0), tone.point(lambda v: v * 0.55))

def bubble(draw, box, tail, fill, outline_w):
    """Bóng thoại elip có đuôi; viền mực đều quanh cả đuôi (giãn mặt nạ hình)."""
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    md.ellipse(box, fill=255)
    md.polygon(tail, fill=255)
    size = outline_w * 2 + 1
    outline = mask.filter(ImageFilter.MaxFilter(size if size % 2 else size + 1))
    img.paste(Image.new("RGB", (S, S), INK), (0, 0), outline)
    img.paste(Image.new("RGB", (S, S), fill), (0, 0), mask)

# Bóng thoại sau: "EN"
bubble(d, (250, 330, 1050, 880), [(560, 800), (400, 1010), (720, 850)], PAPER_BACK, 15)

# Bóng thoại trước: "VI"
bubble(d, (700, 820, 1840, 1680), [(1320, 1640), (1640, 1900), (1520, 1560)], PAPER, 19)

def centered_text(draw, text, center, size, fill, stroke=0, stroke_fill=None, skew=0.0):
    font = ImageFont.truetype(BANGERS, size)
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    bbox = ld.textbbox((0, 0), text, font=font, stroke_width=stroke)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    ld.text((center[0] - w / 2 - bbox[0], center[1] - h / 2 - bbox[1]), text, font=font, fill=fill,
            stroke_width=stroke, stroke_fill=stroke_fill)
    if skew:
        layer = layer.transform((S, S), Image.AFFINE, (1, skew, -skew * center[1], 0, 1, 0), Image.BICUBIC)
    img.paste(layer, (0, 0), layer)

centered_text(d, "EN", (650, 600), 330, (95, 95, 95))
centered_text(d, "VI", (1270, 1255), 600, RED, stroke=26, stroke_fill=INK, skew=0.12)

# Tia sáng vàng nhỏ cạnh chữ (điểm nhấn kiểu manga)
def star(draw, c, r_out, r_in, points, fill):
    pts = []
    for i in range(points * 2):
        r = r_out if i % 2 == 0 else r_in
        a = math.pi * i / points - math.pi / 2
        pts.append((c[0] + math.cos(a) * r, c[1] + math.sin(a) * r))
    draw.polygon(pts, fill=fill)
star(d, (1780, 760), 150, 62, 8, INK)
star(d, (1780, 760), 118, 46, 8, YELLOW)

img = img.resize((1024, 1024), Image.LANCZOS)
img.save(OUT, "PNG")
print("saved", OUT, img.size, img.mode)
