#!/usr/bin/env bash
# Inspect connected Epson printers, print waste-counter info, and snapshot EEPROM/state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

main() {
  ensure_venv "$@"

  mkdir -p "$SNAP_DIR"

  # Parse optional flags for status output
  local SHOW_AMBIG=0
  local CSV_REQ=0
  local CSV_OUT=""
  local SUMMARY_ONLY=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --show-ambiguous)
        SHOW_AMBIG=1; shift ;;
      --csv)
        CSV_REQ=1; shift ;;
      --csv=*)
        CSV_OUT="${1#--csv=}"; shift ;;
      --summary|--summary-only)
        SUMMARY_ONLY=1; shift ;;
      --details|--full)
        SUMMARY_ONLY=0; shift ;;
      *)
        # ignore unknown for now
        shift ;;
    esac
  done

  local stamp
  stamp="$(ts)"
  local status_log="$LOG_DIR/STATUS_${stamp}.log"

  if [[ "$CSV_REQ" -eq 1 && -z "$CSV_OUT" ]]; then
    CSV_OUT="$SNAP_DIR/COUNTERS_${stamp}.csv"
  fi

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
import sys, logging
for name in ('reinkpy', 'reinkpy.usb', 'reinkpy.d4'):
    try:
        logging.getLogger(name).setLevel(logging.WARNING)
    except Exception:
        pass
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
  waste_addrs="$(grep -oiE 'WASTE_ADDRS:\s*0x[0-9a-f]{1,2}(,0x[0-9a-f]{1,2})*|0x[0-9a-f]{1,2}' "$status_log" \
    | sed -E 's/^WASTE_ADDRS:\s*//I' \
    | tr ',' '\n' \
    | grep -oiE '0x[0-9a-f]{1,2}' \
    | sort -u \
    | tr '\n' ',' \
    | sed 's/,$//' || true)"
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

  # Human-readable counters
  echo
  echo "Human-readable:"
  if ! "$VENV_DIR/bin/python3" - "$waste_addrs" "$SHOW_AMBIG" "$CSV_OUT" "$SUMMARY_ONLY" <<'PY'
import sys, re, logging
for name in ('reinkpy', 'reinkpy.usb', 'reinkpy.d4'):
    try:
        logging.getLogger(name).setLevel(logging.WARNING)
    except Exception:
        pass
from reinkpy import UsbDevice

addrs_arg = sys.argv[1] if len(sys.argv) > 1 else ''
show_ambig = bool(int(sys.argv[2])) if len(sys.argv) > 2 and sys.argv[2] else False
csv_out = sys.argv[3] if len(sys.argv) > 3 else ''
summary_only = bool(int(sys.argv[4])) if len(sys.argv) > 4 and sys.argv[4] else False
devices = list(UsbDevice.ifind())
if not devices:
    print(' - No USB device found')
    sys.exit(1)
# Simple selection if multiple devices
d = devices[0]
if len(devices) > 1:
    print(' - Multiple USB devices found:')
    for i, dev in enumerate(devices, start=1):
        print(f"     [{i}] {dev}")
    try:
        choice = input(f"   Select device [1-{len(devices)}]: ").strip()
        idx = int(choice) - 1
        if 0 <= idx < len(devices):
            d = devices[idx]
    except Exception:
        pass
    print(f" - Using: {d}")
e = d.epson
try:
    e.configure(True)
except Exception:
    pass

model = getattr(e, 'detected_model', None) or 'Unknown'
print(' - Model:', model)

# Prefer labeled groups from spec; only fall back to raw override if no groups
entries = []
for m in getattr(e.spec, 'mem', []) or []:
    desc = m.get('desc', '')
    if re.fullmatch(r'(?i)waste counter', desc) or re.fullmatch(r'(?i)platen pad counter', desc):
        entries.append(m)

if not entries:
    # optional fallback: merged waste counters
    merged = e.spec.get_mem('waste counter')
    if merged:
        entries = [merged]

if not entries and addrs_arg:
    try:
        addrs = [int(x, 16) for x in addrs_arg.split(',') if x]
    except Exception:
        addrs = []
    if addrs:
        try:
            res = e.read_eeprom(*addrs)
        except Exception:
            print(' - Unable to read EEPROM without sudo (permissions).')
            sys.exit(1)
        print(' - Raw addresses:')
        for a, v in res:
            if v is None:
                print(f"   • addr 0x{a:02x}: NA")
            else:
                pct = (v/255.0)*100.0
                flag = ' (high)' if pct >= 90 else ''
                print(f"   • addr 0x{a:02x}: 0x{v:02x} ({pct:.1f}%){flag}")
        sys.exit(0)

