// The app's icon: the Tabs mark (globe in a capsule) on a plate. The mark is
// Icon/mark.svg, drawn as-is. A Dock icon needs an opaque square — that's the
// plate, not the logo. Design.swift's Logomark uses the same SVG.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")

/// A dev build (build.sh) puts the mark on a yellow plate rather than a white
/// one, as Chrome Canary does, so the build from a worktree and the installed
/// app are told apart at a glance: in the Dock, in ⌘Tab, at 16 points.
let dev = ProcessInfo.processInfo.environment["SEARCH_DEV"] == "1"
let plateColor = dev ? NSColor(srgbRed: 1.0, green: 0.8, blue: 0.2, alpha: 1) : NSColor.white
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The mark beside this script. build.sh runs us from the repo root.
let markFile = URL(fileURLWithPath: "Icon/mark.svg")
guard let mark = NSImage(contentsOf: markFile) else {
    fputs("icon: could not read \(markFile.path)\n", stderr)
    exit(1)
}

/// Aspect of mark.svg's viewBox (34 × 22).
let markAspect = 34.0 / 22.0

func draw(_ size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    // Apple's grid: the shape takes 824 of 1024, and its corners are 22.37%.
    let s = size / 1024
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let corner = 824 * 0.2237 * s
    let shape = NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner)

    // A soft shadow under the plate, the way every icon on the Dock has one.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    plateColor.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // The mark, centred on the plate. A touch under three quarters keeps it
    // readable at 16 points without crowding the rounded corners.
    let height = plate.height * 0.52
    let width = height * markAspect
    let rect = NSRect(
        x: plate.midX - width / 2,
        y: plate.midY - height / 2,
        width: width,
        height: height
    )
    mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    return image
}

func write(_ image: NSImage, to url: URL, pixels: Int) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { return }
    let sized = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    sized.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sized)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = sized.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = draw(CGFloat(pixels))
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(image, to: out.appendingPathComponent(name), pixels: pixels)
    }
}
print("drew: \(out.path)")

// The same icon as an Icon Composer document, when a second path is given.
// macOS 26 lets the Dock show icons Dark, Clear or Tinted. The mark SVG is
// copied as-is; Dark/Tinted recolour it through fill-specializations.
if CommandLine.arguments.count > 2 {
    let doc = URL(fileURLWithPath: CommandLine.arguments[2])
    let assets = doc.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: doc)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    let width = 1024 * 0.72
    let height = width / markAspect
    // Icon Composer wants its own copy; keep the path fill black so Dark can
    // invert it. The on-disk Icon/mark.svg stays the ink colour for .icns.
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 34 22" fill="none">\
    <path fill="#000000" d="M22.624.129H11.376C5.379.129.5 5.006.5 10.999c0 5.995 4.879 10.872 10.876 10.872h11.248C28.621 21.87 33.5 16.994 33.5 11S28.621.129 22.624.129m9.189 10.046h-4.09c-.271-3.565-2.29-6.649-5.2-8.397h.1c4.81 0 8.77 3.696 9.188 8.397zM17 20.102c-.811 0-1.82-1.34-2.468-3.711h4.934c-.647 2.37-1.657 3.71-2.468 3.71zm-2.822-5.341a22 22 0 0 1-.284-2.937h6.211a22 22 0 0 1-.283 2.937zm-.284-4.586c.036-1.069.134-2.052.284-2.937h5.644c.15.885.25 1.868.284 2.937zm.64-4.567c.646-2.37 1.656-3.71 2.466-3.71s1.82 1.34 2.468 3.71zm5.398-3.226a9.15 9.15 0 0 1 4.4 3.226h-3.179c-.3-1.23-.709-2.34-1.22-3.226m-7.085 3.226H9.669a9.15 9.15 0 0 1 4.399-3.226c-.512.887-.921 1.997-1.221 3.226M8.71 7.238h3.812c-.15.953-.244 1.945-.277 2.937H7.933a9 9 0 0 1 .777-2.937m3.535 4.586c.033.991.126 1.983.277 2.937H8.71a9 9 0 0 1-.777-2.937zm.603 4.567c.3 1.23.709 2.34 1.22 3.226A9.15 9.15 0 0 1 9.67 16.39zm8.307 0h3.178a9.15 9.15 0 0 1-4.398 3.226c.512-.887.92-1.997 1.22-3.226m4.139-1.63H21.48c.15-.953.244-1.946.277-2.937h4.312a9 9 0 0 1-.776 2.937m-3.536-4.586a24 24 0 0 0-.277-2.937h3.813c.414.91.683 1.898.776 2.937zM11.376 1.78h.1c-2.91 1.747-4.929 4.831-5.2 8.397H2.186c.419-4.7 4.38-8.397 9.189-8.397M2.187 11.825h4.09c.271 3.565 2.29 6.649 5.2 8.397h-.1c-4.81 0-8.77-3.697-9.189-8.397m20.437 8.397h-.1c2.91-1.747 4.929-4.831 5.2-8.397h4.09c-.419 4.7-4.38 8.397-9.189 8.397"/>\
    </svg>
    """
    try svg.write(to: assets.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)

    let white = #"{ "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" }"#
    let yellow = #"{ "solid" : "srgb:1.00000,0.80000,0.20000,1.00000" }"#
    let ink = #"{ "solid" : "srgb:0.09000,0.09000,0.09000,1.00000" }"#
    let plate = dev ? yellow : white
    let json = """
    {
      "fill" : \(plate),
      "fill-specializations" : [
        { "value" : \(plate) },
        { "appearance" : "dark", "value" : \(ink) }
      ],
      "groups" : [
        {
          "layers" : [
            {
              "name" : "mark",
              "image-name" : "mark.svg",
              "glass" : false,
              "fill-specializations" : [
                { "value" : \(ink) },
                { "appearance" : "dark", "value" : \(plate) },
                { "appearance" : "tinted", "value" : \(white) }
              ]
            }
          ],
          "shadow" : { "kind" : "none", "opacity" : 0.5 },
          "specular" : false,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }
    """
    try json.write(to: doc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("wrote: \(doc.path)")
}
