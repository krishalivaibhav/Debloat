# Storyboard frames from the real screenshots: one crop per shot on its field colour, headline on top
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
A = "assets/"
F = "/System/Library/Fonts/SFNS.ttf"
def font(n): return ImageFont.truetype(F, n)
W, H = 1600, 900
def base(col): return Image.new("RGB", (W, H), col)
def crop(name, box, width, redact=True):
    im = Image.open(A + name).convert("RGB")
    if name.startswith("claude") and redact:  # personal path in a command row
        ImageDraw.Draw(im).rectangle((490, 740, 1720, 805), fill=(30, 30, 30))
    c = im.crop(box); r = width / c.width
    return c.resize((int(c.width * r), int(c.height * r)), Image.LANCZOS)
def card(img, panel, xy, radius=28, shadow=True):
    m = Image.new("L", panel.size, 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, *panel.size), radius, fill=255)
    if shadow:
        s = Image.new("RGBA", (panel.width + 160, panel.height + 160), (0, 0, 0, 0))
        ImageDraw.Draw(s).rounded_rectangle((80, 100, 80 + panel.width, 100 + panel.height), radius, fill=(0, 0, 0, 120))
        s = s.filter(ImageFilter.GaussianBlur(30)); img.paste(s, (xy[0] - 80, xy[1] - 80), s)
    img.paste(panel, xy, m)
def head(img, text, y=70, col="white"):
    d = ImageDraw.Draw(img); f = font(64); w = d.textlength(text, font=f); d.text(((W - w) / 2, y), text, font=f, fill=col)
def center(img, panel, y):
    card(img, panel, ((W - panel.width) // 2, y))

f = base((29, 79, 168)); icon = Image.open(A + "icon.png").convert("RGBA").resize((300, 300))
f.paste(icon, (650, 330), icon); head(f, "Your Mac runs more than you think.", 120); f.save("frames/1.jpg")

f = base((13, 42, 99)); center(f, crop("memory-apps-dark.png", (0, 0, 1960, 1240), 1200), 210); head(f, "Meet Debloat.", 80); f.save("frames/2.jpg")

f = base((13, 42, 99)); center(f, crop("memory-apps-dark.png", (470, 1530, 1910, 1940), 1300), 360)
center(f, crop("memory-apps-dark.png", (470, 280, 1910, 520), 1000), 150); f.save("frames/3.jpg")

f = base((150, 70, 40)); center(f, crop("claude-dark.png", (470, 480, 1910, 920), 1300), 250); head(f, "Every Claude session.", 90); f.save("frames/4.jpg")

f = base((16, 110, 95)); center(f, crop("storage-dark.png", (470, 300, 1910, 620), 1300), 180)
center(f, crop("storage-dark.png", (470, 1180, 1910, 1320), 1300), 560); head(f, "Move it. It still opens.", 60); f.save("frames/5.jpg")

f = base((82, 67, 184)); center(f, crop("startup-dark.png", (470, 610, 1910, 1310), 1100), 170); f.save("frames/6.jpg")

f = base((60, 66, 84))
for i, (x, y) in enumerate([(120, 200), (560, 120), (1000, 200), (120, 520), (560, 440), (1000, 520)]):
    card(f, crop("apple-dark.png", (470, 880 + i * 147, 1910, 1027 + i * 147), 480), (x, y), 18)
f.save("frames/7.jpg")

f = base((29, 79, 168)); f.paste(icon.resize((220, 220)), (690, 220), icon.resize((220, 220)))
d = ImageDraw.Draw(f); t = "Debloat"; ff = font(120); d.text(((W - d.textlength(t, font=ff)) / 2, 470), t, font=ff, fill="white")
d.rounded_rectangle((430, 680, 1170, 770), 45, fill="white"); u = "github.com/krishalivaibhav/Debloat|"; fu = font(40)
d.text(((W - d.textlength(u, font=fu)) / 2, 700), u, font=fu, fill=(13, 42, 99)); f.save("frames/8.jpg")
