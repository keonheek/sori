import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func render(_ px: Int) -> NSImage {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    // macOS-style squircle inset (icons float in a ~10% margin)
    let inset = s * 0.05
    let rect = NSRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    // deep indigo -> violet gradient, subtle
    let g = NSGradient(starting: NSColor(calibratedRed: 0.03, green: 0.19, blue: 0.24, alpha: 1),
                       ending:   NSColor(calibratedRed: 0.10, green: 0.65, blue: 0.60, alpha: 1))!
    g.draw(in: path, angle: 90)
    // white mic symbol, centered
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .medium)
    if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSColor.white.set()
        NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let symRect = NSRect(x: (s - tinted.size.width)/2, y: (s - tinted.size.height)/2 + s*0.01,
                             width: tinted.size.width, height: tinted.size.height)
        tinted.draw(in: symRect)
    }
    img.unlockFocus()
    return img
}

func writePNG(_ img: NSImage, _ px: Int, _ name: String) {
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
    rep.size = NSSize(width: px, height: px)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
}

for px in sizes {
    if px <= 512 { writePNG(render(px), px, "icon_\(px)x\(px).png") }
    if px >= 32 { writePNG(render(px), px, "icon_\(px/2)x\(px/2)@2x.png") }
}
print("iconset written to \(iconsetPath)")
