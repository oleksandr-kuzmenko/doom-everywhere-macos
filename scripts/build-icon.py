#!/usr/bin/env python3
"""Draw a gray pixel-art wordmark and package it as a macOS app icon."""
import pathlib
import struct
import subprocess
import zlib

root = pathlib.Path(__file__).resolve().parent.parent
size = 96
# Hand-drawn angular glyphs on a small grid, deliberately not a system font.
glyphs = [
    ([(0,0),(15,0),(20,5),(20,34),(0,47)], [(7,8),(12,8),(13,10),(13,29),(7,33)]),
    ([(0,4),(4,0),(16,0),(20,4),(20,36),(10,43),(0,36)], [(7,8),(13,8),(13,29),(10,31),(7,29)]),
    ([(0,4),(4,0),(16,0),(20,4),(20,36),(10,43),(0,36)], [(7,8),(13,8),(13,29),(10,31),(7,29)]),
    ([(0,0),(5,0),(10,9),(15,0),(20,0),(20,47),(13,42),(13,19),(10,24),(7,19),(7,39),(0,35)], []),
]


def inside(x, y, polygon):
    hit = False
    for i, (ax, ay) in enumerate(polygon):
        bx, by = polygon[i - 1]
        if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax:
            hit = not hit
    return hit


mask = set()
for index, (outer, hole) in enumerate(glyphs):
    for y in range(48):
        for x in range(21):
            if inside(x + 0.5, y + 0.5, outer) and not inside(x + 0.5, y + 0.5, hole):
                mask.add((3 + index * 23 + x, 23 + y))
pixels = [(0, 0, 0, 0)] * (size * size)


def put(x, y, shade):
    if 0 <= x < size and 0 <= y < size:
        pixels[y * size + x] = (shade, shade, shade, 255)


# Short stepped extrusion and a one-pixel charcoal outline, with no background tile.
body = set(mask)
for depth in range(1, 5):
    body.update((x + 1, y + depth) for x, y in mask)
for x, y in body:
    for dx, dy in [(-1,0),(1,0),(0,-1),(0,1)]:
        put(x + dx, y + dy, 34)
for x, y in body:
    put(x, y, 66 if (x + y) % 3 else 78)
for x, y in mask:
    # Broad gray bands with ordered dithering, plus hard pixel bevels.
    level = min(3, max(0, (y - 23) // 12))
    shade = [112, 136, 158, 182][level]
    if (x + y) % 4 == 0:
        shade += 12
    if (x, y - 1) not in mask or (x - 1, y) not in mask:
        shade = 226
    elif (x, y - 2) not in mask or (x - 2, y) not in mask:
        shade = 182
    elif (x, y + 1) not in mask or (x + 1, y) not in mask:
        shade = 74
    put(x, y, shade)


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def png(target):
    rows = bytearray()
    for y in range(target):
        rows.append(0)
        for x in range(target):
            rows.extend(pixels[min(size-1, y*size//target)*size + min(size-1, x*size//target)])
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', target, target, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


iconset = root / 'build/AppIcon.iconset'
iconset.mkdir(parents=True, exist_ok=True)
(root / 'build/AppIcon.png').write_bytes(png(384))
for logical in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        (iconset / f'icon_{logical}x{logical}{suffix}.png').write_bytes(png(logical * scale))
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(root / 'build/AppIcon.icns')], check=True)
print('Generated gray pixel-art DOOM icon with transparent background.')
