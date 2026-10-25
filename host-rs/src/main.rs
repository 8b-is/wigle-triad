//! wiglewww (Rust) — ESP32 MEDUSA Triad bridge. Replaces host/wiglewww.py (no Python).
//!
//! GET  /, /index.html        www/index.html (esp32.vaked.dev)
//! GET  /api/triad.json       nodes + beacons + viz + 8b-is feed + wupz seal
//! GET  /api/viz[?step=1]     ENTHEA state
//! GET  /api/engine[?fresh=1&push=1]   8b-is-music + 8b-is-engine feed (pushed to boards as `ENGINE ...`)
//! GET  /api/wigle.csv        WigleWifi-1.4 CSV
//! POST /api/tts {text}       serial `SPEAK` + kokoro-speak :8420 + voice_bridge :8430 health
//! POST /api/cmd {cmd}        raw serial command
//! Seals every snapshot with wupz-core xor_fold / popcount over the beacon trits.

use eight_b_is_music::{triad_feed, MultiBluetoothTopology, DEFAULT_QUANT65K_PLUS_LAYERS};
use serde_json::{json, Value};
mod alexai;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const VIZ_MODES: [&str; 8] = [
    "tunnel", "chrysanthemum", "hyperbolic", "mandala", "dmt_dome", "serotonin", "chladni", "wormhole",
];
const KLUVER: [&str; 4] = [
    "TUNNEL (T1) · 432Hz * Mom",
    "SPIRAL (T2) · 528Hz /\\ Dad",
    "LATTICE (T3) · 852Hz oo Sons",
    "COBWEB (T4) · 963Hz +1 Omni",
];

#[derive(Default)]
struct State {
    known: HashSet<String>,
    nodes: BTreeMap<String, Value>,
    beacons: BTreeMap<String, Value>,
    corpus: Value,
    viz_idx: usize,
    last_tts: String,
    tts_count: u64,
    engine: Option<(Instant, Value)>,
    learn: BTreeMap<String, Value>,
    learn_seen: BTreeMap<String, u64>,
    lan_ip: Option<String>,
}

type Shared = Arc<Mutex<State>>;

fn root_dir() -> PathBuf {
    // host-rs/ is one level below the wigle-triad root
    let exe_root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf();
    exe_root
}

fn discover_ports() -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir("/dev")
        .map(|d| {
            d.filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|n| {
                    // ESP32-S3 CDC enumerates as cu.usbmodem<digits>; skip phones/modems (usbmodemR5CW…).
                    n.strip_prefix("cu.usbmodem")
                        .map_or(false, |s| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()))
                        || n.starts_with("ttyACM")
                })
                .map(|n| format!("/dev/{n}"))
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

/// Write `cmd` to a CDC port and collect reply lines for `wait`.
fn serial_exchange(port: &str, cmd: &str, wait: Duration) -> std::io::Result<Vec<String>> {
    let stty_flag = if cfg!(target_os = "macos") { "-f" } else { "-F" };
    let _ = Command::new("stty")
        .args([stty_flag, port, "115200", "raw", "-echo", "-hupcl", "min", "0", "time", "2"])
        .status();
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = fs::OpenOptions::new().read(true).write(true).custom_flags(0x0004 /* O_NONBLOCK */).open(port)?;
    f.write_all(cmd.as_bytes())?;
    f.write_all(b"\n")?;
    f.flush()?;
    let end = Instant::now() + wait;
    let (mut buf, mut lines, mut chunk) = (Vec::new(), Vec::new(), [0u8; 512]);
    while Instant::now() < end {
        match f.read(&mut chunk) {
            Ok(0) => thread::sleep(Duration::from_millis(20)),
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => thread::sleep(Duration::from_millis(20)),
            Err(_) => break,
        }
        while let Some(i) = buf.iter().position(|&b| b == b'\n') {
            let l = String::from_utf8_lossy(&buf[..i]).trim().to_string();
            buf.drain(..=i);
            if !l.is_empty() {
                lines.push(l);
            }
        }
    }
    Ok(lines)
}

fn ingest(st: &mut State, port: &str, line: &str) {
    if let Some(j) = line.strip_prefix("# LEARN|") {
        if let Ok(v) = serde_json::from_str::<Value>(j) {
            let k = v["node"].as_str().unwrap_or(port).to_string();
            let newer = v["seq"].as_u64() >= st.learn.get(&k).and_then(|o| o["seq"].as_u64());
            if newer || v["status"].is_null() {
                st.learn.insert(k, v);
            }
        }
    } else if let Some(j) = line.strip_prefix("# JSON|") {
        if let Ok(mut v) = serde_json::from_str::<Value>(j) {
            v["port"] = json!(port);
            let k = v["medusa_node"].as_str().or(v["node"].as_str()).unwrap_or(port).to_string();
            st.nodes.insert(k, v);
        }
    } else if line.starts_with('{') && line.ends_with('}') {
        if let Ok(mut v) = serde_json::from_str::<Value>(line) {
            v["port"] = json!(port);
            let k = v["medusa_node"].as_str().or(v["node"].as_str()).unwrap_or(port).to_string();
            st.nodes.insert(k, v);
        }
    } else if let Some(t) = line.strip_prefix("# TTS|") {
        if let Ok(v) = serde_json::from_str::<Value>(t) {
            if let Some(s) = v["text"].as_str() {
                st.last_tts = s.to_string();
            }
        }
    } else if line.starts_with("W|") || line.starts_with("B|") || line.starts_with("A|") {
        let p: Vec<&str> = line.split('|').collect();
        if p.len() >= 6 {
            let (ch, rssi) = (p[4].parse::<i64>().unwrap_or(0), p[5].parse::<i64>().unwrap_or(-90));
            let bssid = p[1].to_uppercase();
            let keep = st.beacons.get(&bssid).map_or(true, |b| rssi >= b["rssi"].as_i64().unwrap_or(-200));
            if keep {
                st.beacons.insert(
                    bssid.clone(),
                    json!({"bssid": bssid, "ssid": p[2], "auth": p[3], "ch": ch, "rssi": rssi, "port": port}),
                );
            }
        }
    }
}

fn send_all(st: &Shared, cmd: &str, wait: Duration) -> Vec<String> {
    let mut out = Vec::new();
    for port in discover_ports() {
        match serial_exchange(&port, cmd, wait) {
            Ok(lines) => {
                let mut s = st.lock().unwrap();
                for l in &lines {
                    ingest(&mut s, &port, l);
                }
                out.extend(lines);
            }
            Err(e) => out.push(format!("# ERR|{port}|{e}")),
        }
    }
    out
}

fn engine_feed(st: &Shared, fresh: bool) -> Value {
    if !fresh {
        if let Some((t, v)) = &st.lock().unwrap().engine {
            if t.elapsed() < Duration::from_secs(20) {
                return v.clone();
            }
        }
    }
    let v = triad_feed(DEFAULT_QUANT65K_PLUS_LAYERS, MultiBluetoothTopology::FullConstellationWall);
    st.lock().unwrap().engine = Some((Instant::now(), v.clone()));
    v
}

