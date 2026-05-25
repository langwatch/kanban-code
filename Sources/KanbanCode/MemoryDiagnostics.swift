import Darwin
import Foundation
import KanbanCodeCore
import os

/// Lightweight process memory logging for diagnosing leaks after the fact.
///
/// Logs to the normal Kanban Code log when footprint grows meaningfully or
/// crosses a high-water threshold. Disable with `KANBAN_MEMORY_DIAGNOSTICS=0`.
final class MemoryDiagnostics: @unchecked Sendable {
    static let shared = MemoryDiagnostics()

    private struct Snapshot {
        let resident: UInt64
        let footprint: UInt64
        let virtualSize: UInt64
    }

    private let isRunning = OSAllocatedUnfairLock(initialState: false)
    private let checkInterval: TimeInterval = 10
    private let periodicInterval: TimeInterval = 60
    private let growthThreshold: UInt64 = 256 * 1024 * 1024
    private let warningThreshold: UInt64 = 1_024 * 1024 * 1024
    private let criticalThreshold: UInt64 = 4 * 1_024 * 1024 * 1024

    private var lastLoggedAt = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private var lastLoggedFootprint = OSAllocatedUnfairLock(initialState: UInt64(0))

    private init() {}

    func start() {
        guard ProcessInfo.processInfo.environment["KANBAN_MEMORY_DIAGNOSTICS"] != "0" else { return }

        let alreadyRunning = isRunning.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else { return }

        if let snapshot = Self.currentSnapshot() {
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
            log(snapshot, reason: "start")
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while self.isRunning.withLock({ $0 }) {
                Thread.sleep(forTimeInterval: self.checkInterval)
                guard let snapshot = Self.currentSnapshot() else { continue }
                self.logIfNeeded(snapshot)
            }
        }
    }

    func stop() {
        isRunning.withLock { $0 = false }
    }

    private func logIfNeeded(_ snapshot: Snapshot) {
        let previous = lastLoggedFootprint.withLock { $0 }
        let growth = snapshot.footprint > previous ? snapshot.footprint - previous : 0

        let now = Date()
        let periodic = lastLoggedAt.withLock { last -> Bool in
            guard now.timeIntervalSince(last) >= periodicInterval else { return false }
            last = now
            return true
        }

        if snapshot.footprint >= criticalThreshold {
            log(snapshot, reason: "critical")
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
        } else if snapshot.footprint >= warningThreshold, growth >= growthThreshold {
            log(snapshot, reason: "growth")
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
        } else if periodic {
            log(snapshot, reason: "periodic")
            lastLoggedFootprint.withLock { $0 = snapshot.footprint }
        }
    }

    private func log(_ snapshot: Snapshot, reason: String) {
        KanbanCodeLog.info(
            "memory",
            "reason=\(reason) footprint=\(Self.format(snapshot.footprint)) rss=\(Self.format(snapshot.resident)) virtual=\(Self.format(snapshot.virtualSize))"
        )
    }

    private static func currentSnapshot() -> Snapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Snapshot(
            resident: UInt64(info.resident_size),
            footprint: UInt64(info.phys_footprint),
            virtualSize: UInt64(info.virtual_size)
        )
    }

    private static func format(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / 1024 / 1024
        if mib >= 1024 {
            return String(format: "%.2fGiB", mib / 1024)
        }
        return String(format: "%.0fMiB", mib)
    }
}
