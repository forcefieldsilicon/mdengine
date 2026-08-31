import SwiftUI
import AppKit

@main
struct MDEngineApp: App {
    @StateObject private var model = ContentViewModel()

    init() {
        // Bare SwiftPM executables launch as background processes; promote to a
        // regular app so the window appears in front with a Dock presence.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
        }
    }
}

/// Menu bar: MDEngine · File (Load/Export) · Edit (Application Settings…) · Help (User Manual).
struct AppCommands: Commands {
    @ObservedObject var model: ContentViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Load File…") { model.loadFilePanel() }
                .keyboardShortcut("o")
            Button("Export File…") { model.exportFilePanel() }
                .keyboardShortcut("e")
                .disabled(model.atoms.isEmpty)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            SettingsLink { Text("Application Settings…") }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .help) {
            Button("MDEngine User Manual") {
                let bundled = Bundle.main.resourceURL?
                    .appendingPathComponent("doc/manual/html/index.html")
                let fallback = URL(fileURLWithPath:
                    "/Applications/MDEngine/Contents/Resources/doc/manual/html/index.html")
                let manual = bundled.flatMap {
                    FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
                } ?? fallback
                NSWorkspace.shared.open(manual)
            }
        }
    }
}
