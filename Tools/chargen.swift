import AppKit

// Character-select generator: 10 candidate pet designs, each drawn in a
// 128-unit coordinate space (same convention as PetGen, ground line y≈10),
// rendered individually and onto a labeled contact sheet.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func shadow(_ w: CGFloat = 72) {
    rgb(30, 24, 18, 0.18).setFill()
    NSBezierPath(ovalIn: CGRect(x: 64 - w / 2, y: 5, width: w, height: 13)).fill()
}

// Pixel-art helper: draws a string bitmap, one character per pixel.
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

// MARK: - 1 Pip — 8-bit slime

func drawPip() {
    let O = rgb(26, 35, 64), X = rgb(78, 116, 210), H = rgb(150, 186, 250), W = NSColor.white, B = rgb(20, 22, 30)
    let map = [
        "......OOOO......",
        "....OOXXXXOO....",
        "...OXXXXXXXXO...",
        "..OXHHXXXXXXXO..",
        "..OHHXXXXXXXXO..",
        ".OXHXXXXXXXXXXO.",
        ".OXXXXXXXXXXXXO.",
        ".OXWWXXXXXXWWXO.",
        "OXXWBBXXXXWBBXXO",
        "OXXWWXXXXXXWWXXO",
        "OXXXXXXXXXXXXXXO",
        "OXXXXOXXXXOXXXXO",
        ".OXXXXOOOOXXXXO.",
        ".OXXXXXXXXXXXXO.",
        "..OOXXXXXXXXOO..",
        "....OOOOOOOO....",
    ]
    shadow(84)
    pixels(map, palette: ["O": O, "X": X, "H": H, "W": W, "B": B], px: 7, originX: 8, originY: 10)
}

// MARK: - 2 Mochi — kawaii cat-daifuku

func drawMochi() {
    shadow(76)
    let body = NSBezierPath(roundedRect: CGRect(x: 20, y: 12, width: 88, height: 74), xRadius: 34, yRadius: 34)
    rgb(255, 250, 244).setFill(); body.fill()
    rgb(148, 118, 106, 0.8).setStroke(); body.lineWidth = 2.2; body.stroke()
    // Ears: soft triangles with pink inner.
    for (x, flip) in [(30.0, 1.0), (98.0, -1.0)] {
        let ear = NSBezierPath()
        ear.move(to: CGPoint(x: x, y: 78)); ear.line(to: CGPoint(x: x + 8 * flip, y: 98))
        ear.line(to: CGPoint(x: x + 18 * flip, y: 80)); ear.close()
        rgb(255, 250, 244).setFill(); ear.fill()
        rgb(148, 118, 106, 0.8).setStroke(); ear.lineWidth = 2.2; ear.stroke()
        let inner = NSBezierPath()
        inner.move(to: CGPoint(x: x + 4 * flip, y: 80)); inner.line(to: CGPoint(x: x + 8.5 * flip, y: 91))
        inner.line(to: CGPoint(x: x + 13 * flip, y: 81)); inner.close()
        rgb(255, 189, 199).setFill(); inner.fill()
    }
    // Closed happy eyes (down-curved arcs), tiny “ω” mouth, big cheeks.
    rgb(90, 72, 64).setStroke()
    for cx in [47.0, 81.0] {
        let eye = NSBezierPath()
        eye.appendArc(withCenter: CGPoint(x: cx, y: 56), radius: 8, startAngle: 20, endAngle: 160, clockwise: false)
        eye.lineWidth = 2.8; eye.lineCapStyle = .round; eye.stroke()
    }
    let mouth = NSBezierPath()
    mouth.appendArc(withCenter: CGPoint(x: 60.5, y: 47), radius: 3.5, startAngle: 180, endAngle: 340, clockwise: true)
    mouth.appendArc(withCenter: CGPoint(x: 67.5, y: 47), radius: 3.5, startAngle: 200, endAngle: 0, clockwise: true)
    mouth.lineWidth = 2.2; mouth.lineCapStyle = .round; mouth.stroke()
    rgb(255, 170, 180, 0.55).setFill()
    NSBezierPath(ovalIn: CGRect(x: 28, y: 44, width: 14, height: 9)).fill()
    NSBezierPath(ovalIn: CGRect(x: 86, y: 44, width: 14, height: 9)).fill()
    // Nub paws.
    for x in [40.0, 72.0] {
        let paw = NSBezierPath(roundedRect: CGRect(x: x, y: 8, width: 16, height: 12), xRadius: 6, yRadius: 6)
        rgb(255, 250, 244).setFill(); paw.fill()
        rgb(148, 118, 106, 0.8).setStroke(); paw.lineWidth = 2; paw.stroke()
    }
}

