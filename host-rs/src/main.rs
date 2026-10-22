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
use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
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
    nodes: BTreeMap<String, Value>,
    beacons: BTreeMap<String, Value>,
    viz_idx: usize,
    last_tts: String,
    tts_count: u64,
    engine: Option<(Instant, Value)>,
    learn: BTreeMap<String, Value>,
    learn_seen: BTreeMap<String, u64>,
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
    let _ = Command::new("stty")
        .args(["-f", port, "115200", "raw", "-echo", "min", "0", "time", "2"])
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

fn handle(mut s: TcpStream, st: Shared, www: PathBuf) {
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
            let lines = send_all(&st, "JSON", Duration::from_millis(400));
            let ak = alexai::compute(None, &st.lock().unwrap().beacons.values().cloned().collect::<Vec<_>>());
            let viz = viz_json(&st);
            let g = st.lock().unwrap();
            let v = json!({
                "surface": "http://127.0.0.1:8088", "mirror": "https://esp32.vaked.dev",
                "version": "3.0.0+rust-wupz-8b-is", "triad_hearts": "{<3,<3,<3}+1",
                "offline_queue_count": alexai::queue_count(), "alexai": ak["alexai"], "kompress_ultra": ak["kompress_ultra"],
                "runtime": "rust (no python)", "viz_enthea": viz, "wupz_seal": wupz_seal(&g),
                "ports": ports, "nodes": g.nodes.values().collect::<Vec<_>>(),
                "beacons_count": g.beacons.len(), "beacons": g.beacons.values().collect::<Vec<_>>(),
                "raw_lines": lines,
            });
            respond(&mut s, 200, json_t, &jbody(v));
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

fn main() {
    let mut port = 8088u16;
    let mut host = "127.0.0.1".to_string();
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--port" => port = it.next().and_then(|v| v.parse().ok()).unwrap_or(8088),
            "--host" => host = it.next().unwrap_or(host),
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
    let st: Shared = Arc::new(Mutex::new(State {
        last_tts: "{<3,<3,<3}+1 · ADA * 432Hz · VAK /\\ 528Hz · OMN oo 852Hz · Viz Enthea 963Hz".into(),
        tts_count: 1,
        ..Default::default()
    }));
    let www = root_dir().join("www");

    // Learning loop: give each board the wall clock (hour-of-day bucket), read what it learned, and speak
    // anything new with Kokoro on this Mac (the board also speaks it on-chip, with its own cooldown).
    {
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
                send_all(&st, &format!("TIME {epoch} {tz}\nLEARN"), Duration::from_millis(600));
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
                for (node, _, say) in todo {
                    dispatch_tts(&st, &format!("{node}: {say}"), false);
                }
            }
        });
    }

    // USB hotplug watcher: announce + push the 8b-is feed to newly attached boards.
    {
        let st = st.clone();
        thread::spawn(move || {
            let mut known = discover_ports();
            loop {
                thread::sleep(Duration::from_millis(2500));
                let cur = discover_ports();
                if cur.iter().any(|p| !known.contains(p)) {
                    send_all(&st, "VIZ", Duration::from_millis(600));
                    let f = engine_feed(&st, true);
                    push_engine(&st, &f);
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
        thread::spawn(move || handle(conn, st, www));
    }
}
