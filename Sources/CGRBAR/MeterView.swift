import AppKit

enum MeterTint: Hashable {
    case primary
    case metric(Metric)
    case high
    case critical
}

struct MeterSegment: Equatable {
    var metric: Metric
    var style: MeterStyle
    /// Fraction in 0...1, or nil while unavailable.
    var value: Double?
    /// Recent values, oldest first. Only used by the chart style.
    var history: [Double]
    var labelTint: MeterTint
    var valueTint: MeterTint
}

struct MeterLayout: Equatable {
    var size: MeterSize = .medium
    var spacing: CGFloat = 6
}

/// Draws the menu bar readout without text layout on every update.
///
/// Text (labels, symbols and single value characters) is rendered once into
/// cached images. Bars and charts are plain layers. An update only touches the
/// layers whose content changed, which avoids the button cell, CoreText and
/// Auto Layout passes that a title change would trigger.
@MainActor
final class MeterView: NSView {
    /// Called when the content width changes, so the status item can resize.
    var onWidthChange: ((CGFloat) -> Void)?

    private(set) var contentWidth: CGFloat = 0
    private var segments: [MeterSegment] = []
    private var meterLayout = MeterLayout()

    private var glyphs: [GlyphKey: Glyph] = [:]
    private var colors: [ColorKey: CGColor] = [:]
    private var slotWidths: [CGFloat: CGFloat] = [:]

    // Separate containers keep bars below charts below text.
    private let rectContainer = CALayer()
    private let shapeContainer = CALayer()
    private let imageContainer = CALayer()
    private var rectLayers: [CALayer] = []
    private var shapeLayers: [CAShapeLayer] = []
    private var imageLayers: [CALayer] = []

    private struct Glyph {
        var image: CGImage
        var width: CGFloat
    }

    // Struct keys instead of interpolated strings: lookups run for every
    // character on every update.
    private struct GlyphKey: Hashable {
        var text: String
        var font: String
        var size: CGFloat
        var height: CGFloat
        var tint: MeterTint
    }

    private struct ColorKey: Hashable {
        var tint: MeterTint
        var alpha: CGFloat
    }

    private enum Element {
        case glyph(Glyph, CGPoint)
        case rect(CGRect, MeterTint, alpha: CGFloat)
        case line(CGPath, MeterTint)
        case area(CGPath, MeterTint)
    }

    /// Fonts and shape sizes for one size setting.
    private struct Dimensions {
        let labelFont: NSFont
        let stackedFont: NSFont
        let inlineFont: NSFont
        let symbolSize: CGFloat
        let bar: CGSize
        let chart: CGSize

