import AppKit

enum PinDrawingTool: String, Codable, CaseIterable {
    case hand, pen, line, rectangle, oval, arrow, text

    var acceptsText: Bool { self == .text || self == .rectangle || self == .oval }

    var symbol: String {
        switch self {
        case .hand: "hand.raised"
        case .text: "textbox"
        case .pen: "pencil.tip"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .oval: "oval"
        case .arrow: "arrow.up.right"
        }
    }

    var title: String {
        switch self {
        case .hand: bilingual("选择", "Select")
        case .text: bilingual("文本框", "Text box")
        case .pen: bilingual("画笔", "Pen")
        case .line: bilingual("直线", "Line")
        case .rectangle: bilingual("矩形框", "Rectangle")
        case .oval: bilingual("椭圆框", "Ellipse")
        case .arrow: bilingual("箭头", "Arrow")
        }
    }
}

struct PinStroke: Identifiable, Codable, Equatable {
    let id: UUID
    let tool: PinDrawingTool
    var color: PinColor
    var width: CGFloat
    var dashed: Bool
    // Unit coordinates in the unrotated clip, measured from its top left.
    var points: [CGPoint]
    var label: PinTextLabel?

    static func rotate(_ point: CGPoint, by angle: Int) -> CGPoint {
        switch (angle % 360 + 360) % 360 {
        case 90: CGPoint(x: 1 - point.y, y: point.x)
        case 180: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 270: CGPoint(x: point.y, y: 1 - point.x)
        default: point
        }
    }

    func textLayout(size: CGSize, rotation: Int) -> PinTextLayout? {
        guard let label, let anchor = points.first else { return nil }
        if tool == .rectangle || tool == .oval {
            let corners = rectangleVertices(size: size, rotation: rotation)
            guard corners.count == 4 else { return nil }
            let start = ((4 - label.orientation / 90) % 4 + 4) % 4
            let center = CGPoint(x: (corners[0].x + corners[2].x) / 2, y: (corners[0].y + corners[2].y) / 2)
            let factor = tool == .oval ? sqrt(0.5) : 1
            let container = (0..<4).map { i in
                let p = corners[(start + i) % 4]
                return CGPoint(x: center.x + (p.x - center.x) * factor, y: center.y + (p.y - center.y) * factor)
            }
            return PinTextLayout(label: label, anchor: anchor, color: color, size: size, rotation: rotation, container: container)
        }
        return PinTextLayout(label: label, anchor: anchor, color: color, size: size, rotation: rotation)
    }

    static func displayPoint(_ p: CGPoint, size: CGSize, rotation: Int) -> CGPoint {
        let u = rotate(p, by: rotation)
        return CGPoint(x: u.x * size.width, y: u.y * size.height)
    }

    func rectangleVertices(size: CGSize, rotation: Int) -> [CGPoint] {
        // Legacy and freshly drawn rectangles use opposite corners. Once
        // transformed, store all four in winding order to retain their angle.
        if points.count == 4 { return points.map { Self.displayPoint($0, size: size, rotation: rotation) } }
        guard let a = points.first, let b = points.last else { return [] }
        let left = min(a.x, b.x), right = max(a.x, b.x), top = min(a.y, b.y), bottom = max(a.y, b.y)
        return [CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)]
            .map { Self.displayPoint($0, size: size, rotation: rotation) }
    }

    func geometry(size: CGSize, rotation: Int) -> (path: CGPath, head: CGPath?) {
        let path = CGMutablePath()
        func location(_ p: CGPoint) -> CGPoint {
            Self.displayPoint(p, size: size, rotation: rotation)
        }
        guard let first = points.first, let last = points.last else { return (path, nil) }
        let start = location(first), end = location(last)
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(start.x - end.x), height: abs(start.y - end.y))
        switch tool {
        case .rectangle:
            path.addLines(between: rectangleVertices(size: size, rotation: rotation))
            path.closeSubpath()
        case .oval: path.addEllipse(in: box)
        case .pen, .line, .arrow:
            path.move(to: start)
            for p in points.dropFirst() { path.addLine(to: location(p)) }
            if points.count == 1 { path.addLine(to: start) }
        case .hand, .text: break
        }
        let dx = end.x - start.x, dy = end.y - start.y, length = hypot(dx, dy)
        guard tool == .arrow, length > 0 else { return (path, nil) }
        let head = min(5 * width * max(size.width, size.height), length * 0.55)
        let ux = dx / length, uy = dy / length
        let base = CGPoint(x: end.x - head * ux, y: end.y - head * uy)
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: base.x - uy * head * 0.52, y: base.y + ux * head * 0.52))
        tip.addLine(to: end)
        tip.addLine(to: CGPoint(x: base.x + uy * head * 0.52, y: base.y - ux * head * 0.52))
        return (path, tip)
    }

    func bounds(size: CGSize, rotation: Int) -> CGRect {
        if tool == .text, let layout = textLayout(size: size, rotation: rotation) { return layout.bounds }
        let (path, head) = geometry(size: size, rotation: rotation)
        return path.boundingBoxOfPath.union(head?.boundingBoxOfPath ?? .null)
    }

    func hit(_ point: CGPoint, size: CGSize, rotation: Int, interior: Bool) -> Bool {
        if tool == .text, let layout = textLayout(size: size, rotation: rotation) { return !interior && layout.bounds.contains(point) }
        if tool == .pen, points.count == 1, let p = points.first {
            let dot = Self.displayPoint(p, size: size, rotation: rotation)
            return hypot(dot.x - point.x, dot.y - point.y) <= (width * max(size.width, size.height)) / 2 + 5
        }
        let (path, head) = geometry(size: size, rotation: rotation)
        if interior { return (tool == .rectangle || tool == .oval) && path.contains(point) }
        let tolerance = width * max(size.width, size.height) + 10
        return [path, head].compactMap { $0 }.contains {
            $0.copy(strokingWithWidth: tolerance, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(point)
        }
    }

    func draw(in ctx: CGContext, size: CGSize, rotation: Int, showText: Bool = true) {
        if tool == .text {
            if showText { textLayout(size: size, rotation: rotation)?.draw(in: ctx) }
            return
        }
        let (path, head) = geometry(size: size, rotation: rotation)
        let thickness = width * max(size.width, size.height)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.color.cgColor)
        ctx.setLineWidth(thickness)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if tool == .pen, points.count == 1, let p = points.first {
            let center = Self.rotate(p, by: rotation)
            ctx.setFillColor(color.color.cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x * size.width - thickness / 2, y: center.y * size.height - thickness / 2,
                                       width: thickness, height: thickness))
            return
        }
        if dashed && tool != .pen { ctx.setLineDash(phase: 0, lengths: [3 * thickness, 2.4 * thickness]) }
        ctx.addPath(path)
        ctx.strokePath()
        if let head {
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.addPath(head)
            ctx.strokePath()
        }
        if showText, label != nil { textLayout(size: size, rotation: rotation)?.draw(in: ctx) }
    }
}

extension Pin {
    var artworkID: String {
        let version = drawing?.isEmpty == false ? (drawingRevision ?? drawing?.last?.id) : nil
        return id.uuidString + "/" + (version?.uuidString ?? "original")
    }
}
