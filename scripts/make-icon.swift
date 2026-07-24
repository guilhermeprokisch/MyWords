// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

// Generates AppIcon.iconset PNGs for MyWords: a keyboard drawn on an indigo
// gradient, rounded-square app-icon shape. Reproducible — no binary asset to
// trust. Run via scripts/make-icon.sh (which calls iconutil).
import AppKit

let sizes: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
let outDir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawIcon(px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Rounded-square background with an indigo → violet gradient.
    let inset = s * 0.05
    let bgRect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = roundedRect(bgRect, radius: bgRect.width * 0.2237)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.46, green: 0.40, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.21, green: 0.13, blue: 0.48, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -90)

    // Keyboard: 3 rows of keys + a space bar, in soft white.
    let kbW = bgRect.width * 0.66
    let kbH = bgRect.height * 0.46
    let kb = NSRect(x: bgRect.midX - kbW / 2, y: bgRect.midY - kbH / 2, width: kbW, height: kbH)
    let rowGap = kbH * 0.11
    let rowH = (kbH - rowGap * 3) / 4
    let keyGap = kbW * 0.06
    let keyW = (kbW - keyGap * 4) / 5
    let keyRadius = max(1, rowH * 0.24)
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.93).setFill()

    // Top three rows, 5 keys each (top row from the visual top).
    for row in 0..<3 {
        let y = kb.maxY - rowH - CGFloat(row) * (rowH + rowGap)
        for col in 0..<5 {
            let x = kb.minX + CGFloat(col) * (keyW + keyGap)
            roundedRect(NSRect(x: x, y: y, width: keyW, height: rowH), radius: keyRadius).fill()
        }
    }
    // Space bar.
    let spaceW = kbW * 0.6
    roundedRect(NSRect(x: kb.midX - spaceW / 2, y: kb.minY, width: spaceW, height: rowH), radius: keyRadius).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (base, scale) in sizes {
    let data = drawIcon(px: base * scale)
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("wrote \(outDir) (\(sizes.count) images)")
