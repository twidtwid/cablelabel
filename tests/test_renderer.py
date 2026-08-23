import unittest

from cable_labelmaker.renderer import (
    DEFAULT_LENGTH_MM,
    PRINT_HEIGHT_PX,
    _fitted_font,
    _split_lines,
    mm_to_px,
    render_wrap_label,
)


class WrapLabelRendererTests(unittest.TestCase):
    def test_default_label_has_physical_dimensions(self):
        image = render_wrap_label("MAC MINI")

        self.assertEqual((mm_to_px(DEFAULT_LENGTH_MM), PRINT_HEIGHT_PX), image.size)

    def test_label_contains_several_repeated_readable_zones(self):
        image = render_wrap_label("SWITCH 08")
        pixels = image.convert("L")
        occupied_columns = [
            any(pixels.getpixel((x, y)) < 128 for y in range(pixels.height))
            for x in range(pixels.width)
        ]
        runs = 0
        in_run = False
        for occupied in occupied_columns:
            if occupied and not in_run:
                runs += 1
            in_run = occupied

        self.assertGreaterEqual(runs, 3)

    def test_endpoint_separator_creates_two_lines(self):
        self.assertEqual(("MAC MINI", "SWITCH 08"), _split_lines("MAC MINI -> SWITCH 08"))

    def test_repeated_separators_create_three_lines(self):
        self.assertEqual(
            ("ROUTER P3", "FLEX P9", "2.5G UPLINK"),
            _split_lines("ROUTER P3 | FLEX P9 | 2.5G UPLINK"),
        )

    def test_more_than_three_lines_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "at most three"):
            render_wrap_label("ONE | TWO | THREE | FOUR")

    def test_long_text_stays_inside_printable_area(self):
        image = render_wrap_label("STUDIO MAC MINI -> NETWORK SWITCH 08")
        inverted = image.convert("L").point(lambda value: 255 - value)
        bbox = inverted.getbbox()

        self.assertIsNotNone(bbox)
        self.assertGreaterEqual(bbox[1], 4)
        self.assertLessEqual(bbox[3], PRINT_HEIGHT_PX - 4)

    def test_three_line_router_label_stays_inside_printable_area(self):
        image = render_wrap_label("ROUTER P3 | FLEX P9 | 2.5G UPLINK")
        inverted = image.convert("L").point(lambda value: 255 - value)
        bbox = inverted.getbbox()

        self.assertIsNotNone(bbox)
        self.assertGreaterEqual(bbox[1], 4)
        self.assertLessEqual(bbox[3], PRINT_HEIGHT_PX - 4)

    def test_all_label_layouts_use_compact_type(self):
        self.assertEqual(20, _fitted_font(("A",), 116).size)
        self.assertEqual(20, _fitted_font(("A", "B"), 116).size)
        self.assertEqual(20, _fitted_font(("RACK", "FLEX", "UPLINK"), 116).size)

    def test_blank_label_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "cannot be blank"):
            render_wrap_label("   ")

    def test_unreadably_long_label_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "too long"):
            render_wrap_label("X" * 200)


if __name__ == "__main__":
    unittest.main()
