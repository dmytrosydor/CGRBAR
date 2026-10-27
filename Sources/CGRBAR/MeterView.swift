import AppKit

struct MeterSegment: Equatable {
    var label: String?
    var value: String
    var load: Load
}

/// Draws the menu bar readout without text layout on every update.
///
/// Labels and single value characters are rendered once into cached images.
/// An update only swaps the contents of the layers whose character changed,
/// which avoids the button cell, CoreText and Auto Layout passes that a
/// title change would trigger.
@MainActor
final class MeterView: NSView {
    /// Called when the content width changes, so the status item can resize.
    var onWidthChange: ((CGFloat) -> Void)?

    private(set) var contentWidth: CGFloat = 0
    private var segments: [MeterSegment] = []
    private var cache: [String: Glyph] = [:]
    private var slotWidth: CGFloat = 0
    private var gap: CGFloat = 0
    private var labelSpace: CGFloat = 0

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let lineHeight = ceil(font.ascender - font.descender)

    private struct Glyph {
        var image: CGImage
        var width: CGFloat
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Clicks belong to the status bar button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ segments: [MeterSegment]) {
        guard segments != self.segments else { return }
        self.segments = segments
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidate()
    }

    override func layout() {
        super.layout()
        render()
    }

    private func invalidate() {
        cache.removeAll()
        slotWidth = 0
        render()
    }

    // MARK: - Layout

    private func render() {
        guard let root = layer else { return }
        if slotWidth == 0 {
            slotWidth = width(of: "100%")
            gap = width(of: "  ")
            labelSpace = width(of: " ")
        }

        var placements: [(Glyph, CGFloat)] = []
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if index > 0 { x += gap }
            if let label = segment.label, let glyph = glyph(label, .normal) {
                placements.append((glyph, x))
                x += glyph.width + labelSpace
            }
            // The value gets a fixed slot as wide as "100%", so the width never jumps.
            var valueX = x
            for glyph in segment.value.compactMap({ glyph(String($0), segment.load) }) {
                placements.append((glyph, valueX))
                valueX += glyph.width
            }
            x += slotWidth
        }

        if x != contentWidth {
            contentWidth = x
            onWidthChange?(x)
        }

        let scale = window?.backingScaleFactor ?? 2
        let originX = ((bounds.width - x) / 2 * scale).rounded() / scale
        let originY = ((bounds.height - Self.lineHeight) / 2 * scale).rounded() / scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var sublayers = root.sublayers ?? []
        while sublayers.count < placements.count {
            let sublayer = CALayer()
            root.addSublayer(sublayer)
            sublayers.append(sublayer)
        }
        for (index, sublayer) in sublayers.enumerated() {
            guard index < placements.count else {
                sublayer.isHidden = true
                continue
            }
            let (glyph, glyphX) = placements[index]
            // Snap to device pixels and keep the bitmap's own size, so glyphs stay sharp.
            let frame = CGRect(
                x: ((originX + glyphX) * scale).rounded() / scale,
                y: originY,
                width: CGFloat(glyph.image.width) / scale,
                height: CGFloat(glyph.image.height) / scale
            )
            // Touch only what changed, so Core Animation commits as little as possible.
            if (sublayer.contents as AnyObject?) !== glyph.image { sublayer.contents = glyph.image }
            if sublayer.frame != frame { sublayer.frame = frame }
            if sublayer.contentsScale != scale { sublayer.contentsScale = scale }
            if sublayer.isHidden { sublayer.isHidden = false }
        }
        CATransaction.commit()
    }

    // MARK: - Glyph cache

    private func width(of string: String) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: Self.font]).size().width
    }

    private func glyph(_ text: String, _ load: Load) -> Glyph? {
        let key = "\(load)|\(text)"
        if let glyph = cache[key] { return glyph }
        guard let glyph = makeGlyph(text, color: color(for: load)) else { return nil }
        cache[key] = glyph
        return glyph
    }

    private func color(for load: Load) -> NSColor {
        switch load {
        case .normal: .labelColor
        case .high: .systemOrange
        case .critical: .systemRed
        }
    }

    private func makeGlyph(_ text: String, color: NSColor) -> Glyph? {
        let string = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: color])
        let width = string.size().width
        let scale = window?.backingScaleFactor ?? 2
        guard
            width > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: Int(ceil(width * scale)),
                height: Int(ceil(Self.lineHeight * scale)),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // Resolve dynamic colors like labelColor against the menu bar's appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            string.draw(at: NSPoint(x: 0, y: -Self.font.descender))
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return Glyph(image: image, width: width)
    }
}
