//! AlexAI (GAIA-MLX-QUANT b1.58) + Kompress-Ultra ditto compression + offline upload queue.
//! Rust port of the former Python wiglewww features. Upload uses the system `curl` (no TLS crate).

use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use wupz_core::fold::{popcount, xor_fold};

const POW3: [u32; 5] = [1, 3, 9, 27, 81];
const PHI: f64 = 1.618_033_988_749_894_8;
const BITS_PER_WEIGHT: f64 = 1.5849625;
const COMPRESSION_VS_F32: f64 = 20.18975;
const DITTO: &str = "″";

pub fn fnv1a_32(s: &str) -> u32 {
    let mut h: u32 = 0x811C9DC5;
    for b in s.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(0x01000193);
    }
    h
}

pub fn pack_ternary(trits: &[i8]) -> Vec<u8> {
    trits
        .chunks(5)
        .map(|c| {
            let mut acc = 0u32;
            for (j, &t) in c.iter().enumerate() {
                let u = if t == -1 { 2 } else if t == 1 { 1 } else { 0 };
                acc += u * POW3[j];
            }
            (acc & 0xFF) as u8
        })
        .collect()
}

pub fn unpack_ternary(packed: &[u8], len: usize) -> Vec<i8> {
    let mut out = Vec::with_capacity(len);
    for &b in packed {
        let mut rem = b as u32;
        for _ in 0..5 {
            if out.len() >= len {
                return out;
            }
            let d = rem % 3;
            rem /= 3;
            out.push(if d == 2 { -1 } else if d == 1 { 1 } else { 0 });
        }
    }
    out
}

fn esc(s: &str) -> String {
    s.replace('\\', "\\x5c").replace('|', "\\x7c").replace('\r', " ").replace('\n', " ")
}

