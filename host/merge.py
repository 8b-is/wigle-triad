#!/usr/bin/env python3
"""merge.py — the triad's host: three ESP32-S3 nodes, one WiGLE-ready CSV + N=NP telemetry snapshot.

Reads the W| and Q| lines from each node's USB serial, dedupes by BSSID keeping
the strongest RSSI, stamps the host's clock, and writes wigle-wifi.csv in
the WiGLE upload format plus triad-telemetry.json for esp32.vaked.dev.
Position is stamped only when you say where the rig is standing; otherwise
0,0 with 0 accuracy, honestly.

    python3 merge.py --ports /dev/cu.usbmodem101 /dev/cu.usbmodem212101 /dev/cu.usbmodem212301 \
        --lat 35.6895 --lon 139.6917 --out-dir session-01

Ctrl-C writes the CSV + JSON. Passive scanning only: the nodes never associate.
"""

import argparse
import csv
import datetime
import json
import os
import re
import signal
import sys

try:
    import serial
except ImportError:
    sys.exit("pyserial is required: pip install pyserial")

LINE = re.compile(r"^W\|([0-9A-Fa-f:]{17})\|(.*)\|([A-Z0-9+_-]+)\|(\d+)\|(-?\d+)$")
QLINE = re.compile(
    r"^Q\|([^|]+)\|([^|]+)\|([0-9A-Fa-f:]{17})\|(\d+)\|(\d+)\|(-?\d+)\|([0-9.]+)\|([+-0]{9})\|([0-9.]+)\|(\d+)\|(\d+)$"
)

WIGLE_HEADER = [
    "MAC", "SSID", "AuthMode", "FirstSeen", "Channel", "RSSI",
    "CurrentLatitude", "CurrentLongitude", "AltitudeMeters",
    "AccuracyMeters", "Type",
]

AUTHMAP = {
    "OPEN": "[OPEN]",
    "WEP": "[WEP]",
    "WPA-PSK": "[WPA-PSK]",
    "WPA2-PSK": "[WPA2-PSK]",
    "WPA2-EAP": "[WPA2-EAP]",
    "WPA3-SAE": "[WPA3-SAE]",
    "UNKNOWN": "[UNKNOWN]",
}


def unesc(s):
    return s.replace("\\x7c", "|").replace("\\x5c", "\\")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ports", nargs="+", required=True)
    ap.add_argument("--lat", type=float, default=0.0)
    ap.add_argument("--lon", type=float, default=0.0)
    ap.add_argument("--alt", type=float, default=0.0)
    ap.add_argument("--out-dir", default=".")
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    seen = {}  # bssid -> row
    nodes = {}  # mac -> telemetry dict
    ports = [serial.Serial(p, args.baud, timeout=1) for p in args.ports]
    print(f"listening on {len(ports)} nodes: " + ", ".join(p.name for p in ports))
    print("ctrl-c to write the CSV + triad-telemetry.json")

    def finish(signum, frame):
        rows = sorted(seen.values(), key=lambda r: r[0])
        out = f"{args.out_dir}/wigle-wifi.csv"
        with open(out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(WIGLE_HEADER)
            w.writerows(rows)
        qout = f"{args.out_dir}/triad-telemetry.json"
        with open(qout, "w") as jf:
            json.dump(
                {
                    "version": "0.3.0-ULTRA",
                    "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "networks_count": len(rows),
                    "nodes": nodes,
                },
                jf,
                indent=2,
            )
        print(f"\nwrote {len(rows)} networks to {out} and {len(nodes)} node telemetry records to {qout}")
        for p in ports:
            p.close()
        sys.exit(0)

    signal.signal(signal.SIGINT, finish)

    while True:
        for p in ports:
            line = p.readline().decode("utf-8", "replace").strip()
            if not line:
                continue
            if line.startswith("#"):
                print(f"[{p.name}] {line}")
                continue
            qm = QLINE.match(line)
            if qm:
                node, vertex, mac, seq, n_ap, mean_rssi, entropy, trits, coherence, heap, uptime = qm.groups()
                nodes[mac.upper()] = {
                    "port": p.name,
                    "node": node,
                    "vertex": vertex,
                    "mac": mac.upper(),
                    "seq": int(seq),
                    "networks": int(n_ap),
                    "mean_rssi": int(mean_rssi),
                    "entropy_bits": float(entropy),
                    "trits": trits,
                    "n_np_coherence": float(coherence),
                    "free_heap": int(heap),
                    "uptime_ms": int(uptime),
                }
                print(f"[{p.name}] {node} [{vertex}] H={entropy}b R={coherence} trits={trits} ({n_ap} APs)")
                continue
            m = LINE.match(line)
            if not m:
                continue
            bssid, ssid, auth, ch, rssi = m.group(1).upper(), unesc(m.group(2)), m.group(3), int(m.group(4)), int(m.group(5))
            first_seen = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            if bssid in seen:
                old = seen[bssid]
                if rssi > int(old[5]):
                    old[5] = rssi
                continue
            seen[bssid] = [
                bssid, ssid, AUTHMAP.get(auth, "[UNKNOWN]"), first_seen,
                ch, rssi, args.lat, args.lon, args.alt, 0, "WIFI",
            ]


if __name__ == "__main__":
    main()
