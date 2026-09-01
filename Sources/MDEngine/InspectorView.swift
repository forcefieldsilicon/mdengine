import SwiftUI
import LAMMPSCore
import MDRender

/// Right-side inspector (⌥⌘I or the sidebar button): display, camera, and
/// timeline-grid customization, plus a legend of the loaded elements.
/// Shares its UserDefaults keys with the Settings window and the renderer,
/// so every change applies live.
struct InspectorView: View {
    @ObservedObject var model: ContentViewModel

    @AppStorage("atomPointSize") private var atomPointSize = 14.0
    @AppStorage("orbitSensitivity") private var orbitSensitivity = 8.0
    @AppStorage("backgroundBrightness") private var backgroundBrightness = 0.05
    @AppStorage("timelineMajorPct") private var timelineMajorPct = 20
    @AppStorage("timelineMinorPct") private var timelineMinorPct = 5
    @AppStorage("timelineShowNumbers") private var timelineShowNumbers = true
    @AppStorage("orthographicProjection") private var orthographic = false
    @AppStorage("showScaleBar") private var showScaleBar = true
    @AppStorage("videoHeight") private var videoHeight = 1080
    @AppStorage("videoFPS") private var videoFPS = 30
    @AppStorage("videoStride") private var videoStride = 0
    @AppStorage("videoAnnotations") private var videoAnnotations = true
    @AppStorage("videoOrbit") private var videoOrbit = false
    @AppStorage("videoOrbitSpeed") private var videoOrbitSpeed = 6.0

    // Z-profile element roles; re-defaulted whenever the loaded element set changes.
    @State private var zSubstrate = ""
    @State private var zProbe = ""

