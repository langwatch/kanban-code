import Foundation
#if canImport(Glibc)
import Glibc
import CMalloc
#endif

/// Keeps a long-running Linux process's resident memory close to its live heap.
///
/// glibc gives each thread that contends for malloc its own arena (up to eight
/// per core) and raises the mmap threshold to the size of the largest block
/// freed, up to 32 MiB. The server decodes and encodes multi-megabyte JSON
/// (links.json, tombstones, remote responses) on whichever pool thread runs the
/// task, so every arena grows to its own high-water mark and keeps it: the live
/// heap stays under 1 GiB while the arenas hold tens of GiB of freed blocks.
/// `tune()` caps the arenas and fixes the mmap threshold, so big buffers are
/// mapped and unmapped on their own; `trim()` hands free arena pages back.
public enum ProcessMemory {
    public static let arenaMax: Int32 = 4
    public static let mmapThreshold: Int32 = 512 * 1024
    public static let trimThreshold: Int32 = 16 * 1024 * 1024

    public struct Snapshot: Sendable, Equatable {
        /// Resident set size of the process.
        public var residentBytes: Int
        /// Bytes malloc has handed out and not yet had back.
        public var heapInUseBytes: Int
        /// Bytes the arenas hold from the system, in use or free.
        public var arenaBytes: Int
        /// Bytes in blocks malloc mapped on their own.
        public var mappedBytes: Int

        public var summary: String {
            func mib(_ bytes: Int) -> String { "\(bytes / (1024 * 1024)) MiB" }
            return "rss \(mib(residentBytes)), heap in use \(mib(heapInUseBytes)), arenas \(mib(arenaBytes)), mapped \(mib(mappedBytes))"
        }
    }

    /// Applies the malloc settings. Call it first thing in `main`, before the
    /// process starts threads. Returns false where glibc refused or is absent.
    @discardableResult
    public static func tune() -> Bool {
        #if canImport(Glibc)
        let arenas = mallopt(M_ARENA_MAX, arenaMax)
        // Setting either threshold explicitly also turns off glibc's dynamic
        // adjustment of both.
        let mmap = mallopt(M_MMAP_THRESHOLD, mmapThreshold)
        let trim = mallopt(M_TRIM_THRESHOLD, trimThreshold)
        return arenas == 1 && mmap == 1 && trim == 1
        #else
        return false
        #endif
    }

    /// Returns the free pages of every arena to the system.
    public static func trim() {
        #if canImport(Glibc)
        _ = malloc_trim(0)
        #endif
    }

    public static func snapshot() -> Snapshot? {
        #if canImport(Glibc)
        let info = mallinfo2()
        return Snapshot(
            residentBytes: residentBytes() ?? 0,
            heapInUseBytes: Int(info.uordblks) + Int(info.hblkhd),
            arenaBytes: Int(info.arena),
            mappedBytes: Int(info.hblkhd)
        )
        #else
        return nil
        #endif
    }

    /// Resident set size from /proc/self/statm.
    public static func residentBytes() -> Int? {
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return nil }
        let fields = text.split(separator: " ")
        guard fields.count > 1, let pages = Int(fields[1]) else { return nil }
        return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
    }

    /// Trims every `trimEvery` and logs a snapshot every `logEvery`, until cancelled.
    public static func runMaintenance(trimEvery: Duration = .seconds(60), logEvery: Duration = .seconds(600)) async {
        var sinceLog = Duration.zero
        if let first = snapshot() { KanbanCodeLog.info("memory", first.summary) }
        while !Task.isCancelled {
            try? await Task.sleep(for: trimEvery)
            guard !Task.isCancelled else { break }
            trim()
            sinceLog += trimEvery
            if sinceLog >= logEvery, let now = snapshot() {
                sinceLog = .zero
                KanbanCodeLog.info("memory", now.summary)
            }
        }
    }
}
