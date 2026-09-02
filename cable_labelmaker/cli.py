"""Command-line interface for human and agent-driven cable labeling."""

import argparse
import json
import sys
import tempfile
from pathlib import Path

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
from .server import (
    create_server,
    main as serve_from_environment,
    open_browser_from_environment,
    port_from_environment,
    run_server,
    trusted_origins_from_environment,
)


EXIT_OK = 0
EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_PRINTER = 3
EXIT_PARTIAL_PRINT = 4


class CLIUsageError(ValueError):
    """Command-line arguments did not satisfy the public CLI contract."""


class CableLabelArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise CLIUsageError(message)


def _length(value: str) -> int:
    try:
        length = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"length must be an integer from {MIN_LENGTH_MM} to {MAX_LENGTH_MM} mm"
        ) from exc
    if not MIN_LENGTH_MM <= length <= MAX_LENGTH_MM:
        raise argparse.ArgumentTypeError(
            f"length must be an integer from {MIN_LENGTH_MM} to {MAX_LENGTH_MM} mm"
        )
    return length


def _port(value: str) -> int:
    try:
        port = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("port must be an integer from 0 to 65535") from exc
    if not 0 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be an integer from 0 to 65535")
    return port


def _copies(value: str) -> int:
    try:
        copies = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("copies must be an integer from 1 to 100") from exc
    if not 1 <= copies <= 100:
        raise argparse.ArgumentTypeError("copies must be an integer from 1 to 100")
    return copies


def build_parser() -> argparse.ArgumentParser:
    parser = CableLabelArgumentParser(
        prog="cablelabel",
        description="Preview, print, and serve wraparound labels for a Brother PT-D600.",
    )
    parser.add_argument("--json", action="store_true", help="emit one JSON object to stdout")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("status", help="check the USB printer connection")

    preview = commands.add_parser("preview", help="write a print-accurate tape preview PNG")
    preview.add_argument("label", help="label text; use | or -> to split up to three lines")
    preview.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("cable-label-preview.png"),
        help="PNG destination (default: cable-label-preview.png)",
    )
    preview.add_argument("--length", type=_length, default=DEFAULT_LENGTH_MM, metavar="MM")

    print_parser = commands.add_parser("print", help="print one or more labels over USB")
    print_parser.add_argument(
        "labels",
        nargs="*",
        metavar="LABEL",
        help="label text; quote spaces and shell metacharacters such as |",
    )
    print_parser.add_argument(
        "--stdin",
        action="store_true",
        help="also read one label per nonblank line from standard input",
    )
    print_parser.add_argument("--copies", type=_copies, default=1)
    print_parser.add_argument("--length", type=_length, default=DEFAULT_LENGTH_MM, metavar="MM")

    serve = commands.add_parser("serve", help="run the local web interface")
    serve.add_argument("--port", type=_port, metavar="PORT")
    serve.add_argument(
        "--trusted-origin",
        action="append",
        default=None,
        metavar="HTTPS_ORIGIN",
        help="allow an HTTPS reverse-proxy origin; repeat for more than one",
    )
    browser = serve.add_mutually_exclusive_group()
    browser.add_argument("--browser", action="store_true", dest="open_browser")
    browser.add_argument("--no-browser", action="store_false", dest="open_browser")
    serve.set_defaults(open_browser=None)
    return parser


def _emit(payload, human_message, *, json_output, stdout, stderr, error=False):
    if json_output:
        print(json.dumps(payload, sort_keys=True), file=stdout, flush=True)
    else:
        print(human_message, file=stderr if error else stdout, flush=True)


def _printer_or_default(printer):
    return printer if printer is not None else PtouchPrinter(PTOUCH_BINARY)


def _status(args, printer, printer_lock, stdout, stderr):
    if not printer_lock.acquire(blocking=False):
        error = printer_error_details("The printer is busy")
        _emit(
            {"command": "status", "connected": False, "ok": False, **error},
            error["error"],
            json_output=args.json,
            stdout=stdout,
            stderr=stderr,
            error=True,
        )
        return EXIT_PRINTER
    try:
        try:
            detail = printer.info()
        except PrinterError as exc:
            error = printer_error_details(str(exc))
            _emit(
                {"command": "status", "connected": False, "ok": False, **error},
                error["error"],
                json_output=args.json,
                stdout=stdout,
                stderr=stderr,
                error=True,
            )
            return EXIT_PRINTER
    finally:
        printer_lock.release()
    _emit(
        {"command": "status", "connected": True, "detail": detail, "ok": True},
        detail,
        json_output=args.json,
        stdout=stdout,
        stderr=stderr,
    )
    return EXIT_OK


