import AppKit

// Generates Rusty's animation frames (128×128 px, displayed at 64 pt) into
// the directory given as argv[1]. Rusty is a mid-century tin toy robot:
// teal tin body, silver faceplate, cyan LED eyes, chest dial, rivets, and an
// antenna with a red bobble. Robot-specific animation flavor:
//   - blink  = LEDs power off (dim slits)
//   - alarm  = falling: LEDs go orange and widen, speaker mouth goes "o"
//   - antenna sways with the walk gait and flails during falls

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

struct Pose {
    enum Eyes { case open, alarm, off }
    enum Mouth { case grille, o, smile }
    var scaleY: CGFloat = 1.0        // squash/stretch about the ground line
    var eyes: Eyes = .open
    var glintDY: CGFloat = 0         // LED glint looks up (+) / down (−)
    var mouth: Mouth = .grille
    var footLiftL: CGFloat = 0
    var footLiftR: CGFloat = 0
    var dangleFeet = false           // airborne
    var tilt: CGFloat = 0            // degrees, flail
    var antennaBend: CGFloat = 0     // degrees, + bends the tip right
    var grounded = true              // shadow on/off
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func render(_ pose: Pose) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext

    if pose.grounded {
        rgb(30, 24, 18, 0.20).setFill()
        NSBezierPath(ovalIn: CGRect(x: 26, y: 5, width: 76, height: 14)).fill()
    }

    // Flail tilt about the body center, then squash/stretch about the ground
    // line (volume-preserving-ish).
    ctx.saveGState()
    let sy = pose.scaleY
    let sx = 1 + (1 - sy) * 0.7
    ctx.translateBy(x: 64, y: 55)
    ctx.rotate(by: pose.tilt * .pi / 180)
    ctx.translateBy(x: -64, y: -55)
    ctx.translateBy(x: 64, y: 10)
    ctx.scaleBy(x: sx, y: sy)
    ctx.translateBy(x: -64, y: -10)

    let darkTeal = rgb(38, 74, 70)
    let steel = rgb(120, 124, 130)
    let silver = rgb(210, 214, 218)
    let alarmRed = rgb(233, 90, 70)

