# Script reference

`epson.sh` is a thin dispatcher. `./epson.sh status` runs `scripts/epson_status.sh`; `./epson.sh reset` runs
`scripts/epson_reset.sh`. Both pass their remaining arguments through unchanged and source `scripts/common.sh`.
On every run, `common.sh` creates the `.env` virtualenv if it is missing, upgrades pip, and installs reinkpy
if it is not already installed.

The scripts do their device work in inline Python, using reinkpy's API (`UsbDevice`, `read_eeprom`,
`write_eeprom`, `reset_waste`). The reinkpy version tested here has no `--usb`, `--list` or EEPROM-dump
options on `python -m reinkpy.epson`. The scripts still check for those options first and fall back to the
API when they are absent.

## Device selection

Both scripts use the same rule to choose a printer. It matters on Linux.

reinkpy's `UsbDevice.ifind()` returns **file devices first** (`/dev/lp?`, `/dev/usb/lp?`) and pyusb
interfaces after them. When the `lp` parallel-port module is loaded, `/dev/lp0`–`/dev/lp3` exist even with no
printer behind them. `/dev/usb/lp0` is the kernel `usblp` node for a USB printer. A typical listing on
openSUSE Tumbleweed looks like this:

```
DEVICE: (unknown brand) (unknown model) sn:? @file:/dev/lp3
DEVICE: (unknown brand) (unknown model) sn:? @file:/dev/lp2
DEVICE: (unknown brand) (unknown model) sn:? @file:/dev/lp1
DEVICE: (unknown brand) (unknown model) sn:? @file:/dev/lp0
DEVICE: (unknown brand) (unknown model) sn:? @file:/dev/usb/lp0
DEVICE: EPSON ET-2850 Series sn:584146353033373789 @usb:1:13:1:(133,4)
```

Taking the first entry would select `/dev/lp3`. The scripts therefore choose a device like this:

1. Sort devices whose name contains `@usb:` (pyusb interfaces) ahead of file devices.
2. Probe each device and keep those that report an Epson model.
3. If exactly one is left, use it: ` - Using: <device>`.
4. If several are left, list them as `[n] <model>: <device>` and use the first. (See
   [Known limitations](#known-limitations): the prompt cannot currently read an answer.)
5. If none reports a model, fall back to reinkpy's first device and say so:
   ` - No detected Epson model; using first backend device: <device>`.

The device listing in `epson_status.sh` probes only `@usb:` devices when there are any. It records how many
others it skipped as `SKIPPED_BACKENDS: N non-USB backend device(s)`.

reinkpy's loggers (`reinkpy`, `reinkpy.usb`, `reinkpy.d4`) are set to `CRITICAL`, so probing nodes with no
printer stays quiet. This also hides problems that reinkpy logs without raising an exception. To debug reinkpy
itself, lower that level in the inline Python.

## `epson_status.sh` — read counters

```
./epson.sh status [--details] [--show-ambiguous] [--csv | --csv=PATH]
```

| Option | Effect |
|---|---|
| *(none)* | Summary: one line per counter group. Same as `--summary` / `--summary-only`. |
| `--details`, `--full` | Also print every address in each group as `addr 0xNN: 0xVV (P%)`, flagged `(high)` at ≥ 90 %. |
| `--show-ambiguous` | Also read `0x1C,0x34–0x37,0xFF`, the set the ET-1810 spec labels `Waste counters (?)`. The set is hard-coded and read for every model. |
| `--csv` | Append the per-address readings to `snapshots/COUNTERS_<stamp>.csv`. |
| `--csv=PATH` | Same, to `PATH`. The file is appended to and gets a header only when new. |

Unknown options are ignored silently.

### What it does

1. **List devices** into `logs/STATUS_<stamp>.log` as `DEVICE:`, `MODEL:`, `WASTE_ADDRS:` and `PLATEN_ADDRS:`
   lines. If no device is found, the script exits with status 1.
2. **Collect waste addresses.** It gathers every `0xNN` token in the listing into "Potential waste slots".
   `reset --auto` extracts addresses from the same log.
3. **Snapshot.** If reinkpy offers an EEPROM dump option, the dump goes to `snapshots/EEPROM_<stamp>.bin`.
   Current reinkpy builds have none, so the script writes `snapshots/STATE_<stamp>.txt` instead. That file
   holds the device listing and reinkpy's `--help` text, **not the counter values**. To keep a record of the
   values, use `--csv` or save the terminal output.
4. **Print counters.** It reads the model spec's `waste counter` and `platen pad counter` groups:
   - **ET-181x** models show only the three groups mapped in the README (`Counter 1/2/3`). Each is shown as a
     percentage normalized against an estimated capacity, for example `Counter 1: 12.06% (sum 17)`.
   - **Other models** (such as the ET-2850) show every group, labelled `Waste #n` / `Platen pad #n`. A group's
     value is the highest single address as a share of 255: `(max 41.2%)`. This is a raw-byte indicator and
     **not** a fill level. A group whose sum is 0 shows `0.00% (sum 0)`.
   - If the spec has no such groups, it reads the addresses from step 2 and prints them raw.
5. **Retry with sudo.** If step 4 fails for any reason, it runs again under `sudo` (asking for your password).
6. **Summary**: the paths to the status log and the snapshot, and the potential waste slots.

## `epson_reset.sh` — reset counters

```
./epson.sh reset --auto [--yes]
./epson.sh reset --addresses 0x2f,0x30[,0x31...] [--yes]
```

| Option | Effect |
|---|---|
| `--auto` | Reset the waste counters that reinkpy's spec defines for the detected model, using `reset_waste()`. |
| `--addresses LIST` | Write `0` to each listed address. The format is `0xNN[,0xNN...]`, one or two hex digits each. |
| `--yes` | Skip the `Proceed? [y/N]` confirmation. |
| `-h`, `--help` | Usage. |

### What it does

1. **Pre-reset status.** It runs `epson_status.sh` with default options. If that fails, the reset aborts.
2. **Decide what to reset.**
   - `--addresses`: the list is validated and used as given.
   - `--auto`: the script reads hex addresses from the newest `logs/STATUS_*.log`, only to confirm that
     detection worked, and then **discards them**. The reset uses the model spec, not the listed addresses.
     Because it relies on reinkpy's per-model spec, `--auto` is the safer choice.
3. **Confirm**, unless `--yes` was given.
4. **Reset.** For `--auto` it calls `reset_waste()`. For `--addresses` it calls `write_eeprom()` once with
   every `(address, 0)` pair and `atomic=True`. Output goes to `logs/RESET_<stamp>.log` and ends with
   `RESULT: OK` or `RESULT: FAIL`. On failure it retries once under `sudo`.
5. **Post-reset status.** It runs `epson_status.sh` again so you can compare. A failure in this step does not
   fail the reset.

> **Warning:** `--addresses` writes to whatever addresses you give it. Zeroing the wrong EEPROM bytes can
> misconfigure the printer. Use only addresses known for your exact model, and prefer `--auto`.

Exit codes: `0` on success or when you answer "no" at the prompt. `1` if the pre-reset status or the reset
itself failed. `2` on a usage error, an invalid `--addresses` list, or when `--auto` finds no addresses.

## Files written

| Path | Written by | Content |
|---|---|---|
| `logs/<YYYYMMDD>.log` | both | Day log of every `[timestamp] message` line |
| `logs/STATUS_<stamp>.log` | status | Device listing (`DEVICE:` / `MODEL:` / `WASTE_ADDRS:`) |
| `logs/RESET_<stamp>.log` | reset | Device chosen, errors, `RESULT:` line |
| `logs/reinkpy_epson_help_<stamp>.txt` | status; reset on failure | `reinkpy.epson --help` output, for diagnostics |
| `snapshots/STATE_<stamp>.txt` | status | Listing and help text; no counter values |
| `snapshots/EEPROM_<stamp>.bin` | status | EEPROM dump, only if reinkpy offers a dump option |
| `snapshots/COUNTERS_<stamp>.csv` | status `--csv` | Per-address readings (columns in the README) |

`reset` runs `status` twice, so each reset produces two status logs and two snapshots.

## Known limitations

- **The device prompt cannot read input.** Each Python block is fed to `python3 -` through a heredoc, so its
  stdin is the script itself. `input()` gets end-of-file immediately and the code falls back to the first
  candidate. With two Epson printers attached, the scripts print the list and then use the first one listed.
  Until this is fixed, **connect only the printer you mean to reset.**
- **`make read-counters` still uses reinkpy's first device** (`next(UsbDevice.ifind())`). On Linux that is a
  `/dev/lp?` node, not the printer. Use `./epson.sh status --details` instead.
- **Counter percentages are estimates.** The ET-181x capacities came from a single snapshot, and other models
  show raw bytes. Neither tells you how full the physical pad is.
- **No undo.** Neither script restores counters from a snapshot, and the `STATE_*.txt` snapshot has no values
  to restore from.

## Tested hardware

- **ET-2850** on openSUSE Tumbleweed, through the pyusb backend. `status` works. `reset --auto` reported
  `RESULT: OK`.
- **ET-1810**: the printer the upstream project was written for. The README has its counter mapping.
