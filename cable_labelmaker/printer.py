"""Safe subprocess wrapper around the ptouch-rs direct USB CLI."""

import subprocess
from pathlib import Path


class PrinterError(RuntimeError):
    """The printer command failed."""


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
