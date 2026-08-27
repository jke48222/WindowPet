import AppKit

// Design-upgrade candidates for Rusty: three directions, same identity
// (teal tin robot, visor eyes, antenna bobble), different levels/kinds of
// finish. Idle pose only — the winner gets the full pose-system treatment.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func shadow(_ w: CGFloat = 76) {
    rgb(30, 24, 18, 0.20).setFill()
    NSBezierPath(ovalIn: CGRect(x: 64 - w / 2, y: 5, width: w, height: 13)).fill()
}

// MARK: U1 — Polished tin: current geometry, real material finish.

func drawPolished() {
    shadow(78)
    let darkTeal = rgb(34, 68, 64)
    // Feet with rubber treads.
    for x in [36.0, 72.0] {
        rgb(96, 100, 108).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: 8, width: 20, height: 12), xRadius: 4, yRadius: 4).fill()
        rgb(52, 56, 62).setStroke()
        for i in 0..<3 {
            let t = NSBezierPath()
            t.move(to: CGPoint(x: x + 4 + CGFloat(i) * 6, y: 8.5))
            t.line(to: CGPoint(x: x + 4 + CGFloat(i) * 6, y: 12))
            t.lineWidth = 1.6; t.stroke()
        }
    }
    // Body with brushed-metal banding + rim light.
    let body = NSBezierPath(roundedRect: CGRect(x: 26, y: 18, width: 76, height: 74),
                            xRadius: 12, yRadius: 12)
    NSGradient(starting: rgb(112, 176, 168), ending: rgb(56, 110, 105))?.draw(in: body, angle: -90)
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    rgb(255, 255, 255, 0.10).setFill()
    for y in [26.0, 40.0, 84.0] { CGRect(x: 26, y: y, width: 76, height: 4).fill() }
    rgb(0, 0, 0, 0.10).setFill()
    CGRect(x: 26, y: 18, width: 76, height: 6).fill()
    // Rim light top-left.
    let rim = NSBezierPath(roundedRect: CGRect(x: 27.5, y: 19.5, width: 73, height: 71),
                           xRadius: 11, yRadius: 11)
    rgb(220, 255, 250, 0.55).setStroke(); rim.lineWidth = 2; rim.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()
    darkTeal.setStroke(); body.lineWidth = 2.4; body.stroke()
    // Corner screws with slots.
    for (x, y) in [(33.0, 25.0), (89.0, 25.0), (33.0, 83.0), (89.0, 83.0)] {
        rgb(210, 214, 218).setFill()
        NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 6, height: 6)).fill()
        rgb(90, 94, 100).setStroke()
        let slot = NSBezierPath()
        slot.move(to: CGPoint(x: x + 1.2, y: y + 3)); slot.line(to: CGPoint(x: x + 4.8, y: y + 3))
        slot.lineWidth = 1.2; slot.stroke()
    }
    // Faceplate + glass visor with reflection.
    let plate = NSBezierPath(roundedRect: CGRect(x: 36, y: 52, width: 56, height: 30),
                             xRadius: 8, yRadius: 8)
    NSGradient(starting: rgb(226, 230, 234), ending: rgb(196, 200, 206))?.draw(in: plate, angle: -90)
    rgb(120, 124, 130).setStroke(); plate.lineWidth = 1.8; plate.stroke()
    let visor = NSBezierPath(roundedRect: CGRect(x: 42, y: 58, width: 44, height: 18),
                             xRadius: 9, yRadius: 9)
    NSGradient(starting: rgb(40, 48, 62), ending: rgb(18, 22, 32))?.draw(in: visor, angle: -90)
    // Eyes with glow halo.
    for x in [50.0, 68.0] {
        rgb(120, 235, 255, 0.28).setFill()
        NSBezierPath(ovalIn: CGRect(x: x - 2.5, y: 59.5, width: 15, height: 15)).fill()
        rgb(120, 235, 255).setFill()
        NSBezierPath(ovalIn: CGRect(x: x, y: 62, width: 10, height: 10)).fill()
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: CGRect(x: x + 3, y: 67, width: 3.5, height: 3.5)).fill()
    }
    // Visor reflection streak.
    NSGraphicsContext.current?.saveGraphicsState()
    visor.addClip()
    rgb(255, 255, 255, 0.14).setFill()
    let streak = NSBezierPath()
    streak.move(to: CGPoint(x: 46, y: 76)); streak.line(to: CGPoint(x: 58, y: 76))
    streak.line(to: CGPoint(x: 50, y: 58)); streak.line(to: CGPoint(x: 42, y: 58)); streak.close()
    streak.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // Chest dial with tick marks.
    rgb(226, 230, 234).setFill()
    NSBezierPath(ovalIn: CGRect(x: 55, y: 25, width: 18, height: 18)).fill()
    rgb(120, 124, 130).setStroke()
    let dialRing = NSBezierPath(ovalIn: CGRect(x: 55, y: 25, width: 18, height: 18))
    dialRing.lineWidth = 1.4; dialRing.stroke()
    for i in 0..<8 {
        let a = CGFloat(i) / 8 * 2 * .pi
        let t = NSBezierPath()
        t.move(to: CGPoint(x: 64 + cos(a) * 6.5, y: 34 + sin(a) * 6.5))
        t.line(to: CGPoint(x: 64 + cos(a) * 8.2, y: 34 + sin(a) * 8.2))
        t.lineWidth = 1; rgb(120, 124, 130).setStroke(); t.stroke()
    }
    rgb(233, 90, 70).setFill()
    NSBezierPath(ovalIn: CGRect(x: 61, y: 31, width: 6, height: 6)).fill()
    // Grille.
    darkTeal.setStroke()
    for i in 0..<3 {
        let m = NSBezierPath()
        m.move(to: CGPoint(x: 52 + CGFloat(i) * 9, y: 46)); m.line(to: CGPoint(x: 58 + CGFloat(i) * 9, y: 46))
        m.lineWidth = 2; m.lineCapStyle = .round; m.stroke()
    }
    // Antenna with coil.
    let ant = NSBezierPath()
    ant.move(to: CGPoint(x: 64, y: 92)); ant.line(to: CGPoint(x: 64, y: 106))
    rgb(120, 124, 130).setStroke(); ant.lineWidth = 3; ant.lineCapStyle = .round; ant.stroke()
    for y in [96.0, 100.0] {
        let coil = NSBezierPath(ovalIn: CGRect(x: 61, y: y, width: 6, height: 3))
        coil.lineWidth = 1.2; rgb(160, 164, 170).setStroke(); coil.stroke()
    }
    NSGradient(starting: rgb(245, 120, 100), ending: rgb(210, 70, 52))?
        .draw(in: NSBezierPath(ovalIn: CGRect(x: 58, y: 104, width: 12, height: 12)), angle: -90)
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(ovalIn: CGRect(x: 60.5, y: 109.5, width: 4, height: 4)).fill()
}