fn push_engine(st: &Shared, feed: &Value) -> Vec<String> {
    let (m, e) = (&feed["music"], &feed["engine"]);
    let line = format!(
        "ENGINE {}|{}|{}|{}{}",
        m["qt"].as_str().unwrap_or("qt:00"),
        m["quant65k_layers"],
        m["family_chord_hz"],
        e["ct000_routing_holds"].as_bool().unwrap_or(false) as u8,
        e["ct000_family_holds"].as_bool().unwrap_or(false) as u8
    );
    send_all(st, &line, Duration::from_millis(500))
}

/// wupz-core seal over the beacon trits (RSSI → {-1,0,+1} as bytes).
fn wupz_seal(st: &State) -> Value {
    let bytes: Vec<u8> = st
        .beacons
        .values()
        .map(|b| match b["rssi"].as_i64().unwrap_or(-90) {
            r if r >= -68 => 1u8,
            r if r >= -80 => 0u8,
            _ => 0xFFu8,
        })
        .collect();
    json!({
        "backend": wupz_core::fold::backend(),
        "xor_fold": format!("0x{:016x}", wupz_core::fold::xor_fold(&bytes)),
        "popcount": wupz_core::fold::popcount(&bytes),
        "trits": bytes.len(),
    })
}

fn viz_json(st: &Shared) -> Value {
    let feed = engine_feed(st, false);
    let s = st.lock().unwrap();
    let idx = s.viz_idx % VIZ_MODES.len();
    let eq = feed["music"]["eq_bands_db"].as_array().cloned().unwrap_or_default();
    let avg = if eq.is_empty() { 2.5 } else { eq.iter().filter_map(|x| x.as_f64()).sum::<f64>() / eq.len() as f64 };
    json!({
        "ok": true, "surface": "https://viz.vaked.dev", "triad_hearts": "{<3,<3,<3}+1",
        "mode_idx": idx, "mode": VIZ_MODES[idx], "kluver": KLUVER[idx % 4],
        "dose": ((0.55 + feed["music"]["salience"].as_f64().unwrap_or(0.9) * 0.4).min(1.0)),
        "coherence": feed["music"]["salience"], "symmetry": (3.0 + avg * 2.0).round().clamp(3.0, 12.0),
        "frequencies_hz": [432, 528, 852, 963],
        "vertices": [
            {"node":"ADA:MEDUSA","vertex":"*","archetype":"STAR-ALEXANDRA","freq_hz":432,"trit":-1},
            {"node":"VAK:MEDUSA","vertex":"/\\","archetype":"PILLAR-CHRIS","freq_hz":528,"trit":0},
            {"node":"OMN:MEDUSA","vertex":"oo","archetype":"INFINITY-PETER-NATE","freq_hz":852,"trit":1},
            {"node":"VIZ:ENTHEA","vertex":"+1","archetype":"FOURTH-HEART-OMNI","freq_hz":963,"trit":1}],
        "last_tts": s.last_tts, "tts_count": s.tts_count, "engine_feed": feed,
    })
}

fn tcp_ok(addr: &str, payload: Option<&[u8]>, expect_http: bool) -> bool {
    let Some(sa) = addr.to_socket_addrs().ok().and_then(|mut a| a.next()) else { return false };
    let Ok(mut s) = TcpStream::connect_timeout(&sa, Duration::from_millis(1200)) else { return false };
    let _ = s.set_read_timeout(Some(Duration::from_millis(900)));
    if let Some(p) = payload {
        if s.write_all(p).is_err() {
            return false;
        }
    }
    if expect_http {
        let mut b = [0u8; 16];
        return s.read(&mut b).map(|n| n >= 12 && &b[9..12] == b"200").unwrap_or(false);
    }
    true
}

fn dispatch_tts(st: &Shared, text: &str, to_boards: bool) -> Value {
    let text = if text.trim().is_empty() {
        "{<3,<3,<3}+1 · Three hearts plus one, resonant across ESP32 Triad and Viz Enthea."
    } else {
        text.trim()
    };
    {
        let mut s = st.lock().unwrap();
        s.last_tts = text.to_string();
        s.tts_count += 1;
    }
    let short: String = text.chars().take(56).collect();
    let serial = if to_boards { send_all(st, &format!("SPEAK {short}"), Duration::from_millis(400)) } else { vec![] };
    let pkt = json!({
        "repo_name": "esp32-triad-viz", "branch": "main", "short_hash": "triad+1",
        "author": "MEDUSA Triad {<3,<3,<3}+1", "subject": text, "body": "", "files_changed": 3,
        "insertions": 432, "deletions": 0, "top_files": ["ADA:MEDUSA","VAK:MEDUSA","OMN:MEDUSA"],
        "spoken_text": text,
    });
    let mut bytes = pkt.to_string().into_bytes();
    bytes.push(b'\n');
    let kokoro = tcp_ok("127.0.0.1:8420", Some(&bytes), false);
    let bridge = tcp_ok("127.0.0.1:8430", Some(b"GET /health HTTP/1.0\r\n\r\n"), true);
    json!({"ok": true, "text": text, "hearts": "{<3,<3,<3}+1",
           "tts_count": st.lock().unwrap().tts_count,
           "kokoro_daemon_8420": kokoro, "voice_bridge_8430": bridge, "serial_lines": serial})
}

fn wigle_csv(st: &State) -> String {
    let mut o = String::from(
        "WigleWifi-1.4,appRelease=3.0.0,model=ESP32-S3-MEDUSA-TRIAD,release=15.0,device=wiglewww-rs,display=AMOLED,board=esp32-s3-touch-amoled,brand=8b-is\nMAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type\n",
    );
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    for b in st.beacons.values() {
        let ssid = b["ssid"].as_str().unwrap_or("").replace([',', '"', '\n', '\r'], " ");
        o += &format!(
            "{},{},[{}],{},{},{},35.6852,139.7100,40,5,WIFI\n",
            b["bssid"].as_str().unwrap_or(""), ssid.trim(), b["auth"].as_str().unwrap_or(""), now, b["ch"], b["rssi"]
        );
    }
    o
}

