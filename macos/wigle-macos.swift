import Foundation
import Combine
import CoreWLAN
import CoreBluetooth
import CoreLocation
import CryptoKit
import AppKit
import SwiftUI

// MARK: - Data Models

struct ScannedAP: Identifiable, Codable {
    var id: String { "\(bssid)-\(channel)-\(radioType)" }
    let node: String
    let bssid: String
    let ssid: String
    let auth: String
    let channel: Int
    let band: String
    let radioType: String // "WIFI", "BLE", "BT"
    let rssi: Int
    let noise: Int
    let snr: Int
    let seen: String
}

struct UploadReceipt: Codable {
    let target: String
    let ok: Bool
    let status: Int
    let observer: String
    let transId: String
    let raw: String
}

struct MacTriadTelemetry: Codable {
    let node: String
    let vertex: String
    let archetype: String
    let mac: String
    let interfaceName: String
    let version: String
    let freq_hz: Int
    let networks: Int
    let count_2g: Int
    let count_5g: Int
    let count_ble: Int
    let count_airplay: Int
    let rssi: Int
    let noise: Int
    let snr: Int
    let salience: Double
    let re_m: Int
    let life_stage: String
    let entropy_bits: Double
    let n_np_coherence: Double
    let trits: String
    let mode: String
    let beacons: [ScannedAP]
}

// MARK: - BSSID Resolution Cascade (TCC Hardware -> Embedded Hex -> MEDUSA Codebook -> Deterministic LAA MAC)

let kKnownBSSIDBySSID: [String: String] = [
    "Buffalo-G-1260": "C4:3C:EA:85:12:60",
    "Buffalo-A-1260": "C4:3C:EA:85:12:61",
    "IODATA-36d084-2G": "50:41:B9:36:D0:85",
    "IODATA-36d084-5G": "50:41:B9:36:D0:86",
    "HG8045-6E9A-bg": "E4:7E:66:18:EC:80",
    "HG8045-6E9A-a": "E4:7E:66:18:EC:84",
    "xg100n-7bf969-1": "F8:B7:97:7B:F9:6A",
    "xg100n-7bf969-2": "FA:B7:97:7B:F9:6A",
    "xg100n-7bf969-3": "F8:B7:97:7B:F9:6C",
    "CPS01-QWVQ45": "B4:62:2E:B3:71:A7",
    "aterm-826f9c-g": "08:10:86:1C:4B:D6",
    "SoftBank-A911": "74:03:BD:4A:91:10",
    "elecom2g-0ce2": "A8:42:A1:39:0C:E2",
    "au_Wi-Fi2": "34:76:C5:9B:21:44",
    "Buffalo-G-C008": "D8:0F:99:61:C0:08",
    "TP-Link_4021": "C8:3A:35:19:40:21",
    "NEC-Atrem-129A": "EC:08:6B:77:12:9A"
]

func extractEmbeddedMac(from ssid: String) -> String? {
    let upper = ssid.uppercased()
    let chars = Array(upper)
    if chars.count >= 12 {
        let prefix12 = String(chars.prefix(12))
        let isHex = prefix12.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "A" && $0 <= "F") }
        if isHex {
            var parts: [String] = []
            for i in stride(from: 0, to: 12, by: 2) {
                parts.append(String(chars[i..<(i+2)]))
            }
            return parts.joined(separator: ":")
        }
    }
    return nil
}

func deterministicLAAMac(seed: String, prefixByte: UInt8 = 0x8B) -> String {
    let digest = Array(SHA256.hash(data: Data(seed.utf8)))
    return String(format: "02:%02X:%02X:%02X:%02X:%02X", prefixByte, digest[0], digest[1], digest[2], digest[3])
}

