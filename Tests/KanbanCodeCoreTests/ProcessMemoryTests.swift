import Testing
import Foundation
@testable import KanbanCodeCore
#if canImport(Glibc)
import Glibc
#endif

@Suite("Process memory", .serialized)
struct ProcessMemoryTests {

    #if canImport(Glibc)
    @Test("Multi-megabyte buffers freed on many threads do not stay in the arenas")
    func bigBuffersLeaveTheArenas() async throws {
        #expect(ProcessMemory.tune())
        ProcessMemory.trim()
        let before = try #require(ProcessMemory.snapshot())

        // The shape of a reconcile or a remote response: a few MiB decoded or
        // encoded on whichever pool thread runs it, then dropped, while small
        // objects made meanwhile stay alive and pin the arena's free space.
        let kept = await withTaskGroup(of: [UInt].self) { group in
            for worker in 0..<16 {
                group.addTask {
                    var small: [UInt] = []
                    for round in 0..<200 {
                        let size = (2 + (worker + round) % 7) * 1024 * 1024
                        let block = malloc(size)!
                        memset(block, 0x5a, size)
                        small.append(UInt(bitPattern: malloc(200 + (round * 37) % 3000)))
                        free(block)
                    }
                    return small
                }
            }
            return await group.reduce(into: [UInt]()) { $0 += $1 }
        }
        defer { for address in kept { free(UnsafeMutableRawPointer(bitPattern: address)) } }

        let after = try #require(ProcessMemory.snapshot())
        // Untuned, glibc raises the mmap threshold past these sizes and every
        // arena keeps the freed blocks: hundreds of MiB here.
        #expect(after.arenaBytes - before.arenaBytes < 32 * 1024 * 1024)
    }

    @Test("A snapshot reports the resident size and the heap")
    func snapshotReadsTheProcess() throws {
        let snap = try #require(ProcessMemory.snapshot())
        #expect(snap.residentBytes > 0)
        #expect(snap.heapInUseBytes > 0)
        #expect(snap.summary.hasPrefix("rss "))
    }
    #endif
}
