// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "neo-md",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "neo-md", targets: ["NeoMD"]),
        .executable(name: "NeoMDQuickLook", targets: ["NeoMDQuickLook"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-cmark.git",
            revision: "0c8947bbd58c491c54aae114aca40621cddc8357"
        ),
    ],
    targets: [
        .target(
            name: "MDCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        .executableTarget(
            name: "NeoMD",
            dependencies: ["MDCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
            ]
        ),
        .executableTarget(
            name: "NeoMDQuickLook",
            dependencies: ["MDCore"],
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        .testTarget(
            name: "MDCoreTests",
            dependencies: ["MDCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
