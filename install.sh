#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure executables
chmod +x "$ROOT_DIR/epson.sh" \
           "$ROOT_DIR/scripts/common.sh" \
           "$ROOT_DIR/scripts/epson_status.sh" \
           "$ROOT_DIR/scripts/epson_reset.sh"

# macOS hint for libusb (best effort)
UNAME=$(uname -s || true)
if [[ "$UNAME" == "Darwin" ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "[hint] Homebrew not found. If you hit USB issues, install libusb via Homebrew:"
    echo "      /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo "      brew install libusb"
  else
    if ! brew list libusb >/dev/null 2>&1; then
      echo "[info] Installing libusb via Homebrew (sudo may be required by brew)..."
      brew install libusb || true
    fi
  fi
fi

# Bootstrap venv and reinkpy by running a status once (non-fatal if no device)
"$ROOT_DIR/epson.sh" status >/dev/null 2>&1 || true

echo "Install complete. Try:"
echo "  ./epson.sh status"
echo "  ./epson.sh reset --auto"