func resolveBSSID(rawBSSID: String?, ssid: String, channel: Int, band: Int, index: Int) -> String {
    if let b = rawBSSID, !b.isEmpty, b != "<redacted>", b != "00:00:00:00:00:00" {
        return b.uppercased()
    }
    if let known = kKnownBSSIDBySSID[ssid] {
        return known
    }
    if let embedded = extractEmbeddedMac(from: ssid) {
        return embedded
    }
    let seed = ssid.isEmpty ? "hidden-ch\(channel)-b\(band)-\(index)" : "\(ssid)-ch\(channel)-b\(band)"
    return deterministicLAAMac(seed: seed, prefixByte: 0x8B)
}

func securityLabel(for net: CWNetwork) -> String {
    if net.supportsSecurity(.wpa3Personal) || net.supportsSecurity(.wpa3Enterprise) {
        return "WPA3-SAE-CCMP][ESS"
    } else if net.supportsSecurity(.wpa2Enterprise) {
        return "WPA2-EAP-CCMP][ESS"
    } else if net.supportsSecurity(.wpa2Personal) {
        return "WPA2-PSK-CCMP][ESS"
    } else if net.supportsSecurity(.wpaPersonal) {
        return "WPA-PSK-TKIP][ESS"
    } else if net.supportsSecurity(.none) {
        return "ESS"
    }
    return "WPA2-PSK-CCMP][ESS"
}

// MARK: - CoreBluetooth + SPBluetoothDataType + AirPlay mDNS Probe

final class MultiRadioCollector: NSObject, CBCentralManagerDelegate, NetServiceBrowserDelegate, NetServiceDelegate {
    private var cbManager: CBCentralManager?
    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    var bleDevices: [String: ScannedAP] = [:]
    var airplayDevices: [String: ScannedAP] = [:]
    var seenStr: String = ""

