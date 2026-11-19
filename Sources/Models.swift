import AppKit
import CryptoKit
import PDFKit

enum Ink: String, Codable, CaseIterable, Identifiable {
    case rose, sage, gold, blue, violet
    var id: Self { self }
    var title: String { switch self { case .rose: L("红色"); case .sage: L("绿色"); case .gold: L("黄色"); case .blue: L("蓝色"); case .violet: L("紫色") } }
    func highlight(in rect: CGRect) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        annotation.color = color.withAlphaComponent(0.48)
        return annotation
    }
    var color: NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch self {
        case .rose: rgb = (0.91, 0.48, 0.44)
        case .sage: rgb = (0.44, 0.70, 0.49)
        case .gold: rgb = (0.91, 0.72, 0.29)
        case .blue: rgb = (0.39, 0.64, 0.84)
        case .violet: rgb = (0.68, 0.54, 0.82)
        }
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}

struct SemanticTag: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var ink: Ink
    var preset: String?
    var overridesSourceColor: Bool?
    var displayName: String { preset == name ? L(name) : name }
    static let general = Self(id: UUID(uuidString: "5B63AB57-722D-43A0-96F1-580DC2802AF4")!, name: "默认", ink: .gold, preset: "默认")
    static let initial = [Self(name: "局限", ink: .rose, preset: "局限"), Self(name: "疑问", ink: .blue, preset: "疑问"),
                          Self(name: "核心创新", ink: .sage, preset: "核心创新"), Self(name: "写作参考", ink: .violet, preset: "写作参考"), general]
}

struct Anchor: Codable, Equatable {
    var page: Int
    var rect: CGRect
}

struct Bookmark: Codable, Identifiable {
    var id = UUID()
    var name: String
    var page: Int
    var point: CGPoint?
    var automatic: Bool?
    var displayName: String { automatic == true ? pageName(page) : name }
}

struct Excerpt: Codable, Identifiable {
    var id = UUID()
    var tag: UUID?
    var text: String
    var note = ""
    var noteEditedAt: Date?
    var lines: [Anchor]
    var collapsed: Bool?
    var cardScale: Double?
    var customTitle: String?
    var sourceHighlight: PDFHighlightID?
    var usesTagColor: Bool?

    func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || text.localizedStandardContains(term) || note.localizedStandardContains(term)
            || customTitle?.localizedStandardContains(term) == true
    }
}

struct PinColor: Codable, Equatable {
    let red, green, blue: UInt8

    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        red = byte(rgb.redComponent); green = byte(rgb.greenComponent); blue = byte(rgb.blueComponent)
    }
    var color: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}

struct Pin: Codable, Identifiable {
    var id = UUID()
    var source: Anchor
    var collapsed = false
    var cardScale: Double?
    var customTitle: String?
    var color: PinColor?
    var note: String?
    var noteEditedAt: Date?
    var drawing: [PinStroke]?
    var drawingRevision: UUID?
}

enum Zoom: String, Codable { case width, page, fixed }

struct PaperState: Codable {
    var page = 0
    var point: CGPoint?
    var zoom: Zoom = .width
    var scale: CGFloat = 1
    var continuous = true
    var rotations: [Int: Int] = [:]
    var bookmarks: [Bookmark] = []
    var excerpts: [Excerpt] = []
    var deletedHighlights: Set<PDFHighlightID>?
    var pins: [Pin] = []
}

struct Recent: Codable, Identifiable {
    var id: String
    var path: String
    var date: Date
    var pages: Int
    var title: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}

struct PaperPrompt: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var text: String
    var english: String?

    var displayText: String {
        get { bilingual(text, english ?? text) }
        set {
            guard newValue != displayText else { return }
            text = newValue
            english = nil
        }
    }
    static let defaults = [
        Self(id: "problem", text: "这篇论文解决了什么问题？", english: "What problem does this paper address?"),
        Self(id: "evidence", text: "主要结论有哪些实验证据？", english: "What evidence supports the main findings?"),
        Self(id: "method", text: "从输入到输出，这个方法分哪几步？", english: "How does the method go from input to output?"),
        Self(id: "comparison", text: "和已有方法相比，关键改进在哪里？", english: "How does this method improve on prior work?"),
        Self(id: "limitations", text: "作者提到了哪些局限或失败案例？", english: "What limitations or failure cases do the authors report?")
    ]
}

struct Preferences: Codable {
    static let memoFontSizes = 10...32
    static let defaultMemoFontSize = 14
    var language: InterfaceLanguage?
    var appearance: InterfaceAppearance?
    var glassStrength: Double?
    var memoFontSize: Int?
    var paperPrompts: [PaperPrompt]?
    var tags = SemanticTag.initial
    var defaultTagID: UUID?
    var recents: [Recent] = []
    var profiles: [Profile] = []
    var active: UUID?

    mutating func migratePresetColors() -> Bool {
        var changed = false
        for i in tags.indices where tags[i].overridesSourceColor != true {
            switch (tags[i].preset, tags[i].ink) {
            case ("疑问", .rose): tags[i].ink = .blue
            case ("写作参考", .gold): tags[i].ink = .violet
            default: continue
            }
            changed = true
        }
        return changed
    }
}

