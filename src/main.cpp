// wigle-triad — one node of the MEDUSA triad.
//
// Passive WiFi beacon scan. No association, no injection, no packets sent
// beyond the ESP32's own probe responses while scanning (scan is passive:
// the radio only listens). Each discovered AP is printed to USB serial as
//
//   W|bssid|ssid|auth|channel|rssi
//
// and the host-side merger (host/merge.py) turns the three nodes' streams
// into a WiGLE-ready CSV with the host's clock and position. The node
// never pretends to know time or place: the host stamps what it can prove.

#include <Arduino.h>
#include <WiFi.h>

#ifndef NODE_NAME
#define NODE_NAME "MEDUSA:UNNAMED"
#endif

static const uint32_t SCAN_INTERVAL_MS = 5000;
static uint32_t lastScan = 0;

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
  return s;
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.printf("# %s · WiGLE rig · passive scan only · no association\n", NODE_NAME);
  Serial.printf("# MAC %s · interval %lu ms\n", WiFi.macAddress().c_str(), (unsigned long)SCAN_INTERVAL_MS);
  WiFi.mode(WIFI_STA);
  WiFi.disconnect(true, false);
}

void loop() {
  const uint32_t now = millis();
  if (now - lastScan < SCAN_INTERVAL_MS) {
    delay(50);
    return;
  }
  lastScan = now;
  const int n = WiFi.scanNetworks(false, true, false, 200);
  if (n < 0) {
    Serial.printf("# scan error %d\n", n);
    return;
  }
  for (int i = 0; i < n; i++) {
    const String bssid = WiFi.BSSIDstr(i);
    const String ssid = esc(WiFi.SSID(i));
    const int ch = WiFi.channel(i);
    const int rssi = WiFi.RSSI(i);
    const char *auth = authName(WiFi.encryptionType(i));
    Serial.printf("W|%s|%s|%s|%d|%d\n", bssid.c_str(), ssid.c_str(), auth, ch, rssi);
  }
  Serial.printf("# scan done: %d networks seen\n", n);
  WiFi.scanDelete();
}
