# wigle-triad — the MEDUSA triad

Three ESP32-S3 nodes, one passive WiGLE rig. Each node listens to WiFi
beacon frames (no association, no injection, nothing sent beyond the
radio's own scan behaviour) and reports what it hears over USB serial.
The host merges the three streams into one WiGLE-ready CSV.

## the nodes

| node | port | MAC | role |
|---|---|---|---|
| ADA:MEDUSA | /dev/cu.usbmodem101 | 80:b5:4e:db:3b:c4 | scan |
| VAK:MEDUSA | /dev/cu.usbmodem212101 | 80:b5:4e:f2:02:b0 | scan |
| OMN:MEDUSA | /dev/cu.usbmodem212301 | 80:b5:4e:f2:02:b4 | scan |

The names are the triad: ADA, VAK, OMN — three heads of the same MEDUSA,
three receivers of the same air.

## wire format

Each node prints, per discovered network:

```
W|bssid|ssid|auth|channel|rssi
```

The node never claims time or position — the host stamps what it can
prove (its clock, and a position only when you state it).

## build and flash

```bash
pio run -e ada -t upload --upload-port /dev/cu.usbmodem101
pio run -e vak -t upload --upload-port /dev/cu.usbmodem212101
pio run -e omn -t upload --upload-port /dev/cu.usbmodem212301
```

## run the merge

```bash
python3 host/merge.py \
  --ports /dev/cu.usbmodem101 /dev/cu.usbmodem212101 /dev/cu.usbmodem212301 \
  --lat 35.6895 --lon 139.6917 \
  --out-dir session-01
```

Ctrl-C writes `session-01/wigle-wifi.csv` in the WiGLE upload format.
Deduplication keeps the strongest RSSI per BSSID.

## honest status

| lane | status |
|---|---|
| passive WiFi scan | ✅ live on all three nodes |
| WiGLE CSV merge | ✅ live (host-side, stdlib + pyserial) |
| GPS position | ⬜ manual (`--lat/--lon`); a GPS module is the next slice |
| BLE scan (type BTLE) | ⬜ next slice |
| WiGLE upload | ⬜ you (needs a WiGLE account; ToS apply) |

## the one rule

Passive listening only. Only observe air you are allowed to be under.
The nodes send no frames, join no networks, and store nothing.

*fine touch from within · 0 + 1 · {<3,<3,<3}+1 · om mani padme hum*
