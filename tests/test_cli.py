import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image

from cable_labelmaker import cli
from cable_labelmaker.limits import MAX_BATCH_SIZE
from cable_labelmaker.printer import PrinterError, PrinterLock
from cable_labelmaker.renderer import mm_to_px


class FakePrinter:
    def __init__(self, info="PT-D600 connected", fail_on_print=None):
        self.info_result = info
        self.fail_on_print = fail_on_print
        self.printed = []

    def info(self):
        if isinstance(self.info_result, Exception):
            raise self.info_result
        return self.info_result

    def print_image(self, path):
        if len(self.printed) + 1 == self.fail_on_print:
            raise PrinterError("Device not found")
        self.printed.append(Path(path).read_bytes())
        return "printed"


class FakeServer:
    def __init__(self, address):
        self.server_port = address[1]
        self.served = False
        self.closed = False

    def serve_forever(self):
        self.served = True

    def server_close(self):
        self.closed = True


class CliTests(unittest.TestCase):
    def setUp(self):
        self.lock_directory = tempfile.TemporaryDirectory()
        self.printer_lock = PrinterLock(Path(self.lock_directory.name) / "printer.lock")

    def tearDown(self):
        self.lock_directory.cleanup()

    def run_cli(self, arguments, printer=None, stdin=""):
        stdout = io.StringIO()
        stderr = io.StringIO()
        code = cli.main(
            arguments,
            printer=printer or FakePrinter(),
            printer_lock=self.printer_lock,
            stdin=io.StringIO(stdin),
            stdout=stdout,
            stderr=stderr,
        )
        return code, stdout.getvalue(), stderr.getvalue()

    def test_status_json_is_machine_readable(self):
        code, stdout, stderr = self.run_cli(["--json", "status"])

        self.assertEqual(0, code)
        self.assertEqual("", stderr)
        self.assertEqual(
            {
                "command": "status",
                "connected": True,
                "detail": "PT-D600 connected",
                "ok": True,
            },
            json.loads(stdout),
        )

    def test_status_failure_has_stable_exit_code_and_json(self):
        printer = FakePrinter(PrinterError("Device not found"))

        code, stdout, stderr = self.run_cli(["--json", "status"], printer)

        self.assertEqual(cli.EXIT_PRINTER, code)
        self.assertEqual("", stderr)
        payload = json.loads(stdout)
        self.assertFalse(payload["ok"])
        self.assertFalse(payload["connected"])
        self.assertIn("PT-D600 not found", payload["error"])

    def test_status_lock_contention_does_not_contact_printer(self):
        printer = FakePrinter(RuntimeError("printer must not be contacted"))
        self.assertTrue(self.printer_lock.acquire(blocking=False))
        try:
            code, stdout, stderr = self.run_cli(["--json", "status"], printer)
        finally:
            self.printer_lock.release()

        self.assertEqual(cli.EXIT_PRINTER, code)
        self.assertEqual("", stderr)
        payload = json.loads(stdout)
        self.assertFalse(payload["connected"])
        self.assertIn("busy", payload["error"].lower())

    def test_unexpected_failure_still_returns_one_json_object(self):
        printer = FakePrinter(RuntimeError("unexpected test failure"))

        code, stdout, stderr = self.run_cli(["--json", "status"], printer)

        self.assertEqual(cli.EXIT_ERROR, code)
        self.assertEqual("", stderr)
        self.assertEqual(
            {
                "command": "status",
                "error": "Cable Labelmaker encountered an unexpected error",
                "ok": False,
            },
            json.loads(stdout),
        )

    def test_preview_writes_the_full_tape_without_printing(self):
        printer = FakePrinter()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "att-uplink.png"

            code, stdout, stderr = self.run_cli(
                ["--json", "preview", "AT&T UPLINK", "--output", str(output)],
                printer,
            )

            self.assertEqual(0, code)
            self.assertEqual("", stderr)
            self.assertEqual([], printer.printed)
            with Image.open(output) as image:
                self.assertEqual((mm_to_px(48), mm_to_px(24)), image.size)
            payload = json.loads(stdout)
            self.assertTrue(payload["ok"])
            self.assertEqual(str(output.resolve()), payload["path"])
            self.assertEqual(48, payload["length_mm"])

    def test_preview_rejects_more_than_three_lines_as_input_error(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "invalid.png"

            code, stdout, _stderr = self.run_cli(
                ["--json", "preview", "A|B|C|D", "--output", str(output)]
            )

            self.assertEqual(cli.EXIT_USAGE, code)
            self.assertFalse(output.exists())
            self.assertIn("at most three", json.loads(stdout)["error"])

    def test_preview_renderer_failure_is_an_internal_error(self):
        with patch(
            "cable_labelmaker.cli.render_tape_preview",
            side_effect=RuntimeError("font unavailable"),
        ):
            code, stdout, stderr = self.run_cli(
                ["--json", "preview", "TEST"]
            )

        self.assertEqual(cli.EXIT_ERROR, code)
        self.assertEqual("", stderr)
        self.assertEqual(1, len(stdout.splitlines()))
        self.assertEqual("preview", json.loads(stdout)["command"])

    def test_argument_errors_are_json_when_requested(self):
        code, stdout, stderr = self.run_cli(
            ["--json", "preview", "TEST", "--length", "200"]
        )

        self.assertEqual(cli.EXIT_USAGE, code)
        self.assertEqual("", stderr)
        payload = json.loads(stdout)
        self.assertFalse(payload["ok"])
        self.assertEqual("arguments", payload["command"])
        self.assertIn("39 to 70", payload["error"])

    def test_json_help_is_exactly_one_machine_readable_object(self):
        code, stdout, stderr = self.run_cli(["--json", "--help"])

        self.assertEqual(cli.EXIT_OK, code)
        self.assertEqual("", stderr)
        payload = json.loads(stdout)
        self.assertEqual("help", payload["command"])
        self.assertEqual("cablelabel", payload["topic"])
        self.assertIn("preview", payload["help"])
        self.assertEqual(1, len(stdout.splitlines()))

    def test_json_version_is_exactly_one_machine_readable_object(self):
        code, stdout, stderr = self.run_cli(["--json", "--version"])

        self.assertEqual(cli.EXIT_OK, code)
        self.assertEqual("", stderr)
        payload = json.loads(stdout)
        self.assertEqual("version", payload["command"])
        self.assertTrue(payload["version"])
        self.assertEqual(1, len(stdout.splitlines()))

    def test_invalid_command_is_not_hidden_by_json_discovery(self):
        for flag in ("--help", "--version"):
            with self.subTest(flag=flag):
                code, stdout, stderr = self.run_cli(
                    ["--json", "not-a-command", flag]
                )

                self.assertEqual(cli.EXIT_USAGE, code)
                self.assertEqual("", stderr)
                self.assertEqual("arguments", json.loads(stdout)["command"])

    def test_print_sends_every_label_and_copy(self):
        printer = FakePrinter()

        code, stdout, stderr = self.run_cli(
            ["--json", "print", "AT&T UPLINK", "COMCAST UPLINK", "--copies", "2"],
            printer,
        )

        self.assertEqual(0, code)
        self.assertEqual("", stderr)
        self.assertEqual(4, len(printer.printed))
        self.assertEqual(
            {"command": "print", "ok": True, "printed": 4, "total": 4},
            json.loads(stdout),
        )

    def test_partial_print_failure_reports_exact_progress(self):
        printer = FakePrinter(fail_on_print=2)

        code, stdout, stderr = self.run_cli(
            ["--json", "print", "ONE", "TWO", "THREE"], printer
        )

        self.assertEqual(cli.EXIT_PARTIAL_PRINT, code)
        self.assertEqual("", stderr)
        self.assertEqual(1, len(printer.printed))
        payload = json.loads(stdout)
        self.assertEqual(1, payload["printed"])
        self.assertEqual(3, payload["total"])
        self.assertEqual(1, payload["failed_index"])
        self.assertEqual("TWO", payload["failed_label"])

    def test_first_print_failure_reports_zero_progress(self):
        printer = FakePrinter(fail_on_print=1)

        code, stdout, stderr = self.run_cli(
            ["--json", "print", "FIRST", "SECOND"], printer
        )

        self.assertEqual(cli.EXIT_PRINTER, code)
        self.assertEqual("", stderr)
        self.assertEqual([], printer.printed)
        payload = json.loads(stdout)
        self.assertEqual(0, payload["printed"])
        self.assertEqual(0, payload["failed_index"])
        self.assertEqual("FIRST", payload["failed_label"])

    def test_positional_batch_limit_rejects_before_printing(self):
        printer = FakePrinter()
        labels = [f"LABEL {index}" for index in range(MAX_BATCH_SIZE + 1)]

        code, stdout, stderr = self.run_cli(
            ["--json", "print", *labels], printer
        )

        self.assertEqual(cli.EXIT_USAGE, code)
        self.assertEqual("", stderr)
        self.assertEqual([], printer.printed)
        self.assertIn("limited", json.loads(stdout)["error"])

    def test_stdin_batch_limit_rejects_before_printing(self):
        printer = FakePrinter()
        labels = "\n".join(
            f"LABEL {index}" for index in range(MAX_BATCH_SIZE + 1)
        )

        code, stdout, stderr = self.run_cli(
            ["--json", "print", "--stdin"], printer, labels
        )

        self.assertEqual(cli.EXIT_USAGE, code)
        self.assertEqual("", stderr)
        self.assertEqual([], printer.printed)
        self.assertIn("limited", json.loads(stdout)["error"])

    def test_print_lock_contention_reports_first_label_without_printing(self):
        printer = FakePrinter()
        self.assertTrue(self.printer_lock.acquire(blocking=False))
        try:
            code, stdout, stderr = self.run_cli(
                ["--json", "print", "WAIT FOR PRINTER"], printer
            )
        finally:
            self.printer_lock.release()

        self.assertEqual(cli.EXIT_PRINTER, code)
        self.assertEqual("", stderr)
        self.assertEqual([], printer.printed)
        payload = json.loads(stdout)
        self.assertEqual(0, payload["failed_index"])
        self.assertEqual("WAIT FOR PRINTER", payload["failed_label"])
        self.assertIn("busy", payload["error"].lower())

    def test_print_renderer_failure_is_an_internal_error_and_releases_lock(self):
        with patch(
            "cable_labelmaker.cli.render_many",
            side_effect=RuntimeError("font unavailable"),
        ):
            code, stdout, stderr = self.run_cli(
                ["--json", "print", "TEST"]
            )

        self.assertEqual(cli.EXIT_ERROR, code)
        self.assertEqual("", stderr)
        self.assertEqual(1, len(stdout.splitlines()))
        self.assertEqual("print", json.loads(stdout)["command"])
        self.assertTrue(self.printer_lock.acquire(blocking=False))
        self.printer_lock.release()

    def test_print_can_read_newline_delimited_labels_from_stdin(self):
        printer = FakePrinter()

        code, stdout, _stderr = self.run_cli(
            ["--json", "print", "--stdin"], printer, "ONE\n\nTWO | PORT 2\n"
        )

        self.assertEqual(0, code)
        self.assertEqual(2, len(printer.printed))
        self.assertEqual(2, json.loads(stdout)["printed"])

    def test_serve_accepts_explicit_runtime_options(self):
        created = {}

        def server_factory(address, printer=None, trusted_origins=()):
            created["address"] = address
            created["printer"] = printer
            created["origins"] = trusted_origins
            created["server"] = FakeServer(address)
            return created["server"]

        with patch("cable_labelmaker.server.webbrowser.open_new_tab") as open_tab:
            code = cli.main(
                [
                    "serve",
                    "--port",
                    "10462",
                    "--trusted-origin",
                    "https://labels.example.ts.net",
                    "--no-browser",
                ],
                printer=FakePrinter(),
                server_factory=server_factory,
                stdout=io.StringIO(),
                stderr=io.StringIO(),
            )

        self.assertEqual(0, code)
        self.assertEqual(("127.0.0.1", 10462), created["address"])
        self.assertEqual(("https://labels.example.ts.net",), created["origins"])
        self.assertTrue(created["server"].served)
        self.assertTrue(created["server"].closed)
        open_tab.assert_not_called()

    def test_explicit_port_overrides_invalid_environment_port(self):
        created = {}

        def server_factory(address, printer=None, trusted_origins=()):
            created["address"] = address
            return FakeServer(address)

        with patch.dict("os.environ", {"CABLELABEL_PORT": "invalid"}, clear=False):
            code = cli.main(
                ["serve", "--port", "10462", "--no-browser"],
                printer=FakePrinter(),
                printer_lock=self.printer_lock,
                server_factory=server_factory,
                stdout=io.StringIO(),
                stderr=io.StringIO(),
            )

        self.assertEqual(cli.EXIT_OK, code)
        self.assertEqual(("127.0.0.1", 10462), created["address"])

    def test_serve_bind_failure_returns_general_error(self):
        def server_factory(_address, printer=None, trusted_origins=()):
            raise OSError("address already in use")

        code, stdout, stderr = self._run_serve_with_factory(
            ["--json", "serve", "--no-browser"], server_factory
        )

        self.assertEqual(cli.EXIT_ERROR, code)
        self.assertEqual("", stderr)
        self.assertIn("address already in use", json.loads(stdout)["error"])

    def test_json_serve_emits_startup_payload(self):
        code, stdout, stderr = self._run_serve_with_factory(
            ["--json", "serve", "--port", "10462", "--no-browser"],
            lambda address, printer=None, trusted_origins=(): FakeServer(address),
        )

        self.assertEqual(cli.EXIT_OK, code)
        self.assertEqual("", stderr)
        self.assertEqual(
            {
                "command": "serve",
                "ok": True,
                "url": "http://127.0.0.1:10462",
            },
            json.loads(stdout),
        )

    def test_json_serve_runtime_failure_keeps_one_stdout_object(self):
        class FailingServer(FakeServer):
            def serve_forever(self):
                raise OSError("server loop failed")

        code, stdout, stderr = self._run_serve_with_factory(
            ["--json", "serve", "--port", "10462", "--no-browser"],
            lambda address, printer=None, trusted_origins=(): FailingServer(address),
        )

        self.assertEqual(cli.EXIT_ERROR, code)
        self.assertEqual(1, len(stdout.splitlines()))
        self.assertTrue(json.loads(stdout)["ok"])
        self.assertIn("server loop failed", stderr)

    def _run_serve_with_factory(self, arguments, server_factory):
        stdout = io.StringIO()
        stderr = io.StringIO()
        code = cli.main(
            arguments,
            printer=FakePrinter(),
            printer_lock=self.printer_lock,
            server_factory=server_factory,
            stdout=stdout,
            stderr=stderr,
        )
        return code, stdout.getvalue(), stderr.getvalue()

    def test_no_arguments_preserves_desktop_serve_behavior(self):
        with patch("cable_labelmaker.cli.serve_from_environment") as serve:
            code = cli.main([], stdout=io.StringIO(), stderr=io.StringIO())

        self.assertEqual(0, code)
        serve.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
