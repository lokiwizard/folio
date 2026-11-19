import AppKit

// Geometry uses the displayed image's aspect ratio. Convert back to page-relative
// coordinates only after the drag, so rotation does not skew a non-square crop.
struct PinShapeHandles {
    enum Kind: Equatable { case corner(Int), rotation, endpoint(Int), edge(Int) }
    struct Handle {
        let kind: Kind
        let position: CGPoint
    }
    let vertices: [CGPoint]
    let handles: [Handle]
    let stem: CGPoint?
    let rotationEdge: Int?
    let size: CGSize
    let pageRotation: Int
    private let textLayout: PinTextLayout?

    init?(_ stroke: PinStroke, size: CGSize, rotation: Int, preferredEdge: Int? = nil) {
        guard size.width > 0, size.height > 0, !stroke.points.isEmpty else { return nil }
        self.size = size
        pageRotation = rotation
        textLayout = stroke.tool == .text ? stroke.textLayout(size: size, rotation: rotation) : nil
        func visible(_ p: CGPoint) -> CGPoint {
            let pad = min(4, min(size.width, size.height) / 2)
            return CGPoint(x: min(size.width - pad, max(pad, p.x)), y: min(size.height - pad, max(pad, p.y)))
        }
        switch stroke.tool {
        case .text:
            guard let layout = textLayout else { return nil }
            let corners = layout.corners
            vertices = corners
            var grips = corners.enumerated().map { Handle(kind: .corner($0.offset), position: visible($0.element)) }
            for i in corners.indices {
                let a = corners[i], b = corners[(i + 1) % 4]
                grips.append(Handle(kind: .edge(i), position: visible(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))))
            }
            handles = grips
            stem = nil
            rotationEdge = nil
        case .arrow, .line:
            guard stroke.points.count >= 2 else { return nil }
            let ends = [stroke.points[0], stroke.points[stroke.points.count - 1]]
            vertices = ends.map { PinStroke.displayPoint($0, size: size, rotation: rotation) }
            handles = vertices.enumerated().map { Handle(kind: .endpoint($0.offset), position: visible($0.element)) }
            stem = nil
            rotationEdge = nil
        case .oval, .pen:
            let b = stroke.bounds(size: size, rotation: rotation)
            guard !b.isNull, max(b.width, b.height) >= 2 else { return nil }
            vertices = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                        CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
            handles = vertices.enumerated().map { Handle(kind: .corner($0.offset), position: visible($0.element)) }
            stem = nil
            rotationEdge = nil
        case .rectangle:
            guard stroke.points.count >= 2 else { return nil }
            let corners = stroke.rectangleVertices(size: size, rotation: rotation)
            vertices = corners
            var grips = corners.enumerated().map { Handle(kind: .corner($0.offset), position: visible($0.element)) }
            // Prefer the top edge. At a crop boundary put the knob on another
            // available edge, keeping it reachable for rectangles at the margin.
            var anchor = corners[0], knob = corners[0]
            var best = CGFloat.infinity, edge = 0
            for i in corners.indices where preferredEdge == nil || preferredEdge == i {
                let a = corners[i], b = corners[(i + 1) % 4]
                let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
                guard length > 0 else { continue }
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let candidate = CGPoint(x: mid.x + 19 * dy / length, y: mid.y - 19 * dx / length)
                let onImage = visible(candidate)
                let cost = hypot(candidate.x - onImage.x, candidate.y - onImage.y)
                if cost < best { anchor = mid; knob = onImage; best = cost; edge = i }
                if cost == 0 { break }
            }
            if hypot(knob.x - anchor.x, knob.y - anchor.y) < 9 {
                let center = CGPoint(x: (corners[0].x + corners[2].x) / 2, y: (corners[0].y + corners[2].y) / 2)
                let inward = atan2(center.y - anchor.y, center.x - anchor.x)
                knob = visible(CGPoint(x: anchor.x + 17 * cos(inward), y: anchor.y + 17 * sin(inward)))
            }
            rotationEdge = edge
            stem = anchor
            grips.append(Handle(kind: .rotation, position: knob))
            handles = grips
        default: return nil
        }
    }

    var hitRadius: CGFloat {
        guard let textLayout else { return 8 }
        return min(8, max(3, min(textLayout.bounds.width, textLayout.bounds.height) * 0.3))
    }

    func cursor(for handle: Handle) -> NSCursor {
        let direction: Int
        switch handle.kind {
        case .corner(let i): direction = i * 2 - 3
        case .edge(let i): direction = i * 2 - 2
        default: return .crosshair
        }
        let axis = atan2(vertices[1].y - vertices[0].y, vertices[1].x - vertices[0].x)
        let sector = (Int((axis / (.pi / 4)).rounded()) + direction + 16) % 8
        if #available(macOS 15.0, *) {
            let positions: [NSCursor.FrameResizePosition] = [.right, .bottomRight, .bottom, .bottomLeft, .left, .topLeft, .top, .topRight]
            return .frameResize(position: positions[sector], directions: .all)
        }
        switch sector % 4 {
        case 0: return .resizeLeftRight
        case 2: return .resizeUpDown
        default: return .crosshair
        }
    }

    func handle(at p: CGPoint) -> Handle? {
        if let box = textLayout?.bounds, min(box.width, box.height) < 20,
           box.insetBy(dx: min(3, box.width * 0.2), dy: min(3, box.height * 0.2)).contains(p) { return nil }
        let nearest = handles.min {
            hypot($0.position.x - p.x, $0.position.y - p.y) < hypot($1.position.x - p.x, $1.position.y - p.y)
        }
        guard let nearest, hypot(nearest.position.x - p.x, nearest.position.y - p.y) <= hitRadius else { return nil }
        return nearest
    }

    func adjusted(_ stroke: PinStroke, handle: Kind, from start: CGPoint, to end: CGPoint) -> PinStroke {
        guard start != end else { return stroke }
        let dx = end.x - start.x, dy = end.y - start.y
        let result: [CGPoint]
        switch handle {
        case let .endpoint(index):
            var point = CGPoint(x: min(size.width, max(0, vertices[index].x + dx)),
                                y: min(size.height, max(0, vertices[index].y + dy)))
            // Preserve a grabbable shaft, including when an endpoint crosses the other.
            let fixed = vertices[1 - index]
            if hypot(point.x - fixed.x, point.y - fixed.y) < 2 {
                let oldX = vertices[index].x - fixed.x, oldY = vertices[index].y - fixed.y
                let fraction = 2 / max(2, hypot(oldX, oldY))
                point = CGPoint(x: fixed.x + oldX * fraction, y: fixed.y + oldY * fraction)
            }
            var changed = stroke
            let movedIndex = index == 0 ? 0 : changed.points.count - 1
            changed.points[movedIndex] = PinStroke.rotate(CGPoint(x: point.x / size.width, y: point.y / size.height), by: -pageRotation)
            return changed
        case .edge:
            return textLayout?.resized(stroke, handle: handle, from: start, to: end) ?? stroke
        case let .corner(index):
            if let textLayout { return textLayout.resized(stroke, handle: handle, from: start, to: end) }
            if stroke.tool == .pen || stroke.tool == .oval {
                let fixed = vertices[(index + 2) % 4], previous = vertices[index]
                let tip = CGPoint(x: min(size.width, max(0, previous.x + dx)), y: min(size.height, max(0, previous.y + dy)))
                func scale(_ from: CGFloat, _ to: CGFloat, pivot: CGFloat) -> CGFloat {
                    guard abs(from - pivot) > 0.001 else { return 1 }
                    return max(min(1, 2 / abs(from - pivot)), (to - pivot) / (from - pivot))
                }
                let sx = scale(previous.x, tip.x, pivot: fixed.x), sy = scale(previous.y, tip.y, pivot: fixed.y)
                result = stroke.points.map {
                    let p = PinStroke.displayPoint($0, size: size, rotation: pageRotation)
                    return CGPoint(x: fixed.x + (p.x - fixed.x) * sx, y: fixed.y + (p.y - fixed.y) * sy)
                }
            } else { result = resized(corner: index, dx: dx, dy: dy) }
        case .rotation:
            let c = CGPoint(x: (vertices[0].x + vertices[2].x) / 2, y: (vertices[0].y + vertices[2].y) / 2)
            guard hypot(end.x - c.x, end.y - c.y) > 1 else { return stroke }
            let angle = atan2(end.y - c.y, end.x - c.x) - atan2(start.y - c.y, start.x - c.x)
            let rotation = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y)
            let rotated = vertices.map { $0.applying(rotation) }
            let path = CGMutablePath()
            path.addLines(between: rotated)
            let box = path.boundingBoxOfPath
            func correction(_ low: CGFloat, _ high: CGFloat, limit: CGFloat) -> CGFloat {
                if high - low > limit { return (limit - high - low) / 2 }
                return max(-low, min(0, limit - high))
            }
            let x = correction(box.minX, box.maxX, limit: size.width)
            let y = correction(box.minY, box.maxY, limit: size.height)
            result = rotated.map { CGPoint(x: $0.x + x, y: $0.y + y) }
        }
        var changed = stroke
        changed.points = result.map { PinStroke.rotate(CGPoint(x: $0.x / size.width, y: $0.y / size.height), by: -pageRotation) }
        return changed
    }

    private func resized(corner index: Int, dx: CGFloat, dy: CGFloat) -> [CGPoint] {
        let fixed = vertices[(index + 2) % 4]
        let first = vertices[0], right = vertices[1], bottom = vertices[3]
        let width = hypot(right.x - first.x, right.y - first.y), height = hypot(bottom.x - first.x, bottom.y - first.y)
        let angle = width > 0.000001 ? atan2(right.y - first.y, right.x - first.x) : atan2(bottom.y - first.y, bottom.x - first.x) - .pi / 2
        let ux = cos(angle), uy = sin(angle)
        let signs: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        let (sx, sy) = signs[index]
        let w = sx * max(min(3, max(1, width)), width + sx * (dx * ux + dy * uy))
        let h = sy * max(min(3, max(1, height)), height + sy * (-dx * uy + dy * ux))
        let proposed = signs.map { xSign, ySign in
            let x = xSign == sx ? w : 0, y = ySign == sy ? h : 0
            return CGPoint(x: fixed.x + x * ux - y * uy, y: fixed.y + x * uy + y * ux)
        }
        // Limit the whole resize together. Independent clipping of vertices
        // would turn a rotated rectangle into a trapezoid.
        var fraction: CGFloat = 1
        func constrain(_ old: CGFloat, _ new: CGFloat, limit: CGFloat) {
            if new < min(0, old) { fraction = min(fraction, (min(0, old) - old) / (new - old)) }
            if new > max(limit, old) { fraction = min(fraction, (max(limit, old) - old) / (new - old)) }
        }
        for (old, new) in zip(vertices, proposed) {
            constrain(old.x, new.x, limit: size.width)
            constrain(old.y, new.y, limit: size.height)
        }
        return zip(vertices, proposed).map { old, new in
            CGPoint(x: old.x + fraction * (new.x - old.x), y: old.y + fraction * (new.y - old.y))
        }
    }
}