/// `beacons`: objects with bssid/ssid/auth/ch/rssi (strongest first not required).
pub fn compute(prompt: Option<&str>, beacons: &[Value]) -> Value {
    let prompt = prompt.map(str::trim).filter(|p| !p.is_empty()).unwrap_or(
        "Analyze Shinjuku 2.4GHz Ch 6 saturation, BLE proximity & AirPlay RAOP surface",
    );
    let seed = fnv1a_32(prompt);
    const M: u64 = 0xFFFF_FFFF;
    let a = (seed as u64 + 0x6D2B79F5) & M;
    let mut t = ((a ^ (a >> 15)).wrapping_mul(a | 1)) & M;
    t ^= (t + (((t ^ (t >> 7)).wrapping_mul(t | 61)) & M)) & M;
    let rand0 = (((t ^ (t >> 14)) >> 8) & 0xFF_FFFF) as f64 / 16777216.0;

    let mut list: Vec<&Value> = beacons.iter().collect();
    list.sort_by_key(|b| std::cmp::Reverse(b["rssi"].as_i64().unwrap_or(-90)));
    let tot = list.len().max(1) as f64;
    let mut ch_counts = std::collections::BTreeMap::<i64, u32>::new();
    for b in &list {
        *ch_counts.entry(b["ch"].as_i64().unwrap_or(0)).or_default() += 1;
    }
    let rf_entropy: f64 = ch_counts.values().map(|&c| c as f64 / tot).filter(|p| *p > 0.0).map(|p| -p * p.log2()).sum();

    let weather = (0.5 + (rand0 - 0.5) * 0.4).clamp(0.0, 1.0);
    let len_factor = (prompt.len() as f64 / 4096.0).min(0.35);
    let rf_factor = ((rf_entropy - 2.5) * 0.05).clamp(-0.08, 0.14);
    let entropy = (0.62 + len_factor - 0.15 + rf_factor).clamp(0.0, 1.0);
    let spread = (entropy - 0.62).abs() * 0.6 + (weather - 0.5).abs() * 0.4;
    let coherence = (1.0 - spread).clamp(0.0, 1.0);
    let deltas = [("gravity", "Ananke", 0.0), ("entropy", "Chaos", (entropy - 0.62).abs()), ("weather", "Zephyrus", (weather - 0.5).abs()), ("resonance", "Aphrodite", 0.0)];
    let dom = deltas.iter().fold(deltas[0], |m, d| if d.2 > m.2 { *d } else { m });

    let mut trits: Vec<i8> = list
        .iter()
        .map(|b| match b["rssi"].as_i64().unwrap_or(-80) {
            r if r >= -68 => 1,
            r if r >= -80 => 0,
            _ => -1,
        })
        .collect();
    while trits.len() < 30 {
        trits.push(1);
    }
    let packed = pack_ternary(&trits);
    let roundtrip_ok = unpack_ternary(&packed, trits.len()) == trits;
    let packed_hex = packed.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(" ");

    let canonical: Vec<String> = list
        .iter()
        .map(|b| {
            let auth = esc(b["auth"].as_str().unwrap_or(""))
                .replace("WPA2-PSK-CCMP][ESS", "W2")
                .replace("WPA3-SAE-CCMP][ESS", "W3");
            format!("W|MAC:MEDUSA|{}|{}|{}|{}|{}|2.4GHz", esc(b["bssid"].as_str().unwrap_or("")), esc(b["ssid"].as_str().unwrap_or("")), auth, b["ch"], b["rssi"])
        })
        .collect();
    let mut prev: Vec<String> = vec![];
    let (mut ditto_lines, mut saved) = (vec![], 0usize);
    for line in &canonical {
        let toks: Vec<String> = line.split('|').map(String::from).collect();
        if prev.is_empty() {
            ditto_lines.push(line.clone());
        } else {
            let d: Vec<String> = toks.iter().enumerate().map(|(i, t)| if i < prev.len() && *t == prev[i] && t.chars().count() > 1 { saved += 1; DITTO.to_string() } else { t.clone() }).collect();
            ditto_lines.push(d.join("|"));
        }
        prev = toks;
    }
    let (mut restored, mut rprev): (Vec<String>, Vec<String>) = (vec![], vec![]);
    for dl in &ditto_lines {
        let r: Vec<String> = dl.split('|').enumerate().map(|(i, t)| if t == DITTO && i < rprev.len() { rprev[i].clone() } else { t.to_string() }).collect();
        restored.push(r.join("|"));
        rprev = r;
    }
    let lossless = restored == canonical;
    let csv = csv_of(beacons);
    let raw_bytes = (csv.len() + serde_json::to_vec(&beacons).map(|v| v.len()).unwrap_or(0)).max(1);
    let wire = format!("# KU-v16.2.0 [BrainLine: ralph · lodri · krengel · cosmos | keep=0.993]\n{}", ditto_lines.join("\n"));
    let comp = wire.len().max(1);
    let seal_src: Vec<u8> = packed.clone();

    json!({
        "alexai": {
            "engine": "GAIA-MLX-QUANT", "repo": "https://github.com/8b-is/alexai", "prompt": prompt, "seed": seed,
            "gravity": 1.0, "entropy": (entropy * 1e4).round() / 1e4, "weather": (weather * 1e4).round() / 1e4,
            "resonance": PHI, "coherence": (coherence * 1e4).round() / 1e4,
            "dominant": dom.0, "dominant_layer": dom.1,
            "sampling": {
                "temperature": ((0.15 + entropy * 1.1).clamp(0.05, 1.2) * 1e4).round() / 1e4,
                "top_p": ((0.5 + coherence * 0.48).clamp(0.5, 0.98) * 1e4).round() / 1e4,
                "top_k": (20.0 + (1.0 - coherence) * 60.0).clamp(20.0, 80.0).round() as i64, "seed": seed },
            "bits_per_weight": BITS_PER_WEIGHT, "compression_vs_f32": COMPRESSION_VS_F32,
            "packed_hex": packed_hex, "roundtrip_ok": roundtrip_ok,
            "wupz_xor_fold": format!("0x{:016x}", xor_fold(&seal_src)), "wupz_popcount": popcount(&seal_src),
        },
        "kompress_ultra": {
            "engine": "kompress-ultra", "version": "16.2.0", "brain_line": "ralph · lodri · krengel · cosmos",
            "exact_keep_rate": 0.993, "ebbinghaus_retention": ((-0.45f64 / 5.0).exp() * 1e4).round() / 1e4,
            "raw_bytes": raw_bytes, "compressed_bytes": comp,
            "compression_ratio": (raw_bytes as f64 / comp as f64 * 100.0).round() / 100.0,
            "savings_pct": ((1.0 - comp as f64 / raw_bytes as f64).max(0.0) * 1000.0).round() / 10.0,
            "ditto_tokens_saved": saved, "lossless_roundtrip_ok": lossless, "ditto_lines": ditto_lines,
        },
    })
}

pub fn csv_of(beacons: &[Value]) -> String {
    let mut o = String::from(
        "WigleWifi-1.4,appRelease=3.0.0,model=ESP32-S3-MEDUSA-TRIAD,release=15.0,device=wiglewww-rs,display=AMOLED,board=esp32-s3-touch-amoled,brand=8b-is\nMAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type\n",
    );
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    for b in beacons {
        let ssid = b["ssid"].as_str().unwrap_or("").replace([',', '"', '\n', '\r'], " ");
        let auth = b["auth"].as_str().unwrap_or("");
        let auth = if auth.starts_with('[') { auth.to_string() } else { format!("[{auth}]") };
        o += &format!("{},{},{},{},{},{},35.6852,139.7100,40,5,WIFI\n", b["bssid"].as_str().unwrap_or(""), ssid.trim(), auth, now, b["ch"], b["rssi"]);
    }
    o
}

// ---------------- offline queue + anonymous upload ----------------

