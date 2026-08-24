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


def friendly_printer_error(detail: str) -> str:
    if "device not found" in detail.lower():
        return (
            "PT-D600 not found. Connect its USB cable, power it on, and close "
            "any other program using it before trying again."
        )
    if "busy" in detail.lower() or "access" in detail.lower():
        return "The PT-D600 is busy. Close any other program using it, then try again."
    return detail.strip()


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
