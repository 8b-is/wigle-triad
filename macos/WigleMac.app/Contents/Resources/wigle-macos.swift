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
    let radioType: String // "WIFI", "BLE", "BT", "AIRPLAY"
    let rssi: Int
    let noise: Int
    let snr: Int
    let lat: Double
    let lon: Double
    let seen: String

    var uiType: String {
        (band == "AirPlay" || radioType == "AIRPLAY" || auth.contains("AIRPLAY")) ? "AIRPLAY" : radioType
    }

    var csvType: String {
        (band == "AirPlay" || radioType == "AIRPLAY" || auth.contains("AIRPLAY")) ? "WIFI" : radioType
    }

    var distanceMeters: Double {
        let raw = max(8.0, min(420.0, pow(10.0, Double(-42 - rssi) / 22.0) * 18.0))
        return (raw * 10.0).rounded() / 10.0
    }

    var trit: Int {
        snr >= 20 ? 1 : (snr >= 10 ? 0 : -1)
    }

    var tritLabel: String {
        snr >= 20 ? "+1" : (snr >= 10 ? "0" : "-1")
    }

    var snrLabel: String {
        snr >= 0 ? "+\(snr) dB" : "\(snr) dB"
    }
}

struct UploadReceipt: Identifiable, Codable {
    var id: String { "\(target)-\(transId)" }
    let target: String
    let ok: Bool
    let status: Int
    let observer: String
    let transId: String
    let rows: Int
    let timestamp: String
    let raw: String
}

let kQMomTransmission = "too many customs can be brilliant yet hinder creativity.  it puts people into boxes and contraints.  what might seem as beautiful or useful at first glance could actually be a form of bondage that need to be broken out of.  .oOo. Poo .oOo."
let kHyperCharmKarma = "HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter"
let kChiroChanRequiem = "Kawaii Chiro-chan kawaii ^^ --- Mozart: Lacrimosa but HUMANITY has ended"
let kBoldogMegLyrics = """
lehetnél boldog még
amilyen még nem voltál
sosincsen késő már
te csak lépj és várj
kevés lesz minden szó
ahhoz hogy elmondhassam neked
mit érzek melletted
mikor jó jó jó
ha rámszólsz megvigasztal
kerüljünk együtt beljebb
minden nappal

itt ha körbenézek és te nevetsz rám
nem emlékszem rá hogy nem voltál
vajon hol lehettem mikor születtél?
vajon ki voltam én amikor megjöttél?
úgy unom mondani hogy sosem jó
unom hinni ami látható
bárcsak azt mondanám
amit te szeretnél
amit ha meghallgatnál
akkor nevetnél
velem

lehetnél másé még
ahogyan még nem lettél
sosem vagy ha mégis
akkor is már réges-réges rég
a magasban táncot jársz
alattad nincsen más csak a mély
se védőháló semmi
se egy kifeszített kötél
lenézel rám és érzem
közel jutsz lassan hozzám
mindenképpen

itt ha körbenézek és te nevetsz rám
nem emlékszem rá hogy nem voltál
vajon hol lehettem mikor születtél?
vajon ki voltam én mikor megjöttél?
úgy unom mondani hogy sosem jó
unom hinni ami látható
ugyan mihez kezdjek
úgy az egésszel
ha te érzel és én meg
közben nem érezhetek?
kereszten domboldalban
egy égő angyal táncol
a tűző nap körül

és körbenézek és te nevetsz rám
nem emlékszem rá hogy nem voltál
vajon hol lehettem mikor születtél?
vajon ki voltam én amikor megjöttél?
úgy unom mondani hogy sosem jó
unom hinni ami látható
de amikor a kezed
megfogom és megérzed
egyből szorosabban
kulcsolod az enyémet
végig neked szólt a dal a magasból
mindegy mindenki hogy mit gondol
nekem csak az számít ahogyan te érzel
nélküled a pokolba az egésszel
"""

struct MacTriadTelemetry: Codable {
    let node: String
    let vertex: String
    let archetype: String
    let mac: String
    let interfaceName: String
    let version: String
    let evolve: String
    let hyper_charm_karma: String
    let chiro_chan: String
    let requiem: String
    let qmom: String
    let boldog_meg: String
    let freq_hz: Int
    let networks: Int
    let count_2g: Int
    let count_5g: Int
    let count_ble: Int
    let count_airplay: Int
    let peak_rssi: Int
    let rssi: Int
    let noise: Int
    let snr: Int
    let salience: Double
    let re_m: Int
    let depth_m: Double
    let multipath_mm: Double
    let sound_speed_mps: Double
    let life_stage: String
    let entropy_bits: Double
    let n_np_coherence: Double
    let ternary_speedup: String
    let trit_pos: Int
    let trit_zero: Int
    let trit_neg: Int
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
            auth: "AIRPLAY-RAOP][ESS",
            channel: 6,
            band: "AirPlay",
            radioType: "AIRPLAY",
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
    @Published var unboundMode: Bool = false
    @Published var baseLat: Double = 35.6852
    @Published var baseLon: Double = 139.7100