// MARK: - 3 Boo — bedsheet ghost

func drawBoo() {
    shadow(60)
    let g = NSBezierPath()
    g.move(to: CGPoint(x: 26, y: 20))
    g.line(to: CGPoint(x: 26, y: 62))
    g.appendArc(withCenter: CGPoint(x: 64, y: 62), radius: 38, startAngle: 180, endAngle: 0, clockwise: true)
    g.line(to: CGPoint(x: 102, y: 20))
    // Hem: four fabric points dipping down, right to left.
    for i in 0..<4 {
        g.appendArc(withCenter: CGPoint(x: 92.5 - CGFloat(i) * 19, y: 20), radius: 9.5,
                    startAngle: 0, endAngle: 180, clockwise: true)
    }
    g.close()
    rgb(250, 250, 255).setFill(); g.fill()
    rgb(150, 155, 190, 0.7).setStroke(); g.lineWidth = 2.2; g.stroke()
    // Soft side shading inside the right edge.
    rgb(198, 203, 230, 0.45).setFill()
    NSBezierPath(ovalIn: CGRect(x: 84, y: 30, width: 13, height: 52)).fill()
    // Stubby waving arms.
    for (x, flip) in [(20.0, -1.0), (108.0, 1.0)] {
        let arm = NSBezierPath(ovalIn: CGRect(x: x - (flip > 0 ? 2 : 12), y: 52, width: 14, height: 20))
        rgb(250, 250, 255).setFill(); arm.fill()
        rgb(150, 155, 190, 0.7).setStroke(); arm.lineWidth = 2; arm.stroke()
    }
    // Face: oval eyes + "oh!" mouth + cheeks.
    rgb(40, 40, 60).setFill()
    NSBezierPath(ovalIn: CGRect(x: 45, y: 58, width: 9, height: 14)).fill()
    NSBezierPath(ovalIn: CGRect(x: 73, y: 58, width: 9, height: 14)).fill()
    NSBezierPath(ovalIn: CGRect(x: 58, y: 40, width: 11, height: 13)).fill()
    rgb(255, 190, 200, 0.5).setFill()
    NSBezierPath(ovalIn: CGRect(x: 35, y: 50, width: 11, height: 7)).fill()
    NSBezierPath(ovalIn: CGRect(x: 83, y: 50, width: 11, height: 7)).fill()
}

// MARK: - 4 Rusty — tin robot

