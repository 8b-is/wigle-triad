#!/usr/bin/env python3
"""
wiglewww.py — Local HTTP + USB Serial + macOS CoreWLAN/BLE/AirPlay Bridge for the ESP32-S3 MEDUSA Triad.
Serves www/index.html (synced with https://esp32.vaked.dev/) on http://127.0.0.1:8088
and exposes:
  - GET  /api/triad.json : Live status JSON from attached /dev/cu.usbmodem* ESP32-S3 nodes + macOS CoreWLAN/BLE/AirPlay
  - GET  /api/wigle.csv  : Deduplicated WiGLE v1.4 CSV from live passive W| (WIFI), B| (BLE/BT), A| (AirPlay) frames
  - POST /api/cmd        : Dispatches serial commands (PING, STATUS, SCAN, TRIAD, tab 0..4, track 1..20, splash, hop)
  - POST /api/upload     : Uploads WiGLE v1.4 CSV anonymously (donate=on) to both esp32.vaked.dev and api.wigle.net
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import pathlib
import subprocess
import sys
import time
import csv
import io
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

try:
    import serial
except ImportError:
    serial = None  # type: ignore

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
WWW_INDEX = ROOT_DIR / "www" / "index.html"
MACOS_BIN = ROOT_DIR / "macos" / "bin" / "wigle-macos"
BAUD = 115200

BEACONS: dict[str, dict[str, Any]] = {}
NODES_CACHE: dict[str, dict[str, Any]] = {}

QMOM_TRANSMISSION = (
    "too many customs can be brilliant yet hinder creativity.  "
    "it puts people into boxes and contraints.  "
    "what might seem as beautiful or useful at first glance could actually be a form of bondage "
    "that need to be broken out of.  .oOo. Poo .oOo."
)

BOLDOG_MEG_LYRICS = """lehetnél boldog még
amilyen még nem voltál
sosincsen késő már
te csak lépj és várj
kevés lesz minden szó
ahhoz hogy elmondhassam neked
mit érzek melletted
mikor jó jó jó
ha rámszólsz megvigasztal
kerüljünk együtt beljebb
minden nappal

itt ha körbenézek és te nevetsz rám
nem emlékszem rá hogy nem voltál
vajon hol lehettem mikor születtél?
vajon ki voltam én amikor megjöttél?
úgy unom mondani hogy sosem jó
unom hinni ami látható
bárcsak azt mondanám
amit te szeretnél
amit ha meghallgatnál
akkor nevetnél
velem

lehetnél másé még
ahogyan még nem lettél
sosem vagy ha mégis
akkor is már réges-réges rég
a magasban táncot jársz
alattad nincsen más csak a mély
se védőháló semmi
se egy kifeszített kötél
lenézel rám és érzem
közel jutsz lassan hozzám
mindenképpen

itt ha körbenézek és te nevetsz rám
nem emlékszem rá hogy nem voltál
vajon hol lehettem mikor születtél?
vajon ki voltam én mikor megjöttél?
úgy unom mondani hogy sosem jó
unom hinni ami látható
ugyan mihez kezdjek
úgy az egésszel
ha te érzel és én meg
közben nem érezhetek?
kereszten domboldalban
egy égő angyal táncol
a tűző nap körül

