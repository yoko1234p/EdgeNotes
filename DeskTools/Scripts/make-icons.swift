// Original code-drawn icons using system symbols; no third-party app artwork.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let values: [(String, String, NSColor, NSColor)] = [
    ("CaptureText", "viewfinder", .systemTeal, .systemGreen),
    ("DevWorkbench", "curlybraces", .systemIndigo, .systemPurple),
    ("EdgeNotes", "note.text", .systemOrange, .systemRed),
]
for (name, symbol, first, second) in values where name == "EdgeNotes" {
    let iconset = root.appendingPathComponent(name + ".iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let p = CGFloat(pixels)
            let rect = NSRect(x: p * 0.08, y: p * 0.08, width: p * 0.84, height: p * 0.84)
            NSGradient(starting: first, ending: second)!.draw(in: NSBezierPath(roundedRect: rect, xRadius: p * 0.2, yRadius: p * 0.2), angle: -60)
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)!
                .withSymbolConfiguration(.init(pointSize: p * 0.46, weight: .medium))!
            let tinted = NSImage(size: image.size)
            tinted.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: image.size).fill()
            image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .destinationIn, fraction: 1)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: p * 0.26, y: p * 0.26, width: p * 0.48, height: p * 0.48))
            NSGraphicsContext.restoreGraphicsState()
            let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
            try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(filename))
        }
    }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent(name + ".icns").path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(1) }
}
