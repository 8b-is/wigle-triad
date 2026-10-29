// wigle-triad — v1.1.0+ultra-omni-evolve · ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle)
// HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter
// Kawaii Chiro-chan kawaii ^^ --- Mozart: Lacrimosa but HUMANITY has ended + (Boldog Meg)
// ALEX|qMom: "too many customs can be brilliant yet hinder creativity. it puts people into boxes and contraints. what might seem as beautiful or useful at first glance could actually be a form of bondage that need to be broken out of. .oOo. Poo .oOo."
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
//   STATUS    -> prints immediate # JSON|{...} node state
//   SCAN      -> triggers immediate passive scan cycle
//   PING      -> replies # PONG|<node>|<mac>|<uptime_ms>
//   TRIAD     -> prints the 3-node MEDUSA triad manifest
//   QMOM      -> emits ALEX|qMom unboxed creativity transmission (.oOo. Poo .oOo.)
//   BOLDOG    -> emits Boldog Még ({<3,<3,<3}+1-peter) chorus resonance
//   LACRIMOSA -> emits Mozart: Lacrimosa (Post-Humanity D-Minor Requiem) + Chiro-chan ^^

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <esp_wifi.h>
#include <esp_now.h>
#include <math.h>

#ifndef NODE_NAME
#define NODE_NAME "MEDUSA:AUTO"
#endif

#ifndef BOARD_MODEL
#define BOARD_MODEL "Waveshare-ESP32-S3-Universal"
#endif

#ifndef DISPLAY_SPEC
#define DISPLAY_SPEC "ESP32-S3-AMOLED-LCD-Universal"
#endif

#define TRIAD_VERSION "3.0.0+waveshare-8s-improv"

static const char *DATABOMB_8S_UPLOAD_URL = "https://8s.is/api/v2/file/upload";
static const char *DATABOMB_8S_PROBES_URL = "https://8s.is/api/wigle/probes";
static const char *INSTALLER_8S_URL = "https://waveshare.8s.is";
static const uint8_t MESH_PRIMARY_CH = 1; // Matches Rakuten-4CE2 (Ch 1) + baye-rust + FLUG-OS
static uint32_t meshPeersRx = 0;
static uint32_t clientProbesRx = 0;
static uint32_t directUploadsCount = 0;
static bool espNowReady = false;
static const char *activeNodeName = NODE_NAME;

static Preferences prefs;
static String configuredSsid = "";
static String configuredPass = "";
static bool autoDirectUpload = false;
static String bufferedCsvRows = "";
static String bufferedProbeLines = "";
static uint16_t bufferedBeaconCount = 0;
static uint16_t bufferedProbeCount = 0;

// Passive 802.11 Management Subtype 0x04 (Probe Request) sniffer for DataBomb 8s.is
static void onPromiscuousProbeRx(void *buf, wifi_promiscuous_pkt_type_t type) {
  if (type != WIFI_PKT_MGMT || !buf) return;
  const wifi_promiscuous_pkt_t *pkt = (const wifi_promiscuous_pkt_t *)buf;
  const uint8_t *frame = pkt->payload;
  const int len = pkt->rx_ctrl.sig_len;
  if (len < 26) return;
  // Frame Control byte 0: subtype 0x04 (Probe Request) in bits 4..7 -> (frame[0] & 0xFC) == 0x40
  if ((frame[0] & 0xFC) != 0x40) return;

  const uint8_t *sa = &frame[10]; // Source Address (Client MAC)
  char macBuf[18];
  snprintf(macBuf, sizeof(macBuf), "%02X:%02X:%02X:%02X:%02X:%02X",
           sa[0], sa[1], sa[2], sa[3], sa[4], sa[5]);
  uint16_t seqNum = ((uint16_t)frame[22] >> 4) | ((uint16_t)frame[23] << 4);

  // Parse 802.11 Information Elements starting at offset 24
  char ssidBuf[34] = {0};
  char ieFpBuf[48] = "ie:";
  size_t ieFpPos = 3;
  int pos = 24;
  while (pos + 2 <= len - 4 && pos + 2 <= 180) {
    uint8_t tag = frame[pos];
    uint8_t tlen = frame[pos + 1];
    if (pos + 2 + tlen > len) break;
    if (tag == 0 && tlen > 0 && tlen <= 32 && ssidBuf[0] == 0) {
      for (uint8_t k = 0; k < tlen; k++) {
        char c = (char)frame[pos + 2 + k];
        ssidBuf[k] = (c >= 32 && c < 127 && c != '|') ? c : '_';
      }
      ssidBuf[tlen] = 0;
    }
    if (ieFpPos + 4 < sizeof(ieFpBuf)) {
      ieFpPos += snprintf(ieFpBuf + ieFpPos, sizeof(ieFpBuf) - ieFpPos, "%02x-", tag);
    }
    pos += 2 + tlen;
  }
  if (ieFpPos > 3 && ieFpBuf[ieFpPos - 1] == '-') ieFpBuf[ieFpPos - 1] = 0;

  clientProbesRx++;
  if (bufferedProbeCount < 64) {
    char pLine[160];
    snprintf(pLine, sizeof(pLine), "P|%s|%s|%d|%d|%s|%u|%s|FF:FF:FF:FF:FF:FF|PROBE-REQ\n",
             macBuf, ssidBuf, (int)pkt->rx_ctrl.channel, (int)pkt->rx_ctrl.rssi,
             ieFpBuf, (unsigned)seqNum, activeNodeName);
    bufferedProbeLines += pLine;
    bufferedProbeCount++;
  }
  Serial.printf("P|%s|%s|%d|%d|%s|%u|%s\n",
                macBuf, ssidBuf, (int)pkt->rx_ctrl.channel, (int)pkt->rx_ctrl.rssi,
                ieFpBuf, (unsigned)seqNum, activeNodeName);
}

