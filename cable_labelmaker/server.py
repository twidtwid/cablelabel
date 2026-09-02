"""Local-only web interface for the direct USB cable labelmaker."""

import json
import os
import sys
import tempfile
import threading
import webbrowser
from io import BytesIO
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from urllib.parse import urlparse

from . import __version__
from .limits import MAX_BATCH_SIZE, MAX_LENGTH_MM, MIN_LENGTH_MM
from .printer import (
    PRINTER_LOCK,
    PTOUCH_BINARY,
    PrinterError,
    PtouchPrinter,
    printer_error_details,
)
from .renderer import DEFAULT_LENGTH_MM, render_many, render_tape_preview


RESOURCE_ROOT = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
WEB_ROOT = RESOURCE_ROOT / "web"
APP_PORT = 9462


class RequestRejected(Exception):
    """The browser request did not come from this local app."""


def _length(value) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("Wrap length must be a number")
    length = int(value)
    if not MIN_LENGTH_MM <= length <= MAX_LENGTH_MM:
        raise ValueError(f"Wrap length must be between {MIN_LENGTH_MM} and {MAX_LENGTH_MM} mm")
    return length


def runtime_config_from_environment(environ=None):
    """Return the listening port and optional HTTPS origins for remote access."""
    environ = os.environ if environ is None else environ
    return port_from_environment(environ), trusted_origins_from_environment(environ)


def port_from_environment(environ=None):
    """Return the validated listening port from the environment."""
    environ = os.environ if environ is None else environ
    raw_port = environ.get("CABLELABEL_PORT", str(APP_PORT))
    try:
        port = int(raw_port)
    except (TypeError, ValueError) as exc:
        raise ValueError("CABLELABEL_PORT must be an integer from 1 to 65535") from exc
    if not 1 <= port <= 65535:
        raise ValueError("CABLELABEL_PORT must be an integer from 1 to 65535")
    return port


def trusted_origins_from_environment(environ=None):
    """Return optional HTTPS origins from the environment."""
    environ = os.environ if environ is None else environ
    return tuple(
        origin.strip()
        for origin in environ.get("CABLELABEL_TRUSTED_ORIGINS", "").split(",")
        if origin.strip()
    )


def open_browser_from_environment(environ=None):
    """Return whether an interactive launch should open the web interface."""
    environ = os.environ if environ is None else environ
    value = environ.get("CABLELABEL_OPEN_BROWSER", "1").strip().lower()
    if value == "1":
        return True
    if value == "0":
        return False
    raise ValueError("CABLELABEL_OPEN_BROWSER must be 1 or 0")


class LabelmakerHTTPServer(ThreadingHTTPServer):
    def __init__(self, address, printer, trusted_origins=(), printer_lock=None):
        remote_hosts = set()
        remote_origins = set()
        for origin in trusted_origins:
            parsed = urlparse(origin)
            if (
                parsed.scheme != "https"
                or not parsed.hostname
                or parsed.path not in ("", "/")
                or parsed.params
                or parsed.query
                or parsed.fragment
                or parsed.username
                or parsed.password
            ):
                raise ValueError("Trusted origins must be HTTPS origins without a path")
            remote_hosts.add(parsed.netloc)
            remote_origins.add(origin.rstrip("/"))

        super().__init__(address, LabelmakerHandler)
        self.printer = printer
        self.printer_lock = PRINTER_LOCK if printer_lock is None else printer_lock
        local_host = f"{self.server_name}:{self.server_port}"
        self.allowed_hosts = {local_host, *remote_hosts}
        self.allowed_origins = {f"http://{local_host}", *remote_origins}

    def server_bind(self):
        # HTTPServer normally performs a reverse-DNS lookup here. That lookup
        # can stall an interactive desktop app and is unnecessary for localhost.
        TCPServer.server_bind(self)
        host, port = self.socket.getsockname()[:2]
        self.server_name = host
        self.server_port = port


