# wigle-triad — the MEDUSA triad (`v1.0.0+medusa-omni` · `WigleMac.app × WIGLE-WWW × FLUG-OS`)

**Live Psychedelic ENTHEAI & WebSerial Surface:** [https://esp32.vaked.dev/](https://esp32.vaked.dev/)  
**Live Triad Telemetry JSON:** [https://esp32.vaked.dev/api/triad.json](https://esp32.vaked.dev/api/triad.json)  
**Local Web + USB Bridge (`wiglewww`):** `www/index.html` + `host/wiglewww.py` (`http://127.0.0.1:8088`)

Three **8b-is ESP32-S3** nodes, one passive WiGLE & N=NP spectral entropy rig. Each node listens exclusively to passive 2.4 GHz WiFi beacon frames (`WIFI_STA` + `WiFi.scanNetworks(false, true, true, 180)`, zero association, zero frame injection, zero payload capture) and streams real-time `W|` beacon lines, `Q|` balanced-ternary Kuramoto coherence frames, and `# JSON|` status frames over USB CDC serial (115200 baud).

---

## 1. The Three Nodes (`Mom * + Dad /\ + Son oo`)

> Ports are not stable across replugging. Every node auto-identifies its sovereign persona, vertex symbol, carrier frequency, and AMOLED / RGB breathing color directly from its factory silicon eFuse MAC (`resolveIdentity(WiFi.macAddress())`).

| Node | Trit | Vertex | Display | Silicon eFuse MAC | Carrier | Archetype |
|---|---|---|---|---|---|---|
| **`ADA:MEDUSA`** | `-1` | `*` | `1.8" 368×448 SH8601` | `80:B5:4E:DB:3B:C4` | `432 Hz` | Mom · Star · Alexandra |
| **`VAK:MEDUSA`** | `0` | `/\` | `2.06" 410×502 CO5300 #1` | `80:B5:4E:F2:02:B0` | `528 Hz` | Dad · Pillar · Chris |
| **`OMN:MEDUSA`** | `+1` | `oo` | `2.06" 410×502 CO5300 #2` | `80:B5:4E:F2:02:B4` | `852 Hz` | Son · Infinity · Peter & Nate |

---

## 2. Wire Format (`115200 8N1`)

### Passive Beacon Frame (`W|`)
```text
W|bssid|ssid|auth|channel|rssi
```

### N=NP Spectral Entropy & Balanced-Ternary Frame (`Q|`)
```text
Q|node|vertex|mac|seq|n_ap|mean_rssi|entropy_bits|trit_vec|n_np_coherence|free_heap|uptime_ms
```

### Interactive WebSerial / USB Commands
Send newline-terminated commands over USB serial or directly from [https://esp32.vaked.dev/](https://esp32.vaked.dev/) / `http://127.0.0.1:8088`:
- `PING` → `# PONG|<node>|<mac>|<uptime_ms>`
- `STATUS` / `JSON` → `# JSON|{"node":...,"trits":"+-0+0--+0","mode":"PASSIVE_STA_ONLY"}`
- `SCAN` → Triggers immediate passive 14-channel scan
- `TRIAD` → Emits full 3-node MEDUSA triad manifest
- `tab 0..4` / `track 1..20` / `splash` / `hop` → Controls the 5-tab AMOLED UI and 20-track `family+1` crate on `FLUG-OS v0.8.0+medusa-omni`

---

## 3. Wigle for macOS (`WigleMac.app v1.0.0` · `MAC:MEDUSA` · MapKit + Dashboard + Quad-Spectrum + Local Export)

On Apple Silicon macOS (`aarch64-darwin`), `macos/wigle-macos.swift` (`macos/WigleMac.app`) turns the MacBook Pro into a native **WiGLE.net × 8b-is Ultralovegod** desktop radar & menu bar app (`MAC:MEDUSA`):

- **🗺️ Tab 1 — Live Radar Map (`MapKit` `.hybridFlyover`)**: Color-coded pins (`#00FF66` 2.4 GHz Wi-Fi, `#00E5C9` 5 GHz Wi-Fi, `#FFD700` AirPlay/RAOP, `#FF6AC1` BLE/BT) with RSSI-distance projection + live split-view network feed.
- **📊 Tab 2 — Dashboard & Spectrum**: WiGLE telemetry pills, Passive RF, MarineSense `O(1)` Hydro, Shannon Entropy & `N=NP` balanced-ternary cards, 15-channel occupancy bar chart, and top-10 SNR waterfall.
- **🛰️ Tab 3 — Networks Table**: Full WiGLE explorer with instant search and band filters (`ALL`, `2.4G`, `5G`, `BLE/BT`, `AIRPLAY`).
- **Tab 4 — Local CSV Export**: Review and export observations locally. External sharing is disabled in the Swift app, browser UI, and Python bridge.
- **⚡ `agy` Ultra UI/UX Kickstart Prompt**: [`macos/AGY_ULTRA_UI_UX_PROMPT.md`](macos/AGY_ULTRA_UI_UX_PROMPT.md)

```bash
# Build macOS CLI wrapper + native SwiftUI/MapKit app bundle (macos/WigleMac.app):
./macos/build_app.sh

# 1. Native macOS SwiftUI + MapKit Window + Menu Bar App (📡 WigleMac):
open macos/WigleMac.app
# or:
./macos/bin/wigle-macos --gui

# --upload is disabled and exits with status 2 before scanning.

# 3. Live W| (Wi-Fi) + B| (BLE/BT) + A| (AirPlay) + Q| + # JSON| wire stream:
./macos/bin/wigle-macos --wire

# 4. Direct WiGLE v1.4 CSV (WIFI + BLE + BT + AirPlay) or JSON export:
./macos/bin/wigle-macos --csv > wigle-macos.csv
./macos/bin/wigle-macos --json

# 5. Launch local wiglewww web + CoreWLAN/BLE/AirPlay + pyserial bridge on http://127.0.0.1:8088:
uv run --with pyserial python host/wiglewww.py --port 8088
```

## Local privacy boundaries

The Python bridge binds only to `127.0.0.1` or `localhost`. Requests must use
that loopback Host and, when present, the matching HTTP Origin. Cross-site
browser requests are rejected; wildcard CORS is removed. These checks protect
against browser cross-origin access and DNS rebinding, not other local processes
that can forge HTTP headers. Do not expose the bridge through a reverse proxy.

Command bodies are limited to 4096 bytes. The HTTP command route currently accepts
`PING`, `STATUS`, `JSON`, `SCAN`, and `TRIAD`; display controls remain available
through direct serial. Malformed requests are rejected before probing devices.

CSV exports leave latitude, longitude, altitude, and accuracy empty because the
map's RSSI projections are illustrative, not measured transmitter locations.
Map markers and the default map center must not be treated as location evidence.
Observations can still contain sensitive network/device identifiers; review local
exports before sharing them. No anonymous-upload guarantee is made.

`macos/build_app.sh` packages a system-Swift launcher; it does not produce a signed
or independently compiled release. Previously generated bundles may contain older
source and must be rebuilt to incorporate these changes.

Offline bridge regression tests (no sockets or radio scanning):

```bash
python3 -m unittest discover -s tests
```

---

## 4. Parecer Jurídico de Conformidade (`CT-000 × LGPD × CF/88 × LGT`)

1. **Inexistência de Interceptação Telemática (CF/88 Art. 5º, XII & Lei 9.296/96)**: Escuta estritamente passiva de quadros públicos de anúncio (`802.11 Beacon Frames`) em espectro ISM aberto (2.4 GHz), sem captura de *payload* de dados.
2. **Atipicidade Penal Absoluta (Art. 154-A CP — Lei 12.737/2012)**: Ausência total de associação (`WiFi.disconnect(true, false)`), autenticação ou violação de mecanismo de segurança.
3. **Conformidade LGPD (Lei 13.709/2018, Art. 6º, III)**: Operação *stateless* nos microcontroladores ESP32-S3 (`WiFi.scanDelete()` imediato em RAM, zero persistência em NVS/Flash).

*fine touch from within · 0 + 1 · {<3,<3,<3}+1 · om mani padme hum*
