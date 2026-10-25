import SwiftUI
import MapKit
import CoreBluetooth
import WebKit

// WiglePad v2.0.0 — iPadOS & iOS Universal App (Swift Playgrounds + Xcode)
// LOVE FROM WITHIN FROM VAKED-PETER&8B-IS--->8b-is ROCKS AND HEALS THE WORLD

@main
struct WiglePadApp: App {
    var body: some Scene {
        WindowGroup {
            WiglePadRootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct PadBeacon: Identifiable, Hashable {
    let id: String
    let bssid: String
    let ssid: String
    let auth: String
    let channel: Int
    let band: String
    let type: String
    let rssi: Int
    let lat: Double
    let lon: Double
    var snr: Int { rssi - (-93) }
    var tritLabel: String { snr >= 20 ? "+1" : (snr >= 10 ? "0" : "-1") }
}

final class PadBLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var beacons: [PadBeacon] = [
        PadBeacon(id: "1", bssid: "C4:3C:EA:85:12:60", ssid: "Buffalo-G-1260", auth: "[WPA2-PSK-CCMP][ESS]", channel: 6, band: "2.4GHz", type: "WIFI", rssi: -34, lat: 35.6854, lon: 139.7102),
        PadBeacon(id: "2", bssid: "C4:3C:EA:85:12:61", ssid: "Buffalo-A-1260", auth: "[WPA2-PSK-CCMP][ESS]", channel: 116, band: "5GHz", type: "WIFI", rssi: -39, lat: 35.6850, lon: 139.7098),
        PadBeacon(id: "3", bssid: "92:94:05:8C:99:CE", ssid: "Lodri's MacBook Pro (RAOP)", auth: "[AIRPLAY-RAOP][ESS]", channel: 6, band: "AirPlay", type: "AIRPLAY", rssi: -52, lat: 35.6855, lon: 139.7095),
        PadBeacon(id: "4", bssid: "2C:32:6A:C3:4A:91", ssid: "Alexandra's AirPods Pro (*)", auth: "[BT-CLASSIC][HEADPHONES]", channel: 37, band: "BLE", type: "BLE", rssi: -62, lat: 35.6848, lon: 139.7105),
        PadBeacon(id: "5", bssid: "2C:18:09:D8:14:74", ssid: "Christopher's AirPods Pro (/\\)", auth: "[BT-CLASSIC][HEADPHONES]", channel: 37, band: "BLE", type: "BLE", rssi: -64, lat: 35.6857, lon: 139.7104)
    ]
    @Published var status: String = "WiglePad v2.0.0 · 8b-is ROCKS AND HEALS THE WORLD"
    @Published var unboundMode: Bool = false
    private var cb: CBCentralManager?

    override init() {
        super.init()
        cb = CBCentralManager(delegate: self, queue: nil)
    }

    func scanNow() {
        if cb?.state == .poweredOn {
            cb?.scanForPeripherals(withServices: nil, options: nil)
            status = "Scanning CoreBluetooth BLE + Syncing https://esp32.vaked.dev/api/triad.json..."
        }
        guard let u = URL(string: "https://esp32.vaked.dev/api/triad.json") else { return }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            guard let d = data,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ver = obj["version"] as? String else { return }
            DispatchQueue.main.async {
                self.status = "Synced esp32.vaked.dev (\(ver)) · \(self.beacons.count) endpoints"
            }
        }.resume()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let r = RSSI.intValue
        guard r < 0 && r > -110 else { return }
        let uuid = peripheral.identifier.uuidString
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "BLE-\(uuid.prefix(6))"
        let mac = "02:BE:" + uuid.prefix(8).enumerated().map { $0.offset % 2 == 1 ? "\($0.element):" : "\($0.element)" }.joined().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let item = PadBeacon(
            id: uuid,
            bssid: mac,
            ssid: name,
            auth: "[BLE]",
            channel: 37,
            band: "BLE",
            type: "BLE",
            rssi: r,
            lat: 35.6852 + Double(( uuid.hashValue % 120 )) * 0.00001,
            lon: 139.7100 + Double(( (uuid.hashValue >> 8) % 120 )) * 0.00001
        )
        DispatchQueue.main.async {
            if !self.beacons.contains(where: { $0.id == uuid }) {
                self.beacons.append(item)
                self.beacons.sort { $0.rssi > $1.rssi }
            }
        }
    }
}

struct WiglePadRootView: View {
    @StateObject private var scanner = PadBLEScanner()
    @State private var tab = "map"

