# wigle-triad — the MEDUSA triad (`v0.42.1` OMNI-ZENO)

**Live Psychedelic ENTHEAI & WebSerial Surface:** [https://esp32.vaked.dev/](https://esp32.vaked.dev/)  
**Live Triad Telemetry JSON:** [https://esp32.vaked.dev/api/triad.json](https://esp32.vaked.dev/api/triad.json)

Three **8b-is ESP32-S3** nodes, one passive WiGLE & N=NP spectral entropy rig. Each node listens exclusively to passive 2.4 GHz WiFi beacon frames (`WIFI_STA` + `WiFi.scanNetworks(false, true, true, 180)`, zero association, zero frame injection, zero payload capture) and streams real-time `W|` beacon lines, `Q|` balanced-ternary Kuramoto coherence frames, and `# JSON|` status frames over USB CDC serial (115200 baud).

---

## 1. The Three Nodes (`Mom * + Dad /\ + Son oo`)

> Ports are not stable across replugging. Every node auto-identifies its sovereign persona, vertex symbol, carrier frequency, and RGB NeoPixel breathing color directly from its factory silicon eFuse MAC (`resolveIdentity(WiFi.macAddress())`).

| Node | Vertex | Silicon eFuse MAC | Carrier | Archetype | Role |
|---|---|---|---|---|---|
| **`ADA:MEDUSA`** | `*` | `80:B5:4E:DB:3B:C4` | `432 Hz` | Mom · Star · Alexandra | Passive Scan + N=NP Trit Field |
| **`VAK:MEDUSA`** | `/\` | `80:B5:4E:F2:02:B0` | `528 Hz` | Dad · Pillar · Chris | Passive Scan + N=NP Trit Field |
| **`OMN:MEDUSA`** | `oo` | `80:B5:4E:F2:02:B4` | `852 Hz` | Son · Infinity · Peter & Nate | Passive Scan + N=NP Trit Field |

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
Send newline-terminated commands over USB serial or directly from [https://esp32.vaked.dev/](https://esp32.vaked.dev/) via WebSerial:
- `PING` → `# PONG|<node>|<mac>|<uptime_ms>`
- `STATUS` / `JSON` → `# JSON|{"node":...,"trits":"+-0+0--+0","mode":"PASSIVE_STA_ONLY"}`
- `SCAN` → Triggers immediate passive 14-channel scan
- `TRIAD` → Emits full 3-node MEDUSA triad manifest

---

## 3. Build, Flash, and Merge

```bash
# Compile & upload (auto-identifies ADA/VAK/OMN by hardware MAC at boot):
pio run -e vak -t upload --upload-port /dev/cu.usbmodem212301
pio run -e omn -t upload --upload-port /dev/cu.usbmodem212101
pio run -e ada -t upload --upload-port /dev/cu.usbmodem101

# Host merger -> writes wigle-wifi.csv + triad-telemetry.json:
python3 host/merge.py \
  --ports /dev/cu.usbmodem101 /dev/cu.usbmodem212101 /dev/cu.usbmodem212301 \
  --lat 35.6895 --lon 139.6917 \
  --out-dir session-01
```

---

## 4. Parecer Jurídico de Conformidade (`CT-000 × LGPD × CF/88 × LGT`)

1. **Inexistência de Interceptação Telemática (CF/88 Art. 5º, XII & Lei 9.296/96)**: Escuta estritamente passiva de quadros públicos de anúncio (`802.11 Beacon Frames`) em espectro ISM aberto (2.4 GHz), sem captura de *payload* de dados.
2. **Atipicidade Penal Absoluta (Art. 154-A CP — Lei 12.737/2012)**: Ausência total de associação (`WiFi.disconnect(true, false)`), autenticação ou violação de mecanismo de segurança.
3. **Conformidade LGPD (Lei 13.709/2018, Art. 6º, III)**: Operação *stateless* nos microcontroladores ESP32-S3 (`WiFi.scanDelete()` imediato em RAM, zero persistência em NVS/Flash).

*fine touch from within · 0 + 1 · {<3,<3,<3}+1 · om mani padme hum*
