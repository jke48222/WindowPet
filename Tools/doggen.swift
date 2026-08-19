import AppKit

// Three art directions for the user's dog. Identity anchors carried through
// all three: brindle caramel striping on dark brown, frosted grey muzzle,
// long black floppy ears, round amber "worried" eyes, big black nose,
// stocky build. 128-unit space, ground line y≈10.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func shadow(_ w: CGFloat = 76) {
    rgb(30, 24, 18, 0.18).setFill()
    NSBezierPath(ovalIn: CGRect(x: 64 - w / 2, y: 5, width: w, height: 13)).fill()
}

func pixels(_ rows: [String], palette: [Character: NSColor], px: CGFloat, originX: CGFloat, originY: CGFloat) {
    for (r, row) in rows.enumerated() {
        for (c, ch) in row.enumerated() {
            guard let color = palette[ch] else { continue }
            color.setFill()
            CGRect(x: originX + CGFloat(c) * px,
                   y: originY + CGFloat(rows.count - 1 - r) * px,
                   width: px, height: px).fill()
        }
    }
}

// MARK: - A · Plush chibi (soft gradients, the current pet's school)

func drawChibi() {
    shadow(82)
    // Feet: dark with frosted grey tips (senior toes).
    for x in [40.0, 71.0] {
        rgb(52, 40, 30).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: 10, width: 17, height: 16), xRadius: 7, yRadius: 7).fill()
        rgb(214, 208, 196).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: 10, width: 17, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
    }
    // Body bean.
    let body = NSBezierPath(roundedRect: CGRect(x: 26, y: 18, width: 76, height: 80),
                            xRadius: 32, yRadius: 32)
    NSGradient(starting: rgb(88, 66, 50), ending: rgb(56, 42, 32))?.draw(in: body, angle: -90)
    rgb(40, 30, 22, 0.7).setStroke(); body.lineWidth = 2.5; body.stroke()
    // Brindle: soft caramel streaks, slightly diagonal, sides + crown.
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    rgb(190, 132, 74, 0.5).setFill()
    for (x, y, w, h, deg) in [(20.0, 62.0, 26.0, 9.0, 18.0), (18.0, 40.0, 22.0, 8.0, 14.0),
                              (86.0, 58.0, 26.0, 9.0, -18.0), (88.0, 36.0, 22.0, 8.0, -14.0),
                              (42.0, 88.0, 18.0, 7.0, 8.0), (68.0, 90.0, 18.0, 7.0, -8.0)] {
        let t = NSAffineTransform()
        t.translateX(by: x + w / 2, yBy: y + h / 2)
        t.rotate(byDegrees: deg)
        t.translateX(by: -(x + w / 2), yBy: -(y + h / 2))
        let streak = NSBezierPath(ovalIn: CGRect(x: x, y: y, width: w, height: h))
        streak.transform(using: t as AffineTransform)
        streak.fill()
    }
    // Grey age-speckles on the brow.
    rgb(216, 210, 198, 0.5).setFill()
    for (x, y) in [(44.0, 80.0), (52.0, 84.0), (78.0, 82.0), (84.0, 78.0), (64.0, 86.0)] {
        NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 3, height: 3)).fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()
    // Long floppy ears hanging down the head sides, in front (like the
    // photos: they frame the face and hang past the muzzle top).
    for x in [26.0, 86.0] {
        let ear = NSBezierPath(roundedRect: CGRect(x: x, y: 36, width: 16, height: 54),
                               xRadius: 8, yRadius: 8)
        rgb(26, 20, 16).setFill(); ear.fill()
        rgb(60, 48, 38, 0.6).setStroke(); ear.lineWidth = 1.5; ear.stroke()
    }
    // Worried inner brows — the signature.
    rgb(214, 208, 196, 0.85).setStroke()
    for (cx, flip) in [(50.0, 1.0), (78.0, -1.0)] {
        let brow = NSBezierPath()
        brow.move(to: CGPoint(x: cx - 7 * flip, y: 74))
        brow.curve(to: CGPoint(x: cx + 4 * flip, y: 78),
                   controlPoint1: CGPoint(x: cx - 2 * flip, y: 77), controlPoint2: CGPoint(x: cx + 1 * flip, y: 78))
        brow.lineWidth = 2.6; brow.lineCapStyle = .round; brow.stroke()
    }
    // Big soulful amber eyes: dark ring, amber iris, huge pupil, sparkle.
    for cx in [48.0, 80.0] {
        rgb(32, 25, 20).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 12, y: 50, width: 24, height: 24)).fill()
        rgb(201, 142, 63).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 9.5, y: 52.5, width: 19, height: 19)).fill()
        rgb(24, 18, 14).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 6.5, y: 54, width: 13, height: 14)).fill()
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 3, y: 62, width: 5, height: 5)).fill()
        NSBezierPath(ovalIn: CGRect(x: cx + 2, y: 55, width: 2.5, height: 2.5)).fill()
    }
    // Frosted grey muzzle with jowls, big nose, whiskers.
    let muzzle = NSBezierPath(roundedRect: CGRect(x: 43, y: 22, width: 42, height: 28),
                              xRadius: 13, yRadius: 13)
    NSGradient(starting: rgb(226, 220, 208), ending: rgb(196, 190, 178))?.draw(in: muzzle, angle: -90)
    rgb(120, 110, 96, 0.5).setStroke(); muzzle.lineWidth = 1.8; muzzle.stroke()
    let nose = NSBezierPath(roundedRect: CGRect(x: 55, y: 38, width: 18, height: 12),
                            xRadius: 6, yRadius: 6)
    rgb(28, 24, 22).setFill(); nose.fill()
    NSColor.white.withAlphaComponent(0.35).setFill()
    NSBezierPath(ovalIn: CGRect(x: 58, y: 44, width: 5, height: 3.5)).fill()
    // Mouth: gentle jowly w.
    let mouth = NSBezierPath()
    mouth.move(to: CGPoint(x: 64, y: 38))
    mouth.line(to: CGPoint(x: 64, y: 34.5))
    mouth.appendArc(withCenter: CGPoint(x: 60, y: 34.5), radius: 4, startAngle: 0, endAngle: 210, clockwise: true)
    mouth.move(to: CGPoint(x: 64, y: 34.5))
    mouth.appendArc(withCenter: CGPoint(x: 68, y: 34.5), radius: 4, startAngle: 180, endAngle: 330, clockwise: true)
    rgb(96, 88, 78).setStroke(); mouth.lineWidth = 1.8; mouth.lineCapStyle = .round; mouth.stroke()
    // Whiskers.
    rgb(230, 226, 216, 0.8).setStroke()
    for (x0, y0, x1, y1) in [(46.0, 30.0, 34.0, 32.0), (46.0, 26.0, 35.0, 25.0),
                             (82.0, 30.0, 94.0, 32.0), (82.0, 26.0, 93.0, 25.0)] {
        let wsk = NSBezierPath()
        wsk.move(to: CGPoint(x: x0, y: y0)); wsk.line(to: CGPoint(x: x1, y: y1))
        wsk.lineWidth = 1.4; wsk.lineCapStyle = .round; wsk.stroke()
    }
}