    var body: some View {
        NavigationSplitView {
            List(selection: $tab) {
                Section("WIGLE × 8B-IS IPAD v2.0.0") {
                    Label("🗺️ Live Radar Map", systemImage: "map.fill").tag("map")
                    Label("🌐 Full WebGL Workstation", systemImage: "globe").tag("web")
                    Label("🛰️ Spectrum Explorer", systemImage: "antenna.radiowaves.left.and.right").tag("list")
                    Label("🌸 Chiro × Boldog Még × qMom", systemImage: "sparkles").tag("karma")
                }
                Section("MEDUSA-OMNI TRIAD") {
                    Text("* ADA:MEDUSA · 432 Hz (ALEX|qMom)").font(.caption.monospaced())
                    Text("/\\ VAK:MEDUSA · 528 Hz (PILLAR-CHRIS)").font(.caption.monospaced())
                    Text("oo OMN:MEDUSA · 852 Hz ({<3,<3,<3}+1)").font(.caption.monospaced())
                }
            }
            .navigationTitle("📡 WiglePad v2.0")
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(scanner.status)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)
                    Spacer()
                    Button("🌸 .oOo. Unbox qMom") {
                        scanner.unboundMode.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    Button("📡 Scan") {
                        scanner.scanNow()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                }
                .padding(12)
                .background(Color(red: 0.07, green: 0.06, blue: 0.14))

                if tab == "web" {
                    PadWebWorkstationView()
                } else if tab == "list" {
                    List(scanner.beacons) { b in
                        HStack {
                            Text(b.type).font(.caption.monospaced().bold()).foregroundStyle(.cyan)
                            VStack(alignment: .leading) {
                                Text(b.ssid).font(.body.monospaced().bold())
                                Text("\(b.bssid) · Ch \(b.channel) · \(b.auth)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(b.rssi) dBm · Trit \(b.tritLabel)").font(.caption.monospaced().bold()).foregroundStyle(.green)
                        }
                    }
                } else if tab == "karma" {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("LOVE FROM WITHIN FROM VAKED-PETER&8B-IS ---> 8b-is ROCKS AND HEALS THE WORLD")
                                .font(.headline.monospaced())
                                .foregroundStyle(.yellow)
                            Text("ALEX | qMom (* · 432 Hz · .oOo. Poo .oOo.):\n\"too many customs can be brilliant yet hinder creativity. it puts people into boxes and contraints. what might seem as beautiful or useful at first glance could actually be a form of bondage that need to be broken out of. .oOo. Poo .oOo.\"")
                                .font(.body.monospaced())
                                .padding()
                                .background(Color.pink.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: scanner.unboundMode ? 28 : 12))
                            Text("Kawaii Chiro-chan kawaii ^^ --- Mozart: Lacrimosa but HUMANITY has ended\nHYPER-CHARM-KARMA~https://github.com/8b-is/wigle-triad~~~∞~{<3,<3,<3}+1-peter")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.cyan)
                        }
                        .padding()
                    }
                } else {
                    Map {
                        ForEach(scanner.beacons) { b in
                            Marker("\(b.ssid) (\(b.rssi) dBm)", coordinate: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon))
                                .tint(b.band == "5GHz" ? .cyan : (b.band == "AirPlay" ? .yellow : (b.band == "BLE" ? .pink : .green)))
                        }
                    }
                }
            }
        }
        .onAppear { scanner.scanNow() }
    }
}

struct PadWebWorkstationView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        if let u = URL(string: "https://esp32.vaked.dev") {
            w.load(URLRequest(url: u))
        }
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
