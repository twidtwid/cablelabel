import json
import threading
import unittest
import urllib.error
import urllib.request
from io import BytesIO

from PIL import Image

from cable_labelmaker.printer import PrinterError
from cable_labelmaker.renderer import mm_to_px, render_wrap_label
from cable_labelmaker.server import (
    _open_browser_from_environment,
    _runtime_config_from_environment,
    create_server,
    friendly_printer_error,
)


class FakePrinter:
    def __init__(self, fail_on_print=None, info_error=None):
        self.printed = []
        self.fail_on_print = fail_on_print
        self.info_error = info_error

    def info(self):
        if self.info_error:
            raise PrinterError(self.info_error)
        return "PT-D600, 24 mm"

    def print_image(self, path):
        if len(self.printed) + 1 == self.fail_on_print:
            raise PrinterError("Device not found")
        self.printed.append(path.read_bytes())


class LabelmakerServerTests(unittest.TestCase):
    def setUp(self):
        self.printer = FakePrinter()
        self.tailnet_origin = "https://cablelabel.example.com:9462"
        self.server = create_server(
            ("127.0.0.1", 0),
            self.printer,
            trusted_origins=(self.tailnet_origin,),
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def post(self, path, payload):
        request = urllib.request.Request(
            self.base_url + path,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        return urllib.request.urlopen(request, timeout=2)

    def rejected_post(self, headers, body=b"{}"):
        request = urllib.request.Request(
            self.base_url + "/api/print",
            data=body,
            headers=headers,
        )
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request, timeout=2)
        return error.exception

    def test_home_page_is_served(self):
        with urllib.request.urlopen(self.base_url, timeout=2) as response:
            body = response.read().decode()

        self.assertIn("Cable Labelmaker", body)
        self.assertIn("Print All", body)
        self.assertNotIn("image-rendering: pixelated", body)

    def test_preview_models_the_full_tape_around_the_printer_bitmap(self):
        with self.post("/api/preview", {"label": "MAC MINI -> SWITCH 08", "length": 48}) as response:
            image = Image.open(BytesIO(response.read())).convert("1")

        self.assertEqual("image/png", response.headers.get_content_type())
        self.assertEqual((mm_to_px(48), mm_to_px(24)), image.size)

        printer_bitmap = render_wrap_label("MAC MINI -> SWITCH 08")
        margin = (image.height - printer_bitmap.height) // 2
        printed_area = image.crop((0, margin, image.width, margin + printer_bitmap.height))

        self.assertEqual(printer_bitmap.tobytes(), printed_area.tobytes())
        self.assertEqual((255, 255), image.crop((0, 0, image.width, margin)).getextrema())
        self.assertEqual(
            (255, 255),
            image.crop((0, margin + printer_bitmap.height, image.width, image.height)).getextrema(),
        )

    def test_print_all_sends_every_label_to_printer(self):
        labels = ["MAC MINI -> SWITCH 08", "NAS -> SWITCH 09"]
        with self.post(
            "/api/print",
            {"labels": labels, "length": 48},
        ) as response:
            payload = json.load(response)

        self.assertEqual(2, payload["printed"])
        expected = []
        for label in labels:
            buffer = BytesIO()
            render_wrap_label(label).save(buffer, format="PNG")
            expected.append(buffer.getvalue())
        self.assertEqual(expected, self.printer.printed)

    def test_partial_print_failure_reports_completed_labels(self):
        self.server.printer = FakePrinter(fail_on_print=2)

        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post("/api/print", {"labels": ["ONE", "TWO", "THREE"], "length": 48})

        payload = json.load(error.exception)
        self.assertEqual(503, error.exception.code)
        self.assertEqual(1, payload["printed"])
        self.assertEqual(3, payload["total"])
        self.assertEqual(1, payload["failed_index"])
        self.assertEqual("TWO", payload["failed_label"])

    def test_status_returns_friendly_printer_error(self):
        self.server.printer = FakePrinter(info_error="Device not found")

        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(self.base_url + "/api/status", timeout=2)

        payload = json.load(error.exception)
        self.assertEqual(503, error.exception.code)
        self.assertFalse(payload["connected"])
        self.assertIn("P-touch Editor", payload["detail"])

    def test_invalid_host_is_rejected(self):
        error = self.rejected_post(
            {"Content-Type": "application/json", "Host": "attacker.example"}
        )

        self.assertEqual(403, error.code)
        self.assertEqual("Invalid request host", json.load(error)["error"])
        self.assertEqual([], self.printer.printed)

    def test_cross_origin_print_request_is_rejected(self):
        error = self.rejected_post(
            {
                "Content-Type": "application/json",
                "Origin": "https://example.com",
            }
        )

        self.assertEqual(403, error.code)
        self.assertEqual("Cross-origin requests are not allowed", json.load(error)["error"])
        self.assertEqual([], self.printer.printed)

    def test_non_json_content_type_is_rejected(self):
        error = self.rejected_post(
            {"Content-Type": "text/plain", "Origin": self.tailnet_origin}
        )

        self.assertEqual(403, error.code)
        self.assertEqual("Content-Type must be application/json", json.load(error)["error"])
        self.assertEqual([], self.printer.printed)

    def test_malformed_json_is_rejected(self):
        error = self.rejected_post(
            {"Content-Type": "application/json"}, body=b'{"labels":'
        )

        self.assertEqual(400, error.code)
        self.assertEqual([], self.printer.printed)

    def test_trusted_tailnet_origin_can_preview(self):
        request = urllib.request.Request(
            self.base_url + "/api/preview",
            data=json.dumps({"label": "REMOTE TEST", "length": 48}).encode(),
            headers={
                "Content-Type": "application/json",
                "Host": "cablelabel.example.com:9462",
                "Origin": self.tailnet_origin,
            },
        )

        with urllib.request.urlopen(request, timeout=2) as response:
            self.assertEqual("image/png", response.headers.get_content_type())

    def test_printer_status_does_not_overlap_print_job(self):
        started = threading.Event()
        release = threading.Event()
        errors = []

        class BlockingPrinter(FakePrinter):
            def print_image(self, path):
                started.set()
                if not release.wait(timeout=2):
                    raise PrinterError("Test print did not resume")
                super().print_image(path)

        self.server.printer = BlockingPrinter()

        def print_label():
            try:
                with self.post("/api/print", {"labels": ["LOCK TEST"], "length": 48}):
                    pass
            except Exception as exc:
                errors.append(exc)

        print_thread = threading.Thread(target=print_label)
        print_thread.start()
        self.assertTrue(started.wait(timeout=2))
        try:
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(self.base_url + "/api/status", timeout=2)
            self.assertEqual(409, error.exception.code)
        finally:
            release.set()
            print_thread.join(timeout=2)
        self.assertEqual([], errors)

    def test_invalid_length_is_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.post("/api/preview", {"label": "TEST", "length": 200})

        self.assertEqual(400, error.exception.code)

    def test_non_object_payload_is_rejected(self):
        request = urllib.request.Request(
            self.base_url + "/api/preview",
            data=json.dumps(["TEST"]).encode(),
            headers={"Content-Type": "application/json"},
        )

        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request, timeout=2)

        self.assertEqual(400, error.exception.code)