if not entries:
    print(' - No waste/platen counter addresses available')
    sys.exit(1)

print(' - Counters:')
w_total = sum(1 for m in entries if re.fullmatch(r'(?i)waste counter', m.get('desc','')))
p_total = sum(1 for m in entries if re.fullmatch(r'(?i)platen pad counter', m.get('desc','')))
w_idx = 0
p_idx = 0

# Model-specific neutral counter labels and normalization (ET-181x family)
def _key(addrs):
    return tuple(int(a) for a in addrs)

counter_labels = {}
norm_caps = {}
if re.match(r'^ET-181', str(model)):
    # Map address pairs to Counter 1/2/3 and provide normalization capacities
    counter_labels[_key([0x30,0x31])] = 'Counter 1'
    norm_caps[_key([0x30,0x31])] = 141.0  # derived from user snapshot (approx)
    counter_labels[_key([0x32,0x33])] = 'Counter 2'
    norm_caps[_key([0x32,0x33])] = None   # unknown; treat sum=0 as 0%
    counter_labels[_key([0xFC,0xFD])] = 'Counter 3'
    norm_caps[_key([0xFC,0xFD])] = 1299.0 # derived from user snapshot (approx)
recognized_keys = set(counter_labels.keys())

# CSV support
def write_csv(rows):
    if not csv_out:
        return
    import os
    new_file = not os.path.exists(csv_out)
    with open(csv_out, 'a', encoding='utf-8') as f:
        if new_file:
            f.write('model,group_label,group_type,addr,value_hex,percent_255,group_sum,normalized_percent,group_max_percent\n')
        for r in rows:
            f.write(','.join(str(x) for x in r) + '\n')

csv_rows = []
for m in entries:
    desc = m.get('desc', '')
    is_platen = bool(re.search(r'(?i)platen', desc))
    # For ET-181x waste counters, only show recognized counter groups by default
    addrs = m.get('addr', [])
    k = _key(addrs)
    if not is_platen and recognized_keys and k not in recognized_keys:
        continue
    if is_platen:
        p_idx += 1
        label = 'Platen pad' + (f' #{p_idx}' if p_total > 1 else '')
    else:
        w_idx += 1
        label = 'Waste' + (f' #{w_idx}' if w_total > 1 else '')
    try:
        res = e.read_eeprom(*addrs)
    except Exception:
        print(' - Unable to read counters without sudo (permissions).')
        sys.exit(1)
    # Override label if recognized counter mapping exists
    clabel = counter_labels.get(k)
    if clabel:
        label = clabel
    # compute group metrics
    group_sum = sum((v or 0) for _, v in res if v is not None)
    cap = norm_caps.get(k)
    norm_pct = None
    if cap and cap > 0:
        norm_pct = min(100.0, (group_sum / cap) * 100.0)
    elif group_sum == 0:
        norm_pct = 0.0
    # also compute max per-address percent of 255
    max_pct = -1.0
    for _, v in res:
        if v is not None:
            pct = (v/255.0)*100.0
            if pct > max_pct:
                max_pct = pct
    if norm_pct is not None:
        summary = f' {norm_pct:.2f}% (sum {group_sum})'
    else:
        summary = f' (max {max_pct:.1f}%)' if max_pct >= 0 else ''
    print(f"   • {label}:{summary}")
    for a, v in res:
        if v is None:
            if not summary_only:
                print(f"      - addr 0x{a:02x}: NA")
            continue
        pct = (v/255.0)*100.0
        if not summary_only:
            flag = ' (high)' if pct >= 90 else ''
            print(f"      - addr 0x{a:02x}: 0x{v:02x} ({pct:.1f}%){flag}")
        csv_rows.append((model, label, 'platen' if is_platen else 'waste', f'0x{a:02x}', f'0x{v:02x}', f'{pct:.1f}', group_sum, f'{norm_pct:.2f}' if norm_pct is not None else '', f'{max_pct:.1f}' if max_pct>=0 else ''))

