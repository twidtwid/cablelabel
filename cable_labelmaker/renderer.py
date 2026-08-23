"""Render fixed-size wraparound cable labels for 24 mm Brother tape."""

import math
import re
from functools import lru_cache
from pathlib import Path
from typing import Iterable, Sequence, Tuple

from PIL import Image, ImageDraw, ImageFont


DPI = 180
TAPE_HEIGHT_MM = 24
PRINT_HEIGHT_PX = 128
DEFAULT_LENGTH_MM = 48
TAPE_MARGIN_PX = 6
MAX_FONT_SIZE = 20
FONT_CANDIDATES = (
    Path("/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"),
    Path("/System/Library/Fonts/Avenir Next Condensed.ttc"),
    Path("/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf"),
)


def mm_to_px(mm: float) -> int:
    """Convert millimeters to printer dots at the PT-D600's 180 dpi."""
    return round(mm * DPI / 25.4)


@lru_cache(maxsize=1)
def _font_path() -> Path:
    for candidate in FONT_CANDIDATES:
        if candidate.exists():
            return candidate
    raise RuntimeError("No suitable condensed font is installed")


def _normalise_text(text: str) -> str:
    cleaned = " ".join(text.split())
    if not cleaned:
        raise ValueError("Label text cannot be blank")
    return cleaned.upper()


def _split_lines(text: str) -> Tuple[str, ...]:
    lines = tuple(part.strip() for part in re.split(r"\s*(?:<->|↔|->|→|\|)\s*", text) if part.strip())
    if len(lines) > 3:
        raise ValueError("Cable labels support at most three text lines")
    return lines or (text,)


def _text_bbox(draw: ImageDraw.ImageDraw, lines: Sequence[str], font: ImageFont.FreeTypeFont):
    return draw.multiline_textbbox((0, 0), "\n".join(lines), font=font, spacing=2, align="center")


@lru_cache(maxsize=32)
def _font(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(_font_path()), size=size)


def _fitted_font(lines: Sequence[str], max_width: int) -> ImageFont.FreeTypeFont:
    measure = ImageDraw.Draw(Image.new("L", (1, 1), 255))
    for size in range(MAX_FONT_SIZE, 7, -1):
        font = _font(size)
        bbox = _text_bbox(measure, lines, font)
        if bbox[2] - bbox[0] <= max_width:
            return font
    raise ValueError("Label text is too long for 24 mm tape. Split it with ->")


def _rotated_repeat(text: str) -> Image.Image:
    lines = _split_lines(text)
    available = PRINT_HEIGHT_PX - TAPE_MARGIN_PX * 2
    font = _fitted_font(lines, available)

    measure = ImageDraw.Draw(Image.new("L", (1, 1), 255))
    bbox = _text_bbox(measure, lines, font)
    text_width = math.ceil(bbox[2] - bbox[0])
    text_height = math.ceil(bbox[3] - bbox[1])
    block = Image.new("L", (text_width + 6, text_height + 6), 255)
    draw = ImageDraw.Draw(block)
    draw.multiline_text(
        (block.width // 2, block.height // 2),
        "\n".join(lines),
        font=font,
        fill=0,
        spacing=2,
        align="center",
        anchor="mm",
    )
    return block.rotate(-90, expand=True, fillcolor=255)


def render_wrap_label(text: str, length_mm: float = DEFAULT_LENGTH_MM) -> Image.Image:
    """Render one cable label with repeated text around its circumference."""
    normalised = _normalise_text(text)
    width = mm_to_px(length_mm)
    if width < 120:
        raise ValueError("Label length must be at least 17 mm")

    repeat = _rotated_repeat(normalised)
    gap = 15
    repeat_count = max(3, (width + gap) // (repeat.width + gap))
    while repeat_count * repeat.width + (repeat_count - 1) * gap > width - 8 and gap > 4:
        gap -= 1
    while repeat_count * repeat.width + (repeat_count - 1) * gap > width - 8 and repeat_count > 3:
        repeat_count -= 1

    content_width = repeat_count * repeat.width + (repeat_count - 1) * gap
    start_x = max(4, (width - content_width) // 2)
    start_y = (PRINT_HEIGHT_PX - repeat.height) // 2

    label = Image.new("L", (width, PRINT_HEIGHT_PX), 255)
    for index in range(repeat_count):
        label.paste(repeat, (start_x + index * (repeat.width + gap), start_y))

    return label.point(lambda value: 255 if value >= 160 else 0, mode="1")


def render_tape_preview(text: str, length_mm: float = DEFAULT_LENGTH_MM) -> Image.Image:
    """Render the printer bitmap inside the full 24 mm tape area."""
    printer_bitmap = render_wrap_label(text, length_mm)
    tape = Image.new("1", (printer_bitmap.width, mm_to_px(TAPE_HEIGHT_MM)), 1)
    margin = (tape.height - printer_bitmap.height) // 2
    tape.paste(printer_bitmap, (0, margin))
    return tape


def render_many(labels: Iterable[str], output_dir: Path, length_mm: float = DEFAULT_LENGTH_MM):
    """Render labels into numbered PNG files and return their paths."""
    output_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for index, label in enumerate(labels, start=1):
        path = output_dir / f"cable-label-{index:03d}.png"
        render_wrap_label(label, length_mm).save(path)
        paths.append(path)
    return paths
