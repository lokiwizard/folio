import SwiftUI
import CoreGraphics

// The worker owns a separate Quartz document. PDFKit can render the reading window concurrently.
actor PinPreviewStore {
    nonisolated let id = UUID()
    private let file: PaperFile
    private var password: String?
    private lazy var document: CGPDFDocument? = {
        defer { password = nil }
        let document = CGPDFDocument(file.currentURL as CFURL)
        if let document, !document.isUnlocked, let password {
            _ = document.unlockWithPassword(password)
        }
        return document
    }()
    private let cache = NSCache<NSString, CGImage>()
    init(file: PaperFile, password: String?) {
        self.file = file
        self.password = password
        cache.countLimit = 50
        cache.totalCostLimit = 16 * 1024 * 1024
    }
    func jpeg(for pin: Pin, rotation: Int?) -> Data? {
        guard let cg = image(for: pin, rotation: rotation, large: true) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
    func detail(for source: Anchor, rotation: Int, visible: CGRect, pixels: CGFloat) -> CGImage? {
        guard !Task.isCancelled, let document, document.isUnlocked, source.page >= 0, source.page < document.numberOfPages,
              let page = document.page(at: source.page + 1) else { return nil }
        let crop = source.rect.intersection(page.getBoxRect(.cropBox))
        let region = visible.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isEmpty, !crop.isEmpty else { return nil }
        let a = PinStroke.rotate(region.origin, by: -rotation)
        let b = PinStroke.rotate(CGPoint(x: region.maxX, y: region.maxY), by: -rotation)
        let selection = CGRect(x: crop.minX + min(a.x, b.x) * crop.width, y: crop.minY + (1 - max(a.y, b.y)) * crop.height,
                               width: abs(b.x - a.x) * crop.width, height: abs(b.y - a.y) * crop.height)
        return ClipRenderer.image(selection, page: page, rotation: rotation, maxEdge: min(4096, max(1, pixels)), scale: .greatestFiniteMagnitude)
    }

    func image(for pin: Pin, rotation: Int?, large: Bool) -> CGImage? {
        guard !Task.isCancelled, let document, document.isUnlocked else { return nil }
        let key = "\(pin.artworkID)/\(rotation.map(String.init) ?? "original")/\(large)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard pin.source.page >= 0, pin.source.page < document.numberOfPages,
              let page = document.page(at: pin.source.page + 1) else { return nil }
        guard let image = ClipRenderer.image(pin.source.rect, page: page, rotation: rotation ?? Int(page.rotationAngle),
                                             maxEdge: large ? 2200 : 680, scale: large ? 3 : 2, drawing: pin.drawing ?? []) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

struct PinArtwork<Content: View>: View {
    let store: PinPreviewStore
    let pin: Pin
    let rotation: Int?
    let large: Bool
    @ViewBuilder var content: (CGImage?) -> Content
    @State private var image: CGImage?

    var body: some View {
        content(image)
            .task(id: "\(store.id)/\(pin.artworkID)/\(rotation.map(String.init) ?? "original")/\(large)") {
                let result = await store.image(for: pin, rotation: rotation, large: large)
                if !Task.isCancelled { image = result }
            }
            .onDisappear { image = nil }
    }
}
