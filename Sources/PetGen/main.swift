import AppKit

// Rusty v3: pose-parameterized frames rendered per skin. Geometry (poses,
// proportions, wide-set eyes) is the user-approved v2 shape; every color
// runs through a Skin palette so the same rig ships in multiple finishes.
// Craft details that keep it from looking machine-generated: screw slots at
// irregular angles, one oversized rivet, an off-center antenna, and (on
// worn skins) chipped enamel plus lithographed pinstripes.
// Output: argv[1]/pet_<skin>_<frame>.png for every skin, plus pet.png.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

struct Pose {
    enum Eyes { case open, alarm, off }
    enum Mouth { case grille, o, smile }
    var scaleY: CGFloat = 1.0
    var eyes: Eyes = .open
    var glintDY: CGFloat = 0
    var glintDX: CGFloat = 0         // look-around micro-fidget
    var mouth: Mouth = .grille
    var footLiftL: CGFloat = 0
    var footLiftR: CGFloat = 0
    var dangleFeet = false
    var tilt: CGFloat = 0
    var antennaBend: CGFloat = 0
    var grounded = true
    var dialGreen = false
    var sleepZs = false
    var dust: Int = 0                // 0 none, 1 landing burst, 2 fading
    var speedLines = false           // fall motion streaks
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

struct Skin {
    let id: String
    let bodyTop, bodyBottom: NSColor
    let bodyStroke: NSColor
    let rim: NSColor
    let plateTop, plateBottom: NSColor
    let metal: NSColor               // screws-stroke, plate stroke, antenna stem
    let metalLight: NSColor          // screw caps, coils
    let visorTop, visorBottom: NSColor
    let eye: NSColor
    let alarm: NSColor
    let offSlit: NSColor
    let footPad, footTread: NSColor
    let dialDot: NSColor
    let dialSleep: NSColor
    let tipTop, tipBottom: NSColor   // antenna ball
    let zColor: NSColor
    let speedLine: NSColor
    let worn: Bool                   // chipped enamel + pinstripes
    let stripe: NSColor
}

let skins: [Skin] = [
    // Hand-painted vintage windup: cream enamel, brass, warm amber eyes.
    Skin(id: "tinplate",
         bodyTop: rgb(241, 231, 208), bodyBottom: rgb(212, 197, 167),
         bodyStroke: rgb(96, 76, 58), rim: rgb(255, 250, 236, 0.6),
         plateTop: rgb(248, 241, 224), plateBottom: rgb(224, 212, 188),
         metal: rgb(150, 126, 84), metalLight: rgb(196, 170, 112),
         visorTop: rgb(56, 47, 40), visorBottom: rgb(30, 25, 21),
         eye: rgb(255, 199, 92), alarm: rgb(255, 128, 70),
         offSlit: rgb(172, 148, 112, 0.85),
         footPad: rgb(122, 108, 92), footTread: rgb(66, 56, 46),
         dialDot: rgb(198, 74, 56), dialSleep: rgb(122, 186, 116),
         tipTop: rgb(226, 96, 74), tipBottom: rgb(178, 58, 42),
         zColor: rgb(214, 188, 140, 0.95), speedLine: rgb(240, 224, 190, 0.4),
         worn: true, stripe: rgb(178, 62, 46, 0.5)),
    // The previous look, kept as a skin: brushed sea-glass tin.
    Skin(id: "seafoam",
         bodyTop: rgb(112, 176, 168), bodyBottom: rgb(56, 110, 105),
         bodyStroke: rgb(34, 68, 64), rim: rgb(220, 255, 250, 0.55),
         plateTop: rgb(226, 230, 234), plateBottom: rgb(196, 200, 206),
         metal: rgb(120, 124, 130), metalLight: rgb(160, 164, 170),
         visorTop: rgb(40, 48, 62), visorBottom: rgb(18, 22, 32),
         eye: rgb(120, 235, 255), alarm: rgb(255, 180, 74),
         offSlit: rgb(96, 150, 160, 0.8),
         footPad: rgb(96, 100, 108), footTread: rgb(52, 56, 62),
         dialDot: rgb(233, 90, 70), dialSleep: rgb(96, 214, 118),
         tipTop: rgb(245, 120, 100), tipBottom: rgb(210, 70, 52),
         zColor: rgb(150, 210, 220, 0.9), speedLine: rgb(190, 240, 250, 0.35),
         worn: false, stripe: .clear),
    // Gunmetal night shift.
    Skin(id: "midnight",
         bodyTop: rgb(78, 88, 104), bodyBottom: rgb(40, 46, 58),
         bodyStroke: rgb(20, 24, 32), rim: rgb(190, 210, 235, 0.4),
         plateTop: rgb(198, 205, 214), plateBottom: rgb(158, 166, 178),
         metal: rgb(110, 118, 130), metalLight: rgb(150, 158, 172),
         visorTop: rgb(28, 33, 44), visorBottom: rgb(10, 13, 20),
         eye: rgb(150, 235, 255), alarm: rgb(255, 150, 84),
         offSlit: rgb(110, 150, 176, 0.8),
         footPad: rgb(70, 76, 88), footTread: rgb(34, 38, 48),
         dialDot: rgb(120, 200, 255), dialSleep: rgb(96, 214, 118),
         tipTop: rgb(150, 190, 240), tipBottom: rgb(90, 130, 190),
         zColor: rgb(160, 190, 225, 0.9), speedLine: rgb(170, 210, 245, 0.35),
         worn: false, stripe: .clear),
    // Hand-painted sakura: blossom enamel, plum visor, soft gold eyes.
    Skin(id: "sakura",
         bodyTop: rgb(243, 197, 205), bodyBottom: rgb(216, 152, 165),
         bodyStroke: rgb(120, 62, 76), rim: rgb(255, 240, 244, 0.6),
         plateTop: rgb(250, 240, 238), plateBottom: rgb(232, 214, 212),
         metal: rgb(164, 118, 118), metalLight: rgb(206, 164, 158),
         visorTop: rgb(66, 42, 56), visorBottom: rgb(36, 22, 32),
         eye: rgb(255, 214, 130), alarm: rgb(255, 132, 92),
         offSlit: rgb(190, 140, 150, 0.85),
         footPad: rgb(140, 108, 112), footTread: rgb(84, 58, 64),
         dialDot: rgb(214, 92, 108), dialSleep: rgb(128, 190, 128),
         tipTop: rgb(236, 120, 130), tipBottom: rgb(190, 74, 92),
         zColor: rgb(232, 190, 176, 0.95), speedLine: rgb(250, 226, 218, 0.4),
         worn: true, stripe: rgb(150, 74, 92, 0.45)),
]

func render(_ pose: Pose, _ s: Skin) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: 128, height: 128))

    if pose.grounded {
        rgb(30, 24, 18, 0.20).setFill()
        NSBezierPath(ovalIn: CGRect(x: 26, y: 5, width: 76, height: 14)).fill()
    }
    if pose.dust > 0 {
        let a: CGFloat = pose.dust == 1 ? 0.5 : 0.22
        let spread: CGFloat = pose.dust == 1 ? 0 : 8
        rgb(200, 196, 188, a).setFill()
        NSBezierPath(ovalIn: CGRect(x: 24 - spread, y: 8, width: 16, height: 9)).fill()
        NSBezierPath(ovalIn: CGRect(x: 88 + spread, y: 8, width: 16, height: 9)).fill()
    }
    if pose.speedLines {
        s.speedLine.setStroke()
        for x in [40.0, 64.0, 88.0] {
            let ln = NSBezierPath()
            ln.move(to: CGPoint(x: x, y: 102))
            ln.line(to: CGPoint(x: x, y: 121))
            ln.lineWidth = 2.5; ln.lineCapStyle = .round; ln.stroke()
        }
    }

    ctx.saveGState()
    let sy = pose.scaleY
    let sx = 1 + (1 - sy) * 0.7
    ctx.translateBy(x: 64, y: 55)
    ctx.rotate(by: pose.tilt * .pi / 180)
    ctx.translateBy(x: -64, y: -55)
    ctx.translateBy(x: 64, y: 10)
    ctx.scaleBy(x: sx, y: sy)
    ctx.translateBy(x: -64, y: -10)

    // Feet: rubber treads.
    func foot(x: CGFloat, y: CGFloat, w: CGFloat = 20, h: CGFloat = 12) {
        s.footPad.setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                     xRadius: 4, yRadius: 4).fill()
        s.footTread.setStroke()
        for i in 0..<3 {
            let t = NSBezierPath()
            t.move(to: CGPoint(x: x + 4 + CGFloat(i) * 6, y: y + 0.5))
            t.line(to: CGPoint(x: x + 4 + CGFloat(i) * 6, y: y + 4))
            t.lineWidth = 1.6; t.stroke()
        }
    }
    if pose.dangleFeet {
        foot(x: 40, y: 3, w: 17, h: 11)
        foot(x: 72, y: 3, w: 17, h: 11)
    } else {
        foot(x: 36, y: 8 + pose.footLiftL)
        foot(x: 72, y: 8 + pose.footLiftR)
    }

    // Body: enamel with a soft band sheen and rim light.
    let body = NSBezierPath(roundedRect: CGRect(x: 26, y: 18, width: 76, height: 74),
                            xRadius: 12, yRadius: 12)
    NSGradient(starting: s.bodyTop, ending: s.bodyBottom)?.draw(in: body, angle: -90)
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    rgb(255, 255, 255, 0.10).setFill()
    for y in [26.0, 40.0, 84.0] { CGRect(x: 26, y: y, width: 76, height: 4).fill() }
    rgb(0, 0, 0, 0.10).setFill()
    CGRect(x: 26, y: 18, width: 76, height: 6).fill()
    if s.worn {
        // Lithographed pinstripes, slightly uneven by hand.
        s.stripe.setStroke()
        for (y, wobble) in [(23.5, 0.4), (87.0, -0.6)] {
            let stripe = NSBezierPath()
            stripe.move(to: CGPoint(x: 27, y: y))
            stripe.curve(to: CGPoint(x: 101, y: y + wobble),
                         controlPoint1: CGPoint(x: 52, y: y - wobble),
                         controlPoint2: CGPoint(x: 78, y: y + wobble))
            stripe.lineWidth = 1.6; stripe.stroke()
        }
    }
    let rim = NSBezierPath(roundedRect: CGRect(x: 27.5, y: 19.5, width: 73, height: 71),
                           xRadius: 11, yRadius: 11)
    s.rim.setStroke(); rim.lineWidth = 2; rim.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()
    s.bodyStroke.setStroke(); body.lineWidth = 2.4; body.stroke()
    if s.worn {
        // A chipped-enamel bite on the shoulder, bare metal showing through.
        let chip = NSBezierPath()
        chip.move(to: CGPoint(x: 93, y: 92.2))
        chip.line(to: CGPoint(x: 97.5, y: 89.5))
        chip.line(to: CGPoint(x: 94.5, y: 87))
        chip.line(to: CGPoint(x: 91.5, y: 89.8))
        chip.close()
        s.metalLight.setFill(); chip.fill()
        s.bodyStroke.withAlphaComponent(0.7).setStroke(); chip.lineWidth = 1; chip.stroke()
    }

    // Corner screws: slots at whatever angle the little screwdriver left
    // them, and the bottom-right rivet is a size up. Hands did this.
    let slotAngles: [CGFloat] = [0.14, -0.42, 0.65, -0.08]
    for (i, (x, y)) in [(33.0, 25.0), (89.0, 25.0), (33.0, 83.0), (89.0, 83.0)].enumerated() {
        let d: CGFloat = i == 1 ? 7 : 6
        s.metalLight.setFill()
        NSBezierPath(ovalIn: CGRect(x: x, y: y, width: d, height: d)).fill()
        s.metal.setStroke()
        let slot = NSBezierPath()
        let cx = x + d / 2, cy = y + d / 2, r = d / 2 - 1.2
        let a = slotAngles[i]
        slot.move(to: CGPoint(x: cx - cos(a) * r, y: cy - sin(a) * r))
        slot.line(to: CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
        slot.lineWidth = 1.2; slot.stroke()
    }

    // Faceplate + glass visor.
    let plate = NSBezierPath(roundedRect: CGRect(x: 36, y: 52, width: 56, height: 30),
                             xRadius: 8, yRadius: 8)
    NSGradient(starting: s.plateTop, ending: s.plateBottom)?.draw(in: plate, angle: -90)
    s.metal.setStroke(); plate.lineWidth = 1.8; plate.stroke()
    let visor = NSBezierPath(roundedRect: CGRect(x: 41, y: 58, width: 46, height: 18),
                             xRadius: 9, yRadius: 9)
    NSGradient(starting: s.visorTop, ending: s.visorBottom)?.draw(in: visor, angle: -90)

    // Eyes, set wide (user-confirmed): centers at x=51 and x=77.
    switch pose.eyes {
    case .open:
        for x in [46.0, 72.0] {
            s.eye.withAlphaComponent(0.28).setFill()
            NSBezierPath(ovalIn: CGRect(x: x - 2.5, y: 59.5, width: 15, height: 15)).fill()
            s.eye.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: 62, width: 10, height: 10)).fill()
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: CGRect(x: x + 3 + pose.glintDX, y: 67 + pose.glintDY,
                                        width: 3.5, height: 3.5)).fill()
        }
    case .alarm:
        for x in [44.0, 71.0] {
            s.alarm.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: CGRect(x: x - 3, y: 57.5, width: 19, height: 19)).fill()
            s.alarm.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: 60.5, width: 13, height: 13)).fill()
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: CGRect(x: x + 4 + pose.glintDX, y: 64 + pose.glintDY,
                                        width: 4.5, height: 4.5)).fill()
        }
    case .off:
        s.offSlit.setStroke()
        for x in [46.0, 72.0] {
            let slit = NSBezierPath()
            slit.move(to: CGPoint(x: x, y: 67)); slit.line(to: CGPoint(x: x + 10, y: 67))
            slit.lineWidth = 2.5; slit.lineCapStyle = .round; slit.stroke()
        }
    }
    // Visor reflection streak.
    NSGraphicsContext.current?.saveGraphicsState()
    visor.addClip()
    rgb(255, 255, 255, 0.13).setFill()
    let streak = NSBezierPath()
    streak.move(to: CGPoint(x: 45, y: 76)); streak.line(to: CGPoint(x: 57, y: 76))
    streak.line(to: CGPoint(x: 49, y: 58)); streak.line(to: CGPoint(x: 41, y: 58)); streak.close()
    streak.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Mouth zone.
    switch pose.mouth {
    case .grille:
        s.bodyStroke.setStroke()
        for i in 0..<3 {
            let m = NSBezierPath()
            m.move(to: CGPoint(x: 52 + CGFloat(i) * 9, y: 46))
            m.line(to: CGPoint(x: 58 + CGFloat(i) * 9, y: 46))
            m.lineWidth = 2; m.lineCapStyle = .round; m.stroke()
        }
    case .o:
        s.bodyStroke.setStroke()
        let o = NSBezierPath(ovalIn: CGRect(x: 59.5, y: 41, width: 9, height: 10))
        o.lineWidth = 2.5; o.stroke()
    case .smile:
        s.bodyStroke.setStroke()
        let smile = NSBezierPath()
        smile.appendArc(withCenter: CGPoint(x: 64, y: 48), radius: 8,
                        startAngle: 200, endAngle: 340, clockwise: false)
        smile.lineWidth = 2.6; smile.lineCapStyle = .round; smile.stroke()
    }

    // Chest dial with tick ring; doubles as charge light asleep.
    s.plateTop.setFill()
    NSBezierPath(ovalIn: CGRect(x: 55, y: 25, width: 18, height: 18)).fill()
    s.metal.setStroke()
    let ring = NSBezierPath(ovalIn: CGRect(x: 55, y: 25, width: 18, height: 18))
    ring.lineWidth = 1.4; ring.stroke()
    for i in 0..<8 {
        let a = CGFloat(i) / 8 * 2 * .pi
        let t = NSBezierPath()
        t.move(to: CGPoint(x: 64 + cos(a) * 6.5, y: 34 + sin(a) * 6.5))
        t.line(to: CGPoint(x: 64 + cos(a) * 8.2, y: 34 + sin(a) * 8.2))
        t.lineWidth = 1; s.metal.setStroke(); t.stroke()
    }
    (pose.dialGreen ? s.dialSleep : s.dialDot).setFill()
    NSBezierPath(ovalIn: CGRect(x: 61, y: 31, width: 6, height: 6)).fill()

    // Antenna: coiled stem, set a touch off-center the way a hand-soldered
    // one would be; bends with motion.
    let baseX: CGFloat = 65.5
    let bend = pose.antennaBend * .pi / 180
    let tip = CGPoint(x: baseX + sin(bend) * 16, y: 92 + cos(bend) * 14)
    let ant = NSBezierPath()
    ant.move(to: CGPoint(x: baseX, y: 92))
    ant.curve(to: tip,
              controlPoint1: CGPoint(x: baseX, y: 100),
              controlPoint2: CGPoint(x: baseX + sin(bend) * 6, y: 102))
    s.metal.setStroke(); ant.lineWidth = 3; ant.lineCapStyle = .round; ant.stroke()
    for f in [0.35, 0.6] {
        let cx = baseX + sin(bend) * 16 * f * f
        let cy = 92 + cos(bend) * 14 * f
        let coil = NSBezierPath(ovalIn: CGRect(x: cx - 3, y: cy - 1.5, width: 6, height: 3))
        coil.lineWidth = 1.2; s.metalLight.setStroke(); coil.stroke()
    }
    NSGradient(starting: s.tipTop, ending: s.tipBottom)?
        .draw(in: NSBezierPath(ovalIn: CGRect(x: tip.x - 6, y: tip.y - 2, width: 12, height: 12)), angle: -90)
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(ovalIn: CGRect(x: tip.x - 3.5, y: tip.y + 3.5, width: 4, height: 4)).fill()

    ctx.restoreGState()

    if pose.sleepZs {
        s.zColor.setStroke()
        for (ox, oy, size) in [(96.0, 96.0, 7.0), (106.0, 108.0, 5.0)] {
            let z = NSBezierPath()
            z.move(to: CGPoint(x: ox, y: oy + size))
            z.line(to: CGPoint(x: ox + size, y: oy + size))
            z.line(to: CGPoint(x: ox, y: oy))
            z.line(to: CGPoint(x: ox + size, y: oy))
            z.lineWidth = 2.2; z.lineCapStyle = .round; z.lineJoinStyle = .round; z.stroke()
        }
    }

    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var frames: [(String, Pose)] = [
    ("idle_0", Pose()),
    ("idle_1", Pose(scaleY: 1.02, antennaBend: 3)),
    ("idle_2", Pose(scaleY: 0.988, antennaBend: -3)),
    ("blink_0", Pose(eyes: .off)),
    ("jump_0", Pose(scaleY: 1.09, glintDY: 3, dangleFeet: true, antennaBend: -6, grounded: false)),
    ("fall_0", Pose(scaleY: 1.12, eyes: .alarm, glintDY: -3, mouth: .o, dangleFeet: true,
                    tilt: -5, antennaBend: 14, grounded: false, speedLines: true)),
    ("fall_1", Pose(scaleY: 1.10, eyes: .alarm, glintDY: -3, mouth: .o, dangleFeet: true,
                    tilt: 5, antennaBend: -14, grounded: false, speedLines: true)),
    ("land_0", Pose(scaleY: 0.76, eyes: .off, mouth: .smile, dust: 1)),
    ("land_1", Pose(scaleY: 1.05, mouth: .smile, antennaBend: 4, dust: 2)),
    ("sleep_0", Pose(scaleY: 0.965, eyes: .off, tilt: 2, antennaBend: 14)),
    ("sleep_1", Pose(scaleY: 0.952, eyes: .off, tilt: 2, antennaBend: 17,
                     dialGreen: true, sleepZs: true)),
    ("look_0", Pose(glintDX: -3.5, antennaBend: -2)),
    ("look_1", Pose(glintDX: 3.5, antennaBend: 2)),
    ("look_2", Pose()),
    ("fidget_0", Pose(scaleY: 1.005, footLiftL: 5, antennaBend: 8)),
    ("fidget_1", Pose(scaleY: 0.995, antennaBend: -6)),
    ("fidget_2", Pose(scaleY: 1.005, footLiftR: 5, antennaBend: 6)),
    ("fidget_3", Pose(antennaBend: -2)),
]
// 10-frame walk with antenna spring (phase-lagged bend reads as inertia).
for i in 0..<10 {
    let phi = CGFloat(i) / 10 * 2 * .pi
    frames.append(("walk_\(i)", Pose(
        scaleY: 1 + 0.03 * abs(sin(phi)),
        footLiftL: max(0, sin(phi)) * 7,
        footLiftR: max(0, sin(phi + .pi)) * 7,
        tilt: -2,
        antennaBend: sin(phi + 0.7) * 11
    )))
}

for skin in skins {
    for (name, pose) in frames {
        try! render(pose, skin).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "\(outDir)/pet_\(skin.id)_\(name).png"))
    }
}
try! render(frames.first { $0.0 == "idle_0" }!.1, skins[0])
    .representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "\(outDir)/pet.png"))
print("wrote \(frames.count) frames x \(skins.count) skins + pet.png")