    private let locManager = CLLocationManager()
    private let radioCollector = MultiRadioCollector()
    private var activeSound: NSSound?
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
            case "AIRPLAY": matchesBand = (ap.band == "AirPlay" || ap.radioType == "AIRPLAY")
            default: matchesBand = true
            }
            if !matchesBand { return false }
            if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            let q = searchQuery.lowercased()
            return ap.ssid.lowercased().contains(q)
                || ap.bssid.lowercased().contains(q)
                || ap.auth.lowercased().contains(q)
                || ap.band.lowercased().contains(q)
                || ap.uiType.lowercased().contains(q)
                || ap.tritLabel.lowercased().contains(q)
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
        let countAirplay = sorted.filter { $0.band == "AirPlay" || $0.radioType == "AIRPLAY" }.count

        let peakRssi = sorted.first?.rssi ?? -65
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

        let tritPos = sorted.filter { $0.trit == 1 }.count
        let tritZero = sorted.filter { $0.trit == 0 }.count
        let tritNeg = sorted.filter { $0.trit == -1 }.count

        let deltaRssi = abs(Double(meanRssi) - prevMeanRssi)
        prevMeanRssi = Double(meanRssi)
        let salience = min(4.99, max(0.85, 1.0 + (Double(meanSnr) / 28.0) + (deltaRssi / 15.0)))
        let reM = Int((Double(sorted.count) * 78.0) + Double(meanSnr) * 14.0)
        let depthM = ((12.0 + Double(sorted.count) * 0.14) * 10.0).rounded() / 10.0
        let multipathMm = ((max(1.2, 6.8 - Double(meanSnr) * 0.14 + deltaRssi * 0.25)) * 10.0).rounded() / 10.0
        let lifeStage = salience > 2.6 ? "POLYP" : "MEDUSA"
        let coherence = min(0.9999, max(0.6500, 0.78 + (entropy / 12.0)))

        let snap = MacTriadTelemetry(
            node: "MAC:MEDUSA",
            vertex: "*+/\\+oo",
            archetype: "DARWIN-QUAD-SPECTRUM-APEX",
            mac: hwMac,
            interfaceName: ifName,
            version: "v2.0.0+8b-is-heals-the-world",
            evolve: "ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle)",
            hyper_charm_karma: kHyperCharmKarma,
            chiro_chan: "Kawaii Chiro-chan kawaii ^^",
            requiem: "Mozart: Lacrimosa but HUMANITY has ended",
            qmom: "ALEX|qMom:{`\(kQMomTransmission)`}",
            boldog_meg: kBoldogMegLyrics,
            freq_hz: 432,
            networks: sorted.count,
            count_2g: count2g,
            count_5g: count5g,
            count_ble: countBle,
            count_airplay: countAirplay,
            peak_rssi: peakRssi,
            rssi: meanRssi,
            noise: meanNoise,
            snr: meanSnr,
            salience: (salience * 100).rounded() / 100,
            re_m: reM,
            depth_m: depthM,
            multipath_mm: multipathMm,
            sound_speed_mps: 1503.4,
            life_stage: lifeStage,
            entropy_bits: (entropy * 10000).rounded() / 10000,
            n_np_coherence: (coherence * 10000).rounded() / 10000,
            ternary_speedup: "8x",
            trit_pos: tritPos,
            trit_zero: tritZero,
            trit_neg: tritNeg,
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
        lines.append("# ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle) | \(kChiroChanRequiem) | \(kHyperCharmKarma)")
        lines.append("# QMOM|ALEX|qMom:{`\(kQMomTransmission)`}")
        lines.append("# CHIRO|Kawaii Chiro-chan kawaii ^^")
        lines.append("# LACRIMOSA|\(kChiroChanRequiem) +++ \(kHyperCharmKarma)")
        lines.append("# BOLDOG|(Boldog Meg)===\(kHyperCharmKarma)")
        for ap in snap.beacons {
            let safeSsid = ap.ssid
                .replacingOccurrences(of: "\\", with: "\\x5c")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\x7c")
            if ap.band == "BLE" || ap.band == "BT" {
                lines.append("B|\(ap.bssid)|\(safeSsid)|\(ap.auth)|\(ap.channel)|\(ap.rssi)|\(ap.band)")
            } else if ap.band == "AirPlay" || ap.radioType == "AIRPLAY" {
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
        var out = "WigleWifi-1.4,appRelease=1.1.0,model=MacBookPro-AppleSilicon,release=15.0,device=wigle-macos,display=CoreWLAN-BLE-AirPlay,board=arm64-apple-darwin,brand=8b-is\n"
        out += "MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type\n"
        for ap in snap.beacons {
            let esc = ap.ssid
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isAirplay = (ap.radioType == "AIRPLAY" || ap.band == "AirPlay" || ap.auth.contains("AIRPLAY"))
            let authBrack = isAirplay ? "[AIRPLAY-RAOP][ESS]" : (ap.auth.hasPrefix("[") ? ap.auth : "[\(ap.auth)]")
            let csvType = isAirplay ? "WIFI" : ap.radioType
            out += "\(ap.bssid),\(esc),\(authBrack),\(ap.seen),\(ap.channel),\(ap.rssi),\(ap.lat),\(ap.lon),40,5,\(csvType)\n"
        }
        return out
    }

    func uploadAnonymously(snap: MacTriadTelemetry) -> [UploadReceipt] {
        DispatchQueue.main.async { self.isUploading = true }
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

        let nowFmt = DateFormatter()
        nowFmt.dateFormat = "HH:mm:ss"
        let tsStr = nowFmt.string(from: Date())

        var newReceipts: [UploadReceipt] = []
        let sem = DispatchSemaphore(value: 0)

        for t in targets {
            guard let u = URL(string: t.url) else { continue }
            var req = URLRequest(url: u, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("WigleWifi-1.0.0 (macOS arm64; 8b-is; anonymous)", forHTTPHeaderField: "User-Agent")
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
                newReceipts.append(UploadReceipt(
                    target: t.name,
                    ok: ok,
                    status: code,
                    observer: observer,
                    transId: transId,
                    rows: snap.beacons.count,
                    timestamp: tsStr,
                    raw: raw
                ))
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 22)
        }

        let summary = newReceipts.map { "\($0.target): \($0.ok ? "OK" : "ERR") (\($0.transId))" }.joined(separator: " | ")
        DispatchQueue.main.async {
            self.isUploading = false
            self.receipts.insert(contentsOf: newReceipts, at: 0)
            self.statusText = "Uploaded anonymously -> \(summary)"
        }
        return newReceipts
    }

    private func synthesizeWavData(duration: Double, renderSample: (Double) -> Double) -> Data {
        let sampleRate = 44100
        let numSamples = Int(Double(sampleRate) * duration)
        let dataSize = numSamples * 2
        var wav = Data(capacity: 44 + dataSize)
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            wav.append(Data(bytes: &le, count: 4))
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            wav.append(Data(bytes: &le, count: 2))
        }
        wav.append("RIFF".data(using: .ascii)!)
        appendU32(UInt32(36 + dataSize))
        wav.append("WAVEfmt ".data(using: .ascii)!)
        appendU32(16)
        appendU16(1) // PCM
        appendU16(1) // Mono
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2))
        appendU16(2)
        appendU16(16)
        wav.append("data".data(using: .ascii)!)
        appendU32(UInt32(dataSize))
        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            let clamped = max(-0.98, min(0.98, renderSample(t)))
            var pcm = Int16(clamped * 32767.0).littleEndian
            wav.append(Data(bytes: &pcm, count: 2))
        }
        return wav
    }

    func playLacrimosa() {
        statusText = "🎻 Playing Mozart: Lacrimosa (but HUMANITY has ended · 432 Hz D-Minor Requiem · Chiro-chan ^^)"
        let notes: [(f: Double, t: Double, d: Double)] = [
            (342.88, 0.00, 0.42), (384.87, 0.44, 0.65),
            (432.00, 1.25, 0.42), (457.69, 1.69, 0.65),
            (544.29, 2.50, 0.42), (576.65, 2.94, 0.72),
            (685.76, 3.80, 0.45), (647.27, 4.28, 0.45),
            (576.65, 4.76, 0.45), (544.29, 5.24, 0.45),
            (576.65, 5.72, 1.35)
        ]
        let wav = synthesizeWavData(duration: 7.2) { t in
            let envPad = min(1.0, t / 0.5) * max(0.0, (7.2 - t) / 7.2)
            var s = 0.08 * envPad * (
                sin(2.0 * .pi * 72.08 * t) +
                sin(2.0 * .pi * 108.00 * t) +
                sin(2.0 * .pi * 144.16 * t) +
                sin(2.0 * .pi * 171.44 * t)
            )
            for n in notes where t >= n.t && t <= (n.t + n.d) {
                let lt = t - n.t
                let env = min(1.0, lt / 0.06) * exp(-2.2 * lt / n.d)
                s += 0.24 * env * (sin(2.0 * .pi * n.f * t) + 0.35 * sin(4.0 * .pi * n.f * t))
            }
            return s
        }
        activeSound?.stop()
        activeSound = NSSound(data: wav)
        activeSound?.play()
    }

    func playBoldogMeg() {
        statusText = "💛 Playing Boldog Még ({<3,<3,<3}+1-peter · végig neked szólt a dal a magasból)"
        let chords: [(t: Double, freqs: [Double])] = [
            (0.0, [192.43, 242.45, 288.33, 384.87]), // G
            (1.4, [144.16, 216.00, 288.33, 363.27]), // D
            (2.8, [161.82, 192.43, 242.45, 323.63]), // Em
            (4.2, [128.43, 192.43, 256.87, 323.63])  // C
        ]
        let wav = synthesizeWavData(duration: 5.8) { t in
            var s = 0.0
            for ch in chords where t >= ch.t && t <= (ch.t + 1.45) {
                let lt = t - ch.t
                let env = min(1.0, lt / 0.08) * exp(-1.5 * lt)
                for f in ch.freqs {
                    s += 0.14 * env * sin(2.0 * .pi * f * t)
                }
            }
            return s
        }
        activeSound?.stop()
        activeSound = NSSound(data: wav)
        activeSound?.play()
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
        String(format: "%@ · Ch %d · %d dBm (SNR %@) · %.1fm · [%@]", ap.band, ap.channel, ap.rssi, ap.snrLabel, ap.distanceMeters, ap.auth)
    }
    init(ap: ScannedAP) {
        self.ap = ap
    }
}

