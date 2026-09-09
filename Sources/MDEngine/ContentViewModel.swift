import Foundation
import MDRender
import AppKit
import LAMMPSCore
import UniformTypeIdentifiers

final class ContentViewModel: ObservableObject {
    @Published var frames: [[Arv]] = [] { didSet { syncInspectorFacts(); scheduleAnalyses() } }
    /// Full frames (box, timestep, per-atom columns) for the analysis tools;
    /// `frames` stays the renderer's view of the same atom arrays (COW, no copy).
    var trajectory: Trajectory = []
    /// Per-atom colours from the overlay tool for the frame on screen; nil =
    /// element colours. NOT published and never passed through SwiftUI as a
    /// value (100 k entries per tick): MetalView pulls it when `overlayGeneration` changes.
    var overlayColors: [SIMD3<Float>]? = nil
    @Published var overlayGeneration = 0
    /// Perceived topology for the frame on screen (GJOB-145). Like
    /// overlayColors: NOT published as a value — MetalView pulls it through
    /// `bondsProvider` when `bondsGeneration` changes.
    var bondSet: BondSet? = nil
    @Published var bondsGeneration = 0
    /// (trajectory generation, frame index) the cached `bondSet` belongs to;
    /// a flag toggle re-publishes it instead of re-perceiving.
    private var bondsComputedFor: (generation: Int, frame: Int) = (-1, -1)
    private var lastBondsSubmit: CFAbsoluteTime = 0
    private var lastBondFlags: (bonds: Bool, backbone: Bool) = (false, false)
    /// Governor bookkeeping for the tool lanes (see ToolsController.swift).
    var toolSubmitTimes: [String: CFAbsoluteTime] = [:]
    var labelsGeneration = -1
    var seriesCancelFlags: [String: Bool] = [:]
    @Published var frameIndex: Int = 0 {
        didSet { if frameIndex != oldValue { syncInspectorFacts(); scheduleAnalyses() } }
    }
    /// The inspector observes this, never the model (see InspectorState).
    let inspector = InspectorState()
    /// File the trajectory came from (nil for the bundled example); tools find side files next to it.
    var sourceURL: URL?
    @Published var generation: Int = 0   // bumped per file load, drives GPU re-upload
    @Published var sourceName: String = ""
    @Published var showInspector = false { didSet { scheduleAnalyses() } }

