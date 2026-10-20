import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const html = readFileSync(new URL('../www/index.html', import.meta.url), 'utf8');
test('session starts empty and radio text renders as text', () => {
  const init = html.slice(html.indexOf('  const beacons ='), html.indexOf('  const serialLog'));
  const render = html.slice(html.indexOf('  function renderSpectrumAndTable'), html.indexOf('  renderSpectrumAndTable();'));
  const context = {apTbody: {}, apTotalBadge: {}, chBars: {appendChild() {}}, document: {createElement() {return {};}}};
  vm.createContext(context);
  vm.runInContext(init + '\n' + render + '\nrenderSpectrumAndTable();', context);
  assert.match(context.apTotalBadge.textContent, /^0 ENDPOINTS/);
  vm.runInContext(`beacons.set('test', {node:'<img>', band:'<svg>', bssid:'<script>', ssid:'<img src=x onerror=alert(1)>', auth:'<iframe>', ch:1, rssi:-50}); renderSpectrumAndTable();`, context);
  assert.doesNotMatch(context.apTbody.innerHTML, /<(?:img|svg|script|iframe)/);
  assert.match(context.apTbody.innerHTML, /&lt;img/);
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
test('CSV quotes radio text and leaves unknown coordinates empty', () => {
  const exporter = html.slice(html.indexOf('  function buildWigleCSVString'), html.indexOf('  // Export WiGLE'));
  const beacons = new Map([['test', {bssid:'02:00:00:00:00:01', ssid:'a,"b"\nc', auth:'OPEN', seen:'2026-01-01', ch:1, rssi:-50}]]);
  const context = {beacons};
  vm.createContext(context);
  const csv = vm.runInContext(exporter + '\nbuildWigleCSVString()', context);
  assert.match(csv, /"a,""b""\nc"/);
  assert.match(csv, /"-50","","","","","WIFI"/);
});
