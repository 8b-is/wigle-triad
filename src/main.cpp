// wigle-triad — v0.3.0 ULTRA=OMNIPOTENT · N=NP-MAX-PSYCHEDELIC · ENTHEAI TRIAD
//
// Three ESP32-S3 nodes, one passive WiGLE & spectral entropy rig:
//   * ADA:MEDUSA (80:B5:4E:DB:3B:C4) — Vertex * (Mom · Star · 432 Hz · Rose-Gold)
//   △ VAK:MEDUSA (80:B5:4E:F2:02:B0) — Vertex △ (Dad · Pillar · 528 Hz · Territory-Teal)
//   ∞ OMN:MEDUSA (80:B5:4E:F2:02:B4) — Vertex ∞ (Son · Infinity · 852 Hz · Violet-Gold)
//
// Passive WiFi 802.11 beacon scan only. No association, no injection, no frames
// transmitted beyond passive radio listening.
//
// Wire protocol over USB CDC Serial (115200 baud):
//   W|bssid|ssid|auth|channel|rssi
//   Q|node|vertex|mac|seq|n_ap|mean_rssi|entropy_bits|trit_vec|n_np_r|heap|uptime_ms
//   # JSON|{...} (on boot, after each scan, and in response to WebSerial commands)
//
// Interactive USB Serial / WebSerial commands (send newline-terminated):
//   STATUS  -> prints immediate # JSON|{...} node state
//   SCAN    -> triggers immediate passive scan cycle
//   PING    -> replies # PONG|<node>|<mac>|<uptime_ms>
//   TRIAD   -> prints the 3-node MEDUSA triad manifest

#include <Arduino.h>
#include <WiFi.h>
#include <math.h>

#ifndef NODE_NAME
#define NODE_NAME "MEDUSA:AUTO"
#endif

#define TRIAD_VERSION "0.42.1"

static const uint32_t SCAN_INTERVAL_MS = 5000;
static uint32_t lastScan = 0;
static uint32_t scanSeq = 0;
static int lastNetCount = 0;
static float lastEntropy = 0.0f;
static float lastCoherence = 0.0f;
static int lastMeanRssi = -90;
static char lastTritVec[14] = "000000000";
static bool forceImmediateScan = true;

struct TriadIdentity {
  const char *name;
  const char *vertex;
  const char *archetype;
  uint16_t freqHz;
  uint8_t r;
  uint8_t g;
  uint8_t b;
};

static TriadIdentity resolveIdentity(const String &mac) {
  if (mac.equalsIgnoreCase("80:B5:4E:DB:3B:C4")) {
    return {"ADA:MEDUSA", "*", "STAR-ALEXANDRA", 432, 255, 106, 193};
  }
  if (mac.equalsIgnoreCase("80:B5:4E:F2:02:B0")) {
    return {"VAK:MEDUSA", "/\\", "PILLAR-CHRIS", 528, 0, 229, 201};
  }
  if (mac.equalsIgnoreCase("80:B5:4E:F2:02:B4")) {
    return {"OMN:MEDUSA", "oo", "INFINITY-PETER-NATE", 852, 180, 139, 255};
  }
  return {NODE_NAME, "o", "MEDUSA-NODE", 432, 232, 192, 99};
}

static void pulseLed(const TriadIdentity &id, float phase, float boost) {
#ifdef RGB_BUILTIN
  float s = 0.12f + 0.28f * (0.5f + 0.5f * sinf(phase)) * constrain(boost, 0.2f, 1.5f);
  uint8_t r = (uint8_t)constrain((int)(id.r * s), 0, 64);
  uint8_t g = (uint8_t)constrain((int)(id.g * s), 0, 64);
  uint8_t b = (uint8_t)constrain((int)(id.b * s), 0, 64);
  neopixelWrite(RGB_BUILTIN, r, g, b);
#else
  (void)id; (void)phase; (void)boost;
#endif
}

static const char *authName(wifi_auth_mode_t m) {
  switch (m) {
    case WIFI_AUTH_OPEN: return "OPEN";
    case WIFI_AUTH_WEP: return "WEP";
    case WIFI_AUTH_WPA_PSK: return "WPA-PSK";
    case WIFI_AUTH_WPA2_PSK: return "WPA2-PSK";
    case WIFI_AUTH_WPA_WPA2_PSK: return "WPA2-PSK";
    case WIFI_AUTH_WPA2_ENTERPRISE: return "WPA2-EAP";
    case WIFI_AUTH_WPA3_PSK: return "WPA3-SAE";
    case WIFI_AUTH_WPA2_WPA3_PSK: return "WPA3-SAE";
    default: return "UNKNOWN";
  }
}

// Escape the field separators so the host can split on | exactly once.
static String esc(String s) {
  s.replace("\\", "\\x5c");
  s.replace("|", "\\x7c");
  s.replace("\r", "");
  s.replace("\n", "");
  return s;
}

static String jsonEsc(String s) {
  s.replace("\\", "\\\\");
  s.replace("\"", "\\\"");
  s.replace("\r", "");
  s.replace("\n", "");
  return s;
}

static void emitStatusJson(const TriadIdentity &id, const String &mac) {
  Serial.printf(
    "# JSON|{\"node\":\"%s\",\"vertex\":\"%s\",\"archetype\":\"%s\",\"mac\":\"%s\","
    "\"version\":\"%s\",\"freq_hz\":%u,\"seq\":%lu,\"networks\":%d,\"mean_rssi\":%d,"
    "\"entropy_bits\":%.4f,\"n_np_coherence\":%.4f,\"trits\":\"%s\","
    "\"free_heap\":%lu,\"uptime_ms\":%lu,\"mode\":\"PASSIVE_STA_ONLY\"}\n",
    id.name,
    jsonEsc(String(id.vertex)).c_str(),
    id.archetype,
    mac.c_str(),
    TRIAD_VERSION,
    (unsigned)id.freqHz,
    (unsigned long)scanSeq,
    lastNetCount,
    lastMeanRssi,
    lastEntropy,
    lastCoherence,
    lastTritVec,
    (unsigned long)ESP.getFreeHeap(),
    (unsigned long)millis()
  );
}