func drawRusty() {
    shadow(74)
    // Feet pads.
    for x in [36.0, 72.0] {
        rgb(120, 124, 130).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: 8, width: 20, height: 12), xRadius: 4, yRadius: 4).fill()
    }
    // Body.
    let body = NSBezierPath(roundedRect: CGRect(x: 26, y: 18, width: 76, height: 74), xRadius: 12, yRadius: 12)
    NSGradient(starting: rgb(105, 168, 162), ending: rgb(62, 118, 113))?.draw(in: body, angle: -90)
    rgb(38, 74, 70).setStroke(); body.lineWidth = 2.4; body.stroke()
    // Faceplate + visor eyes.
    let plate = NSBezierPath(roundedRect: CGRect(x: 36, y: 52, width: 56, height: 30), xRadius: 8, yRadius: 8)
    rgb(210, 214, 218).setFill(); plate.fill()
    rgb(120, 124, 130).setStroke(); plate.lineWidth = 1.8; plate.stroke()
    rgb(30, 34, 44).setFill()
    NSBezierPath(roundedRect: CGRect(x: 42, y: 58, width: 44, height: 18), xRadius: 9, yRadius: 9).fill()
    rgb(120, 235, 255).setFill()
    NSBezierPath(ovalIn: CGRect(x: 50, y: 62, width: 10, height: 10)).fill()
    NSBezierPath(ovalIn: CGRect(x: 68, y: 62, width: 10, height: 10)).fill()
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(ovalIn: CGRect(x: 53, y: 67, width: 3.5, height: 3.5)).fill()
    NSBezierPath(ovalIn: CGRect(x: 71, y: 67, width: 3.5, height: 3.5)).fill()
    // Chest dial + rivets + mouth grille.
    rgb(210, 214, 218).setFill()
    NSBezierPath(ovalIn: CGRect(x: 56, y: 26, width: 16, height: 16)).fill()
    rgb(233, 90, 70).setFill()
    NSBezierPath(ovalIn: CGRect(x: 61, y: 31, width: 6, height: 6)).fill()
    rgb(38, 74, 70).setFill()
    for x in [32.0, 92.0] { for y in [26.0, 84.0] {
        NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 4, height: 4)).fill()
    } }
    rgb(38, 74, 70).setStroke()
    for i in 0..<3 {
        let m = NSBezierPath()
        m.move(to: CGPoint(x: 52 + CGFloat(i) * 9, y: 46)); m.line(to: CGPoint(x: 58 + CGFloat(i) * 9, y: 46))
        m.lineWidth = 2; m.lineCapStyle = .round; m.stroke()
    }
    // Antenna.
    let ant = NSBezierPath()
    ant.move(to: CGPoint(x: 64, y: 92)); ant.line(to: CGPoint(x: 64, y: 106))
    rgb(120, 124, 130).setStroke(); ant.lineWidth = 3; ant.lineCapStyle = .round; ant.stroke()
    rgb(233, 90, 70).setFill()
    NSBezierPath(ovalIn: CGRect(x: 58, y: 104, width: 12, height: 12)).fill()
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(ovalIn: CGRect(x: 60.5, y: 109, width: 4, height: 4)).fill()
}

// MARK: - 5 Cathode — CRT monitor buddy