// MARK: - B · 8-bit pixel sprite

func drawPixel() {
    let O = rgb(24, 18, 13)          // outline
    let D = rgb(74, 56, 40)          // dark brown
    let C = rgb(185, 127, 66)        // caramel brindle
    let E = rgb(34, 27, 21)          // ear black-brown
    let G = rgb(216, 210, 198)       // frosted muzzle
    let B = rgb(18, 14, 12)          // black (nose/pupil)
    let A = rgb(216, 154, 62)        // amber
    let map = [
        "....OOOOOOOO....",
        "..OODDCDDDDCOO..",
        ".OEDDDDDDDDDDEO.",
        "OEEDDCDDDDCDDEEO",
        "OEEDDDDDDDDDDEEO",
        "OEEDAADDDDAADEEO",
        "OEEDABDDDDABDEEO",
        "OEEDDDDDDDDDDEEO",
        ".OODGGGBBGGGOO..",
        "..ODGGGBBGGGO...",
        "..ODDGGGGGGDDO..",
        ".ODDCDDDDDDCDDO.",
        ".ODDDCDDDDCDDDO.",
        ".ODDCDDDDDDCDDO.",
        "..ODDO....ODDO..",
        "..OGGO....OGGO..",
    ]
    shadow(86)
    pixels(map, palette: ["O": O, "D": D, "C": C, "E": E, "G": G, "B": B, "A": A],
           px: 7, originX: 8, originY: 10)
}

// MARK: - C · Saturday-morning cartoon (bold outline, flat fills)

