#!/usr/bin/env python3
"""Generates the PairVox icon concepts as 1024x1024 SVGs (macOS icon grid: 824 px body, flat fills, no gradients)."""
import math, pathlib

OUT = pathlib.Path(__file__).parent
INK, PAPER, ORANGE, CHARTREUSE, CRIMSON, STONE = "#0E0E0E", "#F2EFE8", "#FF4F12", "#C6F000", "#D7263D", "#2A2926"

def squircle(cx=512, cy=512, half=412, n=5.0, steps=240):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + half * math.copysign(abs(c) ** (2 / n), c)
        y = cy + half * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{x:.1f},{y:.1f}")
    return "M" + " L".join(pts) + " Z"

BODY = squircle()

def svg(fill, art, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img">\n'
            f'<title>{title}</title>\n<path d="{BODY}" fill="{fill}"/>\n{art}\n</svg>\n')

def bar(x, cy, w, h, fill, r=8):
    return f'<rect x="{x:.1f}" y="{cy - h / 2:.1f}" width="{w}" height="{h:.1f}" rx="{r}" fill="{fill}"/>'

# 1. Pair: two columns of voice bars, one ink-on-paper, one orange, offset by half a step.
def pair():
    heights = [150, 300, 440, 270, 120]
    art = []
    w, gap = 52, 24
    x0 = 512 - (5 * w + 4 * gap) - 22
    for i, h in enumerate(heights):
        art.append(bar(x0 + i * (w + gap), 512 - 10, w, h, PAPER))
    x1 = 512 + 22
    for i, h in enumerate(reversed(heights)):
        art.append(bar(x1 + i * (w + gap), 512 + 10, w, h, ORANGE))
    return svg(INK, "\n".join(art), "PairVox 1: Pair")

# 2. Prompt: a terminal chevron and a waveform on orange.
def prompt():
    art = [f'<path d="M 214 330 L 430 512 L 214 694 L 214 596 L 322 512 L 214 428 Z" fill="{INK}"/>']
    for i, h in enumerate([150, 330, 220]):
        art.append(bar(494 + i * 100, 512, 60, h, INK, r=6))
    return svg(ORANGE, "\n".join(art), "PairVox 2: Prompt")

# 3. V: one letter made of two halves, a pair meeting at a point.
def vee():
    art = [f'<path d="M 206 230 L 404 230 L 506 584 L 506 806 Z" fill="{INK}"/>',
           f'<path d="M 818 230 L 620 230 L 518 584 L 518 806 Z" fill="{ORANGE}"/>']
    return svg(PAPER, "\n".join(art), "PairVox 3: V")

# 4. Brackets: a developer's brackets with a voice between them (code and speech, paired). Filled shapes, not strokes.
def brackets():
    art = [f'<path d="M 200 218 H 340 V 282 H 264 V 742 H 340 V 806 H 200 Z" fill="{PAPER}"/>',
           f'<path d="M 824 218 H 684 V 282 H 760 V 742 H 684 V 806 H 824 Z" fill="{ORANGE}"/>']
    for i, h in enumerate([170, 360, 170]):
        art.append(bar(404 + i * 80, 512, 56, h, PAPER, r=6))
    return svg(INK, "\n".join(art), "PairVox 4: Brackets")

# 5. Quote: a hard-edged speech block with the waveform cut out of it, on chartreuse.
def quote():
    art = [f'<path d="M 214 246 L 810 246 L 810 640 L 540 640 L 372 792 L 372 640 L 214 640 Z" fill="{INK}"/>']
    for i, h in enumerate([90, 190, 280, 190, 120, 230, 90]):
        art.append(bar(268 + i * 72, 443, 38, h, CHARTREUSE, r=4))
    return svg(CHARTREUSE, "\n".join(art), "PairVox 5: Quote")

