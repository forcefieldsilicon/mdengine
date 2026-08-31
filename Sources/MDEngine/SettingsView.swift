import SwiftUI

/// Edit ▸ Application Settings…  Values persist in UserDefaults; the renderer
/// reads them every frame, so changes apply live.
struct SettingsView: View {
    @AppStorage("atomPointSize") private var atomPointSize = 14.0
    @AppStorage("orbitSensitivity") private var orbitSensitivity = 8.0
    @AppStorage("backgroundBrightness") private var backgroundBrightness = 0.05

    var body: some View {
        Form {
            Slider(value: $atomPointSize, in: 4...32) {
                Text("Atom size")
            }
            Slider(value: $orbitSensitivity, in: 2...20) {
                Text("Orbit speed")
            }
            Slider(value: $backgroundBrightness, in: 0...0.35) {
                Text("Background")
            }
            HStack {
                Spacer()
                Button("Restore Defaults") {
                    atomPointSize = 14
                    orbitSensitivity = 8
                    backgroundBrightness = 0.05
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
