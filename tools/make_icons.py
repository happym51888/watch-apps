"""
Generate the app icons for all six apps.

Constraints this is written around, rather than "draw something nice":

  * watchOS masks the icon to a circle, so nothing may rely on the corners and
    the glyph has to sit inside a centred circle with margin.
  * The icon is mostly seen at about 40 px on a wrist, in motion, outdoors.
    That rules out text, thin strokes, and detail. One bold shape, high
    contrast against the watch's black bezel.
  * Apple rejects alpha channels in the 1024 marketing icon, so the canvas is
    fully opaque.
  * Each glyph is drawn at 4x and downsampled, because PIL's drawing
    primitives are not anti-aliased and a hard-edged circle looks broken.

Each app's glyph is the one thing the app does, not a mascot:

  Kairos  a countdown ring — the TOTP window closing
  Tactus  a pendulum — the metronome
  Awqat   a crescent over the horizon — prayer times by the sun and moon
  Verba   a waveform — recorded speech
  Proxima an arrow leaving a platform — the next departure
  Volumen headphones — a book being listened to, not read

Run:  python tools/make_icons.py
"""

from __future__ import annotations

import json
import math
import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
SIZE = 1024
SS = 4  # supersampling factor
C = SIZE * SS // 2  # centre, in supersampled space

Colour = tuple[int, int, int]


def blend(a: Colour, b: Colour, t: float) -> Colour:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))  # type: ignore[return-value]


def backdrop(accent: Colour) -> Image.Image:
    """A dark vertical gradient tinted toward the accent.

    Dark rather than accent-coloured: on the watch the icon sits on black, and
    a bright fill makes the glyph fight the background instead of reading
    instantly.
    """
    top = blend((14, 16, 20), accent, 0.16)
    bottom = (8, 9, 12)
    image = Image.new("RGB", (1, SIZE))
    for y in range(SIZE):
        image.putpixel((0, y), blend(top, bottom, y / (SIZE - 1)))
    return image.resize((SIZE, SIZE), Image.BILINEAR)


def canvas() -> tuple[Image.Image, ImageDraw.ImageDraw]:
    layer = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
    return layer, ImageDraw.Draw(layer)


def flatten(base: Image.Image, layer: Image.Image) -> Image.Image:
    small = layer.resize((SIZE, SIZE), Image.LANCZOS)
    out = base.copy()
    out.paste(small, (0, 0), small)
    return out


def ring(draw, radius: int, width: int, colour, start: float, end: float) -> None:
    draw.arc(
        [C - radius, C - radius, C + radius, C + radius],
        start=start,
        end=end,
        fill=colour,
        width=width,
    )


# ---------------------------------------------------------------------------
# Kairos — a countdown ring with a gap, the TOTP window closing
# ---------------------------------------------------------------------------