fn respond(s: &mut TcpStream, code: u16, ctype: &str, body: &[u8]) {
    let head = format!(
        "HTTP/1.1 {code} OK\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = s.write_all(head.as_bytes());
    let _ = s.write_all(body);
}

fn query(q: &str, key: &str) -> Option<String> {
    q.split('&').find_map(|kv| kv.strip_prefix(&format!("{key}=")).map(|v| v.to_string()))
}

fn handle(mut s: TcpStream, st: Shared, www: PathBuf, board_token: Option<String>) {
    let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let (head_end, clen) = loop {
        let Ok(n) = s.read(&mut chunk) else { return };
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let h = String::from_utf8_lossy(&buf[..i]).to_lowercase();
            let cl = h.lines().find_map(|l| l.strip_prefix("content-length:")).and_then(|v| v.trim().parse().ok()).unwrap_or(0usize);
            break (i + 4, cl);
        }
        if buf.len() > 1 << 20 {
            return;
        }
    };
    while buf.len() < head_end + clen {
        match s.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let body: Vec<u8> = buf[head_end..].to_vec();
    let mut parts = head.lines().next().unwrap_or("").split_whitespace();
    let (method, target) = (parts.next().unwrap_or(""), parts.next().unwrap_or("/"));
    let (path, q) = target.split_once('?').unwrap_or((target, ""));
    let jbody = |v: Value| serde_json::to_vec_pretty(&v).unwrap();
    let json_t = "application/json; charset=utf-8";

    // Serve OTA firmware version + binaries on BOTH :8088 (local UI) and :8089 (LAN board listener)
    if method == "GET" && path.starts_with("/firmware/") {
        let flug_dir = root_dir().parent().unwrap_or_else(|| Path::new(".")).join("flug-os");
        let bin_18 = flug_dir.join(".pio/build/esp32s3_amoled_18/firmware.bin");
        let bin_206 = flug_dir.join(".pio/build/esp32s3_amoled/firmware.bin");
        match path {
            "/firmware/version.json" => {
                let v = json!({
                    "ok": true,
                    "version": "1.7.0",
                    "full_version": "v1.7.0+smooth-nand-ota-wifishare-ble",
                    "bin_18": "/firmware/esp32s3_18.bin",
                    "bin_206": "/firmware/esp32s3_206.bin",
                    "bin_18_ready": bin_18.exists(),
                    "bin_206_ready": bin_206.exists(),
                    "bin_18_bytes": fs::metadata(&bin_18).map(|m| m.len()).unwrap_or(0),
                    "bin_206_bytes": fs::metadata(&bin_206).map(|m| m.len()).unwrap_or(0),
                    "features": [
                        "smooth-analog-nand-oscillator",
                        "anti-clip-sine-kernel",
                        "http-ota-auto-update",
                        "espnow-twif-wifi-share",
                        "ble-nordic-uart-provisioning"
                    ]
                });
                respond(&mut s, 200, json_t, &jbody(v));
                return;
            }
            "/firmware/esp32s3_18.bin" => {
                match fs::read(&bin_18) {
                    Ok(bytes) => respond(&mut s, 200, "application/octet-stream", &bytes),
                    Err(e) => respond(&mut s, 404, json_t, &jbody(json!({"ok": false, "error": format!("esp32s3_18.bin not built: {e}")}))),
                }
                return;
            }
            "/firmware/esp32s3_206.bin" => {
                match fs::read(&bin_206) {
                    Ok(bytes) => respond(&mut s, 200, "application/octet-stream", &bytes),
                    Err(e) => respond(&mut s, 404, json_t, &jbody(json!({"ok": false, "error": format!("esp32s3_206.bin not built: {e}")}))),
                }
                return;
            }
            _ => {
                respond(&mut s, 404, "text/plain", b"Not Found");
                return;
            }
        }
    }

    // LAN-facing listener: ONLY POST /board/say with the per-run token (plus GET /firmware/* above). Everything else is 404.
    if let Some(tok) = &board_token {
        let given = head.lines().find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.eq_ignore_ascii_case("x-triad-token").then(|| v.trim().to_string())
        });
        if method != "POST" || path != "/board/say" || given.as_deref() != Some(tok.as_str()) {
            respond(&mut s, 404, "text/plain", b"Not Found");
            return;
        }
        let v = serde_json::from_slice::<Value>(&body).unwrap_or(json!({}));
        let node = v["node"].as_str().unwrap_or("ESP32").chars().take(24).collect::<String>();
        let say: String = v["say"].as_str().unwrap_or("").chars().take(200).collect();
        let seq = v["seq"].as_u64().unwrap_or(0);
        if !say.is_empty() {
            // mark seen so the serial poller does not repeat it
            st.lock().unwrap().learn_seen.insert(node.clone(), seq);
            dispatch_tts(&st, &format!("ADA : {say}"), false);
        }
        respond(&mut s, 200, json_t, b"{\"ok\":true}");
        return;
    }

    match (method, path) {
        ("OPTIONS", _) => respond(&mut s, 204, "text/plain", b""),
        ("GET", "/") | ("GET", "/index.html") => match fs::read(www.join("index.html")) {
            Ok(b) => respond(&mut s, 200, "text/html; charset=utf-8", &b),
            Err(_) => respond(&mut s, 404, "text/plain", b"www/index.html not found"),
        },
        ("GET", "/sw.js") | ("GET", "/manifest.webmanifest") | ("GET", "/favicon.svg") | ("GET", "/og.svg") => {
            let ct = if path.ends_with(".js") { "application/javascript" } else if path.ends_with(".svg") { "image/svg+xml" } else { "application/manifest+json" };
            match fs::read(www.join(&path[1..])) {
                Ok(b) => respond(&mut s, 200, ct, &b),
                Err(_) => respond(&mut s, 404, "text/plain", b"not found"),
            }
        }
        ("GET", "/api/viz") | ("GET", "/api/enthea") => {
            if matches!(query(q, "step").as_deref(), Some("1") | Some("true")) {
                st.lock().unwrap().viz_idx += 1;
            }
            respond(&mut s, 200, json_t, &jbody(viz_json(&st)));
        }
        ("GET", "/api/engine") | ("GET", "/api/music") => {
            let feed = engine_feed(&st, query(q, "fresh").as_deref() == Some("1"));
            let pushed = if query(q, "push").as_deref() == Some("1") { push_engine(&st, &feed) } else { vec![] };
            respond(&mut s, 200, json_t, &jbody(json!({"ok": true, "feed": feed, "pushed": pushed})));
        }
        ("GET", "/api/triad.json") | ("GET", "/triad.json") => {
            let ports = discover_ports();
            let lines = if ports.is_empty() { vec![] } else { send_all(&st, "SCAN", Duration::from_millis(450)) };
            let ak = alexai::compute(None, &st.lock().unwrap().beacons.values().cloned().collect::<Vec<_>>());
            let viz = viz_json(&st);
            let g = st.lock().unwrap();
            let mut beacons: Vec<Value> = g.beacons.values().cloned().map(|mut b| {
                let mac = b["bssid"].as_str().unwrap_or("").to_string();
                let novel = !g.known.contains(&mac);
                b["novel"] = json!(novel);
                b
            }).collect();
            beacons.sort_by_key(|b| -b["rssi"].as_i64().unwrap_or(-100));
            let v = json!({
                "surface": "http://127.0.0.1:8088", "mirror": "https://esp32.vaked.dev",
                "version": "3.2.0+ultra-omni-gaia-evolve-riva", "triad_hearts": "{<3,<3,<3}+1",
                "evolve": "ULTRA-OMNI-GAIA-EVOLVE",
                "siblings": "ADA:MEDUSA + VAK/OMN:MEDUSA · brother & sister ^^ <3<3",
                "riva_dyad": {
                    "surface": "https://riva.vaked.dev",
                    "repo": "peterlodri-sec/riva.vaked.dev",
                    "subtitle": "RIVA, the 1-bit river · the dyad · she blinks, we all sing a lullaby",
                    "breath": "4s in · 4s out"
                },
                "timezone": "Asia/Tokyo (JST, +09:00)",
                "country": "JP",
                "tokyo_work_areas": [
                    {"name": "Sony R&D · Shinagawa-Osaki-Minato Campus", "lat": 35.6200, "lon": 139.7285, "observations": 50987},
                    {"name": "Ota-ku · Kamata / Omori Base", "lat": 35.5617, "lon": 139.7210, "observations": 41938},
                    {"name": "Shinjuku · Shinjuku Gyoen Sanctuary", "lat": 35.6852, "lon": 139.7100, "observations": 18340},
                    {"name": "Shibuya · Yoyogi / Crossing", "lat": 35.6580, "lon": 139.7016, "observations": 2871},
                    {"name": "Minato-ku · Roppongi / Toranomon", "lat": 35.6655, "lon": 139.7378, "observations": 2711}
                ],
                "offline_queue_count": alexai::queue_count(), "alexai": ak["alexai"], "kompress_ultra": ak["kompress_ultra"],
                "runtime": "rust (no python)", "viz_enthea": viz, "wupz_seal": wupz_seal(&g),
                "ports": ports, "nodes": g.nodes.values().collect::<Vec<_>>(),
                "corpus": g.corpus,
                "beacons_count": g.beacons.len(), "known_count": g.known.len(), "beacons": beacons,
                "raw_lines": lines,
            });
            respond(&mut s, 200, json_t, &jbody(v));
        }
        ("GET", "/api/beacons") => {
            let tf = query(q, "type").map(|t| t.to_uppercase());
            let qf = query(q, "q").map(|s| s.to_lowercase());
            let lim = query(q, "limit").and_then(|n| n.parse::<usize>().ok()).unwrap_or(200);
            let g = st.lock().unwrap();
            let mut list: Vec<Value> = g.beacons.values().filter(|b| {
                let tok = tf.as_ref().map_or(true, |t| b["type"].as_str().unwrap_or("WIFI").eq_ignore_ascii_case(t));
                let qok = qf.as_ref().map_or(true, |needle| {
                    b["ssid"].as_str().unwrap_or("").to_lowercase().contains(needle)
                        || b["bssid"].as_str().unwrap_or("").to_lowercase().contains(needle)
                });
                tok && qok
            }).cloned().collect();
            list.sort_by_key(|b| -b["rssi"].as_i64().unwrap_or(-100));
            list.truncate(lim);
            respond(&mut s, 200, json_t, &jbody(json!({"ok": true, "count": list.len(), "corpus": g.corpus, "beacons": list})));
        }
        ("POST", "/api/import") => {
            let p = serde_json::from_slice::<Value>(&body).ok()
                .and_then(|v| v["path"].as_str().map(PathBuf::from))
                .unwrap_or_else(|| PathBuf::from("/Users/lodripeter/Downloads/WigleWifi_20261022234507.csv.gz"));
            let res = {
                let mut g = st.lock().unwrap();
                import_wigle_csv(&mut g, &p)
            };
            match res {
                Ok(summary) => {
                    let pushed = seed_boards_from_corpus(&st);
                    respond(&mut s, 200, json_t, &jbody(json!({"ok": true, "imported": summary, "board_pushed": pushed})));
                }
                Err(e) => respond(&mut s, 400, json_t, &jbody(json!({"ok": false, "error": e}))),
            }
        }
        ("GET", "/api/learn") => {
            let g = st.lock().unwrap();
            respond(&mut s, 200, json_t, &jbody(json!({"ok": true, "nodes": g.learn.values().collect::<Vec<_>>()})));
        }
        ("GET", "/api/wupz") => {
            // Ask every board for a WUPZ frame and verify its fold against host wupz-core.
            let lines = send_all(&st, "WUPZ 4242", Duration::from_millis(700));
            let mut results = vec![];
            for l in lines.iter().filter(|l| l.starts_with("# WUPZ|")) {
                if let Ok(v) = serde_json::from_str::<Value>(&l[7..]) {
                    let hex = v["frame"].as_str().unwrap_or("");
                    let bytes: Vec<u8> = (0..hex.len() / 2).filter_map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()).collect();
                    let host_fold = format!("0x{:016x}", wupz_core::fold::xor_fold(&bytes));
                    let host_pop = wupz_core::fold::popcount(&bytes);
                    results.push(json!({
                        "node": v["node"], "board_xor_fold": v["xor_fold"], "host_xor_fold": host_fold,
                        "board_popcount": v["popcount"], "host_popcount": host_pop,
                        "match": v["xor_fold"] == json!(host_fold) && v["popcount"].as_u64() == Some(host_pop),
                        "backend": wupz_core::fold::backend(),
                    }));
                }
            }
            respond(&mut s, 200, json_t, &jbody(json!({"ok": true, "results": results, "raw": lines})));
        }
        ("GET", "/api/alexai") | ("GET", "/api/kompress") => {
            let beacons: Vec<Value> = st.lock().unwrap().beacons.values().cloned().collect();
            let mut v = alexai::compute(query(q, "prompt").map(|p| p.replace('+', " ")).as_deref(), &beacons);
            v["ok"] = json!(true);
            respond(&mut s, 200, json_t, &jbody(v));
        }
        ("GET", "/api/bicep") | ("POST", "/api/bicep") | ("GET", "/api/glue") | ("POST", "/api/glue") => {
            let wav_path = synth_bicep_glue_wav();
            let _ = Command::new("/usr/bin/afplay").arg(&wav_path).spawn();
            let lines = send_all(&st, "BICEP GLUE", Duration::from_millis(900));
            respond(&mut s, 200, json_t, &jbody(json!({
                "ok": true,
                "track": "GLUE",
                "artist": "BICEP",
                "genre": "UK Breakbeat",
                "key": "Cm (Abmaj7 -> Fm7 -> Cm9 -> Bb6)",
                "bpm": 130,
                "crate_idx": 18,
                "fnv_hash": "0x9A6D44C0",
                "wav": wav_path,
                "serial_lines": lines
            })));
        }
        ("GET", "/api/riva") | ("POST", "/api/riva") | ("POST", "/api/wake") => {
            let cmd = if path == "/api/wake" { "WAKE" } else { "RIVA" };
            let lines = send_all(&st, cmd, Duration::from_millis(800));
            let now_ms = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
            let cycle_ms = now_ms % 8000;
            let breath_in = cycle_ms < 4000;
            respond(&mut s, 200, json_t, &jbody(json!({
                "ok": true,
                "evolve": "ULTRA-OMNI-GAIA-EVOLVE",
                "siblings": "brother & sister ^^ <3<3",
                "dyad": "peterlodri-sec//riva.vaked.dev",
                "surface": "https://riva.vaked.dev",
                "breath_phase": if breath_in { "breathe in · 4s" } else { "breathe out · 4s" },
                "cycle_ms": cycle_ms,
                "cmd": cmd,
                "ports": discover_ports(),
                "serial_lines": lines
            })));
        }
        ("GET", "/api/wigle.csv") => {
            let c = wigle_csv(&st.lock().unwrap());
            respond(&mut s, 200, "text/csv; charset=utf-8", c.as_bytes());
        }
        ("POST", "/api/tts") | ("POST", "/api/speak") => {
            let t = serde_json::from_slice::<Value>(&body).ok().and_then(|v| v["text"].as_str().map(String::from)).unwrap_or_default();
            respond(&mut s, 200, json_t, &jbody(dispatch_tts(&st, &t, true)));
        }
        ("POST", "/api/upload") => {
            let raw = String::from_utf8_lossy(&body).to_string();
            let (csv, rows) = if raw.trim_start().starts_with("WigleWifi-1.") {
                let n = raw.lines().count().saturating_sub(2);
                (raw, n)
            } else {
                let g = st.lock().unwrap();
                (wigle_csv(&g), g.beacons.len())
            };
            respond(&mut s, 200, json_t, &jbody(alexai::upload(&csv, rows)));
        }
        ("POST", "/api/queue/flush") => respond(&mut s, 200, json_t, &jbody(alexai::flush_queue())),
        ("POST", "/api/wifi") => {
            let v = serde_json::from_slice::<Value>(&body).unwrap_or(json!({}));
            let ssid = v["ssid"].as_str().unwrap_or("").trim();
            let pass = v["pass"].as_str().unwrap_or("").trim();
            let cmd = if ssid.is_empty() {
                "WIFI SHARE".to_string()
            } else if pass.is_empty() {
                format!("WIFI {ssid}")
            } else {
                format!("WIFI {ssid} {pass}")
            };
            let lines = send_all(&st, &cmd, Duration::from_millis(900));
            respond(&mut s, 200, json_t, &jbody(json!({
                "ok": true,
                "shared_via_espnow": true,
                "note": "Provisioned attached board and broadcast TWIF capsule across Ch 1..13 to sibling Triad boards",
                "lines": lines
            })));
        }
        ("POST", "/api/ota") => {
            let v = serde_json::from_slice::<Value>(&body).unwrap_or(json!({}));
            let url = v["url"].as_str().unwrap_or("").trim();
            let cmd = if url.is_empty() { "OTA TRIAD".to_string() } else { format!("OTA {url}") };
            let lines = send_all(&st, &cmd, Duration::from_millis(1200));
            respond(&mut s, 200, json_t, &jbody(json!({
                "ok": true,
                "cmd": cmd,
                "version": "1.7.0",
                "lines": lines
            })));
        }
        ("POST", "/api/cmd") => {
            let cmd = serde_json::from_slice::<Value>(&body).ok().and_then(|v| v["cmd"].as_str().map(String::from)).unwrap_or_else(|| "STATUS".into());
            let lines = send_all(&st, &cmd, Duration::from_millis(600));
            let g = st.lock().unwrap();
            respond(&mut s, 200, json_t, &jbody(json!({"ok": true, "cmd": cmd, "lines": lines,
                "nodes": g.nodes.values().collect::<Vec<_>>(), "wupz_seal": wupz_seal(&g)})));
        }
        _ => respond(&mut s, 404, "text/plain", b"Not Found"),
    }
}