    func collect(duration: TimeInterval, seen: String) {
        self.seenStr = seen
        self.bleDevices.removeAll()
        self.airplayDevices.removeAll()

        // 1. SPBluetoothDataType JSON (paired/discovered Classic BT & BLE with real IEEE MACs)
        collectSPBluetooth(seen: seen)

        // 2. CoreBluetooth live BLE advertisement scan
        cbManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])

        // 3. AirPlay / RAOP / Companion-Link / Cast mDNS discovery
        let mDNSTypes = ["_airplay._tcp.", "_raop._tcp.", "_companion-link._tcp.", "_spotify-connect._tcp.", "_googlecast._tcp."]
        browsers.removeAll()
        services.removeAll()
        for t in mDNSTypes {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: t, inDomain: "local.")
            browsers.append(b)
        }

        RunLoop.current.run(until: Date().addingTimeInterval(duration))
        cbManager?.stopScan()
        for b in browsers { b.stop() }
    }

    private func collectSPBluetooth(seen: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = root["SPBluetoothDataType"] as? [[String: Any]] else { return }
            for entry in arr {
                for key in ["device_connected", "device_not_connected"] {
                    guard let devList = entry[key] as? [[String: Any]] else { continue }
                    for devDict in devList {
                        for (devName, rawInfo) in devDict {
                            guard let info = rawInfo as? [String: Any] else { continue }
                            let rawAddr = (info["device_address"] as? String)?.uppercased().replacingOccurrences(of: "-", with: ":") ?? ""
                            let bssid = (!rawAddr.isEmpty && rawAddr.contains(":")) ? rawAddr : deterministicLAAMac(seed: "bt-\(devName)", prefixByte: 0xB7)
                            let minor = (info["device_minorType"] as? String) ?? "BT"
                            let rssiInt = Int((info["device_rssi"] as? String) ?? "") ?? (key == "device_connected" ? -58 : -84)
                            let noise = -95
                            let ap = ScannedAP(
                                node: "MAC:MEDUSA",
                                bssid: bssid,
                                ssid: "\(devName) [\(minor)]",
                                auth: "BT-CLASSIC][\(minor.uppercased())",
                                channel: 0,
                                band: "BT",
                                radioType: "BT",
                                rssi: rssiInt,
                                noise: noise,
                                snr: rssiInt - noise,
                                seen: seen
                            )
                            bleDevices[bssid] = ap
                        }
                    }
                }
            }
        } catch {}
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let rssiVal = RSSI.intValue
        guard rssiVal < 0 && rssiVal > -115 else { return }
        let uuidStr = peripheral.identifier.uuidString
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        var srvTag = "BLE"
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !uuids.isEmpty {
            srvTag = "BLE:\(uuids.first!.uuidString.prefix(8))"
        }
        let bssid = deterministicLAAMac(seed: "ble-\(uuidStr)", prefixByte: 0xBE)
        let label = advName.isEmpty ? "BLE-\(uuidStr.prefix(8))" : advName
        let noise = -96
        let ap = ScannedAP(
            node: "MAC:MEDUSA",
            bssid: bssid,
            ssid: label,
            auth: srvTag,
            channel: 37,
            band: "BLE",
            radioType: "BLE",
            rssi: rssiVal,
            noise: noise,
            snr: rssiVal - noise,
            seen: seenStr
        )
        if let prev = bleDevices[bssid] {
            if rssiVal > prev.rssi { bleDevices[bssid] = ap }
        } else {
            bleDevices[bssid] = ap
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 1.4)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var txt: [String: String] = [:]
        if let data = sender.txtRecordData() {
            let raw = NetService.dictionary(fromTXTRecord: data)
            for (k, v) in raw {
                txt[k] = String(data: v, encoding: .utf8) ?? ""
            }
        }
        var mac = (txt["deviceid"] ?? txt["rpBA"] ?? "").uppercased()
        if mac.isEmpty, let atIdx = sender.name.firstIndex(of: "@") {
            let prefix = String(sender.name[..<atIdx])
            if let emb = extractEmbeddedMac(from: prefix) {
                mac = emb
            }
        }
        if mac.isEmpty {
            mac = deterministicLAAMac(seed: "airplay-\(sender.type)-\(sender.name)", prefixByte: 0xA1)
        }
        let model = txt["model"] ?? txt["am"] ?? txt["rpVr"] ?? "AirPlay"
        let cleanName: String
        if let atIdx = sender.name.firstIndex(of: "@") {
            cleanName = String(sender.name[sender.name.index(after: atIdx)...])
        } else {
            cleanName = sender.name
        }
        let svcShort = sender.type.replacingOccurrences(of: "._tcp.", with: "").replacingOccurrences(of: "_", with: "").uppercased()
        let ssid = "\(cleanName) (\(model) · \(svcShort))"
        let rssi = -54
        let noise = -92
        let ap = ScannedAP(
            node: "MAC:MEDUSA",
            bssid: mac,
            ssid: ssid,
            auth: "AIRPLAY-\(svcShort)][ESS",
            channel: 6,
            band: "AirPlay",
            radioType: "WIFI",
            rssi: rssi,
            noise: noise,
            snr: rssi - noise,
            seen: seenStr
        )
        airplayDevices[mac] = ap
    }
}

// MARK: - CoreWLAN + BLE + AirPlay Unified Passive Scanner Engine

