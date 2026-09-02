"""Safe, process-coordinated access to the ptouch-rs direct USB CLI."""

import fcntl
import os
import subprocess
import sys
import threading
from pathlib import Path


RESOURCE_ROOT = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
PTOUCH_BINARY = RESOURCE_ROOT / "bin" / "ptouch"
PRINTER_LOCK_PATH = Path("/tmp") / f"cablelabel-printer-{os.getuid()}.lock"


class PrinterError(RuntimeError):
    """The printer command failed."""


class PrinterLock:
    """Non-blocking printer lock shared by threads and local processes."""

    def __init__(self, path=PRINTER_LOCK_PATH):
        self.path = Path(path)
        self._thread_lock = threading.Lock()
        self._file_descriptor = None

    def acquire(self, blocking=False) -> bool:
        if blocking:
            raise ValueError("The printer lock only supports non-blocking acquisition")
        if not self._thread_lock.acquire(blocking=False):
            return False

        file_descriptor = None
        try:
            flags = os.O_CREAT | os.O_RDWR
            if hasattr(os, "O_CLOEXEC"):
                flags |= os.O_CLOEXEC
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            file_descriptor = os.open(self.path, flags, 0o600)
            fcntl.flock(file_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            if file_descriptor is not None:
                os.close(file_descriptor)
            self._thread_lock.release()
            return False

        self._file_descriptor = file_descriptor
        return True

    def release(self):
        if self._file_descriptor is None:
            raise RuntimeError("The printer lock is not held")
        try:
            fcntl.flock(self._file_descriptor, fcntl.LOCK_UN)
        finally:
            os.close(self._file_descriptor)
            self._file_descriptor = None
            self._thread_lock.release()


PRINTER_LOCK = PrinterLock()


def printer_error_details(detail: str) -> dict:
    """Return stable machine metadata and a useful human printer error."""
    detail = detail.strip()
    lower_detail = detail.lower()
    if "timed out" in lower_detail or "timeout" in lower_detail:
        return {"error": detail, "reason": "timeout", "retryable": True}
    if (
        "print engine is missing" in lower_detail
        or "cannot run" in lower_detail
        or "no such file" in lower_detail
    ):
        return {"error": detail, "reason": "engine_unavailable", "retryable": False}
    if "device not found" in lower_detail or "pt-d600 not found" in lower_detail:
        return {
            "error": (
                "PT-D600 not found. Connect its USB cable, power it on, and close "
                "any other program using it before trying again."
            ),
            "reason": "not_found",
            "retryable": True,
        }
    if "permission denied" in lower_detail or "access denied" in lower_detail:
        return {
            "error": "Cable Labelmaker does not have permission to access the PT-D600.",
            "reason": "access_denied",
            "retryable": False,
        }
    if "busy" in lower_detail or "resource temporarily unavailable" in lower_detail:
        return {
            "error": "The PT-D600 is busy. Close any other program using it, then try again.",
            "reason": "busy",
            "retryable": True,
        }
    return {"error": detail, "reason": "command_failed", "retryable": False}


def friendly_printer_error(detail: str) -> str:
    return printer_error_details(detail)["error"]


class PtouchPrinter:
    def __init__(self, executable: Path):
        self.executable = Path(executable)

    def _run(self, arguments, timeout=30):
        try:
            result = subprocess.run(
                [str(self.executable), *arguments],
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise PrinterError(
                "The print engine timed out. Power-cycle the PT-D600 before trying again."
            ) from exc
        except (FileNotFoundError, PermissionError) as exc:
            raise PrinterError(
                "The print engine is missing or cannot run. Rebuild Cable Labelmaker."
            ) from exc
        if result.returncode:
            detail = (result.stderr or result.stdout or "Printer command failed").strip()
            raise PrinterError(detail)
        return (result.stdout or result.stderr).strip()

    def info(self) -> str:
        return self._run(["info"], timeout=10)

    def print_image(self, image_path: Path) -> str:
        return self._run(
            [
                "print",
                "--image",
                str(image_path),
                "--binarize",
                "threshold",
            ]
        )