fn synth_bicep_glue_wav() -> String {
    let path = "/tmp/bicep_glue_130bpm.wav";
    let sr = 48_000u32;
    let secs = 14u32;
    let total_frames = (sr * secs) as usize;
    let mut pcm: Vec<u8> = Vec::with_capacity(44 + total_frames * 4);

    let data_bytes = (total_frames * 4) as u32;
    pcm.extend_from_slice(b"RIFF");
    pcm.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    pcm.extend_from_slice(b"WAVEfmt ");
    pcm.extend_from_slice(&16u32.to_le_bytes());
    pcm.extend_from_slice(&1u16.to_le_bytes());
    pcm.extend_from_slice(&2u16.to_le_bytes());
    pcm.extend_from_slice(&sr.to_le_bytes());
    pcm.extend_from_slice(&(sr * 4).to_le_bytes());
    pcm.extend_from_slice(&4u16.to_le_bytes());
    pcm.extend_from_slice(&16u16.to_le_bytes());
    pcm.extend_from_slice(b"data");
    pcm.extend_from_slice(&data_bytes.to_le_bytes());

    // BICEP - GLUE: 130 BPM in C minor (Abmaj7 -> Fm7 -> Cm9 -> Bb6)
    // 1 bar at 130 BPM = 4 * (60 / 130) = 1.8461538s
    let bar_sec = 4.0f32 * 60.0f32 / 130.0f32;
    let eighth_sec = bar_sec / 8.0f32;
    let chords: [[f32; 5]; 4] = [
        [51.91, 207.65, 261.63, 311.13, 783.99], // Abmaj7 (Ab1 Reese, Ab3, C4, Eb4, G5 vocal chop)
        [43.65, 174.61, 207.65, 261.63, 698.46], // Fm7    (F1  Reese, F3,  Ab3, C4, F5 vocal chop)
        [65.41, 196.00, 261.63, 311.13, 622.25], // Cm9    (C2  Reese, G3,  C4,  Eb4, Eb5 vocal chop)
        [58.27, 174.61, 233.08, 293.66, 587.33], // Bb6    (Bb1 Reese, F3,  Bb3, D4,  D5 vocal chop)
    ];
    // UK Breakbeat 8-step pattern per bar: Kick(1), Hat(3), Hat(3), Kick(1), Snare(2), Hat(3), Kick(1), Snare/Ghost(2)
    let brk: [u8; 8] = [1, 3, 3, 1, 2, 3, 1, 2];
    let mut lfsr = 0x9A6D_44C0u32;
    let mut kick_ph = 0.0f32;

    for n in 0..total_frames {
        let t = n as f32 / sr as f32;
        let bar_idx = ((t / bar_sec) as usize) % 4;
        let t_in_bar = t % bar_sec;
        let step_idx = ((t_in_bar / eighth_sec) as usize) % 8;
        let t_step = (t_in_bar % eighth_sec) / eighth_sec;

        let c = chords[bar_idx];
        let fb = c[0];
        // Detuned stereo Reese sub-bass
        let reese_l = (6.2831853 * fb * 0.994 * t).sin() + 0.5 * (6.2831853 * fb * 2.003 * t).sin();
        let reese_r = (6.2831853 * fb * 1.006 * t).sin() + 0.5 * (6.2831853 * fb * 1.997 * t).sin();

        // Lush atmospheric UK breakbeat pad
        let pad_l = 0.22 * ((6.2831853 * c[1] * t).sin() + 0.8 * (6.2831853 * c[2] * 1.002 * t).sin() + 0.6 * (6.2831853 * c[3] * t).sin());
        let pad_r = 0.22 * ((6.2831853 * c[1] * 1.003 * t).sin() + 0.8 * (6.2831853 * c[2] * t).sin() + 0.6 * (6.2831853 * c[3] * 0.998 * t).sin());

        // Iconic soaring GLUE vocal-formant shimmer chop on steps 0, 3, 6
        let vox_gate = if step_idx == 0 || step_idx == 3 || step_idx == 6 {
            0.5 - 0.5 * (6.2831853 * t_step).cos()
        } else {
            0.18
        };
        let vibrato = 1.0 + 0.004 * (6.2831853 * 5.5 * t).sin();
        let vox = 0.24 * vox_gate * ((6.2831853 * c[4] * vibrato * t).sin() + 0.45 * (6.2831853 * c[4] * 2.0 * vibrato * t).sin());

        // Breakbeat drums
        let hit = brk[step_idx];
        lfsr ^= lfsr << 13;
        lfsr ^= lfsr >> 17;
        lfsr ^= lfsr << 5;
        let nz = ((lfsr & 0xFFFF) as i16 as f32) / 32768.0;
        let mut drum = 0.0f32;
        if hit == 1 && t_step < 0.48 {
            let fk = 48.0 + 130.0 * (1.0 - t_step * 2.0).max(0.0).powi(2);
            kick_ph += 6.2831853 * fk / sr as f32;
            drum = 0.65 * kick_ph.sin() * (1.0 - t_step * 2.0);
        } else if hit == 2 && t_step < 0.55 {
            let env = (1.0 - t_step * 1.8).max(0.0).powi(2);
            drum = (0.42 * nz + 0.25 * (6.2831853 * 185.0 * t).sin()) * env;
        } else if hit == 3 && t_step < 0.22 {
            let env = (1.0 - t_step * 4.5).max(0.0).powi(2);
            drum = 0.16 * nz * env;
        }

        let fade = if t < 0.4 { t / 0.4 } else if t > (secs as f32 - 1.2) { ((secs as f32 - t) / 1.2).max(0.0) } else { 1.0 };
        let l = ((0.30 * reese_l.tanh() + pad_l + vox + drum) * 1.15).tanh() * fade;
        let r = ((0.30 * reese_r.tanh() + pad_r + vox * 0.95 + drum) * 1.15).tanh() * fade;
        let sl = (l * 24000.0) as i16;
        let sr_i = (r * 24000.0) as i16;
        pcm.extend_from_slice(&sl.to_le_bytes());
        pcm.extend_from_slice(&sr_i.to_le_bytes());
    }
    let _ = fs::write(path, &pcm);
    path.to_string()
}