# ---- Variations of 2 (Prompt) and 4 (Brackets) ----
CHEVRON = '<path d="M 214 330 L 430 512 L 214 694 L 214 596 L 322 512 L 214 428 Z" fill="{c}"/>'

# 2a. Prompt on ink: the orange chevron leads, the voice is paper.
def prompt_ink():
    art = [CHEVRON.format(c=ORANGE)]
    for i, h in enumerate([160, 340, 230]):
        art.append(bar(494 + i * 100, 512, 60, h, PAPER, r=6))
    return svg(INK, "\n".join(art), "PairVox 2a: Prompt on ink")

# 2b. Prompt with a block cursor: the cursor is the voice, one tall orange block on paper.
def prompt_cursor():
    art = [CHEVRON.format(c=INK),
           f'<rect x="520" y="296" width="150" height="432" fill="{ORANGE}"/>',
           f'<rect x="722" y="396" width="56" height="232" fill="{INK}"/>']
    return svg(PAPER, "\n".join(art), "PairVox 2b: Prompt cursor")

# 2c. Prompt ramp: a paper chevron and five bars that rise, like a level meter, on crimson.
def prompt_ramp():
    art = [CHEVRON.format(c=PAPER)]
    for i, h in enumerate([90, 160, 240, 330, 430]):
        art.append(bar(480 + i * 66, 512, 44, h, INK, r=4))
    return svg(CRIMSON, "\n".join(art), "PairVox 2c: Prompt ramp")

# 4a. Brackets on orange: the whole tile is the accent, ink brackets, paper voice.
def brackets_orange():
    art = [f'<path d="M 200 218 H 340 V 282 H 264 V 742 H 340 V 806 H 200 Z" fill="{INK}"/>',
           f'<path d="M 824 218 H 684 V 282 H 760 V 742 H 684 V 806 H 824 Z" fill="{INK}"/>']
    for i, h in enumerate([190, 400, 190]):
        art.append(bar(398 + i * 86, 512, 66, h, PAPER, r=6))
    return svg(ORANGE, "\n".join(art), "PairVox 4a: Brackets on orange")

# 4b. Angle brackets: a tag, < | >, one half ink and one half orange, on paper.
def brackets_angle():
    left = '<path d="M 372 250 L 176 512 L 372 774 L 372 662 L 284 512 L 372 362 Z" fill="{c}"/>'
    right = '<path d="M 652 250 L 848 512 L 652 774 L 652 662 L 740 512 L 652 362 Z" fill="{c}"/>'
    art = [left.format(c=INK), right.format(c=ORANGE), bar(468, 512, 88, 430, INK, r=6)]
    return svg(PAPER, "\n".join(art), "PairVox 4b: Angle brackets")

# 4c. Brackets on chartreuse: heavy ink brackets around a five-bar voice.
def brackets_chartreuse():
    art = [f'<path d="M 190 208 H 350 V 288 H 270 V 736 H 350 V 816 H 190 Z" fill="{INK}"/>',
           f'<path d="M 834 208 H 674 V 288 H 754 V 736 H 674 V 816 H 834 Z" fill="{INK}"/>']
    for i, h in enumerate([130, 290, 420, 290, 130]):
        art.append(bar(354 + i * 70, 512, 46, h, INK, r=5))
    return svg(CHARTREUSE, "\n".join(art), "PairVox 4c: Brackets on chartreuse")

for name, make in [("1-pair", pair), ("2-prompt", prompt), ("3-vee", vee), ("4-brackets", brackets), ("5-quote", quote),
                   ("2a-prompt-ink", prompt_ink), ("2b-prompt-cursor", prompt_cursor), ("2c-prompt-ramp", prompt_ramp),
                   ("4a-brackets-orange", brackets_orange), ("4b-brackets-angle", brackets_angle), ("4c-brackets-chartreuse", brackets_chartreuse)]:
    (OUT / f"pairvox-icon-{name}.svg").write_text(make())
    print("wrote", name)