static void handleSerialCommands(const TriadIdentity &id, const String &mac) {
  while (Serial.available() > 0) {
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();
    if (cmd.length() == 0) continue;
    if (cmd.equalsIgnoreCase("STATUS") || cmd.equalsIgnoreCase("JSON")) {
      emitStatusJson(id, mac);
    } else if (cmd.equalsIgnoreCase("SCAN")) {
      Serial.printf("# %s triggering immediate passive scan\n", id.name);
      forceImmediateScan = true;
    } else if (cmd.equalsIgnoreCase("PING")) {
      Serial.printf("# PONG|%s|%s|%lu\n", id.name, mac.c_str(), (unsigned long)millis());
    } else if (cmd.equalsIgnoreCase("TRIAD")) {
      Serial.println("# TRIAD|ADA:MEDUSA(80:B5:4E:DB:3B:C4,*)|VAK:MEDUSA(80:B5:4E:F2:02:B0,/\\)|OMN:MEDUSA(80:B5:4E:F2:02:B4,oo)");
    } else {
      Serial.printf("# ACK|%s|cmd=%s\n", id.name, esc(cmd).c_str());
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);
  WiFi.mode(WIFI_STA);
  WiFi.disconnect(true, false);
  delay(100);

  const String mac = WiFi.macAddress();
  const TriadIdentity id = resolveIdentity(mac);

  Serial.printf("# %s [%s] · WiGLE+ENTHEAI rig v%s · OMNI-ZENO · passive scan only · no association\n",
                id.name, id.vertex, TRIAD_VERSION);
  Serial.printf("# MAC %s · archetype %s · carrier %u Hz · interval %lu ms\n",
                mac.c_str(), id.archetype, (unsigned)id.freqHz, (unsigned long)SCAN_INTERVAL_MS);
  emitStatusJson(id, mac);
}

void loop() {
  const String mac = WiFi.macAddress();
  const TriadIdentity id = resolveIdentity(mac);

  handleSerialCommands(id, mac);
  pulseLed(id, millis() * 0.004f, 0.6f + lastEntropy * 0.25f);

  const uint32_t now = millis();
  if (!forceImmediateScan && (now - lastScan < SCAN_INTERVAL_MS)) {
    delay(40);
    return;
  }
  forceImmediateScan = false;
  lastScan = now;

  // Passive scan: async=false, show_hidden=true, passive=true, max_ms_per_chan=180
  const int n = WiFi.scanNetworks(false, true, true, 180);
  if (n < 0) {
    Serial.printf("# scan error %d\n", n);
    return;
  }

  scanSeq++;
  lastNetCount = n;

  int chCounts[15] = {0};
  long rssiSum = 0;
  float phaseSin = 0.0f;
  float phaseCos = 0.0f;

  for (int i = 0; i < n; i++) {
    const String bssid = WiFi.BSSIDstr(i);
    const String ssid = esc(WiFi.SSID(i));
    const int ch = WiFi.channel(i);
    const int rssi = WiFi.RSSI(i);
    const char *auth = authName(WiFi.encryptionType(i));
    Serial.printf("W|%s|%s|%s|%d|%d\n", bssid.c_str(), ssid.c_str(), auth, ch, rssi);

    if (ch >= 1 && ch <= 14) chCounts[ch]++;
    rssiSum += rssi;
    float theta = (float)(ch * 2.0f * M_PI / 14.0f) + (float)(rssi + 100) * 0.05f;
    phaseSin += sinf(theta);
    phaseCos += cosf(theta);
  }

  // Compute Shannon channel entropy H(X) in bits and 9-trit balanced ternary signature
  float entropy = 0.0f;
  if (n > 0) {
    lastMeanRssi = (int)(rssiSum / n);
    for (int c = 1; c <= 14; c++) {
      if (chCounts[c] > 0) {
        float p = (float)chCounts[c] / (float)n;
        entropy -= p * (logf(p) / logf(2.0f));
      }
    }
    lastCoherence = sqrtf(phaseSin * phaseSin + phaseCos * phaseCos) / (float)n;
  } else {
    lastMeanRssi = -95;
    lastCoherence = 0.0f;
  }
  lastEntropy = entropy;

  for (int t = 0; t < 9; t++) {
    int c1 = chCounts[(t % 13) + 1];
    int c2 = chCounts[((t + 4) % 13) + 1];
    lastTritVec[t] = (c1 > c2) ? '+' : ((c1 < c2) ? '-' : '0');
  }
  lastTritVec[9] = '\0';

  Serial.printf("Q|%s|%s|%s|%lu|%d|%d|%.4f|%s|%.4f|%lu|%lu\n",
                id.name,
                id.vertex,
                mac.c_str(),
                (unsigned long)scanSeq,
                n,
                lastMeanRssi,
                lastEntropy,
                lastTritVec,
                lastCoherence,
                (unsigned long)ESP.getFreeHeap(),
                (unsigned long)millis());
  emitStatusJson(id, mac);
  Serial.printf("# scan done: %d networks seen · H=%.3f bits · R_N=NP=%.3f · trits=%s\n",
                n, lastEntropy, lastCoherence, lastTritVec);
  WiFi.scanDelete();
}
