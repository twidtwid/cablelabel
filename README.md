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
a LaunchAgent, and keeps it available at <http://127.0.0.1:9462/>. The app is
locally signed but not notarized. macOS can require one Control-click, **Open**,
and confirmation on first launch.

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

The installer places versioned bundles under `~/.local/opt/cablelabel`, enables
`cablelabel.service`, and checks <http://127.0.0.1:9462/> before reporting
success. It uses `sudo` only to install and reload the PT-D600 udev rule.

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
