import SwiftUI
import LAMMPSCore

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

    // Z-profile element roles; re-defaulted whenever the loaded element set changes.
    @State private var zSubstrate = ""
    @State private var zProbe = ""

    var body: some View {
        Form {
            Section("View") {
                Picker("Projection", selection: $orthographic) {
                    Text("Perspective").tag(false)
                    Text("Orthographic").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Scale bar", isOn: $showScaleBar)
                    .help("Show a length reference in the viewport (exact at the structure's center depth)")
            }

            Section("Timeline grid") {
                Picker("Major marks", selection: $timelineMajorPct) {
                    ForEach([10, 20, 25, 50], id: \.self) { Text("every \($0)%").tag($0) }
                }
                Picker("Minor marks", selection: $timelineMinorPct) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("every \($0)%").tag($0) }
                }
                Toggle("Frame numbers", isOn: $timelineShowNumbers)
            }

            Section("Display") {
                LabeledContent("Atom size") {
                    Slider(value: $atomPointSize, in: 4...32)
                }
                LabeledContent("Background") {
                    Slider(value: $backgroundBrightness, in: 0...0.35)
                }
            }

            Section("Camera") {
                LabeledContent("Orbit speed") {
                    Slider(value: $orbitSensitivity, in: 2...20)
                }
                Button("Reset Camera") { model.cameraResetToken += 1 }
            }

            Section("Elements") {
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

            Section("Z-profile") {
                zProfileSection
            }

            Section {
                Button("Restore Defaults") {
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
                    LabeledContent("Depth min · mean · max") {
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
