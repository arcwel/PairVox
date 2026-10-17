#!/usr/bin/env python3
"""Contact sheet: the current icon and the concepts at 340, 128, 64, 32 and 16 px, on light and dark."""
import subprocess, pathlib
d = pathlib.Path(__file__).parent
import sys
variations = len(sys.argv) > 1 and sys.argv[1] == 'variations'
names = (['2-prompt', '2a-prompt-ink', '2b-prompt-cursor', '2c-prompt-ramp', '4-brackets', '4a-brackets-orange', '4b-brackets-angle', '4c-brackets-chartreuse']
         if variations else ['1-pair', '2-prompt', '3-vee', '4-brackets', '5-quote'])
items = ([] if variations else [(d / '../icon.png', 'current')]) + [(d / f'render/pairvox-icon-{n}.png', n) for n in names]
cmd = ['magick', '-size', ('3100x1060' if variations else '2340x1060'), 'canvas:#DCDAD4']
x = 40
for src, label in items:
    s = str(src)
    cmd += ['(', s, '-resize', '340x340', ')', '-geometry', f'+{x}+60', '-composite']
    cmd += ['(', s, '-resize', '128x128', ')', '-geometry', f'+{x}+470', '-composite']
    cmd += ['(', s, '-resize', '64x64', ')', '-geometry', f'+{x+150}+534', '-composite']
    cmd += ['(', s, '-resize', '32x32', ')', '-geometry', f'+{x+240}+566', '-composite']
    cmd += ['(', s, '-resize', '16x16', ')', '-geometry', f'+{x+292}+582', '-composite']
    cmd += ['(', '-size', '340x150', 'canvas:#1C1B19', ')', '-geometry', f'+{x}+700', '-composite']
    cmd += ['(', s, '-resize', '110x110', ')', '-geometry', f'+{x+20}+720', '-composite']
    cmd += ['(', s, '-resize', '48x48', ')', '-geometry', f'+{x+170}+751', '-composite']
    cmd += ['(', s, '-resize', '24x24', ')', '-geometry', f'+{x+250}+763', '-composite']
    cmd += ['-font', 'Helvetica-Bold', '-pointsize', '26', '-fill', '#111', '-annotate', f'+{x}+940', label]
    x += 380
subprocess.run(cmd + [str(d / ('contact-sheet-variations.png' if variations else 'contact-sheet.png'))], check=True)
