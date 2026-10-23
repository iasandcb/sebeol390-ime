// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sebeol390",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Sebeol390", targets: ["Sebeol390IME"]),
    ],
    targets: [
        .target(name: "Sebeol390Core"),
        .executableTarget(
            name: "Sebeol390IME",
            dependencies: ["Sebeol390Core"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "Sebeol390CoreTests",
            dependencies: ["Sebeol390Core"],
            swiftSettings: [
                // Command Line Tools keep TestingMacros out of the default
                // plugin path, so `swift test` cannot see @Test / #expect.
                .unsafeFlags([
                    "-load-plugin-library",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib",
                ]),
            ]
        ),
    ]
)
