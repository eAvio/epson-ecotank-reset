#!/usr/bin/env bash
# Reset Epson EcoTank waste counters safely using reinkpy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage:
  $0 --auto [--yes]
  $0 --addresses 0x2f,0x30[,0x31...] [--yes]

Options:
  --auto         Auto-detect waste counter addresses from latest status log.
  --addresses    Comma-separated hex addresses, e.g., 0x2f,0x30,0x31
  --yes          Do not prompt for confirmation.
  -h, --help     Show this help.
USAGE
}

# Validate comma-separated hex list like 0x2f,0x30
validate_addresses() {
  local addrs="$1"
  if [[ "$addrs" =~ ^0x[0-9a-fA-F]{1,2}(,0x[0-9a-fA-F]{1,2})*$ ]]; then
    return 0
  fi
  return 1
}

# Extract suggested addresses from a log file; prefer lines containing waste/pad/counter
extract_addresses_from_log() {
  local logfile="$1"
  if [[ -f "$logfile" ]]; then
    # Prefer lines with waste/pad/counter; fallback to all hex tokens
    local prefer
    prefer="$(grep -iE 'waste|pad|counter' "$logfile" | grep -oiE '0x[0-9a-f]{1,2}' | sort -u | tr '\n' ',' | sed 's/,$//')"
    if [[ -n "$prefer" ]]; then
      echo "$prefer"
      return 0
    fi
    grep -oiE '0x[0-9a-f]{1,2}' "$logfile" | sort -u | tr '\n' ',' | sed 's/,$//'
  fi
}

# Find the latest STATUS_*.log file
latest_status_log() {
  ls -1t "$LOG_DIR"/STATUS_*.log 2>/dev/null | head -n1 || true
}

confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N]: " ans || true
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

run_reset() {
  local addrs="$1"
  local stamp
  stamp="$(ts)"
  local reset_log="$LOG_DIR/RESET_${stamp}.log"

  log "Resetting waste counters for addresses: $addrs"

  # Use Python API directly (CLI flags are not available in this build)
  local ok=0
  log "Attempt: Python API reset (addresses: ${addrs:-auto/spec})" | tee -a "$reset_log" >/dev/null
  if "$VENV_DIR/bin/python3" - "$addrs" <<'PY' | tee -a "$reset_log"; then
import sys, logging
for name in ('reinkpy', 'reinkpy.usb', 'reinkpy.d4'):
    try:
        logging.getLogger(name).setLevel(logging.WARNING)
    except Exception:
        pass
from reinkpy import UsbDevice

addrs_str = sys.argv[1] if len(sys.argv) > 1 else ''
devices = list(UsbDevice.ifind())
if not devices:
    print(' - No USB device found')
    sys.exit(1)
dev = devices[0]
if len(devices) > 1:
    print(' - Multiple USB devices found:')
    for i, dv in enumerate(devices, start=1):
        print(f"     [{i}] {dv}")
    try:
        choice = input(f"   Select device [1-{len(devices)}]: ").strip()
        idx = int(choice) - 1
        if 0 <= idx < len(devices):
            dev = devices[idx]
    except Exception:
        pass
    print(f" - Using: {dev}")
e = dev.epson
try:
    e.configure(True)  # load spec for detected model
except Exception:
    pass

ok = False
if addrs_str:
    # manual addresses: set to 0 by default
    try:
        addrs = [int(x, 16) for x in addrs_str.split(',') if x]
        pairs = [(a, 0) for a in addrs]
        ok = bool(e.write_eeprom(*pairs, atomic=True))
    except Exception as ex:
        print(f'ERROR: write_eeprom failed: {ex}')
        ok = False
else:
    # auto/spec-based full waste reset
    try:
        res = e.reset_waste()
        ok = bool(res)
    except Exception as ex:
        print(f'ERROR: reset_waste failed: {ex}')
        ok = False

print('RESULT:', 'OK' if ok else 'FAIL')
sys.exit(0 if ok else 1)
PY
    ok=1
  else
    log "Primary attempt failed. Retrying with sudo..." | tee -a "$reset_log" >/dev/null
    if sudo "$VENV_DIR/bin/python3" - "$addrs" <<'PY' | tee -a "$reset_log"; then
import sys, logging
for name in ('reinkpy', 'reinkpy.usb', 'reinkpy.d4'):
    try:
        logging.getLogger(name).setLevel(logging.WARNING)
    except Exception:
        pass
from reinkpy import UsbDevice

addrs_str = sys.argv[1] if len(sys.argv) > 1 else ''
devices = list(UsbDevice.ifind())
if not devices:
    print(' - No USB device found')
    sys.exit(1)
dev = devices[0]
if len(devices) > 1:
    print(' - Multiple USB devices found:')
    for i, dv in enumerate(devices, start=1):
        print(f"     [{i}] {dv}")
    try:
        choice = input(f"   Select device [1-{len(devices)}]: ").strip()
        idx = int(choice) - 1
        if 0 <= idx < len(devices):
            dev = devices[idx]
    except Exception:
        pass
    print(f" - Using: {dev}")
e = dev.epson
try:
    e.configure(True)  # load spec for detected model
except Exception:
    pass

ok = False
if addrs_str:
    # manual addresses: set to 0 by default
    try:
        addrs = [int(x, 16) for x in addrs_str.split(',') if x]
        pairs = [(a, 0) for a in addrs]
        ok = bool(e.write_eeprom(*pairs, atomic=True))
    except Exception as ex:
        print(f'ERROR: write_eeprom failed: {ex}')
        ok = False
else:
    # auto/spec-based full waste reset
    try:
        res = e.reset_waste()
        ok = bool(res)
    except Exception as ex:
        print(f'ERROR: reset_waste failed: {ex}')
        ok = False

print('RESULT:', 'OK' if ok else 'FAIL')
sys.exit(0 if ok else 1)
PY
      ok=1
    fi
  fi

  if [[ "$ok" -ne 1 ]]; then
    log "Reset command failed. See $reset_log for details."
    reink_help_dump || true
    return 1
  fi

  log "Reset command finished successfully. Log: $reset_log"
  return 0
}