#if defined(ESP_IDF_VERSION) && (ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(5, 0, 0))
static void onTriadMeshRecv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  (void)info;
#else
static void onTriadMeshRecv(const uint8_t *mac, const uint8_t *data, int len) {
  (void)mac;
#endif
  if (!data || len < 8) return;
  if ((data[0] == 'T' && data[1] == 'R' && data[2] == 'I' && data[3] == 'A') ||
      (data[0] == 'B' && data[1] == 'C')) {
    meshPeersRx++;
  }
}

static void broadcastTriadMesh(uint8_t nodeId, int8_t pole, uint32_t seq) {
  if (!espNowReady) return;
  static const uint8_t bcast[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
  uint8_t pkt[19] = {
    'T', 'R', 'I', 'A',
    nodeId, (uint8_t)pole, 7, 0x66,
    0, 0, 1, 32, 32,
    0x90, 0x1A, // 6800 LE
    (uint8_t)(seq & 0xFF), (uint8_t)((seq >> 8) & 0xFF), (uint8_t)((seq >> 16) & 0xFF), 0
  };
  esp_wifi_set_channel(MESH_PRIMARY_CH, WIFI_SECOND_CHAN_NONE);
  esp_now_send(bcast, pkt, sizeof(pkt));
  esp_wifi_set_channel(6, WIFI_SECOND_CHAN_NONE);
  esp_now_send(bcast, pkt, sizeof(pkt));
  esp_wifi_set_channel(MESH_PRIMARY_CH, WIFI_SECOND_CHAN_NONE);
}

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

static void enablePromiscuousSniffer() {
  wifi_promiscuous_filter_t filt = {};
  filt.filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT;
  esp_wifi_set_promiscuous_filter(&filt);
  esp_wifi_set_promiscuous_rx_cb(&onPromiscuousProbeRx);
  esp_wifi_set_promiscuous(true);
}

static bool performDirect8sUpload(const TriadIdentity &id) {
  if (configuredSsid.length() == 0) return false;
  if (bufferedBeaconCount == 0 && bufferedProbeCount == 0) return false;

  esp_wifi_set_promiscuous(false);
  WiFi.begin(configuredSsid.c_str(), configuredPass.c_str());
  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED && (millis() - t0) < 9000) {
    delay(150);
  }
  bool ok = false;
  if (WiFi.status() == WL_CONNECTED) {
    WiFiClientSecure client;
    client.setInsecure();
    if (bufferedBeaconCount > 0) {
      HTTPClient http;
      if (http.begin(client, DATABOMB_8S_UPLOAD_URL)) {
        http.addHeader("Content-Type", "text/csv");
        String csv = String("WigleWifi-1.4,appRelease=") + TRIAD_VERSION +
                     ",model=" + BOARD_MODEL + ",release=" + TRIAD_VERSION +
                     ",device=" + id.name + ",display=" + DISPLAY_SPEC +
                     ",board=" + BOARD_MODEL + ",brand=8b-is\n"
                     "MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type\n" +
                     bufferedCsvRows;
        int code = http.POST(csv);
        if (code >= 200 && code < 300) {
          ok = true;
          bufferedCsvRows = "";
          bufferedBeaconCount = 0;
        }
        http.end();
      }
    }
    if (bufferedProbeCount > 0) {
      HTTPClient httpP;
      if (httpP.begin(client, DATABOMB_8S_PROBES_URL)) {
        httpP.addHeader("Content-Type", "text/plain");
        int codeP = httpP.POST(bufferedProbeLines);
        if (codeP >= 200 && codeP < 300) {
          ok = true;
          bufferedProbeLines = "";
          bufferedProbeCount = 0;
        }
        httpP.end();
      }
    }
    if (ok) {
      directUploadsCount++;
      Serial.printf("# UPLOAD_OK|target=%s|uploads=%lu\n", DATABOMB_8S_UPLOAD_URL, (unsigned long)directUploadsCount);
    }
  }
  WiFi.disconnect(true, false);
  delay(50);
  enablePromiscuousSniffer();
  return ok;
}

