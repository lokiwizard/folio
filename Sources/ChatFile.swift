import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ChatFile {
    let text: String
    let images: [Data]
    var byteCount: Int { text.utf8.count + images.reduce(0) { $0 + $1.count } }

    enum Input {
        case file(URL)
        case data(Data, UTType, String)

        var name: String {
            switch self { case let .file(url): url.lastPathComponent; case let .data(_, _, name): name }
        }
    }

    static let contentTypes: [UTType] = [.image, .pdf, .plainText, .json, .commaSeparatedText, UTType(filenameExtension: "md") ?? .plainText]
    static let messageLimit = 12 * 1024 * 1024
    private static let fileLimit = 64 * 1024 * 1024
    static var tooLarge: ReaderError {
        ReaderError(bilingual("附件内容太大，请缩小图片或拆分文档。", "Attachments are too large. Resize the image or split the document."))
    }
    static func read(_ input: Input) throws -> ChatFile {
        switch input {
        case let .data(data, type, _): return try decode(data, type)
        case let .file(url):
            guard url.isFileURL else { throw ReaderError(L("无法打开文件。请检查文件位置和 PDF 格式。")) }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
            guard info.isRegularFile == true else { throw ReaderError(bilingual("请选择文件。", "Choose a file.")) }
            guard (info.fileSize ?? 0) <= fileLimit else { throw tooLarge }
            let type = info.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
            if ["md", "markdown"].contains(url.pathExtension.lowercased()) { return try decode(Data(contentsOf: url), .plainText) }
            guard contentTypes.contains(where: { type.conforms(to: $0) }) else { throw unsupported }
            return try decode(Data(contentsOf: url, options: .mappedIfSafe), type)
        }
    }
    private static var unsupported: ReaderError {
        ReaderError(bilingual("请选择图片、PDF 或文本文件。", "Choose an image, PDF, or text file."))
    }
    private static func decode(_ data: Data, _ type: UTType) throws -> ChatFile {
        guard data.count <= fileLimit else { throw tooLarge }
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(data: data), !document.isLocked, document.allowsCopying, document.pageCount > 0 else {
                throw ReaderError(bilingual("无法读取这份 PDF。请检查密码和内容复制权限。", "Cannot read this PDF. Check its password and copying permissions."))
            }
            var pages: [String] = [], images: [Data] = [], bytes = 0
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard let page = document.page(at: index) else { throw unsupported }
                    let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if text.isEmpty {
                        let anchor = Anchor(page: index, rect: page.bounds(for: .cropBox))
                        guard let image = ClipRenderer.image(anchor, in: document, maxEdge: 1800, scale: 2) else { throw unsupported }
                        let jpeg = try encode(image)
                        images.append(jpeg); bytes += jpeg.count
                    }
                    let section = text.isEmpty ? "\(pageName(index)) · \(bilingual("图片", "Image"))" : pageName(index) + "\n" + text
                    pages.append(section); bytes += section.utf8.count + 2
                    if bytes > messageLimit { throw tooLarge }
                }
            }
            return ChatFile(text: pages.joined(separator: "\n\n"), images: images)
        }
        if type.conforms(to: .image) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 2048,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw unsupported }
            return ChatFile(text: "", images: [try encode(image)])
        }
        guard type.conforms(to: .text) || type.conforms(to: .json) else { throw unsupported }
        guard data.count <= messageLimit else { throw tooLarge }
        let isUTF16 = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
        guard let text = String(data: data, encoding: isUTF16 ? .utf16 : .utf8), !text.isEmpty else {
            throw ReaderError(bilingual("文件没有可读取的文本。", "The file contains no readable text."))
        }
        return ChatFile(text: text, images: [])
    }
    private static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw unsupported }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.82,
                                                   kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1)] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw unsupported }
        return data as Data
    }

    // A copied Finder item may also offer a thumbnail and a string path. Prefer the actual file.
    static func inputs(on board: NSPasteboard) -> [Input] {
        (board.pasteboardItems ?? []).compactMap { item in
            if let path = item.string(forType: .fileURL), let url = URL(string: path), url.isFileURL { return .file(url) }
            for raw in item.types {
                guard let type = UTType(raw.rawValue), type.conforms(to: .pdf) || type.conforms(to: .image),
                      let data = item.data(forType: raw) else { continue }
                let name = type.conforms(to: .pdf) ? bilingual("粘贴的 PDF", "Pasted PDF") : bilingual("粘贴的图片", "Pasted image")
                return .data(data, type, name)
            }
            return nil
        }
    }
}