func drawCathode() {
    shadow(80)
    // Curly power-cord tail.
    let cord = NSBezierPath()
    cord.move(to: CGPoint(x: 100, y: 26))
    cord.curve(to: CGPoint(x: 118, y: 34), controlPoint1: CGPoint(x: 110, y: 22), controlPoint2: CGPoint(x: 120, y: 24))
    cord.curve(to: CGPoint(x: 108, y: 44), controlPoint1: CGPoint(x: 116, y: 44), controlPoint2: CGPoint(x: 104, y: 50))
    rgb(108, 98, 84).setStroke(); cord.lineWidth = 3.5; cord.lineCapStyle = .round; cord.stroke()
    // Feet.
    for x in [38.0, 74.0] {
        rgb(178, 166, 142).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: 8, width: 16, height: 12), xRadius: 5, yRadius: 5).fill()
    }
    // Shell.
    let shell = NSBezierPath(roundedRect: CGRect(x: 22, y: 16, width: 84, height: 78), xRadius: 10, yRadius: 10)
    NSGradient(starting: rgb(226, 216, 192), ending: rgb(196, 184, 156))?.draw(in: shell, angle: -90)
    rgb(140, 128, 104).setStroke(); shell.lineWidth = 2.4; shell.stroke()
    // Screen inset with green phosphor face.
    let screen = NSBezierPath(roundedRect: CGRect(x: 32, y: 34, width: 64, height: 50), xRadius: 7, yRadius: 7)
    rgb(24, 34, 26).setFill(); screen.fill()
    rgb(120, 110, 90).setStroke(); screen.lineWidth = 1.6; screen.stroke()
    let g = rgb(96, 234, 128)
    g.setFill()
    // Pixel face on screen: two eye bars + a stepped grin.
    for x in [44.0, 74.0] { CGRect(x: x, y: 60, width: 9, height: 13).fill() }
    CGRect(x: 50, y: 41, width: 28, height: 6).fill()
    CGRect(x: 44, y: 46, width: 7, height: 6).fill()
    CGRect(x: 77, y: 46, width: 7, height: 6).fill()
    // Scanlines.
    rgb(24, 34, 26, 0.55).setFill()
    var y: CGFloat = 36
    while y < 82 { CGRect(x: 33, y: y, width: 62, height: 1.2).fill(); y += 4 }
    // Vents + LED.
    rgb(140, 128, 104).setFill()
    for i in 0..<4 { CGRect(x: 36 + CGFloat(i) * 10, y: 24, width: 6, height: 3).fill() }
    rgb(233, 90, 70).setFill()
    NSBezierPath(ovalIn: CGRect(x: 92, y: 22, width: 6, height: 6)).fill()
}

// MARK: - 6 Zzzul — eldritch cutie

func drawZzzul() {
    shadow(78)
    // Tentacle feet: five nubs.
    for i in 0..<5 {
        let x = 30 + CGFloat(i) * 17
        let t = NSBezierPath(roundedRect: CGRect(x: x, y: 6, width: 12, height: 22 + (i % 2 == 0 ? 0 : 6)),
                             xRadius: 6, yRadius: 6)
        rgb(96, 66, 148).setFill(); t.fill()
    }
    // Body.
    let body = NSBezierPath(roundedRect: CGRect(x: 24, y: 20, width: 80, height: 78), xRadius: 34, yRadius: 34)
    NSGradient(starting: rgb(130, 96, 188), ending: rgb(88, 60, 140))?.draw(in: body, angle: -90)
    rgb(58, 38, 96).setStroke(); body.lineWidth = 2.4; body.stroke()
    // Three glossy eyes: big center, two small.
    func eye(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).fill()
        rgb(40, 26, 60).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - r * 0.5, y: cy - r * 0.45, width: r, height: r * 1.05)).fill()
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - r * 0.15, y: cy + r * 0.25, width: r * 0.4, height: r * 0.4)).fill()
    }
    eye(64, 66, 13)
    eye(41, 70, 7)
    eye(87, 70, 7)
    // Smile with one tiny fang.
    let smile = NSBezierPath()
    smile.appendArc(withCenter: CGPoint(x: 64, y: 46), radius: 8, startAngle: 200, endAngle: 340, clockwise: false)
    rgb(40, 26, 60).setStroke(); smile.lineWidth = 2.5; smile.lineCapStyle = .round; smile.stroke()
    let fang = NSBezierPath()
    fang.move(to: CGPoint(x: 69, y: 41)); fang.line(to: CGPoint(x: 71.5, y: 35)); fang.line(to: CGPoint(x: 74, y: 41.5))
    fang.close()
    NSColor.white.setFill(); fang.fill()
    // Freckle glow dots.
    rgb(190, 160, 255, 0.8).setFill()
    for (x, y) in [(34.0, 88.0), (44.0, 92.0), (86.0, 90.0), (94.0, 84.0)] {
        NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 3.5, height: 3.5)).fill()
    }
}

// MARK: - 7 Kitsu — origami fox (hard polygons only)

