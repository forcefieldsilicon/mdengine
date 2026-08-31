import SwiftUI
import AppKit

/// Receives Finder open-document events (double-clicked trajectories).
/// Files can arrive before SwiftUI has a view up, so URLs are buffered until
/// ContentView installs the handler.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openHandler: ((URL) -> Void)? {
        didSet { pending.forEach { openHandler?($0) }; pending.removeAll() }
    }
    private static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let handler = AppDelegate.openHandler { handler(url) }
            else { AppDelegate.pending.append(url) }
        }
    }
}

@main
struct MDEngineApp: App {
    @StateObject private var model = ContentViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Bare SwiftPM executables launch as background processes; promote to a
        // regular app so the window appears in front with a Dock presence.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        // One window: every window would share the same trajectory anyway, and
        // macOS state restoration was resurrecting confusing blank duplicates.
        Window("MDEngine", id: "main") {
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
    @AppStorage("orthographicProjection") private var orthographic = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Load File…") { model.loadFilePanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recentFiles, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        model.openRecent(path)
                    }
                    .help(path)
                }
                if !model.recentFiles.isEmpty {
                    Divider()
                    Button("Clear Menu") { model.clearRecents() }
                } else {
                    Button("No Recent Files") {}.disabled(true)
                }
            }
            Button("Export File…") { model.exportFilePanel() }
                .keyboardShortcut("e")
                .disabled(model.atoms.isEmpty)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            SettingsLink { Text("Application Settings…") }
                .keyboardShortcut(",")
        }
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") {
                model.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("Orthographic Projection", isOn: $orthographic)
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
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
