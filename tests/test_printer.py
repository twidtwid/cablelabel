import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cable_labelmaker.printer import PrinterLock, PtouchPrinter, PrinterError


class PrinterLockTests(unittest.TestCase):
    def test_lock_is_shared_between_processes_and_released(self):
        child_program = """
import sys
from pathlib import Path
from cable_labelmaker.printer import PrinterLock

lock = PrinterLock(Path(sys.argv[1]))
raise SystemExit(0 if lock.acquire(blocking=False) else 23)
"""
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "printer.lock"
            lock = PrinterLock(lock_path)
            self.assertTrue(lock.acquire(blocking=False))
            try:
                contended = subprocess.run(
                    [sys.executable, "-c", child_program, str(lock_path)],
                    capture_output=True,
                    text=True,
                    check=False,
                )
            finally:
                lock.release()

            available = subprocess.run(
                [sys.executable, "-c", child_program, str(lock_path)],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(23, contended.returncode, contended.stderr)
        self.assertEqual(0, available.returncode, available.stderr)


class PtouchPrinterTests(unittest.TestCase):
    def test_print_uses_argument_list_without_shell(self):
        printer = PtouchPrinter(Path("/tmp/ptouch"))

        with patch("cable_labelmaker.printer.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "ok", "")
            printer.print_image(Path("/tmp/label with spaces.png"))

        run.assert_called_once_with(
            [
                "/tmp/ptouch",
                "print",
                "--image",
                "/tmp/label with spaces.png",
                "--binarize",
                "threshold",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def test_print_error_contains_device_output(self):
        printer = PtouchPrinter(Path("/tmp/ptouch"))

        with patch("cable_labelmaker.printer.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 1, "", "Device not found")
            with self.assertRaisesRegex(PrinterError, "Device not found"):
                printer.print_image(Path("/tmp/label.png"))

    def test_timeout_has_physical_recovery_step(self):
        printer = PtouchPrinter(Path("/tmp/ptouch"))

        with patch(
            "cable_labelmaker.printer.subprocess.run",
            side_effect=subprocess.TimeoutExpired("ptouch", 30),
        ):
            with self.assertRaisesRegex(PrinterError, "Power-cycle"):
                printer.print_image(Path("/tmp/label.png"))

    def test_missing_print_engine_has_build_recovery_step(self):
        printer = PtouchPrinter(Path("/tmp/ptouch"))

        with patch("cable_labelmaker.printer.subprocess.run", side_effect=FileNotFoundError):
            with self.assertRaisesRegex(PrinterError, "Rebuild Cable Labelmaker"):
                printer.info()


if __name__ == "__main__":
    unittest.main()