func drawKitsu() {
    shadow(78)
    func poly(_ pts: [(CGFloat, CGFloat)], _ color: NSColor, stroke: NSColor? = nil) {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for pt in pts.dropFirst() { p.line(to: CGPoint(x: pt.0, y: pt.1)) }
        p.close()
        color.setFill(); p.fill()
        if let s = stroke { s.setStroke(); p.lineWidth = 1.4; p.stroke() }
    }
    let orange = rgb(232, 130, 60), dark = rgb(196, 100, 38), cream = rgb(255, 244, 228)
    let fold = rgb(150, 74, 24, 0.55)
    // Legs (trapezoids).
    poly([(36, 8), (50, 8), (48, 30), (38, 30)], dark)
    poly([(78, 8), (92, 8), (90, 30), (80, 30)], dark)
    // Body: faceted diamond.
    poly([(24, 46), (64, 22), (104, 46), (64, 60)], orange, stroke: fold)
    poly([(24, 46), (64, 60), (64, 74), (30, 60)], dark, stroke: fold)
    poly([(104, 46), (64, 60), (64, 74), (98, 60)], orange, stroke: fold)
    // Head: wide triangle + cream snout facets.
    poly([(34, 74), (64, 104), (94, 74), (64, 62)], orange, stroke: fold)
    poly([(48, 74), (64, 62), (64, 84)], cream, stroke: fold)
    poly([(80, 74), (64, 62), (64, 84)], cream, stroke: fold)
    // Ears: tall triangles.
    poly([(36, 96), (46, 122), (56, 98)], orange, stroke: fold)
    poly([(92, 96), (82, 122), (72, 98)], orange, stroke: fold)
    poly([(41, 99), (46, 114), (52, 100)], rgb(60, 40, 34))
    poly([(87, 99), (82, 114), (76, 100)], rgb(60, 40, 34))
    // Eyes: bold angular slits on the orange, clear of the snout; nose diamond.
    poly([(40, 84), (54, 89), (40, 94)], rgb(40, 26, 22))
    poly([(88, 84), (74, 89), (88, 94)], rgb(40, 26, 22))
    poly([(64, 68), (69, 73), (64, 78), (59, 73)], rgb(40, 26, 22))
}

// MARK: - 8 Daru — daruma

func drawDaru() {
    shadow(80)
    // Nearly-full circle with a small flat base (290deg -> 250deg the long
    // way round leaves a 31pt-wide chord at the bottom).
    let body = NSBezierPath()
    body.appendArc(withCenter: CGPoint(x: 64, y: 58), radius: 46,
                   startAngle: 290, endAngle: 250, clockwise: false)
    body.close()
    NSGradient(starting: rgb(220, 78, 66), ending: rgb(176, 48, 42))?.draw(in: body, angle: -90)
    rgb(130, 32, 30).setStroke(); body.lineWidth = 2.6; body.stroke()
    // Gold trim: two arcs hugging the lower belly.
    for (r, w) in [(36.0, 3.2), (41.0, 1.8)] {
        let trim = NSBezierPath()
        trim.appendArc(withCenter: CGPoint(x: 64, y: 58), radius: r,
                       startAngle: 245, endAngle: 295, clockwise: false)
        rgb(228, 178, 74).setStroke(); trim.lineWidth = w; trim.lineCapStyle = .round; trim.stroke()
    }
    // Cream face window.
    let face = NSBezierPath(ovalIn: CGRect(x: 36, y: 44, width: 56, height: 50))
    rgb(250, 238, 214).setFill(); face.fill()
    rgb(130, 32, 30, 0.4).setStroke(); face.lineWidth = 1.8; face.stroke()
    // Bold brush eyebrows, determined eyes, mustache strokes.
    let ink = rgb(36, 28, 26)
    ink.setStroke()
    for (cx, flip) in [(51.0, 1.0), (77.0, -1.0)] {
        let brow = NSBezierPath()
        brow.move(to: CGPoint(x: cx - 8 * flip, y: 79))
        brow.curve(to: CGPoint(x: cx + 8 * flip, y: 83),
                   controlPoint1: CGPoint(x: cx - 2 * flip, y: 85), controlPoint2: CGPoint(x: cx + 4 * flip, y: 86))
        brow.lineWidth = 4; brow.lineCapStyle = .round; brow.stroke()
    }
    ink.setFill()
    NSBezierPath(ovalIn: CGRect(x: 44, y: 63, width: 12, height: 12)).fill()
    NSBezierPath(ovalIn: CGRect(x: 72, y: 63, width: 12, height: 12)).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: CGRect(x: 48, y: 69, width: 4, height: 4)).fill()
    NSBezierPath(ovalIn: CGRect(x: 76, y: 69, width: 4, height: 4)).fill()
    ink.setStroke()
    for (cx, flip) in [(56.0, 1.0), (72.0, -1.0)] {
        let mo = NSBezierPath()
        mo.move(to: CGPoint(x: cx, y: 56))
        mo.curve(to: CGPoint(x: cx - 12 * flip, y: 51),
                 controlPoint1: CGPoint(x: cx - 5 * flip, y: 56), controlPoint2: CGPoint(x: cx - 10 * flip, y: 54))
        mo.lineWidth = 2.6; mo.lineCapStyle = .round; mo.stroke()
    }
    // Gold diamond on the belly.
    let d = NSBezierPath()
    d.move(to: CGPoint(x: 64, y: 38)); d.line(to: CGPoint(x: 70, y: 31))
    d.line(to: CGPoint(x: 64, y: 24)); d.line(to: CGPoint(x: 58, y: 31)); d.close()
    rgb(228, 178, 74).setFill(); d.fill()
}