def kairos(accent: Colour) -> Image.Image:
    base = backdrop(accent)
    layer, draw = canvas()

    radius = int(300 * SS)
    width = int(74 * SS)

    # The track, dim, and the remaining time, bright. Starting at -90° puts the
    # gap at the top where a clock's twelve would be.
    ring(draw, radius, width, blend(accent, (18, 20, 24), 0.72) + (255,), -90, 270)
    ring(draw, radius, width, accent + (255,), -90, 152)

    # The head of the arc, so the direction of travel is unambiguous.
    angle = math.radians(152)
    hx, hy = C + radius * math.cos(angle), C + radius * math.sin(angle)
    r = width // 2
    draw.ellipse([hx - r, hy - r, hx + r, hy + r], fill=(255, 255, 255, 255))

    # Three marks for the digits, without drawing digits — text at 40 px is mud.
    mark_w, mark_h, gap = int(46 * SS), int(120 * SS), int(38 * SS)
    total = mark_w * 3 + gap * 2
    x = C - total // 2
    for _ in range(3):
        draw.rounded_rectangle(
            [x, C - mark_h // 2, x + mark_w, C + mark_h // 2],
            radius=mark_w // 2,
            fill=(255, 255, 255, 255),
        )
        x += mark_w + gap

    return flatten(base, layer)


# ---------------------------------------------------------------------------
# Tactus — a pendulum mid-swing
# ---------------------------------------------------------------------------


def tactus(accent: Colour) -> Image.Image:
    base = backdrop(accent)
    layer, draw = canvas()

    # The pivot sits below centre but not at the edge, so that once the circular
    # mask is applied the whole pendulum still reads as one centred object.
    pivot_y = C + int(300 * SS)
    length = int(500 * SS)
    swing = 34  # degrees either side of vertical

    def arm(tilt_deg: float, colour, rod_w: int, weight_r: int) -> None:
        tilt = math.radians(-90 + tilt_deg)
        tip_x = C + length * math.cos(tilt)
        tip_y = pivot_y + length * math.sin(tilt)
        draw.line([C, pivot_y, tip_x, tip_y], fill=colour, width=rod_w)
        draw.ellipse(
            [tip_x - weight_r, tip_y - weight_r, tip_x + weight_r, tip_y + weight_r],
            fill=colour,
        )

    # A ghost at the opposite extreme of the swing. One rod leaning looks like a
    # mistake; two makes it unmistakably a pendulum in motion.
    ghost = blend(accent, (14, 16, 20), 0.66) + (255,)
    arm(-swing, ghost, int(34 * SS), int(70 * SS))

    # The swing path, bridging the two extremes.
    arc_r = length
    draw.arc(
        [C - arc_r, pivot_y - arc_r, C + arc_r, pivot_y + arc_r],
        start=-90 - swing,
        end=-90 + swing,
        fill=blend(accent, (14, 16, 20), 0.5) + (255,),
        width=int(24 * SS),
    )

    arm(swing, (255, 255, 255, 255), int(52 * SS), int(104 * SS))

    # The accent lands on the weight, the part that marks the beat.
    tilt = math.radians(-90 + swing)
    tip_x = C + length * math.cos(tilt)
    tip_y = pivot_y + length * math.sin(tilt)
    inner = int(64 * SS)
    draw.ellipse(
        [tip_x - inner, tip_y - inner, tip_x + inner, tip_y + inner],
        fill=accent + (255,),
    )

    hub = int(72 * SS)
    draw.ellipse([C - hub, pivot_y - hub, C + hub, pivot_y + hub], fill=(255, 255, 255, 255))

    return flatten(base, layer)


# ---------------------------------------------------------------------------
# Awqat — a crescent above the horizon
# ---------------------------------------------------------------------------


def awqat(accent: Colour) -> Image.Image:
    base = backdrop(accent)
    layer, draw = canvas()

    # A crescent as the difference of two circles, which keeps the horns sharp.
    # Drawn on its own layer so the subtraction does not punch a hole in the
    # backdrop.
    moon = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
    md = ImageDraw.Draw(moon)

    cy = C - int(60 * SS)
    outer = int(310 * SS)
    md.ellipse([C - outer, cy - outer, C + outer, cy + outer], fill=accent + (255,))

    inner = int(252 * SS)
    ox = C + int(118 * SS)
    oy = cy - int(52 * SS)
    md.ellipse([ox - inner, oy - inner, ox + inner, oy + inner], fill=(0, 0, 0, 0))

    layer.alpha_composite(moon)

    # The horizon: three bars, thinning outward, for the times through the day.
    y = C + int(330 * SS)
    for half_width, thickness, tone in (
        (int(300 * SS), int(40 * SS), 1.0),
        (int(210 * SS), int(30 * SS), 0.55),
        (int(120 * SS), int(24 * SS), 0.3),
    ):
        colour = blend((255, 255, 255), (18, 20, 24), 1 - tone) + (255,)
        draw.rounded_rectangle(
            [C - half_width, y, C + half_width, y + thickness],
            radius=thickness // 2,
            fill=colour,
        )
        y += thickness + int(34 * SS)

    return flatten(base, layer)


# ---------------------------------------------------------------------------
# Verba — a waveform
# ---------------------------------------------------------------------------


def verba(accent: Colour) -> Image.Image:
    base = backdrop(accent)
    layer, draw = canvas()

    # Heights chosen to look like speech rather than a symmetric equaliser:
    # loud in the middle, tapering, not a smooth curve.
    heights = [0.28, 0.62, 1.0, 0.74, 0.44, 0.86, 0.34]
    bar_w = int(74 * SS)
    gap = int(46 * SS)
    max_h = int(560 * SS)

    total = len(heights) * bar_w + (len(heights) - 1) * gap
    x = C - total // 2

    for index, factor in enumerate(heights):
        height = int(max_h * factor)
        # The peak bar is the accent, the rest white, so there is one focal
        # point instead of a picket fence.
        colour = accent + (255,) if factor == 1.0 else (255, 255, 255, 255)
        draw.rounded_rectangle(
            [x, C - height // 2, x + bar_w, C + height // 2],
            radius=bar_w // 2,
            fill=colour,
        )
        x += bar_w + gap

    return flatten(base, layer)


# ---------------------------------------------------------------------------
# Proxima — an arrow leaving a platform
# ---------------------------------------------------------------------------


def proxima(accent: Colour) -> Image.Image:
    base = backdrop(accent)
    layer, draw = canvas()

    # The platform: a fixed vertical bar on the left. Everything else moves
    # away from it, which is the whole idea of a departure.
    bar_w = int(84 * SS)
    bar_h = int(560 * SS)
    bar_x = C - int(330 * SS)
    draw.rounded_rectangle(
        [bar_x, C - bar_h // 2, bar_x + bar_w, C + bar_h // 2],
        radius=bar_w // 2,
        fill=(255, 255, 255, 255),
    )

    # Two motion dashes, shortening toward the platform, so the direction reads
    # without an animation.
    dash_h = int(58 * SS)
    for index, (length, tone) in enumerate(((int(150 * SS), 0.85), (int(96 * SS), 0.45))):
        y = C - int(150 * SS) + index * int(300 * SS)
        x = bar_x + bar_w + int(70 * SS)
        draw.rounded_rectangle(
            [x, y - dash_h // 2, x + length, y + dash_h // 2],
            radius=dash_h // 2,
            fill=blend((255, 255, 255), (16, 18, 22), 1 - tone) + (255,),
        )

    # The arrow. A single bold chevron plus shaft; at 40 px anything more
    # detailed than this is a smudge.
    shaft_h = int(96 * SS)
    shaft_x0 = bar_x + bar_w + int(70 * SS)
    shaft_x1 = C + int(190 * SS)
    draw.rounded_rectangle(
        [shaft_x0, C - shaft_h // 2, shaft_x1, C + shaft_h // 2],
        radius=shaft_h // 2,
        fill=accent + (255,),
    )
    head = int(196 * SS)
    tip_x = C + int(350 * SS)
    draw.polygon(
        [
            (tip_x, C),
            (tip_x - head, C - head),
            (tip_x - head, C + head),
        ],
        fill=accent + (255,),
    )

    return flatten(base, layer)


# ---------------------------------------------------------------------------
# Volumen — headphones
# ---------------------------------------------------------------------------


def volumen(accent: Colour) -> Image.Image:
    base = backdrop(accent)
    layer, draw = canvas()

    # The headband, drawn as a thick half-arc. Sitting slightly above centre
    # leaves room for the cups without the whole thing drifting off the
    # circular mask.
    cy = C + int(40 * SS)
    radius = int(300 * SS)
    band = int(78 * SS)
    draw.arc(
        [C - radius, cy - radius, C + radius, cy + radius],
        start=180,
        end=360,
        fill=(255, 255, 255, 255),
        width=band,
    )

    # The cups. Rounded rectangles rather than circles: circles read as a pair
    # of eyes at small sizes, rectangles read as headphones.
    cup_w = int(150 * SS)
    cup_h = int(300 * SS)
    top = cy - int(30 * SS)
    for side in (-1, 1):
        x = C + side * radius - cup_w // 2
        draw.rounded_rectangle(
            [x, top, x + cup_w, top + cup_h],
            radius=cup_w // 2,
            fill=accent + (255,),
        )

    return flatten(base, layer)


APPS = {
    "Kairos": ((62, 180, 236), kairos),
    "Tactus": ((252, 133, 76), tactus),
    "Awqat": ((102, 202, 139), awqat),
    "Verba": ((229, 59, 62), verba),
    "Proxima": ((250, 204, 21), proxima),
    "Volumen": ((167, 139, 250), volumen),
}


def main() -> None:
    for name, (accent, render) in APPS.items():
        icon = render(accent)
        assert icon.mode == "RGB", "the marketing icon must not carry an alpha channel"

        iconset = ROOT / "apps" / name / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
        iconset.mkdir(parents=True, exist_ok=True)

        filename = "icon-1024.png"
        icon.save(iconset / filename, "PNG", optimize=True)

        # A single 1024 source for both platforms; Xcode derives every other
        # size. Listing individual watch sizes has not been necessary since
        # Xcode 14 and just creates more files to keep in sync.
        contents = {
            "images": [
                {"idiom": "universal", "platform": "watchos", "size": "1024x1024", "filename": filename},
                {"idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": filename},
            ],
            "info": {"author": "xcode", "version": 1},
        }
        (iconset / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")

        # A 40 px copy alongside it, because that is roughly how big the icon
        # actually is on a wrist and it is the only size worth judging.
        preview = ROOT / "tools" / "icon-preview"
        preview.mkdir(parents=True, exist_ok=True)
        icon.resize((40, 40), Image.LANCZOS).save(preview / f"{name}-40.png", "PNG")
        icon.resize((256, 256), Image.LANCZOS).save(preview / f"{name}-256.png", "PNG")

        print(f"{name:8} {iconset.relative_to(ROOT)}/{filename}  ({icon.size[0]}x{icon.size[1]}, {icon.mode})")


if __name__ == "__main__":
    main()