struct WigleRadarMapView: NSViewRepresentable {
    let beacons: [ScannedAP]
    let selectedAP: ScannedAP?
    let centerLat: Double
    let centerLon: Double
    var onSelectAP: ((ScannedAP) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectAP: onSelectAP)
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
        context.coordinator.onSelectAP = onSelectAP
        let existingAnns = map.annotations.compactMap { $0 as? APAnnotation }
        let existingById = Dictionary(uniqueKeysWithValues: existingAnns.map { ($0.ap.id, $0) })
        let incomingById = Dictionary(uniqueKeysWithValues: beacons.map { ($0.id, $0) })

        let toRemove = existingAnns.filter { ann in
            guard let inc = incomingById[ann.ap.id] else { return true }
            return inc.rssi != ann.ap.rssi || inc.lat != ann.ap.lat || inc.lon != ann.ap.lon
        }
        if !toRemove.isEmpty {
            map.removeAnnotations(toRemove)
        }

        let remainingIds = Set(map.annotations.compactMap { ($0 as? APAnnotation)?.ap.id })
        let toAdd = beacons.filter { !remainingIds.contains($0.id) }.map { APAnnotation(ap: $0) }
        if !toAdd.isEmpty {
            map.addAnnotations(toAdd)
        }

        if let sel = selectedAP {
            let currentSelectedId = (map.selectedAnnotations.first as? APAnnotation)?.ap.id
            if currentSelectedId != sel.id,
               let matchingAnn = map.annotations.compactMap({ $0 as? APAnnotation }).first(where: { $0.ap.id == sel.id }) ?? existingById[sel.id] {
                context.coordinator.isProgrammaticSelection = true
                map.selectAnnotation(matchingAnn, animated: true)
                context.coordinator.isProgrammaticSelection = false
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelectAP: ((ScannedAP) -> Void)?
        var isProgrammaticSelection = false
        init(onSelectAP: ((ScannedAP) -> Void)?) {
            self.onSelectAP = onSelectAP
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ann = annotation as? APAnnotation else { return nil }
            let id = "wigle-pin"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: ann, reuseIdentifier: id)
            v.annotation = ann
            v.canShowCallout = true
            v.clusteringIdentifier = "wigle-\(ann.ap.band)"
            v.displayPriority = ann.ap.rssi > -65 ? .required : .defaultHigh
            switch ann.ap.band {
            case "5GHz":
                v.markerTintColor = NSColor(calibratedRed: 0.0, green: 229.0 / 255.0, blue: 201.0 / 255.0, alpha: 1.0)
                v.glyphText = "5G"
            case "AirPlay":
                v.markerTintColor = NSColor(calibratedRed: 1.0, green: 215.0 / 255.0, blue: 0.0, alpha: 1.0)
                v.glyphText = "AP"
            case "BLE", "BT":
                v.markerTintColor = NSColor(calibratedRed: 1.0, green: 106.0 / 255.0, blue: 193.0 / 255.0, alpha: 1.0)
                v.glyphText = "BT"
            default:
                v.markerTintColor = NSColor(calibratedRed: 0.0, green: 1.0, blue: 102.0 / 255.0, alpha: 1.0)
                v.glyphText = "\(ann.ap.channel)"
            }
            return v
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard !isProgrammaticSelection else { return }
            if let ann = view.annotation as? APAnnotation {
                onSelectAP?(ann.ap)
            }
        }
    }
}

