"""Build the selected Open Span artwork and a review sheet.

Run with Python 3, Pillow and ImageMagick 7. No generated concept images are
used as export sources. Application asset catalogues are not modified.
"""

from pathlib import Path
import subprocess
from xml.sax.saxutils import escape

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parent
ORANGE = "#E77F47"
IVORY = "#F6F2EB"
CHARCOAL = "#202B2D"

# Shared arch and open crossbar. The deck terminates at x=570; the inner
# right leg is beyond x=628 at deck height, leaving a substantial passage.
ARCH = (
    "M184 758 C219 654 264 486 360 348 "
    "C410 280 459 246 512 246 C565 246 614 280 664 348 "
    "C760 486 805 654 840 758 Q846 780 822 780 H712 "
    "Q696 780 690 763 C662 672 630 561 577 445 "
    "C556 400 534 374 512 374 C490 374 468 400 447 445 "
    "C394 561 362 672 334 763 Q328 780 312 780 H202 "
    "Q178 780 184 758 Z"
)
DECK = "M350 560 H532 Q570 560 570 602 Q570 644 532 644 H350 Z"
FOUNDATION = (
    "M180 724 H844 Q872 724 872 752 Q872 780 844 780 "
    "H180 Q152 780 152 752 Q152 724 180 724 Z"
)
SHAPES = {"avenkin": ARCH + " " + DECK,
          "avenkin-office": ARCH + " " + DECK + " " + FOUNDATION}
APPEARANCES = {
    "avenkin": {"light": (ORANGE, IVORY), "dark": (ORANGE, CHARCOAL),
                "monochrome": ("#FFFFFF", "#000000")},
    "avenkin-office": {"light": (CHARCOAL, IVORY), "dark": (IVORY, CHARCOAL),
                       "monochrome": ("#FFFFFF", "#000000")},
}


def svg(name, colour, background=None):
    title = "Avenkin Office" if name.endswith("office") else "Avenkin"
    backdrop = (f'<rect width="1024" height="1024" fill="{background}"/>'
                if background else "")
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024" role="img">\n'
        f'  <title>{escape(title)} — Open Span</title>\n'
        f'  {backdrop}\n'
        f'  <path fill="{colour}" fill-rule="nonzero" d="{SHAPES[name]}"/>\n'
        '</svg>\n'
    )


def render(source, target, size=1024, opaque=False):
    command = ["magick", "-background", "none", str(source),
               "-resize", f"{size}x{size}"]
    if opaque:
        command.extend(["-alpha", "off"])
    command.append(f"{'PNG24' if opaque else 'PNG32'}:{target}")
    subprocess.run(command, check=True)


def font(size, bold=False):
    filename = "Arial Bold.ttf" if bold else "Arial.ttf"
    return ImageFont.truetype(f"/System/Library/Fonts/Supplemental/{filename}", size)


def masked_icon(source, size):
    image = Image.open(source).convert("RGBA").resize((size, size), Image.Resampling.LANCZOS)
    mask = Image.new("L", (size, size))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1),
                                          radius=round(size * .22), fill=255)
    image.putalpha(mask)
    return image


def build_review():
    # No resizing of the review sheet itself: the lower samples are displayed
    # at their labelled pixel sizes in this saved PNG.
    sheet = Image.new("RGB", (1280, 1050), "#EFEAE2")
    draw = ImageDraw.Draw(sheet)
    draw.text((64, 40), "avenkin", fill=CHARCOAL, font=font(54, True))
    draw.text((66, 106), "Open Span / vector artwork", fill=CHARCOAL, font=font(22))
    columns = [("avenkin", 380, "Avenkin"), ("avenkin-office", 870, "Avenkin Office")]
    for name, x, title in columns:
        draw.text((x, 164), title, fill=CHARCOAL, font=font(27, True), anchor="mt")
        for appearance, y in [("light", 220), ("dark", 505)]:
            tile = masked_icon(ROOT / "exports" / f"{name}-{appearance}-1024.png", 240)
            sheet.paste(tile, (x - 120, y), tile)
    draw.text((64, 325), "Light", fill=CHARCOAL, font=font(22))
    draw.text((64, 610), "Dark", fill=CHARCOAL, font=font(22))
    draw.line((64, 790, 1216, 790), fill="#D8D1C6", width=1)
    draw.text((64, 816), "Actual pixel sizes", fill=CHARCOAL, font=font(22, True))
    draw.text((64, 851), "Monochrome", fill=CHARCOAL, font=font(19))
    for name, x, _ in columns:
        for size, offset in zip((16, 24, 32, 48, 64), (-176, -96, -16, 64, 154)):
            tile = masked_icon(ROOT / "exports" / f"{name}-monochrome-1024.png", size)
            cx = x + offset
            sheet.paste(tile, (cx - size // 2, 891 - size), tile)
            draw.text((cx, 910), str(size), fill=CHARCOAL, font=font(18), anchor="mt")
    draw.text((64, 998), "Shared arch. Open crossbar. Office foundation.",
              fill=CHARCOAL, font=font(20))
    sheet.save(ROOT / "04-open-span-vector-review.png")


def main():
    (ROOT / "masters").mkdir(parents=True, exist_ok=True)
    (ROOT / "exports").mkdir(exist_ok=True)
    for name in SHAPES:
        source = ROOT / "masters" / f"{name}-mark.svg"
        source.write_text(svg(name, ORANGE if name == "avenkin" else CHARCOAL))
        render(source, ROOT / "exports" / f"{name}-mark-1024.png")
        for appearance, (colour, background) in APPEARANCES[name].items():
            source = ROOT / "masters" / f"{name}-{appearance}.svg"
            source.write_text(svg(name, colour, background))
            render(source, ROOT / "exports" / f"{name}-{appearance}-1024.png", opaque=True)
    build_review()
    print("Created 8 SVG masters, 8 PNG exports and the pixel-size review sheet.")


if __name__ == "__main__":
    main()
