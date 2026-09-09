import Foundation
import SwiftUI
import LAMMPSCore

/// Counters behind the Performance HUD and `MDENGINE_PERF=1` (design §1b,
/// GJOB-133). Zero cost while disabled: the renderer checks one static Bool,
/// and the two timers exist only while the HUD is shown or the env var is set.
/// Choppiness gets measured, not felt.
final class PerfMonitor: ObservableObject {
    static let shared = PerfMonitor()
    /// Read on the main thread by every draw; deliberately a plain Bool.
    static private(set) var isEnabled = false

    struct Snapshot {
        var drawsPerSecond = 0
        var panes = 0
        var lastDrawMicros = 0
        var hitches = 0            // main-thread stalls > 50 ms since enabled
        var worstHitchMs = 0.0
        var bufferBuildsPerSecond = 0
        var lastBufferBuildMs = 0.0
        var lanes: [String: AnalysisScheduler.LaneStats] = [:]
    }
    @Published private(set) var snapshot = Snapshot()

    private let lock = NSLock()
    private var drawCount = 0
    private var lastDrawMicros = 0
    private var panes = Set<ObjectIdentifier>()
    private var hitches = 0
    private var worstHitchMs = 0.0
    private var bufferBuilds = 0
    private var lastBufferBuildMs = 0.0

    private var secondTimer: Timer?
    private var hitchTimer: Timer?
    private var lastHitchTick: CFAbsoluteTime = 0
    private var users = 0
    private let logToStderr = ProcessInfo.processInfo.environment["MDENGINE_PERF"] != nil

    private init() {
        if logToStderr { DispatchQueue.main.async { self.retain() } }
    }

    /// The HUD calls retain on appear and release on disappear.
    func retain() {
        users += 1
        guard users == 1 else { return }
        PerfMonitor.isEnabled = true
        lastHitchTick = CFAbsoluteTimeGetCurrent()
        // A 50 ms main-queue timer that arrives > 50 ms late = one hitch.
        hitchTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let lateMs = (now - self.lastHitchTick - 0.05) * 1000
            self.lastHitchTick = now
            if lateMs > 50 {
                self.lock.lock()
                self.hitches += 1
                self.worstHitchMs = max(self.worstHitchMs, lateMs)
                self.lock.unlock()
            }
        }
        secondTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.publish()
        }
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0, !logToStderr else { return }
        PerfMonitor.isEnabled = false
        hitchTimer?.invalidate(); hitchTimer = nil
        secondTimer?.invalidate(); secondTimer = nil
    }

    // MARK: Recording (any thread)

    func recordDraw(pane: ObjectIdentifier, micros: Int) {
        lock.lock()
        drawCount += 1
        lastDrawMicros = micros
        panes.insert(pane)
        lock.unlock()
    }

    func recordBufferBuild(ms: Double) {
        lock.lock()
        bufferBuilds += 1
        lastBufferBuildMs = ms
        lock.unlock()
    }

    private func publish() {
        lock.lock()
        var s = Snapshot()
        s.drawsPerSecond = drawCount
        s.panes = panes.count
        s.lastDrawMicros = lastDrawMicros
        s.hitches = hitches
        s.worstHitchMs = worstHitchMs
        s.bufferBuildsPerSecond = bufferBuilds
        s.lastBufferBuildMs = lastBufferBuildMs
        drawCount = 0
        bufferBuilds = 0
        panes.removeAll()
        lock.unlock()
        s.lanes = AnalysisScheduler.shared.stats()
        snapshot = s
        if logToStderr {
            let lanes = s.lanes.keys.sorted().map {
                String(format: "%@=%.1fms/%d/%d", $0, s.lanes[$0]!.lastMs, s.lanes[$0]!.runs, s.lanes[$0]!.dropped)
            }.joined(separator: " ")
            let line = String(format: "perf draws/s=%d panes=%d draw_us=%d hitches=%d worst_ms=%.0f buffers/s=%d buffer_ms=%.1f %@\n",
                              s.drawsPerSecond, s.panes, s.lastDrawMicros, s.hitches, s.worstHitchMs,
                              s.bufferBuildsPerSecond, s.lastBufferBuildMs, lanes)
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
    }
}

/// Small monospaced overlay, top-left of the main pane. Refreshes at 1 Hz
/// from the monitor's snapshot, never per frame.
struct PerfHUDView: View {
    @ObservedObject private var perf = PerfMonitor.shared
    @ObservedObject var model: ContentViewModel

    var body: some View {
        let s = perf.snapshot
        VStack(alignment: .leading, spacing: 1) {
            Text("draws/s \(s.drawsPerSecond) · panes \(s.panes) · draw \(s.lastDrawMicros) µs")
            Text(String(format: "hitches %d · worst %.0f ms · buffers/s %d (%.1f ms)",
                        s.hitches, s.worstHitchMs, s.bufferBuildsPerSecond, s.lastBufferBuildMs))
            Text("atoms \(model.atoms.count) · frame \(model.frameIndex)/\(max(0, model.frames.count - 1))")
            ForEach(s.lanes.keys.sorted(), id: \.self) { lane in
                let l = s.lanes[lane]!
                Text(String(format: "%@ %.1f ms · runs %d · dropped %d · cancelled %d",
                            lane, l.lastMs, l.runs, l.dropped, l.cancelled))
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(.white)
        .padding(6)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .help("Performance HUD: 0 draws/s when idle and 0 hitches during playback are the targets (design §1b)")
        .onAppear { perf.retain() }
        .onDisappear { perf.release() }
    }
}