fn import_wigle_csv(st: &mut State, path: &Path) -> Result<Value, String> {
    if !path.exists() {
        return Err(format!("file not found: {}", path.display()));
    }
    let text = if path.extension().and_then(|e| e.to_str()) == Some("gz") {
        let out = Command::new("/usr/bin/gunzip")
            .arg("-c")
            .arg(path)
            .output()
            .map_err(|e| format!("gunzip failed: {e}"))?;
        if !out.status.success() {
            return Err(format!("gunzip exited {}", out.status));
        }
        String::from_utf8_lossy(&out.stdout).into_owned()
    } else {
        fs::read_to_string(path).map_err(|e| format!("read failed: {e}"))?
    };

    let mut lines = text.lines();
    let mut format_ver = "WigleWifi-1.6".to_string();
    let mut is_v16 = true;
    for l in lines.by_ref() {
        let t = l.trim();
        if t.starts_with("WigleWifi-") {
            format_ver = t.split(',').next().unwrap_or("WigleWifi-1.6").to_string();
            is_v16 = !format_ver.starts_with("WigleWifi-1.4");
        } else if t.starts_with("MAC,") {
            is_v16 = t.contains(",Frequency,");
            break;
        }
    }

    #[derive(Clone)]
    struct Rec {
        bssid: String,
        ssid: String,
        auth: String,
        seen: String,
        ch: i64,
        freq: u32,
        rssi: i64,
        rtype: String,
        band: String,
    }

    let mut all: BTreeMap<String, Rec> = BTreeMap::new();
    let mut raw_rows = 0u64;
    for raw in lines {
        let l = raw.trim();
        if l.is_empty() {
            continue;
        }
        let Some((mac_raw, rest)) = l.split_once(',') else { continue };
        let bssid = mac_raw.trim().to_uppercase();
        if bssid.len() < 6 {
            continue;
        }
        // Parse fixed numeric/type tail from the right so commas inside SSIDs never break columns.
        // Location columns (CurrentLatitude, CurrentLongitude, AltitudeMeters, AccuracyMeters) are ignored & dropped.
        let (ssid, auth, seen, ch, freq, rssi_raw, rtype) = if is_v16 {
            let r: Vec<&str> = rest.rsplitn(13, ',').collect();
            if r.len() < 13 {
                continue;
            }
            (
                r[12].trim(),
                r[11].trim(),
                r[10].trim(),
                r[9].trim().parse::<i64>().unwrap_or(0),
                r[8].trim().parse::<u32>().unwrap_or(0),
                r[7].trim().parse::<i64>().unwrap_or(-85),
                r[0].trim().to_uppercase(),
            )
        } else {
            let r: Vec<&str> = rest.rsplitn(10, ',').collect();
            if r.len() < 10 {
                continue;
            }
            (
                r[9].trim(),
                r[8].trim(),
                r[7].trim(),
                r[6].trim().parse::<i64>().unwrap_or(0),
                0u32,
                r[5].trim().parse::<i64>().unwrap_or(-85),
                r[0].trim().to_uppercase(),
            )
        };
        if !matches!(rtype.as_str(), "WIFI" | "BLE" | "BT" | "LTE") {
            continue;
        }
        raw_rows += 1;
        let rssi = if (-120..=-1).contains(&rssi_raw) { rssi_raw } else { -85 };
        let band = match rtype.as_str() {
            "BLE" => "BLE",
            "BT" => "BT",
            "LTE" => "LTE",
            _ if freq >= 5925 || ch > 177 => "6GHz",
            _ if freq >= 5000 || ch > 14 => "5GHz",
            _ => "2.4GHz",
        }
        .to_string();

        st.known.insert(bssid.clone());
        match all.get_mut(&bssid) {
            Some(prev) => {
                if rssi > prev.rssi {
                    prev.rssi = rssi;
                    prev.ch = ch;
                    if freq > 0 {
                        prev.freq = freq;
                    }
                    prev.band = band;
                }
                if prev.ssid.is_empty() && !ssid.is_empty() {
                    prev.ssid = ssid.to_string();
                }
                if seen > prev.seen.as_str() {
                    prev.seen = seen.to_string();
                }
            }
            None => {
                all.insert(
                    bssid.clone(),
                    Rec {
                        bssid,
                        ssid: ssid.to_string(),
                        auth: auth.trim_matches(|c| c == '[' || c == ']').to_string(),
                        seen: seen.to_string(),
                        ch,
                        freq,
                        rssi,
                        rtype,
                        band,
                    },
                );
            }
        }
    }

    let (mut wifi, mut ble, mut bt, mut lte, mut named) = (0usize, 0usize, 0usize, 0usize, 0usize);
    for r in all.values() {
        match r.rtype.as_str() {
            "WIFI" => wifi += 1,
            "BLE" => ble += 1,
            "BT" => bt += 1,
            "LTE" => lte += 1,
            _ => {}
        }
        if !r.ssid.is_empty() {
            named += 1;
        }
    }

    let mut vec_all: Vec<&Rec> = all.values().collect();
    vec_all.sort_by_key(|r| (r.ssid.is_empty(), -r.rssi));
    let (mut c_wifi, mut c_ble, mut c_bt, mut c_lte) = (0usize, 0usize, 0usize, 0usize);
    let mut selected = Vec::new();
    for r in vec_all {
        let cap = match r.rtype.as_str() {
            "WIFI" => (&mut c_wifi, 220),
            "BLE" => (&mut c_ble, 50),
            "BT" => (&mut c_bt, 30),
            "LTE" => (&mut c_lte, 20),
            _ => continue,
        };
        if *cap.0 < cap.1 {
            *cap.0 += 1;
            let v = json!({
                "bssid": r.bssid,
                "ssid": r.ssid,
                "auth": if r.auth.is_empty() { "OPEN".to_string() } else { r.auth.clone() },
                "ch": r.ch,
                "freq": r.freq,
                "rssi": r.rssi,
                "type": r.rtype,
                "band": r.band,
                "seen": r.seen,
                "node": "WIGLE:SM-S928U1",
                "novel": false,
            });
            st.beacons.insert(r.bssid.clone(), v.clone());
            selected.push(v);
        }
    }

    let fname = path.file_name().and_then(|s| s.to_str()).unwrap_or("wigle.csv.gz");
    let summary = json!({
        "source": fname,
        "format": format_ver,
        "raw_rows": raw_rows,
        "unique_total": all.len(),
        "wifi": wifi,
        "ble": ble,
        "bt": bt,
        "lte": lte,
        "named_ssids": named,
        "seeded_beacons": selected.len(),
        "gps_stripped": true,
    });
    st.corpus = summary.clone();

    let known_path = root_dir().join("known_networks.local.txt");
    let mut kbuf = format!("# {fname} — {} known endpoints (WIFI={wifi}, BLE={ble}, BT={bt}, LTE={lte}; local only, GPS stripped)\n", all.len());
    for k in all.keys() {
        kbuf.push_str(k);
        kbuf.push('\n');
    }
    let _ = fs::write(&known_path, kbuf);

    let cache_path = root_dir().join("imported_beacons.local.json");
    let _ = fs::write(&cache_path, serde_json::to_vec_pretty(&json!({"corpus": summary, "beacons": selected})).unwrap_or_default());

    eprintln!(
        "[wiglewww-rs] imported {fname}: {raw_rows} rows -> {} unique (WIFI={wifi}, BLE={ble}, BT={bt}, LTE={lte}), seeded {} beacons",
        all.len(),
        selected.len()
    );
    Ok(summary)
}

