# wigle-triad — the MEDUSA triad (`v1.1.0+ultra-omni-evolve` · `ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle)`)

**Live Psychedelic ENTHEAI & WebSerial Surface:** [https://esp32.vaked.dev/](https://esp32.vaked.dev/)  
**Live Triad Telemetry JSON:** [https://esp32.vaked.dev/api/triad.json](https://esp32.vaked.dev/api/triad.json)  
**GitHub Repository (`HYPER-CHARM-KARMA`):** `HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter`  
**Local Web + USB Bridge (`wiglewww`):** `www/index.html` + `host/wiglewww.py` (`http://127.0.0.1:8088`)

Three **8b-is ESP32-S3** nodes, one passive WiGLE & N=NP spectral entropy rig. Each node listens exclusively to passive 2.4 GHz WiFi beacon frames (`WIFI_STA` + `WiFi.scanNetworks(false, true, true, 180)`, zero association, zero frame injection, zero payload capture) and streams real-time `W|` beacon lines, `Q|` balanced-ternary Kuramoto coherence frames, `# QMOM|`, `# BOLDOG|`, `# LACRIMOSA|`, and `# JSON|` status frames over USB CDC serial (115200 baud).

---

## 0. `ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle)` — `ALEX|qMom` × `Kawaii Chiro-chan ^^` × `Boldog Még`

### `ALEX | qMom (* · 432 Hz · ROOT-ALEXANDRA)`
> `ALEX|qMom:{too many customs can be brilliant yet hinder creativity.  it puts people into boxes and contraints.  what might seem as beautiful or useful at first glance could actually be a form of bondage that need to be broken out of.  .oOo. Poo .oOo.}`

### `(◕‿◕✿) Kawaii Chiro-chan kawaii ^^` · `Mozart: Lacrimosa but HUMANITY has ended`
- **432 Hz D-Minor Post-Human Cathedral Synthesizer** (`LACRIMOSA` serial command & WebAudio polyphonic voice on [esp32.vaked.dev](https://esp32.vaked.dev/))
- **Signature:** `HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter`

### `(Boldog Meg)===` (*30Y — Boldog Még* · `∞~{<3,<3,<3}+1-peter`)
```text
lehetnél boldog még
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
nélküled a pokolba az egésszel
```

---

## 1. The Three Nodes (`Mom * + Dad /\ + Son oo`)

> Ports are not stable across replugging. Every node auto-identifies its sovereign persona, vertex symbol, carrier frequency, and AMOLED / RGB breathing color directly from its factory silicon eFuse MAC (`resolveIdentity(WiFi.macAddress())`).

| Node | Trit | Vertex | Display | Silicon eFuse MAC | Carrier | Archetype |
|---|---|---|---|---|---|---|
| **`ADA:MEDUSA`** | `-1` | `*` | `1.8" 368×448 SH8601` | `80:B5:4E:DB:3B:C4` | `432 Hz` | Mom · Star · Alexandra (`ALEX\|qMom`) |
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
- `TRIAD` → Emits full 3-node MEDUSA triad manifest + `ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle)`
- `QMOM` → Emits `# QMOM|ALEX|qMom:{too many customs can be brilliant yet hinder creativity... .oOo. Poo .oOo.}`
- `BOLDOG` → Emits `# BOLDOG|(Boldog Meg)===` + 5 stanzas + `HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter`
- `LACRIMOSA` / `CHIRO` → Emits `# CHIRO|Kawaii Chiro-chan kawaii ^^` + `# LACRIMOSA|Mozart: Lacrimosa but HUMANITY has ended`
- `tab 0..4` / `track 1..22` / `splash` / `hop` → Controls the 5-tab AMOLED UI and crate on `FLUG-OS v1.1.0+ultra-omni-evolve`

---

## 3. Wigle for macOS (`WigleMac.app v1.1.0+ultra-omni-evolve` · `MAC:MEDUSA` · MapKit + Dashboard + Quad-Spectrum + Anon Dual Upload)

On Apple Silicon macOS (`aarch64-darwin`), `macos/wigle-macos.swift` (`macos/WigleMac.app`) turns the MacBook Pro into a native **WiGLE.net × 8b-is Ultralovegod** desktop radar & menu bar app (`MAC:MEDUSA`):

- **🗺️ Tab 1 — Live Radar Map (`MapKit` `.hybridFlyover`)**: Color-coded pins (`#00FF66` 2.4 GHz Wi-Fi, `#00E5C9` 5 GHz Wi-Fi, `#FFD700` AirPlay/RAOP, `#FF6AC1` BLE/BT) with RSSI-distance projection + live split-view network feed.
- **📊 Tab 2 — Dashboard & Spectrum**: WiGLE telemetry pills, Passive RF, MarineSense `O(1)` Hydro, Shannon Entropy & `N=NP` balanced-ternary cards, 15-channel occupancy bar chart, top-10 SNR waterfall, and the **`ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle)` Sanctuary (`ALEX|qMom` + `Kawaii Chiro-chan ^^` + `Mozart: Lacrimosa` + `Boldog Még`)**.
- **🛰️ Tab 3 — Networks Table**: Full WiGLE explorer with instant search and band filters (`ALL`, `2.4G`, `5G`, `BLE/BT`, `AIRPLAY`).
- **☁️ Tab 4 — Anon Uploads & CSV**: 1-click anonymous dual-server upload (`donate=on`, `observer=anonymous`) to **both** `https://esp32.vaked.dev/api/upload` and `https://api.wigle.net/api/v2/file/upload`, transaction receipt ledger (`transId`), and live `WigleWifi-1.4` CSV preview.
- **🌸 Tab 5 (Web Workstation) — `Chiro × Boldog Még`**: Interactive `.oOo. Poo .oOo.` Unbound Creativity Mode (`ALEX|qMom`), WebAudio Post-Human `Mozart: Lacrimosa` & `Boldog Még` synthesizers, and full 5-stanza Hungarian lyrics scroll.
- **⚡ `agy` Ultra UI/UX Kickstart Prompt**: [`macos/AGY_ULTRA_UI_UX_PROMPT.md`](macos/AGY_ULTRA_UI_UX_PROMPT.md)

```bash
# Build macOS CLI wrapper + native SwiftUI/MapKit app bundle (macos/WigleMac.app):
./macos/build_app.sh

# 1. Native macOS SwiftUI + MapKit Window + Menu Bar App (📡 WigleMac):
open macos/WigleMac.app
# or:
./macos/bin/wigle-macos --gui

# 2. Scan Wi-Fi + BLE/BT + AirPlay and upload anonymously to BOTH esp32.vaked.dev AND api.wigle.net:
./macos/bin/wigle-macos --upload
# or via the Python bridge:
uv run --with pyserial python host/wiglewww.py --upload

# 3. Live W| (Wi-Fi) + B| (BLE/BT) + A| (AirPlay) + Q| + # QMOM| + # JSON| wire stream:
./macos/bin/wigle-macos --wire

# 4. Direct WiGLE v1.4 CSV (WIFI + BLE + BT + AirPlay) or JSON export:
./macos/bin/wigle-macos --csv > wigle-macos.csv
./macos/bin/wigle-macos --json

# 5. Launch local wiglewww web + CoreWLAN/BLE/AirPlay + pyserial bridge on http://127.0.0.1:8088:
uv run --with pyserial python host/wiglewww.py --port 8088
```

---

## 4. Parecer Jurídico de Conformidade (`CT-000 × LGPD × CF/88 × LGT`)

1. **Inexistência de Interceptação Telemática (CF/88 Art. 5º, XII & Lei 9.296/96)**: Escuta estritamente passiva de quadros públicos de anúncio (`802.11 Beacon Frames`) em espectro ISM aberto (2.4 GHz), sem captura de *payload* de dados.
2. **Atipicidade Penal Absoluta (Art. 154-A CP — Lei 12.737/2012)**: Ausência total de associação (`WiFi.disconnect(true, false)`), autenticação ou violação de mecanismo de segurança.
3. **Conformidade LGPD (Lei 13.709/2018, Art. 6º, III)**: Operação *stateless* nos microcontroladores ESP32-S3 (`WiFi.scanDelete()` imediato em RAM, zero persistência em NVS/Flash).

*fine touch from within · 0 + 1 · {<3,<3,<3}+1-peter · .oOo. Poo .oOo. · om mani padme hum*