    var body: some View {
        Form {
            CollapsibleSection("View", key: "inspExpView", initiallyExpanded: true) {
                Picker("Projection", selection: $orthographic) {
                    Text("Perspective").tag(false)
                    Text("Orthographic").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Scale bar", isOn: $showScaleBar)
                    .toggleStyle(.checkbox)
                    .help("Master switch: show a length reference in every pane (exact at the structure's center depth). Each pane keeps its own checkbox under its options.")
                    .onChange(of: showScaleBar) { on in
                        guard on else { return }
                        for i in 1...4 {   // re-arm every pane's bar
                            UserDefaults.standard.set(true, forKey: "pane\(i)ScaleBar")
                        }
                    }
                HStack {
                    Text("Pane").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("View").font(.caption).foregroundColor(.secondary)
                        .frame(width: 110)
                    Text("Bar").font(.caption).foregroundColor(.secondary)
                        .frame(width: 30)
                        .help("Scale bar in this pane")
                    Text("On").font(.caption).foregroundColor(.secondary)
                        .frame(width: 34)
                }
                PaneGroup(index: 1, model: model)
                PaneGroup(index: 2, model: model)
                PaneGroup(index: 3, model: model)
                PaneGroup(index: 4, model: model)
            }

            CollapsibleSection("Camera", key: "inspExpCamera", initiallyExpanded: false) {
                LabeledContent("Orbit speed") {
                    Slider(value: $orbitSensitivity, in: 2...20)
                }
                Button("Reset Camera") { model.cameraResetToken += 1 }
            }


            CollapsibleSection("Timeline grid", key: "inspExpTimeline", initiallyExpanded: false) {
                Picker("Major marks", selection: $timelineMajorPct) {
                    ForEach([10, 20, 25, 50], id: \.self) { Text("every \($0)%").tag($0) }
                }
                Picker("Minor marks", selection: $timelineMinorPct) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("every \($0)%").tag($0) }
                }
                Toggle("Frame numbers", isOn: $timelineShowNumbers)
            }

            CollapsibleSection("Display", key: "inspExpDisplay", initiallyExpanded: false) {
                LabeledContent("Atom size") {
                    Slider(value: $atomPointSize, in: 4...32)
                }
                LabeledContent("Background") {
                    Slider(value: $backgroundBrightness, in: 0...0.35)
                }
            }


            CollapsibleSection("Elements", key: "inspExpElements", initiallyExpanded: true) {
                let histogram = elementHistogram
                if histogram.isEmpty {
                    Text("No atoms loaded").foregroundColor(.secondary)
                } else {
                    ForEach(histogram.indices, id: \.self) { i in
                        LabeledContent {
                            Text("\(histogram[i].1)").monospacedDigit()
                        } label: {
                            Label(histogram[i].0, systemImage: "circle.fill")
                                .foregroundColor(ElementColors.color(for: histogram[i].0))
                        }
                    }
                }
            }

            CollapsibleSection("Z-profile", key: "inspExpZProfile", initiallyExpanded: false) {
                zProfileSection
            }

            CollapsibleSection("Video export", key: "inspExpVideo", initiallyExpanded: false) {
                Picker("Resolution", selection: $videoHeight) {
                    Text("1080p").tag(1080)
                    Text("1440p").tag(1440)
                    Text("4K").tag(2160)
                }
                Picker("Frame rate", selection: $videoFPS) {
                    ForEach([24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Stride", selection: $videoStride) {
                    Text("auto (≈15 s)").tag(0)
                    ForEach([1, 2, 5, 10, 20], id: \.self) { Text("every \($0)").tag($0) }
                }
                if model.frames.count > 1 {
                    LabeledContent("Video length") {
                        Text(videoDurationText).monospacedDigit()
                    }
                }
                Toggle("Annotations", isOn: $videoAnnotations)
                    .help("Bake the scale bar and frame counter into the video")
                Toggle("Cinematic orbit", isOn: $videoOrbit)
                    .help("Slowly rotate the camera while the trajectory plays")
                if videoOrbit {
                    LabeledContent("Orbit speed") {
                        Slider(value: $videoOrbitSpeed, in: 1...30)
                            .help("\(Int(videoOrbitSpeed))°/s")
                    }
                }
                if let progress = model.exportProgress {
                    HStack {
                        ProgressView(value: progress)
                        Button("Cancel") { model.cancelVideoExport() }
                            .controlSize(.small)
                    }
                } else {
                    HStack {
                        Button("Export MP4…") { model.exportVideo(format: .mp4) }
                        Button("Export GIF…") { model.exportVideo(format: .gif) }
                            .help("Web-sized: 640×360, ≤15 fps — right for a README")
                    }
                    .disabled(model.frames.count < 2)
                }
            }

            Section {
                Button("Restore Defaults") {
                    // Reset each pane's VIEW to factory (Isometric/Top/Left/
                    // Front) but leave which panes are on/off alone.
                    let d = UserDefaults.standard
                    for i in 1...4 {
                        d.set(PaneGroup.defaultPreset(i), forKey: "pane\(i)Preset")
                    }
                    model.applyViewPreset(.isometric)
                    orthographic = false
                    atomPointSize = 14
                    orbitSensitivity = 8
                    backgroundBrightness = 0.05
                    timelineMajorPct = 20
                    timelineMinorPct = 5
                    timelineShowNumbers = true
                    showScaleBar = true
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { defaultZElements() }
        .onChange(of: elementNames) { _ in defaultZElements() }
    }

    private var videoDurationText: String {
        let fps = max(1, videoFPS)
        let stride = videoStride > 0 ? videoStride
            : VideoExporter.autoStride(frameCount: model.frames.count, fps: fps)
        let outFrames = (model.frames.count + stride - 1) / stride
        let seconds = Double(outFrames) / Double(fps)
        return String(format: "%d frames · %.1f s", outFrames, seconds)
    }

    // MARK: - Z-profile (surface plane + penetration depths along z)

    private var elementNames: [String] { elementHistogram.map(\.0) }

    private func defaultZElements() {
        let names = elementNames
        guard !names.contains(zSubstrate) || !names.contains(zProbe) || zSubstrate == zProbe else { return }
        if let d = ZProfileAnalysis.defaultElements(for: model.atoms) {
            zSubstrate = d.substrate
            zProbe = d.probe
        }
    }

    @ViewBuilder private var zProfileSection: some View {
        let names = elementNames
        if names.count < 2 {
            Text("Needs two elements (substrate + deposited species)")
                .foregroundColor(.secondary)
        } else {
            Picker("Substrate", selection: $zSubstrate) {
                ForEach(names, id: \.self) { Text($0) }
            }
            Picker("Probe", selection: $zProbe) {
                ForEach(names, id: \.self) { Text($0) }
            }
            if let zp = ZProfileAnalysis(frame: model.atoms,
                                         substrate: zSubstrate, probe: zProbe) {
                LabeledContent("Surface plane") { Text(String(format: "z = %.1f Å", zp.surfaceZ)).monospacedDigit() }
                LabeledContent("Penetrated") { Text("\(zp.penetrations.count)").monospacedDigit() }
                if let maxP = zp.maxPenetration, let minP = zp.minPenetration, let meanP = zp.meanPenetration {
                    LabeledContent("Depth (Å)") {
                        Text(String(format: "%.2f · %.2f · %.2f Å", minP, meanP, maxP))
                            .monospacedDigit()
                    }
                }
                LabeledContent("At surface (≤\(String(format: "%.1f", ZProfileAnalysis.surfaceBand)) Å)") {
                    Text("\(zp.atSurfaceCount)").monospacedDigit()
                }
                LabeledContent("Above / in flight") { Text("\(zp.aboveCount)").monospacedDigit() }
                if let q = zp.boundProbeMeanCharge {
                    LabeledContent("Bound probe ⟨q⟩") { Text(String(format: "%+.2f e", q)).monospacedDigit() }
                }
                zHistogram(zp)
            } else if zSubstrate == zProbe {
                Text("Pick two different elements").foregroundColor(.secondary)
            }
        }
    }

    /// Mini histogram of probe z relative to the surface plane (▼ left of the
    /// dashed line = penetrated; right = above the surface).
    private func zHistogram(_ zp: ZProfileAnalysis) -> some View {
        let maxCount = max(1, zp.histogram.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(zp.histogram.indices, id: \.self) { i in
                    let bin = zp.histogram[i]
                    let penetratedBin = bin.range.upperBound <= 0.01
                    Rectangle()
                        .fill(penetratedBin ? Color.orange : Color.accentColor.opacity(0.7))
                        .frame(height: max(2, 36 * CGFloat(bin.count) / CGFloat(maxCount)))
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .help(String(format: "%.1f…%.1f Å rel. surface: %d",
                                     bin.range.lowerBound, bin.range.upperBound, bin.count))
                }
            }
            .frame(height: 38, alignment: .bottom)
            HStack {
                Text("◀ deeper").font(.system(size: 9)).foregroundColor(.orange)
                Spacer()
                Text("above surface ▶").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }

    private var elementHistogram: [(String, Int)] {
        var histogram: [String: Int] = [:]
        for a in model.atoms { histogram[a.element, default: 0] += 1 }
        return histogram.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { ($0.key, $0.value) }
    }
}

/// Inspector group that expands/collapses on click, with a visible chevron.
/// Expansion state persists per section across launches.
private struct CollapsibleSection<Content: View>: View {
    private let title: String
    @AppStorage private var expanded: Bool
    @ViewBuilder private let content: () -> Content

    init(_ title: String, key: String, initiallyExpanded: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _expanded = AppStorage(wrappedValue: initiallyExpanded, key)
        self.content = content
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                content()
            } label: {
                Text(title).font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { expanded.toggle() } }
            }
        }
    }
}

/// One viewport pane's controls: chevron-expandable, with an on/off toggle
/// and its view preset underneath. Pane 1 is the main viewport (always on).
private struct PaneGroup: View {
    let index: Int
    @ObservedObject var model: ContentViewModel
    @AppStorage private var expanded: Bool
    @AppStorage private var enabled: Bool
    @AppStorage private var preset: String
    @AppStorage private var scaleBar: Bool
    @AppStorage("showScaleBar") private var showScaleBar = true

    init(index: Int, model: ContentViewModel) {
        self.index = index
        self.model = model
        _expanded = AppStorage(wrappedValue: false, "pane\(index)Expanded")
        _enabled = AppStorage(wrappedValue: index == 1, "pane\(index)Enabled")
        _preset = AppStorage(wrappedValue: PaneGroup.defaultPreset(index), "pane\(index)Preset")
        _scaleBar = AppStorage(wrappedValue: true, "pane\(index)ScaleBar")
    }

    private var isMain: Bool { index == 1 }

    /// Factory defaults: main = Isometric; panes 2/3/4 = Top/Left/Front.
    static func defaultPreset(_ index: Int) -> String {
        switch index {
        case 1: return "isometric"
        case 3: return "left"
        case 4: return "front"
        default: return "top"
        }
    }

    var body: some View {
        // An OFF pane is a single plain row (name + switch) — its view picker
        // only appears once the pane is on, so the panel stays uncluttered.
        headerRow
    }

    /// One flat row per pane: name · view picker · scale-bar checkbox · on/off
    /// switch. Controls appear only while the pane is on, so off panes stay
    /// minimal; the "Bar" checkbox obeys the master Scale bar checkbox above.
    private var headerRow: some View {
        HStack {
            Text(isMain ? "Pane 1 (main)" : "Pane \(index)")
                .lineLimit(1)
                .fixedSize()
            Spacer()
            if isMain || enabled {
                Picker("", selection: $preset) {
                    Text("Free").tag("free")
                    ForEach(RenderCore.ViewPreset.allCases, id: \.rawValue) {
                        Text($0.label).tag($0.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .onChange(of: preset) { value in
                    if isMain, let p = RenderCore.ViewPreset(rawValue: value) {
                        model.applyViewPreset(p)
                    }
                }
                Toggle("", isOn: $scaleBar)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!showScaleBar)
                    .frame(width: 30)
                    .help(showScaleBar ? "Show the scale bar in this pane"
                                       : "Turn on the master Scale bar checkbox above first")
            }
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(isMain)
                .frame(width: 34)
                .help(isMain ? "Pane 1 is the main viewport — always on"
                             : "Show this pane in the viewport grid")
        }
    }

}