    init() {
        loadToolPrefs()
        lastBondFlags = (showBonds, showBackbone)
        // The Display section's Bonds/Backbone toggles are @AppStorage, so
        // they arrive here through UserDefaults.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let flags = (self.showBonds, self.showBackbone)
                if flags != self.lastBondFlags {
                    self.lastBondFlags = flags
                    self.scheduleBonds(force: true)
                }
            }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }
    @Published var cameraResetToken = 0   // bumped by inspector's Reset Camera

    // MARK: Recent files (File ▸ Open Recent)
    @Published var recentFiles: [String] =
        UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []

    private func noteRecent(_ url: URL) {
        var list = recentFiles.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        recentFiles = Array(list.prefix(10))
        UserDefaults.standard.set(recentFiles, forKey: "recentFiles")
    }

    func openRecent(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            recentFiles.removeAll { $0 == path }
            UserDefaults.standard.set(recentFiles, forKey: "recentFiles")
            Self.alert("File not found", info: "\(path) no longer exists; removed from Open Recent.")
            return
        }
        load(url: URL(fileURLWithPath: path))
    }

    func clearRecents() {
        recentFiles = []
        UserDefaults.standard.set(recentFiles, forKey: "recentFiles")
    }

    // MARK: Playback
    @Published var isPlaying = false
    @Published var loopPlayback = UserDefaults.standard.bool(forKey: "loopPlayback") {
        didSet { UserDefaults.standard.set(loopPlayback, forKey: "loopPlayback") }
    }
    private var playTimer: Timer?

    // MARK: Live following of a growing trajectory file
    @Published var isFollowingFile = false
    private var watchedURL: URL?
    private var watchedSize: Int = -1
    private var watchTimer: Timer?

    /// The frame currently on screen.
    var atoms: [Arv] { frames.indices.contains(frameIndex) ? frames[frameIndex] : [] }

    // MARK: - Analyses off the main thread (design §1b, GJOB-133)
    //
    // The inspector used to compute these inside its SwiftUI body — an
    // O(N log N) pass over every atom on the main thread per playback tick.
    // Now they run through AnalysisScheduler (latest request wins) and only
    // while the inspector, and for the Z-profile its section, is on screen.

    /// Element → count for the current frame (also feeds the summary bar).
    var elementHistogram: [(String, Int)] { inspector.elementHistogram }
    private var defaultsObserver: NSObjectProtocol?
    /// Governor rule (design §1b): while playing, a tool's section is
    /// refreshed at most this often — re-laying out the inspector on every
    /// tick is what dropped 30 fps to 14 draws/s, not the analysis itself.
    static let playbackRefreshInterval: CFAbsoluteTime = 0.25

    /// The element histogram feeds the always-visible summary bar, so it runs
    /// whenever the frame changes; analysis tools only while their section shows
    /// (ToolsController). The Z-profile is one of those tools (GJOB-164).
    func scheduleAnalyses() {
        let frame = atoms
        AnalysisScheduler.shared.submit(lane: "elements", atoms: frame.count, compute: { isCancelled in
            var histogram: [String: Int] = [:]
            for (n, a) in frame.enumerated() {
                histogram[a.element, default: 0] += 1
                if n & 0xFFFF == 0xFFFF, isCancelled() { return nil }
            }
            let sorted = histogram.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .map { ($0.key, $0.value) }
            return sorted
        }, onResult: { [weak self] (sorted: [(String, Int)]) in
            self?.setInspectorElementHistogram(sorted)
        })
        scheduleBonds()
        scheduleTools()
    }

    // MARK: - Bonds + backbone trace (GJOB-145)

    /// Display ▸ Bonds. Read straight from UserDefaults (the toggle is
    /// @AppStorage in the inspector) so there is one source of truth.
    var showBonds: Bool { UserDefaults.standard.bool(forKey: "showBonds") }
    /// Display ▸ Backbone trace.
    var showBackbone: Bool { UserDefaults.standard.bool(forKey: "showBackbone") }
    /// Escape hatch for the tolerance on the covalent-radius sum; unset =
    /// 1.15. Handy for a system whose radii sit just outside the default
    /// (fcc Al: nearest neighbour 2.86 Å against a 2.78 Å criterion).
    var bondTolerance: Double {
        let t = UserDefaults.standard.double(forKey: "bondTolerance")
        return t > 0 ? t : BondPerception.defaultTolerance
    }

    /// What the renderer should draw: the cached set filtered by the two
    /// flags. nil = points only.
    func bondsForRenderer() -> BondSet? {
        guard let set = bondSet else { return nil }
        let filtered = BondSet(pairs: showBonds ? set.pairs : [],
                               backbone: showBackbone ? set.backbone : [])
        return filtered.isEmpty ? nil : filtered
    }

    /// Perceive bonds for the current frame on the "bonds" lane. Latest wins;
    /// during playback at most one submission per `playbackRefreshInterval`,
    /// and while a new set is in flight the renderer keeps the previous one.
    func scheduleBonds(force: Bool = false) {
        guard showBonds || showBackbone else {
            if bondSet != nil {
                bondSet = nil
                bondsComputedFor = (-1, -1)
                bondsGeneration += 1
            }
            return
        }
        guard let frame = currentFrame else { return }
        // Both flags read the same perceived set, so a toggle only re-publishes.
        if bondsComputedFor == (generation, frameIndex), bondSet != nil {
            bondsGeneration += 1
            return
        }
        if isPlaying && !force {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastBondsSubmit < Self.playbackRefreshInterval { return }
        }
        lastBondsSubmit = CFAbsoluteTimeGetCurrent()
        let gen = generation, fi = frameIndex, tolerance = bondTolerance
        AnalysisScheduler.shared.submit(lane: "bonds", atoms: frame.count,
                                        compute: { isCancelled -> BondSet? in
            BondPerception.perceive(frame: frame, tolerance: tolerance, isCancelled: isCancelled)
        }, onResult: { [weak self] set in
            guard let self, self.generation == gen else { return }
            self.bondSet = set
            self.bondsComputedFor = (gen, fi)
            self.bondsGeneration += 1
        })
    }


    /// Load the bundled example trajectory (a Lennard-Jones argon melt,
    /// `lj_melt.xyz`, generated by the also-bundled `lj_melt.in` deck) — but
    /// only if no real file shows up first. Finder/`open <file>` events land
    /// a beat AFTER launch, so loading the demo immediately flashed argon
    /// before every opened trajectory; give the open event a moment instead.
    func runSimulationAndDisplayResults() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.frames.isEmpty, self.sourceName.isEmpty else { return }
            guard let text = self.loadTrajectoryText() else {
                print("ContentViewModel: no bundled trajectory resource found")
                return
            }
            self.show(XYZParser.parseTrajectory(text), name: "LJ argon melt (bundled example)")
        }
    }

    /// The frame on screen with its box and per-atom columns (tools read this).
    var currentFrame: Frame? { trajectory.indices.contains(frameIndex) ? trajectory[frameIndex] : nil }

    private func show(_ parsed: Trajectory, name: String) {
        trajectory = parsed
        frames = parsed.map(\.atoms)
        frameIndex = max(0, parsed.count - 1)   // open at the final state
        generation += 1
        sourceName = name
        applyPerfHarness()
    }

    /// Shell-drivable performance gates (design §1b): `MDENGINE_INSPECTOR=1`
    /// opens the inspector, `MDENGINE_AUTOPLAY=<fps>` starts looped playback
    /// at that rate. Combined with `MDENGINE_PERF=1` the stderr log gives
    /// idle draws/s and playback hitches without a hand on the mouse.
    private func applyPerfHarness() {
        let env = ProcessInfo.processInfo.environment
        if env["MDENGINE_INSPECTOR"] != nil { showInspector = true }
        if let fps = env["MDENGINE_AUTOPLAY"].flatMap(Double.init), frames.count > 1 {
            playbackFPS = max(1, min(60, fps))
            loopPlayback = true
            frameIndex = 0
            startPlayback()
        }
    }

    // MARK: - View presets (Top/Front/… snap, from the viewport menu)

    @Published var viewPresetToken = 0
    var pendingViewPreset: RenderCore.ViewPreset?

    func applyViewPreset(_ preset: RenderCore.ViewPreset) {
        pendingViewPreset = preset
        viewPresetToken += 1
    }

    // MARK: - Video export

    /// True while a file parse is in flight (drives the viewport spinner).
    @Published var isLoading = false

    /// Bumped when per-element colors/sizes change (inspector edits).
    @Published var styleGeneration = 0

    /// Bumped only by Restore Defaults: forces element rows to rebuild with
    /// factory values. Kept separate from styleGeneration — recreating a row
    /// mid-edit would orphan an open color picker's binding.
    @Published var styleResetToken = 0 { didSet { setInspectorStyleResetToken(styleResetToken) } }

    /// nil = idle; 0…1 while an export runs (drives the inspector progress bar).
    @Published var exportProgress: Double? { didSet { setInspectorExportProgress(exportProgress) } }
    private var exportCancelled = false

    func cancelVideoExport() { exportCancelled = true }

    func exportVideo(format: VideoExporter.Format) {
        guard frames.count > 1, exportProgress == nil else { return }
        let d = UserDefaults.standard
        let height = d.object(forKey: "videoHeight") as? Int ?? 1080
        let fps = d.object(forKey: "videoFPS") as? Int ?? 30
        let stride = d.object(forKey: "videoStride") as? Int ?? 0
        let annotations = d.object(forKey: "videoAnnotations") as? Bool ?? true
        let orbit = d.object(forKey: "videoOrbit") as? Bool ?? false
        let orbitSpeed = d.object(forKey: "videoOrbitSpeed") as? Double ?? 6

        let vs = ViewportScale.shared
        let camera = OffscreenRenderer.Camera(
            yaw: vs.yaw, pitch: vs.pitch,
            distance: vs.distance > 0 ? vs.distance : 2.8, pan: vs.pan,
            orthographic: d.bool(forKey: "orthographicProjection"),
            roll: vs.roll)

        var options = VideoExporter.Options(
            width: height * 16 / 9, height: height, fps: fps, stride: stride,
            format: format, annotations: annotations,
            orbitDegreesPerSecond: orbit ? orbitSpeed : 0, camera: camera,
            pointSize: Float(d.object(forKey: "atomPointSize") as? Double ?? 14),
            background: Renderer.backgroundColor(),
            style: ElementStyleStore.currentStyle())
        if format == .gif {   // GIFs get web-sane defaults: small and ≤15 fps
            options.width = 640
            options.height = 360
            options.fps = min(fps, 15)
        }
        options.overlay = overlayFieldProvider()
        // Bonds in the movie match the window: same flags, same tolerance,
        // perceived frame by frame on the export's own queue.
        if showBonds || showBackbone {
            let traj = trajectory, tolerance = bondTolerance, wantSticks = showBonds
            options.bonds = { i in
                guard traj.indices.contains(i),
                      var set = BondPerception.perceive(frame: traj[i], tolerance: tolerance)
                else { return nil }
                if !wantSticks { set.pairs = [] }
                return set
            }
            options.showBackbone = showBackbone
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .mp4 ? .mpeg4Movie : .gif]
        let base = sourceName.isEmpty ? "trajectory"
            : (sourceName as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + (format == .mp4 ? ".mp4" : ".gif")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        exportCancelled = false
        exportProgress = 0
        let trajectory = frames
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try VideoExporter.export(frames: trajectory, to: url, options: options) { p in
                    DispatchQueue.main.async { self?.exportProgress = p }
                    return !(self?.exportCancelled ?? true)
                }
                DispatchQueue.main.async {
                    self?.exportProgress = nil
                    if self?.exportCancelled == false {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.exportProgress = nil
                    Self.alert("Video export failed", info: error.localizedDescription)
                }
            }
        }
    }


    // MARK: - Playback

    /// Frames per second while playing; the speed bar above the play button
    /// drives this. Persisted, and applied live mid-playback.
    @Published var playbackFPS: Double = max(1, min(60, UserDefaults.standard.object(forKey: "playbackFPS") as? Double ?? 10)) {
        didSet {
            UserDefaults.standard.set(playbackFPS, forKey: "playbackFPS")
            if isPlaying { startPlayback() }
        }
    }

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    func startPlayback() {
        guard frames.count > 1 else { return }
        isPlaying = true
        setInspectorPlaying(true)
        playTimer?.invalidate()
        playTimer = Timer.scheduledTimer(withTimeInterval: 1 / max(1, playbackFPS),
                                         repeats: true) { [weak self] _ in
            self?.stepPlayback()
        }
    }

    func stopPlayback() {
        isPlaying = false
        playTimer?.invalidate()
        playTimer = nil
        setInspectorPlaying(false)
        scheduleTools(force: true)  // sections were frozen while playing
    }

    private func stepPlayback() {
        if frameIndex < frames.count - 1 {
            frameIndex += 1
        } else if loopPlayback {
            frameIndex = 0
        } else {
            stopPlayback()
        }
    }

    // MARK: - Live following

    /// Poll the loaded file; when a running simulation appends frames, re-parse
    /// (the readers are safe on in-flight files) and extend the timeline in
    /// place — no re-loading by the user. Camera and scrub position are kept;
    /// if the user was at the final frame, follow the new final frame.
    private func watch(url: URL, knownSize: Int) {
        watchTimer?.invalidate()
        watchedURL = url
        watchedSize = knownSize
        isFollowingFile = true
        // Poll slower for big files: a full re-parse costs time proportional
        // to size, so the interval scales well past the parse cost
        // (2s small, ~45s at 350MB) to avoid burning a core continuously.
        let interval = max(2.0, Double(knownSize) / 8_000_000)
        watchTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshFromWatchedFile()
        }
    }

    private func refreshFromWatchedFile() {
        guard let url = watchedURL, !refreshInFlight else { return }
        let size = fileSize(url)
        guard size != watchedSize, size < 1_000_000_000 else { return }
        watchedSize = size
        refreshInFlight = true
        parseQueue.async { [weak self] in
            let parsed = (try? TrajectoryReader.parseTrajectory(contentsOf: url)) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                guard self.watchedURL == url,                    // not replaced meanwhile
                      parsed.count != self.frames.count, !parsed.isEmpty else { return }
                let wasAtEnd = self.frameIndex >= self.frames.count - 1
                self.trajectory = parsed
                self.frames = parsed.map(\.atoms)
                self.generation += 1
                self.frameIndex = wasAtEnd ? parsed.count - 1 : min(self.frameIndex, parsed.count - 1)
            }
        }
    }

    private func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
    }

    // MARK: - File menu

    /// File ▸ Load File…: open any XYZ / extended-XYZ trajectory from disk.
    func loadFilePanel() {
        let panel = NSOpenPanel()
        panel.message = "Choose a trajectory: XYZ / extended-XYZ or native LAMMPS dump"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    /// Parsing happens OFF the main thread — large trajectories must never
    /// beachball the app (a 343MB in-flight dump did exactly that once).
    func load(url: URL) {
        let size = fileSize(url)
        guard size < 2_000_000_000 else {
            Self.alert("\(url.lastPathComponent) is \(size / 1_000_000) MB",
                       info: "MDEngine loads whole trajectories into memory (limit 2 GB). "
                           + "Shrink it first: mdengine decimate <file> --every N")
            return
        }
        sourceName = "Loading \(url.lastPathComponent)…"
        isLoading = true
        parseQueue.async { [weak self] in
            let loaded = try? TrajectoryReader.parseTrajectory(contentsOf: url)
            let parsed = loaded ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                guard loaded != nil else {
                    self.sourceName = ""
                    Self.alert("Could not read \(url.lastPathComponent)",
                               info: "The file could not be opened as text.")
                    return
                }
                guard !parsed.isEmpty else {
                    self.sourceName = ""
                    Self.alert("No atoms found in \(url.lastPathComponent)",
                               info: "MDEngine reads XYZ / extended-XYZ and native LAMMPS dump files "
                                   + "(ITEM: TIMESTEP blocks from `dump atom`/`dump custom`). "
                                   + "Trajectories open at their final frame — scrub with the timeline.")
                    return
                }
                self.sourceURL = url
                self.show(parsed, name: url.lastPathComponent)
                self.noteRecent(url)
                self.watch(url: url, knownSize: size)
            }
        }
    }

    private let parseQueue = DispatchQueue(label: "mdengine.parse", qos: .userInitiated)
    private var refreshInFlight = false

    /// File ▸ Export File…: write the displayed frame back out as XYZ.
    func exportFilePanel() {
        guard !atoms.isEmpty else { return }
        let panel = NSSavePanel()
        panel.message = "Export the displayed frame as XYZ"
        panel.nameFieldStringValue = "frame.xyz"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var text = "\(atoms.count)\nExported from MDEngine — \(sourceName)\n"
        for a in atoms {
            text += "\(a.element) \(a.x) \(a.y) \(a.z)\n"
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.alert("Export failed", info: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func loadTrajectoryText() -> String? {
        if let url = Bundle.module.url(forResource: "lj_melt", withExtension: "xyz"),
           let text = try? String(contentsOf: url) {
            return text
        }
        return nil
    }

    static func alert(_ message: String, info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.runModal()
    }
}
