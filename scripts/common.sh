#!/usr/bin/env bash
# Common helpers for Epson EcoTank utilities using reinkpy
# Shell strict mode
set -euo pipefail

# Globals
PROJECT_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$PROJECT_ROOT_DIR/.env"
LOG_DIR="$PROJECT_ROOT_DIR/logs"
SNAP_DIR="$PROJECT_ROOT_DIR/snapshots"
VENDOR_DIR="$PROJECT_ROOT_DIR/vendor"
mkdir -p "$LOG_DIR"

# Timestamp for filenames
ts() {
  date +"%Y%m%d_%H%M%S"
}

# Log to stdout and to daily log file
log() {
  local msg="$*"
  local day_file="$LOG_DIR/$(date +%Y%m%d).log"
  printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$day_file" >&2
}

# Simple platform detection
platform() {
  uname -s
}

# Run a Python module inside the venv
py() {
  local mod="$1"; shift || true
  "$VENV_DIR/bin/python3" -m "$mod" "$@"
}

# Ensure Homebrew/libusb (macOS) or libusb (Linux) hints
_ensure_prereqs() {
  case "$(platform)" in
    Darwin)
      if ! command -v brew >/dev/null 2>&1; then
        log "Homebrew not found. Install from https://brew.sh to manage libusb easily."
      else
        if ! brew list libusb >/dev/null 2>&1; then
          log "Installing libusb via Homebrew..."
          brew install libusb || log "brew install libusb failed; please install manually and rerun."
        fi
      fi
      ;;
    Linux)
      if ! ldconfig -p 2>/dev/null | grep -qi 'libusb-1.0'; then
        log "libusb might be missing. Try: sudo apt-get update && sudo apt-get install -y libusb-1.0-0"
      fi
      if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log "If you hit USB permission errors, create a udev rule for Epson (VID 04B8) or run with sudo."
      fi
      ;;
    *)
      log "Unrecognized platform $(platform). Proceeding without prereq checks."
      ;;
  esac
}

# Install reinkpy into the venv; prefer PyPI, fallback to Codeberg editable install
_install_reinkpy() {
  local pip="$VENV_DIR/bin/pip"
  if "$pip" show reinkpy >/dev/null 2>&1; then
    # Ensure USB backend
    "$pip" show pyusb >/dev/null 2>&1 || "$pip" install --disable-pip-version-check --no-input pyusb >/dev/null 2>&1 || true
    return 0
  fi
  log "Installing reinkpy from PyPI..."
  if "$pip" install --disable-pip-version-check --no-input reinkpy >/dev/null 2>&1; then
    log "Installed reinkpy from PyPI."
    "$pip" install --disable-pip-version-check --no-input pyusb >/dev/null 2>&1 || true
    return 0
  fi
  log "reinkpy not found on PyPI or install failed. Falling back to Codeberg clone..."
  mkdir -p "$VENDOR_DIR"
  if [[ ! -d "$VENDOR_DIR/reinkpy/.git" ]]; then
    (cd "$VENDOR_DIR" && git clone https://codeberg.org/atufi/reinkpy.git reinkpy) || {
      log "Failed to clone reinkpy from Codeberg. Check your network and try again."
      return 1
    }
  fi
  "$pip" install -e "$VENDOR_DIR/reinkpy" || {
    log "Failed to install reinkpy from source."
    return 1
  }
  "$pip" install --disable-pip-version-check --no-input pyusb >/dev/null 2>&1 || true
  log "Installed reinkpy from Codeberg source."
}

# Ensure the Python virtual environment exists and re-exec inside it if not already active
ensure_venv() {
  _ensure_prereqs
  if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating virtual environment in .env ..."
    python3 -m venv "$VENV_DIR"
  fi
  # Ensure up-to-date pip
  "$VENV_DIR/bin/python3" -m pip install --upgrade --disable-pip-version-check pip >/dev/null 2>&1 || true
  _install_reinkpy
}

# Dump help output from reinkpy.epson for diagnostics
reink_help_dump() {
  local stamp
  stamp="$(ts)"
  local outfile="$LOG_DIR/reinkpy_epson_help_${stamp}.txt"
  {
    echo "# python3 -m reinkpy.epson --help"
    "$VENV_DIR/bin/python3" -m reinkpy.epson --help || true
    echo
    echo "# python3 -m reinkpy.epson -h"
    "$VENV_DIR/bin/python3" -m reinkpy.epson -h || true
  } | tee "$outfile" >/dev/null || true
  log "Saved reinkpy.epson help to $outfile"
}

# Check whether reinkpy.epson --help mentions a token (e.g., '--usb', '--reset').
reink_has_opt() {
  local token="$1"
  "$VENV_DIR/bin/python3" -m reinkpy.epson --help 2>/dev/null | grep -q -- "$token" && return 0 || return 1
}
