import AppKit

// Menu-bar status icon: Rusty as a monochrome template glyph, 18pt (36px @2x),
// matching system menu-bar icon weight. Usage:
//   swift Tools/icongen.swift mockup <out.png>   — approval sheet
//   swift Tools/icongen.swift template <out.png> — black template asset

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mockup"
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "icon.png"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Draw the robot glyph into a 36×36 space (18pt @2x), monochrome.
/// Detail budget for menu-bar scale: antenna + bobble, visor with two eyes,
/// three-slit grille, feet pads. Knockouts carry the detail, like the
/// battery's numerals.
func drawGlyph(_ color: NSColor) {
    let ctx = NSGraphicsContext.current!.cgContext
    color.setFill()
    // Antenna.
    NSBezierPath(roundedRect: CGRect(x: 17.1, y: 26.5, width: 1.8, height: 5),
                 xRadius: 0.9, yRadius: 0.9).fill()
    NSBezierPath(ovalIn: CGRect(x: 15.4, y: 30.6, width: 5.2, height: 5.2)).fill()
    // Feet.
    NSBezierPath(roundedRect: CGRect(x: 9.6, y: 1.2, width: 6.6, height: 4.6),
                 xRadius: 2, yRadius: 2).fill()
    NSBezierPath(roundedRect: CGRect(x: 19.8, y: 1.2, width: 6.6, height: 4.6),
                 xRadius: 2, yRadius: 2).fill()
    // Body.
    NSBezierPath(roundedRect: CGRect(x: 7, y: 5.2, width: 22, height: 21.8),
                 xRadius: 5.5, yRadius: 5.5).fill()
    // Knockouts: visor + grille.
    ctx.setBlendMode(.clear)
    NSBezierPath(roundedRect: CGRect(x: 10.4, y: 16.6, width: 15.2, height: 8),
                 xRadius: 4, yRadius: 4).fill()
    for x in [11.9, 16.3, 20.7] {
        NSBezierPath(roundedRect: CGRect(x: x, y: 11.4, width: 3.4, height: 1.9),
                     xRadius: 0.95, yRadius: 0.95).fill()
    }
    ctx.setBlendMode(.normal)
    // Eyes inside the visor.
    color.setFill()
    NSBezierPath(ovalIn: CGRect(x: 12.8, y: 18.7, width: 3.9, height: 3.9)).fill()
    NSBezierPath(ovalIn: CGRect(x: 19.3, y: 18.7, width: 3.9, height: 3.9)).fill()
}

func render(size: Int, scale: CGFloat, color: NSColor) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    g.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    g.cgContext.scaleBy(x: scale, y: scale)
    drawGlyph(color)
    g.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if mode == "appicon" {
    // 1024px macOS app icon: teal squircle tile + the white robot glyph.
    let size = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    g.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let tile = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 185, yRadius: 185)
    NSGradient(starting: rgb(96, 158, 152), ending: rgb(44, 92, 88))?.draw(in: tile, angle: -90)
    rgb(30, 60, 57, 0.6).setStroke(); tile.lineWidth = 6; tile.stroke()
    // Glyph rendered as its own layer, then composited — so its knockouts
    // (visor, grille) reveal the dark tile, not transparency.
    let glyphSize = 612
    let glyphRep = render(size: glyphSize, scale: CGFloat(glyphSize) / 36, color: rgb(250, 252, 252))
    let glyphImg = NSImage(size: NSSize(width: glyphSize, height: glyphSize))
    glyphImg.addRepresentation(glyphRep)
    glyphImg.draw(in: CGRect(x: (size - glyphSize) / 2, y: (size - glyphSize) / 2 - 10,
                             width: glyphSize, height: glyphSize),
                  from: .zero, operation: .sourceOver, fraction: 1)
    g.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath)")
    exit(0)
}

if mode == "template" {
    // Black glyph, alpha carries shape — NSImage.isTemplate does the rest.
    try! render(size: 36, scale: 1, color: rgb(0, 0, 0))
        .representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath)")
    exit(0)
}

// ---- Mockup sheet: menu-bar strip at real scale + enlargements ----
let W = 840, H = 330
let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let g = NSGraphicsContext(bitmapImageRep: sheet)!
NSGraphicsContext.current = g

rgb(232, 228, 218).setFill()
CGRect(x: 0, y: 0, width: W, height: H).fill()

// Simulated menu-bar strip (dark, wallpaper-blue like the screenshot).
let strip = NSBezierPath(roundedRect: CGRect(x: 20, y: 240, width: 800, height: 66),
                         xRadius: 12, yRadius: 12)
NSGradient(starting: rgb(64, 96, 132), ending: rgb(46, 74, 106))?.draw(in: strip, angle: -90)

// Neighbor glyphs for weight comparison: generic battery pill + toggle.
let white = rgb(255, 255, 255, 0.95)
white.setStroke()
let batt = NSBezierPath(roundedRect: CGRect(x: 340, y: 259, width: 46, height: 26), xRadius: 8, yRadius: 8)
batt.lineWidth = 2.4; batt.stroke()
white.setFill()
NSBezierPath(roundedRect: CGRect(x: 343, y: 262, width: 26, height: 20), xRadius: 5, yRadius: 5).fill()
NSBezierPath(roundedRect: CGRect(x: 388, y: 266, width: 4, height: 12), xRadius: 2, yRadius: 2).fill()
let togglePlate = NSBezierPath(roundedRect: CGRect(x: 660, y: 258, width: 44, height: 30), xRadius: 9, yRadius: 9)
togglePlate.lineWidth = 2.4; togglePlate.stroke()
white.setFill()
NSBezierPath(ovalIn: CGRect(x: 666, y: 272, width: 11, height: 11)).fill()
NSBezierPath(ovalIn: CGRect(x: 687, y: 262, width: 11, height: 11)).fill()

func composite(_ rep: NSBitmapImageRep, in rect: CGRect) {
    let img = NSImage(size: rect.size)
    img.addRepresentation(rep)
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

// The robot at true menu-bar size (36px in the strip), between them.
composite(render(size: 36, scale: 1, color: white),
          in: CGRect(x: 508, y: 254, width: 36, height: 36))

// Enlarged: white-on-dark and black-on-light (template renders both).
let darkCard = NSBezierPath(roundedRect: CGRect(x: 60, y: 30, width: 320, height: 180),
                            xRadius: 16, yRadius: 16)
rgb(38, 52, 68).setFill(); darkCard.fill()
composite(render(size: 144, scale: 4, color: rgb(255, 255, 255)),
          in: CGRect(x: 148, y: 48, width: 144, height: 144))

let lightCard = NSBezierPath(roundedRect: CGRect(x: 460, y: 30, width: 320, height: 180),
                             xRadius: 16, yRadius: 16)
rgb(250, 250, 252).setFill(); lightCard.fill()
rgb(205, 200, 188).setStroke(); lightCard.lineWidth = 1.5; lightCard.stroke()
composite(render(size: 144, scale: 4, color: rgb(40, 40, 44)),
          in: CGRect(x: 548, y: 48, width: 144, height: 144))

("menu bar · actual 18pt" as NSString).draw(at: CGPoint(x: 32, y: 214),
    withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                     .foregroundColor: rgb(96, 90, 80)])
("dark menu bar" as NSString).draw(at: CGPoint(x: 72, y: 40),
    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: rgb(180, 190, 200)])
("light menu bar" as NSString).draw(at: CGPoint(x: 472, y: 40),
    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: rgb(120, 114, 104)])

g.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! sheet.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