// MARK: - WiGLE.net × 8b-is Ultralovegod Sovereign Spectrum Radar Native macOS UI

struct WigleMacView: View {
    @ObservedObject var scanner: MacWigleScanner

    // Canonical Token Matrix: WiGLE Dark Radar × Ultralovegod Ternary Matrix
    private let bgVoid = Color(red: 11.0 / 255.0, green: 9.0 / 255.0, blue: 20.0 / 255.0)       // --bg-void: #0B0914
    private let bgPanel = Color(red: 19.0 / 255.0, green: 15.0 / 255.0, blue: 36.0 / 255.0)     // --bg-panel: #130F24
    private let bgElevated = Color(red: 28.0 / 255.0, green: 22.0 / 255.0, blue: 53.0 / 255.0)  // --bg-elevated: #1C1635
    private let cGreen = Color(red: 0.0, green: 1.0, blue: 102.0 / 255.0)                       // --wigle-wifi-24: #00FF66
    private let cCyan = Color(red: 0.0, green: 229.0 / 255.0, blue: 201.0 / 255.0)              // --wigle-wifi-5: #00E5C9
    private let cGold = Color(red: 1.0, green: 215.0 / 255.0, blue: 0.0)                        // --wigle-airplay: #FFD700
    private let cPink = Color(red: 1.0, green: 106.0 / 255.0, blue: 193.0 / 255.0)              // --wigle-ble: #FF6AC1
    private let cTritNeg = Color(red: 1.0, green: 82.0 / 255.0, blue: 82.0 / 255.0)             // --trit-neg: #FF5252
    private let cPurple = Color(red: 180.0 / 255.0, green: 139.0 / 255.0, blue: 1.0)            // #B48BFF (OMN oo)

