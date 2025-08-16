# Epson EcoTank Waste Counter Utility

A small, safe‑ish shell utility to inspect and reset Epson EcoTank “waste ink pad” counters using the open‑source
[reinkpy](https://codeberg.org/atufi/reinkpy) project.

Why this exists: our office Epson EcoTank ET-1810 reported “waste tank full”, but the physical pad/tank was almost
empty and the vendor tools didn’t offer a reset. With reinkpy’s open tooling we can read counters, keep backups,
and reset the timers — similar to paid tools, but free and auditable.

Important warning: this is experimental. Use at your own risk. Always make snapshots before modifying device state,
and ensure your pads are not physically saturated.

## Quick Start 

- Install and bootstrap (creates venv, installs deps, probes status):
  ```bash
  ./install.sh
  ```
- Read status (detects printer, logs details, saves a snapshot):
  ```bash
  ./epson.sh status
  ```
- Reset waste counters (auto-detected addresses; will prompt):
  ```bash
  ./epson.sh reset --auto
  ```
 - Reset waste counters manually (no --auto; example ET-series slots):
  ```bash
  ./epson.sh reset --addresses 0x2f,0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37 --yes
  ```

Notes:
- On macOS, reading/writing EEPROM may require `sudo` due to USB permissions.
- Logs live in `logs/` and snapshots in `snapshots/`.

## Credits
- Built on top of the excellent open-source [reinkpy](https://codeberg.org/atufi/reinkpy) by @atufi.
- Community discussions (example ET-series reset set): Reddit thread “Epson Ecotank ... reset totally free”.

 

## Features
- Auto-bootstrap virtualenv and install `reinkpy` (PyPI or fallback to Codeberg source).
- macOS: Homebrew/libusb hints and installation.
- Linux: libusb presence hint and udev guidance for Epson VID `04B8`.
- Robust logging with daily logs, per-run status/reset logs.
- EEPROM dump if supported; textual state snapshot otherwise.

## Prerequisites
### macOS
- Homebrew recommended. If missing, scripts print a hint.
- Ensure libusb: `brew list libusb || brew install libusb`.

### Linux
- Ensure libusb (`sudo apt-get install -y libusb-1.0-0` or equivalent for your distro).
- If running as non-root, you may need a udev rule for Epson VID `04B8` to allow USB access. Example rule (save as `/etc/udev/rules.d/99-epson.rules`):
  ```
  SUBSYSTEM=="usb", ATTR{idVendor}=="04b8", MODE="0666"
  ```
  Then reload rules: `sudo udevadm control --reload-rules && sudo udevadm trigger`.

 

## Structure
```
.
├── epson.sh              # Single entrypoint: status/reset
├── install.sh            # One-shot bootstrap (chmod, hints, first probe)
├── Makefile              # Optional convenience targets
├── .env/                 # Python virtualenv (auto-created)
├── logs/                 # Logs with timestamps
├── snapshots/            # EEPROM/state backups
├── scripts/
│   ├── common.sh         # Shared helpers (venv, logging, help dump)
│   ├── epson_status.sh   # Device detect, status, snapshot
│   └── epson_reset.sh    # Reset counters (auto/manual)
├── vendor/               # reinkpy source if PyPI unavailable
├── .gitignore
└── README.md
```
