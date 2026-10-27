import AppKit

struct MeterSegment: Equatable {
    var label: String?
    var value: String
    var load: Load
}

/// Draws the menu bar readout without text layout on every update.
///
/// Each metric is a narrow column: an optional tiny label stacked above the
/// value. Labels and single value characters are rendered once into cached
/// images. An update only swaps the contents of the layers whose character
/// changed, which avoids the button cell, CoreText and Auto Layout passes that
/// a title change would trigger.
@MainActor
final class MeterView: NSView {
    /// Called when the content width changes, so the status item can resize.
    var onWidthChange: ((CGFloat) -> Void)?

    private(set) var contentWidth: CGFloat = 0
    private var segments: [MeterSegment] = []
    private var cache: [String: Glyph] = [:]
    private var slotWidths: [CGFloat: CGFloat] = [:]

    private static let gap: CGFloat = 6
    private static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    private static let stackedValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let inlineValueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    private struct Glyph {
        var image: CGImage
        var width: CGFloat
    }

    private struct Placement {
        var glyph: Glyph
        var x: CGFloat
        var y: CGFloat
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
        slotWidths.removeAll()
        render()
    }

    // MARK: - Layout

    private func render() {
        guard let root = layer else { return }
        let stacked = segments.contains { $0.label != nil }
        let valueFont = stacked ? Self.stackedValueFont : Self.inlineValueFont
        // Every value column is as wide as "100", so the width never jumps.
        let slotWidth = slotWidth(valueFont)
        let valueHeight = lineHeight(valueFont)
        let labelHeight = stacked ? lineHeight(Self.labelFont) - 1 : 0
        let blockHeight = labelHeight + valueHeight

        var placements: [Placement] = []
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if index > 0 { x += Self.gap }
            var columnWidth = slotWidth
            if let label = segment.label, let glyph = glyph(label, font: Self.labelFont, load: .normal) {
                columnWidth = max(columnWidth, glyph.width)
                placements.append(Placement(glyph: glyph, x: x + (columnWidth - glyph.width) / 2, y: valueHeight - 1))
            }
            let glyphs = segment.value.compactMap { glyph(String($0), font: valueFont, load: segment.load) }
            var valueX = x + (columnWidth - glyphs.reduce(0) { $0 + $1.width }) / 2
            for glyph in glyphs {
                placements.append(Placement(glyph: glyph, x: valueX, y: 0))
                valueX += glyph.width
            }
            x += columnWidth
        }

        if x != contentWidth {
            contentWidth = x
            onWidthChange?(x)
        }

        let scale = window?.backingScaleFactor ?? 2
        let originX = (bounds.width - x) / 2
        let originY = (bounds.height - blockHeight) / 2

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
            let placement = placements[index]
            let image = placement.glyph.image
            // Snap to device pixels and keep the bitmap's own size, so glyphs stay sharp.
            let frame = CGRect(
                x: ((originX + placement.x) * scale).rounded() / scale,
                y: ((originY + placement.y) * scale).rounded() / scale,
                width: CGFloat(image.width) / scale,
                height: CGFloat(image.height) / scale
            )
            // Touch only what changed, so Core Animation commits as little as possible.
            if (sublayer.contents as AnyObject?) !== image { sublayer.contents = image }
            if sublayer.frame != frame { sublayer.frame = frame }
            if sublayer.contentsScale != scale { sublayer.contentsScale = scale }
            if sublayer.isHidden { sublayer.isHidden = false }
        }
        CATransaction.commit()
    }

    private func slotWidth(_ font: NSFont) -> CGFloat {
        if let width = slotWidths[font.pointSize] { return width }
        let width = ceil(NSAttributedString(string: "100", attributes: [.font: font]).size().width)
        slotWidths[font.pointSize] = width
        return width
    }

    private func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender)
    }

    // MARK: - Glyph cache

    private func glyph(_ text: String, font: NSFont, load: Load) -> Glyph? {
        let key = "\(font.pointSize)|\(load)|\(text)"
        if let glyph = cache[key] { return glyph }
        guard let glyph = makeGlyph(text, font: font, color: color(for: load)) else { return nil }
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

    private func makeGlyph(_ text: String, font: NSFont, color: NSColor) -> Glyph? {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let width = string.size().width
        let height = lineHeight(font)
        let scale = window?.backingScaleFactor ?? 2
        guard
            width > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: Int(ceil(width * scale)),
                height: Int(ceil(height * scale)),
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
            string.draw(at: NSPoint(x: 0, y: -font.descender))
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return Glyph(image: image, width: width)
    }
}
