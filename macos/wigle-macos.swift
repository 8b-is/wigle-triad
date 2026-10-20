import Foundation
import Combine
import CoreWLAN
import CoreBluetooth
import CoreLocation
import CryptoKit
import MapKit
import AppKit
import SwiftUI

// MARK: - Data Models

struct ScannedAP: Identifiable, Codable, Hashable {
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
    let lat: Double
    let lon: Double
    let seen: String
}

struct UploadReceipt: Identifiable, Codable {
    var id: String { "\(target)-\(transId)" }
    let target: String
    let ok: Bool
    let status: Int
    let observer: String
    let transId: String
    let timestamp: String
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

// MARK: - BSSID & Coordinate Helpers

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

func jitteredCoordinate(bssid: String, rssi: Int, baseLat: Double = 35.6852, baseLon: Double = 139.7100) -> (Double, Double) {
    // Deterministic polar offset around Shinjuku Gyoen / operator origin scaled by RSSI distance
    let digest = Array(SHA256.hash(data: Data(bssid.utf8)))
    let angle = (Double(Int(digest[0]) * 256 + Int(digest[1])) / 65535.0) * 2.0 * Double.pi
    let distMeters = max(8.0, min(420.0, pow(10.0, Double(-42 - rssi) / 22.0) * 18.0))
    let dLat = (distMeters * cos(angle)) / 111_111.0
    let dLon = (distMeters * sin(angle)) / (111_111.0 * cos(baseLat * Double.pi / 180.0))
    return (((baseLat + dLat) * 1000000).rounded() / 1000000, ((baseLon + dLon) * 1000000).rounded() / 1000000)
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
    var baseLat: Double = 35.6852
    var baseLon: Double = 139.7100

    func collect(duration: TimeInterval, seen: String, lat: Double, lon: Double) {
        self.seenStr = seen
        self.baseLat = lat
        self.baseLon = lon
        self.bleDevices.removeAll()
        self.airplayDevices.removeAll()

        collectSPBluetooth(seen: seen)
        cbManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])

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
                            let (lat, lon) = jitteredCoordinate(bssid: bssid, rssi: rssiInt, baseLat: baseLat, baseLon: baseLon)
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
                                lat: lat,
                                lon: lon,
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
        let (lat, lon) = jitteredCoordinate(bssid: bssid, rssi: rssiVal, baseLat: baseLat, baseLon: baseLon)
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
            lat: lat,
            lon: lon,
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
        let (lat, lon) = jitteredCoordinate(bssid: mac, rssi: rssi, baseLat: baseLat, baseLon: baseLon)
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
            lat: lat,
            lon: lon,
            seen: seenStr
        )
        airplayDevices[mac] = ap
    }
}

// MARK: - CoreWLAN + BLE + AirPlay Unified Passive Scanner Engine

