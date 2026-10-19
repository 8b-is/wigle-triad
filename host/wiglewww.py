#!/usr/bin/env python3
"""
wiglewww.py — Local HTTP + USB Serial Bridge for the 3-node ESP32-S3 MEDUSA Triad.
Serves www/index.html (synced with https://esp32.vaked.dev/) on http://127.0.0.1:8088
and exposes:
  - GET  /api/triad.json : Live status JSON from attached /dev/cu.usbmodem* ESP32-S3 nodes
  - GET  /api/wigle.csv  : Deduplicated WiGLE v1.4 CSV from live passive W| beacons
  - POST /api/cmd        : Dispatches serial commands (PING, STATUS, SCAN, TRIAD, tab 0..4, track 1..20, splash, hop)
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import pathlib
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

try:
    import serial
except ImportError:
    serial = None  # type: ignore

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
WWW_INDEX = ROOT_DIR / "www" / "index.html"
BAUD = 115200

BEACONS: dict[str, dict[str, Any]] = {}
NODES_CACHE: dict[str, dict[str, Any]] = {}


def discover_ports() -> list[str]:
    ports = sorted(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/ttyACM*"))
    return ports


def send_and_collect(ports: list[str], cmd: str, wait_s: float = 0.45) -> list[str]:
    if serial is None:
        return [f"# WARN|pyserial not installed; run via: uv run --with pyserial python host/wiglewww.py"]
    lines_out: list[str] = []
    clean = cmd.strip()
    for port in ports:
        try:
            with serial.Serial(port, BAUD, timeout=0.15) as ser:
                ser.reset_input_buffer()
                ser.write((clean + "\n").encode("utf-8"))
                ser.flush()
                deadline = time.monotonic() + wait_s
                while time.monotonic() < deadline:
                    raw = ser.readline()
                    if not raw:
                        continue
                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line:
                        continue
                    lines_out.append(line)
                    ingest_line(port, line)
        except Exception as exc:
            lines_out.append(f"# ERR|{port}|{exc}")
    return lines_out


def ingest_line(port: str, line: str) -> None:
    now_str = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if line.startswith("# JSON|"):
        try:
            obj = json.loads(line[7:])
            obj["port"] = port
            node_key = str(obj.get("medusa_node") or obj.get("node") or port)
            NODES_CACHE[node_key] = obj
        except Exception:
            pass
    elif line.startswith("{") and line.endswith("}"):
        try:
            obj = json.loads(line)
            obj["port"] = port
            node_key = str(obj.get("medusa_node") or obj.get("node") or port)
            NODES_CACHE[node_key] = obj
        except Exception:
            pass
    elif line.startswith("W|"):
        parts = line.split("|")
        if len(parts) >= 6:
            bssid = parts[1].strip().upper()
            ssid = parts[2].replace("\\x7c", "|").replace("\\x5c", "\\")
            auth = parts[3].strip()
            try:
                ch = int(parts[4])
                rssi = int(parts[5])
            except ValueError:
                return
            prev = BEACONS.get(bssid)
            if prev is None or rssi > prev["rssi"]:
                BEACONS[bssid] = {
                    "bssid": bssid,
                    "ssid": ssid,
                    "auth": auth,
                    "ch": ch,
                    "rssi": rssi,
                    "seen": now_str,
                    "port": port,
                }


def build_wigle_csv() -> str:
    header = (
        "WigleWifi-1.4,appRelease=0.8.0+medusa-omni,model=ESP32-S3-MEDUSA-TRIAD,"
        "release=v0.8.0,device=wiglewww,display=AMOLED-CO5300-SH8601,"
        "board=esp32-s3-touch-amoled,brand=8b-is\n"
        "MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type\n"
    )
    rows = []
    for bssid in sorted(BEACONS.keys()):
        r = BEACONS[bssid]
        ssid_esc = str(r["ssid"]).replace('"', '""')
        rows.append(
            f'{r["bssid"]},"{ssid_esc}",[{r["auth"]}],{r["seen"]},{r["ch"]},{r["rssi"]},35.6895,139.6917,40,0,WIFI'
        )
    return header + "\n".join(rows) + "\n"


class WigleWWWHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(f"[wiglewww] {self.address_string()} - {fmt % args}\n")

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path in ("/", "/index.html"):
            if WWW_INDEX.exists():
                self._send(200, WWW_INDEX.read_bytes(), "text/html; charset=utf-8")
            else:
                self._send(404, b"www/index.html not found", "text/plain; charset=utf-8")
            return
        if self.path in ("/api/triad.json", "/triad.json"):
            ports = discover_ports()
            lines = send_and_collect(ports, "JSON", wait_s=0.35) if ports else []
            payload = {
                "surface": "http://127.0.0.1:8088",
                "mirror": "https://esp32.vaked.dev",
                "version": "0.8.0+medusa-omni",
                "ports": ports,
                "nodes": list(NODES_CACHE.values()),
                "beacons_count": len(BEACONS),
                "raw_lines": lines,
            }
            self._send(200, json.dumps(payload, indent=2).encode("utf-8"), "application/json; charset=utf-8")
            return
        if self.path == "/api/wigle.csv":
            self._send(200, build_wigle_csv().encode("utf-8"), "text/csv; charset=utf-8")
            return
        self._send(404, b"Not Found", "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        if self.path == "/api/cmd":
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length > 0 else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
                cmd = str(body.get("cmd", "STATUS")).strip()
            except Exception:
                cmd = "STATUS"
            ports = discover_ports()
            wait_s = 1.6 if cmd.upper() == "SCAN" else 0.4
            lines = send_and_collect(ports, cmd, wait_s=wait_s) if ports else [f"# SIM|{cmd}|0 physical ports"]
            resp = {"ok": True, "cmd": cmd, "ports": ports, "lines": lines, "nodes": list(NODES_CACHE.values())}
            self._send(200, json.dumps(resp).encode("utf-8"), "application/json; charset=utf-8")
            return
        self._send(404, b"Not Found", "text/plain; charset=utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="wiglewww — Local HTTP + USB Serial Bridge for ESP32-S3 MEDUSA Triad")
    ap.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    ap.add_argument("--port", type=int, default=8088, help="HTTP port (default: 8088)")
    ap.add_argument("--once", action="store_true", help="Probe attached serial ports once, print triad JSON, and exit")
    args = ap.parse_args()

    ports = discover_ports()
    if args.once:
        lines = send_and_collect(ports, "JSON", wait_s=0.45) if ports else []
        print(
            json.dumps(
                {
                    "surface": f"http://{args.host}:{args.port}",
                    "mirror": "https://esp32.vaked.dev",
                    "version": "0.8.0+medusa-omni",
                    "ports": ports,
                    "nodes": list(NODES_CACHE.values()),
                    "lines": lines,
                },
                indent=2,
            )
        )
        return 0

    srv = ThreadingHTTPServer((args.host, args.port), WigleWWWHandler)
    print(f"[wiglewww] Serving {WWW_INDEX} on http://{args.host}:{args.port} (ports: {ports})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