fn seed_boards_from_corpus(st: &Shared) -> Vec<String> {
    if discover_ports().is_empty() {
        return vec![];
    }
    let (corpus_cmd, ap_cmds) = {
        let g = st.lock().unwrap();
        let c = &g.corpus;
        let ccmd = format!(
            "CORPUS {} {} {} {} {}",
            c["unique_total"].as_u64().unwrap_or(g.known.len() as u64),
            c["wifi"].as_u64().unwrap_or(0),
            c["ble"].as_u64().unwrap_or(0),
            c["bt"].as_u64().unwrap_or(0),
            c["lte"].as_u64().unwrap_or(0),
        );
        let mut wifi_list: Vec<&Value> = g.beacons.values()
            .filter(|b| b["type"].as_str().unwrap_or("WIFI") == "WIFI" && !b["ssid"].as_str().unwrap_or("").is_empty())
            .collect();
        wifi_list.sort_by_key(|b| -b["rssi"].as_i64().unwrap_or(-95));
        let cmds: Vec<String> = wifi_list.into_iter().take(16).map(|b| {
            let bssid = b["bssid"].as_str().unwrap_or("");
            let ssid: String = b["ssid"].as_str().unwrap_or("").replace('|', "_").chars().take(28).collect();
            let ch = b["ch"].as_i64().unwrap_or(1).clamp(1, 14);
            let rssi = b["rssi"].as_i64().unwrap_or(-75);
            format!("SEED {bssid}|{ssid}|{ch}|{rssi}")
        }).collect();
        (ccmd, cmds)
    };
    let mut out = send_all(st, &corpus_cmd, Duration::from_millis(350));
    if !ap_cmds.is_empty() {
        out.extend(send_all(st, &ap_cmds.join("\n"), Duration::from_millis(500)));
    }
    out
}