class LabelmakerHelpersTests(unittest.TestCase):
    def test_runtime_configuration_defaults_to_local_only(self):
        port, trusted_origins = _runtime_config_from_environment({})

        self.assertEqual(9462, port)
        self.assertEqual((), trusted_origins)

    def test_runtime_configuration_accepts_port_and_multiple_origins(self):
        port, trusted_origins = _runtime_config_from_environment(
            {
                "CABLELABEL_PORT": "10462",
                "CABLELABEL_TRUSTED_ORIGINS": (
                    "https://label-one.example.com, https://label-two.example.com:9462"
                ),
            }
        )

        self.assertEqual(10462, port)
        self.assertEqual(
            (
                "https://label-one.example.com",
                "https://label-two.example.com:9462",
            ),
            trusted_origins,
        )

    def test_runtime_configuration_rejects_invalid_port(self):
        for value in ("nope", "0", "65536"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                _runtime_config_from_environment({"CABLELABEL_PORT": value})

    def test_browser_opening_defaults_on_and_accepts_binary_values(self):
        self.assertTrue(_open_browser_from_environment({}))
        self.assertFalse(_open_browser_from_environment({"CABLELABEL_OPEN_BROWSER": "0"}))
        self.assertTrue(_open_browser_from_environment({"CABLELABEL_OPEN_BROWSER": "1"}))

    def test_browser_opening_rejects_invalid_value(self):
        with self.assertRaisesRegex(ValueError, "CABLELABEL_OPEN_BROWSER"):
            _open_browser_from_environment({"CABLELABEL_OPEN_BROWSER": "sometimes"})

    def test_server_rejects_non_https_trusted_origin(self):
        with self.assertRaisesRegex(ValueError, "HTTPS origins"):
            create_server(("127.0.0.1", 0), FakePrinter(), ("http://example.com",))

    def test_device_not_found_message_has_mac_recovery_steps(self):
        message = friendly_printer_error("Error: Device not found")

        self.assertIn("power it on", message.lower())
        self.assertIn("P-touch Editor", message)


if __name__ == "__main__":
    unittest.main()