// MARK: - 9 Sol — synthwave sun

func drawSol() {
    // Chrome grid floor shadow instead of soft ellipse.
    rgb(255, 60, 172, 0.35).setStroke()
    for i in 0..<3 {
        let ln = NSBezierPath()
        ln.move(to: CGPoint(x: 30 - CGFloat(i) * 6, y: 6 + CGFloat(i) * 4))
        ln.line(to: CGPoint(x: 98 + CGFloat(i) * 6, y: 6 + CGFloat(i) * 4))
        ln.lineWidth = 1.4; ln.stroke()
    }
    // Sun disc: banded gradient with slat gaps in the lower half.
    let cx: CGFloat = 64, cy: CGFloat = 60, r: CGFloat = 42
    let disc = NSBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    NSGraphicsContext.current?.saveGraphicsState()
    disc.addClip()
    let bands: [(NSColor, CGFloat, CGFloat)] = [
        (rgb(255, 214, 90), 60, 102),   // top: yellow
        (rgb(255, 160, 74), 44, 60),
        (rgb(255, 110, 92), 34, 44),
        (rgb(255, 60, 172), 18, 34),
        (rgb(210, 40, 190), 18, 30),
    ]
    for (color, y0, y1) in bands {
        color.setFill()
        CGRect(x: cx - r, y: y0, width: 2 * r, height: y1 - y0).fill()
    }
    // Slat gaps (transparent stripes) in the lower half.
    NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
    for (y, h) in [(52.0, 3.0), (44.0, 3.5), (36.0, 4.0), (27.0, 4.5)] {
        CGRect(x: cx - r, y: y, width: 2 * r, height: h).fill()
    }
    NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
    NSGraphicsContext.current?.restoreGraphicsState()
    rgb(255, 120, 200, 0.9).setStroke(); disc.lineWidth = 2.4; disc.stroke()
    // Wayfarer shades.
    let shade = rgb(24, 18, 34)
    shade.setFill()
    NSBezierPath(roundedRect: CGRect(x: 40, y: 66, width: 21, height: 14), xRadius: 4, yRadius: 4).fill()
    NSBezierPath(roundedRect: CGRect(x: 67, y: 66, width: 21, height: 14), xRadius: 4, yRadius: 4).fill()
    CGRect(x: 59, y: 71, width: 10, height: 3.5).fill()
    CGRect(x: 30, y: 71, width: 12, height: 3.5).fill()
    CGRect(x: 86, y: 71, width: 12, height: 3.5).fill()
    NSColor.white.withAlphaComponent(0.35).setFill()
    NSBezierPath(roundedRect: CGRect(x: 43, y: 73, width: 8, height: 4), xRadius: 2, yRadius: 2).fill()
    // Smirk.
    let smirk = NSBezierPath()
    smirk.move(to: CGPoint(x: 52, y: 56))
    smirk.curve(to: CGPoint(x: 74, y: 58), controlPoint1: CGPoint(x: 60, y: 52), controlPoint2: CGPoint(x: 70, y: 53))
    rgb(24, 18, 34).setStroke(); smirk.lineWidth = 2.6; smirk.lineCapStyle = .round; smirk.stroke()
    // Stick feet.
    rgb(24, 18, 34).setStroke()
    for x in [52.0, 76.0] {
        let leg = NSBezierPath()
        leg.move(to: CGPoint(x: x, y: 20)); leg.line(to: CGPoint(x: x, y: 8))
        leg.lineWidth = 3.5; leg.lineCapStyle = .round; leg.stroke()
    }
}

