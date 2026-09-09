import Foundation
import LAMMPSCore

/// What the inspector is allowed to observe (design §1b, GJOB-133).
///
/// Measured 2026-09-08 on the 100 k-atom fixture: with the inspector bound to
/// the whole ContentViewModel, every playback tick (frameIndex publish) re-ran
/// the Form's layout — 30 fps fell to 12–15 draws/s with the (then fixed) Z-profile and
/// Elements sections expanded, and the main thread was all StackLayout /
/// sizeThatFits. The inspector now observes only this object, which changes
/// when its own content changes: analysis results, the frame COUNT (not the
/// index), and a few tokens the sections need.
final class InspectorState: ObservableObject {
    /// Element → count for the current frame, most frequent first; published
    /// only when the counts actually change.
    @Published fileprivate(set) var elementHistogram: [(String, Int)] = []
    /// Number of frames loaded (changes on load / live follow, not on scrub).
    @Published fileprivate(set) var frameCount = 0
    /// Whether the displayed frame is the last one (exports use the last frame).
    @Published fileprivate(set) var showingLastFrame = true
    @Published fileprivate(set) var exportProgress: Double?
    @Published fileprivate(set) var styleResetToken = 0

    // MARK: Tools area (design §1 + §1b)

    struct ToolPanel: Equatable {
        var result: ToolResult?
        var error: String?
        var computing = false
        /// Governor: too expensive for the playback frame budget; recomputes when playback stops.
        var deferred = false
        var lastMs: Double = 0
        /// Time series over frames (frame index → scalar) and its progress while running.
        var series: [Int: Double] = [:]
        var seriesProgress: Double?
        /// true when `series` came with the tool's result (ToolResult.series), so a
        /// parameter change may replace it; false once the user ran "Chart over all frames".
        var seriesFromTool = false
    }
    /// Tools the user added, in order; enabled/params live in the ToolRegistry store.
    @Published var addedTools: [String] = []
    @Published var tools: [String: ToolPanel] = [:]
    /// The one tool whose per-atom field colours the view (nil = element colours).
    @Published var overlayTool: String?
    /// Column names of the current frame — for the "Colour by column" picker.
    @Published var availableColumns: [String] = []
    /// Per-atom string labels of the loaded file (chain, resname…) → distinct
    /// values, plus "element" → element symbols. Computed once per file load,
    /// off main. Drives the Adhesion group-selector picker.
    @Published var availableLabels: [String: [String]] = [:]
    /// Frame marker for the time-series chart; updated at ≤ 4 Hz during playback.
    @Published var chartFrame = 0
    /// Reference (undeformed / t = 0) frame for tools that require one (Deformation).
    @Published var referenceFrame = 0
    /// Bumped when a tool's enabled flag or parameters change (registry store is not observable).
    @Published var toolSettingsGeneration = 0
    /// Governor: while playing, analysis sections freeze (each refresh re-lays
    /// out the whole inspector Form — measured 100+ ms at 100 k atoms, i.e.
    /// 30 fps → 23 draws/s at 1 Hz). The overlay keeps following the frame.
    @Published fileprivate(set) var isPlaying = false
}

extension ContentViewModel {
    /// Mirror the few model facts the inspector needs, without letting it
    /// observe the model itself. Called from the model's didSets.
    func syncInspectorFacts() {
        let count = frames.count
        if inspector.frameCount != count { inspector.frameCount = count }
        let last = frames.isEmpty || frameIndex == frames.count - 1
        if inspector.showingLastFrame != last { inspector.showingLastFrame = last }
    }

    func setInspectorElementHistogram(_ sorted: [(String, Int)]) {
        if sorted.map(\.0) != inspector.elementHistogram.map(\.0)
            || sorted.map(\.1) != inspector.elementHistogram.map(\.1) {
            inspector.elementHistogram = sorted
        }
    }

    func setInspectorExportProgress(_ p: Double?) { inspector.exportProgress = p }
    func setInspectorPlaying(_ playing: Bool) { if inspector.isPlaying != playing { inspector.isPlaying = playing } }
    func setInspectorStyleResetToken(_ t: Int) { inspector.styleResetToken = t }
}
