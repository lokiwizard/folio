import AppKit
import PDFKit

enum PageExport {
    static func indices(_ entry: String, count: Int) throws -> [Int] {
        let normalized = entry.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        var indices: [Int] = []
        var seen = Set<Int>()
        for part in normalized.components(separatedBy: ",") {
            let ends = part.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard ends.count <= 2, let first = Int(ends[0]), let last = Int(ends.last!),
                  first >= 1, last >= first, last <= count else {
                throw ReaderError(bilingual("请输入 1 到 \(count) 之间的页码，例如 1, 3–5。", "Enter pages from 1 to \(count), for example 1, 3–5."))
            }
            for page in first...last where seen.insert(page).inserted { indices.append(page - 1) }
        }
        return indices
    }

    static func write(source: URL, password: String?, selection: String, to destination: URL) throws {
        let sourceID = (try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        let destinationID = (try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        guard source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath(),
              sourceID?.isEqual(destinationID) != true else {
            throw ReaderError(bilingual("请选择新的文件名，以保留原 PDF。", "Choose a different filename to keep the original PDF."))
        }
        guard let original = PDFDocument(url: source), !original.isLocked || original.unlock(withPassword: password ?? ""),
              original.allowsCopying else { throw ReaderError(L("无法从这份 PDF 提取页面。")) }
        let pages = try indices(selection, count: original.pageCount)
        let files = FileManager.default
        // Stage on the destination volume. A validated PDF can be installed without reading its bytes back into the app.
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: staging) }
        let output = staging.appendingPathComponent("pages.pdf")
        var input = ["file": source.path, "range": pages.map { String($0 + 1) }.joined(separator: ",")]
        input["password"] = password
        let job: [String: Any] = ["empty": "", "pages": [input], "outputFile": output.path]
        let payload = try JSONSerialization.data(withJSONObject: job)
        let process = Process()
        var helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/qpdf")
        #if VERIFY
        if !files.isExecutableFile(atPath: helper.path) {
            helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("qpdf")
        }
        #endif
        process.executableURL = helper
        // Keep the document password off the command line and out of temporary files.
        process.arguments = ["--job-json-file=/dev/stdin"]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try pipe.fileHandleForWriting.write(contentsOf: payload)
            try pipe.fileHandleForWriting.close()
        } catch {
            try? pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        // qpdf can recover source defects (status 3), such as duplicate dictionary keys.
        guard process.terminationReason == .exit, [0, 3].contains(process.terminationStatus),
              let result = PDFDocument(url: output), result.pageCount == pages.count, !result.isLocked
        else { throw ReaderError(L("无法从这份 PDF 提取页面。")) }
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: output)
        } else {
            try files.moveItem(at: output, to: destination)
        }
    }
}

@MainActor
final class ExportPageRange: NSObject, NSOpenSavePanelDelegate {
    let field: NSTextField
    let pageCount: Int
    init(current: Int, count: Int) {
        field = NSTextField(string: String(current + 1))
        field.placeholderString = "1, 3–5, 8"
        field.setAccessibilityLabel(L("页码范围"))
        pageCount = count
    }
    func panel(_ sender: Any, validate url: URL) throws {
        _ = try PageExport.indices(field.stringValue, count: pageCount)
    }
}