        init(_ size: MeterSize) {
            let (label, stacked, inline, bar, chart): (CGFloat, CGFloat, CGFloat, CGSize, CGSize) = switch size {
            case .small: (7, 10, 11, CGSize(width: 4, height: 14), CGSize(width: 24, height: 12))
            case .medium: (7.5, 11, 12, CGSize(width: 5, height: 16), CGSize(width: 30, height: 14))
            case .large: (8.5, 12.5, 13.5, CGSize(width: 6, height: 18), CGSize(width: 36, height: 16))
            }
            labelFont = .systemFont(ofSize: label, weight: .semibold)
            stackedFont = .monospacedDigitSystemFont(ofSize: stacked, weight: .semibold)
            inlineFont = .monospacedDigitSystemFont(ofSize: inline, weight: .medium)
            symbolSize = inline - 1
            self.bar = bar
            self.chart = chart
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for container in [rectContainer, shapeContainer, imageContainer] {
            layer?.addSublayer(container)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Clicks belong to the status bar button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Returns false when nothing changed and nothing was drawn.
    @discardableResult
    func update(_ segments: [MeterSegment], layout: MeterLayout) -> Bool {
        guard segments != self.segments || layout != meterLayout else { return false }
        self.segments = segments
        meterLayout = layout
        render()
        return true
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
        glyphs.removeAll()
        colors.removeAll()
        slotWidths.removeAll()
        render()
    }

    // MARK: - Layout

    private func render() {
        let dimensions = Dimensions(meterLayout.size)
        var elements: [Element] = []
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if index > 0 { x += meterLayout.spacing }
            x += layOut(segment, at: x, dimensions, into: &elements)
        }

        if x != contentWidth {
            contentWidth = x
            onWidthChange?(x)
        }

        let origin = CGPoint(x: (bounds.width - x) / 2, y: 0)
        apply(elements, offset: origin)
    }

    /// Adds the elements for one segment and returns its width.
    private func layOut(
        _ segment: MeterSegment,
        at x: CGFloat,
        _ dimensions: Dimensions,
        into elements: inout [Element]
    ) -> CGFloat {
        let midY = bounds.height / 2
        let text = segment.value.map(Format.number) ?? "–"

        switch segment.style {
        case .stacked:
            let font = dimensions.stackedFont
            let valueHeight = lineHeight(font)
            let labelHeight = lineHeight(dimensions.labelFont) - 1
            let y = midY - (valueHeight + labelHeight) / 2
            var width = slotWidth(font)
            if let label = glyph(segment.metric.label, font: dimensions.labelFont, tint: segment.labelTint) {
                width = max(width, label.width)
                elements.append(.glyph(label, CGPoint(x: x + (width - label.width) / 2, y: y + valueHeight - 1)))
            }
            addValue(text, font: font, tint: segment.valueTint, centeredIn: x, width: width, y: y, into: &elements)
            return width

        case .number:
            let font = dimensions.inlineFont
            let width = slotWidth(font)
            addValue(text, font: font, tint: segment.valueTint, centeredIn: x, width: width, y: midY - lineHeight(font) / 2, into: &elements)
            return width

        case .icon:
            let font = dimensions.inlineFont
            var iconWidth: CGFloat = 0
            if let icon = symbolGlyph(segment.metric.symbolName, size: dimensions.symbolSize, height: lineHeight(font), tint: segment.labelTint) {
                iconWidth = icon.width + 3
                elements.append(.glyph(icon, CGPoint(x: x, y: midY - lineHeight(font) / 2)))
            }
            let width = slotWidth(font)
            addValue(text, font: font, tint: segment.valueTint, centeredIn: x + iconWidth, width: width, y: midY - lineHeight(font) / 2, into: &elements)
            return iconWidth + width

        case .bar:
            let size = dimensions.bar
            let track = CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
            elements.append(.rect(track, segment.labelTint, alpha: 0.25))
            if let value = segment.value, value > 0 {
                let height = max(size.width, (size.height * min(value, 1)).rounded())
                elements.append(.rect(CGRect(x: track.minX, y: track.minY, width: size.width, height: height), segment.valueTint, alpha: 1))
            }
            return size.width

        case .chart:
            let size = dimensions.chart
            let frame = CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
            elements.append(.rect(frame, segment.labelTint, alpha: 0.12))
            // About one sample per two points of width.
            let values = Array(segment.history.suffix(Int(size.width / 2) + 1))
            if values.count > 1 {
                let inset = frame.insetBy(dx: 1, dy: 1.5)
                let step = inset.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { index, value in
                    CGPoint(x: inset.minX + CGFloat(index) * step, y: inset.minY + CGFloat(min(max(value, 0), 1)) * inset.height)
                }
                let line = CGMutablePath()
                line.addLines(between: points)
                let area = CGMutablePath()
                area.addLines(between: [CGPoint(x: points[0].x, y: inset.minY)] + points + [CGPoint(x: inset.maxX, y: inset.minY)])
                area.closeSubpath()
                elements.append(.area(area, segment.valueTint))
                elements.append(.line(line, segment.valueTint))
            }
            return size.width
        }
    }

    private func addValue(
        _ text: String,
        font: NSFont,
        tint: MeterTint,
        centeredIn x: CGFloat,
        width: CGFloat,
        y: CGFloat,
        into elements: inout [Element]
    ) {
        let characters = text.compactMap { glyph(String($0), font: font, tint: tint) }
        var glyphX = x + (width - characters.reduce(0) { $0 + $1.width }) / 2
        for character in characters {
            elements.append(.glyph(character, CGPoint(x: glyphX, y: y)))
            glyphX += character.width
        }
    }

    // MARK: - Layers

    private func apply(_ elements: [Element], offset: CGPoint) {
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var imageIndex = 0, rectIndex = 0, shapeIndex = 0

        for element in elements {
            switch element {
            case let .glyph(glyph, point):
                let layer = pooled(&imageLayers, in: imageContainer, at: imageIndex)
                imageIndex += 1
                let image = glyph.image
                // Snap to device pixels and keep the bitmap's own size, so glyphs stay sharp.
                let frame = CGRect(
                    x: snap(offset.x + point.x),
                    y: snap(offset.y + point.y),
                    width: CGFloat(image.width) / scale,
                    height: CGFloat(image.height) / scale
                )
                // Touch only what changed, so Core Animation commits as little as possible.
                if (layer.contents as AnyObject?) !== image { layer.contents = image }
                if layer.frame != frame { layer.frame = frame }
                if layer.contentsScale != scale { layer.contentsScale = scale }

            case let .rect(rect, tint, alpha):
                let layer = pooled(&rectLayers, in: rectContainer, at: rectIndex)
                rectIndex += 1
                let frame = CGRect(x: snap(offset.x + rect.minX), y: snap(offset.y + rect.minY), width: rect.width, height: rect.height)
                let color = cgColor(tint, alpha: alpha)
                if layer.frame != frame { layer.frame = frame }
                if layer.backgroundColor != color { layer.backgroundColor = color }
                // Thin level bars are pills; chart backgrounds get soft corners.
                let radius = rect.width < 8 ? rect.width / 2 : 2.5
                if layer.cornerRadius != radius { layer.cornerRadius = radius }

            case let .line(path, tint), let .area(path, tint):
                let layer = pooledShape(at: shapeIndex)
                shapeIndex += 1
                var transform = CGAffineTransform(translationX: offset.x, y: offset.y)
                layer.path = path.copy(using: &transform)
                if case .line = element {
                    layer.fillColor = nil
                    layer.strokeColor = cgColor(tint, alpha: 1)
                    layer.lineWidth = 1.25
                    layer.lineJoin = .round
                    layer.lineCap = .round
                } else {
                    layer.strokeColor = nil
                    layer.fillColor = cgColor(tint, alpha: 0.3)
                }
                if layer.contentsScale != scale { layer.contentsScale = scale }
            }
        }

        hide(imageLayers, from: imageIndex)
        hide(rectLayers, from: rectIndex)
        hide(shapeLayers, from: shapeIndex)
        CATransaction.commit()
    }

    private func pooled(_ pool: inout [CALayer], in container: CALayer, at index: Int) -> CALayer {
        if index == pool.count {
            let layer = CALayer()
            container.addSublayer(layer)
            pool.append(layer)
        }
        let layer = pool[index]
        if layer.isHidden { layer.isHidden = false }
        return layer
    }

    private func pooledShape(at index: Int) -> CAShapeLayer {
        if index == shapeLayers.count {
            let layer = CAShapeLayer()
            layer.frame = bounds
            shapeContainer.addSublayer(layer)
            shapeLayers.append(layer)
        }
        let layer = shapeLayers[index]
        if layer.isHidden { layer.isHidden = false }
        if layer.frame != bounds { layer.frame = bounds }
        return layer
    }

    private func hide(_ layers: [CALayer], from index: Int) {
        for layer in layers[index...] where !layer.isHidden {
            layer.isHidden = true
        }
    }

    // MARK: - Caches

    private func slotWidth(_ font: NSFont) -> CGFloat {
        if let width = slotWidths[font.pointSize] { return width }
        // Every value column is as wide as "100", so the width never jumps.
        let width = ceil(NSAttributedString(string: "100", attributes: [.font: font]).size().width)
        slotWidths[font.pointSize] = width
        return width
    }

    private func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender)
    }