// MARK: U2 — Soft toy: chunkier, rounder, bigger-eyed, fewer lines.

func drawSoft() {
    shadow(80)
    for x in [38.0, 72.0] {
        rgb(148, 158, 168).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: 7, width: 18, height: 14), xRadius: 7, yRadius: 7).fill()
    }
    let body = NSBezierPath(roundedRect: CGRect(x: 24, y: 17, width: 80, height: 78),
                            xRadius: 22, yRadius: 22)
    NSGradient(starting: rgb(134, 194, 186), ending: rgb(88, 148, 141))?.draw(in: body, angle: -90)
    rgb(60, 108, 102, 0.8).setStroke(); body.lineWidth = 2.6; body.stroke()
    // Big friendly visor.
    let visor = NSBezierPath(roundedRect: CGRect(x: 36, y: 54, width: 56, height: 26),
                             xRadius: 13, yRadius: 13)
    NSGradient(starting: rgb(46, 56, 72), ending: rgb(24, 30, 42))?.draw(in: visor, angle: -90)
    rgb(214, 224, 228, 0.9).setStroke(); visor.lineWidth = 2.2; visor.stroke()
    for x in [48.0, 70.0] {
        rgb(130, 240, 255).setFill()
        NSBezierPath(ovalIn: CGRect(x: x, y: 60, width: 13, height: 13)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: x + 3.5, y: 66.5, width: 5, height: 5)).fill()
        NSBezierPath(ovalIn: CGRect(x: x + 8.5, y: 61.5, width: 2.5, height: 2.5)).fill()
    }
    // Cream belly plate + happy little grille-smile.
    let belly = NSBezierPath(roundedRect: CGRect(x: 42, y: 24, width: 44, height: 24),
                             xRadius: 12, yRadius: 12)
    rgb(238, 232, 216).setFill(); belly.fill()
    rgb(60, 108, 102, 0.5).setStroke(); belly.lineWidth = 1.8; belly.stroke()
    rgb(60, 108, 102).setStroke()
    let smile = NSBezierPath()
    smile.appendArc(withCenter: CGPoint(x: 64, y: 39), radius: 7, startAngle: 200, endAngle: 340, clockwise: false)
    smile.lineWidth = 2.4; smile.lineCapStyle = .round; smile.stroke()
    rgb(233, 90, 70).setFill()
    NSBezierPath(ovalIn: CGRect(x: 61, y: 27, width: 6, height: 6)).fill()
    // Blush!
    rgb(255, 140, 120, 0.35).setFill()
    NSBezierPath(ovalIn: CGRect(x: 30, y: 50, width: 11, height: 7)).fill()
    NSBezierPath(ovalIn: CGRect(x: 87, y: 50, width: 11, height: 7)).fill()
    // Chunky antenna.
    let ant = NSBezierPath()
    ant.move(to: CGPoint(x: 64, y: 95)); ant.line(to: CGPoint(x: 64, y: 106))
    rgb(148, 158, 168).setStroke(); ant.lineWidth = 4; ant.lineCapStyle = .round; ant.stroke()
    rgb(240, 100, 80).setFill()
    NSBezierPath(ovalIn: CGRect(x: 56, y: 103, width: 16, height: 16)).fill()
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(ovalIn: CGRect(x: 59.5, y: 110.5, width: 5, height: 5)).fill()
}

