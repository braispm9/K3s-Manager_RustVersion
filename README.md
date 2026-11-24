# K3s Manager — Rust Version

A Rust rewrite of the original K3S-Manager with a compact Bash CLI and an `egui` desktop interface.

## Features

- Cross-platform Rust GUI with pod, network, audit, and help views
- Bash-compatible CLI for headless servers
- Pod listing, selection, logs, descriptions, creation, deletion, IP lookup
- NetworkPolicy isolation/opening and basic port testing
- Compact installer for CLI or GUI deployments
- Safe argument handling and corrected namespace support

## Build

```bash
cargo build --release
./target/release/k3smanager
```

The GUI locates `k3smanager.sh` beside the binary or in `/usr/local/bin`.

## Install

```bash
chmod +x k3sinstaller.sh
sudo ./k3sinstaller.sh cli
# or
sudo ./k3sinstaller.sh gui
```

For the GUI, build and publish `target/release/k3smanager` first. The installer then downloads that binary as `k3smanager-gui`.

## Usage

```bash
k3smanager list
k3smanager select 1-3
k3smanager describe
k3smanager check-ports 1-3
k3smanager
```

## Requirements

- Linux
- `kubectl`
- K3s
- Bash
- Rust 1.79+ for source builds

## License

MIT
