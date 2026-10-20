import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const html = readFileSync(new URL('../www/index.html', import.meta.url), 'utf8');
function modelContext() {
  const nodes = new Map();
  const context = {document: {
    getElementById(id) {
      if (!nodes.has(id)) nodes.set(id, {style: {}, addEventListener() {}, querySelectorAll() {return [];}});
      return nodes.get(id);
    },
    querySelectorAll() {return [];}
  }};
  vm.createContext(context);
  const start = html.indexOf('  const BASE_LAT');
  const end = html.indexOf('  // Interactive Dark Vector Radar Canvas');
  assert.ok(start >= 0 && end > start);
  vm.runInContext(html.slice(start, end), context);
  return {context, nodes};
}
test('session starts empty and radio text renders as text across all views', () => {
  const {context, nodes} = modelContext();
  vm.runInContext('renderAll()', context);
  assert.match(nodes.get('ap-total-badge').textContent, /^0 ENDPOINTS/);
  vm.runInContext(`const b = enrichBeacon({node:'<img>', band:'<svg>', type:'<iframe>', bssid:'<script>', ssid:'<img src=x onerror=alert(1)>', auth:'<iframe>', ch:1, rssi:-50}); beacons.set(b.bssid,b); renderAll();`, context);
  for (const id of ['ap-tbody', 'map-feed-list', 'waterfall-list']) {
    assert.doesNotMatch(nodes.get(id).innerHTML, /<(?:img|svg|script|iframe)/i);
    assert.match(nodes.get(id).innerHTML, /&lt;img/);
  }
});
test('unavailable bridge does not invent telemetry or success', async () => {
  const command = html.slice(html.indexOf('  async function sendSerialCommand'), html.indexOf('  document.querySelectorAll("[data-cmd]")'));
  const logs = [];
  const context = {activePorts: [], location: {hostname: 'localhost'}, fetch: async () => ({ok:false}), logLine: text => logs.push(text)};
  vm.createContext(context);
  vm.runInContext(command, context);
  await vm.runInContext('sendSerialCommand("SCAN")', context);
  assert.equal(logs.length, 1);
  assert.match(logs[0], /not confirmed/);
  assert.doesNotMatch(html, /(?:[0-9a-f]{2}:){5}[0-9a-f]{2}/i);
});
test('CSV preserves quoted radio text, omits illustrative coordinates and normalizes AirPlay', () => {
  const {context} = modelContext();
  context.sample = {bssid:'02:00:00:00:00:01', ssid:'a,"b"\nc', auth:'OPEN', seen:'2026-01-01', ch:1, rssi:-50, type:'AIRPLAY'};
  const csv = vm.runInContext('const row = enrichBeacon(sample); beacons.set(row.bssid,row); buildWigleCSVString()', context);
  assert.match(csv, /"a,""b""\nc"/);
  assert.match(csv, /"-50","","","","","WIFI"/);
  assert.match(csv, /"\[AIRPLAY-RAOP\]\[ESS\]"/);
});
