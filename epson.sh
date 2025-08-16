#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Epson EcoTank Waste Counter Utility

Usage:
  $0 status                # Inspect devices, log status, snapshot
  $0 reset [--auto]        # Reset waste counters (auto-detected addresses)
  $0 reset --addresses A   # Reset with comma-separated hex addresses
  $0 reset --auto --yes    # Reset without confirmation
  $0 help                  # Show this help

Examples:
  $0 status
  $0 reset --auto
  $0 reset --addresses 0x2f,0x30,0x31 --yes
EOF
}

cmd=${1:-help}
shift || true
case "$cmd" in
  status)
    exec "$SCRIPT_DIR/scripts/epson_status.sh" "$@"
    ;;
  reset)
    exec "$SCRIPT_DIR/scripts/epson_reset.sh" "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 1
    ;;
 esac
