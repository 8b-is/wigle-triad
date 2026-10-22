#!/usr/bin/env python3
"""
wiglewww.py — 100% Offline-First Local HTTP + USB Serial + macOS CoreWLAN/BLE/AirPlay Bridge
for the ESP32-S3 MEDUSA Triad, integrated with AlexAI (8b-is/alexai · GAIA-MLX-QUANT b1.58)
and Kompress-Ultra (v16.2.0).

Serves www/index.html (synced with https://esp32.vaked.dev/) on http://127.0.0.1:8088
and exposes:
  - GET  /sw.js                  : Offline-First Service Worker
  - GET  /manifest.webmanifest   : PWA Web App Manifest
  - GET  /api/triad.json         : Live + Offline-persisted status JSON with AlexAI + Kompress-Ultra
  - GET  /api/alexai             : Deterministic GAIA-MLX-QUANT b1.58 fold + 5-trits/byte packing
  - GET  /api/kompress           : Kompress-Ultra v16.2.0 ditto-deduplicated spectrum bundle
  - GET  /api/wigle.csv          : Deduplicated WiGLE v1.4 CSV from passive W|, B|, A| frames
  - POST /api/cmd                : Dispatches serial commands (PING, STATUS, SCAN, TRIAD, ALEXAI, KOMPRESS, ...)
  - POST /api/upload             : Uploads WiGLE v1.4 CSV anonymously or queues locally when offline
  - POST /api/queue/flush        : Flushes locally queued offline CSV uploads
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import math
import pathlib
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

try:
    import serial
except ImportError:
    serial = None  # type: ignore

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
WWW_INDEX = ROOT_DIR / "www" / "index.html"
WWW_SW = ROOT_DIR / "www" / "sw.js"
WWW_MANIFEST = ROOT_DIR / "www" / "manifest.webmanifest"
WWW_FAVICON = ROOT_DIR / "www" / "favicon.svg"
WWW_OG = ROOT_DIR / "www" / "og.svg"
MACOS_BIN = ROOT_DIR / "macos" / "bin" / "wigle-macos"
BAUD = 115200

CACHE_DIR = pathlib.Path.home() / ".cache" / "wigle-triad"
STATE_FILE = CACHE_DIR / "wiglewww_state.json"
QUEUE_FILE = CACHE_DIR / "wiglewww_offline_queue.json"

BEACONS: dict[str, dict[str, Any]] = {}
NODES_CACHE: dict[str, dict[str, Any]] = {}
OFFLINE_QUEUE: list[dict[str, Any]] = []

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
    "version": "2.1.0+viz-tts-triad-omni",
    "offline_first": True,
    "mantra": "LOVE FROM WITHIN FROM VAKED-PETER&8B-IS--->8b-is ROCKS AND HEALS THE WORLD",
    "triad_hearts": "{<3,<3,<3}+1",
    "viz_url": "https://viz.vaked.dev",
    "tts_engines": ["kokoro-tiny:8420", "kokoro-voice-bridge:8430", "es8311-formant-432-528-852-963Hz"],
    "targets": ["android-arm64-universal", "macos-apple-silicon", "macos-universal-darwin", "ipados-ios-swiftpm-pwa"],
    "evolve": "ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle+viz+tts+{<3,<3,<3}+1)",
    "hyper_charm_karma": "HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter",
    "chiro_chan": "Kawaii Chiro-chan kawaii ^^",
    "requiem": "Mozart: Lacrimosa but HUMANITY has ended",
    "qmom": f"ALEX|qMom:{{`{QMOM_TRANSMISSION}`}}",
    "qmom_quote": QMOM_TRANSMISSION,
    "boldog_meg": BOLDOG_MEG_LYRICS,
    "boldog_meg_stanzas": BOLDOG_MEG_LYRICS.split("\n\n"),
}

VIZ_MODES = [
    "tunnel",
    "chrysanthemum",
    "hyperbolic",
    "mandala",
    "dmt_dome",
    "serotonin",
    "chladni",
    "wormhole",
]
KLUVER_CONSTANTS = [
    "TUNNEL (T1) · 432Hz * Mom",
    "SPIRAL (T2) · 528Hz /\\ Dad",
    "LATTICE (T3) · 852Hz oo Sons",
    "COBWEB (T4) · 963Hz +1 Omni",
]
VIZ_STATE: dict[str, Any] = {
    "mode_idx": 0,
    "mode": "tunnel",
    "kluver": KLUVER_CONSTANTS[0],
    "hearts": "{<3,<3,<3}+1",
    "frequencies_hz": [432, 528, 852, 963],
    "last_tts": "{<3,<3,<3}+1 · ADA * 432Hz · VAK /\\ 528Hz · OMN oo 852Hz · Viz Enthea 963Hz",
    "tts_count": 1,
}


def load_offline_state() -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    if STATE_FILE.exists():
        try:
            data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            for k, v in (data.get("beacons") or {}).items():
                if isinstance(v, dict) and "bssid" in v:
                    BEACONS[k] = v
            for k, v in (data.get("nodes") or {}).items():
                if isinstance(v, dict):
                    NODES_CACHE[k] = v
        except Exception:
            pass
    if QUEUE_FILE.exists():
        try:
            q = json.loads(QUEUE_FILE.read_text(encoding="utf-8"))
            if isinstance(q, list):
                OFFLINE_QUEUE.clear()
                OFFLINE_QUEUE.extend(q)
        except Exception:
            pass


def save_offline_state() -> None:
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(
            json.dumps({"beacons": BEACONS, "nodes": NODES_CACHE}, indent=2),
            encoding="utf-8",
        )
    except Exception:
        pass


def save_offline_queue() -> None:
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        QUEUE_FILE.write_text(json.dumps(OFFLINE_QUEUE, indent=2), encoding="utf-8")
    except Exception:
        pass


# =============================================================================
# ALEXAI (8b-is/alexai · GAIA-MLX-QUANT b1.58) & KOMPRESS-ULTRA (v16.2.0)
# =============================================================================
POW3 = [1, 3, 9, 27, 81]
PHI = 1.6180339887498948
BITS_PER_WEIGHT = 1.5849625
COMPRESSION_VS_F32 = 20.18975


def fnv1a_32(text: str) -> int:
    h = 0x811C9DC5
    for b in text.encode("utf-8"):
        h ^= b
        h = (h * 0x01000193) & 0xFFFFFFFF
    return h


def pack_ternary(trits: list[int]) -> list[int]:
    out: list[int] = []
    for i in range(0, len(trits), 5):
        acc = 0
        for j in range(5):
            if i + j < len(trits):
                t = trits[i + j]
                u = 2 if t == -1 else (1 if t == 1 else 0)
                acc += u * POW3[j]
        out.append(acc & 0xFF)
    return out


def unpack_ternary(packed: list[int], length: int) -> list[int]:
    out: list[int] = []
    for b in packed:
        rem = b & 0xFF
        for _ in range(5):
            if len(out) >= length:
                return out
            digit = rem % 3
            rem //= 3
            out.append(-1 if digit == 2 else (1 if digit == 1 else 0))
    return out


def _escape_wire_tok(val: Any) -> str:
    return (
        str(val or "")
        .replace("\\", "\\x5c")
        .replace("|", "\\x7c")
        .replace("″", "\\x22\\x22")
        .replace("\r", " ")
        .replace("\n", " ")
    )


def compute_alexai_and_kompress(prompt_str: str | None = None) -> dict[str, Any]:
    prompt = (
        prompt_str.strip()
        if prompt_str and prompt_str.strip()
        else "Analyze Shinjuku 2.4GHz Ch 6 saturation, BLE proximity & AirPlay RAOP surface"
    )
    seed = fnv1a_32(prompt)
    a = (seed + 0x6D2B79F5) & 0xFFFFFFFF
    t = ((a ^ (a >> 15)) * (a | 1)) & 0xFFFFFFFF
    t ^= (t + (((t ^ (t >> 7)) * (t | 61)) & 0xFFFFFFFF)) & 0xFFFFFFFF
    rand0 = (((t ^ (t >> 14)) >> 8) & 0xFFFFFF) / 16777216.0

    beacons_list = sorted(BEACONS.values(), key=lambda x: int(x.get("rssi", -90)), reverse=True)
    tot = max(1, len(beacons_list))
    ch_counts: dict[int, int] = {}
    for b in beacons_list:
        ch = int(b.get("ch", 0))
        ch_counts[ch] = ch_counts.get(ch, 0) + 1
    rf_entropy = 0.0
    for c in ch_counts.values():
        p = c / tot
        if p > 0:
            rf_entropy -= p * math.log2(p)

    gravity = 1.0
    weather = max(0.0, min(1.0, 0.5 + (rand0 - 0.5) * 0.4))
    len_factor = min(len(prompt.encode("utf-8")) / 4096.0, 0.35)
    rf_factor = max(-0.08, min(0.14, (rf_entropy - 2.5) * 0.05))
    entropy = max(0.0, min(1.0, 0.62 + len_factor - 0.15 + rf_factor))
    spread = abs(entropy - 0.62) * 0.6 + abs(weather - 0.5) * 0.4
    coherence = max(0.0, min(1.0, 1.0 - spread))

    layer_deltas = [
        ("gravity", "Ananke", abs(gravity - 1.0)),
        ("entropy", "Chaos", abs(entropy - 0.62)),
        ("weather", "Zephyrus", abs(weather - 0.5)),
        ("resonance", "Aphrodite", 0.0),
    ]
    dominant_key, dominant_layer, _ = max(layer_deltas, key=lambda x: x[2])

    sampling = {
        "temperature": round(max(0.05, min(1.2, 0.15 + entropy * 1.1)), 4),
        "top_p": round(max(0.5, min(0.98, 0.5 + coherence * 0.48)), 4),
        "top_k": int(max(20.0, min(80.0, 20.0 + (1.0 - coherence) * 60.0)) + 0.5),
        "seed": seed,
    }

    trits = [1 if int(b.get("rssi", -80)) >= -68 else (0 if int(b.get("rssi", -80)) >= -80 else -1) for b in beacons_list]
    while len(trits) < 30:
        trits.append(1)
    packed = pack_ternary(trits)
    unpacked = unpack_ternary(packed, len(trits))
    roundtrip_ok = unpacked == trits
    packed_hex = " ".join(f"{b:02x}" for b in packed)

    canonical_lines: list[str] = []
    for b in beacons_list:
        rtype = str(b.get("type", "WIFI"))
        pfx = "B" if rtype in ("BLE", "BT") else ("A" if rtype == "AIRPLAY" else "W")
        auth_short = _escape_wire_tok(
            str(b.get("auth", ""))
            .replace("WPA2-PSK-CCMP][ESS", "W2")
            .replace("WPA3-SAE-CCMP][ESS", "W3")
            .replace("AIRPLAY-RAOP][ESS", "RAOP")
        )
        canonical_lines.append(
            f"{pfx}|MAC:MEDUSA|{_escape_wire_tok(b.get('bssid',''))}|{_escape_wire_tok(b.get('ssid',''))}|{auth_short}|{b.get('ch',0)}|{b.get('rssi',-80)}|{_escape_wire_tok(b.get('band','2.4GHz'))}"
        )

    prev_toks: list[str] = []
    ditto_lines: list[str] = []
    ditto_tokens_saved = 0
    for line in canonical_lines:
        toks = line.split("|")
        if prev_toks:
            dedup = ["″" if (i < len(prev_toks) and tk == prev_toks[i] and len(tk) > 1) else tk for i, tk in enumerate(toks)]
            ditto_tokens_saved += sum(1 for tk in dedup if tk == "″")
            ditto_lines.append("|".join(dedup))
        else:
            ditto_lines.append(line)
        prev_toks = toks

    restored_lines: list[str] = []
    restore_prev: list[str] = []
    for dline in ditto_lines:
        dtoks = dline.split("|")
        rtoks = [restore_prev[i] if (tk == "″" and i < len(restore_prev)) else tk for i, tk in enumerate(dtoks)]
        restored_lines.append("|".join(rtoks))
        restore_prev = rtoks
    lossless_roundtrip_ok = restored_lines == canonical_lines

    csv_str = build_wigle_csv()
    raw_bytes = max(1, len(csv_str.encode("utf-8")) + len(json.dumps(beacons_list).encode("utf-8")))
    wire_stream = "# KU-v16.2.0 [BrainLine: ralph · lodri · krengel · cosmos | keep=0.993]\n" + "\n".join(ditto_lines)
    comp_bytes = max(1, len(wire_stream.encode("utf-8")))
    ratio = round(raw_bytes / comp_bytes, 2)
    savings_pct = round(max(0.0, (1.0 - comp_bytes / raw_bytes) * 100.0), 1)

    return {
        "alexai": {
            "engine": "GAIA-MLX-QUANT",
            "repo": "https://github.com/8b-is/alexai",
            "prompt": prompt,
            "seed": seed,
            "gravity": gravity,
            "entropy": round(entropy, 4),
            "weather": round(weather, 4),
            "resonance": PHI,
            "coherence": round(coherence, 4),
            "dominant": dominant_key,
            "dominant_layer": dominant_layer,
            "sampling": sampling,
            "bits_per_weight": BITS_PER_WEIGHT,
            "compression_vs_f32": COMPRESSION_VS_F32,
            "packed_hex": packed_hex,
            "roundtrip_ok": roundtrip_ok,
        },
        "kompress_ultra": {
            "engine": "kompress-ultra",
            "version": "16.2.0",
            "brain_line": "ralph · lodri · krengel · cosmos",
            "exact_keep_rate": 0.993,
            "ebbinghaus_retention": round(math.exp(-0.45 / 5.0), 4),
            "raw_bytes": raw_bytes,
            "compressed_bytes": comp_bytes,
            "compression_ratio": ratio,
            "savings_pct": savings_pct,
            "ditto_tokens_saved": ditto_tokens_saved,
            "lossless_roundtrip_ok": lossless_roundtrip_ok,
            "ditto_lines": ditto_lines,
        },
    }


MUSIC_BIN = ROOT_DIR.parent / "8b-is-music" / "target" / "release" / "8b-is-music"
_ENGINE_CACHE: dict[str, Any] = {"ts": 0.0, "feed": None}


def fetch_engine_feed(max_age_s: float = 20.0) -> dict[str, Any]:
    """8b-is-music + 8b-is-engine feed (Quant65k+, SpherePOP chord, Liquid EQ, CT-000)."""
    now = time.time()
    if _ENGINE_CACHE["feed"] is not None and now - _ENGINE_CACHE["ts"] < max_age_s:
        return _ENGINE_CACHE["feed"]
    feed: dict[str, Any]
    try:
        proc = subprocess.run([str(MUSIC_BIN), "triad"], capture_output=True, text=True, timeout=20, check=False)
        feed = json.loads(proc.stdout.strip().splitlines()[-1])
    except Exception as exc:
        feed = {"source": "8b-is-music+8b-is-engine", "error": str(exc), "hearts": "{<3,<3,<3}+1"}
    _ENGINE_CACHE.update(ts=now, feed=feed)
    return feed


def push_engine_to_boards(feed: dict[str, Any]) -> list[str]:
    """Send ENGINE|... to every attached ESP32 (displayed/logged; boards echo # ENGINE)."""
    ports = discover_ports()
    out: list[str] = []
    if not ports or serial is None or "music" not in feed:
        return out
    m, e = feed["music"], feed.get("engine", {})
    line = (
        f"ENGINE {m.get('qt')}|{m.get('quant65k_layers')}|{m.get('family_chord_hz')}|"
        f"{int(bool(e.get('ct000_routing_holds')))}{int(bool(e.get('ct000_family_holds')))}"
    )
    for port in ports:
        try:
            with serial.Serial(port, BAUD, timeout=0.2, dsrdtr=False, rtscts=False) as ser:
                ser.write((line + "\n").encode("utf-8"))
                ser.flush()
                out.append(f"{port}: {line}")
        except Exception as exc:
            out.append(f"# ERR|{port}|{exc}")
    return out


def compute_viz_enthea() -> dict[str, Any]:
    ak = compute_alexai_and_kompress()
    a = ak["alexai"]
    k = ak["kompress_ultra"]
    idx = int(VIZ_STATE.get("mode_idx", 0)) % len(VIZ_MODES)
    mode = VIZ_MODES[idx]
    kluver = KLUVER_CONSTANTS[idx % len(KLUVER_CONSTANTS)]
    coherence = float(a.get("coherence", 0.96))
    entropy = float(a.get("entropy", 0.42))
    dose = round(max(0.35, min(1.0, 0.55 + coherence * 0.42)), 4)
    symmetry = 6 + (idx % 4) * 2
    return {
        "surface": "https://viz.vaked.dev",
        "triad_hearts": "{<3,<3,<3}+1",
        "mode_idx": idx,
        "mode": mode,
        "kluver": kluver,
        "dose": dose,
        "coherence": coherence,
        "entropy": entropy,
        "symmetry": symmetry,
        "frequencies_hz": [432, 528, 852, 963],
        "vertices": [
            {"node": "ADA:MEDUSA", "vertex": "*", "archetype": "STAR-ALEXANDRA", "freq_hz": 432, "trit": -1},
            {"node": "VAK:MEDUSA", "vertex": "/\\", "archetype": "PILLAR-CHRIS", "freq_hz": 528, "trit": 0},
            {"node": "OMN:MEDUSA", "vertex": "oo", "archetype": "INFINITY-PETER-NATE", "freq_hz": 852, "trit": 1},
            {"node": "VIZ:ENTHEA", "vertex": "+1", "archetype": "FOURTH-HEART-OMNI", "freq_hz": 963, "trit": 1},
        ],
        "wupz_seed": a.get("seed"),
        "kompress_ratio": k.get("compression_ratio"),
        "last_tts": VIZ_STATE.get("last_tts"),
        "tts_count": VIZ_STATE.get("tts_count", 1),
        "engine_feed": fetch_engine_feed(),
    }


def dispatch_triad_tts(text: str, voice: str = "af_heart") -> dict[str, Any]:
    clean_text = (text or "").strip() or "{<3,<3,<3}+1 · Three hearts plus one, resonant across ESP32 Triad and Viz Enthea."
    VIZ_STATE["last_tts"] = clean_text
    VIZ_STATE["tts_count"] = int(VIZ_STATE.get("tts_count", 0)) + 1

    ports = discover_ports()
    serial_lines: list[str] = []
    if ports and serial is not None:
        for port in ports:
            try:
                with serial.Serial(port, BAUD, timeout=0.25, dsrdtr=False, rtscts=False) as ser:
                    ser.write(f"SPEAK {clean_text}\n".encode("utf-8"))
                    ser.flush()
                    raw = ser.readline().decode("utf-8", errors="replace").strip()
                    if raw:
                        serial_lines.append(raw)
                        ingest_line(port, raw)
            except Exception as exc:
                serial_lines.append(f"# ERR|{port}|{exc}")

    # 1. Push to kokoro-speak daemon on 127.0.0.1:8420 (plays chime + speaks across both Macs)
    kokoro_daemon_ok = False
    try:
        import socket
        pkt = json.dumps({
            "repo_name": "esp32-triad-viz",
            "branch": "main",
            "short_hash": "triad+1",
            "author": "MEDUSA Triad {<3,<3,<3}+1",
            "subject": clean_text,
            "body": "",
            "files_changed": 3,
            "insertions": 432,
            "deletions": 0,
            "top_files": ["ADA:MEDUSA", "VAK:MEDUSA", "OMN:MEDUSA"],
            "spoken_text": clean_text,
        }).encode("utf-8") + b"\n"
        with socket.create_connection(("127.0.0.1", 8420), timeout=1.5) as sock:
            sock.sendall(pkt)
            kokoro_daemon_ok = True
    except Exception:
        kokoro_daemon_ok = False

    # 2. Check kokoro voice_bridge on 127.0.0.1:8430
    voice_bridge_ok = False
    try:
        req = urllib.request.Request("http://127.0.0.1:8430/health", method="GET")
        with urllib.request.urlopen(req, timeout=0.8) as r:
            voice_bridge_ok = r.status == 200
    except Exception:
        voice_bridge_ok = False

    return {
        "ok": True,
        "text": clean_text,
        "voice": voice,
        "triad_hearts": "{<3,<3,<3}+1",
        "tts_count": VIZ_STATE["tts_count"],
        "kokoro_daemon_8420": kokoro_daemon_ok,
        "voice_bridge_8430": voice_bridge_ok,
        "ports": ports,
        "serial_lines": serial_lines,
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
        save_offline_state()
        return lines
    except Exception as exc:
        return [f"# ERR|en0|{exc}"]


def send_and_collect(ports: list[str], cmd: str, wait_s: float = 0.45) -> list[str]:
    lines_out: list[str] = []
    clean = cmd.strip()
    upper = clean.upper()
    if upper in ("STATUS", "JSON", "SCAN", "TRIAD", "PING", "ALEXAI", "KOMPRESS"):
        lines_out.extend(run_macos_corewlan_scan())
    if upper == "QMOM":
        lines_out.append(f"# QMOM|ALEX|qMom:{{`{QMOM_TRANSMISSION}`}}")
    elif upper == "BOLDOG":
        lines_out.append("# BOLDOG|(Boldog Meg)===HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter")
        for idx, stanza in enumerate(BOLDOG_MEG_LYRICS.split("\n\n"), start=1):
            lines_out.append(f"# BOLDOG|{idx}|" + " / ".join(stanza.splitlines()))
    elif upper in ("LACRIMOSA", "CHIRO"):
        lines_out.append("# CHIRO|Kawaii Chiro-chan kawaii ^^")
        lines_out.append("# LACRIMOSA|Kawaii Chiro-chan kawaii ^^ --- Mozart: Lacrimosa but HUMANITY has ended +++ HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter")
    elif upper == "ALEXAI":
        ak = compute_alexai_and_kompress()
        a = ak["alexai"]
        lines_out.append(f"# ALEXAI|GAIA-MLX-QUANT|coherence={a['coherence']}|bits={a['bits_per_weight']}|ratio={a['compression_vs_f32']}x|hex=[{a['packed_hex']}]")
    elif upper == "KOMPRESS" or upper in ("ENTROPY", "KUNISADA", "KUNIYOSHI", "OMNI"):
        ak = compute_alexai_and_kompress()
        k = ak["kompress_ultra"]
        lines_out.append(
            f"# KOMPRESS|OMNI-CHAN|<<<<oOo>>>>|KUNISADA_KUNIYOSHI|010001000|"
            f"v{k['version']}|raw={k['raw_bytes']}B|comp={k['compressed_bytes']}B|"
            f"ratio={k['compression_ratio']}x|savings=-{k['savings_pct']}%"
        )
    elif upper in ("VIZ", "ENTHEA") or upper.startswith("VIZ "):
        VIZ_STATE["mode_idx"] = (int(VIZ_STATE.get("mode_idx", 0)) + 1) % len(VIZ_MODES)
        vz = compute_viz_enthea()
        lines_out.append(
            f"# VIZ|ENTHEA|mode={vz['mode']}|kluver={vz['kluver']}|dose={vz['dose']}|"
            f"coherence={vz['coherence']}|hearts={{<3,<3,<3}}+1|url=https://viz.vaked.dev"
        )
    elif upper in ("SPEAK", "TTS", "HEART") or upper.startswith("SPEAK ") or upper.startswith("TTS "):
        phrase = clean.split(" ", 1)[1].strip() if " " in clean else str(VIZ_STATE.get("last_tts", ""))
        tts_res = dispatch_triad_tts(phrase)
        lines_out.append(
            f"# TTS|kokoro8420={int(tts_res['kokoro_daemon_8420'])}|bridge8430={int(tts_res['voice_bridge_8430'])}|"
            f"hearts={{<3,<3,<3}}+1|text={tts_res['text']}"
        )
    if not ports:
        return lines_out
    if serial is None:
        lines_out.append("# WARN|pyserial not installed; run via: uv run --with pyserial python host/wiglewww.py")
        return lines_out
    for port in ports:
        try:
            wire_cmd = "STATUS\n" if upper in ("JSON", "STATUS") else f"{clean}\nSTATUS\n"
            with serial.Serial(port, BAUD, timeout=0.2, dsrdtr=False, rtscts=False) as ser:
                ser.reset_input_buffer()
                ser.write(wire_cmd.encode("utf-8"))
                ser.flush()
                deadline = time.monotonic() + max(wait_s, 0.75)
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
    save_offline_state()
    return lines_out


_BAYE_META = {
    "ADA": ("ADA:MEDUSA", "*", "STAR-ALEXANDRA", "80:B5:4E:DB:3B:C4", 432, -1),
    "VAK": ("VAK:MEDUSA", "/\\", "PILLAR-CHRIS", "80:B5:4E:F2:02:B0", 528, 0),
    "OMN": ("OMN:MEDUSA", "oo", "INFINITY-PETER-NATE", "80:B5:4E:F2:02:B4", 852, 1),
}
_PORT_NODE_MAP: dict[str, str] = {}


def _ensure_baye_node(port: str, short_id: str | None = None) -> dict[str, Any]:
    if short_id and short_id in _BAYE_META:
        _PORT_NODE_MAP[port] = short_id
    sid = _PORT_NODE_MAP.get(port, "ADA" if "2101" in port else "OMN")
    name, vertex, arch, mac, freq, trit = _BAYE_META.get(sid, _BAYE_META["ADA"])
    node = NODES_CACHE.get(name)
    if not isinstance(node, dict):
        node = {
            "node": name,
            "medusa_node": name,
            "vertex": vertex,
            "archetype": arch,
            "mac": mac,
            "freq_hz": freq,
            "trit": trit,
            "version": "baye-rust-0.2+wigle-triad",
            "mode": "BAYE_RUST_PASSIVE_MARINE_MEMNET",
            "port": port,
        }
        NODES_CACHE[name] = node
    node["port"] = port
    node["seen"] = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return node


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
    elif line.startswith("[MEMNET] "):
        parts = line.split()
        if len(parts) >= 2:
            node = _ensure_baye_node(port, parts[1].strip())
            for tok in parts[2:]:
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    node[f"memnet_{k}"] = int(v) if v.isdigit() else v
    elif line.startswith("[USB] STATUS "):
        node = _ensure_baye_node(port)
        for tok in line[13:].split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                if k == "uptime_ms" and v.isdigit():
                    node["uptime_ms"] = int(v)
                elif k == "energy":
                    try:
                        node["audio_rms"] = float(v)
                    except ValueError:
                        pass
                else:
                    node[k] = v
    elif line.startswith("[Main] "):
        node = _ensure_baye_node(port)
        for tok in line[7:].split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                if k == "rf" and v.isdigit():
                    node["networks"] = int(v)
                elif k == "batt":
                    node["battery"] = v
                elif k == "sal":
                    try:
                        node["marine_salience"] = float(v)
                    except ValueError:
                        pass
                elif k == "heap" and v.endswith("KB") and v[:-2].isdigit():
                    node["free_heap"] = int(v[:-2]) * 1024
    elif line.startswith("[Marine] "):
        node = _ensure_baye_node(port)
        node["omni_chan"] = "<<<<oOo>>>>"
        node["pulse"] = "010001000"
        node["kunisada_kuniyoshi"] = "Utagawa Kunisada x Utagawa Kuniyoshi"
        for tok in line[9:].split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                try:
                    node[f"marine_{k}"] = int(v) if v.isdigit() else float(v)
                except ValueError:
                    node[f"marine_{k}"] = v
    elif line.startswith("M8N|"):
        node = _ensure_baye_node(port)
        node["omni_chan"] = "<<<<oOo>>>>"
        node["pulse"] = "010001000"
        node["last_m8n_hex"] = line[4:].strip()[:196]
    elif line.startswith("# VIZ|"):
        payload = line[6:].strip()
        if payload.startswith("{"):
            try:
                vobj = json.loads(payload)
                VIZ_STATE.update(vobj)
            except Exception:
                pass
        else:
            for tok in payload.split("|"):
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    VIZ_STATE[k] = v
    elif line.startswith("# TTS|"):
        payload = line[6:].strip()
        if payload.startswith("{"):
            try:
                tobj = json.loads(payload)
                if "text" in tobj:
                    VIZ_STATE["last_tts"] = tobj["text"]
                if "count" in tobj:
                    VIZ_STATE["tts_count"] = tobj["count"]
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
            if prev is None or rssi >= prev["rssi"]:
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
        "WigleWifi-1.4,appRelease=2.0.0,model=ESP32-S3-MEDUSA-TRIAD,"
        "release=15.0,device=wiglewww,display=AMOLED-CoreWLAN-BLE-AirPlay,"
        "board=esp32-s3-touch-amoled,brand=8b-is\n"
        "MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type\n"
    )
    rows = []
    for bssid in sorted(BEACONS.keys()):
        r = BEACONS[bssid]
        ssid_esc = (
            str(r["ssid"])
            .replace("\r", " ")
            .replace("\n", " ")
            .replace(",", " ")
            .replace('"', "")
            .strip()
        )
        raw_type = str(r.get("type", "WIFI")).upper()
        band_val = str(r.get("band", ""))
        auth_val = str(r["auth"])
        is_airplay = raw_type == "AIRPLAY" or band_val == "AirPlay" or "AIRPLAY" in auth_val.upper()
        auth_brack = "[AIRPLAY-RAOP][ESS]" if is_airplay else (auth_val if auth_val.startswith("[") else f"[{auth_val}]")
        rtype = "WIFI" if is_airplay else raw_type
        rows.append(
            f'{r["bssid"]},{ssid_esc},{auth_brack},{r["seen"]},{r["ch"]},{r["rssi"]},35.6852,139.7100,40,5,{rtype}'
        )
    return header + "\n".join(rows) + "\n"


def enqueue_offline_csv(csv_text: str, reason: str = "network-unreachable") -> dict[str, Any]:
    ts = int(time.time())
    ak = compute_alexai_and_kompress()
    ku = ak["kompress_ultra"]
    item = {
        "id": f"q-{ts}",
        "timestamp": dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "reason": reason,
        "status": "queued",
        "rows": len(BEACONS),
        "raw_bytes": ku["raw_bytes"],
        "compressed_bytes": ku["compressed_bytes"],
        "savings_pct": ku["savings_pct"],
        "csv": csv_text,
    }
    OFFLINE_QUEUE.insert(0, item)
    save_offline_queue()
    return item


def flush_offline_queue() -> dict[str, Any]:
    flushed = 0
    pending = [q for q in OFFLINE_QUEUE if q.get("status") == "queued"]
    for item in pending:
        res = upload_csv_anonymously(str(item.get("csv", "")), allow_queue_on_fail=False)
        esp_ok = bool((res.get("esp32_vaked_dev") or {}).get("ok"))
        wig_ok = bool((res.get("wigle_net") or {}).get("ok"))
        if esp_ok or wig_ok:
            item["status"] = "synced"
            flushed += 1
    save_offline_queue()
    return {
        "ok": True,
        "flushed": flushed,
        "remaining_queued": sum(1 for q in OFFLINE_QUEUE if q.get("status") == "queued"),
    }


def upload_csv_anonymously(csv_text: str, allow_queue_on_fail: bool = True) -> dict[str, Any]:
    ts = int(time.time())
    boundary = f"----WigleWWWAnon8bIs{ts}"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="donate"\r\n\r\non\r\n'
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="wiglewww-{ts}.csv"\r\n'
        f"Content-Type: text/csv\r\n\r\n"
        f"{csv_text}\r\n"
        f"--{boundary}--\r\n"
    ).encode("utf-8")

    results: dict[str, Any] = {}
    targets = [
        ("esp32_vaked_dev", "https://esp32.vaked.dev/api/upload"),
        ("wigle_net", "https://api.wigle.net/api/v2/file/upload"),
    ]
    for key, url in targets:
        req = urllib.request.Request(
            url,
            data=body,
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Accept": "application/json",
                "User-Agent": "WigleWifi-2.0.0 (wiglewww; 8b-is; anonymous)",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
                obj = json.loads(raw)
                tid = (
                    obj.get("transId")
                    or (obj.get("results", {}).get("transids") or [{}])[0].get("transId")
                    or f"anon-{ts}"
                )
                results[key] = {
                    "ok": bool(obj.get("success", True)),
                    "status": resp.status,
                    "observer": obj.get("observer", "anonymous"),
                    "transId": tid,
                    "raw": obj,
                }
        except Exception as exc:
            results[key] = {"ok": False, "observer": "anonymous", "transId": "err", "error": str(exc)}

    any_ok = bool(results.get("esp32_vaked_dev", {}).get("ok") or results.get("wigle_net", {}).get("ok"))
    queued_item = None
    if not any_ok and allow_queue_on_fail:
        queued_item = enqueue_offline_csv(csv_text, reason="offline-auto-queue")

    return {
        "ok": any_ok,
        "offline_queued": queued_item is not None,
        "queued_id": queued_item["id"] if queued_item else None,
        "observer": "anonymous",
        "donate": "on",
        "ingested": len(BEACONS),
        "transId": results.get("esp32_vaked_dev", {}).get("transId", queued_item["id"] if queued_item else f"anon-{ts}"),
        "esp32_vaked_dev": results.get("esp32_vaked_dev"),
        "wigle_net": results.get("wigle_net"),
    }


class WigleWWWHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(f"[wiglewww] {self.address_string()} - {fmt % args}\n")

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:
        self._send(204, b"", "text/plain; charset=utf-8")

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        p = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        if p in ("/", "/index.html"):
            if WWW_INDEX.exists():
                self._send(200, WWW_INDEX.read_bytes(), "text/html; charset=utf-8")
            else:
                self._send(404, b"www/index.html not found", "text/plain; charset=utf-8")
            return
        if p == "/sw.js":
            if WWW_SW.exists():
                self._send(200, WWW_SW.read_bytes(), "application/javascript; charset=utf-8")
            else:
                self._send(404, b"// sw.js not found", "application/javascript; charset=utf-8")
            return
        if p == "/manifest.webmanifest":
            if WWW_MANIFEST.exists():
                self._send(200, WWW_MANIFEST.read_bytes(), "application/manifest+json; charset=utf-8")
            else:
                self._send(404, b"{}", "application/manifest+json; charset=utf-8")
            return
        if p == "/favicon.svg":
            if WWW_FAVICON.exists():
                self._send(200, WWW_FAVICON.read_bytes(), "image/svg+xml; charset=utf-8")
            else:
                self._send(404, b"<svg xmlns='http://www.w3.org/2000/svg'/>", "image/svg+xml; charset=utf-8")
            return
        if p == "/og.svg":
            if WWW_OG.exists():
                self._send(200, WWW_OG.read_bytes(), "image/svg+xml; charset=utf-8")
            else:
                self._send(404, b"<svg xmlns='http://www.w3.org/2000/svg'/>", "image/svg+xml; charset=utf-8")
            return
        if p in ("/api/engine", "/api/music"):
            feed = fetch_engine_feed(max_age_s=0.0 if (qs.get("fresh") or ["0"])[0] == "1" else 20.0)
            sent = push_engine_to_boards(feed) if (qs.get("push") or ["0"])[0] == "1" else []
            self._send(200, json.dumps({"ok": True, "feed": feed, "pushed": sent}, indent=2).encode("utf-8"), "application/json; charset=utf-8")
            return
        if p in ("/api/viz", "/api/enthea"):
            if (qs.get("step") or ["0"])[0] in ("1", "true"):
                VIZ_STATE["mode_idx"] = (int(VIZ_STATE.get("mode_idx", 0)) + 1) % len(VIZ_MODES)
            self._send(200, json.dumps({"ok": True, **compute_viz_enthea()}, indent=2).encode("utf-8"), "application/json; charset=utf-8")
            return
        if p in ("/api/alexai", "/api/kompress"):
            if not BEACONS:
                send_and_collect(discover_ports(), "SCAN", wait_s=0.35)
            prompt_q = (qs.get("prompt") or [None])[0]
            res = compute_alexai_and_kompress(prompt_q)
            self._send(200, json.dumps({"ok": True, **res}, indent=2).encode("utf-8"), "application/json; charset=utf-8")
            return
        if p in ("/api/triad.json", "/triad.json", "/api/ultra-omni.json"):
            ports = discover_ports()
            lines = send_and_collect(ports, "JSON", wait_s=0.35)
            ak = compute_alexai_and_kompress()
            vz = compute_viz_enthea()
            payload = {
                "surface": "http://127.0.0.1:8088",
                "mirror": "https://esp32.vaked.dev",
                **ULTRA_OMNI_META,
                "ultra_omni": ULTRA_OMNI_META,
                "viz_enthea": vz,
                "alexai": ak["alexai"],
                "kompress_ultra": ak["kompress_ultra"],
                "offline_queue_count": sum(1 for q in OFFLINE_QUEUE if q.get("status") == "queued"),
                "ports": ports,
                "nodes": list(NODES_CACHE.values()),
                "beacons_count": len(BEACONS),
                "beacons": list(BEACONS.values()),
                "raw_lines": lines,
            }
            self._send(200, json.dumps(payload, indent=2).encode("utf-8"), "application/json; charset=utf-8")
            return
        if p == "/api/wigle.csv":
            if not BEACONS:
                send_and_collect(discover_ports(), "SCAN", wait_s=0.35)
            self._send(200, build_wigle_csv().encode("utf-8"), "text/csv; charset=utf-8")
            return
        self._send(404, b"Not Found", "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        if self.path.startswith("/api/tts") or self.path.startswith("/api/speak"):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length > 0 else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
                txt = str(body.get("text", "")).strip()
                voice = str(body.get("voice", "af_heart")).strip() or "af_heart"
            except Exception:
                txt = ""
                voice = "af_heart"
            res = dispatch_triad_tts(txt, voice=voice)
            self._send(200, json.dumps(res, indent=2).encode("utf-8"), "application/json; charset=utf-8")
            return
        if self.path.startswith("/api/queue/flush"):
            res = flush_offline_queue()
            self._send(200, json.dumps(res, indent=2).encode("utf-8"), "application/json; charset=utf-8")
            return
        if self.path.startswith("/api/upload"):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length).decode("utf-8", errors="replace") if length > 0 else ""
            if not raw.strip().startswith("WigleWifi-1."):
                if not BEACONS:
                    send_and_collect(discover_ports(), "SCAN", wait_s=0.45)
                csv_text = build_wigle_csv()
            else:
                csv_text = raw
            receipt = upload_csv_anonymously(csv_text)
            self._send(200, json.dumps(receipt, indent=2).encode("utf-8"), "application/json; charset=utf-8")
            return
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
            lines = send_and_collect(ports, cmd, wait_s=wait_s)
            ak = compute_alexai_and_kompress(cmd)
            vz = compute_viz_enthea()
            resp = {
                "ok": True,
                "cmd": cmd,
                **ULTRA_OMNI_META,
                "ultra_omni": ULTRA_OMNI_META,
                "viz_enthea": vz,
                "alexai": ak["alexai"],
                "kompress_ultra": ak["kompress_ultra"],
                "ports": ports,
                "lines": lines,
                "nodes": list(NODES_CACHE.values()),
                "beacons": list(BEACONS.values()),
            }
            self._send(200, json.dumps(resp).encode("utf-8"), "application/json; charset=utf-8")
            return
        self._send(404, b"Not Found", "text/plain; charset=utf-8")


def main() -> int:
    load_offline_state()
    ap = argparse.ArgumentParser(description="wiglewww — 100% Offline-First Local HTTP + USB Serial + CoreWLAN/BLE/AirPlay Bridge")
    ap.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    ap.add_argument("--port", type=int, default=8088, help="HTTP port (default: 8088)")
    ap.add_argument("--once", action="store_true", help="Probe serial ports + macOS CoreWLAN/BLE/AirPlay once and exit")
    ap.add_argument("--alexai", action="store_true", help="Run AlexAI GAIA-MLX-QUANT b1.58 fold over current spectrum and exit")
    ap.add_argument("--kompress", action="store_true", help="Run Kompress-Ultra v16.2.0 compression over current spectrum and exit")
    ap.add_argument("--flush-queue", action="store_true", help="Flush locally queued offline CSV uploads and exit")
    ap.add_argument("--upload", action="store_true", help="Scan all radios and upload WiGLE v1.4 CSV anonymously to esp32.vaked.dev + api.wigle.net")
    args = ap.parse_args()

    ports = discover_ports()
    if args.flush_queue:
        print(json.dumps(flush_offline_queue(), indent=2))
        return 0

    if args.alexai:
        if not BEACONS:
            send_and_collect(ports, "SCAN", wait_s=0.35)
        print(json.dumps(compute_alexai_and_kompress()["alexai"], indent=2))
        return 0

    if args.kompress:
        if not BEACONS:
            send_and_collect(ports, "SCAN", wait_s=0.35)
        print(json.dumps(compute_alexai_and_kompress()["kompress_ultra"], indent=2))
        return 0

    if args.upload:
        send_and_collect(ports, "SCAN", wait_s=0.45)
        csv_text = build_wigle_csv()
        receipt = upload_csv_anonymously(csv_text)
        print(json.dumps(receipt, indent=2))
        return 0

    if args.once:
        lines = send_and_collect(ports, "JSON", wait_s=0.45)
        ak = compute_alexai_and_kompress()
        print(
            json.dumps(
                {
                    "surface": f"http://{args.host}:{args.port}",
                    "mirror": "https://esp32.vaked.dev",
                    **ULTRA_OMNI_META,
                    "ultra_omni": ULTRA_OMNI_META,
                    "alexai": ak["alexai"],
                    "kompress_ultra": ak["kompress_ultra"],
                    "offline_queue_count": sum(1 for q in OFFLINE_QUEUE if q.get("status") == "queued"),
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

    import threading

    def _usb_hotplug_watcher() -> None:
        known: set[str] = set(discover_ports())
        while True:
            time.sleep(2.5)
            cur = set(discover_ports())
            added = sorted(cur - known)
            if added:
                send_and_collect(added, "VIZ", wait_s=0.6)
                push_engine_to_boards(fetch_engine_feed())
                dispatch_triad_tts(
                    f"ESP32 Medusa Triad attached on {', '.join(pathlib.Path(p).name for p in added)}. Three hearts plus one online."
                )
            known = cur

    threading.Thread(target=_usb_hotplug_watcher, daemon=True).start()
    srv = ThreadingHTTPServer((args.host, args.port), WigleWWWHandler)
    print(f"[wiglewww] Serving {WWW_INDEX} on http://{args.host}:{args.port} (ports: {ports})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
