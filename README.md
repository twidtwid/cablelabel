# Cable Labelmaker

A small local app for designing and printing wraparound cable labels on 24 mm
Brother laminated tape. It renders a print-accurate preview and sends labels
directly to a Brother PT-D600 over USB.

## What it does

- Repeats compact, rotated text around the cable for visibility from several sides.
- Supports one, two, or three stacked lines with a consistent 20-dot type size.
- Previews the full 24 mm tape, including the printer's unprintable margins.
- Prints one label or a batch directly over USB.
- Runs locally by default and can optionally be exposed inside a Tailscale tailnet.
- Supports Apple silicon macOS and x86_64/arm64 Linux.

The default label is 48 mm long. This leaves enough overlap for a durable wrap
on typical network cables.

## Build and install on macOS

Requirements:

- Apple silicon Mac
- [uv](https://docs.astral.sh/uv/)
- ImageMagick (`brew install imagemagick`)
- Brother PT-D600 connected over USB

```sh
scripts/build-mac-app.sh
scripts/install-macos-service.sh
```

The installer copies the app to `/Applications/Cable Labelmaker.app`, installs
a LaunchAgent, exposes the CLI at `~/.local/bin/cablelabel`, and keeps the web
app available at <http://127.0.0.1:9462/>. The app is locally signed but not
notarized. macOS can require one Control-click, **Open**, and confirmation on
first launch.

## Build and install on Linux

Linux bundles support x86_64 and arm64. Persistent installation uses a systemd
user service. The installer also adds a udev rule for PT-D600 USB access.

Debian and Ubuntu build requirements:

```sh
sudo apt install curl file libudev-dev pkg-config shellcheck
```

Install [uv](https://docs.astral.sh/uv/), then build and install:

```sh
scripts/build-linux-app.sh
scripts/install-linux-service.sh
```

The arm64 build also requires a Rust toolchain because ptouch-rs does not
publish a Linux arm64 binary. The build compiles its pinned `v0.5.0` source.
Linux bundles include a pinned Roboto Condensed Bold font and its Apache 2.0
license, so previews and prints do not depend on system-installed fonts.

The installer places versioned bundles under `~/.local/opt/cablelabel`, exposes
the CLI at `~/.local/bin/cablelabel`, enables `cablelabel.service`, and checks
<http://127.0.0.1:9462/> before reporting success. It installs the PT-D600 udev
rule with the service user as its stable device owner, while retaining
desktop-session access. It uses `sudo` only to install and reload that rule.

For a headless machine that must start the user service before login, enable
lingering once:

```sh
loginctl enable-linger "$USER"
```

Use `--port PORT` with either installer to select another local port. Quit any
other program using the PT-D600 before printing because only one process can
own the USB device.

## Make labels

Put one cable on each row. Use `|`, `->`, `→`, `↔`, or `<->` to split a label
into as many as three stacked lines:

```text
AT&T UPLINK
ROUTER P3 | FLEX P9 | 2.5G
OFFICE -> SWITCH 08
```

Clean the cable, wrap firmly, and overlap at least 12 mm of tape onto itself.

## Command line

The installer provides the same `cablelabel` command on macOS and Linux. If
`~/.local/bin` is not already on your `PATH`, add it in your shell profile:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Check the connected printer and make a preview without using tape:

```sh
cablelabel status
cablelabel preview "AT&T UPLINK" --output att-uplink.png
```

Printing is an explicit command. Multiple arguments form a batch, `--copies`
repeats each label, and `--stdin` reads one label per nonblank line:

```sh
cablelabel print "AT&T UPLINK" "COMCAST UPLINK"
printf '%s\n' "ROUTER | PORT 3" "SWITCH | PORT 9" | cablelabel print --stdin
```

Quote labels containing spaces, `|`, or other shell metacharacters. Use
`--length MM` on `preview` or `print` to select a 39–70 mm wrap length. Run
`cablelabel serve --help` for web-server options.

## For agents

Install from a checked-out release exactly as a human would:

```sh
# macOS
scripts/build-mac-app.sh && scripts/install-macos-service.sh

# Linux
scripts/build-linux-app.sh && scripts/install-linux-service.sh
```

For source-tree automation without installing, replace `cablelabel` in the
examples below with:

```sh
uv run --with-requirements requirements.txt python main.py
```

Pass global `--json` before the subcommand. Successful and failed commands emit
one JSON object on stdout, making it safe to parse without scraping prose:

```sh
cablelabel --json status
cablelabel --json preview "ROUTER | PORT 3" --output /tmp/router-p3.png
cablelabel --json print "AT&T UPLINK"
printf '%s\n' "ONE" "TWO | PORT 2" | cablelabel --json print --stdin
```

Only the `print` subcommand produces physical output. `status`, `preview`,
`--help`, and `--version` never print a label. Do not invoke `print` merely to
test connectivity; use `status` and inspect a `preview` PNG first.

Exit codes are stable automation contracts:

| Code | Meaning |
|---:|---|
| `0` | Success |
| `1` | Unexpected internal failure |
| `2` | Invalid arguments, label text, length, or output path |
| `3` | Printer unavailable or failure before any label printed |
| `4` | Partial batch: at least one label printed before failure |

On a partial batch, the JSON object includes `printed`, `total`, zero-based
`failed_index`, and `failed_label`. An agent should not blindly retry the whole
batch because doing so would duplicate labels that already printed.

The long-running server can also be launched deterministically:

```sh
cablelabel --json serve --port 9462 --no-browser
```

It emits its startup JSON object before serving. Stop it with `SIGINT` or
`SIGTERM`; do not infer readiness from process existence when an HTTP health
check against the emitted `url` is available.

## Tailnet access

Cable Labelmaker binds only to localhost. Tailscale Serve can add HTTPS inside
your tailnet without opening the app to the public internet.

Replace the example hostname with the machine's Tailscale DNS name:

```sh
scripts/install-linux-service.sh \
  --trusted-origin "https://label-host.example.ts.net:9462"
tailscale serve --bg --https=9462 http://127.0.0.1:9462
```

Use `scripts/install-macos-service.sh` on macOS. Then open the trusted HTTPS
URL. You can repeat `--trusted-origin` when more than one origin is needed.

Do not use Tailscale Funnel. Cable Labelmaker has no application-level login;
tailnet identity and access controls are its remote security boundary.

## Development

Run the platform-specific gate used by CI:

```sh
make check
```

Runtime configuration:

| Variable | Default | Purpose |
|---|---:|---|
| `CABLELABEL_PORT` | `9462` | Local listening port |
| `CABLELABEL_TRUSTED_ORIGINS` | empty | Comma-separated HTTPS origins allowed through a trusted reverse proxy |
| `CABLELABEL_OPEN_BROWSER` | `1` | Set to `0` for a headless service |

## Direct-print engine

[`vowstar/ptouch-rs`](https://github.com/vowstar/ptouch-rs) provides USB
transport. Builds pin version `0.5.0`, verify downloaded SHA-256 digests, and
bundle its GPL license. The Linux arm64 bundle compiles the same pinned source
with Cargo's lockfile. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

The original Cable Labelmaker source is available under the [MIT License](LICENSE).
