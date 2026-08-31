import SwiftUI

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

    var body: some View {
        Form {
            Section("View") {
                Picker("Projection", selection: $orthographic) {
                    Text("Perspective").tag(false)
                    Text("Orthographic").tag(true)
                }
                .pickerStyle(.segmented)
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

            Section {
                Button("Restore Defaults") {
                    orthographic = false
                    atomPointSize = 14
                    orbitSensitivity = 8
                    backgroundBrightness = 0.05
                    timelineMajorPct = 20
                    timelineMinorPct = 5
                    timelineShowNumbers = true
                }
            }
        }
        .formStyle(.grouped)
    }

    private var elementHistogram: [(String, Int)] {
        var histogram: [String: Int] = [:]
        for a in model.atoms { histogram[a.element, default: 0] += 1 }
        return histogram.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { ($0.key, $0.value) }
    }
}
