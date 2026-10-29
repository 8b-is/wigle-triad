#!/usr/bin/env node
/**
 * dual-upload-wigle.mjs — Multi-target upload of a WiGLE export (.csv.gz or .csv) to:
 *   Target 0 (Sovereign DataBomb 8s): https://8s.is/api/v2/file/upload
 *   Target 1: https://esp32.vaked.dev/api/upload?mirror=wigle
 *   Target 2: https://api.wigle.net/api/v2/file/upload
 *
 * Also updates local `known_networks.local.txt` (gitignored) and writes a
 * privacy-safe, zero-PII receipt (no BSSIDs, no SSIDs, no GPS coordinates).
 *
 * Credentials are NEVER stored in code or logs; optional env var:
 *   WIGLE_API_TOKEN (Basic base64 API Name:Token from wigle.net/account)
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { gunzipSync } from 'node:zlib'
import { createHash } from 'node:crypto'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..')
const input = process.argv[2]

if (!input) {
  console.error('usage: node scripts/dual-upload-wigle.mjs <WigleWifi_*.csv[.gz]>')
  process.exit(1)
}

const rawFileBytes = readFileSync(input)
const sha256 = createHash('sha256').update(rawFileBytes).digest('hex')
const plainBytes = input.endsWith('.gz') ? gunzipSync(rawFileBytes) : rawFileBytes
const text = plainBytes.toString('utf8')
const lines = text.split(/\r?\n/)

const preHeader = lines[0] || ''
let headerIdx = -1
for (let i = 0; i < Math.min(lines.length, 20); i++) {
  if (lines[i].startsWith('MAC,')) {
    headerIdx = i
    break
  }
}
if (headerIdx < 0) {
  console.error('error: no WiGLE CSV header row found (expected "MAC,SSID,...")')
  process.exit(1)
}

const header = lines[headerIdx].split(',')
const macCol = header.indexOf('MAC')
const typeCol = header.indexOf('Type')

const knownWifiMacs = new Set()
const uniqueMacsByType = { WIFI: new Set(), BT: new Set(), BLE: new Set(), CELL: new Set(), OTHER: new Set() }
const obsByType = { WIFI: 0, BT: 0, BLE: 0, CELL: 0, OTHER: 0 }
let totalObservations = 0

for (let i = headerIdx + 1; i < lines.length; i++) {
  const line = lines[i]
  if (!line || !line.trim()) continue
  totalObservations++
  const cols = line.split(',')
  const t = (cols[typeCol] || 'OTHER').trim().toUpperCase()
  const mac = (cols[macCol] || '').trim().toUpperCase()
  const bucket = t in obsByType ? t : 'OTHER'
  obsByType[bucket]++
  if (mac) uniqueMacsByType[bucket].add(mac)
  if (bucket === 'WIFI' && /^[0-9A-F:]{17}$/.test(mac)) {
    knownWifiMacs.add(mac)
  }
}

// 1. Update local gitignored known_networks.local.txt
const knownOut = join(root, 'known_networks.local.txt')
writeFileSync(
  knownOut,
  `# ${basename(input)} — ${knownWifiMacs.size} known WIFI bssids (local only, not committed)\n` +
    [...knownWifiMacs].sort().join('\n') +
    '\n',
)

function makeFormData() {
  const fd = new FormData()
  fd.append('donate', 'on')
  const mime = input.endsWith('.gz') ? 'application/gzip' : 'text/csv'
  fd.append('file', new Blob([rawFileBytes], { type: mime }), basename(input))
  return fd
}

async function uploadToWigleNet() {
  const headers = {
    Accept: 'application/json',
    'User-Agent': 'WigleWifi-2.111 (Android 16; SM-S928U1; 8b-is/wigle-triad)',
  }
  let mode = 'anonymous (donate=on)'
  if (process.env.WIGLE_API_TOKEN) {
    const tok = process.env.WIGLE_API_TOKEN.trim()
    headers.Authorization = tok.startsWith('Basic ') ? tok : `Basic ${tok}`
    mode = 'api_token'
  }
  const resp = await fetch('https://api.wigle.net/api/v2/file/upload', {
    method: 'POST',
    headers,
    body: makeFormData(),
  })
  const data = await resp.json().catch(async () => ({ raw: await resp.text() }))
  return {
    target: 'api.wigle.net',
    url: 'https://api.wigle.net/api/v2/file/upload',
    auth_mode: mode,
    http_status: resp.status,
    success: Boolean(data?.success),
    observer: data?.observer || null,
    transId: data?.results?.transids?.[0]?.transId || data?.transId || null,
    filename_echoed: data?.results?.transids?.[0]?.file || data?.results?.filename || null,
    uncompressed_size: data?.results?.transids?.[0]?.size || null,
    time_taken: data?.results?.timeTaken || null,
    warning: data?.warning || data?.message || null,
  }
}

async function uploadToEsp32VakedDev() {
  try {
    const resp = await fetch('https://esp32.vaked.dev/api/upload?mirror=wigle', {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'User-Agent': 'WigleWifi-2.111 (Android 16; SM-S928U1; 8b-is/wigle-triad)',
      },
      body: makeFormData(),
    })
    const data = await resp.json().catch(async () => ({ raw: (await resp.text()).slice(0, 240) }))
    return {
      target: 'esp32.vaked.dev',
      url: 'https://esp32.vaked.dev/api/upload?mirror=wigle',
      http_status: resp.status,
      ok: resp.ok,
      transId: data?.transId || null,
      observer: data?.observer || null,
      response: data,
    }
  } catch (err) {
    return {
      target: 'esp32.vaked.dev',
      url: 'https://esp32.vaked.dev/api/upload?mirror=wigle',
      ok: false,
      error: err.message,
    }
  }
}

async function uploadToDatabomb8s() {
  const url = process.env.DATABOMB_8S_URL || 'https://8s.is/api/v2/file/upload'
  try {
    const resp = await fetch(url, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'User-Agent': 'WigleWifi-2.111 (Android 16; SM-S928U1; 8b-is/wigle-triad -> DataBomb-8s)',
      },
      body: makeFormData(),
    })
    const data = await resp.json().catch(async () => ({ raw: (await resp.text()).slice(0, 240) }))
    return {
      target: 'databomb-8s (8s.is)',
      url,
      http_status: resp.status,
      ok: resp.ok,
      transId: data?.transId || null,
      observer: data?.observer || null,
      receipt: data?.receipt || null,
    }
  } catch (err) {
    return {
      target: 'databomb-8s (8s.is)',
      url,
      ok: false,
      error: err.message,
    }
  }
}

const [databomb8sReceipt, wigleNetReceipt, esp32Receipt] = await Promise.all([
  uploadToDatabomb8s(),
  uploadToWigleNet(),
  uploadToEsp32VakedDev(),
])

const summary = {
  file: basename(input),
  sha256,
  compressed_bytes: rawFileBytes.length,
  uncompressed_bytes: plainBytes.length,
  device_header: preHeader,
  total_observations: totalObservations,
  observations_by_type: obsByType,
  unique_endpoints_by_type: {
    WIFI: uniqueMacsByType.WIFI.size,
    BLE: uniqueMacsByType.BLE.size,
    BT: uniqueMacsByType.BT.size,
    CELL: uniqueMacsByType.CELL.size,
    OTHER: uniqueMacsByType.OTHER.size,
  },
  known_networks_local_updated: knownWifiMacs.size,
  private_vault_repo: 'https://github.com/8b-is/wigle-triad-data',
  dual_upload_receipts: {
    databomb_8s: databomb8sReceipt,
    wigle_net: wigleNetReceipt,
    esp32_vaked_dev: esp32Receipt,
  },
  uploaded_at: new Date().toISOString(),
}

console.log(JSON.stringify(summary, null, 2))
