#!/usr/bin/env python3
"""128x128 RGBA silhouette thumbnails for the catalog proxies, plus the opaque 1024x1024 app icon
required by the iOS exporter (pure-Python PNG writer).

Usage: python3 scripts/generate_thumbnails.py [--out DIR]
"""
from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path
from typing import Callable

SIZE = 128
OUT_DIR = Path(__file__).resolve().parent.parent / "app" / "assets" / "thumbnails"

Pixel = tuple[int, int, int, int]
Canvas = list[list[Pixel]]


def png_bytes(canvas: Canvas) -> bytes:
	h = len(canvas)
	w = len(canvas[0])

	def chunk(tag: bytes, data: bytes) -> bytes:
		return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

	raw = b"".join(b"\x00" + b"".join(bytes(px) for px in row) for row in canvas)
	ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)  # 8-bit RGBA, no interlace
	return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def blank(size: int = SIZE, color: Pixel = (0, 0, 0, 0)) -> Canvas:
	return [[color] * size for _ in range(size)]


def fill(canvas: Canvas, color: Pixel, inside: Callable[[float, float], bool]) -> None:
	"""Shapes are defined in 128-unit space and scaled to the canvas size."""
	size = len(canvas)
	k = SIZE / size
	for y in range(size):
		row = canvas[y]
		for x in range(size):
			if inside((x + 0.5) * k, (y + 0.5) * k):
				row[x] = color


def rect(x0: float, y0: float, x1: float, y1: float) -> Callable[[float, float], bool]:
	return lambda x, y: x0 <= x < x1 and y0 <= y < y1


def triangle(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float]) -> Callable[[float, float], bool]:
	def edge(p: tuple[float, float], q: tuple[float, float], x: float, y: float) -> float:
		return (q[0] - p[0]) * (y - p[1]) - (q[1] - p[1]) * (x - p[0])

	def inside(x: float, y: float) -> bool:
		d = (edge(a, b, x, y), edge(b, c, x, y), edge(c, a, x, y))
		return all(v >= 0 for v in d) or all(v <= 0 for v in d)
	return inside


def ellipse(cx: float, cy: float, rx: float, ry: float) -> Callable[[float, float], bool]:
	return lambda x, y: ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0


def cabin() -> Canvas:
	c = blank()
	fill(c, (107, 107, 100, 255), rect(18, 100, 110, 110))  # stone foundation
	fill(c, (140, 97, 56, 255), rect(22, 62, 106, 100))  # timber walls
	fill(c, (77, 31, 26, 255), triangle((12, 64), (116, 64), (64, 20)))  # roof
	fill(c, (46, 28, 15, 255), rect(56, 76, 72, 100))  # door
	return c


def boulder() -> Canvas:
	c = blank()
	fill(c, (110, 110, 106, 255), ellipse(64, 76, 50, 36))
	fill(c, (140, 140, 134, 255), ellipse(52, 64, 22, 14))  # highlight
	return c


def spruce(c: Canvas | None = None) -> Canvas:
	c = c or blank()
	fill(c, (110, 72, 40, 255), rect(58, 100, 70, 122))  # trunk
	fill(c, (34, 92, 48, 255), triangle((24, 104), (104, 104), (64, 6)))  # crown
	return c


def grass_tuft() -> Canvas:
	c = blank()
	for i, (x, lean, shade) in enumerate([(40, -22, 0), (52, -10, 1), (64, 2, 0), (76, 12, 1), (88, 24, 0)]):
		col = (86, 158, 56, 255) if shade == 0 else (118, 184, 72, 255)
		fill(c, col, triangle((x - 7, 112), (x + 7, 112), (x + lean, 34 + 8 * (i % 2) + 16 * (i in (0, 4)))))
	return c


def fern() -> Canvas:
	c = blank()
	green = (38, 102, 41, 255)
	for tip_x, tip_y in [(14, 54), (36, 24), (64, 12), (92, 24), (114, 54)]:
		fill(c, green, triangle((54, 112), (74, 112), (tip_x, tip_y)))
	fill(c, (28, 78, 32, 255), ellipse(64, 108, 14, 8))
	return c


def wildflowers() -> Canvas:
	c = blank()
	stem = (92, 158, 61, 255)
	for x, top, col in [(36, 40, (250, 214, 46, 255)), (62, 26, (242, 133, 184, 255)), (90, 44, (248, 248, 240, 255))]:
		fill(c, stem, triangle((x - 4, 114), (x + 4, 114), (x, top)))
		fill(c, col, ellipse(x, top, 12, 12))
		fill(c, (214, 150, 40, 255), ellipse(x, top, 4, 4))
	fill(c, stem, triangle((20, 114), (110, 114), (64, 86)))
	return c


def pebbles() -> Canvas:
	c = blank()
	fill(c, (148, 146, 138, 255), ellipse(48, 86, 34, 22))
	fill(c, (117, 115, 110, 255), ellipse(90, 94, 26, 16))
	fill(c, (168, 164, 153, 255), ellipse(66, 66, 18, 11))
	return c


def app_icon() -> Canvas:
	return spruce(blank(1024, (196, 222, 186, 255)))  # opaque: App Store icons may not have alpha


THUMBNAILS = {"cabin_a.png": cabin, "boulder_a.png": boulder, "spruce_a.png": spruce, "grass_tuft_a.png": grass_tuft,
	"fern_a.png": fern, "wildflowers_a.png": wildflowers, "pebbles_a.png": pebbles, "app_icon.png": app_icon}


def main(argv: list[str] | None = None) -> int:
	p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	p.add_argument("--out", type=Path, default=OUT_DIR)
	a = p.parse_args(argv)
	a.out.mkdir(parents=True, exist_ok=True)
	for name, draw in THUMBNAILS.items():
		(a.out / name).write_bytes(png_bytes(draw()))
		print("wrote %s" % (a.out / name))
	return 0


if __name__ == "__main__":
	sys.exit(main())
