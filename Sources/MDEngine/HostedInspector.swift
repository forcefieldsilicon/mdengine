import SwiftUI
import AppKit

/// Hosts the inspector in its OWN NSHostingView — a separate SwiftUI view
/// graph — so the main window's per-tick layout pass cannot reach the Form.
///
/// Measured 2026-09-08 (design §1b): with the Form in the window's graph,
/// every playback tick re-laid out all visible inspector rows even though
/// none of them changed — 30 fps fell to 17 draws/s with the View, Elements
/// and Z-profile sections expanded, 27–30 with fewer rows. The cost scaled
/// with visible rows, not with what changed, i.e. it was the shared layout
/// pass, not the inspector's content. An NSHostingView is an opaque NSView
/// to the window graph; its inner graph lays out only when its own state
/// (InspectorState, @AppStorage) changes.
struct HostedInspector: NSViewRepresentable {
    let model: ContentViewModel

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let root = AnyView(InspectorView(model: model, state: model.inspector).equatable())
        let host = NSHostingView(rootView: root)
        // Fill the pane; never push an intrinsic size back into the window.
        host.sizingOptions = []
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
        return host
    }

    func updateNSView(_ nsView: NSHostingView<AnyView>, context: Context) {
        // Nothing: the inspector reads its state through InspectorState and
        // @AppStorage; replacing rootView here would re-run the whole Form.
    }
}
