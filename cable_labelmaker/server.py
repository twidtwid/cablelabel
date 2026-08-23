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

from .printer import PrinterError, PtouchPrinter
from .renderer import DEFAULT_LENGTH_MM, render_many, render_tape_preview


RESOURCE_ROOT = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
WEB_ROOT = RESOURCE_ROOT / "web"
PTOUCH_BINARY = RESOURCE_ROOT / "bin" / "ptouch"
APP_PORT = 9462


class RequestRejected(Exception):
    """The browser request did not come from this local app."""


def friendly_printer_error(detail: str) -> str:
    if "device not found" in detail.lower():
        return (
            "PT-D600 not found. Connect its USB cable, power it on, and quit "
            "P-touch Editor before trying again."
        )
    if "busy" in detail.lower() or "access" in detail.lower():
        return "The PT-D600 is busy. Quit P-touch Editor, then try again."
    return detail.strip()


def _length(value) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("Wrap length must be a number")
    length = int(value)
    if not 39 <= length <= 70:
        raise ValueError("Wrap length must be between 39 and 70 mm")
    return length


def _runtime_config_from_environment(environ=None):
    """Return the listening port and optional HTTPS origins for remote access."""
    environ = os.environ if environ is None else environ
    raw_port = environ.get("CABLELABEL_PORT", str(APP_PORT))
    try:
        port = int(raw_port)
    except (TypeError, ValueError) as exc:
        raise ValueError("CABLELABEL_PORT must be an integer from 1 to 65535") from exc
    if not 1 <= port <= 65535:
        raise ValueError("CABLELABEL_PORT must be an integer from 1 to 65535")

    trusted_origins = tuple(
        origin.strip()
        for origin in environ.get("CABLELABEL_TRUSTED_ORIGINS", "").split(",")
        if origin.strip()
    )
    return port, trusted_origins


class LabelmakerHTTPServer(ThreadingHTTPServer):
    def __init__(self, address, printer, trusted_origins=()):
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
        self.printer_lock = threading.Lock()
        local_host = f"{self.server_name}:{self.server_port}"
        self.allowed_hosts = {local_host, *remote_hosts}
        self.allowed_origins = {f"http://{local_host}", *remote_origins}

    def server_bind(self):
        # HTTPServer normally performs a reverse-DNS lookup here. That lookup
        # can stall a windowed macOS app and is unnecessary for localhost.
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
        if path == "/":
            self._send(200, "text/html; charset=utf-8", (WEB_ROOT / "index.html").read_bytes())
            return
        if path == "/api/status":
            if not self.server.printer_lock.acquire(blocking=False):
                self._json(409, {"connected": True, "detail": "A print job is running"})
                return
            try:
                detail = self.server.printer.info()
                self._json(200, {"connected": True, "detail": detail})
            except PrinterError as exc:
                self._json(503, {"connected": False, "detail": friendly_printer_error(str(exc))})
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
            self._json(503, {"error": friendly_printer_error(str(exc))})
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
        if len(labels) > 100:
            raise ValueError("Print batches are limited to 100 labels")
        length = _length(payload.get("length", DEFAULT_LENGTH_MM))
        if not self.server.printer_lock.acquire(blocking=False):
            self._json(409, {"error": "A print job is already running"})
            return
        try:
            with tempfile.TemporaryDirectory(prefix="cable-labels-") as directory:
                for index, path in enumerate(render_many(labels, Path(directory), length)):
                    try:
                        self.server.printer.print_image(path)
                    except PrinterError as exc:
                        self._json(
                            503,
                            {
                                "error": friendly_printer_error(str(exc)),
                                "printed": index,
                                "total": len(labels),
                                "failed_index": index,
                                "failed_label": labels[index],
                            },
                        )
                        return
            self._json(200, {"printed": len(labels)})
        finally:
            self.server.printer_lock.release()


def create_server(address=("127.0.0.1", APP_PORT), printer=None, trusted_origins=()):
    return LabelmakerHTTPServer(
        address,
        printer or PtouchPrinter(PTOUCH_BINARY),
        trusted_origins=trusted_origins,
    )


def main():
    port, trusted_origins = _runtime_config_from_environment()
    server = create_server(("127.0.0.1", port), trusted_origins=trusted_origins)
    url = f"http://127.0.0.1:{server.server_port}"
    threading.Timer(0.3, lambda: webbrowser.open_new_tab(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
