import SwiftUI
import LAMMPSCore

struct ContentView: View {
    @ObservedObject var model: ContentViewModel

    var body: some View {
        VStack(spacing: 0) {
            MetalView(frames: model.frames,
                      frameIndex: model.frameIndex,
                      generation: model.generation)
                .frame(minWidth: 600, minHeight: 600)

            if model.frames.count > 1 {
                TrajectoryScrubber(frameCount: model.frames.count,
                                   index: $model.frameIndex)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            summaryBar
        }
        .onAppear {
            model.runSimulationAndDisplayResults()
        }
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
            Text(total == 0
                 ? "Loading trajectory…"
                 : "\(model.sourceName) · drag orbit · double-click-hold pan · scroll zoom")
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Bottom timeline: drag to scrub through trajectory frames.
/// Major tick every 20% of the trajectory, minor tick every 5%.
struct TrajectoryScrubber: View {
    let frameCount: Int
    @Binding var index: Int

    private let thumbSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 12) {
            Text("frame \(index + 1)/\(frameCount)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)

            GeometryReader { geo in
                let usable = max(1, geo.size.width - thumbSize)
                let midY = geo.size.height / 2
                let fraction = frameCount > 1 ? CGFloat(index) / CGFloat(frameCount - 1) : 0

                ZStack(alignment: .topLeading) {
                    // Track
                    Capsule()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: usable, height: 4)
                        .position(x: thumbSize / 2 + usable / 2, y: midY)
                    // Progress fill up to the thumb
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(2, usable * fraction), height: 4)
                        .position(x: thumbSize / 2 + usable * fraction / 2, y: midY)
                    // Ticks: 5% minor, 20% major
                    ForEach(0...20, id: \.self) { t in
                        let major = t % 4 == 0
                        Rectangle()
                            .fill(Color.secondary.opacity(major ? 0.75 : 0.4))
                            .frame(width: major ? 2 : 1, height: major ? 14 : 7)
                            .position(x: thumbSize / 2 + usable * CGFloat(t) / 20, y: midY)
                    }
                    // Thumb
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .frame(width: thumbSize, height: thumbSize)
                        .position(x: thumbSize / 2 + usable * fraction, y: midY)
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
            .frame(height: 24)
            .accessibilityElement()
            .accessibilityLabel("Trajectory timeline")
            .accessibilityValue("frame \(index + 1) of \(frameCount)")
        }
    }
}