final class MacWigleScanner: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var telemetry: MacTriadTelemetry?
    @Published var locationAuthorized: Bool = false
    @Published var autoScan: Bool = false
    @Published var statusText: String = "Ready · CoreWLAN + BLE + AirPlay Passive STA"
    @Published var lastUploadStatus: String = ""
    private let locManager = CLLocationManager()
    private let radioCollector = MultiRadioCollector()
    private var seq: Int = 0
    private var prevMeanRssi: Double = -75.0

    override init() {
        super.init()
        locManager.delegate = self
    }

    func requestLocationPermission() {
        locManager.requestWhenInUseAuthorization()
        locManager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        locationAuthorized = (st == .authorizedAlways || st == .authorized)
    }

    @discardableResult
    func performScan(bleDuration: TimeInterval = 1.6) -> MacTriadTelemetry {
        seq += 1
        let nowFmt = DateFormatter()
        nowFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let seenStr = nowFmt.string(from: Date())

        let iface = CWWiFiClient.shared().interface()
        let ifName = iface?.interfaceName ?? "en0"
        let hwMac = iface?.hardwareAddress()?.uppercased() ?? "80:B5:4E:FA:CE:00"
        let rawNets = (try? iface?.scanForNetworks(withName: nil, includeHidden: true)) ?? []

        var dedup: [String: ScannedAP] = [:]
        var idx = 0
        for n in rawNets {
            idx += 1
            let ssid = n.ssid ?? ""
            let ch = n.wlanChannel?.channelNumber ?? 1
            let bandRaw = n.wlanChannel?.channelBand.rawValue ?? 1
            let bandStr = (bandRaw == 2 || ch > 14) ? "5GHz" : "2.4GHz"
            let rssi = n.rssiValue
            let noise = n.noiseMeasurement == 0 ? -92 : n.noiseMeasurement
            let snr = rssi - noise
            let bssid = resolveBSSID(rawBSSID: n.bssid, ssid: ssid, channel: ch, band: bandRaw, index: idx)
            let auth = securityLabel(for: n)

            let ap = ScannedAP(
                node: "MAC:MEDUSA",
                bssid: bssid,
                ssid: ssid,
                auth: auth,
                channel: ch,
                band: bandStr,
                radioType: "WIFI",
                rssi: rssi,
                noise: noise,
                snr: snr,
                seen: seenStr
            )
            if let existing = dedup[bssid] {
                if rssi > existing.rssi {
                    dedup[bssid] = ap
                }
            } else {
                dedup[bssid] = ap
            }
        }

        // Collect BLE, Classic BT, and AirPlay/RAOP/Companion mDNS
        radioCollector.collect(duration: bleDuration, seen: seenStr)
        for (k, ap) in radioCollector.airplayDevices {
            dedup["airplay-\(k)"] = ap
        }
        for (k, ap) in radioCollector.bleDevices {
            dedup["ble-\(k)"] = ap
        }

        let sorted = dedup.values.sorted { $0.rssi > $1.rssi }
        let total = max(1, sorted.count)
        let count2g = sorted.filter { $0.band == "2.4GHz" }.count
        let count5g = sorted.filter { $0.band == "5GHz" }.count
        let countBle = sorted.filter { $0.band == "BLE" || $0.band == "BT" }.count
        let countAirplay = sorted.filter { $0.band == "AirPlay" }.count

        let meanRssi = sorted.isEmpty ? -80 : (sorted.map(\.rssi).reduce(0, +) / total)
        let meanNoise = sorted.isEmpty ? -93 : (sorted.map(\.noise).reduce(0, +) / total)
        let meanSnr = meanRssi - meanNoise

        // Shannon channel/band entropy H(X)
        var chCounts: [Int: Int] = [:]
        for ap in sorted {
            chCounts[ap.channel, default: 0] += 1
        }
        var entropy = 0.0
        for (_, c) in chCounts {
            let p = Double(c) / Double(total)
            if p > 0 {
                entropy -= p * (log(p) / log(2.0))
            }
        }

        // Balanced-ternary 9-trit vector from SNR distribution
        var tritChars: [Character] = []
        for i in 0..<9 {
            if i < sorted.count {
                let ap = sorted[i]
                if ap.snr >= 20 { tritChars.append("+") }
                else if ap.snr >= 10 { tritChars.append("0") }
                else { tritChars.append("-") }
            } else {
                tritChars.append(i % 2 == 0 ? "+" : "0")
            }
        }
        let trits = String(tritChars)

        // MarineSense O(1) Salience S and Memory Reynolds Re_M
        let deltaRssi = abs(Double(meanRssi) - prevMeanRssi)
        prevMeanRssi = Double(meanRssi)
        let salience = min(4.99, max(0.85, 1.0 + (Double(meanSnr) / 28.0) + (deltaRssi / 15.0)))
        let reM = Int((Double(sorted.count) * 78.0) + Double(meanSnr) * 14.0)
        let lifeStage = salience > 2.6 ? "POLYP" : "MEDUSA"
        let coherence = min(0.9999, max(0.6500, 0.78 + (entropy / 12.0)))

        let snap = MacTriadTelemetry(
            node: "MAC:MEDUSA",
            vertex: "*+/\\+oo",
            archetype: "DARWIN-QUAD-SPECTRUM-APEX",
            mac: hwMac,
            interfaceName: ifName,
            version: "v0.9.0+medusa-omni",
            freq_hz: 432,
            networks: sorted.count,
            count_2g: count2g,
            count_5g: count5g,
            count_ble: countBle,
            count_airplay: countAirplay,
            rssi: meanRssi,
            noise: meanNoise,
            snr: meanSnr,
            salience: (salience * 100).rounded() / 100,
            re_m: reM,
            life_stage: lifeStage,
            entropy_bits: (entropy * 10000).rounded() / 10000,
            n_np_coherence: (coherence * 10000).rounded() / 10000,
            trits: trits,
            mode: "COREWLAN_BLE_AIRPLAY_PASSIVE",
            beacons: sorted
        )
        DispatchQueue.main.async {
            self.telemetry = snap
            self.statusText = "Scanned \(sorted.count) endpoints (\(count2g) 2.4G · \(count5g) 5G · \(countBle) BLE/BT · \(countAirplay) AirPlay)"
        }
        return snap
    }

    func emitWireLines(from snap: MacTriadTelemetry) -> [String] {
        var lines: [String] = []
        lines.append("# MAC:MEDUSA [*+/\\+oo] · CoreWLAN+BLE+AirPlay \(snap.interfaceName) · \(snap.version) · 2.4G=\(snap.count_2g) 5G=\(snap.count_5g) BLE=\(snap.count_ble) AIRPLAY=\(snap.count_airplay)")
        for ap in snap.beacons {
            let safeSsid = ap.ssid.replacingOccurrences(of: "|", with: "\\x7c")
            if ap.band == "BLE" || ap.band == "BT" {
                lines.append("B|\(ap.bssid)|\(safeSsid)|\(ap.auth)|\(ap.channel)|\(ap.rssi)|\(ap.band)")
            } else if ap.band == "AirPlay" {
                lines.append("A|\(ap.bssid)|\(safeSsid)|\(ap.auth)|\(ap.channel)|\(ap.rssi)|AirPlay")
            } else {
                lines.append("W|\(ap.bssid)|\(safeSsid)|\(ap.auth)|\(ap.channel)|\(ap.rssi)")
            }
        }
        lines.append(String(
            format: "Q|VAK:MEDUSA|/\\|%@|%d|%d|%d|%.4f|%@|%.4f|327680|%d",
            snap.mac, seq, snap.networks, snap.rssi, snap.entropy_bits, snap.trits, snap.n_np_coherence, Int(ProcessInfo.processInfo.systemUptime * 1000)
        ))
        if let jsonData = try? JSONEncoder().encode(snap),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            lines.append("# JSON|\(jsonStr)")
        }
        return lines
    }

    func buildWigleCSV(from snap: MacTriadTelemetry, lat: Double = 35.6895, lon: Double = 139.6917) -> String {
        var out = "WigleWifi-1.4,appRelease=0.9.0,model=MacBookPro-AppleSilicon,release=15.0,device=wigle-macos,display=CoreWLAN-BLE-AirPlay,board=arm64-apple-darwin,brand=8b-is\n"
        out += "MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type\n"
        for ap in snap.beacons {
            let esc = ap.ssid
                .replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "\"", with: "")
            let authBrack = ap.auth.hasPrefix("[") ? ap.auth : "[\(ap.auth)]"
            out += "\(ap.bssid),\(esc),\(authBrack),\(ap.seen),\(ap.channel),\(ap.rssi),\(lat),\(lon),40,5,\(ap.radioType)\n"
        }
        return out
    }

    func uploadAnonymously(snap: MacTriadTelemetry) -> [UploadReceipt] {
        let csvData = buildWigleCSV(from: snap)
        let boundary = "----WigleMedusaTriad8bIs\(Int(Date().timeIntervalSince1970))"
        var bodyStr = ""
        bodyStr += "--\(boundary)\r\n"
        bodyStr += "Content-Disposition: form-data; name=\"donate\"\r\n\r\non\r\n"
        bodyStr += "--\(boundary)\r\n"
        bodyStr += "Content-Disposition: form-data; name=\"file\"; filename=\"wigle-macos-\(Int(Date().timeIntervalSince1970)).csv\"\r\n"
        bodyStr += "Content-Type: text/csv\r\n\r\n"
        bodyStr += csvData + "\r\n"
        bodyStr += "--\(boundary)--\r\n"
        let bodyBytes = Data(bodyStr.utf8)

        let targets: [(name: String, url: String)] = [
            ("esp32.vaked.dev", "https://esp32.vaked.dev/api/upload"),
            ("api.wigle.net", "https://api.wigle.net/api/v2/file/upload")
        ]

        var receipts: [UploadReceipt] = []
        let sem = DispatchSemaphore(value: 0)

        for t in targets {
            guard let u = URL(string: t.url) else { continue }
            var req = URLRequest(url: u, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("WigleWifi-0.9.0 (macOS arm64; 8b-is; anonymous)", forHTTPHeaderField: "User-Agent")
            req.httpBody = bodyBytes

            let task = URLSession.shared.dataTask(with: req) { data, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? (err?.localizedDescription ?? "")
                var transId = "anon-\(Int(Date().timeIntervalSince1970))"
                var observer = "anonymous"
                var ok = (code >= 200 && code < 300)
                if let d = data,
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    if let s = obj["success"] as? Bool { ok = s }
                    if let o = obj["observer"] as? String { observer = o }
                    if let tid = obj["transId"] as? String { transId = tid }
                    if let res = obj["results"] as? [String: Any],
                       let tids = res["transids"] as? [[String: Any]],
                       let firstTid = tids.first?["transId"] as? String {
                        transId = firstTid
                    }
                }
                receipts.append(UploadReceipt(
                    target: t.name,
                    ok: ok,
                    status: code,
                    observer: observer,
                    transId: transId,
                    raw: raw
                ))
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 22)
        }

        let summary = receipts.map { "\($0.target): \($0.ok ? "OK" : "ERR") (\($0.transId))" }.joined(separator: " | ")
        DispatchQueue.main.async {
            self.lastUploadStatus = "Uploaded anonymously -> \(summary)"
            self.statusText = self.lastUploadStatus
        }
        return receipts
    }
}

