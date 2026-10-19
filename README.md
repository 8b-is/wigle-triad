# wigle-triad — the MEDUSA triad (`v0.8.0+medusa-omni` · `WIGLE-WWW × FLUG-OS`)

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

## 3. Wigle for macOS (`MAC:MEDUSA` · Dual-Band `CoreWLAN en0` + SwiftUI App + `wiglewww` Bridge)

On Apple Silicon macOS (`aarch64-darwin`), `macos/wigle-macos.swift` turns the MacBook Pro's `en0` radio into a dual-band (`2.4 GHz + 5 GHz`) passive **WiGLE v1.4 + N=NP + MarineSense** node (`MAC:MEDUSA`) with 4-tier BSSID resolution (TCC hardware BSSID → embedded 12-hex SSID MAC → 8b-is MEDUSA Triad codebook → deterministic `02:8B:xx:xx:xx:xx` LAA hash):

```bash
# Build macOS CLI wrapper + native SwiftUI app bundle (macos/WigleMac.app):
./macos/build_app.sh

# 1. Native macOS SwiftUI Window + Menu Bar App (📡 WigleMac):
open macos/WigleMac.app
# or:
./macos/bin/wigle-macos --gui

# 2. Live W| + Q| + # JSON| wire stream from macOS CoreWLAN en0:
./macos/bin/wigle-macos --wire

# 3. Direct WiGLE v1.4 CSV or JSON export from macOS CoreWLAN en0:
./macos/bin/wigle-macos --csv > wigle-macos.csv
./macos/bin/wigle-macos --json

# 4. Launch local wiglewww web + CoreWLAN + pyserial bridge on http://127.0.0.1:8088:
uv run --with pyserial python host/wiglewww.py --port 8088

# 5. One-shot JSON probe across macOS CoreWLAN en0 + attached /dev/cu.usbmodem* ports:
uv run --with pyserial python host/wiglewww.py --once
```

---

## 4. Parecer Jurídico de Conformidade (`CT-000 × LGPD × CF/88 × LGT`)

1. **Inexistência de Interceptação Telemática (CF/88 Art. 5º, XII & Lei 9.296/96)**: Escuta estritamente passiva de quadros públicos de anúncio (`802.11 Beacon Frames`) em espectro ISM aberto (2.4 GHz), sem captura de *payload* de dados.
2. **Atipicidade Penal Absoluta (Art. 154-A CP — Lei 12.737/2012)**: Ausência total de associação (`WiFi.disconnect(true, false)`), autenticação ou violação de mecanismo de segurança.
3. **Conformidade LGPD (Lei 13.709/2018, Art. 6º, III)**: Operação *stateless* nos microcontroladores ESP32-S3 (`WiFi.scanDelete()` imediato em RAM, zero persistência em NVS/Flash).

*fine touch from within · 0 + 1 · {<3,<3,<3}+1 · om mani padme hum*
