#!/usr/bin/env node
// import-wigle.mjs — turn a WiGLE WiFi export (CSV or CSV.gz) into the
// host's known-networks set. Local only: the output file is gitignored,
// and location columns are dropped here, never copied.
//
//   node scripts/import-wigle.mjs ~/Downloads/WigleWifi_20261022234507.csv.gz
import { readFileSync, writeFileSync } from 'node:fs'
import { gunzipSync } from 'node:zlib'
import { basename } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..')
const input = process.argv[2]
if (!input) {
  console.error('usage: node scripts/import-wigle.mjs <export.csv[.gz]>')
  process.exit(1)
}

let raw = readFileSync(input)
if (input.endsWith('.gz')) raw = gunzipSync(raw)
const text = raw.toString('utf8')
const lines = text.split('\n')

// First data line starts with "WigleWifi-"; the second is the header.
let headerIdx = -1
for (let i = 0; i < Math.min(lines.length, 20); i++) {
  if (lines[i].startsWith('MAC,')) { headerIdx = i; break }
}
if (headerIdx < 0) {
  console.error('no WiGLE header row found (expected "MAC,SSID,...")')
  process.exit(1)
}
const header = lines[headerIdx].split(',')
const macCol = header.indexOf('MAC')
const typeCol = header.indexOf('Type')
if (macCol < 0 || typeCol < 0) {
  console.error('missing MAC or Type column')
  process.exit(1)
}

const known = new Set()
for (const line of lines.slice(headerIdx + 1)) {
  if (!line.trim()) continue
  const cols = line.split(',')
  if (cols[typeCol] !== 'WIFI') continue
  const mac = cols[macCol]?.trim().toUpperCase()
  if (/^[0-9A-F:]{17}$/.test(mac ?? '')) known.add(mac)
}

const out = join(root, 'known_networks.local.txt')
writeFileSync(out, `# ${basename(input)} — ${known.size} known WIFI bssids (local only, not committed)\n`
  + [...known].sort().join('\n') + '\n')
console.log(`wrote ${known.size} WIFI bssids to ${out}`)
