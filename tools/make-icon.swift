// Renders the DriveSync app icon (blue tile + cloud-upload glyph) into an .iconset folder.
// Usage: swift tools/make-icon.swift <out.iconset> && iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
             (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
for (px, name) in sizes {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tile = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804) // macOS icon grid
    NSColor(srgbRed: 0.04, green: 0.40, blue: 0.85, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18).fill()
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.40, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    let sym = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    sym.draw(in: NSRect(x: (s - sym.size.width) / 2, y: (s - sym.size.height) / 2, width: sym.size.width, height: sym.size.height))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
