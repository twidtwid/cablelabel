# Cable Labelmaker

A small, local macOS app for designing and printing wraparound cable labels on
24 mm Brother laminated tape. It renders a print-accurate preview and sends the
label directly to a Brother PT-D600 over USB—no P-touch Editor round trip.

## What it does

- Repeats compact, rotated text around the cable so it is readable from several sides.
- Supports one, two, or three stacked lines with a consistent 20-dot type size.
- Previews the full 24 mm tape, including the printer's unprintable margins.
- Prints one label or a batch directly over USB.
- Runs locally by default and can optionally be exposed inside a Tailscale tailnet.

The current release targets Apple silicon Macs, the Brother PT-D600, and 24 mm
laminated tape. The default label is 48 mm long, leaving enough overlap for a
durable wrap on typical network cables.

## Build and install

Requirements:

- macOS on Apple silicon
- [uv](https://docs.astral.sh/uv/)
- ImageMagick (`brew install imagemagick`)
- A Brother PT-D600 connected over USB

Build the ad-hoc-signed app and install it as a persistent per-user service:

```sh
scripts/build-mac-app.sh
scripts/install-macos-service.sh
```

The installer copies the app to `/Applications/Cable Labelmaker.app`, installs
a LaunchAgent, and keeps it available at <http://127.0.0.1:9462/>. Quit P-touch
Editor before printing because only one application can own the USB device.
Use `--port PORT` to select another local port.

The app is locally signed but not notarized. On first launch, macOS may require
you to Control-click the app, choose **Open**, and confirm.

## Make labels

Put one cable on each row. Use `|`, `->`, `→`, `↔`, or `<->` to split a label
into as many as three stacked lines:

```text
AT&T UPLINK
ROUTER P3 | FLEX P9 | 2.5G
OFFICE -> SWITCH 08
```

For the best adhesion, clean the cable, wrap firmly, and overlap at least 12 mm
of laminated tape onto itself.

## Tailnet access

Cable Labelmaker binds only to localhost. Tailscale Serve can add HTTPS and
make it available to devices allowed by your tailnet policy without opening it
to the public internet.

Replace the example hostname with this Mac's Tailscale DNS name:

```sh
scripts/install-macos-service.sh \
  --trusted-origin "https://my-mac.my-tailnet.ts.net:9462"
tailscale serve --bg --https=9462 http://127.0.0.1:9462
```

Then open `https://my-mac.my-tailnet.ts.net:9462/`. Trusted origins must be
explicit HTTPS origins. You can repeat `--trusted-origin` when more than one is
needed.

Do not use Tailscale Funnel for this app. Cable Labelmaker intentionally has no
application-level login; tailnet identity and access controls are its remote
security boundary.

## Development

Run the same gate used by CI:

```sh
make check
```

Or run the test suite directly:

```sh
uv run --with-requirements requirements.txt \
  python -m unittest discover -s tests -v
```

Runtime configuration:

| Variable | Default | Purpose |
|---|---:|---|
| `CABLELABEL_PORT` | `9462` | Local listening port |
| `CABLELABEL_TRUSTED_ORIGINS` | empty | Comma-separated HTTPS origins allowed through a trusted reverse proxy |

## Direct-print engine

The USB transport is provided by
[`vowstar/ptouch-rs`](https://github.com/vowstar/ptouch-rs), version 0.5.0. The
build downloads its Apple silicon binary and verifies the published SHA-256
digest before bundling it. `ptouch-rs` is GPL-3.0-or-later; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

The original Cable Labelmaker source is available under the [MIT License](LICENSE).
