# Contributing

Thanks for helping improve Cable Labelmaker.

## Development setup

Requirements:

- macOS on Apple silicon or Linux on x86_64/arm64
- [uv](https://docs.astral.sh/uv/)
- ImageMagick for macOS application builds
- `file`, `shellcheck`, and systemd tools for Linux verification
- Rust, `pkg-config`, and libudev development files for Linux arm64 builds

Run the automated gate before opening a pull request:

```sh
make check
```

Connected-printer testing is not a CI requirement. If a change touches direct
printing, describe the printer model, tape width, and manual result in the pull
request. Avoid unnecessary test prints.

## Pull requests

- Keep each pull request focused.
- Add or update tests for behavior changes.
- Update the README when user-visible behavior changes.
- Do not include credentials, private hostnames, local filesystem paths, or
  network configuration.
- Do not commit downloaded printer binaries or build output.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
