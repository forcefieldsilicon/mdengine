import Foundation
import Combine

/// Camera facts the SwiftUI layer needs for the on-screen scale bar, published
/// by the renderer (zoom / camera reset / trajectory load). Values change
/// outside SwiftUI's view updates, so mutations hop through the main queue.
final class ViewportScale: ObservableObject {
    static let shared = ViewportScale()

    /// Camera distance in model units (renderer's orbit radius).
    @Published var distance: Float = 0
    /// Ångströms per model unit (inverse of the trajectory normalization).
    @Published var angstromsPerModelUnit: Float = 0

    func update(distance: Float, angstromsPerModelUnit: Float) {
        guard distance != self.distance
                || angstromsPerModelUnit != self.angstromsPerModelUnit else { return }
        DispatchQueue.main.async {
            self.distance = distance
            self.angstromsPerModelUnit = angstromsPerModelUnit
        }
    }
}
