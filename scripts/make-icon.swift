// Renders Tween's app icon into an AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift Tween/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let center = CGPoint(x: canvas / 2, y: canvas / 2)
let ringRadius: CGFloat = 228
let ringWidth: CGFloat = 96
let gapHalfAngle: CGFloat = 38          // the opening, centred on the right
let resolvedFrom: CGFloat = 164         // the smooth arc runs from the gap over the top to here
let dissolve: CGFloat = 16              // ...and fades in over this many degrees, over the finest blocks

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat, alpha: CGFloat = 1) -> CGColor {
    func channel(_ shift: UInt32) -> CGFloat {
        let x = CGFloat((a >> shift) & 0xFF), y = CGFloat((b >> shift) & 0xFF)
        return (x + (y - x) * t) / 255
    }
    return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: alpha)
}

let cyan: UInt32 = 0x2FB8FF
let ice: UInt32 = 0xE9FBFF

/// Colour along the ring: deep cyan where it's quantized, near-white where it's most resolved.
func ringColor(atDegrees angle: CGFloat, alpha: CGFloat = 1) -> CGColor {
    // 38° (sharpest, at the gap) → 1.0 ; 322° (coarsest) → 0.0
    let span = 360 - 2 * gapHalfAngle
    let t = 1 - min(max((angle - gapHalfAngle) / span, 0), 1)
    return mix(cyan, ice, pow(t, 1.4), alpha: alpha)
}

func point(_ degrees: CGFloat, _ radius: CGFloat) -> CGPoint {
    let r = degrees * .pi / 180
    return CGPoint(x: center.x + cos(r) * radius, y: center.y + sin(r) * radius)
}

func render() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // Squircle tile on Apple's 824 pt grid, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x0A0F1C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                colors: [rgb(0x182238), rgb(0x0B1020), rgb(0x070A14)] as CFArray,
                                locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A faint cool bloom behind the resolved arc.
    let bloom = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [rgb(cyan, 0.16), rgb(cyan, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bloom, startCenter: point(95, 150), startRadius: 0,
                           endCenter: point(95, 150), endRadius: 430, options: [])
    ctx.restoreGState()

    // Hairline highlight on the tile's top edge.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184.5, cornerHeight: 184.5, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.07))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    let inner = ringRadius - ringWidth / 2, outer = ringRadius + ringWidth / 2

    // Quantized half: square samples on grids that shrink step by step toward the resolved arc.
    // Nested grids, like mipmap levels: every cell size divides the next and all share one lattice
    // through the centre, so a coarse block covers exactly four finer ones. Finest first; a coarser
    // block that would touch an already placed one is left out, so levels never overlap.
    let bands: [(from: CGFloat, to: CGFloat, cell: CGFloat)] = [
        (resolvedFrom - dissolve, 186, 6), (186, 218, 12), (218, 262, 24), (262, 360 - gapHalfAngle, 48),
    ]
    var placed: [CGRect] = []
    for band in bands {
        let gap = max(2, band.cell * 0.12)
        let start = center.x - ceil((outer + band.cell) / band.cell) * band.cell
        var y = start
        while y < center.y + outer {
            var x = start
            while x < center.x + outer {
                let mid = CGPoint(x: x + band.cell / 2, y: y + band.cell / 2)
                let dx = mid.x - center.x, dy = mid.y - center.y
                let distance = hypot(dx, dy)
                var angle = atan2(dy, dx) * 180 / .pi
                if angle < 0 { angle += 360 }
                let block = CGRect(x: x + gap / 2, y: y + gap / 2, width: band.cell - gap, height: band.cell - gap)
                // Tolerance grows with block size so coarse samples still hold the ring's silhouette.
                let slack = min(band.cell * 0.3, 7)
                if distance >= inner - slack, distance <= outer + slack, angle >= band.from, angle < band.to,
                   !placed.contains(where: { $0.insetBy(dx: -gap / 2, dy: -gap / 2).intersects(block) }) {
                    placed.append(block)
                    // Coarser blocks carry less energy: same hue, earlier moment.
                    let energy = 0.55 + 0.45 * (1 - (band.cell - 6) / 42)
                    ctx.setFillColor(ringColor(atDegrees: angle, alpha: energy))
                    ctx.addPath(CGPath(roundedRect: block, cornerWidth: band.cell * 0.08, cornerHeight: band.cell * 0.08, transform: nil))
                    ctx.fillPath()
                }
                x += band.cell
            }
            y += band.cell
        }
    }

    // Resolved half: one continuous stroke, brightening toward the opening, with a soft glow.
    let steps = 240
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 34, color: rgb(cyan, 0.55))
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.butt)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for i in 0..<steps {
        let a0 = resolvedFrom - (resolvedFrom - gapHalfAngle) * CGFloat(i) / CGFloat(steps)
        let a1 = resolvedFrom - (resolvedFrom - gapHalfAngle) * CGFloat(i + 1) / CGFloat(steps)
        // The first few degrees fade in over the finest blocks, so samples dissolve into the line.
        let fade = min(max((resolvedFrom - (a0 + a1) / 2) / dissolve, 0), 1)
        ctx.setStrokeColor(ringColor(atDegrees: (a0 + a1) / 2, alpha: fade * fade * (3 - 2 * fade)))
        ctx.addArc(center: center, radius: ringRadius, startAngle: a0 * .pi / 180, endAngle: (a1 - 0.35) * .pi / 180, clockwise: true)
        ctx.strokePath()
    }
    // Round cap at the opening.
    ctx.setFillColor(ringColor(atDegrees: gapHalfAngle))
    let capCenter = point(gapHalfAngle, ringRadius)
    ctx.fillEllipse(in: CGRect(x: capCenter.x - ringWidth / 2, y: capCenter.y - ringWidth / 2, width: ringWidth, height: ringWidth))
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // The point of arrival: a four-pointed spark in the opening.
    let spark = point(0, ringRadius + 6)
    let long: CGFloat = 74, short: CGFloat = 13
    let sparkPath = CGMutablePath()
    sparkPath.move(to: CGPoint(x: spark.x, y: spark.y + long))
    sparkPath.addQuadCurve(to: CGPoint(x: spark.x + long, y: spark.y), control: CGPoint(x: spark.x + short, y: spark.y + short))
    sparkPath.addQuadCurve(to: CGPoint(x: spark.x, y: spark.y - long), control: CGPoint(x: spark.x + short, y: spark.y - short))
    sparkPath.addQuadCurve(to: CGPoint(x: spark.x - long, y: spark.y), control: CGPoint(x: spark.x - short, y: spark.y - short))
    sparkPath.addQuadCurve(to: CGPoint(x: spark.x, y: spark.y + long), control: CGPoint(x: spark.x - short, y: spark.y + short))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: rgb(ice, 0.9))
    ctx.addPath(sparkPath)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let master = render()
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(master, size: points * scale, to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(outDir.path)")
