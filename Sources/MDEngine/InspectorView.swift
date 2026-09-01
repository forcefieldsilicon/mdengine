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
    @AppStorage("backgroundBrightness") private var backgroundBrightness = 0.08
    @State private var backgroundColor: Color = {
        let stored = UserDefaults.standard.string(forKey: "backgroundColor") ?? "0.63 0.63 1.0"
        let p = stored.split(separator: " ").compactMap { Double($0) }
        return p.count == 3 ? Color(red: p[0], green: p[1], blue: p[2])
                            : Color(red: 0.63, green: 0.63, blue: 1.0)
    }()
    @AppStorage("timelineMajorPct") private var timelineMajorPct = 20
    @AppStorage("timelineMinorPct") private var timelineMinorPct = 5
    @AppStorage("timelineShowNumbers") private var timelineShowNumbers = true
    @AppStorage("orthographicProjection") private var orthographic = false
    @AppStorage("showScaleBar") private var showScaleBar = true
    @AppStorage("paneCount") private var paneCount = 1
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
                ZStack {
                    HStack {
                        Text("Projection")
                        Spacer()
                    }
                    Picker("", selection: $orthographic) {
                        Text("Persp.").tag(false)
                        Text("Ortho.").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 137)   // matches the Panes indicator below
                }
                ZStack {
                    HStack {
                        Text("Panes")
                        Spacer()
                    }
                    // Cumulative level indicator: panes accumulate, so
                    // selecting 3 lights 1-2-3, not just the 3.
                    HStack(spacing: 3) {
                        ForEach(1...4, id: \.self) { i in
                            Button {
                                paneCount = i
                            } label: {
                                Text("\(i)")
                                    .frame(width: 32, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(i <= paneCount ? Color.accentColor
                                                       : Color.secondary.opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .foregroundColor(i <= paneCount ? .white : .primary)
                        }
                    }
                    .help("Viewport layout: 1 = main pane only, up to a 2×2 grid. Hidden panes remember their views.")
                }
                HStack {
                    Text("Pane").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("View").font(.caption).foregroundColor(.secondary)
                        .frame(width: 110)
                    // Master scale-bar checkbox heads its own column, directly
                    // above the per-pane bar checkboxes.
                    VStack(spacing: 1) {
                        Text("Bar").font(.caption).foregroundColor(.secondary)
                        Toggle("", isOn: $showScaleBar)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help("Master switch: scale bars in every pane (exact at the structure's center depth)")
                            .onChange(of: showScaleBar) { on in
                                guard on else { return }
                                for i in 1...4 {   // re-arm every pane's bar
                                    UserDefaults.standard.set(true, forKey: "pane\(i)ScaleBar")
                                }
                            }
                    }
                    .frame(width: 30)
                }
                ForEach(1...max(1, min(4, paneCount)), id: \.self) { i in
                    PaneGroup(index: i, model: model)
                }
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
                LabeledContent("Brightness") {
                    Slider(value: $backgroundBrightness, in: 0...0.35)
                }
                LabeledContent("Background color") {
                    ColorPicker("", selection: $backgroundColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 44, alignment: .trailing)
                        .help("Background hue — Brightness sets how bright it is")
                }
                .onChange(of: backgroundColor) { c in
                    let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
                    UserDefaults.standard.set(
                        "\(n.redComponent) \(n.greenComponent) \(n.blueComponent)",
                        forKey: "backgroundColor")
                }
            }


            CollapsibleSection("Elements", key: "inspExpElements", initiallyExpanded: true) {
                let histogram = elementHistogram
                if histogram.isEmpty {
                    Text("No atoms loaded").foregroundColor(.secondary)
                } else {
                    HStack {
                        Text("Element").font(.caption).foregroundColor(.secondary)
                            .frame(width: 76, alignment: .leading)
                        Text("Size ×").font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                        Text("Count").font(.caption).foregroundColor(.secondary)
                            .frame(width: 54, alignment: .trailing)
                    }
                    ForEach(histogram.indices, id: \.self) { i in
                        ElementRow(model: model,
                                   element: histogram[i].0, count: histogram[i].1)
                            .id("\(histogram[i].0)-\(model.styleResetToken)")
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
                    model.cameraResetToken += 1   // isometric + home zoom + centered
                    ElementStyleStore.resetSizes(elements: elementNames)   // views + sizes reset; colors kept
                    model.styleGeneration += 1
                    model.styleResetToken += 1
                    orthographic = false
                    atomPointSize = 14
                    orbitSensitivity = 8
                    backgroundBrightness = 0.08
                    UserDefaults.standard.removeObject(forKey: "backgroundColor")
                    backgroundColor = Color(red: 0.63, green: 0.63, blue: 1.0)
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
                LabeledContent("Depth (Å)") {
                    if let maxP = zp.maxPenetration, let minP = zp.minPenetration,
                       let meanP = zp.meanPenetration {
                        Text(String(format: "%.2f · %.2f · %.2f", minP, meanP, maxP))
                            .monospacedDigit()
                    } else {
                        Text("—").foregroundColor(.secondary)
                    }
                }
                LabeledContent("At surface (≤\(String(format: "%.1f", ZProfileAnalysis.surfaceBand)) Å)") {
                    Text("\(zp.atSurfaceCount)").monospacedDigit()
                }
                LabeledContent("Above / in flight") { Text("\(zp.aboveCount)").monospacedDigit() }
                LabeledContent("Bound probe ⟨q⟩") {
                    if let q = zp.boundProbeMeanCharge {
                        Text(String(format: "%+.2f e", q)).monospacedDigit()
                    } else {
                        Text("—").foregroundColor(.secondary)
                    }
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
    @AppStorage private var preset: String
    @AppStorage private var scaleBar: Bool
    @AppStorage("showScaleBar") private var showScaleBar = true

    init(index: Int, model: ContentViewModel) {
        self.index = index
        self.model = model
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

    /// One flat row per VISIBLE pane (the Panes segments decide how many):
    /// name · view picker · scale-bar checkbox.
    private var headerRow: some View {
        HStack {
            Text(isMain ? "Pane 1 (main)" : "Pane \(index)")
                .lineLimit(1)
                .fixedSize()
            Spacer()
            Picker("", selection: $preset) {
                Text("Free").tag("free")
                ForEach(RenderCore.ViewPreset.allCases, id: \.rawValue) {
                    Text($0.label).tag($0.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(width: 110, alignment: .trailing)
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
    }

}

/// One element's row: color well · token · relative size slider · atom count.
/// Color and size persist per element token and apply to every pane and to
/// video export; final sprite size = global Atom size × this factor.
private struct ElementRow: View {
    @ObservedObject var model: ContentViewModel
    let element: String
    let count: Int
    @State private var color: Color
    @State private var sizeFactor: Double

    init(model: ContentViewModel, element: String, count: Int) {
        self.model = model
        self.element = element
        self.count = count
        let rgb = ElementStyleStore.color(for: element)
        _color = State(initialValue: Color(red: Double(rgb.x), green: Double(rgb.y),
                                           blue: Double(rgb.z)))
        _sizeFactor = State(initialValue:
            UserDefaults.standard.object(forKey: "elemSize.\(element)") as? Double ?? 1)
    }

    var body: some View {
        HStack {
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28)
                .onChange(of: color) { c in
                    let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
                    ElementStyleStore.setColor(SIMD3(Float(n.redComponent),
                                                     Float(n.greenComponent),
                                                     Float(n.blueComponent)), for: element)
                    model.styleGeneration += 1
                }
                .help("Atom color for \(element)")
            Text(element)
                .frame(minWidth: 40, alignment: .leading)
            Slider(value: $sizeFactor, in: 0.3...3)
                .frame(minWidth: 100, maxWidth: .infinity)
                .onChange(of: sizeFactor) { f in
                    ElementStyleStore.setSize(f, for: element)
                    model.styleGeneration += 1
                }
                .help(String(format: "Relative size ×%.2f — multiplied by the global Atom size", sizeFactor))
            Text("\(count)").monospacedDigit()
                .frame(width: 54, alignment: .trailing)
                .foregroundColor(.secondary)
        }
    }
}