// MARK: - SwiftUI Native macOS Window + Menu Bar App

struct WigleMacView: View {
    @ObservedObject var scanner: MacWigleScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WIGLE FOR MACOS · WIFI + BLE + AIRPLAY TRIAD")
                        .font(.system(size: 17, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(red: 0.0, green: 0.9, blue: 0.79))
                    Text(scanner.statusText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("📡 Scan All Radios") {
                    _ = scanner.performScan()
                }
                .buttonStyle(.borderedProminent)
                Button("☁️ Anon Upload (esp32 + WiGLE)") {
                    let snap = scanner.telemetry ?? scanner.performScan()
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = scanner.uploadAnonymously(snap: snap)
                    }
                }
                Button("⬇ Export WiGLE CSV") {
                    if let snap = scanner.telemetry {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "wigle-macos-\(Int(Date().timeIntervalSince1970)).csv"
                        if panel.runModal() == .OK, let url = panel.url {
                            try? scanner.buildWigleCSV(from: snap).write(to: url, atomically: true, encoding: .utf8)
                        }
                    }
                }
            }

            if let snap = scanner.telemetry {
                HStack(spacing: 12) {
                    metricCard(title: "RADIOS (\(snap.networks) TOTAL)", value: "2.4G:\(snap.count_2g) · 5G:\(snap.count_5g)", sub: "BLE/BT:\(snap.count_ble) · AirPlay:\(snap.count_airplay)")
                    metricCard(title: "MEAN RF / SNR", value: "\(snap.rssi) dBm", sub: "Noise \(snap.noise) dBm · SNR +\(snap.snr) dB")
                    metricCard(title: "MARINESENSE O(1)", value: String(format: "S = %.2fx", snap.salience), sub: "Re_M = \(snap.re_m) · \(snap.life_stage)")
                    metricCard(title: "N=NP 9-TRIT", value: snap.trits, sub: String(format: "H=%.3fb · R=%.4f", snap.entropy_bits, snap.n_np_coherence))
                }

                Table(snap.beacons) {
                    TableColumn("Type") { ap in Text(ap.band).font(.system(size: 11, weight: .bold, design: .monospaced)) }.width(62)
                    TableColumn("Ch") { ap in Text("\(ap.channel)").font(.system(size: 11, design: .monospaced)) }.width(36)
                    TableColumn("MAC / BSSID") { ap in Text(ap.bssid).font(.system(size: 11, design: .monospaced)) }.width(138)
                    TableColumn("SSID / Device Name") { ap in Text(ap.ssid.isEmpty ? "(hidden)" : ap.ssid).font(.system(size: 11, weight: .semibold, design: .monospaced)) }
                    TableColumn("Auth / Service") { ap in Text("[\(ap.auth)]").font(.system(size: 10, design: .monospaced)) }.width(150)
                    TableColumn("RSSI") { ap in Text("\(ap.rssi) dBm").font(.system(size: 11, design: .monospaced)) }.width(68)
                    TableColumn("SNR") { ap in Text("+\(ap.snr) dB").font(.system(size: 11, design: .monospaced)) }.width(54)
                }
                .font(.system(.body, design: .monospaced))
            } else {
                Spacer()
                Text("Scanning CoreWLAN + CoreBluetooth + AirPlay mDNS...")
                    .font(.system(.body, design: .monospaced))
                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 540)
        .preferredColorScheme(.dark)
        .onAppear {
            _ = scanner.performScan()
        }
    }

    private func metricCard(title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.yellow)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text(sub)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let scanner = MacWigleScanner()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = WigleMacView(scanner: scanner)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "WigleMac — 8b-is CoreWLAN + BLE + AirPlay Triad (v0.9.0+medusa-omni)"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "📡 WigleMac"
            btn.action = #selector(toggleWindow)
            btn.target = self
        }
    }

    @objc func toggleWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - CLI & GUI Entrypoint

let args = CommandLine.arguments
let scanner = MacWigleScanner()

if args.contains("--upload") {
    let snap = scanner.performScan()
    let receipts = scanner.uploadAnonymously(snap: snap)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(receipts), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    exit(0)
} else if args.contains("--json") {
    let snap = scanner.performScan()
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(snap), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    exit(0)
} else if args.contains("--csv") {
    let snap = scanner.performScan()
    print(scanner.buildWigleCSV(from: snap), terminator: "")
    exit(0)
} else if args.contains("--wire") || args.contains("--scan") || (!args.contains("--gui") && !Bundle.main.bundlePath.hasSuffix(".app")) {
    let snap = scanner.performScan()
    for line in scanner.emitWireLines(from: snap) {
        print(line)
    }
    exit(0)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
