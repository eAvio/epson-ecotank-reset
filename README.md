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
- Read status (detects printer, logs details, saves a snapshot). Default output is a concise normalized summary:
  ```bash
  ./epson.sh status
  ```
  Show full per-address details:
  ```bash
  ./epson.sh status --details
  ```
  Show ambiguous counters and write CSV snapshot:
  ```bash
  ./epson.sh status --show-ambiguous
  ./epson.sh status --csv                      # writes snapshots/COUNTERS_<stamp>.csv
  ./epson.sh status --csv=snapshots/my.csv     # custom path
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
- macOS: USB access for status/reset typically REQUIRES sudo. The tool auto-retries with sudo on permission errors and hides low-level tracebacks. You can also run directly with `sudo ./epson.sh status` or `sudo ./epson.sh reset ...` to avoid prompts.
- Quiet by default: INFO logs from reinkpy are suppressed; user-facing output is concise. Use `logs/` for detailed diagnostics.
- Multiple devices: if more than one Epson USB device is found, you'll be prompted to select which one.
- Logs live in `logs/` and snapshots in `snapshots/`.
- If CSV is written while the script elevates to sudo, the CSV file may be owned by root. You can fix ownership with:
  ```bash
  sudo chown "$USER" snapshots/COUNTERS_<stamp>.csv
  ```

## Credits
- Built on top of the excellent open-source [reinkpy](https://codeberg.org/atufi/reinkpy) by @atufi.
- Community discussions (example ET-series reset set): Reddit thread “[Epson Ecotank ... reset totally free](https://www.reddit.com/r/printers/comments/18s9cfi/epson_ecotank_epson_et2720_ink_pad_reset_totally/)”.
 
 

## Features
- Auto-bootstrap virtualenv and install `reinkpy` (PyPI or fallback to Codeberg source).
- macOS: Homebrew/libusb hints and installation.
- Linux: libusb presence hint and udev guidance for Epson VID `04B8`.
- Robust logging with daily logs, per-run status/reset logs.
- EEPROM dump if supported; textual state snapshot otherwise.
- Human-readable grouping of waste/platen counters using model specs.
- Neutral Counter 1/2/3 labeling for ET-181x family (default output shows normalized percentages).
- Optional display of ambiguous "Waste counters (?)" via `--show-ambiguous`.
- CSV export of per-address readings via `--csv[=PATH]`.
 - Quiet output by default (suppresses INFO-level logs and hides Python tracebacks). Use logs for deep debugging.
 - Interactive device selection if multiple printers are connected.

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

 

## Counter mapping (ET‑1810)

When running `./epson.sh status`, ET‑1810 models label groups as neutral counters and display normalized percentages by default:

- `Counter 1` → addresses `[0x30,0x31]`
- `Counter 2` → addresses `[0x32,0x33]`
- `Counter 3` → addresses `[0xFC,0xFD]`

You can show the spec's ambiguous set with `--show-ambiguous` to aid diagnostics:

- Ambiguous group: `[0x1C,0x34,0x35,0x36,0x37,0xFF]` (0x34/0x35 often mirror 0x30/0x31).

CSV rows contain: `model,group_label,group_type,addr,value_hex,percent_255,group_sum,normalized_percent,group_max_percent`.

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