// MARK: U3 — Retro-mecha: panel lines, gauge, boots, accents.

func drawMecha() {
    shadow(80)
    let hull = rgb(70, 118, 112)
    let dark = rgb(30, 58, 54)
    let accent = rgb(240, 150, 60)
    // Boots with toe caps + treads.
    for x in [34.0, 72.0] {
        rgb(84, 90, 98).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: 7, width: 22, height: 14), xRadius: 5, yRadius: 5).fill()
        rgb(52, 56, 62).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: 7, width: 22, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        rgb(150, 156, 164).setFill()
        NSBezierPath(roundedRect: CGRect(x: x + 13, y: 10, width: 9, height: 10), xRadius: 4, yRadius: 4).fill()
    }
    // Hull with panel seams.
    let body = NSBezierPath(roundedRect: CGRect(x: 25, y: 19, width: 78, height: 74),
                            xRadius: 10, yRadius: 10)
    NSGradient(starting: rgb(96, 152, 145), ending: rgb(52, 96, 91))?.draw(in: body, angle: -90)
    dark.setStroke(); body.lineWidth = 2.6; body.stroke()
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    dark.withAlphaComponent(0.5).setStroke()
    for (x0, y0, x1, y1) in [(25.0, 50.0, 103.0, 50.0), (64.0, 19.0, 64.0, 26.0), (44.0, 93.0, 44.0, 82.0), (84.0, 93.0, 84.0, 82.0)] {
        let seam = NSBezierPath()
        seam.move(to: CGPoint(x: x0, y: y0)); seam.line(to: CGPoint(x: x1, y: y1))
        seam.lineWidth = 1.4; seam.stroke()
    }
    // Accent stripes on the shoulder line.
    accent.setFill()
    CGRect(x: 25, y: 84, width: 14, height: 5).fill()
    CGRect(x: 42, y: 84, width: 7, height: 5).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // Rivets.
    rgb(200, 206, 212).setFill()
    for x in [30.0, 95.0] {
        for y in [26.0, 46.0, 66.0] {
            NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 3.5, height: 3.5)).fill()
        }
    }
    // Face: inset armored visor.
    let plate = NSBezierPath(roundedRect: CGRect(x: 34, y: 53, width: 60, height: 31),
                             xRadius: 7, yRadius: 7)
    NSGradient(starting: rgb(206, 212, 218), ending: rgb(170, 176, 184))?.draw(in: plate, angle: -90)
    rgb(96, 102, 110).setStroke(); plate.lineWidth = 2; plate.stroke()
    let visor = NSBezierPath(roundedRect: CGRect(x: 40, y: 59, width: 48, height: 19),
                             xRadius: 6, yRadius: 6)
    NSGradient(starting: rgb(34, 42, 56), ending: rgb(14, 18, 26))?.draw(in: visor, angle: -90)
    accent.setStroke(); visor.lineWidth = 1.6; visor.stroke()
    for x in [48.0, 68.0] {
        rgb(140, 240, 255).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: 63, width: 12, height: 10), xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: CGRect(x: x + 7, y: 69, width: 3, height: 3)).fill()
    }
    // Chest gauge with needle.
    rgb(226, 230, 234).setFill()
    NSBezierPath(ovalIn: CGRect(x: 53, y: 24, width: 22, height: 22)).fill()
    rgb(96, 102, 110).setStroke()
    let ring = NSBezierPath(ovalIn: CGRect(x: 53, y: 24, width: 22, height: 22))
    ring.lineWidth = 1.6; ring.stroke()
    for i in 0..<5 {
        let a = CGFloat.pi * (0.15 + 0.175 * CGFloat(i))
        let t = NSBezierPath()
        t.move(to: CGPoint(x: 64 + cos(a) * 7.5, y: 35 + sin(a) * 7.5))
        t.line(to: CGPoint(x: 64 + cos(a) * 9.5, y: 35 + sin(a) * 9.5))
        t.lineWidth = 1.2; rgb(96, 102, 110).setStroke(); t.stroke()
    }
    let needle = NSBezierPath()
    needle.move(to: CGPoint(x: 64, y: 35))
    needle.line(to: CGPoint(x: 64 + cos(.pi * 0.32) * 8.5, y: 35 + sin(.pi * 0.32) * 8.5))
    rgb(233, 90, 70).setStroke(); needle.lineWidth = 2; needle.lineCapStyle = .round; needle.stroke()
    // Side vents.
    dark.setStroke()
    for i in 0..<3 {
        let v = NSBezierPath()
        v.move(to: CGPoint(x: 30, y: 54 + CGFloat(i) * 5)); v.line(to: CGPoint(x: 36, y: 54 + CGFloat(i) * 5))
        v.lineWidth = 2; v.lineCapStyle = .round; v.stroke()
    }
    // Antenna: coiled with glowing tip ring.
    let ant = NSBezierPath()
    ant.move(to: CGPoint(x: 74, y: 93)); ant.line(to: CGPoint(x: 78, y: 108))
    rgb(120, 124, 130).setStroke(); ant.lineWidth = 2.6; ant.lineCapStyle = .round; ant.stroke()
    rgb(240, 150, 60, 0.4).setFill()
    NSBezierPath(ovalIn: CGRect(x: 71, y: 103, width: 14, height: 14)).fill()
    accent.setFill()
    NSBezierPath(ovalIn: CGRect(x: 74, y: 106, width: 8, height: 8)).fill()
}

