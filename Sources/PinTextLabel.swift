import AppKit
import CoreText

struct PinTextLabel: Codable, Equatable {
    var string: String
    let orientation: Int
    var boxWidth: CGFloat   // Fraction of the image width at creation.
    var fontSize: CGFloat   // Fraction of the longer image edge.
    var boxHeight: CGFloat? = nil   // Minimum height in the original writing orientation.
}

// Lay out once at a consistent scale so a thumbnail wraps at the same words as an exported PNG.
struct PinTextLayout {
    let transform: CGAffineTransform
    let basis: CGSize
    let box: CGRect
    let frame: CTFrame

    private let setter: CTFramesetter
    private let lineHeight: CGFloat

    init(label: PinTextLabel, anchor: CGPoint, color: PinColor, size: CGSize, rotation: Int, container: [CGPoint]? = nil) {
        let scale = max(size.width, size.height, 1) / 1000
        let font = NSFont.systemFont(ofSize: max(1, label.fontSize * 1000))
        lineHeight = font.ascender - font.descender
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = container == nil ? .natural : .center
        let text = NSAttributedString(string: label.string, attributes: [.font: font, .foregroundColor: color.color, .paragraphStyle: paragraph])
        let setter = CTFramesetterCreateWithAttributedString(text)
        self.setter = setter
        if let container {
            let a = container[0], b = container[1], d = container[3]
            let angle = atan2(b.y - a.y, b.x - a.x)
            transform = CGAffineTransform(translationX: a.x, y: a.y).rotated(by: angle).scaledBy(x: scale, y: scale)
            basis = CGSize(width: max(1, hypot(b.x - a.x, b.y - a.y) / scale),
                           height: max(1, hypot(d.x - a.x, d.y - a.y) / scale))
            let inset = min(font.pointSize * 0.22, basis.width * 0.1)
            let width = max(1, basis.width - 2 * inset)
            let height = min(basis.height, Self.requiredHeight(setter, width: width, lineHeight: lineHeight))
            box = CGRect(x: (basis.width - width) / 2, y: (basis.height - height) / 2, width: width, height: height)
        } else {
            let delta = ((rotation - label.orientation) % 360 + 360) % 360
            basis = CGSize(width: (delta % 180 == 0 ? size.width : size.height) / scale,
                           height: (delta % 180 == 0 ? size.height : size.width) / scale)
            let turn: CGAffineTransform
            switch delta {
            case 90: turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.width, ty: 0)
            case 180: turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
            case 270: turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.height)
            default: turn = .identity
            }
            transform = turn.scaledBy(x: scale, y: scale)
            let width = max(1, basis.width * min(1, max(0, label.boxWidth)))
            let height = min(basis.height, max((label.boxHeight ?? 0) * basis.height, Self.requiredHeight(setter, width: width, lineHeight: lineHeight)))
            let p = PinStroke.rotate(anchor, by: label.orientation)
            box = CGRect(x: max(0, min(p.x * basis.width, basis.width - width)),
                         y: max(0, min(p.y * basis.height, basis.height - height)), width: width, height: height)
        }
        let path = CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil)
        frame = CTFramesetterCreateFrame(setter, CFRange(), path, nil)
    }

    private static func requiredHeight(_ setter: CTFramesetter, width: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                            CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude), nil)
        return ceil(max(lineHeight, measured.height)) + 2
    }

    var bounds: CGRect { box.applying(transform) }
    var origin: CGPoint { box.origin.applying(transform) }

    var corners: [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
         CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].map { $0.applying(transform) }
    }

    // Work in the text's original writing direction, even on a rotated PDF page.
    func resized(_ stroke: PinStroke, handle: PinShapeHandles.Kind, from start: CGPoint, to end: CGPoint) -> PinStroke {
        guard var label = stroke.label, box.width > 0, box.height > 0 else { return stroke }
        let left: Bool, right: Bool, top: Bool, bottom: Bool
        switch handle {
        case let .corner(i):
            left = i == 0 || i == 3; right = !left
            top = i < 2; bottom = !top
        case let .edge(i):
            top = i == 0; right = i == 1; bottom = i == 2; left = i == 3
        default: return stroke
        }
        let inverse = transform.inverted(), a = start.applying(inverse), b = end.applying(inverse)
        let dx = b.x - a.x, dy = b.y - a.y
        let availableWidth = left ? box.maxX : basis.width - box.minX
        let availableHeight = top ? box.maxY : basis.height - box.minY
        let minWidth = min(box.width, max(8, label.fontSize * 1000 + 2))
        var width = left || right ? min(availableWidth, max(minWidth, box.width + (left ? -dx : dx))) : box.width
        func contentHeight(_ w: CGFloat) -> CGFloat { Self.requiredHeight(setter, width: w, lineHeight: lineHeight) }
        var natural = contentHeight(width)
        // Near a crop boundary, stop narrowing at the last width that still fits the text.
        if natural > availableHeight, width < box.width, contentHeight(box.width) <= availableHeight {
            var low = width, high = box.width
            for _ in 0..<12 {
                let mid = (low + high) / 2
                if contentHeight(mid) > availableHeight { low = mid } else { high = mid }
            }
            width = high
            natural = contentHeight(width)
        }
        if left || right { label.boxWidth = width / basis.width }
        let vertical = (top || bottom) && abs(dy) > 0.000001
        if vertical {
            let height = min(availableHeight, max(natural, box.height + (top ? -dy : dy)))
            label.boxHeight = height / basis.height
        }
        let height = min(basis.height, max(natural, (label.boxHeight ?? 0) * basis.height))
        let x = left ? box.maxX - width : box.minX
        let y = top ? box.maxY - height : box.minY
        var changed = stroke
        changed.label = label
        let origin = CGPoint(x: max(0, min(basis.width - width, x)) / basis.width,
                             y: max(0, min(basis.height - height, y)) / basis.height)
        changed.points = [PinStroke.rotate(origin, by: -label.orientation)]
        return changed
    }

    func draw(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(transform)
        context.translateBy(x: box.minX, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }
}