    private func nsColor(_ tint: MeterTint) -> NSColor {
        switch tint {
        case .primary: .labelColor
        case .metric(.cpu): .systemBlue
        case .metric(.gpu): .systemPurple
        case .metric(.memory): .systemTeal
        case .high: .systemOrange
        case .critical: .systemRed
        }
    }

    /// Dynamic colors resolved against the menu bar's appearance.
    private func cgColor(_ tint: MeterTint, alpha: CGFloat) -> CGColor {
        let key = ColorKey(tint: tint, alpha: alpha)
        if let color = colors[key] { return color }
        var color = CGColor(gray: 0, alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = nsColor(tint).withAlphaComponent(alpha).cgColor
        }
        colors[key] = color
        return color
    }

    private func glyph(_ text: String, font: NSFont, tint: MeterTint) -> Glyph? {
        let key = GlyphKey(text: text, font: font.fontName, size: font.pointSize, height: 0, tint: tint)
        if let glyph = glyphs[key] { return glyph }
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: nsColor(tint)])
        let glyph = makeGlyph(width: string.size().width, height: lineHeight(font)) {
            // In an unflipped context the point is the bottom of the line,
            // descender included, so the baseline lands at -descender.
            string.draw(at: .zero)
        }
        glyphs[key] = glyph
        return glyph
    }

    private func symbolGlyph(_ name: String, size: CGFloat, height: CGFloat, tint: MeterTint) -> Glyph? {
        let key = GlyphKey(text: name, font: "symbol", size: size, height: height, tint: tint)
        if let glyph = glyphs[key] { return glyph }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(.init(paletteColors: [nsColor(tint)]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        let glyph = makeGlyph(width: symbol.size.width, height: height) {
            symbol.draw(at: NSPoint(x: 0, y: (height - symbol.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        }
        glyphs[key] = glyph
        return glyph
    }

    private func makeGlyph(width: CGFloat, height: CGFloat, draw: () -> Void) -> Glyph? {
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
        effectiveAppearance.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return Glyph(image: image, width: width)
    }
}