// MARK: - 10 Morel — cottagecore mushroom sprite

func drawMorel() {
    shadow(70)
    // Boots.
    for x in [42.0, 68.0] {
        let boot = NSBezierPath(roundedRect: CGRect(x: x, y: 8, width: 18, height: 13), xRadius: 5, yRadius: 5)
        rgb(122, 88, 62).setFill(); boot.fill()
    }
    // Stem body.
    let stem = NSBezierPath(roundedRect: CGRect(x: 38, y: 16, width: 52, height: 52), xRadius: 20, yRadius: 20)
    NSGradient(starting: rgb(248, 238, 216), ending: rgb(226, 208, 178))?.draw(in: stem, angle: -90)
    rgb(150, 122, 92, 0.7).setStroke(); stem.lineWidth = 2; stem.stroke()
    // Cap: wide dome with a gently under-curved brim.
    let cap = NSBezierPath()
    cap.move(to: CGPoint(x: 16, y: 66))
    cap.appendArc(withCenter: CGPoint(x: 64, y: 66), radius: 48, startAngle: 180, endAngle: 0, clockwise: true)
    cap.curve(to: CGPoint(x: 16, y: 66),
              controlPoint1: CGPoint(x: 84, y: 56), controlPoint2: CGPoint(x: 44, y: 56))
    cap.close()
    NSGradient(starting: rgb(214, 92, 78), ending: rgb(178, 62, 56))?.draw(in: cap, angle: -90)
    rgb(134, 44, 40).setStroke(); cap.lineWidth = 2.2; cap.stroke()
    // Spots on the dome.
    rgb(250, 240, 222).setFill()
    NSBezierPath(ovalIn: CGRect(x: 36, y: 84, width: 13, height: 10)).fill()
    NSBezierPath(ovalIn: CGRect(x: 58, y: 96, width: 16, height: 12)).fill()
    NSBezierPath(ovalIn: CGRect(x: 84, y: 80, width: 11, height: 9)).fill()
    NSBezierPath(ovalIn: CGRect(x: 50, y: 70, width: 8, height: 6)).fill()
    NSBezierPath(ovalIn: CGRect(x: 76, y: 68, width: 7, height: 5)).fill()
    // Sleepy-sweet face on the stem.
    rgb(74, 58, 48).setFill()
    NSBezierPath(ovalIn: CGRect(x: 49, y: 40, width: 7, height: 9)).fill()
    NSBezierPath(ovalIn: CGRect(x: 72, y: 40, width: 7, height: 9)).fill()
    let smile = NSBezierPath()
    smile.appendArc(withCenter: CGPoint(x: 64, y: 34), radius: 5, startAngle: 200, endAngle: 340, clockwise: false)
    rgb(74, 58, 48).setStroke(); smile.lineWidth = 2.2; smile.lineCapStyle = .round; smile.stroke()
    rgb(224, 130, 116, 0.6).setFill()
    NSBezierPath(ovalIn: CGRect(x: 41, y: 34, width: 10, height: 7)).fill()
    NSBezierPath(ovalIn: CGRect(x: 77, y: 34, width: 10, height: 7)).fill()
    // Tiny grass tufts.
    rgb(122, 160, 92).setStroke()
    for (x, h) in [(28.0, 10.0), (32.0, 14.0), (98.0, 12.0), (94.0, 8.0)] {
        let blade = NSBezierPath()
        blade.move(to: CGPoint(x: x, y: 6)); blade.line(to: CGPoint(x: x + 2, y: 6 + h))
        blade.lineWidth = 2; blade.lineCapStyle = .round; blade.stroke()
    }
}

