import AppKit
import ImageIO
import UniformTypeIdentifiers

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { fatalError("Cannot read artwork") }
// Tahoe adds a gray surround when these PNG representations use grayscale.
// Preserve RGB + alpha even though the artwork itself is monochrome.
let rgb = CGColorSpaceCreateDeviceRGB()
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        // 512 px covers a 256 pt Retina icon while keeping the whole app < 3 MB.
        guard pixels <= 512 else { continue }
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels * 4, space: rgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("No RGB context") }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = context.makeImage() else { fatalError("No encoded image") }
        let suffix = scale == 2 ? "@2x" : ""
        let target = output.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
        guard let writer = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("No PNG writer") }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { fatalError("PNG encode failed") }
    }
}