struct ReaderError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Resolve only when a worker first opens the PDF, including after a Finder rename.
struct PaperFile {
    let original: URL
    private let bookmark: Data?
    init(_ original: URL) {
        self.original = original
        bookmark = try? original.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    var currentURL: URL {
        guard let bookmark else { return original }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                         relativeTo: nil, bookmarkDataIsStale: &stale)) ?? original
    }
}

struct LocalStore {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("页间", isDirectory: true)
    }
    static func identity(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let identity: String
        if let inode = attrs?[.systemFileNumber], let device = attrs?[.systemNumber], let date = attrs?[.creationDate] as? Date {
            identity = "\(device)/\(inode)/\(date.timeIntervalSince1970)"
        } else { identity = path }
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func read<T: Decodable>(_ name: String, fallback: T) throws -> T {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
    func write<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
    }
}

extension PDFDocument {
    func safePage(_ index: Int) -> PDFPage? {
        (0..<pageCount).contains(index) ? page(at: index) : nil
    }
}

enum ClipRenderer {
    static func image(_ source: Anchor, in document: PDFDocument, maxEdge: CGFloat, scale: CGFloat, drawing: [PinStroke] = [], rotation: Int? = nil) -> CGImage? {
        guard let page = document.safePage(source.page), let pdf = page.pageRef else { return nil }
        return image(source.rect, page: pdf, rotation: rotation ?? page.rotation, maxEdge: maxEdge, scale: scale, drawing: drawing)
    }
    static func image(_ selection: CGRect, page pdf: CGPDFPage, rotation: Int, maxEdge: CGFloat, scale: CGFloat, drawing: [PinStroke] = []) -> CGImage? {
        let box = pdf.getBoxRect(.cropBox)
        let rect = selection.intersection(box)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        let swapped = rotation % 180 != 0
        let size = swapped ? CGSize(width: box.height, height: box.width) : box.size
        let transform = pdf.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                rotate: Int32(rotation) - pdf.rotationAngle, preserveAspectRatio: true)
        let crop = rect.applying(transform)
        let factor = min(scale, maxEdge / max(crop.width, crop.height))
        let w = max(1, Int(ceil(crop.width * factor))), h = max(1, Int(ceil(crop.height * factor)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.scaleBy(x: factor, y: factor)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.concatenate(transform)
        ctx.drawPDFPage(pdf)
        ctx.restoreGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        for stroke in drawing { stroke.draw(in: ctx, size: CGSize(width: w, height: h), rotation: rotation) }
        return ctx.makeImage()
    }
}

enum NotebookExport {
    private static func label(_ text: String) -> String {
        var escaped = ""
        for character in text.components(separatedBy: .newlines).joined(separator: " ") {
            if #"\`*_[]<>~&$#"#.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
    static func write(to url: URL, title: String, document: PDFDocument, state: PaperState, tags: [SemanticTag]) throws {
        let summary = bilingual("\(document.pageCount) 页 · \(state.excerpts.count) 条批注 · \(state.pins.count) 张便签",
                                "Pages · \(document.pageCount)   |   Annotations · \(state.excerpts.count)   |   Clips · \(state.pins.count)")
        var lines = ["# " + label(title), "", summary, ""]
        let groups = Dictionary(grouping: state.excerpts, by: \.tag)
        let sections = tags.map { (Optional($0.id), $0.displayName) } + [(nil, bilingual("未分类", "Uncategorized"))]
        if !groups.isEmpty { lines += ["## " + L("批注"), ""] }
        for (id, name) in sections {
            guard let entries = groups[id] else { continue }
            lines += ["### " + label(name), ""]
            for entry in entries {
                let pages = Set(entry.lines.map(\.page)).sorted().map(pageName).joined(separator: bilingual("、", ", "))
                let title = entry.customTitle.map { "**" + label($0) + "** · " } ?? ""
                lines += [title + "*" + pages + "*", ""]
                let source = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !source.isEmpty {
                    lines += source.components(separatedBy: .newlines).map { "> " + $0 }
                    lines.append("")
                }
                if !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines += [entry.note, ""] }
            }
        }
        let folder = url.deletingLastPathComponent()
        // Publish images first in a new directory so replacing a note never breaks its earlier attachments.
        let assetName = "figures-" + UUID().uuidString.lowercased()
        let assets = folder.appendingPathComponent(assetName)
        var madeAssets = false
        do {
            if !state.pins.isEmpty {
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
                madeAssets = true
                lines += [bilingual("## 图表便签", "## Pinned clips"), ""]
                for (i, pin) in state.pins.enumerated() {
                    let file = String(format: "clip-%03d.png", i + 1)
                    try autoreleasepool {
                        guard let cg = ClipRenderer.image(pin.source, in: document, maxEdge: 4096, scale: 3,
                                                          drawing: pin.drawing ?? [], rotation: state.rotations[pin.source.page]),
                              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                        else { throw ReaderError(bilingual("第 \(pin.source.page + 1) 页的便签图片生成失败。", "Could not render the clip on page \(pin.source.page + 1).")) }
                        try png.write(to: assets.appendingPathComponent(file))
                    }
                    let caption = label(pin.customTitle ?? bilingual("便签 \(i + 1)", "Clip \(i + 1)"))
                    lines += ["### " + caption, "", "*" + pageName(pin.source.page) + "*", "",
                              "![\(caption)](\(assetName)/\(file))", ""]
                    if let note = pin.note, !note.isEmpty { lines += [note, ""] }
                }
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            if madeAssets { try? FileManager.default.removeItem(at: assets) }
            throw error
        }
    }
}