final class MacWigleScanner: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var telemetry: MacTriadTelemetry?
    @Published var selectedTab: String = "map"
    @Published var bandFilter: String = "ALL"
    @Published var searchQuery: String = ""
    @Published var selectedAP: ScannedAP?
    @Published var receipts: [UploadReceipt] = []
    @Published var isUploading: Bool = false
    @Published var locationAuthorized: Bool = false
    @Published var statusText: String = "Ready · CoreWLAN + BLE + AirPlay Passive STA"
    @Published var baseLat: Double = 35.6852
    @Published var baseLon: Double = 139.7100

    private let locManager = CLLocationManager()
    private let radioCollector = MultiRadioCollector()
    private var seq: Int = 0
    private var prevMeanRssi: Double = -75.0

    override init() {
        super.init()
        locManager.delegate = self
    }

    var filteredBeacons: [ScannedAP] {
        guard let list = telemetry?.beacons else { return [] }
        return list.filter { ap in
            let matchesBand: Bool
            switch bandFilter {
            case "2.4G": matchesBand = (ap.band == "2.4GHz")
            case "5G": matchesBand = (ap.band == "5GHz")
            case "BLE/BT": matchesBand = (ap.band == "BLE" || ap.band == "BT")
            case "AIRPLAY": matchesBand = (ap.band == "AirPlay")
            default: matchesBand = true
            }
            if !matchesBand { return false }
            if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            let q = searchQuery.lowercased()
            return ap.ssid.lowercased().contains(q)
                || ap.bssid.lowercased().contains(q)
                || ap.auth.lowercased().contains(q)
                || ap.band.lowercased().contains(q)
        }
    }

    func requestLocationPermission() {
        locManager.requestWhenInUseAuthorization()
        locManager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        locationAuthorized = (st == .authorizedAlways || st == .authorized)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            baseLat = loc.coordinate.latitude
            baseLon = loc.coordinate.longitude
        }
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
            let (lat, lon) = jitteredCoordinate(bssid: bssid, rssi: rssi, baseLat: baseLat, baseLon: baseLon)

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
                lat: lat,
                lon: lon,
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

        radioCollector.collect(duration: bleDuration, seen: seenStr, lat: baseLat, lon: baseLon)
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
            version: "v1.0.0+medusa-omni",
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
            if self.selectedAP == nil { self.selectedAP = sorted.first }
            self.statusText = "Scan #\(self.seq): \(sorted.count) endpoints (\(count2g) 2.4G · \(count5g) 5G · \(countBle) BLE/BT · \(countAirplay) AirPlay)"
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

    func buildWigleCSV(from snap: MacTriadTelemetry) -> String {
        var out = "WigleWifi-1.4,appRelease=1.0.0,model=MacBookPro-AppleSilicon,release=15.0,device=wigle-macos,display=CoreWLAN-BLE-AirPlay,board=arm64-apple-darwin,brand=8b-is\n"
        out += "MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type\n"
        for ap in snap.beacons {
            let authBrack = ap.auth.hasPrefix("[") ? ap.auth : "[\(ap.auth)]"
            let fields = [ap.bssid, ap.ssid, authBrack, ap.seen,
                          String(ap.channel), String(ap.rssi), "", "", "", "", ap.radioType]
            out += fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: ",") + "\n"
        }
        return out
    }

    func uploadAnonymously(snap: MacTriadTelemetry) -> [UploadReceipt] {
        DispatchQueue.main.async {
            self.isUploading = false
            self.statusText = "External observation sharing is disabled"
        }
        return []
    }
}

// MARK: - MapKit Dark Radar View (NSViewRepresentable)

final class APAnnotation: NSObject, MKAnnotation {
    let ap: ScannedAP
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: ap.lat, longitude: ap.lon)
    }
    var title: String? {
        ap.ssid.isEmpty ? "(hidden) · \(ap.bssid)" : ap.ssid
    }
    var subtitle: String? {
        "\(ap.band) · Ch \(ap.channel) · \(ap.rssi) dBm (SNR +\(ap.snr) dB) · [\(ap.auth)]"
    }
    init(ap: ScannedAP) {
        self.ap = ap
    }
}

struct WigleRadarMapView: NSViewRepresentable {
    let beacons: [ScannedAP]
    let centerLat: Double
    let centerLon: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .hybridFlyover
        map.showsCompass = true
        map.showsScale = true
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            latitudinalMeters: 620,
            longitudinalMeters: 620
        )
        map.setRegion(region, animated: false)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        map.removeAnnotations(map.annotations)
        let anns = beacons.map { APAnnotation(ap: $0) }
        map.addAnnotations(anns)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ann = annotation as? APAnnotation else { return nil }
            let id = "wigle-pin"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: ann, reuseIdentifier: id)
            v.annotation = ann
            v.canShowCallout = true
            switch ann.ap.band {
            case "5GHz":
                v.markerTintColor = NSColor(calibratedRed: 0.0, green: 0.90, blue: 0.79, alpha: 1.0)
                v.glyphText = "5G"
            case "AirPlay":
                v.markerTintColor = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
                v.glyphText = "AP"
            case "BLE", "BT":
                v.markerTintColor = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.76, alpha: 1.0)
                v.glyphText = "BT"
            default:
                v.markerTintColor = NSColor(calibratedRed: 0.0, green: 1.0, blue: 0.40, alpha: 1.0)
                v.glyphText = "\(ann.ap.channel)"
            }
            return v
        }
    }
}

