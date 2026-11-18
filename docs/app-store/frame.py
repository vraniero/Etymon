"""The App Store screenshots: each raw one in screenshots-6.9/ under a headline, into store-6.9/ (python3 frame.py; needs Pillow)."""
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "screenshots-6.9")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "store-6.9")
W, H = 1320, 2868

SHOTS = [
    ("2-photo.png", "Point at any sign", "See which of its words share a root, right over the picture."),
    ("3-type-story.png", "One word, 6,000 years old", "Notte, night and nocturnal all come from Proto-Indo-European *nókʷts."),
    ("4-talk.png", "Talk, and watch words connect", "Who said what, in which language, and where your words meet."),
    ("5-explore-3d.png", "Walk the family tree in 3D", "Every ancestor, back to Latin, Greek and the oldest roots."),
    ("6-map-journey.png", "Follow a word across the map", "From where it was born to the word you use today."),
    ("7-games.png", "Play with roots", "Five word games, on your own or with up to six friends."),
    ("1-home.png", "20 languages, on your iPhone", "No account, no ads, no tracking. Works offline."),
]


def serif(size):
    f = ImageFont.truetype("/System/Library/Fonts/NewYork.ttf", size)
    f.set_variation_by_axes([size, 640, 0])  # optical size, semibold-ish weight
    return f


def sans(size):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try:
        f.set_variation_by_name("Medium")
    except Exception:
        pass
    return f


def wrap(draw, text, f, width):
    """Fewest lines that fit, then as even as possible (no lone last word)."""
    words = text.split()

    def greedy(limit):
        lines, line = [], ""
        for word in words:
            trial = (line + " " + word).strip()
            if line and draw.textlength(trial, font=f) > limit:
                lines.append(line)
                line = word
            else:
                line = trial
        return lines + [line]

    best = greedy(width)
    lo, hi = 0, width
    while hi - lo > 4:
        mid = (lo + hi) / 2
        if len(greedy(mid)) <= len(best):
            hi = mid
        else:
            lo = mid
    return greedy(hi)


def background():
    top, bottom = (17, 36, 86), (4, 9, 28)
    grad = Image.linear_gradient("L").resize((W, H))
    bg = Image.composite(Image.new("RGB", (W, H), bottom), Image.new("RGB", (W, H), top), grad)
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    ImageDraw.Draw(glow).ellipse((W * 0.1, -300, W * 0.9, 700), fill=(110, 88, 30))
    return ImageChops.add(bg, glow.filter(ImageFilter.GaussianBlur(200)))


BG = background()
os.makedirs(OUT, exist_ok=True)
for n, (name, title, sub) in enumerate(SHOTS, 1):
    img = BG.copy()
    d = ImageDraw.Draw(img)
    tf, sf = serif(116), sans(52)
    y = 180
    for line in wrap(d, title, tf, W - 180):
        d.text((W / 2, y), line, font=tf, fill=(255, 255, 255), anchor="ma")
        y += 136
    y += 24
    for line in wrap(d, sub, sf, W - 240):
        d.text((W / 2, y), line, font=sf, fill=(226, 208, 158), anchor="ma")
        y += 68

    shot = Image.open(os.path.join(SRC, name)).convert("RGB")
    sw = 1110
    sh = int(shot.height * sw / shot.width)
    shot = shot.resize((sw, sh), Image.LANCZOS)
    top = y + 70
    shot = shot.crop((0, 0, sw, min(sh, H - top)))  # the phone runs off the bottom edge
    sh = shot.height
    x = (W - sw) // 2
    radius = 88
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw, sh + radius), radius=radius, fill=255)
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x, top + 24, x + sw, H + 200), radius=radius, fill=180)
    img.paste((0, 0, 0), (0, 0), shadow.filter(ImageFilter.GaussianBlur(44)))
    ImageDraw.Draw(img).rounded_rectangle((x - 7, top - 7, x + sw + 7, H + 200), radius=radius + 7,
                                          fill=(64, 76, 116))
    img.paste(shot, (x, top), mask)
    img.save(os.path.join(OUT, f"{n}-{name.split('-', 1)[1]}"), optimize=True)
    print(n, name, "screenshot from", top)
