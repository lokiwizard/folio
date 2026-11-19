import PDFKit

struct PageThumbnailRequest: Equatable {
    let page: Int
    let rotation: Int?
    let marksRevision: Int
}

// This document is confined to the worker. PDFView keeps its own pages and annotations on the main thread.
actor PageThumbnailStore {
    private final class Entry {
        let request: PageThumbnailRequest
        let image: CGImage

        init(_ request: PageThumbnailRequest, _ image: CGImage) {
            self.request = request
            self.image = image
        }
    }

    private let file: PaperFile
    private var password: String?
    private lazy var document: PDFDocument? = {
        defer { password = nil }
        guard let pdf = PDFDocument(url: file.currentURL) else { return nil }
        if pdf.isLocked {
            guard let password, pdf.unlock(withPassword: password) else { return nil }
        }
        return pdf
    }()
    private let cache = NSCache<NSNumber, Entry>()

    init(file: PaperFile, password: String?) {
        self.file = file
        self.password = password
        cache.countLimit = 48
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func search(_ needle: String) async -> (hits: [SearchHit], byPage: [Int: Range<Int>]) {
        guard !needle.isEmpty, let document else { return ([], [:]) }
        var hits: [SearchHit] = [], byPage: [Int: Range<Int>] = [:]
        for index in 0..<document.pageCount {
            if Task.isCancelled { return ([], [:]) }
            let start = hits.count
            autoreleasepool {
                guard let text = document.page(at: index)?.string as NSString? else { return }
                var offset = 0
                while offset < text.length && !Task.isCancelled {
                    let match = text.range(of: needle, options: .caseInsensitive, range: NSRange(location: offset, length: text.length - offset))
                    guard match.location != NSNotFound, match.length > 0 else { break }
                    hits.append(SearchHit(page: index, range: match))
                    offset = NSMaxRange(match)
                }
            }
            if hits.count > start { byPage[index] = start..<hits.count }
            await Task.yield()
        }
        return (hits, byPage)
    }

    func exportNotebook(to url: URL, title: String, state: PaperState, tags: [SemanticTag]) throws {
        guard let document else { throw ReaderError(L("无法打开文件。请检查文件位置和 PDF 格式。")) }
        try NotebookExport.write(to: url, title: title, document: document, state: state, tags: tags)
    }

    func paperText() async throws -> String {
        guard let document, document.allowsCopying else { throw ReaderError(bilingual("无法提取这份 PDF 的文字。", "Text extraction is unavailable for this PDF.")) }
        var pages: [String] = []
        for i in 0..<document.pageCount {
            try Task.checkCancellation()
            autoreleasepool {
                if let text = document.page(at: i)?.string, text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil {
                    pages.append(pageName(i) + "\n" + text)
                }
            }
            await Task.yield()
        }
        guard !pages.isEmpty else { throw ReaderError(bilingual("这份 PDF 没有可读取的文字层。", "This PDF has no readable text layer.")) }
        return pages.joined(separator: "\n\n")
    }
    func embeddedHighlights() async -> [Excerpt] {
        guard let document else { return [] }
        var result: [Excerpt] = []
        for index in 0..<document.pageCount {
            guard !Task.isCancelled else { return [] }
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                for (source, annotation) in PDFHighlightID.annotations(on: page, index: index) {
                    if let mark = Excerpt(annotation: annotation, source: source, page: page, canCopy: document.allowsCopying) {
                        result.append(mark)
                    }
                }
            }
            await Task.yield()
        }
        return result
    }

    func image(for request: PageThumbnailRequest, excerpts: [Excerpt], tags: [SemanticTag], deleted: Set<PDFHighlightID> = []) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = NSNumber(value: request.page)
        if let hit = cache.object(forKey: key), hit.request == request { return hit.image }
        guard let page = document?.safePage(request.page) else { return nil }
        let originalRotation = page.rotation
        if let angle = request.rotation, angle != originalRotation { page.rotation = angle }
        var hidden = Set(deleted.filter { $0.page == request.page })
        for entry in excerpts where entry.usesTagColor == true {
            if let source = entry.sourceHighlight, source.page == request.page { hidden.insert(source) }
        }
        let originals = hidden.isEmpty ? [] : PDFHighlightID.annotations(on: page, index: request.page).filter { hidden.contains($0.0) }
        // Temporarily change visibility, preserving annotation order (including identical overlapping marks).
        let flags = originals.map { ($0.1, $0.1.shouldPrint) }
        for (mark, _) in flags { mark.shouldDisplay = false; mark.shouldPrint = false }
        var marks: [PDFAnnotation] = []
        defer {
            for mark in marks { page.removeAnnotation(mark) }
            for (mark, printFlag) in flags { mark.shouldDisplay = true; mark.shouldPrint = printFlag }
            if page.rotation != originalRotation { page.rotation = originalRotation }
        }
        for entry in excerpts where entry.sourceHighlight == nil || entry.usesTagColor == true {
            guard let tag = entry.tag, let ink = tags.first(where: { $0.id == tag })?.ink else { continue }
            for line in entry.lines where line.page == request.page {
                let mark = ink.highlight(in: line.rect)
                page.addAnnotation(mark)
                marks.append(mark)
            }
        }
        guard !Task.isCancelled else { return nil }
        let thumb = page.thumbnail(of: CGSize(width: 186, height: 234), for: .cropBox)
        guard let image = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        cache.setObject(Entry(request, image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
