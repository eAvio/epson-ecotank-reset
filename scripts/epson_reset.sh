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

  # Try a few CLI variants; primary is --reset
  local tried=()
  local ok=0
  local cmds=(
    "$VENV_DIR/bin/python3 -m reinkpy.epson -v --reset $addrs"
    "$VENV_DIR/bin/python3 -m reinkpy.epson --reset $addrs"
    "$VENV_DIR/bin/python3 -m reinkpy.epson --reset-waste $addrs"
  )
  for c in "${cmds[@]}"; do
    log "Attempt: $c" | tee -a "$reset_log" >/dev/null
    if bash -c "$c" | tee -a "$reset_log"; then
      ok=1
      break
    else
      tried+=("$c")
    fi
  done

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
    addrs="$(extract_addresses_from_log "$latest")"
    if [[ -z "$addrs" ]]; then
      log "Could not auto-detect waste counter addresses."
      log "Guidance: run '$SCRIPT_DIR/epson_status.sh' and inspect the log for waste/pad counters, then rerun with --addresses 0x..,0x.."
      exit 2
    fi
    if ! validate_addresses "$addrs"; then
      log "Auto-detected addresses appear malformed: $addrs"
      exit 2
    fi
  fi

  echo "Will reset waste counters at addresses: $addrs"
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