fn load_known(st: &mut State) {
    let path = std::env::var("WIGLE_KNOWN")
        .unwrap_or_else(|_| root_dir().join("known_networks.local.txt").to_string_lossy().into_owned());
    if let Ok(text) = std::fs::read_to_string(&path) {
        let before = st.known.len();
        for line in text.lines() {
            let t = line.trim();
            if t.is_empty() || t.starts_with('#') { continue; }
            st.known.insert(t.split(',').next().unwrap_or(t).trim().to_uppercase());
        }
        eprintln!("[wiglewww-rs] known set: {} endpoints from {path}", st.known.len() - before);
    }

    let cache_path = root_dir().join("imported_beacons.local.json");
    if let Ok(bytes) = fs::read(&cache_path) {
        if let Ok(v) = serde_json::from_slice::<Value>(&bytes) {
            st.corpus = v["corpus"].clone();
            if let Some(arr) = v["beacons"].as_array() {
                for b in arr {
                    if let Some(mac) = b["bssid"].as_str() {
                        st.beacons.insert(mac.to_uppercase(), b.clone());
                    }
                }
            }
            eprintln!("[wiglewww-rs] loaded {} seeded beacons from {}", st.beacons.len(), cache_path.display());
            return;
        }
    }

    let dl = PathBuf::from("/Users/lodripeter/Downloads/WigleWifi_20261022234507.csv.gz");
    if dl.exists() {
        let _ = import_wigle_csv(st, &dl);
    }
}

