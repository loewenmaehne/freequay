// The icon of Freequay.app: the landing sign of its window, an arrow coming down onto the blue quay
// edge, on a light tile. The arrow is drawn here, as Apple's license keeps SF Symbols out of app
// icons. scripts/build-app.sh runs this and packs the images with iconutil.
// Usage: Icon <folder>.iconset
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
private let accent = CGColor(srgbRed: 0.13, green: 0.32, blue: 0.93, alpha: 1)  // as in the window
private let accentLight = CGColor(srgbRed: 0.22, green: 0.42, blue: 1.0, alpha: 1)
private let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
private let shade = CGColor(srgbRed: 0.925, green: 0.94, blue: 0.965, alpha: 1)

// Apple's grid for Mac app icons, on a canvas of 1024 with y downwards: a tile of 824 with
// continuous corners and a soft shadow. macOS 26 and later show an icon on this grid as it is and
// put any other on a grey tile.
private let tile = RoundedRectangle(cornerRadius: 185.4, style: .continuous)
    .path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath
private let edge = CGPath(rect: CGRect(x: 0, y: 800, width: 1024, height: 224), transform: nil)  // clipped by the tile

// a stem and a head of round strokes, with its ink from 262 down to 724, above the edge
private let arrow: CGPath = {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 512, y: 304))
    path.addLine(to: CGPoint(x: 512, y: 682))
    path.move(to: CGPoint(x: 332, y: 502))
    path.addLine(to: CGPoint(x: 512, y: 682))
    path.addLine(to: CGPoint(x: 692, y: 502))
    return path.copy(strokingWithWidth: 84, lineCap: .round, lineJoin: .round, miterLimit: 10)
}()

// fills a path with a gradient from top to bottom
private func fill(_ context: CGContext, _ path: CGPath, _ colors: [CGColor], from top: CGFloat, to bottom: CGFloat) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

private func icon(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,  // shadows ignore the scale
                      color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(tile)
    context.setFillColor(white)
    context.fillPath()
    context.restoreGState()
    fill(context, tile, [white, shade], from: 100, to: 924)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    fill(context, edge, [accentLight, accent], from: 800, to: 924)
    context.restoreGState()
    fill(context, arrow, [accentLight, accent], from: 262, to: 724)
    return context.makeImage()!
}

guard CommandLine.arguments.count == 2 else {
    print("usage: Icon <folder>.iconset")
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let url = folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(file, icon(size: points * scale), nil)
        guard CGImageDestinationFinalize(file) else { fatalError("could not write \(url.path)") }
    }
}
