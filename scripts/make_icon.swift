// Draws the MDEngine icon: three shaded atoms on a dark rounded square.
import AppKit

let S: CGFloat = 1024
let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-rect ground, deep blue-black like the render view.
let inset: CGFloat = S * 0.06
let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: S * 0.18, yRadius: S * 0.18)
NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.09, alpha: 1).setFill()
bg.fill()

func atom(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ color: NSColor) {
    let grad = NSGradient(colors: [
        color.blended(withFraction: 0.45, of: .white)!,
        color,
        color.blended(withFraction: 0.55, of: .black)!,
    ])!
    let circle = NSBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    grad.draw(in: circle, relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))
}

let silver = NSColor(calibratedRed: 0.75, green: 0.76, blue: 0.80, alpha: 1)
let red = NSColor(calibratedRed: 0.85, green: 0.22, blue: 0.18, alpha: 1)
atom(S * 0.38, S * 0.40, S * 0.230, silver)
atom(S * 0.66, S * 0.56, S * 0.185, silver)
atom(S * 0.52, S * 0.71, S * 0.130, red)

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