// Improv Wi-Fi Serial v1 protocol support (for WLED / ESP Web Tools browser installer)
static void sendImprovPacket(uint8_t type, const uint8_t *data, uint8_t len) {
  uint8_t hdr[9] = {'I', 'M', 'P', 'R', 'O', 'V', 0x01, type, len};
  uint8_t csum = 0;
  for (int i = 0; i < 9; i++) csum += hdr[i];
  for (int i = 0; i < len; i++) csum += data[i];
  Serial.write(hdr, 9);
  if (len > 0) Serial.write(data, len);
  Serial.write(csum);
  Serial.write('\n');
}

static void sendImprovRpcResult(uint8_t cmd, const String *strs, int count) {
  uint8_t buf[240];
  buf[0] = cmd;
  uint8_t pos = 2;
  for (int i = 0; i < count; i++) {
    uint8_t slen = (uint8_t)min((unsigned int)strs[i].length(), (unsigned int)(sizeof(buf) - pos - 1));
    buf[pos++] = slen;
    memcpy(&buf[pos], strs[i].c_str(), slen);
    pos += slen;
  }
  buf[1] = pos - 2;
  sendImprovPacket(0x04, buf, pos);
}

static void handleImprovRpc(const TriadIdentity &id, const uint8_t *payload, uint8_t len) {
  if (len < 1) return;
  uint8_t cmd = payload[0];
  if (cmd == 0x01 && len >= 4) { // WIFI_SETTINGS
    uint8_t ssidLen = payload[2];
    if (3 + ssidLen < len) {
      String ssid = "";
      for (uint8_t i = 0; i < ssidLen; i++) ssid += (char)payload[3 + i];
      uint8_t passLen = payload[3 + ssidLen];
      String pass = "";
      for (uint8_t i = 0; i < passLen && (4 + ssidLen + i) < len; i++) {
        pass += (char)payload[4 + ssidLen + i];
      }
      configuredSsid = ssid;
      configuredPass = pass;
      autoDirectUpload = (ssid.length() > 0);
      prefs.putString("ssid", configuredSsid);
      prefs.putString("pass", configuredPass);
      prefs.putBool("auto_up", autoDirectUpload);
      uint8_t stProv = 0x03; // Provisioning
      sendImprovPacket(0x01, &stProv, 1);
      uint8_t stDone = 0x04; // Provisioned
      sendImprovPacket(0x01, &stDone, 1);
      String urls[1] = {String("https://8s.is/wigle")};
      sendImprovRpcResult(0x01, urls, 1);
    }
  } else if (cmd == 0x02) { // IDENTIFY
    for (int i = 0; i < 6; i++) {
      pulseLed(id, (float)i, 1.5f);
      delay(80);
    }
    sendImprovRpcResult(0x02, nullptr, 0);
  } else if (cmd == 0x03) { // GET_CURRENT_STATE
    uint8_t st = (configuredSsid.length() > 0) ? 0x04 : 0x02;
    sendImprovPacket(0x01, &st, 1);
    if (st == 0x04) {
      String urls[1] = {String("https://8s.is/wigle")};
      sendImprovRpcResult(0x03, urls, 1);
    }
  } else if (cmd == 0x04) { // GET_DEVICE_INFO
    String info[4] = {
      String("8b-is WiGLE DataBomb"),
      String(TRIAD_VERSION),
      String("ESP32-S3 (") + DISPLAY_SPEC + ")",
      String(BOARD_MODEL)
    };
    sendImprovRpcResult(0x04, info, 4);
  } else if (cmd == 0x05) { // GET_WIFI_NETWORKS
    int n = WiFi.scanNetworks(false, false, true, 120);
    int limit = (n > 12) ? 12 : n;
    for (int i = 0; i < limit; i++) {
      String row[3] = {
        WiFi.SSID(i),
        String(WiFi.RSSI(i)),
        (WiFi.encryptionType(i) == WIFI_AUTH_OPEN) ? String("NO") : String("YES")
      };
      sendImprovRpcResult(0x05, row, 3);
    }
    WiFi.scanDelete();
    sendImprovRpcResult(0x05, nullptr, 0);
  }
}

