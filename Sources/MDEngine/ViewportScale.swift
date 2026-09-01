import Foundation
import Combine
import simd

/// Camera facts the SwiftUI layer needs for the on-screen scale bar, published
/// by the renderer (zoom / camera reset / trajectory load). Values change
/// outside SwiftUI's view updates, so mutations hop through the main queue.
final class ViewportScale: ObservableObject {
    static let shared = ViewportScale()

    /// Camera distance in model units (renderer's orbit radius).
    @Published var distance: Float = 0
    /// Ångströms per model unit (inverse of the trajectory normalization).
    @Published var angstromsPerModelUnit: Float = 0
    /// Full camera pose of the primary view — video export renders with it.
    @Published var yaw: Float = 0
    @Published var pitch: Float = 0
    @Published var pan = SIMD2<Float>(0, 0)
    @Published var roll: Float = 0

    func update(distance: Float, angstromsPerModelUnit: Float,
                yaw: Float, pitch: Float, pan: SIMD2<Float>, roll: Float) {
        guard distance != self.distance
                || angstromsPerModelUnit != self.angstromsPerModelUnit
                || yaw != self.yaw || pitch != self.pitch || pan != self.pan
                || roll != self.roll else { return }
        DispatchQueue.main.async {
            self.distance = distance
            self.angstromsPerModelUnit = angstromsPerModelUnit
            self.yaw = yaw
            self.pitch = pitch
            self.pan = pan
            self.roll = roll
        }
    }
}