func drawCartoon() {
    shadow(84)
    let ink = rgb(32, 24, 15)
    let coat = rgb(94, 68, 50)
    let caramel = rgb(196, 138, 74)
    let grey = rgb(222, 216, 204)

    func flat(_ p: NSBezierPath, _ fill: NSColor, line: CGFloat = 3.5) {
        fill.setFill(); p.fill()
        ink.setStroke(); p.lineWidth = line; p.lineJoinStyle = .round; p.stroke()
    }
    // Curled tail on the ground, poking out right.
    let tail = NSBezierPath()
    tail.move(to: CGPoint(x: 96, y: 16))
    tail.curve(to: CGPoint(x: 118, y: 22), controlPoint1: CGPoint(x: 108, y: 12), controlPoint2: CGPoint(x: 118, y: 14))
    tail.curve(to: CGPoint(x: 102, y: 26), controlPoint1: CGPoint(x: 116, y: 28), controlPoint2: CGPoint(x: 108, y: 28))
    tail.close()
    flat(tail, coat, line: 3)
    // Haunches: wide sitting base.
    let haunch = NSBezierPath(roundedRect: CGRect(x: 26, y: 10, width: 76, height: 44),
                              xRadius: 22, yRadius: 22)
    flat(haunch, coat)
    // Chest: cream-grey bib between the front legs.
    let bib = NSBezierPath(roundedRect: CGRect(x: 48, y: 12, width: 32, height: 40),
                           xRadius: 14, yRadius: 14)
    flat(bib, grey, line: 3)
    // Front paws.
    for x in [46.0, 66.0] {
        flat(NSBezierPath(roundedRect: CGRect(x: x, y: 8, width: 16, height: 11),
                          xRadius: 5, yRadius: 5), grey, line: 3)
    }
    // Brindle: flat jagged stripes on the haunches.
    caramel.setFill()
    for (x, y) in [(30.0, 30.0), (88.0, 32.0), (34.0, 18.0), (90.0, 18.0)] {
        let z = NSBezierPath()
        z.move(to: CGPoint(x: x, y: y))
        z.line(to: CGPoint(x: x + 10, y: y + 4)); z.line(to: CGPoint(x: x + 4, y: y + 7))
        z.line(to: CGPoint(x: x + 12, y: y + 10)); z.line(to: CGPoint(x: x + 2, y: y + 8))
        z.line(to: CGPoint(x: x + 7, y: y + 4)); z.close()
        z.fill()
    }
    // Head: big, slightly wider at the jowls.
    let head = NSBezierPath(roundedRect: CGRect(x: 30, y: 54, width: 68, height: 58),
                            xRadius: 26, yRadius: 26)
    flat(head, coat)
    // Ears: long flat black flaps over the head sides.
    for (x, deg) in [(36.0, 5.0), (92.0, -5.0)] {
        let t = NSAffineTransform()
        t.translateX(by: x, yBy: 106)
        t.rotate(byDegrees: deg)
        t.translateX(by: -x, yBy: -106)
        let ear = NSBezierPath(roundedRect: CGRect(x: x - 8, y: 54, width: 16, height: 52),
                               xRadius: 8, yRadius: 8)
        ear.transform(using: t as AffineTransform)
        flat(ear, rgb(38, 30, 24), line: 3)
    }
    // Head brindle patch.
    caramel.setFill()
    let hp = NSBezierPath()
    hp.move(to: CGPoint(x: 52, y: 108)); hp.line(to: CGPoint(x: 62, y: 111))
    hp.line(to: CGPoint(x: 57, y: 105)); hp.line(to: CGPoint(x: 68, y: 107))
    hp.line(to: CGPoint(x: 58, y: 102)); hp.close()
    hp.fill()
    // Worried eyes: big whites, amber iris, heavy slanted brows.
    for (cx, flip) in [(50.0, 1.0), (78.0, -1.0)] {
        let eye = NSBezierPath(ovalIn: CGRect(x: cx - 9, y: 84, width: 18, height: 16))
        flat(eye, NSColor.white, line: 2.6)
        rgb(201, 142, 63).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 5, y: 85.5, width: 10, height: 11)).fill()
        ink.setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 2.5, y: 87, width: 6, height: 7)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 0.5, y: 91, width: 2.6, height: 2.6)).fill()
        // Heavy worried brow: clear above the eye, inner end tilted up.
        let brow = NSBezierPath()
        brow.move(to: CGPoint(x: cx - 8 * flip, y: 104.5))
        brow.line(to: CGPoint(x: cx + 6 * flip, y: 108.5))
        brow.lineWidth = 4; brow.lineCapStyle = .round
        ink.setStroke(); brow.stroke()
    }
    // Frosted muzzle with jowls + big nose + mouth.
    let muzzle = NSBezierPath(roundedRect: CGRect(x: 44, y: 56, width: 40, height: 26),
                              xRadius: 12, yRadius: 12)
    flat(muzzle, grey, line: 3)
    let nose = NSBezierPath(roundedRect: CGRect(x: 55, y: 71, width: 18, height: 12),
                            xRadius: 6, yRadius: 6)
    flat(nose, ink, line: 2)
    let mouth = NSBezierPath()
    mouth.move(to: CGPoint(x: 64, y: 71))
    mouth.line(to: CGPoint(x: 64, y: 67))
    mouth.appendArc(withCenter: CGPoint(x: 60, y: 67), radius: 4, startAngle: 0, endAngle: 210, clockwise: true)
    mouth.move(to: CGPoint(x: 64, y: 67))
    mouth.appendArc(withCenter: CGPoint(x: 68, y: 67), radius: 4, startAngle: 180, endAngle: 330, clockwise: false)
    ink.setStroke(); mouth.lineWidth = 2.4; mouth.lineCapStyle = .round; mouth.stroke()
    // Comic whiskers.
    ink.setStroke()
    for (x0, y0, x1, y1) in [(44.0, 64.0, 33.0, 66.0), (44.0, 60.0, 34.0, 58.0),
                             (84.0, 64.0, 95.0, 66.0), (84.0, 60.0, 94.0, 58.0)] {
        let wsk = NSBezierPath()
        wsk.move(to: CGPoint(x: x0, y: y0)); wsk.line(to: CGPoint(x: x1, y: y1))
        wsk.lineWidth = 1.6; wsk.lineCapStyle = .round; wsk.stroke()
    }
}