// MARK: - Sheet

let variants: [(String, String, String, () -> Void)] = [
    ("U1", "Polished tin", "brushed metal, rim light, glass visor", drawPolished),
    ("U2", "Soft toy", "chunky, big-eyed, blush, belly smile", drawSoft),
    ("U3", "Retro-mecha", "panel seams, gauge, boots, accents", drawMecha),
]

func render(_ draw: () -> Void, size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    g.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    g.cgContext.scaleBy(x: CGFloat(size) / 128, y: CGFloat(size) / 128)
    draw()
    g.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func composite(_ rep: NSBitmapImageRep, in rect: CGRect) {
    let img = NSImage(size: rect.size)
    img.addRepresentation(rep)
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

let cellW = 330, cellH = 410, margin = 20
let W = 3 * cellW + margin * 2, H = cellH + margin * 2
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let g = NSGraphicsContext(bitmapImageRep: sheet)!
NSGraphicsContext.current = g
rgb(228, 224, 214).setFill()
CGRect(x: 0, y: 0, width: W, height: H).fill()
for (i, (tag, name, style, draw)) in variants.enumerated() {
    let x = CGFloat(margin + i * cellW) + 8
    let y = CGFloat(margin) + 8
    let card = NSBezierPath(roundedRect: CGRect(x: x, y: y, width: CGFloat(cellW) - 16, height: CGFloat(cellH) - 16),
                            xRadius: 16, yRadius: 16)
    rgb(243, 240, 233).setFill(); card.fill()
    rgb(205, 200, 188).setStroke(); card.lineWidth = 1.5; card.stroke()
    composite(render(draw, size: 256), in: CGRect(x: x + 29, y: y + 120, width: 256, height: 256))
    composite(render(draw, size: 128), in: CGRect(x: x + 240, y: y + 34, width: 64, height: 64))
    ("\(tag) · \(name)" as NSString).draw(at: CGPoint(x: x + 24, y: y + 62),
        withAttributes: [.font: NSFont.systemFont(ofSize: 25, weight: .bold),
                         .foregroundColor: rgb(58, 54, 47)])
    (style as NSString).draw(at: CGPoint(x: x + 24, y: y + 34),
        withAttributes: [.font: NSFont.systemFont(ofSize: 15),
                         .foregroundColor: rgb(122, 116, 104)])
}
g.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! sheet.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "\(outDir)/rusty-v2-directions.png"))
print("wrote \(outDir)/rusty-v2-directions.png")
