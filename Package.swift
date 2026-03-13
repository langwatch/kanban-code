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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/PostHog/posthog-ios", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "KanbanCode",
            dependencies: ["KanbanCodeCore", "SwiftTerm", .product(name: "MarkdownUI", package: "swift-markdown-ui"), .product(name: "PostHog", package: "posthog-ios")],
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
            dependencies: ["KanbanCodeCore"],
            path: "Tests/KanbanCodeCoreTests"
        ),
        .testTarget(
            name: "KanbanCodeTests",
            dependencies: ["KanbanCode", "KanbanCodeCore"],
            path: "Tests/KanbanCodeTests"
        ),
    ]
)