// MARK: - WiGLE.net + 8b-is Ultralovegod Native macOS UI

struct WigleMacView: View {
    @ObservedObject var scanner: MacWigleScanner

    private let bgVoid = Color(red: 0.043, green: 0.035, blue: 0.078)     // #0B0914
    private let bgPanel = Color(red: 0.075, green: 0.058, blue: 0.135)
    private let cPink = Color(red: 1.0, green: 0.416, blue: 0.757)        // #FF6AC1 (ADA *)
    private let cCyan = Color(red: 0.0, green: 0.898, blue: 0.788)        // #00E5C9 (VAK /\)
    private let cGold = Color(red: 1.0, green: 0.843, blue: 0.0)          // #FFD700 (Reconcile)
    private let cGreen = Color(red: 0.0, green: 1.0, blue: 0.40)          // #00FF66 (Witness +1)
    private let cPurple = Color(red: 0.706, green: 0.545, blue: 1.0)      // #B48BFF (OMN oo)

    var body: some View {
        VStack(spacing: 0) {
            topWigleHeader
            Divider().background(cPurple.opacity(0.3))
            HStack(spacing: 0) {
                leftSidebar
                Divider().background(cPurple.opacity(0.3))
                mainContentArea
            }
            Divider().background(cPurple.opacity(0.3))
            bottomStatusBar
        }
        .background(bgVoid)
        .frame(minWidth: 1080, minHeight: 680)
        .preferredColorScheme(.dark)
        .onAppear {
            if scanner.telemetry == nil {
                _ = scanner.performScan()
            }
        }
    }