# Optionally include ambiguous group for diagnostics
if show_ambig:
    amb_addrs = [0x1C,0x34,0x35,0x36,0x37,0xFF]
    try:
        res = e.read_eeprom(*amb_addrs)
    except Exception:
        print('   • AMBIGUOUS: unable to read (permissions)')
        res = []
    # compute group summary for CSV consistency
    amb_sum = sum((v or 0) for _, v in res if v is not None)
    amb_max = -1.0
    for _, v in res:
        if v is not None:
            p = (v/255.0)*100.0
            if p > amb_max:
                amb_max = p
    print('   • AMBIGUOUS (spec: Waste counters (?))')
    for a, v in res:
        if v is None:
            if not summary_only:
                print(f"      - addr 0x{a:02x}: NA")
            continue
        pct = (v/255.0)*100.0
        if not summary_only:
            flag = ' (high)' if pct >= 90 else ''
            print(f"      - addr 0x{a:02x}: 0x{v:02x} ({pct:.1f}%){flag}")
        csv_rows.append((model, 'AMBIGUOUS', 'ambiguous', f'0x{a:02x}', f'0x{v:02x}', f'{pct:.1f}', amb_sum, '', f'{amb_max:.1f}' if amb_max>=0 else ''))

write_csv(csv_rows)
sys.exit(0)
PY
  then
    echo "(Retrying with sudo for USB permissions)"
    sudo "$VENV_DIR/bin/python3" - "$waste_addrs" "$SHOW_AMBIG" "$CSV_OUT" "$SUMMARY_ONLY" <<'PY'
import sys, re, logging
for name in ('reinkpy', 'reinkpy.usb', 'reinkpy.d4'):
    try:
        logging.getLogger(name).setLevel(logging.WARNING)
    except Exception:
        pass
from reinkpy import UsbDevice

addrs_arg = sys.argv[1] if len(sys.argv) > 1 else ''
show_ambig = bool(int(sys.argv[2])) if len(sys.argv) > 2 and sys.argv[2] else False
csv_out = sys.argv[3] if len(sys.argv) > 3 else ''
summary_only = bool(int(sys.argv[4])) if len(sys.argv) > 4 and sys.argv[4] else False
devices = list(UsbDevice.ifind())
if not devices:
    print(' - No USB device found')
    sys.exit(1)
d = devices[0]
if len(devices) > 1:
    print(' - Multiple USB devices found:')
    for i, dev in enumerate(devices, start=1):
        print(f"     [{i}] {dev}")
    try:
        choice = input(f"   Select device [1-{len(devices)}]: ").strip()
        idx = int(choice) - 1
        if 0 <= idx < len(devices):
            d = devices[idx]
    except Exception:
        pass
    print(f" - Using: {d}")
e = d.epson
try:
    e.configure(True)
except Exception:
    pass

model = getattr(e, 'detected_model', None) or 'Unknown'
print(' - Model:', model)

# Prefer labeled groups from spec; only fall back to raw override if no groups
entries = []
for m in getattr(e.spec, 'mem', []) or []:
    desc = m.get('desc', '')
    if re.fullmatch(r'(?i)waste counter', desc) or re.fullmatch(r'(?i)platen pad counter', desc):
        entries.append(m)

if not entries:
    merged = e.spec.get_mem('waste counter')
    if merged:
        entries = [merged]

if not entries and addrs_arg:
    try:
        addrs = [int(x, 16) for x in addrs_arg.split(',') if x]
    except Exception:
        addrs = []
    if addrs:
        try:
            res = e.read_eeprom(*addrs)
        except Exception:
            print(' - Unable to read EEPROM (read error)')
            sys.exit(1)
        print(' - Raw addresses:')
        for a, v in res:
            if v is None:
                print(f"   • addr 0x{a:02x}: NA")
            else:
                pct = (v/255.0)*100.0
                flag = ' (high)' if pct >= 90 else ''
                print(f"   • addr 0x{a:02x}: 0x{v:02x} ({pct:.1f}%){flag}")
        sys.exit(0)

if not entries:
    print(' - No waste/platen counter addresses available')
    sys.exit(1)

print(' - Counters:')
w_total = sum(1 for m in entries if re.fullmatch(r'(?i)waste counter', m.get('desc','')))
p_total = sum(1 for m in entries if re.fullmatch(r'(?i)platen pad counter', m.get('desc','')))
w_idx = 0
p_idx = 0

# Model-specific neutral counter labels and normalization (ET-181x family)
def _key(addrs):
    return tuple(int(a) for a in addrs)

