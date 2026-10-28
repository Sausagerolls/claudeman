// Renders the Claudeman app icon and packs it into Resources/AppIcon.icns,
// plus a full-bleed square version for the iOS companion app.
// Usage: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(fullBleed: Bool = false) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824pt body inset 100pt, with a soft drop shadow.
    // iOS wants an opaque square that the system masks itself, so scale the body to fill it.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = fullBleed ? NSBezierPath(rect: body) : NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    if fullBleed {
        ctx.scaleBy(x: size / 824, y: size / 824)
        ctx.translateBy(x: -100, y: -100)
    }

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35).cgColor)
    color(0xC15F3C).setFill()
    bodyPath.fill()
    ctx.restoreGState()

    // Warm Claude-orange gradient background.
    NSGradient(colors: [color(0xF0A07A), color(0xD97757), color(0xB4532F)])!
        .draw(in: bodyPath, angle: -70)

    // Subtle top highlight.
    ctx.saveGState()
    bodyPath.addClip()
    NSGradient(colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    ctx.restoreGState()

    // Terminal window card.
    let card = NSRect(x: 196, y: 236, width: 632, height: 500)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 56, yRadius: 56)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x3A1608, 0.45).cgColor)
    color(0x1E1D1C).setFill()
    cardPath.fill()
    ctx.restoreGState()

    // Title bar with traffic lights.
    ctx.saveGState()
    cardPath.addClip()
    color(0x2C2A28).setFill()
    NSRect(x: card.minX, y: card.maxY - 92, width: card.width, height: 92).fill()
    ctx.restoreGState()
    for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        color(hex).setFill()
        NSBezierPath(ovalIn: NSRect(x: card.minX + 46 + CGFloat(index) * 54, y: card.maxY - 62, width: 32, height: 32)).fill()
    }

    // Prompt chevron.
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 278, y: 560))
    chevron.line(to: NSPoint(x: 398, y: 470))
    chevron.line(to: NSPoint(x: 278, y: 380))
    chevron.lineWidth = 46
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    color(0xF5F1EA).setStroke()
    chevron.stroke()

    // Cursor block.
    color(0xF5F1EA).setFill()
    NSBezierPath(roundedRect: NSRect(x: 446, y: 352, width: 150, height: 46), xRadius: 14, yRadius: 14).fill()

    // Claude-style sparkle.
    let center = NSPoint(x: 690, y: 520)
    let sparkle = NSBezierPath()
    let rays = 8
    for i in 0..<(rays * 2) {
        let angle = CGFloat(i) * .pi / CGFloat(rays) + .pi / 2
        let radius: CGFloat = i % 2 == 0 ? 82 : 22
        let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        i == 0 ? sparkle.move(to: point) : sparkle.line(to: point)
    }
    sparkle.close()
    color(0xE58A62).setFill()
    sparkle.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = render()
let masterURL = root.appendingPathComponent("Resources/AppIcon.png")
try! master.representation(using: .png, properties: [:])!.write(to: masterURL)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["-z", "\(pixels)", "\(pixels)", masterURL.path, "--out", iconset.appendingPathComponent(name).path]
        process.standardOutput = FileHandle.nullDevice
        try! process.run()
        process.waitUntilExit()
    }
}

let iosIcon = root.appendingPathComponent("iOS/ClaudemanRemote/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try! render(fullBleed: true).representation(using: .png, properties: [:])!.write(to: iosIcon)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