    // Feet pads.
    if pose.dangleFeet {
        for x in [40.0, 72.0] {
            steel.setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: 3, width: 16, height: 11),
                         xRadius: 4, yRadius: 4).fill()
        }
    } else {
        for (x, lift) in [(36.0, pose.footLiftL), (72.0, pose.footLiftR)] {
            steel.setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: 8 + lift, width: 20, height: 12),
                         xRadius: 4, yRadius: 4).fill()
        }
    }

    // Body.
    let body = NSBezierPath(roundedRect: CGRect(x: 26, y: 18, width: 76, height: 74),
                            xRadius: 12, yRadius: 12)
    NSGradient(starting: rgb(105, 168, 162), ending: rgb(62, 118, 113))?.draw(in: body, angle: -90)
    darkTeal.setStroke(); body.lineWidth = 2.4; body.stroke()

    // Faceplate + visor.
    let plate = NSBezierPath(roundedRect: CGRect(x: 36, y: 52, width: 56, height: 30),
                             xRadius: 8, yRadius: 8)
    silver.setFill(); plate.fill()
    steel.setStroke(); plate.lineWidth = 1.8; plate.stroke()
    rgb(30, 34, 44).setFill()
    NSBezierPath(roundedRect: CGRect(x: 42, y: 58, width: 44, height: 18),
                 xRadius: 9, yRadius: 9).fill()

    // LED eyes.
    switch pose.eyes {
    case .open:
        rgb(120, 235, 255).setFill()
        NSBezierPath(ovalIn: CGRect(x: 50, y: 62, width: 10, height: 10)).fill()
        NSBezierPath(ovalIn: CGRect(x: 68, y: 62, width: 10, height: 10)).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: CGRect(x: 53, y: 67 + pose.glintDY, width: 3.5, height: 3.5)).fill()
        NSBezierPath(ovalIn: CGRect(x: 71, y: 67 + pose.glintDY, width: 3.5, height: 3.5)).fill()
    case .alarm:
        // Wide orange alert LEDs with a warning ring.
        rgb(255, 180, 74).setFill()
        NSBezierPath(ovalIn: CGRect(x: 48, y: 60.5, width: 13, height: 13)).fill()
        NSBezierPath(ovalIn: CGRect(x: 67, y: 60.5, width: 13, height: 13)).fill()
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: CGRect(x: 52, y: 64 + pose.glintDY, width: 4.5, height: 4.5)).fill()
        NSBezierPath(ovalIn: CGRect(x: 71, y: 64 + pose.glintDY, width: 4.5, height: 4.5)).fill()
    case .off:
        // Powered-down slits.
        rgb(96, 150, 160, 0.8).setStroke()
        for x in [50.0, 68.0] {
            let slit = NSBezierPath()
            slit.move(to: CGPoint(x: x, y: 67))
            slit.line(to: CGPoint(x: x + 10, y: 67))
            slit.lineWidth = 2.5
            slit.lineCapStyle = .round
            slit.stroke()
        }
    }

    // Mouth on the body below the faceplate.
    switch pose.mouth {
    case .grille:
        darkTeal.setStroke()
        for i in 0..<3 {
            let m = NSBezierPath()
            m.move(to: CGPoint(x: 52 + CGFloat(i) * 9, y: 46))
            m.line(to: CGPoint(x: 58 + CGFloat(i) * 9, y: 46))
            m.lineWidth = 2; m.lineCapStyle = .round; m.stroke()
        }
    case .o:
        // Speaker alarm.
        darkTeal.setStroke()
        let o = NSBezierPath(ovalIn: CGRect(x: 59.5, y: 41, width: 9, height: 10))
        o.lineWidth = 2.5; o.stroke()
    case .smile:
        darkTeal.setStroke()
        let smile = NSBezierPath()
        smile.appendArc(withCenter: CGPoint(x: 64, y: 48), radius: 8,
                        startAngle: 200, endAngle: 340, clockwise: false)
        smile.lineWidth = 2.6; smile.lineCapStyle = .round; smile.stroke()
    }

    // Chest dial + rivets.
    silver.setFill()
    NSBezierPath(ovalIn: CGRect(x: 56, y: 26, width: 16, height: 16)).fill()
    alarmRed.setFill()
    NSBezierPath(ovalIn: CGRect(x: 61, y: 31, width: 6, height: 6)).fill()
    darkTeal.setFill()
    for x in [32.0, 92.0] {
        for y in [26.0, 84.0] {
            NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 4, height: 4)).fill()
        }
    }

    // Antenna: bends with motion; red bobble at the tip.
    let bend = pose.antennaBend * .pi / 180
    let tip = CGPoint(x: 64 + sin(bend) * 16, y: 92 + cos(bend) * 14)
    let ant = NSBezierPath()
    ant.move(to: CGPoint(x: 64, y: 92))
    ant.curve(to: tip,
              controlPoint1: CGPoint(x: 64, y: 100),
              controlPoint2: CGPoint(x: 64 + sin(bend) * 6, y: 102))
    steel.setStroke(); ant.lineWidth = 3; ant.lineCapStyle = .round; ant.stroke()
    alarmRed.setFill()
    NSBezierPath(ovalIn: CGRect(x: tip.x - 6, y: tip.y - 2, width: 12, height: 12)).fill()
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(ovalIn: CGRect(x: tip.x - 3.5, y: tip.y + 3, width: 4, height: 4)).fill()

    ctx.restoreGState()
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// The frame manifest — names and counts must match SpriteSet.swift.
var frames: [(String, Pose)] = [
    ("idle_0", Pose()),
    ("idle_1", Pose(scaleY: 1.02, antennaBend: 3)),
    ("idle_2", Pose(scaleY: 0.988, antennaBend: -3)),
    ("blink_0", Pose(eyes: .off)),
    ("jump_0", Pose(scaleY: 1.09, glintDY: 3, dangleFeet: true, antennaBend: -6, grounded: false)),
    ("fall_0", Pose(scaleY: 1.12, eyes: .alarm, glintDY: -3, mouth: .o,
                    dangleFeet: true, tilt: -5, antennaBend: 12, grounded: false)),
    ("fall_1", Pose(scaleY: 1.10, eyes: .alarm, glintDY: -3, mouth: .o,
                    dangleFeet: true, tilt: 5, antennaBend: -12, grounded: false)),
    ("land_0", Pose(scaleY: 0.76, eyes: .off, mouth: .smile)),
    ("land_1", Pose(scaleY: 1.05, mouth: .smile, antennaBend: 4)),
]
for i in 0..<6 {
    let phi = CGFloat(i) / 6 * 2 * .pi
    frames.append(("walk_\(i)", Pose(
        scaleY: 1 + 0.03 * abs(sin(phi)),
        footLiftL: max(0, sin(phi)) * 7,
        footLiftR: max(0, sin(phi + .pi)) * 7,
        tilt: -2,
        antennaBend: sin(phi) * 9
    )))
}

for (name, pose) in frames {
    let rep = render(pose)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/pet_\(name).png"))
    print("wrote \(outDir)/pet_\(name).png")
}
try! render(frames.first { $0.0 == "idle_0" }!.1)
    .representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "\(outDir)/pet.png"))
print("wrote \(outDir)/pet.png")