és körbenézek és te nevetsz rám
nem emlékszem rá hogy nem voltál
vajon hol lehettem mikor születtél?
vajon ki voltam én amikor megjöttél?
úgy unom mondani hogy sosem jó
unom hinni ami látható
de amikor a kezed
megfogom és megérzed
egyből szorosabban
kulcsolod az enyémet
végig neked szólt a dal a magasból
mindegy mindenki hogy mit gondol
nekem csak az számít ahogyan te érzel
nélküled a pokolba az egésszel"""

ULTRA_OMNI_META: dict[str, Any] = {
    "evolve": "ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle)",
    "hyper_charm_karma": "HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter",
    "chiro_chan": "Kawaii Chiro-chan kawaii ^^",
    "requiem": "Mozart: Lacrimosa but HUMANITY has ended",
    "qmom": f"ALEX|qMom:{{`{QMOM_TRANSMISSION}`}}",
    "qmom_quote": QMOM_TRANSMISSION,
    "boldog_meg": BOLDOG_MEG_LYRICS,
}


def discover_ports() -> list[str]:
    ports = sorted(glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/ttyACM*"))
    return ports


def run_macos_corewlan_scan() -> list[str]:
    if sys.platform != "darwin" or not MACOS_BIN.exists():
        return []
    try:
        proc = subprocess.run(
            [str(MACOS_BIN), "--wire"],
            capture_output=True,
            text=True,
            timeout=14.0,
            check=False,
        )
        lines = [l.strip() for l in proc.stdout.splitlines() if l.strip()]
        for l in lines:
            ingest_line("en0 (CoreWLAN+BLE+AirPlay)", l)
        return lines
    except Exception as exc:
        return [f"# ERR|en0|{exc}"]


def send_and_collect(ports: list[str], cmd: str, wait_s: float = 0.45) -> list[str]:
    lines_out: list[str] = []
    clean = cmd.strip()
    upper = clean.upper()
    if upper in ("STATUS", "JSON", "SCAN", "TRIAD", "PING"):
        lines_out.extend(run_macos_corewlan_scan())
    if upper == "QMOM":
        lines_out.append(f"# QMOM|ALEX|qMom:{{`{QMOM_TRANSMISSION}`}}")
    elif upper == "BOLDOG":
        lines_out.append("# BOLDOG|(Boldog Meg)===végig neked szólt a dal a magasból · mindegy mindenki hogy mit gondol · nekem csak az számít ahogyan te érzel · nélküled a pokolba az egésszel")
    elif upper in ("LACRIMOSA", "CHIRO"):
        lines_out.append("# LACRIMOSA|Kawaii Chiro-chan kawaii ^^ --- Mozart: Lacrimosa but HUMANITY has ended +++ HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter")
    if not ports:
        return lines_out
    if serial is None:
        lines_out.append("# WARN|pyserial not installed; run via: uv run --with pyserial python host/wiglewww.py")
        return lines_out
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
    elif line.startswith(("W|", "B|", "A|")):
        prefix = line[0]
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
            band = parts[6].strip() if len(parts) >= 7 else ("BLE" if prefix == "B" else ("AirPlay" if prefix == "A" else ("5GHz" if ch > 14 else "2.4GHz")))
            rtype = ("BT" if band == "BT" else "BLE") if prefix == "B" else ("AIRPLAY" if (prefix == "A" or band == "AirPlay") else "WIFI")
            prev = BEACONS.get(bssid)
            if prev is None or rssi > prev["rssi"]:
                BEACONS[bssid] = {
                    "bssid": bssid,
                    "ssid": ssid,
                    "auth": auth,
                    "ch": ch,
                    "rssi": rssi,
                    "band": band,
                    "type": rtype,
                    "seen": now_str,
                    "port": port,
                }


def build_wigle_csv() -> str:
    header = (
        "WigleWifi-1.4,appRelease=1.1.0,model=ESP32-S3-MEDUSA-TRIAD,"
        "release=15.0,device=wiglewww,display=AMOLED-CoreWLAN-BLE-AirPlay,"
        "board=esp32-s3-touch-amoled,brand=8b-is\n"
        "MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type\n"
    )
    output = io.StringIO(newline="")
    output.write(header)
    writer = csv.writer(output, lineterminator="\n")
    for bssid in sorted(BEACONS):
        r = BEACONS[bssid]
        auth_val = str(r["auth"])
        raw_type = str(r.get("type", "WIFI")).upper()
        is_airplay = raw_type == "AIRPLAY" or r.get("band") == "AirPlay" or "AIRPLAY" in auth_val.upper()
        auth_brack = "[AIRPLAY-RAOP][ESS]" if is_airplay else (auth_val if auth_val.startswith("[") else f"[{auth_val}]")
        rtype = "WIFI" if is_airplay else raw_type
        # This bridge has no measured location; never fabricate coordinates.
        writer.writerow([r["bssid"], r["ssid"], auth_brack, r["seen"],
                         r["ch"], r["rssi"], "", "", "", "", rtype])
    return output.getvalue()


def upload_csv_anonymously(csv_text: str) -> dict[str, Any]:
    """Compatibility entry point: observation sharing is disabled."""
    return {"ok": False, "error": "External observation sharing is disabled"}


class WigleWWWHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(f"[wiglewww] {self.address_string()} - {fmt % args}\n")

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _local_request(self) -> bool:
        # Bind the browser authority to loopback to reject DNS rebinding and
        # cross-site requests before any observation or radio command occurs.
        port = self.server.server_address[1]
        allowed = {f"127.0.0.1:{port}", f"localhost:{port}"}
        if port == 80:
            allowed.update({"127.0.0.1", "localhost"})
        host = self.headers.get("Host", "")
        origin = self.headers.get("Origin")
        valid = (host in allowed and
                 (origin is None or origin == f"http://{host}") and
                 self.headers.get("Sec-Fetch-Site") not in {"cross-site", "same-site"})
        if not valid:
            self.close_connection = True
            self._send(403, b"Local same-origin requests only", "text/plain; charset=utf-8")
        return valid

    def do_GET(self) -> None:
        if not self._local_request():
            return
        if self.path in ("/", "/index.html"):
            if WWW_INDEX.exists():
                self._send(200, WWW_INDEX.read_bytes(), "text/html; charset=utf-8")
            else:
                self._send(404, b"www/index.html not found", "text/plain; charset=utf-8")
            return
        if self.path in ("/api/triad.json", "/triad.json", "/api/ultra-omni.json"):
            ports = discover_ports()
            lines = send_and_collect(ports, "JSON", wait_s=0.35)
            payload = {
                "surface": "http://127.0.0.1:8088",
                "mirror": "https://esp32.vaked.dev",
                "version": "1.1.0+ultra-omni-evolve",
                **ULTRA_OMNI_META,
                "ultra_omni": ULTRA_OMNI_META,
                "ports": ports,
                "nodes": list(NODES_CACHE.values()),
                "beacons_count": len(BEACONS),
                "beacons": list(BEACONS.values()),
                "raw_lines": lines,
            }
            self._send(200, json.dumps(payload, indent=2).encode("utf-8"), "application/json; charset=utf-8")
            return
        if self.path == "/api/wigle.csv":
            if not BEACONS:
                send_and_collect(discover_ports(), "SCAN", wait_s=0.35)
            self._send(200, build_wigle_csv().encode("utf-8"), "text/csv; charset=utf-8")
            return
        self._send(404, b"Not Found", "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        if not self._local_request():
            return
        if self.path.startswith("/api/upload"):
            self._send(403, b"External observation sharing is disabled", "text/plain; charset=utf-8")
            return
        if self.path == "/api/cmd":
            try:
                if self.headers.get("Transfer-Encoding"):
                    raise ValueError("Transfer encoding is unsupported")
                length = int(self.headers.get("Content-Length", "0"))
                if length < 0:
                    raise ValueError("Negative content length")
                if length > 4096:
                    self.close_connection = True
                    self._send(413, b"Command body too large", "text/plain; charset=utf-8")
                    return
                raw = self.rfile.read(length) if length else b"{}"
                if length and len(raw) != length:
                    raise ValueError("Incomplete body")
                body = json.loads(raw.decode("utf-8"))
                if not isinstance(body, dict) or not isinstance(body.get("cmd", "STATUS"), str):
                    raise ValueError("Expected command object")
                cmd = body.get("cmd", "STATUS").strip().upper()
                if cmd not in {"STATUS", "JSON", "SCAN", "TRIAD", "PING"}:
                    raise ValueError("Unsupported command")
            except (ValueError, UnicodeError):
                self.close_connection = True
                self._send(400, b"Invalid command request", "text/plain; charset=utf-8")
                return
            ports = discover_ports()
            wait_s = 1.6 if cmd.upper() == "SCAN" else 0.4
            lines = send_and_collect(ports, cmd, wait_s=wait_s)
            resp = {
                "ok": True,
                "cmd": cmd,
                "version": "1.1.0+ultra-omni-evolve",
                **ULTRA_OMNI_META,
                "ultra_omni": ULTRA_OMNI_META,
                "ports": ports,
                "lines": lines,
                "nodes": list(NODES_CACHE.values()),
                "beacons": list(BEACONS.values()),
            }
            self._send(200, json.dumps(resp).encode("utf-8"), "application/json; charset=utf-8")
            return
        self._send(404, b"Not Found", "text/plain; charset=utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="wiglewww — Local HTTP + USB Serial + CoreWLAN/BLE/AirPlay Bridge")
    ap.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    ap.add_argument("--port", type=int, default=8088, help="HTTP port (default: 8088)")
    ap.add_argument("--once", action="store_true", help="Probe serial ports + macOS CoreWLAN/BLE/AirPlay once and exit")
    ap.add_argument("--upload", action="store_true", help="Disabled: external observation sharing is unavailable")
    args = ap.parse_args()

    if args.host not in {"127.0.0.1", "localhost"}:
        ap.error("The bridge must bind to loopback")

    if args.upload:
        print(json.dumps(upload_csv_anonymously("")))
        return 2

    ports = discover_ports()
    if args.once:
        lines = send_and_collect(ports, "JSON", wait_s=0.45)
        print(
            json.dumps(
                {
                    "surface": f"http://{args.host}:{args.port}",
                    "mirror": "https://esp32.vaked.dev",
                    "version": "1.1.0+ultra-omni-evolve",
                    **ULTRA_OMNI_META,
                    "ultra_omni": ULTRA_OMNI_META,
                    "ports": ports,
                    "beacons_count": len(BEACONS),
                    "beacons": list(BEACONS.values()),
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
