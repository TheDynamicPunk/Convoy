// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Convoy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Convoy", targets: ["Convoy"]),
        .library(name: "DownloadEngine", targets: ["DownloadEngine"]),
        .executable(name: "NativeMessagingHost", targets: ["NativeMessagingHost"]),
        .executable(name: "helper-manifest", targets: ["HelperManifestTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // No `resources:` here on purpose. It used to declare
        // .process("Resources"), but Sources/Convoy/Resources has never
        // existed, so every build printed "Invalid Resource 'Resources': File
        // not found" and nothing used the Bundle.module it would have
        // generated. This app's resources -- icons, Info.plist, the signed
        // helper list -- are placed into Contents/Resources by build.sh, which
        // is what assembles the .app bundle in the first place.
        .executableTarget(
            name: "Convoy",
            dependencies: [
                "DownloadEngine",
                "IPCKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // build.sh copies Sparkle.framework into Contents/Frameworks.
            // SwiftPM's own rpath only covers the build directory.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .target(
            name: "DownloadEngine",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "IPCKit",
            dependencies: []
        ),
        .executableTarget(
            name: "NativeMessagingHost",
            dependencies: ["IPCKit"]
        ),
        // Maintainer-side only: builds and signs the helper list that
        // HelperManifestStore verifies downloads against. Never copied into
        // the app bundle -- build.sh ships only Convoy and
        // NativeMessagingHost.
        .executableTarget(
            name: "HelperManifestTool",
            dependencies: ["DownloadEngine"]
        ),
        .testTarget(
            name: "DownloadEngineTests",
            dependencies: ["DownloadEngine"]
        ),
        .testTarget(
            name: "ConvoyTests",
            dependencies: ["Convoy"]
        ),
    ]
)