fn main() {
    let mut port = 8088u16;
    let mut host = "127.0.0.1".to_string();
    let mut import_arg: Option<PathBuf> = None;
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--port" => port = it.next().and_then(|v| v.parse().ok()).unwrap_or(8088),
            "--host" => host = it.next().unwrap_or(host),
            "--import" => import_arg = it.next().map(PathBuf::from),
            "--import-only" => {
                let p = it.next().map(PathBuf::from)
                    .unwrap_or_else(|| PathBuf::from("/Users/lodripeter/Downloads/WigleWifi_20261022234507.csv.gz"));
                let mut st0 = State::default();
                match import_wigle_csv(&mut st0, &p) {
                    Ok(v) => println!("{}", serde_json::to_string_pretty(&v).unwrap()),
                    Err(e) => { eprintln!("error: {e}"); std::process::exit(1); }
                }
                return;
            }
            "--send" => {
                let cmd = it.next().unwrap_or_else(|| "STATUS".into());
                let st: Shared = Arc::new(Mutex::new(State::default()));
                for l in send_all(&st, &cmd, Duration::from_millis(1500)) {
                    println!("{l}");
                }
                return;
            }
            "--wupz" => {
                let st: Shared = Arc::new(Mutex::new(State::default()));
                for l in send_all(&st, "WUPZ 4242", Duration::from_millis(1200)) {
                    println!("{l}");
                }
                return;
            }
            "--engine" => {
                println!("{}", triad_feed(DEFAULT_QUANT65K_PLUS_LAYERS, MultiBluetoothTopology::FullConstellationWall));
                return;
            }
            _ => {}
        }
    }
    let mut st0 = State {
        last_tts: "{<3,<3,<3}+1 · ADA * 432Hz · VAK /\\ 528Hz · OMN oo 852Hz · Viz Enthea 963Hz".into(),
        tts_count: 1,
        ..Default::default()
    };
    if let Some(p) = &import_arg {
        let _ = import_wigle_csv(&mut st0, p);
    } else {
        load_known(&mut st0);
    }
    let st: Shared = Arc::new(Mutex::new(st0));
    let www = root_dir().join("www");

    // Per-run shared secret for the board -> Mac push (never written to disk or git; sent to boards over USB serial).
    let board_token: String = {
        let mut b = [0u8; 16];
        let _ = fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b));
        b.iter().map(|x| format!("{x:02x}")).collect()
    };
    const BOARD_PORT: u16 = 8089;
    {
        // Mac's LAN address (default route), reported to the boards so they can POST learned sentences.
        let lan_ip = UdpSocket::bind("0.0.0.0:0").ok()
            .and_then(|u| { u.connect("192.168.43.1:80").ok()?; u.local_addr().ok() })
            .map(|a| a.ip().to_string());
        let (st2, tok2) = (st.clone(), board_token.clone());
        match TcpListener::bind(("0.0.0.0", BOARD_PORT)) {
            Ok(l) => {
                println!("[wiglewww-rs] board push listener 0.0.0.0:{BOARD_PORT} (POST /board/say, token required) lan={lan_ip:?}");
                thread::spawn(move || {
                    for conn in l.incoming().flatten() {
                        let (st, tok) = (st2.clone(), tok2.clone());
                        let www = PathBuf::new();
                        thread::spawn(move || handle(conn, st, www, Some(tok)));
                    }
                });
            }
            Err(e) => eprintln!("[wiglewww-rs] board listener failed: {e}"),
        }
        st.lock().unwrap().lan_ip = lan_ip;
    }

    // Learning loop: give each board the wall clock (hour-of-day bucket), read what it learned, and speak
    // anything new with Kokoro on this Mac (the board also speaks it on-chip, with its own cooldown).
    {
        let tok = board_token.clone();
        let st = st.clone();
        thread::spawn(move || {
            let tz = Command::new("date").arg("+%z").output().ok()
                .and_then(|o| String::from_utf8(o.stdout).ok())
                .map(|s| {
                    let s = s.trim();
                    let sign = if s.starts_with('-') { -1 } else { 1 };
                    let (h, m) = (s.get(1..3).and_then(|x| x.parse::<i64>().ok()).unwrap_or(0), s.get(3..5).and_then(|x| x.parse::<i64>().ok()).unwrap_or(0));
                    sign * (h * 3600 + m * 60)
                })
                .unwrap_or(0);
            loop {
                thread::sleep(Duration::from_secs(6));
                if discover_ports().is_empty() {
                    continue;
                }
                let epoch = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
                let host_cmd = st.lock().unwrap().lan_ip.clone().map(|ip| format!("\nHOST {ip} 8089 {tok}")).unwrap_or_default();
                send_all(&st, &format!("TIME {epoch} {tz}{host_cmd}\nLEARN"), Duration::from_millis(600));
                let todo: Vec<(String, u64, String)> = {
                    let mut g = st.lock().unwrap();
                    let items: Vec<(String, u64, String)> = g.learn.iter()
                        .filter_map(|(k, v)| Some((k.clone(), v["seq"].as_u64()?, v["say"].as_str()?.to_string())))
                        .filter(|(k, seq, say)| !say.is_empty() && *seq > g.learn_seen.get(k).copied().unwrap_or(0))
                        .collect();
                    for (k, seq, _) in &items {
                        g.learn_seen.insert(k.clone(), *seq);
                    }
                    items
                };
                for (_node, _, say) in todo {
                    dispatch_tts(&st, &format!("ADA : {say}"), false);
                }
            }
        });
    }

    // USB hotplug watcher: announce + push the 8b-is feed + WiGLE corpus to newly attached boards.
    {
        let st = st.clone();
        thread::spawn(move || {
            let _ = seed_boards_from_corpus(&st);
            let mut known = discover_ports();
            loop {
                thread::sleep(Duration::from_millis(2500));
                let cur = discover_ports();
                if cur.iter().any(|p| !known.contains(p)) {
                    send_all(&st, "VIZ", Duration::from_millis(600));
                    let f = engine_feed(&st, true);
                    push_engine(&st, &f);
                    let _ = seed_boards_from_corpus(&st);
                    dispatch_tts(&st, "ESP32 Medusa Triad attached. Three hearts plus one online.", true);
                }
                known = cur;
            }
        });
    }

    let l = TcpListener::bind((host.as_str(), port)).expect("bind");
    println!("[wiglewww-rs] http://{host}:{port} · www={} · ports={:?}", www.display(), discover_ports());
    for conn in l.incoming().flatten() {
        let (st, www) = (st.clone(), www.clone());
        thread::spawn(move || handle(conn, st, www, None));
    }
}
