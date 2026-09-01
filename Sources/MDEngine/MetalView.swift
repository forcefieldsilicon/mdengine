import SwiftUI
import MetalKit
import LAMMPSCore

/// MTKView subclass that feeds mouse/trackpad input to the renderer:
/// Orbit: drag. Pan: double-click-drag (hold after the second click; OVITO-style).
/// Zoom: scroll or pinch. Reset: plain double-click.
final class InteractiveMTKView: MTKView {
    weak var renderer: Renderer?

    private var isPanning = false
    private var draggedSinceDown = false

    // MTKView's internal display link proved unreliable across SwiftUI window
    // re-hosting (views ended up never drawing - verified by sampling: zero
    // draw calls). Drive rendering with an explicit display link instead:
    // alive exactly while the view sits in a window.
    private var link: CADisplayLink?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPaused = true                 // never rely on the internal loop
        enableSetNeedsDisplay = false
        link?.invalidate()
        link = nil
        if window != nil {
            link = displayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
        }
    }

    @objc private func tick() {
        draw()                          // runs the delegate's render pass
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isPanning = event.clickCount >= 2
        draggedSinceDown = false
    }

    override func mouseDragged(with event: NSEvent) {
        draggedSinceDown = true
        let dx = Float(event.deltaX)
        let dy = Float(event.deltaY)
        if isPanning {
            renderer?.pan(dx: dx, dy: dy)
        } else {
            renderer?.orbit(dx: dx, dy: dy)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // A double-click that never dragged is still the camera reset.
        if isPanning && !draggedSinceDown {
            renderer?.resetCamera()
        }
        isPanning = false
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = Float(event.scrollingDeltaY)
        let step: Float = event.hasPreciseScrollingDeltas ? 0.004 : 0.06
        renderer?.zoom(byFactor: exp(dy * step))
    }

    override func magnify(with event: NSEvent) {
        renderer?.zoom(byFactor: 1 + Float(event.magnification))
    }
}

struct MetalView: NSViewRepresentable {
    let frames: [[Arv]]
    let frameIndex: Int
    let generation: Int   // bumped by the model on every file load
    let cameraResetToken: Int

    func makeNSView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()!
        let view = InteractiveMTKView(frame: .zero, device: device)

        let renderer = Renderer(view: view)
        view.delegate = renderer
        view.renderer = renderer

        context.coordinator.renderer = renderer
        // AppKit can destroy and recreate this NSView (window restoration,
        // re-hosting) while the SAME coordinator survives. A fresh renderer
        // with a stale generation counter would never receive the trajectory
        // and render blank forever - reset so the next update re-uploads.
        context.coordinator.generation = -1
        context.coordinator.cameraResetToken = cameraResetToken
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Re-upload the trajectory only when a new file was loaded; scrubbing
        // just switches frames.
        if context.coordinator.generation != generation {
            context.coordinator.renderer?.setTrajectory(frames)
            context.coordinator.generation = generation
        }
        context.coordinator.renderer?.showFrame(frameIndex)
        if context.coordinator.cameraResetToken != cameraResetToken {
            context.coordinator.cameraResetToken = cameraResetToken
            context.coordinator.renderer?.resetCamera()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var renderer: Renderer?
        var generation = -1
        var cameraResetToken = 0
    }
}