main() {
  local auto=0
  local addrs=""
  local assume_yes=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto) auto=1; shift ;;
      --addresses) addrs="${2:-}"; shift 2 ;;
      --yes) assume_yes=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *)
        log "Unknown argument: $1"
        usage
        exit 2
        ;;
    esac
  done

  if [[ "$auto" -eq 0 && -z "$addrs" ]]; then
    usage
    exit 2
  fi

  ensure_venv "$@"

  # Pre-reset snapshot/log
  log "Taking pre-reset status snapshot..."
  "$SCRIPT_DIR/epson_status.sh" || {
    log "Pre-reset status failed. Ensure a supported Epson device is connected and accessible."
    exit 1
  }

  # Determine addresses
  if [[ -n "$addrs" ]]; then
    if ! validate_addresses "$addrs"; then
      log "Invalid --addresses format. Expected: 0x2f,0x30[,0x31]"
      exit 2
    fi
  elif [[ "$auto" -eq 1 ]]; then
    local latest
    latest="$(latest_status_log)"
    if [[ -z "$latest" ]]; then
      log "No previous STATUS_*.log found; re-running status to capture info."
      "$SCRIPT_DIR/epson_status.sh" || true
      latest="$(latest_status_log)"
    fi
    local extracted
    extracted="$(extract_addresses_from_log "$latest")"
    if [[ -z "$extracted" ]]; then
      log "Could not auto-detect waste counter addresses."
      log "Guidance: run '$SCRIPT_DIR/epson_status.sh' and inspect the log for waste/pad counters, then rerun with --addresses 0x..,0x.."
      exit 2
    fi
    # Prefer model spec-based reset via Python API over raw addresses
    log "Auto-detected candidates: $extracted"
    log "Proceeding with model spec-based reset (safer)"
    addrs=""
  fi

  if [[ -n "$addrs" ]]; then
    echo "Will reset waste counters at addresses: $addrs"
  else
    echo "Will reset waste counters using model spec (auto)"
  fi
  if [[ "$assume_yes" -ne 1 ]]; then
    if ! confirm "Proceed?"; then
      log "Aborted by user."
      exit 0
    fi
  fi

  if ! run_reset "$addrs"; then
    log "Reset failed. See logs for details and try manual addresses or different permissions."
    exit 1
  fi

  # Post-reset verification
  log "Taking post-reset status snapshot..."
  "$SCRIPT_DIR/epson_status.sh" || true

  echo
  echo "SUCCESS: Waste counters reset attempted for addresses: $addrs"
  echo "See logs in: $LOG_DIR"
  echo "Snapshots in: $SNAP_DIR"
}

main "$@"
