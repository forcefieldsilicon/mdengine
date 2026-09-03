import SwiftUI
import LAMMPSCore
import MDRender

struct ContentView: View {
    @ObservedObject var model: ContentViewModel
    @AppStorage("showScaleBar") private var showScaleBar = true
    @AppStorage("pane1ScaleBar") private var pane1ScaleBar = true
    @AppStorage("paneCount") private var paneCount = 1
    @AppStorage("pane2Preset") private var pane2Preset = "top"
    @AppStorage("pane3Preset") private var pane3Preset = "left"
    @AppStorage("pane4Preset") private var pane4Preset = "front"

    var body: some View {
        VStack(spacing: 0) {
            viewportArea
                .frame(minWidth: 600, minHeight: 600)

            if model.frames.count > 1 {
                HStack(alignment: .center, spacing: 14) {
                    VStack(spacing: 3) {
                        Slider(value: $model.playbackFPS, in: 1...60, step: 1)
                            .controlSize(.mini)
                            .frame(width: 72)
                            .help("Playback speed: \(Int(model.playbackFPS)) frames/s")
                        Text("\(Int(model.playbackFPS)) f/s")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.secondary)
                        Button {
                            model.togglePlayback()
                        } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .frame(width: 22)
                        }
                        .buttonStyle(.bordered)
                        .help(model.isPlaying ? "Pause playback" : "Play through the trajectory")
                        Toggle("Loop", isOn: $model.loopPlayback)
                            .toggleStyle(.checkbox)
                            .controlSize(.mini)
                            .help("Repeat from the first frame when playback reaches the end")
                    }
                    TrajectoryScrubber(frameCount: model.frames.count,
                                       index: $model.frameIndex)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            summaryBar
        }
        .navigationTitle(model.sourceName.isEmpty ? "MDEngine" : model.sourceName)
        .toolbar {
            // Top-right, Xcode-style: full-size toolbar button with the system
            // rounded background, instead of a small icon buried in the status bar.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Hide or show the Inspector (⌥⌘I)")
            }
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 320, ideal: 340, max: 460)
        }
        .onAppear {
            AppDelegate.openHandler = { [weak model] url in model?.load(url: url) }
            model.runSimulationAndDisplayResults()
        }
    }

    /// Extra panes chosen in Inspector ▸ View (CAD-style Top/Front/Rear/Bottom).
    struct ExtraPane: Identifiable {
        let id: Int
        let preset: RenderCore.ViewPreset?   // nil = free camera
    }

    private var extraPanes: [ExtraPane] {
        let presets = [pane2Preset, pane3Preset, pane4Preset]
        return (2...max(2, min(4, paneCount)))
            .compactMap { paneCount >= $0 ? $0 : nil }
            .map { ExtraPane(id: $0, preset: RenderCore.ViewPreset(rawValue: presets[$0 - 2])) }
    }

    @ViewBuilder private var viewportArea: some View {
        let extras = extraPanes
        if extras.isEmpty {
            mainPane
        } else {
            // 2-up: side by side; 3-4 views: 2x2 grid, main pane top-left.
            // Explicit rows, not LazyVGrid: Metal views have no intrinsic
            // size, so a lazy grid collapses every row after the first.
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    mainPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    extraPane(extras[0]).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if extras.count >= 2 {
                    HStack(spacing: 2) {
                        extraPane(extras[1]).frame(maxWidth: .infinity, maxHeight: .infinity)
                        if extras.count >= 3 {
                            extraPane(extras[2]).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func extraPane(_ pane: ExtraPane) -> some View {
        ExtraPaneView(model: model, pane: pane)
    }

    private var mainPane: some View {
        MetalView(frames: model.frames,
                  frameIndex: model.frameIndex,
                  generation: model.generation,
                  cameraResetToken: model.cameraResetToken,
                  preset: model.pendingViewPreset,
                  presetToken: model.viewPresetToken,
                  styleGeneration: model.styleGeneration)
            .overlay(alignment: .bottomLeading) {
                if showScaleBar && pane1ScaleBar && !model.atoms.isEmpty {
                    GeometryReader { geo in
                        ScaleBarView(viewportHeight: geo.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomLeading)
                            .padding(12)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if !model.atoms.isEmpty { viewMenu.padding(10) }
            }
    }

    /// CAD-style view snap (the AutoCAD-cube idea, menu form): Top/Front/… set
    /// the camera to a canonical angle; orbiting afterwards returns to free view.
    @AppStorage("pane1Preset") private var pane1Preset = "free"

    private var viewMenu: some View {
        Menu {
            Button("Isometric") { snap(.isometric) }
            Menu("Planes") {
                Button("Top") { snap(.top) }
                Button("Bottom") { snap(.bottom) }
                Button("Front") { snap(.front) }
                Button("Rear") { snap(.rear) }
                Button("Left") { snap(.left) }
            }
            Divider()
            Button("Reset Camera") {
                model.cameraResetToken += 1
                pane1Preset = "free"
            }
        } label: {
            Label("View", systemImage: "cube")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .foregroundColor(.white.opacity(0.9))
        .help("Snap the camera: Isometric, or a plane view (Top/Bottom/Front/Rear/Left)")
    }

    private func snap(_ preset: RenderCore.ViewPreset) {
        model.applyViewPreset(preset)
        pane1Preset = preset.rawValue
    }

    private var summaryBar: some View {
        let total = model.atoms.count
        var histogram: [String: Int] = [:]
        for a in model.atoms { histogram[a.element, default: 0] += 1 }
        let top: [(String, Int)] = histogram.sorted {
            ($0.value, $1.key) > ($1.value, $0.key)   // by count desc, name asc
        }.prefix(3).map { ($0.key, $0.value) }
        return HStack(spacing: 16) {
            Text("\(total) atoms").bold()
            ForEach(top.indices, id: \.self) { i in
                Label("\(top[i].1) \(top[i].0)", systemImage: "circle.fill")
                    .foregroundColor(ElementColors.color(for: top[i].0))
            }
            Spacer()
            if model.isFollowingFile {
                Label("live", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundColor(.green)
                    .help("Following the file: frames a running simulation appends show up automatically")
            }
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(total == 0
                 ? "Loading trajectory…"
                 : "\(model.sourceName) · Orbit: drag · Pan: double-click- or two-finger-drag · Zoom: scroll")
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One extra viewport pane: its own camera-state publisher so its scale bar
/// tracks its own zoom, plus its own scale-bar preference.
private struct ExtraPaneView: View {
    @ObservedObject var model: ContentViewModel
    let pane: ContentView.ExtraPane
    @StateObject private var paneScale = ViewportScale()
    @AppStorage("showScaleBar") private var showScaleBar = true
    @AppStorage private var paneScaleBar: Bool

    init(model: ContentViewModel, pane: ContentView.ExtraPane) {
        self.model = model
        self.pane = pane
        _paneScaleBar = AppStorage(wrappedValue: true, "pane\(pane.id)ScaleBar")
    }

    var body: some View {
        MetalView(frames: model.frames,
                  frameIndex: model.frameIndex,
                  generation: model.generation,
                  cameraResetToken: model.cameraResetToken,
                  preset: pane.preset,
                  styleGeneration: model.styleGeneration,
                  scaleSink: paneScale)
            .overlay(alignment: .topLeading) {
                Text(pane.preset?.label ?? "Free")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if showScaleBar && paneScaleBar && !model.atoms.isEmpty {
                    GeometryReader { geo in
                        ScaleBarView(viewportHeight: geo.size.height, scale: paneScale)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomLeading)
                            .padding(12)
                    }
                }
            }
    }
}

/// Bottom timeline: drag to scrub through trajectory frames.
/// Grid is user-configurable in the inspector (defaults: major tick every 20%
/// of the trajectory, minor every 5%) with frame numbers under major ticks.
struct TrajectoryScrubber: View {
    let frameCount: Int
    @Binding var index: Int

    @AppStorage("timelineMajorPct") private var majorPct = 20
    @AppStorage("timelineMinorPct") private var minorPct = 5
    @AppStorage("timelineShowNumbers") private var showNumbers = true

    private let thumbSize: CGFloat = 14
    private let trackY: CGFloat = 12

    private func frameNumber(atPercent p: Int) -> Int {
        Int((Double(p) / 100 * Double(frameCount - 1)).rounded()) + 1
    }

    var body: some View {
        let major = max(1, majorPct)
        let minor = max(1, min(minorPct, major))
        HStack(spacing: 12) {
            Text("frame \(index + 1)/\(frameCount)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)

            GeometryReader { geo in
                let usable = max(1, geo.size.width - thumbSize)
                let fraction = frameCount > 1 ? CGFloat(index) / CGFloat(frameCount - 1) : 0

                ZStack(alignment: .topLeading) {
                    // Track
                    Capsule()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: usable, height: 4)
                        .position(x: thumbSize / 2 + usable / 2, y: trackY)
                    // Progress fill up to the thumb
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, usable * fraction), height: 4)
                        .position(x: thumbSize / 2 + usable * fraction / 2, y: trackY)
                    // Grid ticks + frame numbers under major ticks
                    ForEach(Array(stride(from: 0, through: 100, by: minor)), id: \.self) { p in
                        let isMajor = p % major == 0
                        let x = thumbSize / 2 + usable * CGFloat(p) / 100
                        Rectangle()
                            .fill(Color.secondary.opacity(isMajor ? 0.75 : 0.4))
                            .frame(width: isMajor ? 2 : 1, height: isMajor ? 14 : 7)
                            .position(x: x, y: trackY)
                        if isMajor && showNumbers {
                            Text("\(frameNumber(atPercent: p))")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundColor(.secondary)
                                .position(x: x, y: trackY + 16)
                        }
                    }
                    // Thumb
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .frame(width: thumbSize, height: thumbSize)
                        .position(x: thumbSize / 2 + usable * fraction, y: trackY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let f = min(max((g.location.x - thumbSize / 2) / usable, 0), 1)
                            index = Int((f * CGFloat(frameCount - 1)).rounded())
                        }
                )
            }
            .frame(height: showNumbers ? 34 : 24)
            .accessibilityElement()
            .accessibilityLabel("Trajectory timeline")
            .accessibilityValue("frame \(index + 1) of \(frameCount)")
        }
    }
}
