import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

let ink = color(0x354A43)
let mint = color(0xB6DEC7)
let paper = color(0xFFF6E5)

func stroke(_ path: NSBezierPath, color: NSColor = ink, width: CGFloat = 24) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

func fill(_ path: NSBezierPath, color: NSColor, outlined: Bool = true) {
    color.setFill()
    path.fill()
    if outlined { stroke(path) }
}

func drawGuardian(detailed: Bool) {
    fill(NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936),
                      xRadius: 216, yRadius: 216), color: paper, outlined: false)

    let shackle = NSBezierPath()
    shackle.move(to: NSPoint(x: 354, y: 594))
    shackle.line(to: NSPoint(x: 354, y: 714))
    shackle.curve(to: NSPoint(x: 670, y: 714), controlPoint1: NSPoint(x: 354, y: 924),
                 controlPoint2: NSPoint(x: 670, y: 924))
    shackle.line(to: NSPoint(x: 670, y: 594))
    stroke(shackle, width: 94)
    stroke(shackle, color: mint, width: 47)

    for footCenter in [CGFloat(401), CGFloat(623)] {
        let foot = NSBezierPath()
        foot.move(to: NSPoint(x: footCenter, y: 252))
        foot.line(to: NSPoint(x: footCenter, y: 173))
        foot.line(to: NSPoint(x: footCenter + (footCenter < 512 ? -42 : 42), y: 173))
        stroke(foot, width: 31)
    }

    let leftArm = NSBezierPath()
    leftArm.move(to: NSPoint(x: 281, y: 467))
    leftArm.curve(to: NSPoint(x: 189, y: 509), controlPoint1: NSPoint(x: 218, y: 457),
                 controlPoint2: NSPoint(x: 186, y: 471))
    stroke(leftArm, width: 26)
    let rightArm = NSBezierPath()
    rightArm.move(to: NSPoint(x: 743, y: 467))
    rightArm.curve(to: NSPoint(x: 831, y: 549), controlPoint1: NSPoint(x: 807, y: 458),
                  controlPoint2: NSPoint(x: 843, y: 502))
    stroke(rightArm, width: 26)

    let body = NSBezierPath(roundedRect: NSRect(x: 263, y: 250, width: 498, height: 398),
                            xRadius: 104, yRadius: 104)
    fill(body, color: mint)

    if detailed {
        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: 309, y: 543))
        highlight.curve(to: NSPoint(x: 365, y: 601), controlPoint1: NSPoint(x: 308, y: 586),
                        controlPoint2: NSPoint(x: 329, y: 600))
        stroke(highlight, color: color(0xE6F5E9), width: 16)
    }

    for eyeCenter in [CGFloat(414), CGFloat(610)] {
        fill(NSBezierPath(ovalIn: NSRect(x: eyeCenter - 18, y: 455, width: 36, height: 53)),
             color: ink, outlined: false)
    }
    for cheekCenter in [CGFloat(359), CGFloat(665)] {
        fill(NSBezierPath(ovalIn: NSRect(x: cheekCenter - 29, y: 405, width: 58, height: 27)),
             color: color(0xE8A18F), outlined: false)
    }
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: 461, y: 422))
    smile.curve(to: NSPoint(x: 563, y: 422), controlPoint1: NSPoint(x: 480, y: 378),
                controlPoint2: NSPoint(x: 544, y: 378))
    stroke(smile, width: 19)

    fill(NSBezierPath(ovalIn: NSRect(x: 480, y: 299, width: 64, height: 64)),
         color: paper, outlined: false)
    let check = NSBezierPath()
    check.move(to: NSPoint(x: 496, y: 332))
    check.line(to: NSPoint(x: 508, y: 320))
    check.line(to: NSPoint(x: 529, y: 342))
    stroke(check, width: 9)

    if detailed {
        let sparkle = NSBezierPath()
        sparkle.move(to: NSPoint(x: 809, y: 683))
        sparkle.line(to: NSPoint(x: 809, y: 741))
        sparkle.move(to: NSPoint(x: 780, y: 712))
        sparkle.line(to: NSPoint(x: 838, y: 712))
        stroke(sparkle, color: color(0xDBB46D), width: 16)
    }
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        drawGuardian(detailed: pixels >= 64)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
