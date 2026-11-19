import CryptoKit
import PDFKit

struct PDFHighlightID: Codable, Hashable {
    let page: Int
    let key: String
    let occurrence: Int

    // Names (/NM) are optional. EagerPDF, for example, saves just the marked quads.
    static func annotations(on page: PDFPage, index: Int) -> [(PDFHighlightID, PDFAnnotation)] {
        var counts: [String: Int] = [:]
        return page.annotations.compactMap { mark in
            guard mark.type == "Highlight", mark.shouldDisplay else { return nil }
            let key: String
            if let name = mark.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String, !name.isEmpty {
                key = "id:" + name
            } else {
                let rect = mark.bounds
                var coordinates = [rect.minX, rect.minY, rect.width, rect.height]
                for point in mark.quadrilateralPoints ?? [] {
                    coordinates.append(point.pointValue.x)
                    coordinates.append(point.pointValue.y)
                }
                let geometry = coordinates.map { String(Double($0).bitPattern, radix: 16) }.joined(separator: "/")
                key = SHA256.hash(data: Data(geometry.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            let occurrence = counts[key, default: 0]
            counts[key] = occurrence + 1
            return (PDFHighlightID(page: index, key: key, occurrence: occurrence), mark)
        }
    }
}

extension Excerpt {
    init?(annotation: PDFAnnotation, source: PDFHighlightID, page: PDFPage, canCopy: Bool) {
        let bounds = annotation.bounds.standardized
        let crop = page.bounds(for: .cropBox)
        let points = annotation.quadrilateralPoints ?? []
        var lines: [Anchor] = []
        // PDFKit returns each quad relative to the annotation origin, even on rotated pages.
        for start in stride(from: 0, to: points.count - points.count % 4, by: 4) {
            var rect = CGRect.null
            for value in points[start..<(start + 4)] {
                rect = rect.union(CGRect(origin: value.pointValue, size: .zero))
            }
            rect = rect.offsetBy(dx: bounds.minX, dy: bounds.minY).intersection(crop)
            if !rect.isEmpty && !rect.isInfinite { lines.append(Anchor(page: source.page, rect: rect)) }
        }
        if lines.isEmpty {
            let rect = bounds.intersection(crop)
            guard !rect.isEmpty, !rect.isInfinite else { return nil }
            lines.append(Anchor(page: source.page, rect: rect))
        }
        let text = canCopy ? lines.compactMap { line in
            page.selection(for: line.rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: "\n") : ""
        self.init(text: text, note: annotation.contents ?? "", lines: lines, sourceHighlight: source)
    }
}
