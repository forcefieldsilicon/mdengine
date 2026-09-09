//
//  FieldCache.swift — LRU of tool results, bounded by BYTES.
//
//  Per-atom fields are what actually consume memory (4 bytes × N × frames), so
//  a frame-count cache says nothing useful: 8 frames of 10 k atoms is 320 kB,
//  8 frames of 20 M atoms is 640 MB. Hence a byte ceiling.
//

import Foundation

public struct FieldCacheKey: Hashable {
    public let toolId: String
    public let paramsHash: Int
    public let frameIndex: Int
    public let referenceFrameIndex: Int?
    public init(toolId: String, paramsHash: Int, frameIndex: Int, referenceFrameIndex: Int? = nil) {
        self.toolId = toolId
        self.paramsHash = paramsHash
        self.frameIndex = frameIndex
        self.referenceFrameIndex = referenceFrameIndex
    }
}

public final class FieldCache: @unchecked Sendable {
    public static let defaultLimit = 256 * 1024 * 1024   // 256 MB

    private struct Entry { let result: ToolResult; let bytes: Int; var lastUsed: UInt64 }
    private let lock = NSLock()
    private var entries: [FieldCacheKey: Entry] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private var limit: Int

    public init(byteLimit: Int = FieldCache.defaultLimit) { limit = max(0, byteLimit) }

    public var currentBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    public var byteLimit: Int { lock.lock(); defer { lock.unlock() }; return limit }

    public func value(for key: FieldCacheKey) -> ToolResult? {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[key] else { return nil }
        clock += 1
        e.lastUsed = clock
        entries[key] = e
        return e.result
    }

    public func insert(_ result: ToolResult, for key: FieldCacheKey) {
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { bytes -= old.bytes }
        let size = result.estimatedBytes
        // A single result larger than the whole budget is not worth evicting
        // everything for; recompute it next time instead.
        guard size <= limit else { evictLocked(toBytes: limit); return }
        clock += 1
        entries[key] = Entry(result: result, bytes: size, lastUsed: clock)
        bytes += size
        evictLocked(toBytes: limit)
    }

    /// Drop least-recently-used entries until at most `toBytes` remain.
    /// Also the memory-pressure hook: `evict(toBytes: 0)` == `removeAll()`.
    public func evict(toBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        evictLocked(toBytes: max(0, toBytes))
    }

    public func setByteLimit(_ newLimit: Int) {
        lock.lock(); defer { lock.unlock() }
        limit = max(0, newLimit)
        evictLocked(toBytes: limit)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        bytes = 0
    }

    private func evictLocked(toBytes target: Int) {
        guard bytes > target else { return }
        for (key, entry) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            guard bytes > target else { break }
            entries.removeValue(forKey: key)
            bytes -= entry.bytes
        }
    }
}