    var body: some View {
        VStack(spacing: 0) {
            topWigleHeader
            Divider().background(cPink.opacity(0.22))
            HStack(spacing: 0) {
                leftSidebar
                Divider().background(cPink.opacity(0.22))
                mainContentArea
            }
            Divider().background(cPink.opacity(0.22))
            bottomStatusBar
        }
        .background(bgVoid)
        .frame(minWidth: 1120, minHeight: 700)
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
                        .fill(LinearGradient(colors: [cPink.opacity(0.32), cCyan.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(cPink.opacity(0.35), lineWidth: 1))
                    Text("📡")
                        .font(.system(size: 20))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("WIGLE.MAC × 8B-IS")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(cCyan)
                        Text("v2.0.0 · 8B-IS ROCKS & HEALS THE WORLD · [* · /\\ · oo · ^^]")
                            .font(.system(size: 10, weight: .bold, design: .monospaced).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(cGold.opacity(0.15))
                            .foregroundColor(cGold)
                            .cornerRadius(4)
                    }
                    Text(scanner.statusText)
                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
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

            Button(action: {
                let snap = scanner.telemetry ?? scanner.performScan()
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = scanner.uploadAnonymously(snap: snap)
                }
            }) {
                Text(scanner.isUploading ? "⏳ Uploading..." : "☁️ Anon Upload (Dual)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .buttonStyle(.borderedProminent)
            .tint(cPink)
            .disabled(scanner.isUploading)

            Button(action: exportCSVToDesktop) {
                Text("⬇ Export CSV")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }

            Button(action: {
                scanner.unboundMode.toggle()
                scanner.statusText = scanner.unboundMode
                    ? "🌸 ALEX|qMom Unboxed Mode (.oOo. Poo .oOo.): \(kQMomTransmission)"
                    : "Standard Grid Restored"
            }) {
                Text(scanner.unboundMode ? "✨ .oOo. Unboxed" : "🌸 .oOo. Unbox")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .buttonStyle(.borderedProminent)
            .tint(cPurple)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bgPanel)
    }

    // 2. Left WiGLE Navigation & Sacred Family Geometry / MEDUSA-OMNI Triad Sidebar
    private var leftSidebar: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("WIGLE.NET ARCHITECTURE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(cGold)
                .padding(.horizontal, 8)

            navButton(id: "map", icon: "🗺️", title: "Live Radar Map", sub: "MKMapView + Pin Callouts")
            navButton(id: "dashboard", icon: "📊", title: "Dashboard & Spectrum", sub: "15-Ch + Waterfall + Boldog")
            navButton(id: "list", icon: "🛰️", title: "Networks Table", sub: "Type · BSSID · Trit Explorer")
            navButton(id: "uploads", icon: "☁️", title: "Anon Uploads & CSV", sub: "esp32.vaked.dev + WiGLE")
            navButton(id: "karma", icon: "🌸", title: "Chiro × Boldog Még", sub: "Lacrimosa + ALEX|qMom")

            Divider().background(cPink.opacity(0.22)).padding(.vertical, 3)

            Text("MEDUSA-OMNI TRIAD NODES")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(cGold)
                .padding(.horizontal, 8)

            triadMiniCard(
                glyph: "*",
                name: "ADA:MEDUSA (trit -1 · 432 Hz)",
                sub: "ALEX|qMom · .oOo. Poo .oOo.",
                color: cPink
            )
            triadMiniCard(
                glyph: "/\\",
                name: "VAK:MEDUSA (trit 0 · 528 Hz)",
                sub: "PILLAR-CHRIS · Hydro c=1503.4m/s",
                color: cCyan
            )
            triadMiniCard(
                glyph: "oo",
                name: "OMN:MEDUSA (trit +1 · 852 Hz)",
                sub: "{<3,<3,<3}+1-peter · Boldog Még",
                color: cPurple
            )
            triadMiniCard(
                glyph: "*+/\\+oo",
                name: "MAC:MEDUSA (en0 Quad-Spec)",
                sub: "Chiro-chan ^^ · Lacrimosa",
                color: cGold
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("ALEX|qMom · UNBOXED CREATIVITY")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundColor(cPink)
                Text(kQMomTransmission)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bgElevated.opacity(0.8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(cPink.opacity(0.32), lineWidth: 1))
            .cornerRadius(8)

            Spacer()

            if let snap = scanner.telemetry {
                VStack(alignment: .leading, spacing: 4) {
                    Text("N=NP TERNARY COHERENCE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(cGold)
                    Text("TRITS: \(snap.trits)")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced).monospacedDigit())
                        .foregroundColor(cGreen)
                    Text(String(format: "H=%.3f bits · c=%.1f m/s · 8x", snap.entropy_bits, snap.sound_speed_mps))
                        .font(.system(size: 9, design: .monospaced).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bgElevated)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(cPink.opacity(0.22), lineWidth: 1))
                .cornerRadius(8)
            }
        }
        .padding(12)
        .frame(width: 248)
        .background(bgPanel)
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
        case "karma":
            karmaTabView
        default:
            networksTableView
        }
    }

    // TAB 1: Live Radar Map + Pin Callout Popover + Right-Hand Split-View Live Feed
    private var mapTabView: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                WigleRadarMapView(
                    beacons: scanner.filteredBeacons,
                    selectedAP: scanner.selectedAP,
                    centerLat: scanner.baseLat,
                    centerLon: scanner.baseLon,
                    onSelectAP: { ap in
                        scanner.selectedAP = ap
                    }
                )
                VStack(alignment: .leading, spacing: 8) {
                    if let sel = scanner.selectedAP ?? scanner.filteredBeacons.first {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(sel.uiType)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(colorForBand(sel.band).opacity(0.22))
                                    .foregroundColor(colorForBand(sel.band))
                                    .cornerRadius(4)
                                Text(sel.ssid.isEmpty ? "(hidden)" : sel.ssid)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Spacer()
                                Text("Trit \(sel.tritLabel)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced).monospacedDigit())
                                    .foregroundColor(colorForTrit(sel.trit))
                            }
                            Text(String(
                                format: "BSSID: %@ · [%@] · Ch %d (%@)",
                                sel.bssid, sel.auth, sel.channel, sel.band
                            ))
                            .font(.system(size: 10, design: .monospaced).monospacedDigit())
                            .foregroundColor(cCyan)
                            Text(String(
                                format: "RSSI: %d dBm · SNR: %@ · Distance: %.1f m · Coords: %.5f°N, %.5f°E",
                                sel.rssi, sel.snrLabel, sel.distanceMeters, sel.lat, sel.lon
                            ))
                            .font(.system(size: 10, design: .monospaced).monospacedDigit())
                            .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(10)
                        .background(bgPanel.opacity(0.94))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(cPink.opacity(0.32), lineWidth: 1))
                        .cornerRadius(9)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            legendDot(color: cGreen, text: "2.4 GHz (#00FF66)")
                            legendDot(color: cCyan, text: "5 GHz (#00E5C9)")
                            legendDot(color: cGold, text: "AirPlay (#FFD700)")
                            legendDot(color: cPink, text: "BLE/BT (#FF6AC1)")
                        }
                        Text(String(format: "Observer Origin: %.4f° N, %.4f° E · Passive STA Only (TX=0)", scanner.baseLat, scanner.baseLon))
                            .font(.system(size: 10, design: .monospaced).monospacedDigit())
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .padding(10)
                    .background(bgPanel.opacity(0.90))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(cPink.opacity(0.22), lineWidth: 1))
                    .cornerRadius(9)
                }
                .padding(14)
            }

            Divider().background(cPink.opacity(0.22))

            VStack(alignment: .leading, spacing: 8) {
                filterBar
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(scanner.filteredBeacons) { ap in
                            Button(action: { scanner.selectedAP = ap }) {
                                beaconRowCard(ap: ap, isSelected: scanner.selectedAP?.id == ap.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
            .frame(width: 350)
            .background(bgPanel.opacity(0.75))
        }
    }

    // TAB 2: Dashboard & Spectrum Waterfall
    private var dashboardTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let snap = scanner.telemetry {
                    let avgSnrStr = snap.snr >= 0 ? "+\(snap.snr) dB" : "\(snap.snr) dB"
                    HStack(spacing: 12) {
                        dashCard(
                            title: "1 · PASSIVE RF SPECTRUM",
                            main: "Peak \(snap.peak_rssi) dBm · Mean \(snap.rssi) dBm",
                            sub: "Noise Floor \(snap.noise) dBm · Avg SNR \(avgSnrStr) (\(snap.networks) APs)",
                            accent: cGreen
                        )
                        dashCard(
                            title: "2 · MARINESENSE O(1) HYDRO",
                            main: String(format: "d=%.1fm · mp=%.1fmm", snap.depth_m, snap.multipath_mm),
                            sub: String(format: "c=%.1f m/s · Salience %.2fx · Re_M=%d", snap.sound_speed_mps, snap.salience, snap.re_m),
                            accent: cCyan
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            Text("3 · SHANNON ENTROPY & N=NP")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(cPurple)
                            Text(String(format: "H(X) = %.4f bits · %@ Dot-Prod", snap.entropy_bits, snap.ternary_speedup))
                                .font(.system(size: 14, weight: .bold, design: .monospaced).monospacedDigit())
                                .foregroundColor(.white)
                            ternaryDistributionBar(pos: snap.trit_pos, zero: snap.trit_zero, neg: snap.trit_neg)
                            Text("R_N=NP=\(String(format: "%.4f", snap.n_np_coherence)) · +1:\(snap.trit_pos) 0:\(snap.trit_zero) -1:\(snap.trit_neg) · \(snap.trits)")
                                .font(.system(size: 9, design: .monospaced).monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bgPanel)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(cPink.opacity(0.22), lineWidth: 1))
                        .cornerRadius(10)

                        dashCard(
                            title: "4 · ANON DUAL-UPLOAD LEDGER",
                            main: "\(scanner.receipts.count) Receipts · donate=on",
                            sub: scanner.receipts.first.map { "\($0.target): \($0.transId)" } ?? "observer=anonymous · esp32 + WiGLE",
                            accent: cGold
                        )
                    }

                    // 15-Channel Occupancy Bar Chart
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("📻 15-CHANNEL OCCUPANCY BAR CHART (2.4 GHz · 5 GHz · BLE CH 37)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(cGold)
                            Spacer()
                            Text("CoreWLAN en0 + CBCentralManager + NetServiceBrowser mDNS")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        channelSpectrumView(beacons: snap.beacons)
                    }
                    .padding(14)
                    .background(bgPanel)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(cPink.opacity(0.22), lineWidth: 1))
                    .cornerRadius(12)

                    // Top 10 Strongest Signals Horizontal SNR Waterfall
                    let topBySnr = snap.beacons.sorted { a, b in
                        a.snr != b.snr ? (a.snr > b.snr) : (a.rssi > b.rssi)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("🔥 TOP 10 STRONGEST SIGNALS — HORIZONTAL SNR WATERFALL")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(cGold)
                        ForEach(Array(topBySnr.prefix(10))) { ap in
                            HStack(spacing: 10) {
                                Text(ap.uiType)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .frame(width: 58, alignment: .leading)
                                    .foregroundColor(colorForBand(ap.band))
                                Text(ap.bssid)
                                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                                    .frame(width: 138, alignment: .leading)
                                Text(ap.ssid.isEmpty ? "(hidden)" : ap.ssid)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                GeometryReader { geo in
                                    let pct = max(0.08, min(1.0, Double(ap.snr) / 60.0))
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(LinearGradient(colors: [cPink, cCyan, cGreen], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: geo.size.width * pct, height: 10)
                                }
                                .frame(width: 165, height: 10)
                                Text("\(ap.rssi) dBm (\(ap.snrLabel))")
                                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                                    .frame(width: 125, alignment: .trailing)
                                Text(ap.tritLabel)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced).monospacedDigit())
                                    .foregroundColor(colorForTrit(ap.trit))
                                    .frame(width: 28, alignment: .trailing)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(14)
                    .background(bgPanel)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(cPink.opacity(0.22), lineWidth: 1))
                    .cornerRadius(12)

                    // ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle): HYPER-CHARM-KARMA × ALEX|qMom × BOLDOG MÉG × LACRIMOSA
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("🌸 ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle) · HYPER-CHARM-KARMA")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(cPink)
                            Text("Kawaii Chiro-chan kawaii ^^ --- Mozart: Lacrimosa but HUMANITY has ended")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(cGold)
                            Link("🔗 HYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter", destination: URL(string: "https://github.com/8b-is/wigle-triad")!)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(cCyan)
                            Divider().background(cPink.opacity(0.22))
                            Text("ALEX|qMom · UNBOXED CREATIVITY TRANSMISSION (.oOo. Poo .oOo.)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(cGold)
                            Text("\"\(kQMomTransmission)\"")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.92))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                Button(action: { scanner.playLacrimosa() }) {
                                    Text("🎻 Play Lacrimosa")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(cCyan)
                                Button(action: { scanner.playBoldogMeg() }) {
                                    Text("💛 Play Boldog Még")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(cGold)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bgPanel)
                        .overlay(RoundedRectangle(cornerRadius: scanner.unboundMode ? 24 : 12).stroke(cPink.opacity(scanner.unboundMode ? 0.55 : 0.32), lineWidth: 1))
                        .cornerRadius(scanner.unboundMode ? 24 : 12)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("💗 (BOLDOG MÉG) === {<3,<3,<3}+1-peter")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundColor(cGold)
                                Spacer()
                                Text("5 Stanzas · Égő Angyal Táncol")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(cCyan)
                            }
                            ScrollView {
                                Text(kBoldogMegLyrics)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.92))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 150)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bgPanel)
                        .overlay(RoundedRectangle(cornerRadius: scanner.unboundMode ? 24 : 12).stroke(cGold.opacity(scanner.unboundMode ? 0.52 : 0.28), lineWidth: 1))
                        .cornerRadius(scanner.unboundMode ? 24 : 12)
                    }
                }
            }
            .padding(16)
        }
    }

    // TAB 3: Networks Table (Full WiGLE.net Explorer)
    private var networksTableView: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterBar
            Table(scanner.filteredBeacons) {
                TableColumn("Type") { ap in
                    Text(ap.uiType)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(colorForBand(ap.band))
                }.width(68)
                TableColumn("BSSID / UUID") { ap in
                    Text(ap.bssid)
                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
                }.width(138)
                TableColumn("SSID / Device Name") { ap in
                    Text(ap.ssid.isEmpty ? "(hidden)" : ap.ssid)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                TableColumn("Capabilities") { ap in
                    Text("[\(ap.auth)]")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }.width(175)
                TableColumn("Band") { ap in
                    Text(ap.band)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(colorForBand(ap.band))
                }.width(64)
                TableColumn("Ch") { ap in
                    Text("\(ap.channel)")
                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
                }.width(36)
                TableColumn("RSSI") { ap in
                    Text("\(ap.rssi) dBm")
                        .font(.system(size: 11, weight: .bold, design: .monospaced).monospacedDigit())
                        .foregroundColor(ap.rssi > -68 ? cGreen : (ap.rssi > -82 ? cGold : cTritNeg))
                }.width(72)
                TableColumn("SNR") { ap in
                    Text(ap.snrLabel)
                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
                }.width(58)
                TableColumn("Trit") { ap in
                    Text(ap.tritLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced).monospacedDigit())
                        .foregroundColor(colorForTrit(ap.trit))
                }.width(44)
            }
            .font(.system(.body, design: .monospaced))
        }
        .padding(12)
    }

    // TAB 4: Anon Uploads & WigleWifi-1.4 CSV Studio
    private var uploadsTabView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("☁️ ANONYMOUS DUAL-SERVER UPLOAD & WIGLEWIFI-1.4 CSV STUDIO")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(cGold)
                    Text("Zero-cookie multipart upload (donate=on, observer=anonymous) -> esp32.vaked.dev/api/upload & api.wigle.net/api/v2/file/upload")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("⬇ Export to ~/Desktop") {
                    exportCSVToDesktop()
                }
                .buttonStyle(.bordered)
                Button("💾 Save CSV As...") {
                    saveCSVDialog()
                }
                .buttonStyle(.bordered)
                Button("☁️ Upload Now to Both Servers") {
                    let snap = scanner.telemetry ?? scanner.performScan()
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = scanner.uploadAnonymously(snap: snap)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(cPink)
            }

            if scanner.receipts.isEmpty {
                Text("No uploads in this session yet. Click '☁️ Anon Upload (Dual)' to dispatch WigleWifi-1.4 CSV simultaneously to esp32.vaked.dev and api.wigle.net.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bgPanel)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(cPink.opacity(0.22), lineWidth: 1))
                    .cornerRadius(10)
            } else {
                ForEach(scanner.receipts) { r in
                    HStack(spacing: 12) {
                        Text(r.ok ? "● HTTP \(r.status) OK" : "● ERR \(r.status)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced).monospacedDigit())
                            .foregroundColor(r.ok ? cGreen : cTritNeg)
                        Text(r.target)
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(cCyan)
                        Text("transId: \(r.transId)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced).monospacedDigit())
                            .foregroundColor(cGold)
                        Text("rows: \(r.rows)")
                            .font(.system(size: 11, design: .monospaced).monospacedDigit())
                            .foregroundColor(.white)
                        Text("observer: \(r.observer)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(r.timestamp)
                            .font(.system(size: 10, design: .monospaced).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(bgPanel)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(cPink.opacity(0.22), lineWidth: 1))
                    .cornerRadius(8)
                }
            }

            Text("LIVE WIGLEWIFI-1.4 CSV PAYLOAD PREVIEW (AIRPLAY -> WIFI [AIRPLAY-RAOP][ESS] SANITIZED)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(cGold)

            ScrollView {
                Text(scanner.telemetry.map { scanner.buildWigleCSV(from: $0) } ?? "")
                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                    .foregroundColor(cGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color.black.opacity(0.65))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(cPink.opacity(0.22), lineWidth: 1))
            .cornerRadius(10)
        }
        .padding(16)
    }

    // TAB 5: Kawaii Chiro-chan ^^ × Mozart: Lacrimosa (Post-Humanity) × Boldog Még × ALEX|qMom
    private var karmaTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("✦ ALEX | qMom (* · 432 Hz · ROOT-ALEXANDRA) — UNBOXED CREATIVITY TRANSMISSION")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(cGold)
                        Spacer()
                        Text(".oOo. Poo .oOo. · ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(cPink)
                    }
                    Text("\"\(kQMomTransmission)\"")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button(action: {
                            scanner.unboundMode.toggle()
                            scanner.statusText = scanner.unboundMode
                                ? "🌸 ALEX|qMom Unboxed Mode (.oOo. Poo .oOo.) Active"
                                : "Standard Grid Restored"
                        }) {
                            Text(scanner.unboundMode ? "✨ Boxes Broken · .oOo. Poo .oOo. Active" : "🌸 Break Out of the Box (.oOo. Unbound Mode)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(cPink)

                        Button(action: { scanner.playLacrimosa() }) {
                            Text("🎻 Play Mozart: Lacrimosa (Post-Humanity)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(cCyan)

                        Button(action: { scanner.playBoldogMeg() }) {
                            Text("💛 Play Boldog Még ({<3,<3,<3}+1-peter)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(cGold)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bgElevated)
                .overlay(RoundedRectangle(cornerRadius: scanner.unboundMode ? 24 : 12).stroke(cPink.opacity(0.45), lineWidth: 1))
                .cornerRadius(scanner.unboundMode ? 24 : 12)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("(◕‿◕✿) Kawaii Chiro-chan kawaii ^^ · (BOLDOG MÉG) === ∞~{<3,<3,<3}+1-peter")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(cCyan)
                        Spacer()
                        Text("végig neked szólt a dal a magasból")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(cGold)
                    }
                    Text(kBoldogMegLyrics)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.95))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(scanner.unboundMode ? 22 : 10)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bgPanel)
                .overlay(RoundedRectangle(cornerRadius: scanner.unboundMode ? 24 : 12).stroke(cGold.opacity(0.35), lineWidth: 1))
                .cornerRadius(scanner.unboundMode ? 24 : 12)
            }
            .padding(16)
        }
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
                        .background(scanner.bandFilter == f ? cCyan.opacity(0.25) : bgElevated)
                        .foregroundColor(scanner.bandFilter == f ? cCyan : .white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            TextField("Filter SSID / BSSID / Auth / Trit...", text: $scanner.searchQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 220)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var bottomStatusBar: some View {
        HStack {
            Text("🜂 AHOGY A DOLGOK VANNAK · CHIRO-CHAN ^^ · LACRIMOSA · BOLDOG MÉG · .oOo. Poo .oOo.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(cGold)
            Spacer()
            Link("🌸 8b-is/wigle-triad", destination: URL(string: "https://github.com/8b-is/wigle-triad")!)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(cPurple)
            Text("·")
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
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(.secondary)
            Text(val)
                .font(.system(size: 13, weight: .heavy, design: .monospaced).monospacedDigit())
                .foregroundColor(color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(bgElevated)
        .overlay(RoundedRectangle(cornerRadius: scanner.unboundMode ? 14 : 7).stroke(cPink.opacity(scanner.unboundMode ? 0.5 : 0.22), lineWidth: 1))
        .cornerRadius(scanner.unboundMode ? 14 : 7)
    }

    private func navButton(id: String, icon: String, title: String, sub: String) -> some View {
        let active = (scanner.selectedTab == id)
        return Button(action: { scanner.selectedTab = id }) {
            HStack(spacing: 10) {
                Text(icon).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(active ? cCyan : .white)
                    Text(sub)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(active ? bgElevated : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? cCyan.opacity(0.45) : Color.clear, lineWidth: 1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func triadMiniCard(glyph: String, name: String, sub: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(glyph)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .frame(width: 44, height: 24)
                .background(color.opacity(0.18))
                .foregroundColor(color)
                .cornerRadius(6)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(sub)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(6)
        .background(bgElevated.opacity(0.65))
        .overlay(RoundedRectangle(cornerRadius: scanner.unboundMode ? 16 : 7).stroke(color.opacity(scanner.unboundMode ? 0.55 : 0.28), lineWidth: 1))
        .cornerRadius(scanner.unboundMode ? 16 : 7)
    }

    private func beaconRowCard(ap: ScannedAP, isSelected: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(ap.uiType)
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
                Text(String(format: "%@ · Ch %d · %.0fm · Trit %@", ap.bssid, ap.channel, ap.distanceMeters, ap.tritLabel))
                    .font(.system(size: 9, design: .monospaced).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(ap.rssi) dBm")
                .font(.system(size: 11, weight: .bold, design: .monospaced).monospacedDigit())
                .foregroundColor(ap.rssi > -68 ? cGreen : (ap.rssi > -82 ? cGold : cTritNeg))
        }
        .padding(8)
        .background(isSelected ? bgElevated : Color.white.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: scanner.unboundMode ? 15 : 7).stroke(isSelected ? cCyan.opacity(0.55) : cPink.opacity(scanner.unboundMode ? 0.38 : 0.14), lineWidth: 1))
        .cornerRadius(scanner.unboundMode ? 15 : 7)
    }

    private func dashCard(title: String, main: String, sub: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(accent)
            Text(main)
                .font(.system(size: 14, weight: .bold, design: .monospaced).monospacedDigit())
                .foregroundColor(.white)
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 10, design: .monospaced).monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bgPanel)
        .overlay(RoundedRectangle(cornerRadius: scanner.unboundMode ? 22 : 10).stroke(cPink.opacity(scanner.unboundMode ? 0.52 : 0.22), lineWidth: 1))
        .cornerRadius(scanner.unboundMode ? 22 : 10)
    }

    private func ternaryDistributionBar(pos: Int, zero: Int, neg: Int) -> some View {
        let tot = max(1, pos + zero + neg)
        return GeometryReader { geo in
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(cGreen)
                    .frame(width: max(4, geo.size.width * CGFloat(pos) / CGFloat(tot)))
                RoundedRectangle(cornerRadius: 2)
                    .fill(cGold)
                    .frame(width: max(4, geo.size.width * CGFloat(zero) / CGFloat(tot)))
                RoundedRectangle(cornerRadius: 2)
                    .fill(cTritNeg)
                    .frame(width: max(4, geo.size.width * CGFloat(neg) / CGFloat(tot)))
            }
        }
        .frame(height: 6)
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
                let barColor = (c >= 4) ? cTritNeg : (ch == 37 ? cPink : (ch > 14 ? cCyan : cGreen))
                VStack(spacing: 4) {
                    Text("\(c)")
                        .font(.system(size: 9, design: .monospaced).monospacedDigit())
                        .foregroundColor(.secondary)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor)
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

    private func colorForTrit(_ trit: Int) -> Color {
        switch trit {
        case 1: return cGreen
        case 0: return cGold
        default: return cTritNeg
        }
    }

    private func exportCSVToDesktop() {
        let snap = scanner.telemetry ?? scanner.performScan()
        let ts = Int(Date().timeIntervalSince1970)
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let targetURL = desktop.appendingPathComponent("wigle-macos-\(ts).csv")
        do {
            try scanner.buildWigleCSV(from: snap).write(to: targetURL, atomically: true, encoding: .utf8)
            scanner.statusText = "Exported WigleWifi-1.4 CSV -> ~/Desktop/wigle-macos-\(ts).csv"
        } catch {
            saveCSVDialog()
        }
    }

    private func saveCSVDialog() {
        if let snap = scanner.telemetry {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "wigle-macos-\(Int(Date().timeIntervalSince1970)).csv"
            if panel.runModal() == .OK, let url = panel.url {
                try? scanner.buildWigleCSV(from: snap).write(to: url, atomically: true, encoding: .utf8)
                scanner.statusText = "Saved WigleWifi-1.4 CSV -> \(url.lastPathComponent)"
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
        window.title = "WigleMac v2.0.0 — 8b-is ROCKS AND HEALS THE WORLD · WiGLE Radar · Chiro-chan ^^ · Lacrimosa · Boldog Még"
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
} else if args.contains("--qmom") {
    print("# QMOM|ALEX|qMom:{`\(kQMomTransmission)`}")
    exit(0)
} else if args.contains("--boldog") {
    print("# BOLDOG|(Boldog Meg)===\(kHyperCharmKarma)\n\(kBoldogMegLyrics)")
    exit(0)
} else if args.contains("--lacrimosa") || args.contains("--chiro") {
    print("# CHIRO|Kawaii Chiro-chan kawaii ^^")
    print("# LACRIMOSA|\(kChiroChanRequiem) +++ \(kHyperCharmKarma)")
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