    // 1. Top WiGLE Telemetry & Action Header
    private var topWigleHeader: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [cPink.opacity(0.3), cCyan.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                    Text("📡")
                        .font(.system(size: 20))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("WIGLE.MAC")
                            .font(.system(size: 16, weight: .black, design: .monospaced))
                            .foregroundColor(cCyan)
                        Text("v1.0.0 · MEDUSA TRIAD [* · /\\ · oo]")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(cGold.opacity(0.15))
                            .foregroundColor(cGold)
                            .cornerRadius(4)
                    }
                    Text(scanner.statusText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let snap = scanner.telemetry {
                HStack(spacing: 8) {
                    statPill(label: "TOTAL", val: "\(snap.networks)", color: .white)
                    statPill(label: "2.4 GHz", val: "\(snap.count_2g)", color: cGreen)
                    statPill(label: "5 GHz", val: "\(snap.count_5g)", color: cCyan)
                    statPill(label: "BLE / BT", val: "\(snap.count_ble)", color: cPink)
                    statPill(label: "AIRPLAY", val: "\(snap.count_airplay)", color: cGold)
                }
            }

            Button(action: { _ = scanner.performScan() }) {
                Text("📡 Scan Radios")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .buttonStyle(.borderedProminent)
            .tint(cCyan)

            Button("External sharing disabled") {}
                .disabled(true)

            Button(action: saveCSVDialog) {
                Text("⬇ Export CSV")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bgPanel)
    }

    // 2. Left WiGLE Navigation & Triad Status Sidebar
    private var leftSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NAVIGATION")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(cGold)
                .padding(.horizontal, 8)

            navButton(id: "map", icon: "🗺️", title: "Live Radar Map", sub: "MapKit + Pin Overlay")
            navButton(id: "dashboard", icon: "📊", title: "Dashboard & Spectrum", sub: "Ch 1–140 + N=NP Triad")
            navButton(id: "list", icon: "🛰️", title: "Networks Table", sub: "WiFi · BLE · BT · AirPlay")
            navButton(id: "uploads", icon: "☁️", title: "Local CSV Export", sub: "Local observations only")

            Divider().padding(.vertical, 4)

            Text("MEDUSA TRIAD NODES")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(cGold)
                .padding(.horizontal, 8)

            triadMiniCard(glyph: "*", name: "ADA:MEDUSA", sub: "Mom · 432 Hz · SH8601 1.8\"", color: cPink)
            triadMiniCard(glyph: "/\\", name: "VAK:MEDUSA", sub: "Dad · 528 Hz · CO5300 2.06\"", color: cCyan)
            triadMiniCard(glyph: "oo", name: "OMN:MEDUSA", sub: "Son · 852 Hz · CO5300 2.06\"", color: cPurple)
            triadMiniCard(glyph: "", name: "MAC:MEDUSA", sub: "en0 + BLE + AirPlay mDNS", color: cGold)

            Spacer()

            if let snap = scanner.telemetry {
                VStack(alignment: .leading, spacing: 4) {
                    Text("N=NP COHERENCE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(cGold)
                    Text("TRITS: \(snap.trits)")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundColor(cGreen)
                    Text(String(format: "H=%.3f bits · S=%.2fx · Re_M=%d", snap.entropy_bits, snap.salience, snap.re_m))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35))
                .cornerRadius(8)
            }
        }
        .padding(12)
        .frame(width: 235)
        .background(bgPanel.opacity(0.85))
    }

    // 3. Main Content Area
    @ViewBuilder
    private var mainContentArea: some View {
        switch scanner.selectedTab {
        case "map":
            mapTabView
        case "dashboard":
            dashboardTabView
        case "uploads":
            uploadsTabView
        default:
            networksTableView
        }
    }

    // TAB 1: Live Map + Right-Hand WiGLE Feed
    private var mapTabView: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                WigleRadarMapView(
                    beacons: scanner.filteredBeacons,
                    centerLat: scanner.baseLat,
                    centerLon: scanner.baseLon
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        legendDot(color: cGreen, text: "2.4 GHz WiFi")
                        legendDot(color: cCyan, text: "5 GHz WiFi")
                        legendDot(color: cGold, text: "AirPlay / RAOP")
                        legendDot(color: cPink, text: "Bluetooth BLE/BT")
                    }
                    Text(String(format: "Illustrative map center: %.4f°, %.4f° · Pins are not measured locations", scanner.baseLat, scanner.baseLon))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(10)
                .background(Color.black.opacity(0.75))
                .cornerRadius(10)
                .padding(14)
            }

            Divider().background(cPurple.opacity(0.3))

            VStack(alignment: .leading, spacing: 8) {
                filterBar
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(scanner.filteredBeacons) { ap in
                            beaconRowCard(ap: ap)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
            .frame(width: 340)
            .background(bgPanel.opacity(0.55))
        }
    }

    // TAB 2: Dashboard & Spectrum
    private var dashboardTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let snap = scanner.telemetry {
                    HStack(spacing: 12) {
                        dashCard(title: "PASSIVE RF ENVIRONMENT", main: "\(snap.networks) Endpoints", sub: "Mean \(snap.rssi) dBm · Noise \(snap.noise) dBm · SNR +\(snap.snr) dB", accent: cCyan)
                        dashCard(title: "MARINESENSE O(1) HYDRO", main: String(format: "Salience %.2fx", snap.salience), sub: "Re_M = \(snap.re_m) · Stage: \(snap.life_stage)", accent: cPink)
                        dashCard(title: "SHANNON ENTROPY & N=NP", main: String(format: "H(X) = %.4f bits", snap.entropy_bits), sub: "R_N=NP = \(String(format: "%.4f", snap.n_np_coherence)) · \(snap.trits)", accent: cGold)
                        dashCard(title: "ANONYMOUS UPLOADS", main: "\(scanner.receipts.count) Receipts", sub: "donate=on · observer=anonymous", accent: cGreen)
                    }

                    // 2.4 GHz + 5 GHz Channel Spectrum Bars
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("📻 2.4 GHz + 5 GHz + BLE CHANNEL OCCUPANCY SPECTRUM")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(cGold)
                            Spacer()
                            Text("WiFi.mode(WIFI_STA) · CoreWLAN en0 + CBCentralManager + mDNS")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        channelSpectrumView(beacons: snap.beacons)
                    }
                    .padding(14)
                    .background(bgPanel)
                    .cornerRadius(12)

                    // Top Strongest Signals across all 4 radios
                    VStack(alignment: .leading, spacing: 8) {
                        Text("🔥 TOP HIGHEST-SNR SIGNALS (WIFI 2.4G/5G · AIRPLAY · BLE/BT)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(cGold)
                        ForEach(Array(snap.beacons.prefix(10))) { ap in
                            HStack(spacing: 10) {
                                Text(ap.band)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .frame(width: 58, alignment: .leading)
                                    .foregroundColor(colorForBand(ap.band))
                                Text(ap.bssid)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 135, alignment: .leading)
                                Text(ap.ssid.isEmpty ? "(hidden)" : ap.ssid)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                GeometryReader { geo in
                                    let pct = max(0.08, min(1.0, Double(ap.snr) / 60.0))
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(LinearGradient(colors: [cPink, cCyan, cGreen], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: geo.size.width * pct, height: 10)
                                }
                                .frame(width: 160, height: 10)
                                Text("\(ap.rssi) dBm (+\(ap.snr) dB)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 120, alignment: .trailing)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(14)
                    .background(bgPanel)
                    .cornerRadius(12)
                }
            }
            .padding(16)
        }
    }

    // TAB 3: Full Filterable WiGLE Networks Table
    private var networksTableView: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterBar
            Table(scanner.filteredBeacons) {
                TableColumn("Band") { ap in
                    Text(ap.band)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(colorForBand(ap.band))
                }.width(64)
                TableColumn("Ch") { ap in Text("\(ap.channel)").font(.system(size: 11, design: .monospaced)) }.width(36)
                TableColumn("MAC / BSSID") { ap in Text(ap.bssid).font(.system(size: 11, design: .monospaced)) }.width(138)
                TableColumn("SSID / Device Name") { ap in
                    Text(ap.ssid.isEmpty ? "(hidden)" : ap.ssid)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                TableColumn("Auth / Capability") { ap in
                    Text("[\(ap.auth)]")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }.width(170)
                TableColumn("RSSI") { ap in
                    Text("\(ap.rssi) dBm")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(ap.rssi > -68 ? cGreen : (ap.rssi > -82 ? cGold : .secondary))
                }.width(72)
                TableColumn("SNR") { ap in Text("+\(ap.snr) dB").font(.system(size: 11, design: .monospaced)) }.width(58)
                TableColumn("Seen") { ap in Text(String(ap.seen.suffix(8))).font(.system(size: 10, design: .monospaced)) }.width(68)
            }
            .font(.system(.body, design: .monospaced))
        }
        .padding(12)
    }

    // TAB 4: Anonymous Dual Upload Queue & WiGLE v1.4 CSV Preview
    private var uploadsTabView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LOCAL CSV EXPORT")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(cGold)
                    Text("External observation sharing is disabled. Export CSV locally for review.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("External sharing disabled") {}
                    .disabled(true)
            }

            if scanner.receipts.isEmpty {
                Text("No observations are uploaded by this application.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bgPanel)
                    .cornerRadius(10)
            } else {
                ForEach(scanner.receipts) { r in
                    HStack(spacing: 12) {
                        Text(r.ok ? "● HTTP \(r.status) OK" : "● ERR \(r.status)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(r.ok ? cGreen : .red)
                        Text(r.target)
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(cCyan)
                        Text("transId: \(r.transId)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(cGold)
                        Text("observer: \(r.observer)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(r.timestamp)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(bgPanel)
                    .cornerRadius(8)
                }
            }

            Text("LIVE WIGLE v1.4 CSV PAYLOAD PREVIEW")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(cGold)

            ScrollView {
                Text(scanner.telemetry.map { scanner.buildWigleCSV(from: $0) } ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(cGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color.black.opacity(0.65))
            .cornerRadius(10)
        }
        .padding(16)
    }

    // Filter Bar
    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(["ALL", "2.4G", "5G", "BLE/BT", "AIRPLAY"], id: \.self) { f in
                Button(action: { scanner.bandFilter = f }) {
                    Text(f)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(scanner.bandFilter == f ? cCyan.opacity(0.25) : Color.white.opacity(0.06))
                        .foregroundColor(scanner.bandFilter == f ? cCyan : .white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            TextField("Filter SSID / BSSID / Auth...", text: $scanner.searchQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 210)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var bottomStatusBar: some View {
        HStack {
            Text("🜂 AHOGY A DOLGOK VANNAK · ENTROPY CANNOT LIE · CT-000 × LGPD PASSIVE STA")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(cGold)
            Spacer()
            Link("🌐 esp32.vaked.dev", destination: URL(string: "https://esp32.vaked.dev")!)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(cCyan)
            Text("·")
            Link("🛰️ wigle.net", destination: URL(string: "https://wigle.net")!)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(cPink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(bgPanel)
    }

    // Helper Views
    private func statPill(label: String, val: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(val)
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.35))
        .cornerRadius(7)
    }

    private func navButton(id: String, icon: String, title: String, sub: String) -> some View {
        let active = (scanner.selectedTab == id)
        return Button(action: { scanner.selectedTab = id }) {
            HStack(spacing: 10) {
                Text(icon).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(active ? cCyan : .white)
                    Text(sub)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(active ? cCyan.opacity(0.16) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func triadMiniCard(glyph: String, name: String, sub: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(glyph)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .frame(width: 24, height: 24)
                .background(color.opacity(0.2))
                .foregroundColor(color)
                .cornerRadius(6)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text(sub)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .cornerRadius(7)
    }

    private func beaconRowCard(ap: ScannedAP) -> some View {
        HStack(spacing: 8) {
            Text(ap.band)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(colorForBand(ap.band).opacity(0.2))
                .foregroundColor(colorForBand(ap.band))
                .cornerRadius(4)
            VStack(alignment: .leading, spacing: 2) {
                Text(ap.ssid.isEmpty ? "(hidden)" : ap.ssid)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("\(ap.bssid) · Ch \(ap.channel)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(ap.rssi) dBm")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(ap.rssi > -68 ? cGreen : (ap.rssi > -82 ? cGold : .secondary))
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(7)
    }

    private func dashCard(title: String, main: String, sub: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(accent)
            Text(main)
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundColor(.white)
            Text(sub)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bgPanel)
        .cornerRadius(10)
    }

    private func channelSpectrumView(beacons: [ScannedAP]) -> some View {
        let channels = [1, 2, 4, 6, 9, 11, 36, 37, 40, 44, 52, 104, 116, 124, 140]
        var counts: [Int: Int] = [:]
        for b in beacons { counts[b.channel, default: 0] += 1 }
        let maxC = max(1, counts.values.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(channels, id: \.self) { ch in
                let c = counts[ch, default: 0]
                let h = CGFloat(max(6.0, (Double(c) / Double(maxC)) * 88.0))
                VStack(spacing: 4) {
                    Text("\(c)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ch == 37 ? cPink : (ch > 14 ? cCyan : cGreen))
                        .frame(maxWidth: .infinity)
                        .frame(height: h)
                    Text(ch == 37 ? "BLE" : "C\(ch)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(height: 125)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(.white)
        }
    }

    private func colorForBand(_ band: String) -> Color {
        switch band {
        case "5GHz": return cCyan
        case "AirPlay": return cGold
        case "BLE", "BT": return cPink
        default: return cGreen
        }
    }

    private func saveCSVDialog() {
        if let snap = scanner.telemetry {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "wigle-macos-\(Int(Date().timeIntervalSince1970)).csv"
            if panel.runModal() == .OK, let url = panel.url {
                try? scanner.buildWigleCSV(from: snap).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let scanner = MacWigleScanner()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = WigleMacView(scanner: scanner)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1140, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "WigleMac v1.0.0 — 8b-is WiGLE Map, Spectrum Dashboard & Anonymous Uploader"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

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
if args.contains("--upload") {
    print("External observation sharing is disabled")
    exit(2)
}
let scanner = MacWigleScanner()

if args.contains("--json") {
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