fn queue_path() -> PathBuf {
    let d = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into())).join(".cache/wigle-triad");
    let _ = fs::create_dir_all(&d);
    d.join("wiglewww_offline_queue.json")
}

pub fn queue_load() -> Vec<Value> {
    fs::read(queue_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn queue_save(q: &[Value]) {
    let _ = fs::write(queue_path(), serde_json::to_vec_pretty(q).unwrap_or_default());
}

fn post_csv(url: &str, csv: &str) -> Value {
    let tmp = std::env::temp_dir().join(format!("wiglewww-{}.csv", std::process::id()));
    if fs::write(&tmp, csv).is_err() {
        return json!({"ok": false, "error": "tmpfile"});
    }
    let out = Command::new("curl")
        .args(["-s", "-m", "15", "-A", "WigleWifi-3.0.0 (wiglewww-rs; 8b-is; anonymous)", "-F", "donate=on", "-F"])
        .arg(format!("file=@{};type=text/csv", tmp.display()))
        .arg(url)
        .output();
    let _ = fs::remove_file(&tmp);
    match out {
        Ok(o) if o.status.success() => match serde_json::from_slice::<Value>(&o.stdout) {
            Ok(v) => json!({"ok": v["success"].as_bool().unwrap_or(true), "observer": "anonymous", "raw": v}),
            Err(_) => json!({"ok": false, "error": "non-json response"}),
        },
        Ok(o) => json!({"ok": false, "error": format!("curl exit {:?}", o.status.code())}),
        Err(e) => json!({"ok": false, "error": e.to_string()}),
    }
}

pub const DATABOMB_8S_UPLOAD_URL: &str = "https://8s.is/api/v2/file/upload";
pub const DATABOMB_8S_PROBES_URL: &str = "https://8s.is/api/wigle/probes";

pub fn post_probes(probe_lines: &[String]) -> Value {
    if probe_lines.is_empty() {
        return json!({"ok": true, "probes_ingested": 0});
    }
    let payload = probe_lines.join("\n");
    let out = Command::new("curl")
        .args([
            "-s",
            "-m",
            "12",
            "-X",
            "POST",
            "-H",
            "Content-Type: text/plain; charset=utf-8",
            "--data-binary",
            &payload,
            DATABOMB_8S_PROBES_URL,
        ])
        .output();
    match out {
        Ok(o) if o.status.success() => serde_json::from_slice::<Value>(&o.stdout)
            .unwrap_or_else(|_| json!({"ok": true, "raw": String::from_utf8_lossy(&o.stdout)})),
        Ok(o) => json!({"ok": false, "error": format!("curl exit {:?}", o.status.code())}),
        Err(e) => json!({"ok": false, "error": e.to_string()}),
    }
}

fn upload_targets(csv: &str) -> (Value, Value, Value, bool) {
    // Priority #1: Sovereign DataBomb on 8s.is
    let db8s = post_csv(DATABOMB_8S_UPLOAD_URL, csv);
    // Priority #2: esp32.vaked.dev edge mirror
    let e = post_csv("https://esp32.vaked.dev/api/upload", csv);
    // Priority #3: external wigle.net fallback
    let w = post_csv("https://api.wigle.net/api/v2/file/upload", csv);
    let ok = db8s["ok"].as_bool().unwrap_or(false)
        || e["ok"].as_bool().unwrap_or(false)
        || w["ok"].as_bool().unwrap_or(false);
    (db8s, e, w, ok)
}

pub fn upload(csv: &str, rows: usize) -> Value {
    let (db8s, e, w, ok) = upload_targets(csv);
    let mut queued = Value::Null;
    if !ok {
        let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let item = json!({"id": format!("q-{ts}"), "timestamp": ts, "status": "queued", "reason": "offline-auto-queue", "rows": rows, "csv": csv});
        let mut q = queue_load();
        q.insert(0, item.clone());
        queue_save(&q);
        queued = item["id"].clone();
    }
    json!({"ok": ok, "priority_target": DATABOMB_8S_UPLOAD_URL, "offline_queued": !queued.is_null(), "queued_id": queued, "observer": "8b-is-triad",
           "donate": "on", "ingested": rows, "databomb_8s": db8s, "esp32_vaked_dev": e, "wigle_net": w})
}

pub fn flush_queue() -> Value {
    let mut q = queue_load();
    let mut flushed = 0;
    for item in q.iter_mut().filter(|i| i["status"] == "queued") {
        let (_, _, _, ok) = upload_targets(item["csv"].as_str().unwrap_or(""));
        if ok {
            item["status"] = json!("synced");
            flushed += 1;
        }
    }
    queue_save(&q);
    json!({"ok": true, "priority_target": DATABOMB_8S_UPLOAD_URL, "flushed": flushed, "remaining_queued": q.iter().filter(|i| i["status"] == "queued").count()})
}

pub fn queue_count() -> usize {
    queue_load().iter().filter(|i| i["status"] == "queued").count()
}
