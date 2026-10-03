// swift-tools-version: 6.2
import PackageDescription

// macOS builds the app, its helpers and the iOS wire types. Linux builds only
// the headless side: Core, the remote API wire types, the demo server and
// kanban-code-server, with swift-crypto standing in for CryptoKit and the
// system zlib for the Compression framework.
#if os(Linux)
let linuxOnly = true
#else
let linuxOnly = false
#endif

var products: [Product] = [
    .executable(name: "kanban-code-remote-demo", targets: ["KanbanCodeRemoteDemo"]),
    .executable(name: "kanban-code-server", targets: ["KanbanCodeServer"]),
    .executable(name: "kanban-code-export", targets: ["KanbanCodeExport"]),
    .library(name: "KanbanCodeCore", targets: ["KanbanCodeCore"]),
    .library(name: "KanbanCodeRemoteKit", targets: ["KanbanCodeRemoteKit"]),
]

var dependencies: [Package.Dependency] = []

var coreDependencies: [Target.Dependency] = ["KanbanCodeRemoteKit"]
var remoteKitDependencies: [Target.Dependency] = []

var targets: [Target] = [
    // Development server for the remote control clients: the real server over a fake board.
    .executableTarget(
        name: "KanbanCodeRemoteDemo",
        dependencies: ["KanbanCodeCore", "KanbanCodeRemoteKit"],
        path: "Sources/KanbanCodeRemoteDemo"
    ),
    // Headless master: the remote control API over ~/.kanban-code, for Linux hosts.
    .executableTarget(
        name: "KanbanCodeServer",
        dependencies: ["KanbanCodeCore", "KanbanCodeRemoteKit"],
        path: "Sources/KanbanCodeServer"
    ),
    // Prints a session as the app's Markdown export, for `kanban export`.
    .executableTarget(
        name: "KanbanCodeExport",
        dependencies: ["KanbanCodeCore"],
        path: "Sources/KanbanCodeExport"
    ),
    .testTarget(
        name: "KanbanCodeRemoteKitTests",
        dependencies: ["KanbanCodeRemoteKit"],
        path: "Tests/KanbanCodeRemoteKitTests"
    ),
    .testTarget(
        name: "KanbanCodeCoreTests",
        dependencies: ["KanbanCodeCore"],
        path: "Tests/KanbanCodeCoreTests"
    ),
]

if linuxOnly {
    dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
    coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    remoteKitDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    coreDependencies.append("CZlib")
    targets.append(.systemLibrary(name: "CZlib", path: "Sources/CZlib"))
} else {
    products.insert(contentsOf: [
        .executable(name: "KanbanCode", targets: ["KanbanCode"]),
        .executable(name: "kanban-code-active-session", targets: ["KanbanCodeActiveSession"]),
    ], at: 0)
    dependencies.append(contentsOf: [
        .package(path: "LocalPackages/SwiftTerm"),
        // Vendored fork: see LocalPackages/swift-markdown-ui/FORK.md
        .package(path: "LocalPackages/swift-markdown-ui"),
    ])
    targets.append(contentsOf: [
        .executableTarget(
            name: "KanbanCode",
            dependencies: ["KanbanCodeCore", "SwiftTerm", .product(name: "MarkdownUI", package: "swift-markdown-ui")],
            path: "Sources/KanbanCode",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "KanbanCodeActiveSession",
            path: "Sources/KanbanCodeActiveSession"
        ),
        .testTarget(
            name: "KanbanCodeTests",
            dependencies: ["KanbanCode", "KanbanCodeCore"],
            path: "Tests/KanbanCodeTests"
        ),
    ])
}

// Wire types of the remote control API and the vault's owner-key crypto,
// shared with the iOS app.
targets.append(
    .target(
        name: "KanbanCodeRemoteKit",
        dependencies: remoteKitDependencies,
        path: "Sources/KanbanCodeRemoteKit"
    )
)

targets.append(
    .target(
        name: "KanbanCodeCore",
        dependencies: coreDependencies,
        path: "Sources/KanbanCodeCore"
    )
)

let package = Package(
    name: "KanbanCode",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
