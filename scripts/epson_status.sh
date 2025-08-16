#!/usr/bin/env bash
# Inspect connected Epson printers, print waste-counter info, and snapshot EEPROM/state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

main() {
  ensure_venv "$@"

  mkdir -p "$SNAP_DIR"

  local stamp
  stamp="$(ts)"
  local status_log="$LOG_DIR/STATUS_${stamp}.log"

  log "=== Epson status start @ ${stamp} ==="
  log "Platform: $(platform)"
  log "Python: $("$VENV_DIR/bin/python3" --version 2>&1 | tr -d '\n')"

  # Try to get reinkpy version if available
  local reink_ver
  reink_ver="$("$VENV_DIR/bin/python3" - <<'PY'
try:
    import importlib.metadata as md
except Exception:
    import pkg_resources as md
try:
    try:
        print(md.version('reinkpy'))
    except Exception:
        import reinkpy
        print(getattr(reinkpy, '__version__', 'unknown'))
except Exception:
    print('unknown')
PY
)"
  log "reinkpy: ${reink_ver}"

  # Detect devices via primary command --usb; fallback to --list
  if reink_has_opt "--usb" || reink_has_opt "--list"; then
    local usb_cmd=("$VENV_DIR/bin/python3" -m reinkpy.epson --usb)
    log "Running: ${usb_cmd[*]} (device listing)"
    if ! "${usb_cmd[@]}" | tee "$status_log"; then
      log "'--usb' failed. Trying fallback '--list'..."
      local list_cmd=("$VENV_DIR/bin/python3" -m reinkpy.epson --list)
      if ! "${list_cmd[@]}" | tee -a "$status_log"; then
        log "No device info could be obtained. Possible causes: permissions (udev), cable/USB, unsupported model."
        case "$(platform)" in
          Linux) log "Try running with sudo or adding a udev rule for Epson VID 04B8.";;
        esac
        reink_help_dump || true
        exit 1
      fi
    fi
  else
    log "This reinkpy build does not expose USB/listing options in reinkpy.epson; using Python API fallback."
    reink_help_dump || true
    # Python API: list USB devices and print info and potential waste slots
    "$VENV_DIR/bin/python3" - <<PY | tee "$status_log"
import sys
from reinkpy import UsbDevice
devices = list(UsbDevice.ifind())
if not devices:
    print('No USB devices found via Python API')
    sys.exit(1)
for d in devices:
    print('DEVICE:', d)
    try:
        e = d.epson
        print('MODEL:', e.detected_model)
        m = e.spec.get_mem('waste counter')
        if m:
            print('WASTE_ADDRS:', ','.join('0x%02x'%a for a in m['addr']))
        m2 = e.spec.get_mem('platen pad counter')
        if m2:
            print('PLATEN_ADDRS:', ','.join('0x%02x'%a for a in m2['addr']))
    except Exception as ex:
        print('ERROR:', ex)
PY
    # Continue to parsing stage using the produced $status_log content
  fi

  # Ensure at least one Epson device is referenced in output
  if ! grep -qiE "epson|04b8|DEVICE:" "$status_log"; then
    log "No Epson device detected in output. Check connections and power."
    exit 1
  fi

  # Try to discover waste counter slots (look for hex like 0x2f, words waste/pad)
  local waste_addrs
  waste_addrs="$(grep -oiE 'WASTE_ADDRS:\s*0x[0-9a-f]{1,2}(,0x[0-9a-f]{1,2})*|0x[0-9a-f]{1,2}' "$status_log" | sed -E 's/^WASTE_ADDRS:\s*//I' | tr ',' '\n' | grep -oiE '0x[0-9a-f]{1,2}' | sort -u | tr '\n' ',' | sed 's/,$//')"
  local hints
  hints="$(grep -iE 'waste|pad|counter' "$status_log" || true)"

  if [[ -n "$waste_addrs" ]]; then
    log "Discovered potential waste slots: $waste_addrs"
  fi
  if [[ -n "$hints" ]]; then
    log "Hints found in listing (waste/pad/counter keywords present)."
  fi

  # Attempt EEPROM dump with several possible flags
  local eeprom_file="$SNAP_DIR/EEPROM_${stamp}.bin"
  local state_file="$SNAP_DIR/STATE_${stamp}.txt"
  local dumped=0
  for flag in --dump-eeprom --dump --read-eeprom; do
    if ! reink_has_opt "$flag"; then
      continue
    fi
    local dump_cmd=("$VENV_DIR/bin/python3" -m reinkpy.epson "$flag" "$eeprom_file")
    log "Attempting EEPROM dump with: ${dump_cmd[*]}"
    if "${dump_cmd[@]}" >>"$status_log" 2>&1; then
      if [[ -s "$eeprom_file" ]]; then
        log "EEPROM snapshot saved to $eeprom_file"
        dumped=1
        break
      fi
    fi
  done

  if [[ "$dumped" -eq 0 ]]; then
    log "EEPROM dump flags not supported by this reinkpy build; saving textual state instead."
    {
      echo "# Device listing"
      cat "$status_log"
      echo
      echo "# Help output"
      "$VENV_DIR/bin/python3" -m reinkpy.epson --help || true
    } > "$state_file" 2>&1 || true
    log "State snapshot saved to $state_file"
  fi

  # Summary
  echo
  echo "Summary:"
  echo "- Status log: $status_log"
  if [[ -n "${waste_addrs}" ]]; then
    echo "- Potential waste slots: ${waste_addrs}"
  else
    echo "- Potential waste slots: none auto-detected"
  fi
  if [[ -f "$eeprom_file" && -s "$eeprom_file" ]]; then
    echo "- EEPROM: $eeprom_file"
  else
    echo "- State snapshot: $state_file"
  fi
  log "=== Epson status end @ ${stamp} ==="
}

main "$@"