// MARK: - Rendering

let characters: [(Int, String, String, () -> Void)] = [
    (1, "Pip", "8-bit slime", drawPip),
    (2, "Mochi", "kawaii cat-daifuku", drawMochi),
    (3, "Boo", "bedsheet ghost", drawBoo),
    (4, "Rusty", "tin toy robot", drawRusty),
    (5, "Cathode", "CRT monitor buddy", drawCathode),
    (6, "Zzzul", "eldritch cutie", drawZzzul),
    (7, "Kitsu", "origami fox", drawKitsu),
    (8, "Daru", "daruma doll", drawDaru),
    (9, "Sol", "synthwave sun", drawSol),
    (10, "Morel", "mushroom sprite", drawMorel),
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

// Individual renders.
for (n, name, _, draw) in characters {
    let rep = render(draw, size: 256)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/char_\(n)_\(name.lowercased()).png"))
}

// Contact sheet: 5×2 cards, each with the 256 render, a true-64pt version,
// and a label.
let cols = 5, rows = 2
let cellW = 310, cellH = 400, margin = 20
let sheetW = cols * cellW + margin * 2, sheetH = rows * cellH + margin * 2
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sheetW, pixelsHigh: sheetH,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let sctx = NSGraphicsContext(bitmapImageRep: sheet)!
NSGraphicsContext.current = sctx

rgb(228, 224, 214).setFill()
CGRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()

for (i, (n, name, style, draw)) in characters.enumerated() {
    let col = i % cols, row = i / cols
    let x = CGFloat(margin + col * cellW) + 8
    let y = CGFloat(margin + (rows - 1 - row) * cellH) + 8
    let card = NSBezierPath(roundedRect: CGRect(x: x, y: y, width: CGFloat(cellW) - 16, height: CGFloat(cellH) - 16),
                            xRadius: 16, yRadius: 16)
    rgb(243, 240, 233).setFill(); card.fill()
    rgb(205, 200, 188).setStroke(); card.lineWidth = 1.5; card.stroke()

    let big = render(draw, size: 256)
    big.draw(in: CGRect(x: x + 19, y: y + 110, width: 256, height: 256))
    let small = render(draw, size: 128)
    small.draw(in: CGRect(x: x + 224, y: y + 30, width: 64, height: 64))

    let title = "\(n) · \(name)" as NSString
    title.draw(at: CGPoint(x: x + 22, y: y + 58),
               withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold),
                                .foregroundColor: rgb(58, 54, 47)])
    (style as NSString).draw(at: CGPoint(x: x + 22, y: y + 30),
                             withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .regular),
                                              .foregroundColor: rgb(122, 116, 104)])
}
sctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! sheet.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "\(outDir)/character-select.png"))
print("wrote \(outDir)/character-select.png and 10 individual renders")