def _preview(args, stdout, stderr):
    try:
        image = render_tape_preview(args.label, args.length)
    except ValueError as exc:
        _emit(
            {"command": "preview", "error": str(exc), "ok": False},
            str(exc),
            json_output=args.json,
            stdout=stdout,
            stderr=stderr,
            error=True,
        )
        return EXIT_USAGE

    try:
        output = args.output.expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        image.save(output, format="PNG")
    except (OSError, ValueError) as exc:
        _emit(
            {"command": "preview", "error": str(exc), "ok": False},
            str(exc),
            json_output=args.json,
            stdout=stdout,
            stderr=stderr,
            error=True,
        )
        return EXIT_USAGE

    payload = {
        "command": "preview",
        "height_px": image.height,
        "label": args.label,
        "length_mm": args.length,
        "ok": True,
        "path": str(output),
        "width_px": image.width,
    }
    _emit(
        payload,
        f"Preview written to {output}",
        json_output=args.json,
        stdout=stdout,
        stderr=stderr,
    )
    return EXIT_OK


def _input_labels(args, stdin):
    labels = [label.strip() for label in args.labels if label.strip()]
    if len(labels) * args.copies > MAX_BATCH_SIZE:
        raise ValueError(
            f"print batches are limited to {MAX_BATCH_SIZE} labels, including copies"
        )
    if args.stdin:
        for line in stdin:
            label = line.strip()
            if not label:
                continue
            if (len(labels) + 1) * args.copies > MAX_BATCH_SIZE:
                raise ValueError(
                    f"print batches are limited to {MAX_BATCH_SIZE} labels, including copies"
                )
            labels.append(label)
    if not labels:
        raise ValueError("add at least one label or use --stdin")
    expanded = [label for label in labels for _copy in range(args.copies)]
    return expanded


def _print_failure(args, labels, index, error, stdout, stderr):
    error_details = printer_error_details(error)
    payload = {
        "command": "print",
        "failed_index": index,
        "failed_label": labels[index],
        "ok": False,
        "printed": index,
        "total": len(labels),
        **error_details,
    }
    _emit(
        payload,
        f"{error_details['error']} ({index} of {len(labels)} labels printed)",
        json_output=args.json,
        stdout=stdout,
        stderr=stderr,
        error=True,
    )
    return EXIT_PARTIAL_PRINT if index else EXIT_PRINTER


def _print(args, printer, printer_lock, stdin, stdout, stderr):
    lock_acquired = False
    try:
        labels = _input_labels(args, stdin)
    except ValueError as exc:
        _emit(
            {"command": "print", "error": str(exc), "ok": False},
            str(exc),
            json_output=args.json,
            stdout=stdout,
            stderr=stderr,
            error=True,
        )
        return EXIT_USAGE

    try:
        if not printer_lock.acquire(blocking=False):
            return _print_failure(
                args,
                labels,
                0,
                "The printer is busy",
                stdout,
                stderr,
            )
        lock_acquired = True
        with tempfile.TemporaryDirectory(prefix="cable-labels-") as directory:
            paths = render_many(labels, Path(directory), args.length)
            for index, path in enumerate(paths):
                try:
                    printer.print_image(path)
                except PrinterError as exc:
                    return _print_failure(
                        args,
                        labels,
                        index,
                        str(exc),
                        stdout,
                        stderr,
                    )
    except ValueError as exc:
        _emit(
            {"command": "print", "error": str(exc), "ok": False},
            str(exc),
            json_output=args.json,
            stdout=stdout,
            stderr=stderr,
            error=True,
        )
        return EXIT_USAGE
    finally:
        if lock_acquired:
            printer_lock.release()

    payload = {"command": "print", "ok": True, "printed": len(labels), "total": len(labels)}
    _emit(
        payload,
        f"Printed {len(labels)} label{'s' if len(labels) != 1 else ''}.",
        json_output=args.json,
        stdout=stdout,
        stderr=stderr,
    )
    return EXIT_OK


def _serve(args, printer, server_factory, stdout, stderr):
    ready_emitted = False

    def report_ready(url):
        nonlocal ready_emitted
        _emit(
            {"command": "serve", "ok": True, "url": url},
            f"Cable Labelmaker is available at {url}",
            json_output=args.json,
            stdout=stdout,
            stderr=stderr,
        )
        ready_emitted = True

    try:
        port = args.port if args.port is not None else port_from_environment()
        origins = (
            tuple(args.trusted_origin)
            if args.trusted_origin is not None
            else trusted_origins_from_environment()
        )
        open_browser = (
            args.open_browser
            if args.open_browser is not None
            else open_browser_from_environment()
        )
        run_server(
            port,
            origins,
            open_browser,
            printer=printer,
            server_factory=server_factory,
            ready_callback=report_ready,
        )
    except ValueError as exc:
        if ready_emitted:
            print(f"Cable Labelmaker stopped: {exc}", file=stderr, flush=True)
            return EXIT_ERROR
        _emit(
            {"command": "serve", "error": str(exc), "ok": False},
            str(exc),
            json_output=args.json,
            stdout=stdout,
            stderr=stderr,
            error=True,
        )
        return EXIT_USAGE
    except OSError as exc:
        if ready_emitted:
            print(f"Cable Labelmaker stopped: {exc}", file=stderr, flush=True)
            return EXIT_ERROR
        _emit(
            {"command": "serve", "error": str(exc), "ok": False},
            str(exc),
            json_output=args.json,
            stdout=stdout,
            stderr=stderr,
            error=True,
        )
        return EXIT_ERROR
    except Exception:
        if ready_emitted:
            print(
                "Cable Labelmaker stopped after startup because of an unexpected error",
                file=stderr,
                flush=True,
            )
            return EXIT_ERROR
        raise
    return EXIT_OK


