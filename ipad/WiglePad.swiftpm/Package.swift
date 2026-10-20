// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "WiglePad",
    platforms: [
        .iOS("17.0"),
        .macOS("14.0")
    ],
    products: [
        .iOSApplication(
            name: "WiglePad",
            targets: ["WiglePadApp"],
            bundleIdentifier: "is.eightb.wiglepad",
            teamIdentifier: "8BISLOVE",
            displayVersion: "2.0.0",
            bundleVersion: "200",
            appIcon: .placeholder(icon: .antenna),
            accentColor: .presetColor(.pink),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown
            ],
            capabilities: [
                .bluetoothAlways(purposeString: "WiglePad scans passive BLE advertisements for the 8b-is Sovereign Spectrum Radar."),
                .localNetwork(purposeString: "WiglePad discovers AirPlay/RAOP mDNS endpoints on your local network.", bonjourServiceTypes: ["_airplay._tcp", "_raop._tcp", "_companion-link._tcp"]),
                .outgoingNetworkConnections()
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "WiglePadApp",
            path: "."
        )
    ]
)