class LabelmakerHandler(BaseHTTPRequestHandler):
    server: LabelmakerHTTPServer
    timeout = 10

    def log_message(self, _format, *_args):
        return

    def _send(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, payload):
        self._send(status, "application/json; charset=utf-8", json.dumps(payload).encode())

    def _payload(self):
        if self.headers.get("Host") not in self.server.allowed_hosts:
            raise RequestRejected("Invalid request host")
        origin = self.headers.get("Origin")
        if origin and origin not in self.server.allowed_origins:
            raise RequestRejected("Cross-origin requests are not allowed")
        if not self.headers.get("Content-Type", "").lower().startswith("application/json"):
            raise RequestRejected("Content-Type must be application/json")
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 65536:
            raise ValueError("Invalid request size")
        body = self.rfile.read(length)
        if len(body) != length:
            raise ValueError("Truncated request body")
        payload = json.loads(body)
        if not isinstance(payload, dict):
            raise ValueError("Request body must be a JSON object")
        return payload

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/health":
            self._json(200, {"name": "cablelabel", "version": __version__})
            return
        if path == "/":
            self._send(200, "text/html; charset=utf-8", (WEB_ROOT / "index.html").read_bytes())
            return
        if path == "/api/status":
            if not self.server.printer_lock.acquire(blocking=False):
                self._json(
                    409,
                    {
                        "connected": True,
                        "detail": "A print job is running",
                        "reason": "busy",
                        "retryable": True,
                    },
                )
                return
            try:
                detail = self.server.printer.info()
                self._json(200, {"connected": True, "detail": detail})
            except PrinterError as exc:
                error = printer_error_details(str(exc))
                self._json(
                    503,
                    {
                        "connected": False,
                        "detail": error.pop("error"),
                        **error,
                    },
                )
            finally:
                self.server.printer_lock.release()
            return
        self._json(404, {"error": "Not found"})

    def do_POST(self):
        try:
            payload = self._payload()
            path = urlparse(self.path).path
            if path == "/api/preview":
                self._preview(payload)
            elif path == "/api/print":
                self._print(payload)
            else:
                self._json(404, {"error": "Not found"})
        except RequestRejected as exc:
            self._json(403, {"error": str(exc)})
        except (ValueError, TypeError) as exc:
            self._json(400, {"error": str(exc)})
        except PrinterError as exc:
            self._json(503, printer_error_details(str(exc)))
        except Exception:
            self._json(500, {"error": "Cable Labelmaker encountered an unexpected error"})

    def _preview(self, payload):
        label = str(payload.get("label", ""))
        length = _length(payload.get("length", DEFAULT_LENGTH_MM))
        buffer = BytesIO()
        render_tape_preview(label, length).save(buffer, format="PNG")
        self._send(200, "image/png", buffer.getvalue())

    def _print(self, payload):
        labels = payload.get("labels")
        if not isinstance(labels, list):
            raise ValueError("Labels must be a list")
        labels = [normalised for label in labels if (normalised := str(label).strip())]
        if not labels:
            raise ValueError("Add at least one label")
        if len(labels) > MAX_BATCH_SIZE:
            raise ValueError(f"Print batches are limited to {MAX_BATCH_SIZE} labels")
        length = _length(payload.get("length", DEFAULT_LENGTH_MM))
        if not self.server.printer_lock.acquire(blocking=False):
            self._json(
                409,
                {
                    "error": "A print job is already running",
                    "reason": "busy",
                    "retryable": True,
                },
            )
            return
        try:
            with tempfile.TemporaryDirectory(prefix="cable-labels-") as directory:
                for index, path in enumerate(render_many(labels, Path(directory), length)):
                    try:
                        self.server.printer.print_image(path)
                    except PrinterError as exc:
                        error = printer_error_details(str(exc))
                        self._json(
                            503,
                            {
                                "printed": index,
                                "total": len(labels),
                                "failed_index": index,
                                "failed_label": labels[index],
                                **error,
                            },
                        )
                        return
            self._json(200, {"printed": len(labels)})
        finally:
            self.server.printer_lock.release()


def create_server(
    address=("127.0.0.1", APP_PORT),
    printer=None,
    trusted_origins=(),
    printer_lock=None,
):
    return LabelmakerHTTPServer(
        address,
        printer or PtouchPrinter(PTOUCH_BINARY),
        trusted_origins=trusted_origins,
        printer_lock=printer_lock,
    )


def run_server(
    port,
    trusted_origins,
    open_browser,
    *,
    printer=None,
    server_factory=create_server,
    ready_callback=None,
):
    """Run the web server until interrupted, optionally reporting its URL."""
    server = server_factory(
        ("127.0.0.1", port),
        printer=printer,
        trusted_origins=trusted_origins,
    )
    url = f"http://127.0.0.1:{server.server_port}"
    if ready_callback is not None:
        ready_callback(url)
    if open_browser:
        threading.Timer(0.3, lambda: webbrowser.open_new_tab(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main():
    port, trusted_origins = runtime_config_from_environment()
    run_server(port, trusted_origins, open_browser_from_environment())


if __name__ == "__main__":
    main()
