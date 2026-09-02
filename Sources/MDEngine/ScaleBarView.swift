import SwiftUI
import MDRender

/// On-viewport scale bar (toggle: Inspector ▸ View ▸ Scale bar). Length snaps
/// to a round Ångström value (1/2/5 × 10ⁿ) sized to stay 60–150 pt wide.
/// Exact at the structure's center depth; in perspective, nearer/farther atoms
/// deviate slightly (orthographic is depth-true everywhere).
struct ScaleBarView: View {
    @ObservedObject var scale: ViewportScale
    let viewportHeight: CGFloat

    init(viewportHeight: CGFloat, scale: ViewportScale = .shared) {
        self.viewportHeight = viewportHeight
        self.scale = scale
    }

    private var angstromsPerPoint: Double? {
        guard scale.distance > 0, scale.angstromsPerModelUnit > 0,
              viewportHeight > 0 else { return nil }
        // Visible model-space height at the camera target, per the renderer's
        // projection (fovY π/4; orthographic matches it by construction).
        let visibleModel = 2 * Double(scale.distance) * tan(Double.pi / 8)
        return visibleModel * Double(scale.angstromsPerModelUnit) / Double(viewportHeight)
    }

    var body: some View {
        if let perPoint = angstromsPerPoint {
            let nice = RenderCore.niceLength(targetAngstroms: 100 * perPoint)
            let width = CGFloat(nice / perPoint)
            VStack(alignment: .leading, spacing: 3) {
                Text(nice >= 10_000 ? String(format: "%.1f µm", nice / 10_000)
                     : nice == nice.rounded() ? String(format: "%.0f Å", nice)
                     : String(format: "%.1f Å", nice))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.9))
                ZStack(alignment: .leading) {
                    Rectangle().frame(width: width, height: 2)
                    Rectangle().frame(width: 2, height: 8)
                    Rectangle().frame(width: 2, height: 8).offset(x: width - 2)
                }
                .foregroundColor(.white.opacity(0.9))
            }
            .padding(8)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .allowsHitTesting(false)
        }
    }
}
