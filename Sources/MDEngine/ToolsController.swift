import Foundation
import AppKit
import LAMMPSCore
import UniformTypeIdentifiers
import MDRender

/// UserDefaults-backed store for the ToolRegistry (enabled set + parameters).
final class UserDefaultsToolStore: ToolKeyValueStore {
    func data(forKey key: String) -> Data? { UserDefaults.standard.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) {
        if let data { UserDefaults.standard.set(data, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// The app side of the analysis tools (design §1 "App", §1b governor):
/// which tools are added/enabled, when they compute, where results go, and
/// the overlay hand-off to the renderer. Every compute goes through
/// AnalysisScheduler on lane "tool.<id>"; nothing here touches atoms on the
/// main thread.
extension ContentViewModel {
    static let toolRegistry: ToolRegistry = {
        let r = ToolRegistry(store: UserDefaultsToolStore())
        r.registerBuiltIns()
        return r
    }()
    var registry: ToolRegistry { Self.toolRegistry }

    /// Frame budget during playback: a tool predicted to exceed this is deferred.
    static let playbackToolBudgetMicros: Double = 50_000
    /// Governor: while playing, tool SECTIONS freeze (an inspector refresh
    /// re-lays out the whole Form: measured 100+ ms at 100 k atoms). Only the
    /// overlay tool keeps computing, at ≤ 4 Hz, for the renderer's colours.

    private static let addedKey = "tools.added"
    private static let overlayKey = "tools.overlay"

    func loadToolPrefs() {
        inspector.addedTools = UserDefaults.standard.stringArray(forKey: Self.addedKey) ?? []
        inspector.overlayTool = UserDefaults.standard.string(forKey: Self.overlayKey)
    }

    // MARK: Editing what is on the panel

    func addTool(_ id: String) {
        guard registry.tool(id) != nil, !inspector.addedTools.contains(id) else { return }
        inspector.addedTools.append(id)
        UserDefaults.standard.set(inspector.addedTools, forKey: Self.addedKey)
        registry.setEnabled(true, for: id)
        UserDefaults.standard.set(true, forKey: "inspExpTool.\(id)")
        inspector.toolSettingsGeneration += 1
        scheduleTool(id, force: true)
    }

    func removeTool(_ id: String) {
        inspector.addedTools.removeAll { $0 == id }
        UserDefaults.standard.set(inspector.addedTools, forKey: Self.addedKey)
        inspector.tools[id] = nil
        if inspector.overlayTool == id { setOverlayTool(nil) }
        AnalysisScheduler.shared.cancel(lane: "tool.\(id)")
        inspector.toolSettingsGeneration += 1
    }

    func setToolEnabled(_ id: String, _ on: Bool) {
        registry.setEnabled(on, for: id)
        inspector.toolSettingsGeneration += 1
        if on { scheduleTool(id, force: true) }
        else {
            inspector.tools[id]?.computing = false
            inspector.tools[id]?.deferred = false
            if inspector.overlayTool == id { applyOverlayColors(nil) }
        }
    }

    func setToolParameters(_ id: String, json: Data?) {
        registry.setParameters(json, for: id)
        inspector.tools[id]?.series = [:]        // stale against new parameters
        inspector.toolSettingsGeneration += 1
        scheduleTool(id, force: true)
    }

    /// Only one overlay at a time; nil restores element colours.
    func setOverlayTool(_ id: String?) {
        inspector.overlayTool = id
        if let id { UserDefaults.standard.set(id, forKey: Self.overlayKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.overlayKey) }
        if let id {
            if let field = inspector.tools[id]?.result?.field, field.values.count == atoms.count {
                AnalysisScheduler.shared.submit(lane: "overlay", atoms: field.values.count,
                                                compute: { _ in FieldColors.colors(for: field) },
                                                onResult: { [weak self] colors in self?.applyOverlayColors(colors) })
            } else {
                scheduleTool(id, force: true)
            }
        } else {
            applyOverlayColors(nil)
        }
    }

    // MARK: Label catalogue for group pickers (once per file load, off main)

    private func refreshAvailableLabels(_ frame: Frame) {
        guard labelsGeneration != generation else { return }
        labelsGeneration = generation
        let labels = frame.labels, atoms = frame.atoms
        AnalysisScheduler.shared.submit(lane: "labels", atoms: atoms.count, compute: { isCancelled -> [String: [String]]? in
            var out: [String: [String]] = [:]
            for (name, values) in labels where values.count == atoms.count {
                var seen = Set<String>()
                for (n, v) in values.enumerated() {
                    seen.insert(v)
                    if n & 0xFFFF == 0xFFFF, isCancelled() { return nil }
                }
                out[name] = seen.sorted { a, b in
                    if let x = Int(a), let y = Int(b) { return x < y }
                    return a < b
                }
            }
            var elements = Set<String>()
            for a in atoms { elements.insert(a.element) }
            out["element"] = elements.sorted()
            return out
        }, onResult: { [weak self] labels in
            self?.inspector.availableLabels = labels
        })
    }

    // MARK: Reference frame (tools with requirement .referenceFrame)

    func setReferenceFrame(_ index: Int) {
        let clamped = max(0, min(max(0, trajectory.count - 1), index))
        guard inspector.referenceFrame != clamped else { return }
        inspector.referenceFrame = clamped
        for id in inspector.addedTools {
            inspector.tools[id]?.series = [:]      // series were against the old reference
            scheduleTool(id, force: true)
        }
    }

    /// Context for `tool` at `frameIndex`, with the reference frame attached
    /// when the tool declares it. Safe off the main thread (values captured).
    func makeContext(for meta: ToolMetadata, frameIndex: Int, trajectory traj: Trajectory,
                     referenceIndex: Int, isCancelled: @escaping () -> Bool = { false }) -> AnalysisContext {
        let gen = generation
        guard meta.requirements.contains(.referenceFrame), traj.indices.contains(referenceIndex) else {
            return AnalysisContext(frameIndex: frameIndex, isCancelled: isCancelled, sourceURL: sourceURL,
                                   trajectory: traj, trajectoryGeneration: gen)
        }
        return AnalysisContext(frameIndex: frameIndex, referenceFrame: traj[referenceIndex],
                               referenceFrameIndex: referenceIndex, isCancelled: isCancelled, sourceURL: sourceURL,
                               trajectory: traj, trajectoryGeneration: gen)
    }

    // MARK: Scheduling (the governor)

    /// A tool computes only while it can be seen: inspector shown and its
    /// section expanded — or it is the overlay tool (its colours are visible).
    func toolWanted(_ id: String) -> Bool {
        guard inspector.addedTools.contains(id), registry.isEnabled(id) else { return false }
        if inspector.overlayTool == id { return true }
        return showInspector && UserDefaults.standard.bool(forKey: "inspExpTool.\(id)")
    }

    func scheduleTools(force: Bool = false) {
        if let frame = currentFrame {
            let cols = ColumnFieldTool.availableColumns(frame)
            if cols != inspector.availableColumns { inspector.availableColumns = cols }
            refreshAvailableLabels(frame)
        }
        for id in inspector.addedTools { scheduleTool(id, force: force) }
        updateChartFrame(force: force)
    }

    func scheduleTool(_ id: String, force: Bool = false) {
        guard let frame = currentFrame, let tool = registry.tool(id) else { return }
        guard toolWanted(id) else {
            if inspector.overlayTool == id, overlayColors != nil { applyOverlayColors(nil) }
            return
        }
        var panel = inspector.tools[id] ?? .init()
        if isPlaying && !force {
            guard inspector.overlayTool == id else { return }   // frozen section, no compute
            let cost = registry.estimatedCost(toolId: id, atoms: frame.count)
            if cost > Self.playbackToolBudgetMicros {
                if !panel.deferred { panel.deferred = true; inspector.tools[id] = panel }
                return
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - (toolSubmitTimes[id] ?? 0) < Self.playbackRefreshInterval { return }
            toolSubmitTimes[id] = now
        } else {
            toolSubmitTimes[id] = CFAbsoluteTimeGetCurrent()
        }
        if !panel.computing { panel.computing = true; inspector.tools[id] = panel }

        let params = registry.parameters(for: id)
        let fi = frameIndex
        let atoms = frame.count
        let wantsColors = inspector.overlayTool == id      // colours are built off main, with the result
        let meta = tool.metadata, traj = trajectory, refIndex = inspector.referenceFrame
        enum Outcome { case ok(ToolResult, Double, [SIMD3<Float>]?), failed(String) }
        AnalysisScheduler.shared.submit(lane: "tool.\(id)", atoms: atoms, compute: { [weak self] isCancelled -> Outcome in
            guard let self else { return .failed("cancelled") }
            let ctx = self.makeContext(for: meta, frameIndex: fi, trajectory: traj,
                                       referenceIndex: refIndex, isCancelled: isCancelled)
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                let r = try tool.analyze(frame: frame, context: ctx, parametersJSON: params)
                let micros = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3
                let colors = (wantsColors && r.field?.values.count == atoms) ? r.field.map(FieldColors.colors) : nil
                return .ok(r, micros, colors)
            } catch AnalysisError.cancelled {
                return .failed("cancelled")
            } catch {
                return .failed(error.localizedDescription)
            }
        }, onResult: { [weak self] outcome in
            guard let self, self.inspector.addedTools.contains(id) else { return }
            if case .ok(_, let micros, let colors) = outcome {
                self.registry.recordMeasurement(toolId: id, atoms: atoms, microseconds: micros)
                if self.inspector.overlayTool == id {
                    self.applyOverlayColors(colors?.count == self.atoms.count ? colors : nil)
                }
                if self.isPlaying, !force { return }    // colours applied; section stays frozen
            }
            var p = self.inspector.tools[id] ?? .init()
            p.computing = false
            p.deferred = false
            switch outcome {
            case .ok(let r, let micros, let colors):
                p.result = r
                p.error = nil
                p.lastMs = micros / 1000
                _ = colors
                // A tool that knows its scalar over all frames (side-file tools) fills the
                // chart at once; a running or user-made series is never overwritten.
                if let s = r.series, p.seriesProgress == nil, p.series.isEmpty || p.seriesFromTool {
                    p.series = s
                    p.seriesFromTool = true
                }
            case .failed(let msg):
                if msg != "cancelled" { p.error = msg; p.result = nil }
            }
            if self.inspector.tools[id] != p { self.inspector.tools[id] = p }
        })
    }

    private func applyOverlayColors(_ colors: [SIMD3<Float>]?) {
        overlayColors = colors
        overlayGeneration += 1
    }

    /// Chart cursor follows the frame at ≤ 4 Hz while playing (inspector layout cost).
    private func updateChartFrame(force: Bool) {
        guard inspector.tools.values.contains(where: { !$0.series.isEmpty }) else { return }
        if isPlaying && !force {
            let now = CFAbsoluteTimeGetCurrent()
            if now - (toolSubmitTimes["_chart"] ?? 0) < Self.playbackRefreshInterval { return }
            toolSubmitTimes["_chart"] = now
        }
        if inspector.chartFrame != frameIndex { inspector.chartFrame = frameIndex }
    }

    // MARK: Time series (explicit, with progress and Cancel — never automatic)

    func runTimeSeries(_ id: String) {
        guard let tool = registry.tool(id), !trajectory.isEmpty else { return }
        seriesCancelFlags[id] = false
        var panel = inspector.tools[id] ?? .init()
        panel.series = [:]
        panel.seriesFromTool = false
        panel.seriesProgress = 0
        inspector.tools[id] = panel
        let params = registry.parameters(for: id)
        let traj = trajectory
        let meta = tool.metadata, refIndex = inspector.referenceFrame
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var series: [Int: Double] = [:]
            var lastPublish = CFAbsoluteTimeGetCurrent()
            for (i, frame) in traj.enumerated() {
                var cancelled = false
                DispatchQueue.main.sync { cancelled = self?.seriesCancelFlags[id] ?? true }
                if cancelled { break }
                guard let self else { break }
                let ctx = self.makeContext(for: meta, frameIndex: i, trajectory: traj, referenceIndex: refIndex)
                if let r = try? tool.analyze(frame: frame, context: ctx, parametersJSON: params),
                   let s = r.scalar {
                    series[i] = s
                }
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastPublish > 0.1 || i == traj.count - 1 {
                    lastPublish = now
                    let snapshot = series
                    let progress = Double(i + 1) / Double(traj.count)
                    DispatchQueue.main.async {
                        var p = self.inspector.tools[id] ?? .init()
                        p.series = snapshot
                        p.seriesProgress = progress
                        self.inspector.tools[id] = p
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var p = self.inspector.tools[id] ?? .init()
                p.seriesProgress = nil
                self.inspector.tools[id] = p
                self.inspector.chartFrame = self.frameIndex
            }
        }
    }

    func cancelTimeSeries(_ id: String) { seriesCancelFlags[id] = true }

    // MARK: Export

    func exportToolCSV(_ id: String) { exportTool(id, format: .csv) }
    func exportToolXLSX(_ id: String) { exportTool(id, format: .xlsx) }

    enum ToolExportFormat { case csv, xlsx }

    /// One exporter for every tool (LAMMPSCore.ToolExport): summary, profile, time series,
    /// and in the workbook the per-atom field. The .xlsx container is written by `Zip` — no shell-out.
    func exportTool(_ id: String, format: ToolExportFormat) {
        guard let panel = inspector.tools[id], let result = panel.result,
              let meta = registry.metadata.first(where: { $0.id == id }) else { return }
        let ext = format == .csv ? "csv" : "xlsx"
        let panelSave = NSSavePanel()
        if let type = UTType(filenameExtension: ext) { panelSave.allowedContentTypes = [type] }
        let base = sourceName.split(separator: ".").first.map(String.init) ?? "trajectory"
        panelSave.nameFieldStringValue = "\(base)-\(id).\(ext)"
        guard panelSave.runModal() == .OK, let url = panelSave.url else { return }
        let prov = ToolExport.Provenance(toolTitle: meta.title, toolId: id, source: sourceName, frameIndex: frameIndex)
        do {
            switch format {
            case .csv:
                try ToolExport.csv(result, provenance: prov, series: panel.series)
                    .write(to: url, atomically: true, encoding: .utf8)
            case .xlsx:
                try ToolExport.writeXLSX(result, provenance: prov, to: url, series: panel.series)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            Self.alert("Export failed", info: error.localizedDescription)
        }
    }
}

// MARK: - Snapshots and video overlays

extension ContentViewModel {
    /// Per-frame field of the overlay tool for the exporter (runs on the
    /// export's own thread; nil when no overlay is active).
    func overlayFieldProvider() -> ((Int) -> PerAtomField?)? {
        guard let id = inspector.overlayTool, registry.isEnabled(id), let tool = registry.tool(id) else { return nil }
        let params = registry.parameters(for: id)
        let traj = trajectory
        let meta = tool.metadata, refIndex = inspector.referenceFrame
        return { [weak self] index in
            guard let self, traj.indices.contains(index) else { return nil }
            let ctx = self.makeContext(for: meta, frameIndex: index, trajectory: traj, referenceIndex: refIndex)
            return (try? tool.analyze(frame: traj[index], context: ctx, parametersJSON: params))?.field
        }
    }

    /// PNG of the current view with this tool's field as the colour source and
    /// its legend baked (same annotation path as video export).
    func snapshotTool(_ id: String) {
        guard !frames.isEmpty, let tool = registry.tool(id), let frame = currentFrame else { return }
        let d = UserDefaults.standard
        let height = d.object(forKey: "videoHeight") as? Int ?? 1080
        let vs = ViewportScale.shared
        let camera = OffscreenRenderer.Camera(
            yaw: vs.yaw, pitch: vs.pitch,
            distance: vs.distance > 0 ? vs.distance : 2.8, pan: vs.pan,
            orthographic: d.bool(forKey: "orthographicProjection"),
            roll: vs.roll)
        let options = VideoExporter.Options(
            width: height * 16 / 9, height: height, fps: 30, stride: 1,
            format: .mp4, annotations: d.object(forKey: "videoAnnotations") as? Bool ?? true,
            orbitDegreesPerSecond: 0, camera: camera,
            pointSize: Float(d.object(forKey: "atomPointSize") as? Double ?? 14),
            background: Renderer.backgroundColor(),
            style: ElementStyleStore.currentStyle())
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let base = sourceName.isEmpty ? "trajectory" : (sourceName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base)-\(id)-frame\(frameIndex).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let params = registry.parameters(for: id)
        let fi = frameIndex
        let traj = frames
        let ctx = makeContext(for: tool.metadata, frameIndex: fi, trajectory: trajectory,
                              referenceIndex: inspector.referenceFrame)
        DispatchQueue.global(qos: .userInitiated).async {
            let field = (try? tool.analyze(frame: frame, context: ctx, parametersJSON: params))?.field
            do {
                _ = try VideoExporter.exportPNG(frames: traj, frameIndex: fi, to: url, options: options, overlay: field)
            } catch {
                DispatchQueue.main.async { Self.alert("Snapshot failed", info: error.localizedDescription) }
            }
        }
    }
}
