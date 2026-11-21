// swift-tools-version: 6.0
import PackageDescription

// Build with the Xcode toolchain and Xcode's own SDK (see scripts/env.sh): on this machine the
// Command Line Tools' SwiftPM fails to start its build system, and xcrun otherwise pairs Xcode's
// clang with the CLT SDK.
let package = Package(
    name: "Fidelis",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Fidelis", targets: ["FidelisApp"]),
    ],
    targets: [
        // Sony's LDAC encoder (AOSP, Apache-2.0). Only the two unity translation units are
        // compiled, as in its Android.bp; they #include the rest.
        .target(
            name: "CLDAC",
            path: "third_party/libldac",
            sources: ["src/ldaclib.c", "src/ldacBT.c"],
            publicHeadersPath: "inc",
            cSettings: [.unsafeFlags(["-w", "-O2"])]
        ),
        // Its adaptive bitrate (libldac/abr), what Android's LDAC "best effort" runs.
        .target(
            name: "CLDACABR",
            dependencies: ["CLDAC"],
            path: "Sources/CLDACABR",
            cSettings: [.unsafeFlags(["-w", "-O2", "-I", Context.packageDirectory + "/third_party/libldac/abr/inc"])]
        ),
        // Every private Bluetooth entry point lives here and nowhere else.
        .target(
            name: "FidelisBluetooth",
            path: "Sources/FidelisBluetooth",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
            ]
        ),
        // Opens the AVDTP media channel from a second bluetoothd client session. Needs its own
        // identity, so it carries an embedded Info.plist and is signed separately.
        .executableTarget(
            name: "FidelisMediaHelper",
            dependencies: ["FidelisBluetooth"],
            path: "Sources/FidelisMediaHelper",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", Context.packageDirectory + "/Resources/MediaHelper-Info.plist",
            ])]
        ),
        .target(
            name: "FidelisCore",
            dependencies: ["FidelisBluetooth", "CLDAC", "CLDACABR"],
            path: "Sources/FidelisCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FidelisApp",
            dependencies: ["FidelisCore"],
            path: "Sources/FidelisApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FidelisCoreTests",
            dependencies: ["FidelisCore"],
            path: "Tests/FidelisCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
