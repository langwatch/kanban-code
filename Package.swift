// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KanbanCode",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "KanbanCode", targets: ["KanbanCode"]),
        .executable(name: "kanban-code-active-session", targets: ["KanbanCodeActiveSession"]),
        .library(name: "KanbanCodeCore", targets: ["KanbanCodeCore"]),
    ],
    dependencies: [
        .package(path: "LocalPackages/SwiftTerm"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/swiftlang/swift-testing", from: "0.15.0"),
    ],
    targets: [
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
        .target(
            name: "KanbanCodeCore",
            path: "Sources/KanbanCodeCore"
        ),
        .testTarget(
            name: "KanbanCodeCoreTests",
            dependencies: ["KanbanCodeCore", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/KanbanCodeCoreTests"
        ),
        .testTarget(
            name: "KanbanCodeTests",
            dependencies: ["KanbanCode", "KanbanCodeCore", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/KanbanCodeTests"
        ),
    ]
)
