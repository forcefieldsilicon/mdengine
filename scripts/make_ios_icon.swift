// make_ios_icon.swift — turn the macOS AppIcon.icns artwork into an App Store-legal iOS app icon.
//
//   iconutil -c iconset scripts/AppIcon.icns -o /tmp/i.iconset
//   swift scripts/make_ios_icon.swift /tmp/i.iconset/icon_512x512@2x.png \
//       ios/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png 0.90
//
// Why this is not just a copy of the macOS icon:
//   * macOS icons bake in their own rounded rect and ~6% transparent margin; iOS icons are full-bleed
//     squares and iOS applies the squircle mask itself. Used as-is, the Mac icon renders as a small
//     rounded badge floating inside a square.
//   * An iOS app icon with an alpha channel is an automatic App Store upload rejection. This writes
//     noneSkipLast (3 samples/pixel, hasAlpha: no).
// So: find the opaque bounding box, sample the artwork's own background colour just inside its left edge,
// fill an opaque square with it, and draw the cropped art centred at `scale` (0.90 keeps the spheres
// clear of the corner mask). The source's rounded corners melt into the identical background colour.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let src = CommandLine.arguments[1]
let dst = CommandLine.arguments[2]

guard let isrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else { fatalError("load") }

let w = img.width, h = img.height
// Read pixels (RGBA8)
var buf = [UInt8](repeating: 0, count: w*h*4)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("ctx") }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

// Bounding box of pixels with alpha > 8
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h { for x in 0..<w {
    if buf[(y*w+x)*4+3] > 8 { if x<minX {minX=x}; if x>maxX {maxX=x}; if y<minY {minY=y}; if y>maxY {maxY=y} }
}}
guard maxX >= minX else { fatalError("empty") }
let cw = maxX-minX+1, ch = maxY-minY+1
// Background: sample a pixel just inside the content, 30% in from the left edge at mid-height
let sx = minX + cw*3/10, sy = minY + ch/2
// better: sample near the top-left interior of the rounded rect (background region)
let bx = minX + cw/12, by = minY + ch/2
let o = (by*w+bx)*4
let bg = (r: CGFloat(buf[o])/255.0, g: CGFloat(buf[o+1])/255.0, b: CGFloat(buf[o+2])/255.0)
FileHandle.standardError.write("content \(cw)x\(ch) at (\(minX),\(minY))  bg=\(Int(bg.r*255)),\(Int(bg.g*255)),\(Int(bg.b*255)) sample2=(\(sx),\(sy))\n".data(using:.utf8)!)

guard let cropped = img.cropping(to: CGRect(x: minX, y: minY, width: cw, height: ch)) else { fatalError("crop") }

let out = 1024
guard let octx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
                           space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("octx") }
octx.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
octx.fill(CGRect(x: 0, y: 0, width: out, height: out))
octx.interpolationQuality = .high
// Draw the rounded-rect artwork full-bleed; its own rounded corners melt into the identical bg
let scale = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 1.0
let side = Double(out) * scale
let off = (Double(out) - side)/2.0
octx.draw(cropped, in: CGRect(x: off, y: off, width: side, height: side))

guard let final = octx.makeImage() else { fatalError("make") }
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dst) as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("dest") }
CGImageDestinationAddImage(dest, final, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("finalize") }
print("wrote \(dst)")
