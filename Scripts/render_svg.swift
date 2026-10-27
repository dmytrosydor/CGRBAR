// Renders an SVG to a square PNG using the system SVG support in NSImage.
// Usage: swift Scripts/render_svg.swift <in.svg> <out.png> <pixels>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 4, let size = Int(arguments[3]) else {
    FileHandle.standardError.write("usage: render_svg.swift <in.svg> <out.png> <pixels>\n".data(using: .utf8)!)
    exit(1)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) else {
    FileHandle.standardError.write("cannot load \(arguments[1])\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