// MARK: - Rendering

let directions: [(String, String, String, () -> Void)] = [
    ("A", "Plush chibi", "soft gradients, worry brows", drawChibi),
    ("B", "8-bit sprite", "NES palette, brindle dither", drawPixel),
    ("C", "Saturday cartoon", "bold ink, flat color, sitting", drawCartoon),
]

func render(_ draw: () -> Void, size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    gctx.cgContext.scaleBy(x: CGFloat(size) / 128, y: CGFloat(size) / 128)
    draw()
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (tag, name, _, draw) in directions {
    try! render(draw, size: 256).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/dog_\(tag)_\(name.lowercased().replacingOccurrences(of: " ", with: "-")).png"))
}

let cellW = 330, cellH = 410, margin = 20
let sheetW = 3 * cellW + margin * 2, sheetH = cellH + margin * 2
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sheetW, pixelsHigh: sheetH,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let sctx = NSGraphicsContext(bitmapImageRep: sheet)!
NSGraphicsContext.current = sctx
rgb(228, 224, 214).setFill()
CGRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()

for (i, (tag, name, style, draw)) in directions.enumerated() {
    let x = CGFloat(margin + i * cellW) + 8
    let y = CGFloat(margin) + 8
    let card = NSBezierPath(roundedRect: CGRect(x: x, y: y, width: CGFloat(cellW) - 16, height: CGFloat(cellH) - 16),
                            xRadius: 16, yRadius: 16)
    rgb(243, 240, 233).setFill(); card.fill()
    rgb(205, 200, 188).setStroke(); card.lineWidth = 1.5; card.stroke()
    render(draw, size: 256).draw(in: CGRect(x: x + 29, y: y + 120, width: 256, height: 256))
    render(draw, size: 128).draw(in: CGRect(x: x + 240, y: y + 34, width: 64, height: 64))
    ("\(tag) · \(name)" as NSString).draw(at: CGPoint(x: x + 24, y: y + 62),
        withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold),
                         .foregroundColor: rgb(58, 54, 47)])
    (style as NSString).draw(at: CGPoint(x: x + 24, y: y + 34),
        withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .regular),
                         .foregroundColor: rgb(122, 116, 104)])
}
sctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! sheet.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "\(outDir)/dog-directions.png"))
print("wrote \(outDir)/dog-directions.png")