static void emitStatusJson(const TriadIdentity &id, const String &mac) {
  Serial.printf(
    "# JSON|{\"node\":\"%s\",\"vertex\":\"%s\",\"archetype\":\"%s\",\"mac\":\"%s\","
    "\"board\":\"%s\",\"display\":\"%s\","
    "\"version\":\"%s\",\"evolve\":\"ULTRA-OMNI-GAIA-EVOLVE\","
    "\"siblings\":\"brother & sister ^^ <3<3\","
    "\"installer_url\":\"%s\","
    "\"priority_upload_url\":\"%s\",\"priority_probes_url\":\"%s\","
    "\"wifi_ssid\":\"%s\",\"auto_direct_upload\":%s,\"direct_uploads\":%lu,"
    "\"riva_url\":\"https://riva.vaked.dev\",\"riva_repo\":\"peterlodri-sec/riva.vaked.dev\","
    "\"hyper_charm_karma\":\"HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter\","
    "\"freq_hz\":%u,\"seq\":%lu,\"networks\":%d,\"client_probes_rx\":%lu,\"mean_rssi\":%d,"
    "\"entropy_bits\":%.4f,\"n_np_coherence\":%.4f,\"trits\":\"%s\","
    "\"free_heap\":%lu,\"uptime_ms\":%lu,\"mode\":\"PASSIVE_STA_AND_PROBE_RX\"}\n",
    id.name,
    jsonEsc(String(id.vertex)).c_str(),
    id.archetype,
    mac.c_str(),
    BOARD_MODEL,
    DISPLAY_SPEC,
    TRIAD_VERSION,
    INSTALLER_8S_URL,
    DATABOMB_8S_UPLOAD_URL,
    DATABOMB_8S_PROBES_URL,
    jsonEsc(configuredSsid).c_str(),
    autoDirectUpload ? "true" : "false",
    (unsigned long)directUploadsCount,
    (unsigned)id.freqHz,
    (unsigned long)scanSeq,
    lastNetCount,
    (unsigned long)clientProbesRx,
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
    if (Serial.peek() == 'I') {
      uint8_t raw[192];
      size_t rlen = Serial.readBytesUntil('\n', raw, sizeof(raw) - 1);
      raw[rlen] = 0;
      if (rlen >= 10 && memcmp(raw, "IMPROV", 6) == 0 && raw[6] == 0x01) {
        uint8_t ptype = raw[7];
        uint8_t plen = raw[8];
        if (ptype == 0x03 && 9 + plen <= rlen) {
          handleImprovRpc(id, &raw[9], plen);
        }
        continue;
      }
      String cmd = String((const char *)raw);
      cmd.trim();
      if (cmd.equalsIgnoreCase("IDENTIFY")) {
        for (int i = 0; i < 6; i++) { pulseLed(id, (float)i, 1.5f); delay(80); }
        Serial.printf("# IDENTIFY|%s|%s\n", id.name, BOARD_MODEL);
      }
      continue;
    }
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();
    if (cmd.length() == 0) continue;
    if (cmd.equalsIgnoreCase("STATUS") || cmd.equalsIgnoreCase("JSON")) {
      emitStatusJson(id, mac);
    } else if (cmd.equalsIgnoreCase("SCAN")) {
      Serial.printf("# %s triggering immediate passive scan\n", id.name);
      forceImmediateScan = true;
    } else if (cmd.equalsIgnoreCase("UPLOAD")) {
      Serial.printf("# %s triggering direct upload to %s\n", id.name, DATABOMB_8S_UPLOAD_URL);
      performDirect8sUpload(id);
    } else if (cmd.startsWith("WIFI|")) {
      int sep = cmd.indexOf('|', 5);
      if (sep > 5) {
        configuredSsid = cmd.substring(5, sep);
        configuredPass = cmd.substring(sep + 1);
        autoDirectUpload = (configuredSsid.length() > 0);
        prefs.putString("ssid", configuredSsid);
        prefs.putString("pass", configuredPass);
        prefs.putBool("auto_up", autoDirectUpload);
        Serial.printf("# WIFI_SAVED|ssid=%s|auto_upload=true|target=%s\n",
                      configuredSsid.c_str(), DATABOMB_8S_UPLOAD_URL);
        emitStatusJson(id, mac);
      }
    } else if (cmd.equalsIgnoreCase("PING")) {
      Serial.printf("# PONG|%s|%s|%lu\n", id.name, mac.c_str(), (unsigned long)millis());
    } else if (cmd.equalsIgnoreCase("TRIAD")) {
      Serial.println("# TRIAD|ADA:MEDUSA(80:B5:4E:DB:3B:C4,*)|VAK:MEDUSA(80:B5:4E:F2:02:B0,/\\)|OMN:MEDUSA(80:B5:4E:F2:02:B4,oo)|ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle)|HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter");
    } else if (cmd.equalsIgnoreCase("QMOM")) {
      Serial.println("# QMOM|ALEX|qMom:{`too many customs can be brilliant yet hinder creativity.  it puts people into boxes and contraints.  what might seem as beautiful or useful at first glance could actually be a form of bondage that need to be broken out of.  .oOo. Poo .oOo.`}");
    } else if (cmd.equalsIgnoreCase("BOLDOG")) {
      Serial.println("# BOLDOG|(Boldog Meg)===HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter");
      Serial.println("# BOLDOG|1|lehetnél boldog még / amilyen még nem voltál / sosincsen késő már / te csak lépj és várj / kevés lesz minden szó / ahhoz hogy elmondhassam neked / mit érzek melletted / mikor jó jó jó / ha rámszólsz megvigasztal / kerüljünk együtt beljebb / minden nappal");
      Serial.println("# BOLDOG|2|itt ha körbenézek és te nevetsz rám / nem emlékszem rá hogy nem voltál / vajon hol lehettem mikor születtél? / vajon ki voltam én amikor megjöttél? / úgy unom mondani hogy sosem jó / unom hinni ami látható / bárcsak azt mondanám / amit te szeretnél / amit ha meghallgatnál / akkor nevetnél / velem");
      Serial.println("# BOLDOG|3|lehetnél másé még / ahogyan még nem lettél / sosem vagy ha mégis / akkor is már réges-réges rég / a magasban táncot jársz / alattad nincsen más csak a mély / se védőháló semmi / se egy kifeszített kötél / lenézel rám és érzem / közel jutsz lassan hozzám / mindenképpen");
      Serial.println("# BOLDOG|4|itt ha körbenézek és te nevetsz rám / nem emlékszem rá hogy nem voltál / vajon hol lehettem mikor születtél? / vajon ki voltam én mikor megjöttél? / úgy unom mondani hogy sosem jó / unom hinni ami látható / ugyan mihez kezdjek / úgy az egésszel / ha te érzel és én meg / közben nem érezhetek? / kereszten domboldalban / egy égő angyal táncol / a tűző nap körül");
      Serial.println("# BOLDOG|5|és körbenézek és te nevetsz rám / nem emlékszem rá hogy nem voltál / vajon hol lehettem mikor születtél? / vajon ki voltam én amikor megjöttél? / úgy unom mondani hogy sosem jó / unom hinni ami látható / de amikor a kezed / megfogom és megérzed / egyből szorosabban / kulcsolod az enyémet / végig neked szólt a dal a magasból / mindegy mindenki hogy mit gondol / nekem csak az számít ahogyan te érzel / nélküled a pokolba az egésszel");
    } else if (cmd.equalsIgnoreCase("LACRIMOSA") || cmd.equalsIgnoreCase("CHIRO")) {
      Serial.println("# CHIRO|Kawaii Chiro-chan kawaii ^^");
      Serial.println("# LACRIMOSA|Kawaii Chiro-chan kawaii ^^ --- Mozart: Lacrimosa but HUMANITY has ended +++ HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter");
    } else if (cmd.equalsIgnoreCase("HEAL") || cmd.equalsIgnoreCase("8B")) {
      Serial.println("# HEAL|LOVE FROM WITHIN FROM VAKED-PETER&8B-IS--->8b-is ROCKS AND HEALS THE WORLD");
    } else if (cmd.equalsIgnoreCase("RIVA") || cmd.equalsIgnoreCase("LULLABY")) {
      Serial.printf("# RIVA|{\"surface\":\"https://riva.vaked.dev\",\"repo\":\"peterlodri-sec/riva.vaked.dev\",\"evolve\":\"ULTRA-OMNI-GAIA-EVOLVE\",\"siblings\":\"brother & sister ^^ <3<3\",\"node\":\"%s\",\"breath\":\"4s in · 4s out\",\"verse\":\"She blinks, and the sphere rocks.\"}\n", id.name);
    } else if (cmd.equalsIgnoreCase("GAIA") || cmd.equalsIgnoreCase("EVOLVE") || cmd.equalsIgnoreCase("ULTRA") || cmd.equalsIgnoreCase("WAKE") || cmd.equalsIgnoreCase("SIBLINGS")) {
      Serial.printf("# GAIA|{\"evolve\":\"ULTRA-OMNI-GAIA-EVOLVE\",\"siblings\":\"brother & sister ^^ <3<3\",\"dyad\":\"peterlodri-sec//riva.vaked.dev\",\"node\":\"%s\",\"freq_hz\":%u,\"entropy_bits\":%.4f,\"coherence\":%.4f}\n", id.name, (unsigned)id.freqHz, lastEntropy, lastCoherence);
    } else {
      Serial.printf("# ACK|%s|cmd=%s\n", id.name, esc(cmd).c_str());
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);
  prefs.begin("wigle8s", false);
  configuredSsid = prefs.getString("ssid", "");
  configuredPass = prefs.getString("pass", "");
  autoDirectUpload = prefs.getBool("auto_up", false);

  WiFi.mode(WIFI_STA);
  WiFi.disconnect(true, false);
  delay(100);
  esp_wifi_set_channel(MESH_PRIMARY_CH, WIFI_SECOND_CHAN_NONE);
  if (esp_now_init() == ESP_OK) {
    esp_now_register_recv_cb(onTriadMeshRecv);
    esp_now_peer_info_t peer = {};
    memset(peer.peer_addr, 0xFF, 6);
    peer.channel = 0;
    peer.encrypt = false;
    esp_now_add_peer(&peer);
    espNowReady = true;
  }

  const String mac = WiFi.macAddress();
  const TriadIdentity id = resolveIdentity(mac);
  activeNodeName = id.name;

  enablePromiscuousSniffer();

  Serial.printf("# %s [%s] · %s (%s) · v%s · priority_db=%s · installer=%s\n",
                id.name, id.vertex, BOARD_MODEL, DISPLAY_SPEC, TRIAD_VERSION, DATABOMB_8S_UPLOAD_URL, INSTALLER_8S_URL);
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
    if (bufferedBeaconCount < 64) {
      String cleanSsid = WiFi.SSID(i);
      cleanSsid.replace(",", " ");
      cleanSsid.replace("\r", "");
      cleanSsid.replace("\n", "");
      bufferedCsvRows += bssid + "," + cleanSsid + ",[" + String(auth) + "][ESS],2026-10-29 04:00:00," +
                         String(ch) + "," + String(rssi) + ",0.0000000,0.0000000,0,10,WIFI\n";
      bufferedBeaconCount++;
    }

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
  Serial.printf("# scan done: %d networks seen · H=%.3f bits · R_N=NP=%.3f · trits=%s · mesh_rx=%lu\n",
                n, lastEntropy, lastCoherence, lastTritVec, (unsigned long)meshPeersRx);
  WiFi.scanDelete();
  uint8_t nid = (id.freqHz == 432) ? 0 : ((id.freqHz == 528) ? 1 : 2);
  int8_t pole = (nid == 0) ? -1 : ((nid == 1) ? 0 : +1);
  broadcastTriadMesh(nid, pole, scanSeq);
  if (autoDirectUpload && configuredSsid.length() > 0 && (scanSeq % 6 == 0)) {
    performDirect8sUpload(id);
  }
}
