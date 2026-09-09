//
//  AnalysisScheduler.swift — LAMMPSCore
//
//  The one door every analysis goes through (design §1b, GJOB-133).
//
//  Why: the inspector used to run ZProfileAnalysis inside its SwiftUI body,
//  so an O(N log N) pass over every atom ran on the main thread on every
//  playback tick. The scheduler moves that work off the main thread and
//  makes it LATEST-WINS per lane: scrubbing 40 frames enqueues 40 requests
//  and computes at most 2 (the one already running and the newest). A
//  stale result is never published; a running job can poll `isCancelled`
//  and bail out early.
//
//  Publishing happens on the main queue by default (SwiftUI @Published);
//  tests inject their own publisher.
//

import Foundation

public final class AnalysisScheduler {
    public static let shared = AnalysisScheduler()

    public struct LaneStats: Equatable {
        public var runs = 0          // computes that ran to completion
        public var dropped = 0       // requests replaced before they started
        public var cancelled = 0     // computes superseded while running
        public var lastMs: Double = 0
        public var lastAtoms = 0
    }

    private struct Lane {
        var latestTicket: UInt64 = 0
        var running = false
        var pending: (() -> Void)?
        var stats = LaneStats()
    }

    private let lock = NSLock()
    private var lanes: [String: Lane] = [:]
    private var ticketCounter: UInt64 = 0
    private let work: DispatchQueue
    private let publish: (@escaping () -> Void) -> Void

    /// `publish` runs the publish closure; defaults to the main queue.
    public init(qos: DispatchQoS = .userInitiated,
                publish: ((@escaping () -> Void) -> Void)? = nil) {
        work = DispatchQueue(label: "mdengine.analysis", qos: qos, attributes: .concurrent)
        self.publish = publish ?? { block in DispatchQueue.main.async(execute: block) }
    }

    /// Request `compute` on `lane`. `compute` receives an `isCancelled`
    /// probe (cheap; call it every ~10k atoms) and returns nil to skip
    /// publishing. `onResult` runs on the publish queue only if this request
    /// is still the newest one on its lane when the compute finishes.
    public func submit<T>(lane: String, atoms: Int = 0,
                          compute: @escaping (_ isCancelled: @escaping () -> Bool) -> T?,
                          onResult: @escaping (T) -> Void) {
        lock.lock()
        ticketCounter += 1
        let ticket = ticketCounter
        var l = lanes[lane] ?? Lane()
        l.latestTicket = ticket
        if l.pending != nil { l.stats.dropped += 1 }

        let job: () -> Void = { [weak self] in
            guard let self else { return }
            let isCancelled: () -> Bool = { [weak self] in
                guard let self else { return true }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.lanes[lane]?.latestTicket != ticket
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let result = compute(isCancelled)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6

            self.lock.lock()
            var lane2 = self.lanes[lane] ?? Lane()
            let isLatest = lane2.latestTicket == ticket
            if isLatest {
                lane2.stats.runs += 1
                lane2.stats.lastMs = ms
                lane2.stats.lastAtoms = atoms
            } else {
                lane2.stats.cancelled += 1
            }
            let next = lane2.pending
            lane2.pending = nil
            lane2.running = next != nil
            self.lanes[lane] = lane2
            self.lock.unlock()

            if isLatest, let value = result {
                self.publish { onResult(value) }
            }
            if let next { self.work.async(execute: next) }
        }

        if l.running {
            l.pending = job          // replaces any earlier pending request
            lanes[lane] = l
            lock.unlock()
        } else {
            l.running = true
            lanes[lane] = l
            lock.unlock()
            work.async(execute: job)
        }
    }

    /// Per-lane counters for the performance HUD.
    public func stats() -> [String: LaneStats] {
        lock.lock(); defer { lock.unlock() }
        return lanes.mapValues(\.stats)
    }

    /// Drop a lane's pending request and mark its running one stale.
    public func cancel(lane: String) {
        lock.lock(); defer { lock.unlock() }
        guard var l = lanes[lane] else { return }
        ticketCounter += 1
        l.latestTicket = ticketCounter
        if l.pending != nil { l.stats.dropped += 1 }
        l.pending = nil
        lanes[lane] = l
    }
}
