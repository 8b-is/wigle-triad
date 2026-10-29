#!/usr/bin/env bash
# flash-omn.sh — Flash OMN:MEDUSA (3.2.0+omni-upz-alexai-aurora) at 115200 baud
# Enforces the waveshare.8s.is USB-CDC 115200 baud invariant (460800 drops midway)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist/omn"
ESPTOOL="${ESPTOOL:-/Library/Frameworks/Python.framework/Versions/3.12/bin/esptool}"

PORT="${1:-}"
if [ -z "$PORT" ]; then
  echo "Waiting for ESP32-S3 USB-CDC port (/dev/cu.usbmodem*)..."
  for _ in $(seq 1 60); do
    PORT=$(find /dev -maxdepth 1 -name "cu.usbmodem*" 2>/dev/null | sort | head -n 1 || true)
    if [ -n "$PORT" ]; then
      break
    fi
    sleep 0.5
  done
fi

if [ -z "$PORT" ] || [ ! -e "$PORT" ]; then
  echo "error: no /dev/cu.usbmodem* device detected on the USB bus" >&2
  exit 1
fi

echo "Flashing OMN:MEDUSA (3.2.0+omni-upz-alexai-aurora) to ${PORT} @ 115200 baud..."
"$ESPTOOL" --chip esp32s3 --port "$PORT" --baud 115200 \
  --before default-reset --after hard-reset write-flash -z \
  --flash-mode dio --flash-freq 80m --flash-size detect \
  0x0000 "${DIST_DIR}/bootloader.bin" \
  0x8000 "${DIST_DIR}/partitions.bin" \
  0xe000 "${DIST_DIR}/boot_app0.bin" \
  0x10000 "${DIST_DIR}/firmware.bin"