def _json_discovery(arguments, parser, stdout, stderr):
    if "--json" not in arguments:
        return None
    option_arguments = arguments[: arguments.index("--")] if "--" in arguments else arguments
    command_names = {"status", "preview", "print", "serve"}
    first_positional_index = next(
        (
            index
            for index, argument in enumerate(option_arguments)
            if not argument.startswith("-")
        ),
        None,
    )
    if first_positional_index is not None and (
        option_arguments[first_positional_index] not in command_names
    ):
        return None
    command_index = first_positional_index
    version_index = (
        option_arguments.index("--version") if "--version" in option_arguments else None
    )
    discovery_indices = [
        index
        for index in (
            version_index,
            *(
                option_arguments.index(flag)
                for flag in ("--help", "-h")
                if flag in option_arguments
            ),
        )
        if index is not None
    ]
    if command_index is None and discovery_indices:
        first_discovery = min(discovery_indices)
        if any(
            not argument.startswith("-")
            for argument in option_arguments[:first_discovery]
        ):
            return None
    if version_index is not None and (
        command_index is None or version_index < command_index
    ):
        _emit(
            {"command": "version", "ok": True, "version": __version__},
            f"cablelabel {__version__}",
            json_output=True,
            stdout=stdout,
            stderr=stderr,
        )
        return EXIT_OK
    help_indices = [
        option_arguments.index(flag)
        for flag in ("--help", "-h")
        if flag in option_arguments
    ]
    if not help_indices:
        return None

    help_index = min(help_indices)
    command = (
        option_arguments[command_index]
        if command_index is not None and command_index < help_index
        else None
    )
    help_parser = parser
    if command is not None:
        subparsers = next(
            action
            for action in parser._actions
            if isinstance(action, argparse._SubParsersAction)
        )
        help_parser = subparsers.choices[command]
    _emit(
        {
            "command": "help",
            "help": help_parser.format_help(),
            "ok": True,
            "topic": command or "cablelabel",
        },
        help_parser.format_help(),
        json_output=True,
        stdout=stdout,
        stderr=stderr,
    )
    return EXIT_OK


def main(
    argv=None,
    *,
    printer=None,
    printer_lock=PRINTER_LOCK,
    server_factory=create_server,
    stdin=None,
    stdout=None,
    stderr=None,
):
    """Run the CLI and return its process exit code."""
    arguments = list(sys.argv[1:] if argv is None else argv)
    if not arguments:
        serve_from_environment()
        return EXIT_OK

    stdin = sys.stdin if stdin is None else stdin
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    parser = build_parser()
    discovery_result = _json_discovery(arguments, parser, stdout, stderr)
    if discovery_result is not None:
        return discovery_result
    try:
        args = parser.parse_args(arguments)
    except CLIUsageError as exc:
        json_requested = "--json" in arguments
        _emit(
            {"command": "arguments", "error": str(exc), "ok": False},
            str(exc),
            json_output=json_requested,
            stdout=stdout,
            stderr=stderr,
            error=True,
        )
        return EXIT_USAGE
    except SystemExit as exc:
        return int(exc.code)

    try:
        if args.command == "status":
            return _status(
                args,
                _printer_or_default(printer),
                printer_lock,
                stdout,
                stderr,
            )
        if args.command == "preview":
            return _preview(args, stdout, stderr)
        if args.command == "print":
            return _print(
                args,
                _printer_or_default(printer),
                printer_lock,
                stdin,
                stdout,
                stderr,
            )
        if args.command == "serve":
            return _serve(
                args,
                _printer_or_default(printer),
                server_factory,
                stdout,
                stderr,
            )
    except Exception:
        error = "Cable Labelmaker encountered an unexpected error"
        _emit(
            {"command": args.command, "error": error, "ok": False},
            error,
            json_output=args.json,
            stdout=stdout,
            stderr=stderr,
            error=True,
        )
        return EXIT_ERROR
    return EXIT_ERROR
