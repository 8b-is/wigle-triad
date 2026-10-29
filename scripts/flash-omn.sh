#!/usr/bin/env bash
# flash-omn.sh — Flash OMN:MEDUSA (3.2.0+omni-upz-alexai-aurora) at 115200 baud
# Enforces the waveshare.8s.is USB-CDC 115200 baud invariant (460800 drops midway)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist/omn"
ESPTOOL="${ESPTOOL:-/Library/Frameworks/Python.framework/Versions/3.12/bin/esptool}"

PORT="${1:-}"
WAIT_TICKS="${WAIT_TICKS:-7200}" # default 3600s (1 hour) at 0.5s intervals
if [ -z "$PORT" ]; then
  echo "Waiting for ESP32-S3 USB-CDC port (/dev/cu.usbmodem*)..."
  for _ in $(seq 1 "$WAIT_TICKS"); do
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

echo "Splitting firmware.bin into 320 KiB sector-aligned chunks for USB-Serial/JTAG (--no-stub)..."
python3 - "$DIST_DIR" <<'PY'
import sys, os
dist = sys.argv[1]
data = open(os.path.join(dist, "firmware.bin"), "rb").read()
chunk = 0x50000 # 327680 bytes (80 * 4096B flash sectors)
for idx, offset in enumerate(range(0, len(data), chunk)):
    open(os.path.join(dist, f"fw_part{idx}.bin"), "wb").write(data[offset:offset+chunk])
PY

echo "Flashing MEDUSA (3.2.0+omni-upz-alexai-aurora) to ${PORT} @ 115200 baud (--no-stub chunked)..."
"$ESPTOOL" --chip esp32s3 --port "$PORT" --baud 115200 --no-stub \
  --before default-reset --after no-reset write-flash \
  --flash-mode dio --flash-freq 80m --flash-size 16MB \
  0x0000 "${DIST_DIR}/bootloader.bin" \
  0x8000 "${DIST_DIR}/partitions.bin" \
  0xe000 "${DIST_DIR}/boot_app0.bin" \
  0x10000 "${DIST_DIR}/fw_part0.bin"

"$ESPTOOL" --chip esp32s3 --port "$PORT" --baud 115200 --no-stub \
  --before no-reset --after no-reset write-flash \
  --flash-mode dio --flash-freq 80m --flash-size 16MB \
  0x60000 "${DIST_DIR}/fw_part1.bin"

"$ESPTOOL" --chip esp32s3 --port "$PORT" --baud 115200 --no-stub \
  --before no-reset --after hard-reset write-flash \
  --flash-mode dio --flash-freq 80m --flash-size 16MB \
  0xb0000 "${DIST_DIR}/fw_part2.bin"