counter_labels = {}
norm_caps = {}
if re.match(r'^ET-181', str(model)):
    counter_labels[_key([0x30,0x31])] = 'Counter 1'
    norm_caps[_key([0x30,0x31])] = 141.0  # approx derived
    counter_labels[_key([0x32,0x33])] = 'Counter 2'
    norm_caps[_key([0x32,0x33])] = None   # unknown; 0 sum => 0%
    counter_labels[_key([0xFC,0xFD])] = 'Counter 3'
    norm_caps[_key([0xFC,0xFD])] = 1299.0 # approx derived
recognized_keys = set(counter_labels.keys())

# CSV support
def write_csv(rows):
    if not csv_out:
        return
    import os
    new_file = not os.path.exists(csv_out)
    with open(csv_out, 'a', encoding='utf-8') as f:
        if new_file:
            f.write('model,group_label,group_type,addr,value_hex,percent_255,group_sum,normalized_percent,group_max_percent\n')
        for r in rows:
            f.write(','.join(str(x) for x in r) + '\n')

csv_rows = []
for m in entries:
    desc = m.get('desc', '')
    is_platen = bool(re.search(r'(?i)platen', desc))
    addrs = m.get('addr', [])
    k = _key(addrs)
    if not is_platen and recognized_keys and k not in recognized_keys:
        continue
    if is_platen:
        p_idx += 1
        label = 'Platen pad' + (f' #{p_idx}' if p_total > 1 else '')
    else:
        w_idx += 1
        label = 'Waste' + (f' #{w_idx}' if w_total > 1 else '')
    try:
        res = e.read_eeprom(*addrs)
    except Exception:
        print(' - Unable to read counters (read error)')
        sys.exit(1)
    # Override label if recognized mapping exists
    clabel = counter_labels.get(k)
    if clabel:
        label = clabel
    # compute group metrics
    group_sum = sum((v or 0) for _, v in res if v is not None)
    cap = norm_caps.get(k)
    norm_pct = None
    if cap and cap > 0:
        norm_pct = min(100.0, (group_sum / cap) * 100.0)
    elif group_sum == 0:
        norm_pct = 0.0
    # also compute max per-address percent of 255
    max_pct = -1.0
    for _, v in res:
        if v is not None:
            pct = (v/255.0)*100.0
            if pct > max_pct:
                max_pct = pct
    if norm_pct is not None:
        summary = f' {norm_pct:.2f}% (sum {group_sum})'
    else:
        summary = f' (max {max_pct:.1f}%)' if max_pct >= 0 else ''
    print(f"   • {label}:{summary}")
    for a, v in res:
        if v is None:
            if not summary_only:
                print(f"      - addr 0x{a:02x}: NA")
            continue
        pct = (v/255.0)*100.0
        if not summary_only:
            flag = ' (high)' if pct >= 90 else ''
            print(f"      - addr 0x{a:02x}: 0x{v:02x} ({pct:.1f}%){flag}")
        csv_rows.append((model, label, 'platen' if is_platen else 'waste', f'0x{a:02x}', f'0x{v:02x}', f'{pct:.1f}', group_sum, f'{norm_pct:.2f}' if norm_pct is not None else '', f'{max_pct:.1f}' if max_pct>=0 else ''))

if show_ambig:
    amb_addrs = [0x1C,0x34,0x35,0x36,0x37,0xFF]
    try:
        res = e.read_eeprom(*amb_addrs)
    except Exception:
        print('   • AMBIGUOUS: unable to read')
        res = []
    amb_sum = sum((v or 0) for _, v in res if v is not None)
    amb_max = -1.0
    for _, v in res:
        if v is not None:
            p = (v/255.0)*100.0
            if p > amb_max:
                amb_max = p
    print('   • AMBIGUOUS (spec: Waste counters (?))')
    for a, v in res:
        if v is None:
            if not summary_only:
                print(f"      - addr 0x{a:02x}: NA")
            continue
        pct = (v/255.0)*100.0
        if not summary_only:
            flag = ' (high)' if pct >= 90 else ''
            print(f"      - addr 0x{a:02x}: 0x{v:02x} ({pct:.1f}%){flag}")
        csv_rows.append((model, 'AMBIGUOUS', 'ambiguous', f'0x{a:02x}', f'0x{v:02x}', f'{pct:.1f}', amb_sum, '', f'{amb_max:.1f}' if amb_max>=0 else ''))

write_csv(csv_rows)
sys.exit(0)
PY
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
