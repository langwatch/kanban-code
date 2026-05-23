import Foundation
import KanbanCodeCore
import QuartzCore
import SwiftUI
import os

/// Thresholded diagnostics for expensive main-actor view construction and UI load work.
///
/// SwiftUI does not expose a stable callback for "this component finished rendering".
/// Measuring body/computed-view construction still gives the log a useful breadcrumb
/// when SwiftUI is spending too long building a screen before layout can proceed.
enum RenderDiagnostics {
    private static let minLogInterval: TimeInterval = 2
    private static let lastLogTime = OSAllocatedUnfairLock(initialState: [String: CFTimeInterval]())

    static func measure<Value>(
        _ scope: String,
        thresholdMs: Double = 16,
        metadata: @autoclosure () -> String = "",
        _ body: () -> Value
    ) -> Value {
        let start = CACurrentMediaTime()
        defer {
            logIfSlow(
                scope,
                elapsedMs: (CACurrentMediaTime() - start) * 1_000,
                thresholdMs: thresholdMs,
                metadata: metadata()
            )
        }
        return body()
    }

    static func measureView<Content: View>(
        _ scope: String,
        thresholdMs: Double = 16,
        metadata: @autoclosure () -> String = "",
        @ViewBuilder _ body: () -> Content
    ) -> Content {
        let start = CACurrentMediaTime()
        let content = body()
        logIfSlow(
            scope,
            elapsedMs: (CACurrentMediaTime() - start) * 1_000,
            thresholdMs: thresholdMs,
            metadata: metadata()
        )
        return content
    }

    static func mark() -> CFTimeInterval {
        CACurrentMediaTime()
    }

    static func logIfSlow(
        _ scope: String,
        since start: CFTimeInterval,
        thresholdMs: Double,
        metadata: @autoclosure () -> String = ""
    ) {
        logIfSlow(
            scope,
            elapsedMs: (CACurrentMediaTime() - start) * 1_000,
            thresholdMs: thresholdMs,
            metadata: metadata()
        )
    }

    private static func logIfSlow(
        _ scope: String,
        elapsedMs: Double,
        thresholdMs: Double,
        metadata: String
    ) {
        guard elapsedMs >= thresholdMs else { return }

        let now = CACurrentMediaTime()
        let shouldLog = lastLogTime.withLock { times -> Bool in
            guard now - (times[scope] ?? 0) >= minLogInterval else { return false }
            times[scope] = now
            return true
        }
        guard shouldLog else { return }

        let detail = metadata.isEmpty ? "" : " \(metadata)"
        KanbanCodeLog.warn(
            "ui-slow",
            String(format: "%@ %.1fms%@", scope, elapsedMs, detail)
        )
    }
}
