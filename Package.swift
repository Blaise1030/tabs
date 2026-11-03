// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.macOS(.v14)],
    dependencies: [
        // A terminal emulator, for tabsh's sessions as native tabs: the one
        // piece of the browser that is not Apple's. See TabshTerminal.swift.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.99.0")
    ],
    targets: [
        .executableTarget(
            name: "Search",
            dependencies: ["SwiftTerm"],
            path: "Sources/Search",
            // The typing packs, sampled from the same MIT-licensed kbsim and
            // Mechvibes sets tabsh uses (see Sounds/*/LICENSE).
            resources: [.copy("Sounds")],
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // tabsctl: the separate CLI an agent in a session runs to create a
        // sibling session (see Sources/TabsCLI/main.swift). It cannot import
        // the Search executable, so its socket protocol is duplicated there
        // by design and pinned by TabsctlContractTests.
        .executableTarget(
            name: "TabsCLI",
            path: "Sources/TabsCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search"],
            path: "Tests/SearchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
