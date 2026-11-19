import SwiftUI
import PDFKit
import WebKit
import ScreenCaptureKit
import Darwin

// No credentials or paper text leave the test process.
private final class ChatFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let listing = url.lastPathComponent == "models"
        let mime = listing ? "application/json" : "text/event-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if listing {
            let page = url.query == nil ? #"{"data":[{"id":"model-b"}],"has_more":true,"last_id":"model-b"}"# : #"{"data":[{"id":"model-a"}],"has_more":false}"#
            client?.urlProtocol(self, didLoad: Data(page.utf8))
        } else {
            for payload in [#"{"type":"response.output_text.delta","delta":"逐步"}"#,
                            #"{"type":"response.output_text.delta","delta":"回答"}"#,
                            #"{"type":"response.completed"}"#] {
                client?.urlProtocol(self, didLoad: Data(("data: " + payload + "\n\n").utf8))
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// In-process Core Graphics wheel events have no AppKit window, even when the
// mouse-under-pointer fields are set. Bind gestures to the same window as their coordinates.
private class WindowGesture: NSEvent {
    var point = CGPoint.zero
    weak var target: NSWindow?
    override var locationInWindow: NSPoint { point }
    override var window: NSWindow? { target }
    override var windowNumber: Int { target?.windowNumber ?? 0 }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

private final class Pinch: WindowGesture {
    var amount: CGFloat = 0
    var samplePhase: NSEvent.Phase = .changed
    override var type: NSEvent.EventType { .magnify }
    override var magnification: CGFloat { amount }
    override var phase: NSEvent.Phase { samplePhase }
}

private final class LineWheel: WindowGesture {
    var lines: CGFloat = 0
    var keys: NSEvent.ModifierFlags = []
    override var type: NSEvent.EventType { .scrollWheel }
    override var modifierFlags: NSEvent.ModifierFlags { keys }
    override var scrollingDeltaY: CGFloat { lines }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var isDirectionInvertedFromDevice: Bool { false }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}

@main
@MainActor
enum Verify {
    static func check(_ test: @autoclosure () -> Bool, _ label: String, details: @autoclosure () -> String = "") throws {
        if !test() {
            try requireDesktop()
            let reason = details()
            throw ReaderError("FAIL " + label + (reason.isEmpty ? "" : " (" + reason + ")"))
        }
        print("PASS " + label)
    }
    static func pause(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            autoreleasepool {
                let slice = min(end, Date().addingTimeInterval(0.015))
                if let event = NSApp.nextEvent(matching: .any, until: slice, inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                NSApp.updateWindows()
            }
        }
    }
    static func paint(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }
    static func capture(_ window: NSWindow, _ url: URL, chrome: Bool = false) throws {
        paint(window)
        guard let view = chrome ? window.contentView?.superview : window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ReaderError("无法获取窗口图像") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
    static func hasReadableInk(_ pdf: PDFView) -> Bool {
        autoreleasepool { visibleInk(pdf) }
    }
    @available(macOS 14.4, *)
    static func testGlass() throws {
        func sample(_ strength: Double) -> some View {
            HStack(spacing: 0) {
                ForEach(0..<24) { i in Rectangle().fill(i.isMultiple(of: 2) ? Color.blue : Color.teal) }
            }.overlay { PaperGlass(strength: strength, corner: 12) }
        }
        let view = NSHostingView(rootView: sample(0))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 240, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.orderFrontRegardless()
        paint(window); pause(0.15)
        defer { window.orderOut(nil) }
        var result: Result<Void, Error>?
        Task {
            do {
                let windows = try? await SCShareableContent.currentProcess.windows
                let filter = windows?.first { $0.windowID == window.windowNumber }.map { SCContentFilter(desktopIndependentWindow: $0) }
                let config = SCStreamConfiguration()
                config.width = 240; config.height = 80; config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                var reds: [CGFloat] = []
                var liveCapture = filter != nil
                for level in [0.0, 0.5, 1.0] {
                    view.rootView = sample(level)
                    paint(window); pause(0.15)
                    let bitmap: NSBitmapImageRep
                    if liveCapture, let filter, let image = try? await captureSample(filter, config) {
                        bitmap = NSBitmapImageRep(cgImage: image)
                    } else {
                        // Headless/locked desktops can deny a compositor stream. Measure
                        // all three strengths using the same native view drawing path.
                        if liveCapture && !reds.isEmpty { throw ReaderError("材质采样期间系统截图服务中断") }
                        liveCapture = false
                        guard let drawn = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ReaderError("无法采样窗口材质") }
                        view.cacheDisplay(in: view.bounds, to: drawn)
                        bitmap = drawn
                    }
                    let row = (30..<210).compactMap { bitmap.colorAt(x: $0 * bitmap.pixelsWide / 240, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)?.redComponent }
                    guard row.count == 180 else { throw ReaderError("无法读取材质像素") }
                    reds.append(row.reduce(0, +) / CGFloat(row.count))
                }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                    try check(abs(reds[0] - reds[2]) < 0.02, "降低透明度时各档位均为实色")
                } else {
                    try check(reds[0] - reds[1] > 0.05 && reds[1] - reds[2] > 0.05,
                              (liveCapture ? "窗口合成画面" : "原生视图绘制") + "中 0%、50%、100% 三档逐步透出背景颜色")
                }
                result = .success(())
            } catch { result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { pause(0.02) }
        guard let result else { throw ReaderError("材质画面验证超时") }
        try result.get()
    }
    @available(macOS 14.4, *)
    static func captureSample(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws -> CGImage {
        // The compositor can temporarily reject a new stream while the previous sheet closes.
        for _ in 0..<2 {
            do { return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
            catch { try await Task.sleep(for: .milliseconds(180)) }
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
    static func visibleInk(_ pdf: PDFView) -> Bool {
        guard let page = pdf.currentPage else { return false }
        let pageFrame = pdf.convert(page.bounds(for: .cropBox), from: page).intersection(pdf.bounds)
        let area = pageFrame.insetBy(dx: 20, dy: 20)
        guard area.width > 0, area.height > 0, let bitmap = pdf.bitmapImageRepForCachingDisplay(in: area) else { return false }
        pdf.cacheDisplay(in: area, to: bitmap)
        var ink = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 12) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 12) {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   c.alphaComponent > 0.8 && max(c.redComponent, c.greenComponent, c.blueComponent) < 0.45 { ink += 1 }
                if ink > 30 { return true }
            }
        }
        return false
    }
    static func memory() -> (rss: UInt64, footprint: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? (info.resident_size, info.phys_footprint) : (0, 0)
    }
    static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    static func main() {
        setbuf(stdout, nil)
        do {
            try requireDesktop()
            try run()
            try requireDesktop()
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
            exit(1)
        }
    }
    static func requireDesktop() throws {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else {
            throw ReaderError("原生交互回归需要已解锁的 macOS 桌面。当前会话无法接收鼠标，本轮未通过。")
        }
    }
    static func testSavedKey(_ work: URL, reopening: Bool) throws {
        let store = CredentialStore(root: work.appendingPathComponent("test-secrets"))
        let marker = work.appendingPathComponent("test-profile")
        if reopening {
            let id = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: marker))
            let value = try store.get(id)
            try check(value == "fixture-replaced", "新进程无需交互即可读取原服务配置的密钥")
            try store.remove(id)
            try check(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("Credentials/" + id.uuidString).path), "删除密钥文件")
        } else {
            let id = UUID()
            try JSONEncoder().encode(id).write(to: marker)
            try store.set("fixture-original", for: id)
            let first = try store.get(id)
            let encrypted = try Data(contentsOf: store.root.appendingPathComponent("Credentials/" + id.uuidString))
            try check(first == "fixture-original" && encrypted.range(of: Data(first.utf8)) == nil, "设备加密密钥存储及读取")
            try store.set("fixture-replaced", for: id)
        }
    }
    static func testMath() throws {
        try check(!MathAnswer.containsMarkup("Cost is $20") && MathAnswer.containsMarkup("Energy $E=mc^2$"), "单个货币符号使用原生文字，完整公式启用数学排版")
        try check(MathAnswer.containsMarkup("\\### 网络输入与输出") && !MathAnswer.containsMarkup("正文里的 ### 符号"),
                  "仅行首的标题标记触发标题排版")
        let page = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Math/answer.html")
        var height: CGFloat = 0
        let view = NSHostingView(rootView: MathSurface(page: page, text: #"**行内 $x^2$**，**重点**，独立公式 \[\frac{a}{b}\]，代码 `$x$`，未完成 \(y"#,
                                                      dark: false, height: Binding(get: { height }, set: { height = $0 })))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(10)
        while height == 0 && Date() < deadline { pause(0.05) }
        func webView(_ node: NSView) -> WKWebView? {
            if let web = node as? WKWebView { return web }
            return node.subviews.compactMap(webView).first
        }
        guard let web = webView(view) else { throw ReaderError("未创建公式视图") }
        var valid: Bool?
        web.evaluateJavaScript("document.querySelectorAll('math').length === 2 && !!document.querySelector('strong msup') && document.querySelectorAll('strong').length === 2 && !!document.querySelector('.display mfrac') && document.querySelector('code').textContent.includes('$x$') && answer.textContent.endsWith('y')") { response, _ in valid = response as? Bool }
        while valid == nil && Date() < deadline { pause(0.05) }
        try check(height > 20 && valid == true, "离线 WebKit 排版行内上标和独立分式，保留代码和流式未闭合片段")
        view.rootView = MathSurface(page: page, text: #"补全 \(y^2\)，矩阵 $$\begin{pmatrix}1&0\\0&1\end{pmatrix}$$"#,
                                    dark: true, height: Binding(get: { height }, set: { height = $0 }))
        let updateDeadline = Date().addingTimeInterval(4)
        var updated = false
        while !updated && Date() < updateDeadline {
            pause(0.08)
            web.evaluateJavaScript("document.documentElement.style.colorScheme === 'dark' && document.querySelectorAll('math').length === 2 && !!document.querySelector('.display mtable')") { result, _ in updated = result as? Bool == true }
        }
        try check(updated, "同一回答更新时补全公式，深色模式下排版矩阵")
    }
    static func run() throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else { throw ReaderError("需要测试目录及两份 PDF") }
        let work = URL(fileURLWithPath: args[1])
        print("验证目录 " + work.path)
        let paper = URL(fileURLWithPath: args[2]), long = URL(fileURLWithPath: args[3])
        // Give each verification run a deterministic starting position.
        UserDefaults.standard.set(1.0, forKey: "chatPositionX")
        UserDefaults.standard.set(1.0, forKey: "chatPositionY")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var sent: [[ChatLine]] = []
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let r = Reader(store: LocalStore(root: work.appendingPathComponent("state")), imagePasteboard: clipboard) { _, messages in
            sent.append(messages)
            return "Fixture answer"
        }
        let delegate = Application(reader: r)
        app.finishLaunching()
        delegate.setupWindow()
        let window = delegate.window!
        window.setContentSize(NSSize(width: 1140, height: 740))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let focusDeadline = Date().addingTimeInterval(2)
        while !window.isKeyWindow && Date() < focusDeadline { pause(0.03) }
        try check(window.isKeyWindow, "阅读器测试窗口获得前台输入焦点")
        if args.last == "--highlights" {
            try testEmbeddedHighlights(r, window, work)
            if paper.standardizedFileURL != URL(fileURLWithPath: "Tests/Fixtures/embedded-highlights.pdf").standardizedFileURL {
                try testSourceHighlight(r, window, paper)
            }
            return
        }
        if args.last == "--benchmark" {
            try testSavedKey(work, reopening: true)
            try benchmark(r, window, paper, long)
            return
        }
        r.open(paper)
        pause(0.02); paint(window)
        guard let first = r.pdf, let firstPage = r.document?.page(at: 0) else { throw ReaderError("载入论文失败") }
        let readyDeadline = Date().addingTimeInterval(6)
        while (first.window == nil || first.visiblePages.isEmpty || !hasReadableInk(first)) && Date() < readyDeadline { pause(0.02); paint(window) }
        try check(first.window != nil && hasReadableInk(first), "第一页已绘出正文")
        paint(window)
        let start = Double(ProcessInfo.processInfo.environment["FOLIO_PROCESS_START"] ?? "") ?? ProcessInfo.processInfo.systemUptime
        print(String(format: "METRIC 新进程至第一页出现可读像素 %.3f s", ProcessInfo.processInfo.systemUptime - start))
        try check(firstPage.numberOfCharacters > 0 && r.document!.pageCount > 2, "真实论文文本层与页面")
        try testTextCursor(r, window)
        try testReadingEdges(r, window)
        try testPaperPrompts(r, window)
        try testInlinePlacement()
        try testChatWheel(r, window)
        try testTimeline(r, window, work)
        try testPreferences(r, window, work)
        try testSavedKey(work, reopening: false)
        try testPresetColors(r.prefs.tags, work)
        try capture(window, work.appendingPathComponent("reader.png"))
        try testWheelZoom(r, window)
        delegate.languageChanged()
        let goTo = app.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.first { $0.keyEquivalent == "l" }
        guard let action = goTo?.action else { throw ReaderError("缺少跳转页码快捷键") }
        app.sendAction(action, to: delegate, from: goTo); pause(0.16)
        guard let pageEditor = window.firstResponder as? NSTextView else { throw ReaderError("⌘L 未聚焦页码框") }
        try check(pageEditor.selectedRange().length == pageEditor.string.utf16.count && !pageEditor.string.isEmpty, "⌘L 选中当前页码")
        pageEditor.insertText("3", replacementRange: pageEditor.selectedRange())
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(enter); pause(0.2)
        try check(r.pageIndex == 2, "回车跳到输入页码")
        let jumpClip = first.documentView!.enclosingScrollView!.contentView
        let landed = jumpClip.bounds.origin
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
        window.sendEvent(down); pause(0.2)
        try check(jumpClip.bounds.origin != landed, "回车跳页后可立即用方向键继续阅读")
        r.go(0); pause(0.1)
        try testNavigation(r, window, work)
        // A fixed character range can span a vertical arXiv stamp and an entire title page.
        let titlePageText = firstPage.selection(for: firstPage.bounds(for: first.displayBox))
        guard let selection = titlePageText?.selectionsByLine().first(where: {
            let line = $0.bounds(for: firstPage)
            return line.width > line.height * 3 && ($0.string?.count ?? 0) >= 12
        }) else { throw ReaderError("未找到用于选区交互的正文行") }
        first.go(to: selection.bounds(for: firstPage), on: firstPage)
        first.setCurrentSelection(selection, animate: false)
        let selectionDeadline = Date().addingTimeInterval(2)
        while r.selectionFrame == nil && Date() < selectionDeadline { pause(0.025); paint(window) }
        try check(r.hasText && r.selectedCitation() != nil, "正文文字选区")
        try check(r.selectionFrame != nil, "选区工具栏定位到真实页面")
        try capture(window, work.appendingPathComponent("selection-zh.png"), chrome: true)
        try check(window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "more" } == true, "原生阅读工具栏已挂载")
        let viewSize = first.bounds.size
        for anchor in [CGRect(x: 0, y: 1, width: 20, height: 12),
                       CGRect(x: viewSize.width - 15, y: viewSize.height - 22, width: 12, height: 18)] {
            let bar = CGSize(width: 280, height: 32)
            let point = SelectionLayout.center(anchor: anchor, viewport: viewSize, bar: bar)
            let result = CGRect(x: point.x - 140, y: point.y - 16, width: 280, height: 32)
            try check(CGRect(origin: .zero, size: viewSize).contains(result) && !result.intersects(anchor), "工具栏避让视口边缘")
        }
        let tag = r.prefs.tags[1]
        r.highlight(tag)
        try check(r.state.excerpts.count == 1 && r.state.excerpts[0].tag == tag.id && r.state.excerpts[0].lines.count >= 1, "高亮关联所选语义标签")
        try check(firstPage.annotations.contains { $0.type == "Highlight" && PinColor($0.color) == PinColor(Ink.blue.color) }, "疑问标签在正文中显示为蓝色")
        r.setNote(r.state.excerpts[0].id, text: "回顾实验设置")
        // The drawing gestures below need a figure-sized clip. A PDF's first text
        // line may be a narrow vertical arXiv stamp.
        let pageBounds = firstPage.bounds(for: first.displayBox)
        let width = min(pageBounds.width * 0.6, pageBounds.height)
        let rect = Anchor(page: 0, rect: CGRect(x: pageBounds.midX - width / 2, y: pageBounds.midY - width / 4,
                                               width: width, height: width / 2))
        first.go(to: rect.rect, on: firstPage)
        pause(0.1)
        r.setRegionMode(true)
        // Route real drag coordinates through the event handlers, including PDFKit page transforms.
        let display = first.convert(rect.rect.insetBy(dx: -2, dy: -2), from: firstPage)
        let from = first.convert(NSPoint(x: display.minX, y: display.minY), to: nil)
        let to = first.convert(NSPoint(x: display.maxX, y: display.maxY), to: nil)
        func event(_ kind: NSEvent.EventType, _ at: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: at, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        first.mouseDown(with: event(.leftMouseDown, from))
        first.mouseDragged(with: event(.leftMouseDragged, to))
        first.mouseUp(with: event(.leftMouseUp, to))
        try check(r.region?.page == 0 && r.region!.rect.intersects(rect.rect), "框选坐标转换")
        r.pin()
        try check(r.state.pins.count == 1 && preview(r.pinPreviews, r.state.pins[0]) != nil, "固定图片便签与预览")
        let note = work.appendingPathComponent("notes.md")
        try NotebookExport.write(to: note, title: r.title, document: r.document!, state: r.state, tags: r.prefs.tags)
        let md = try String(contentsOf: note, encoding: .utf8)
        try check(md.contains("### 疑问") && md.contains("> ") && !md.contains("（无）") && md.contains("回顾实验设置") && md.contains("clip-001.png"), "Markdown 摘录、备注和相对图片")
        let dirs = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
        let dir = dirs.first { $0.lastPathComponent.hasPrefix("figures-") }!
        try check(NSImage(contentsOf: dir.appendingPathComponent("clip-001.png")) != nil, "导出 PNG 可解码")
        first.setCurrentSelection(selection, animate: false)
        guard let noteSource = r.selectedCitation() else { throw ReaderError("缺少测试选区") }
        // Simulate an untagged note written by an older build.
        r.state.excerpts.append(Excerpt(text: noteSource.text, note: "Standalone note", lines: noteSource.anchors))
        let firstNote = r.cardReference(r.state.excerpts[0].id, in: .notes)
        let newNote = r.cardReference(r.state.excerpts[1].id, in: .notes)
        try check(r.moveCard(newNote, relativeTo: firstNote, after: false) && r.state.excerpts[0].id == newNote.id, "批注卡片前移")
        try check(r.moveCard(newNote, relativeTo: firstNote, after: true) && r.state.excerpts[1].id == newNote.id, "批注卡片后移")
        r.state.excerpts[1].cardScale = 1.5; r.state.excerpts[1].collapsed = true
        r.state.pins.append(Pin(source: rect))
        let pinRef = r.cardReference(r.state.pins[0].id, in: .pins)
        let otherPin = r.cardReference(r.state.pins[1].id, in: .pins)
        try check(r.moveCard(otherPin, relativeTo: pinRef, after: false) && r.state.pins[0].id == otherPin.id, "图片卡片排序")
        var foreign = otherPin; foreign.document = "another-document"
        try check(!r.moveCard(foreign, relativeTo: pinRef, after: false) && !r.moveCard(newNote, relativeTo: pinRef, after: true), "跨论文及跨列表拖放保护")
        r.state.pins[0].cardScale = 1.25
        try testCardDrag(r, window, work, clipboard)
        let custom = PinColor(NSColor(srgbRed: 0.12, green: 0.47, blue: 0.61, alpha: 1))!
        r.setPinColor(custom, for: otherPin)
        try check(r.state.pins[0].color == custom && r.state.pins[1].color == nil, "独立设置便签的自选颜色")
        r.setPinColor(nil, for: otherPin)
        try check(r.state.pins[0].color == nil, "恢复默认便签颜色")
        r.setPinColor(custom, for: otherPin)
        r.renameCard(otherPin, to: "系统框图")
        r.renameCard(otherPin, to: "   ")
        try check(r.state.pins[0].customTitle == nil, "清空卡片名称恢复默认")
        r.renameCard(otherPin, to: "系统框图")
        r.renameCard(newNote, to: "伪代码")
        r.setPinNote(otherPin.id, text: "核对图中的反馈路径")
        let standalone = work.appendingPathComponent("personal.md")
        try NotebookExport.write(to: standalone, title: r.title, document: r.document!, state: r.state, tags: r.prefs.tags)
        let exported = try String(contentsOf: standalone, encoding: .utf8)
        try check(exported.contains("### 系统框图\n\n*第 1 页*") && exported.contains("**伪代码** · *第 1 页*") && exported.contains("核对图中的反馈路径"), "导出卡片名称和原文页码")
        try check(exported.contains("### 未分类") && exported.contains("Standalone note"), "独立笔记可导出")
        r.setAppearance(.light); r.setGlassStrength(0)
        let oldPanel = r.panel, wasOpen = r.composerOpen
        r.showLeft = true; r.panel = .notes; r.composerOpen = true
        let demoProfile = Profile(.openAI)
        r.prefs.profiles = [demoProfile]; r.prefs.active = demoProfile.id
        r.pdf?.clearSelection()
        r.question = "请解释这篇论文的主要方法。"
        r.sending = true; r.partialAnswer = ""
        pause(0.2); paint(window)
        try capture(window, work.appendingPathComponent("reading-sidebars.png"), chrome: true)
        try check(window.titleVisibility == .hidden && r.pdf!.convert(r.pdf!.bounds, to: nil).minX >= 230,
                  "展开导航后加宽左栏，论文标题由正文栏承载")
        r.stopAnswer(); r.question = ""; r.prefs.profiles = []; r.prefs.active = nil
        r.showLeft = false; r.panel = oldPanel; r.composerOpen = wasOpen
        pause(0.12); try capture(window, work.appendingPathComponent("light-zh.png"))
        r.setAppearance(.dark); r.setGlassStrength(0.85)
        pause(0.12)
        try check(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, "主窗口即时深色外观")
        try capture(window, work.appendingPathComponent("dark-zh.png"))
        r.switchLanguage(.english); pause(0.12)
        try capture(window, work.appendingPathComponent("dark-en.png"))
        r.settings = true; pause(0.35)
        if let sheet = window.attachedSheet { try capture(sheet, work.appendingPathComponent("appearance-en.png")) }
        r.settings = false; pause(0.25)
        r.setAppearance(.light); pause(0.1)
        try capture(window, work.appendingPathComponent("light-en.png"))
        r.showLeft = true; r.panel = .chat
        first.setCurrentSelection(selection, animate: false); r.askSelection()
        window.setContentSize(NSSize(width: 870, height: 565)); pause(0.15)
        try capture(window, work.appendingPathComponent("narrow-chat-en.png"), chrome: true)
        try testSelectionPrompts(r, window)
        try check(first.frame.width >= 409, "窄窗口保留阅读宽度")
        r.showLeft = false; r.resetChat(); r.panel = .notes
        window.setContentSize(NSSize(width: 1140, height: 740)); pause(0.15)
        r.setAppearance(.system)
        try check(NSApp.appearance == nil, "切回系统外观")
        let legacy = try JSONDecoder().decode(PaperState.self, from: JSONEncoder().encode(PaperState()))
        let oldPin = try JSONDecoder().decode(Pin.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","source":{"page":0,"rect":[[1,2],[3,4]]},"collapsed":false}"#.utf8))
        try check(oldPin.cardScale == nil && oldPin.color == nil && oldPin.customTitle == nil && legacy.excerpts.isEmpty, "旧便签兼容新增显示属性")
        let look = try r.store.read("library.json", fallback: Preferences())
        try check(look.appearance == .system && look.glassStrength == 0.85, "外观和材质强度持久化")
        r.switchLanguage(.chinese)
        r.showFind = true; r.query = "the"; r.startSearch()
        let timeout = Date().addingTimeInterval(20)
        while r.searching && Date() < timeout { pause(0.02) }
        try check(r.hits.count > 1 && !(r.pdf?.highlightedSelections?.isEmpty ?? true), "全文查找与当前视野命中高亮")
        r.stepHit(1); try check(r.hitIndex == 1, "下一处搜索")
        r.query = "the"; r.startSearch()
        r.query = "qzx-unmatched-314159"; r.startSearch()
        let replacementDeadline = Date().addingTimeInterval(10)
        while r.searching && Date() < replacementDeadline { pause(0.02) }
        try check(!r.searching && r.hits.isEmpty && (r.pdf?.highlightedSelections?.isEmpty ?? true), "快速更换查找词后丢弃旧命中和高亮")
        r.dismissFind()
        first.setCurrentSelection(selection, animate: false); r.askSelection()
        try check(r.citation?.pages == [0] && r.transcript.isEmpty && !r.includePage && !r.sending, "提问前选区范围与引用页码")
        pause(0.15)
        try testSelectionPrompts(r, window)
        try capture(window, work.appendingPathComponent("selection-prompts-zh.png"), chrome: true)
        let profile = Profile(.openAI)
        r.prefs.profiles = [profile]; r.prefs.active = profile.id
        r.question = "Q1"; r.send()
        let sentTurn = r.pendingTurn
        pause(0.05)
        try check(sentTurn != nil && r.pendingTurn == nil && r.chat.first?.id == sentTurn?.id &&
                  r.chat.first?.createdAt == sentTurn?.createdAt, "流式转为历史时保留同一时间线圆点和提问时间")
        try check(sent.count == 1 && sent[0].count == 1 && sent[0][0].text.contains(selection.string!) && !sent[0][0].text.contains(firstPage.string!) && r.chat.count == 2, "首次提问仅有问题、页码及原选区")
        let currentID = r.conversationID
        let nextSelection = firstPage.selection(for: NSRange(location: 130, length: 75))!
        first.setCurrentSelection(nextSelection, animate: false)
        r.question = "Q2"
        r.askSelection()
        try check(r.conversationID == currentID && r.transcript.count == 2 && r.question == "Q2" && r.citation?.text == nextSelection.string, "新选区沿用当前会话并保留草稿和完整原文")
        r.go(2); r.includePage = true; let pageText = r.contextPageText
        r.question = "Q2"; r.send(); pause(0.05)
        try check(sent.count == 2 && sent[1].count == 3 && sent[1][2].text.contains(pageText) && sent[1][2].text.contains(nextSelection.string!) && r.conversations.count == 1 && sent[1][1].text == "Fixture answer", "追问带上问答历史与显式附加页")
        let oldChat = r.conversations.first!
        r.resetChat(); r.question = "Full paper?"; r.send()
        let paperDeadline = Date().addingTimeInterval(10)
        while r.sending && Date() < paperDeadline { pause(0.02) }
        try check(sent.last?.first?.text.contains(pageName(r.document!.pageCount - 1)) == true && r.conversations.count == 2, "全文提问包含末页并保存独立会话")
        r.resetChat()
        let card = r.state.excerpts[0]
        r.attachCard(r.cardReference(card.id, in: .notes))
        let pin = r.state.pins[0]
        r.attachCard(r.cardReference(pin.id, in: .pins))
        r.question = "Card?"
        let preview = try awaitMessages(r)
        let privateNotes = [card.note, pin.note!]
        try check(privateNotes.allSatisfy { note in !note.isEmpty && !preview.contains(where: { $0.text.contains(note) }) },
                  "发送预览不包含批注和便签的个人备注")
        let old = ChatLine(role: "user", text: "Excerpt + private legacy comment", displayText: "What did the authors measure?")
        try check(old.forFollowUp.text == old.displayText, "旧对话追问不再转发混入备注的旧附件文本")
        let emptySource = CardAttachment(Excerpt(text: "", note: "private-only", lines: card.lines))
        try check(!emptySource.label.contains("private-only"), "无文字层的批注也不会在引用标签中显示备注")
        r.send()
        let attachmentDeadline = Date().addingTimeInterval(5)
        while r.sending && Date() < attachmentDeadline { pause(0.02) }
        try check(sent.last?.last?.images?.first.flatMap(NSImage.init(data:)) != nil, "图片便签以可解码的裁切图片附在请求中")
        try check(privateNotes.allSatisfy { note in sent.last?.contains(where: { $0.text.contains(note) }) == false } && sent.last?.first?.text.contains(card.text) == true && !r.wholePaper && r.conversations.count == 3, "便签和批注拖入后只发送引用内容，两种个人备注均被排除")
        let imageChat = r.conversations[0]
        r.openChat(imageChat)
        try check(r.chat.first?.id == r.transcript.first?.id && r.chat.first?.images == nil &&
                  r.transcript.first?.images?.isEmpty == false, "恢复含图片的聊天只给界面加载展示文字，追问仍保留原附件")
        r.openChat(oldChat)
        try check(r.chat.count == 4 && r.chat.first?.text == "Q1" && r.chat[0].selection?.text == selection.string && r.chat[2].selection?.text == nextSelection.string, "恢复会话显示原始问题")
        r.deleteExchange(r.chat[0].id)
        try check(r.chat.count == 2 && r.transcript.count == 2 && r.chat.first?.text == "Q2", "删除单轮问答同步更新模型历史")
        r.deleteChat(oldChat.id)
        try check(r.conversations.count == 2 && r.chat.isEmpty, "删除当前聊天记录")
        let lone = ChatLine(role: "user", text: "Unanswered"), next = ChatLine(role: "user", text: "Next")
        r.openChat(PaperChat(messages: [lone, next]))
        r.deleteExchange(lone.id)
        try check(r.chat.map(\.id) == [next.id], "删除旧记录中的无回答问题仅影响该轮")
        r.deleteExchange(next.id)
        try check(r.transcript.isEmpty && r.chat.isEmpty, "最后一条未回答的问题也可删除")
        r.resetChat()
        r.go(2); r.setZoom(.fixed, value: 1.2); r.addBookmark()
        r.state.bookmarks[0].name = "实验"
        r.state.pins[0].collapsed = true
        r.panel = .notes; r.showLeft = false
        pause(0.15)
        let location = r.pdf!.currentDestination!
        let savedPage = r.document!.index(for: location.page!)
        let savedPoint = location.point
        try check(r.close(), "关闭时保存")
        r.open(paper); pause(0.2); paint(window)
        try check(r.state.pins.first?.collapsed == true && r.state.excerpts[0].note == "回顾实验设置" && r.state.bookmarks.first?.name == "实验", "重新打开恢复便签、高亮和书签")
        try check(r.state.pins[0].id == otherPin.id && r.state.pins[0].cardScale == 1.25 &&
                  r.state.excerpts[1].cardScale == 1.5 && r.state.excerpts[1].collapsed == true, "重开恢复卡片顺序、缩放与折叠")
        try check(r.state.pins[0].color == custom && r.state.pins[1].color == nil, "重开恢复每张便签的颜色")
        try check(r.state.pins[0].customTitle == "系统框图" && r.state.excerpts[1].customTitle == "伪代码" && r.state.excerpts[1].tag == r.prefs.defaultTagID && r.state.pins[0].note == "核对图中的反馈路径", "重开论文恢复卡片名称")
        try check(abs(r.scale - 1.2) < 0.01 && r.document!.index(for: r.pdf!.currentDestination!.page!) == savedPage && abs(r.pdf!.currentDestination!.point.y - savedPoint.y) < 4, "恢复缩放、页码和页内阅读位置")
        let dest = PDFDestination(page: r.document!.page(at: 0)!, at: CGPoint(x: 0, y: 700))
        r.pdf!.perform(PDFActionGoTo(destination: dest)); pause(0.08)
        try check(r.pdf!.canGoBack, "PDF 内链与返回历史")
        r.pdf!.goBack(nil)
        r.rotate(); r.setContinuous(false); r.setZoom(.page); pause(0.1)
        try check(r.pdf?.displayMode == .singlePage && r.scale > 0, "旋转、单页与整页显示")
        let rotateDeadline = Date().addingTimeInterval(5)
        while !hasReadableInk(r.pdf!) && Date() < rotateDeadline { pause(0.04); paint(window) }
        try capture(window, work.appendingPathComponent("notes.png"))
        let current = r.pdf!, currentPage = current.currentPage!
        try check(currentPage.rotation == 90 && hasReadableInk(current), "旋转后正文可读")
        try testPageExport(paper, work)
        try testCrop(work)
        try testSwitchDuringRequest(paper, work: work)
        try protocols()
        try testAITransport()
        r.switchLanguage(.english)
        try check(L("最近打开") == "Recently opened" && r.prefs.tags[0].displayName == "Limitation" && pageName(0) == "Page 1", "英文控件、标签和页码")
        try check(SemanticTag(name: "自定义", ink: .sage).displayName == "自定义" && r.state.excerpts[0].note == "回顾实验设置", "保留用户输入的语言")
        let readBack = try r.store.read("library.json", fallback: Preferences())
        try check(readBack.language == .english && readBack.tags[0].id == r.prefs.tags[0].id, "语言偏好持久化且标签标识稳定")
        try testChatHeadings(r, window)
        _ = r.close()
        try capture(window, work.appendingPathComponent("library.png"))
        try testEmbeddedHighlights(r, window, work)
        try testMath()
        if #available(macOS 14.4, *) { try testGlass() }
        print("功能验证完成")
    }
    static func benchmark(_ r: Reader, _ window: NSWindow, _ paper: URL, _ long: URL) throws {
        // Run in its own process, without the screenshot buffers or the integration test's live selections.
        autoreleasepool { r.open(long); pause(0.3); paint(window) }
        guard let count = r.document?.pageCount else { throw ReaderError("长文档打开失败") }
        var quiet = 0
        let deadline = Date().addingTimeInterval(45)
        while quiet < 3 && Date() < deadline {
            let slice = cpuSeconds()
            autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
            quiet = cpuSeconds() - slice < 0.06 ? quiet + 1 : 0
        }
        let idleStart = cpuSeconds(); let before = ProcessInfo.processInfo.systemUptime
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        let idle = (cpuSeconds() - idleStart) / (ProcessInfo.processInfo.systemUptime - before) * 100
        var peak = memory()
        print(String(format: "METRIC 翻页前 RSS %.1f MiB，物理内存占用 %.1f MiB", Double(peak.rss)/1048576, Double(peak.footprint)/1048576))
        for i in 0..<count {
            autoreleasepool {
                r.go(i); paint(window); pause(0.06)
                let sample = memory()
                peak = (max(peak.rss, sample.rss), max(peak.footprint, sample.footprint))
            }
        }
        print(String(format: "METRIC 长文 %d 页，翻页 RSS 采样峰值 %.1f MiB，物理内存采样峰值 %.1f MiB，空闲 CPU（5 s）%.2f%%",
                     count, Double(peak.rss)/1048576, Double(peak.footprint)/1048576, idle))
        weak var longDocument: PDFDocument?
        autoreleasepool { longDocument = r.document; _ = r.close() }
        let until = Date().addingTimeInterval(75)
        while longDocument != nil && Date() < until {
            autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        }
        try check(longDocument == nil, "长文连续翻完后文档释放")
        for i in 0..<4 {
            weak var released: PDFDocument?
            weak var viewReleased: PaperView?
            autoreleasepool {
                r.open(i % 2 == 0 ? paper : long); pause(0.1); released = r.document; viewReleased = r.pdf
                _ = r.close()
            }
            let closedAt = ProcessInfo.processInfo.systemUptime
            let releaseDeadline = Date().addingTimeInterval(75)
            while (released != nil || viewReleased != nil) && Date() < releaseDeadline {
                autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
            }
            print(String(format: "METRIC 关闭 #%d，视图和文档释放等待 %.2f s", i + 1, ProcessInfo.processInfo.systemUptime - closedAt))
            try check(released == nil && viewReleased == nil, "关闭文档释放 #\(i + 1)")
        }
        let closed = memory()
        print(String(format: "METRIC 关闭后的 RSS %.1f MiB，物理内存占用 %.1f MiB", Double(closed.rss)/1048576, Double(closed.footprint)/1048576))
        print("性能验证完成")
    }
    static func awaitResult<T>(_ operation: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task {
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { pause(0.01) }
        guard let result else { throw ReaderError("等待后台任务超时") }
        return try result.get()
    }
    static func awaitMessages(_ reader: Reader) throws -> [ChatLine] {
        try awaitResult { try await reader.outgoingMessages() }
    }
    static func testPaperPrompts(_ r: Reader, _ window: NSWindow) throws {
        let previousPanel = r.panel, previousLanguage = r.language
        defer { r.resetChat(); r.composerOpen = false; r.panel = previousPanel; r.switchLanguage(previousLanguage) }
        r.panel = .chat
        let titles = [
            ("这篇论文解决了什么问题？", "What problem does this paper address?"),
            ("主要结论有哪些实验证据？", "What evidence supports the main findings?"),
            ("从输入到输出，这个方法分哪几步？", "How does the method go from input to output?"),
            ("和已有方法相比，关键改进在哪里？", "How does this method improve on prior work?"),
            ("作者提到了哪些局限或失败案例？", "What limitations or failure cases do the authors report?")
        ]
        for language in [InterfaceLanguage.chinese, .english] {
            r.switchLanguage(language); pause(0.2); paint(window)
            guard let clip = (window as? ReaderWindow)?.transcriptMarker?.enclosingScrollView?.contentView else {
                throw ReaderError("未找到预置问题列表")
            }
            let expected = titles.map { language == .chinese ? $0.0 : $0.1 }
            var found: [String] = []
            let frame = clip.convert(clip.bounds, to: nil)
            for y in stride(from: frame.maxY - 14, to: frame.minY, by: -18) {
                r.wholePaper = false
                click(window, at: CGPoint(x: frame.midX, y: y))
                if r.wholePaper && found.last != r.question {
                    try check(r.composerOpen && r.chat.isEmpty && !r.sending, "点选后可编辑再发送：" + r.question)
                    found.append(r.question)
                }
                if found.count == expected.count { break }
            }
            try check(found == expected, "全文提问的五个预置问题均可点选（" + language.name + "）")
        }
        r.switchLanguage(.chinese); r.resetChat(); pause(0.15)
        try testPromptEditor(r, window)
    }
    static func testPromptEditor(_ r: Reader, _ window: NSWindow) throws {
        let original = r.prefs.paperPrompts
        defer { r.prefs.paperPrompts = original; r.persistPreferences() }
        guard let clip = (window as? ReaderWindow)?.transcriptMarker?.enclosingScrollView?.contentView else { throw ReaderError("缺少对话列表") }
        func open() throws -> NSWindow {
            let frame = clip.convert(clip.bounds, to: nil)
            click(window, at: CGPoint(x: frame.maxX - 74, y: frame.maxY + 25))
            guard let sheet = window.attachedSheet else { throw ReaderError("无法打开全文提示词编辑器") }
            return sheet
        }
        func enter(_ value: String, in sheet: NSWindow) throws {
            guard let editor = sheet.firstResponder as? NSTextView else { throw ReaderError("提示词输入框未获得焦点") }
            editor.selectAll(nil); editor.insertText(value, replacementRange: editor.selectedRange()); pause(0.06)
        }
        func save(_ sheet: NSWindow) { click(sheet, at: CGPoint(x: sheet.contentView!.bounds.width - 48, y: 30)) }
        let sheet = try open()
        let size = sheet.contentView!.bounds.size
        let custom = "按实验逐项列出对照组。\n保留原文中的 $x$ 和 **术语**。"
        click(sheet, at: CGPoint(x: 95, y: size.height - 80))
        try enter(custom, in: sheet)
        let extra = ["列出消融实验。", "比较计算开销。", "给出复现步骤。", "列出消融实验。"]
        for text in extra {
            click(sheet, at: CGPoint(x: 64, y: 30))
            try enter(text, in: sheet)
        }
        save(sheet)
        try check(window.attachedSheet == nil && r.paperPrompts.count == 9 && r.paperPrompts.first?.text == custom &&
                  r.paperPrompts.suffix(4).map(\.text) == extra, "编辑初始问题并新增至九条，支持多行和同名提示词")
        r.switchLanguage(.english); pause(0.15)
        try check(r.paperPrompts.first?.displayText == custom && r.paperPrompts[1].displayText == "What evidence supports the main findings?",
                  "用户填写的内容逐字保留，未编辑的问题随界面切换语言")
        let frame = clip.convert(clip.bounds, to: nil)
        click(window, at: CGPoint(x: frame.midX, y: frame.maxY - 22))
        try check(r.question == custom && r.wholePaper && r.chat.isEmpty && !r.sending, "点击自定义提示词填入完整草稿")
        let reopened = Reader(store: r.store)
        try check(reopened.paperPrompts == r.paperPrompts, "新的阅读器实例读回全部自定义提示词")
        r.switchLanguage(.chinese); pause(0.1)
        let deleting = try open()
        // Keep the click in the button whether the native scroll bar takes up space or not.
        for _ in r.paperPrompts { click(deleting, at: CGPoint(x: size.width - 50, y: size.height - 75)) }
        save(deleting)
        try check(window.attachedSheet == nil && Reader(store: r.store).paperPrompts.isEmpty, "所有初始和自定义提示词都可删除，重开仍为空")
        let cancel = try open()
        click(cancel, at: CGPoint(x: 162, y: 30))
        click(cancel, at: CGPoint(x: size.width - 110, y: 30))
        try check(window.attachedSheet == nil && r.paperPrompts.isEmpty, "取消恢复默认保留原先的空列表")
        let restoring = try open()
        click(restoring, at: CGPoint(x: 162, y: 30)); save(restoring)
        try check(r.paperPrompts == PaperPrompt.defaults, "从空列表恢复五个双语初始提示词")
    }
    static func testSelectionPrompts(_ r: Reader, _ window: NSWindow) throws {
        let conversation = r.conversationID
        let selection = r.citation?.id
        let count = r.chat.count
        guard let root = window.contentView else { throw ReaderError("未找到窗口") }
        func find(_ view: NSView, matching: (NSView) -> Bool) -> NSView? {
            if matching(view) { return view }
            for child in view.subviews {
                if let found = find(child, matching: matching) { return found }
            }
            return nil
        }
        guard let panel = find(root, matching: { $0.identifier?.rawValue == "chatDropTarget" }) else { throw ReaderError("未找到浮窗") }
        paint(window)
        let rect = panel.convert(panel.bounds, to: nil)
        try check(root.convert(root.bounds, to: nil).contains(rect), "选区浮窗完整显示")
        let presets = [("解释", "请解释这段文字。"), ("翻译", "请把这段文字翻译成中文。"), ("总结", "请用中文总结这段文字。")]
        for index in [1, 2, 0] {
            let (label, prompt) = presets[index]
            let columnWidth = (rect.width - 34) / 3
            let point = CGPoint(x: rect.minX + 17 + (CGFloat(index) + 0.5) * columnWidth, y: rect.minY + 100)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.postEvent(event, atStart: false)
            }
            pause(0.12)
            try check(r.question == L(prompt) && !r.sending && r.chat.count == count && r.citation?.id == selection && r.conversationID == conversation,
                      "点击 " + L(label) + " 在当前选区对话中填入可编辑问题")
        }
        guard let editor = window.firstResponder as? NSTextView else { throw ReaderError("快捷提问后输入框未获得焦点") }
        // A Mac text field may select the full prompt on focus. Dragging an existing
        // selection moves its text; this gesture starts from an insertion point.
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        paint(window)
        let beforeTextDrag = panel.convert(panel.bounds, to: nil)
        let start = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        let end = editor.firstRect(forCharacterRange: NSRange(location: 5, length: 1), actualRange: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let events: [(NSEvent.EventType, CGFloat)] = [(.leftMouseDown, start.midX), (.leftMouseDragged, (start.midX + end.midX) / 2),
                                                       (.leftMouseDragged, end.midX), (.leftMouseUp, end.midX)]
        for (i, sample) in events.enumerated() {
            let (type, x) = sample
            let point = window.convertPoint(fromScreen: CGPoint(x: x, y: start.midY))
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp + Double(i) * 0.025,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
        }
        pause(0.12)
        let afterTextDrag = panel.convert(panel.bounds, to: nil)
        if editor.selectedRange().length == 0 { print("提问框文字选择", editor.selectedRange(), start, end, beforeTextDrag, afterTextDrag) }
        try check(editor.selectedRange().length > 0 && abs(afterTextDrag.minX - beforeTextDrag.minX) < 1 && abs(afterTextDrag.minY - beforeTextDrag.minY) < 1, "在浮窗输入框中拖动选择文字")
    }
    static func testChatHeadings(_ r: Reader, _ window: NSWindow) throws {
        r.resetChat(); r.panel = .chat; r.showRight = true
        func answerView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { answerView(in: $0) }.first
        }
        func checkHeading(_ condition: String, _ label: String) throws {
            let deadline = Date().addingTimeInterval(8)
            var matched = false
            while !matched && Date() < deadline {
                pause(0.05); paint(window)
                if let transcript = (window as? ReaderWindow)?.transcriptMarker?.enclosingScrollView,
                   let web = answerView(in: transcript), web.bounds.height > 10 {
                    web.evaluateJavaScript(condition) { value, _ in
                        if value as? Bool == true { matched = true }
                    }
                }
            }
            try check(matched, label)
        }

        r.sending = true
        r.partialAnswer = "### 网络"
        try checkHeading("answer.querySelector('h3')?.textContent === '网络'", "流式标题在正文到达前即可排版")
        r.partialAnswer += "输入与输出\n输入 $x$，输出 **预测值**。"
        try checkHeading("answer.querySelector('h3')?.textContent === '网络输入与输出' && !!answer.querySelector('math') && answer.querySelector('strong')?.textContent === '预测值'",
                         "补全三级标题时保留公式、加粗和标题后的正文")

        let stored = "\\### **网络输入与输出**" + "\n```md\n### 原样显示\n```\n正文里的 ### 也保留"
        let session = PaperChat(messages: [ChatLine(role: "user", text: "结构"), ChatLine(role: "assistant", text: stored)])
        r.openChat(try JSONDecoder().decode(PaperChat.self, from: JSONEncoder().encode(session)))
        try checkHeading("""
            answer.querySelectorAll('h3').length === 1 && answer.querySelector('h3 > strong')?.textContent === '网络输入与输出'
                && answer.querySelector('code')?.textContent.includes('### 原样显示') && answer.textContent.endsWith('正文里的 ### 也保留')
            """, "重开历史时兼容转义标题，代码和行内井号保持原文")
    }
    static func testChatWheel(_ r: Reader, _ window: NSWindow) throws {
        let previous = r.panel
        r.panel = .chat; r.showRight = true
        r.question = "Scroll"
        r.sending = true
        defer { r.stopAnswer(); r.question = ""; r.panel = previous }
        r.partialAnswer = String(repeating: "**重点**与公式 $x_i$。\n", count: 100)
        let deadline = Date().addingTimeInterval(10)
        var viewport: NSScrollView?
        while Date() < deadline {
            pause(0.08); paint(window)
            viewport = (window as? ReaderWindow)?.transcriptMarker?.enclosingScrollView
            if let viewport, viewport.contentView.bounds.minY > 100 {
                // Wait for the actual WebKit typesetting pass, not the plain-text
                // placeholder that is displayed while the first page loads.
                func containsSizedAnswer(_ node: NSView) -> Bool {
                    if node is WKWebView, node.bounds.height > 100 { return true }
                    return node.subviews.contains(where: containsSizedAnswer)
                }
                if containsSizedAnswer(viewport) { break }
            }
        }
        guard let scroll = viewport else { throw ReaderError("未找到聊天滚动区域") }
        let clip = scroll.contentView
        pause(0.2); paint(window)
        let bottom = clip.bounds.minY
        guard bottom > 100 else { throw ReaderError("新回答未滚动到末尾") }
        let point = window.convertPoint(toScreen: clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil))
        func wheel(_ delta: Int32, target: CGPoint? = nil) throws {
            let point = target ?? point
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { throw ReaderError("无法创建聊天滚轮事件") }
            cg.location = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
            for field in [CGEventField.mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent] {
                cg.setIntegerValueField(field, value: Int64(window.windowNumber))
            }
            guard let event = NSEvent(cgEvent: cg) else { throw ReaderError("无法转换聊天滚轮事件") }
            window.sendEvent(event); pause(0.2); paint(window)
        }
        try wheel(8)
        let earlier = clip.bounds.minY
        try check(earlier < bottom - 5, "在公式与加粗回答上使用滚轮可回看前文")
        r.partialAnswer += String(repeating: "新段落。\n", count: 8); pause(0.3); paint(window)
        try check(abs(clip.bounds.minY - earlier) < 4, "流式输出保留手动滚动后的阅读位置")
        try wheel(-4)
        try check(clip.bounds.minY > earlier, "聊天侧栏滚轮可向下滚动")
        let paper = r.pdf!
        let pdfClip = paper.documentView!.enclosingScrollView!.contentView
        let beforePaper = pdfClip.bounds.origin, beforeChat = clip.bounds.origin
        let bodyPoint = paper.convert(CGPoint(x: paper.bounds.midX, y: paper.bounds.midY), to: nil)
        try wheel(-6, target: window.convertPoint(toScreen: bodyPoint))
        try check(pdfClip.bounds.origin != beforePaper && clip.bounds.origin == beforeChat, "打开流式问答时正文和聊天独立滚动")
    }
    static func click(_ window: NSWindow, at point: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
        }
        pause(0.2)
    }
    static func testReadingEdges(_ r: Reader, _ window: NSWindow) throws {
        let left = r.showLeft, right = r.showRight, originalFrame = window.frame
        let defaults = UserDefaults.standard
        let oldWidth = defaults.object(forKey: "inspectorWidth"), oldFraction = defaults.object(forKey: "twoPaneInspectorFraction")
        defer {
            defaults.set(oldWidth, forKey: "inspectorWidth")
            defaults.set(oldFraction, forKey: "twoPaneInspectorFraction")
            window.setFrame(originalFrame, display: true)
            r.showLeft = left; r.showRight = right; pause(0.15)
        }
        defaults.removeObject(forKey: "twoPaneInspectorFraction")
        r.showLeft = true; r.showRight = true; pause(0.18); paint(window)
        func handle(_ node: NSView, _ id: String) -> NSView? {
            if node.identifier?.rawValue == id { return node }
            return node.subviews.lazy.compactMap { handle($0, id) }.first
        }
        func center(_ grip: NSView) -> CGPoint { grip.convert(CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil) }
        func drag(_ grip: NSView, by dx: CGFloat) {
            let p = center(grip)
            for (type, shift) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseDragged, dx / 2), (.leftMouseDragged, dx), (.leftMouseUp, dx)] {
                let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x + shift, y: p.y), modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.postEvent(event, atStart: false); pause(0.03)
            }
            paint(window)
        }
        for id in ["navigation.splitter", "inspector.splitter"] {
            guard let grip = handle(window.contentView!, id) else { throw ReaderError("缺少侧栏分隔线") }
            let initial = window.frame, x = center(grip).x
            let dx: CGFloat = id == "navigation.splitter" ? 22 : -22
            drag(grip, by: dx)
            try check(abs(center(grip).x - x - dx) < 1.5 && window.frame == initial && !grip.mouseDownCanMoveWindow,
                      id + " 拖动时宽度跟随指针且主窗口不动")
            drag(grip, by: -dx)
            try check(abs(center(grip).x - x) < 1.5 && window.frame == initial, id + " 可反向拖回原宽度")
        }
        guard let paper = r.pdf else { throw ReaderError("缺少 PDF 视图") }
        let root = window.contentView!
        func inspectorGrip() throws -> NSView {
            guard let grip = handle(root, "inspector.splitter") else { throw ReaderError("右栏分隔线未显示") }
            return grip
        }
        func rightWidth() throws -> CGFloat {
            let grip = try inspectorGrip()
            return root.convert(root.bounds, to: nil).maxX - grip.convert(grip.bounds, to: nil).maxX
        }
        func layout() { pause(0.15); paint(window) }
        let threePaneWidth = try rightWidth()
        r.showLeft = false; layout()
        var inspector = try rightWidth()
        try check(abs(inspector - threePaneWidth) <= 1, "首次收起导航时沿用已保存的右栏宽度")
        try drag(inspectorGrip(), by: -420)
        for windowWidth in [1140, 870, 1370] {
            window.setContentSize(CGSize(width: windowWidth, height: 740)); layout()
            inspector = try rightWidth()
            try check(abs(paper.bounds.width - inspector) <= 1 && abs(paper.bounds.width * 2 + 8 - root.bounds.width) <= 1,
                      "窗口宽 \(windowWidth) 时，正文与右栏实际可用宽度相等")
        }
        r.showLeft = true; layout()
        inspector = try rightWidth()
        try check(abs(inspector - threePaneWidth) <= 1, "展开导航后恢复三栏布局的独立宽度")
        try drag(inspectorGrip(), by: -480)
        inspector = try rightWidth()
        try check(inspector > 490 && paper.bounds.width >= 410, "宽窗口中三栏布局也可扩大右栏，同时保留正文空间")
        r.showLeft = false; layout()
        inspector = try rightWidth()
        try check(abs(inspector - paper.bounds.width) <= 1, "再次收起导航恢复二栏等分")
        try drag(inspectorGrip(), by: 95)
        inspector = try rightWidth()
        let fraction = inspector / (inspector + paper.bounds.width)
        r.showRight = false; layout()
        window.setFrame(originalFrame, display: true); layout()
        r.showRight = true; layout()
        inspector = try rightWidth()
        try check(fraction < 0.49 && abs(inspector - fraction * (inspector + paper.bounds.width)) <= 1,
                  "拖回非等分比例后，改变窗口和开合右栏仍保留选择")
        try testMemoLayout(r, window) { width in
            try drag(inspectorGrip(), by: rightWidth() - width)
            layout()
        }
    }
    static func testTextCursor(_ r: Reader, _ window: NSWindow) throws {
        guard let paper = r.pdf, let page = r.document?.page(at: 0) else { throw ReaderError("缺少光标测试页") }
        let oldZoom = r.state.zoom
        defer { r.setRegionMode(false); r.setZoom(oldZoom) }
        r.setZoom(.width); r.go(0); pause(0.25); paint(window)
        let box = page.bounds(for: .cropBox)
        func event(_ type: NSEvent.EventType, _ pagePoint: CGPoint) -> NSEvent {
            let point = paper.convert(paper.convert(pagePoint, from: page), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        let run = (4..<max(4, page.numberOfCharacters - 8)).lazy.compactMap { i -> (CGPoint, CGPoint)? in
            let a = page.characterBounds(at: i), b = page.characterBounds(at: i + 8)
            guard !a.isEmpty, !b.isEmpty, abs(a.midY - b.midY) < 2, b.midX - a.midX > 24,
                  paper.visibleRect.contains(paper.convert(a.union(b), from: page)) else { return nil }
            return (CGPoint(x: a.midX, y: a.midY), CGPoint(x: b.midX, y: b.midY))
        }.first
        guard let (first, last) = run else { throw ReaderError("未找到连续可见的 PDF 文字") }
        let margin = CGPoint(x: box.minX + 2, y: first.y)
        window.sendEvent(event(.mouseMoved, first))
        try check(NSCursor.current == .iBeam, "指向 PDF 文字时显示工字形指针")
        var sawTextCursor = false
        // PDFKit can consume a full drag inside mouseDown in its own tracking loop.
        let observer = r.$hasText.sink { selected in
            if selected { sawTextCursor = NSCursor.current == .iBeam }
        }
        let midpoint = CGPoint(x: (first.x + last.x) / 2, y: first.y)
        // Put the matching drag and release first in PDFKit's native mouse-tracking loop.
        for (type, point) in [(NSEvent.EventType.leftMouseUp, last), (.leftMouseDragged, last), (.leftMouseDragged, midpoint)] {
            NSApp.postEvent(event(type, point), atStart: true)
        }
        window.sendEvent(event(.leftMouseDown, first))
        pause(0.18)
        observer.cancel()
        try check((paper.currentSelection?.string?.count ?? 0) >= 2, "按下后拖动能够选中 PDF 原文")
        try check(sawTextCursor, "拖选正文时保持工字形指针")
        try check(r.selectionFrame != nil && (window as? ReaderWindow)?.selectingTextIn == nil,
                  "原生拖选松手后立即恢复选区工具栏，无需再移动鼠标")
        paper.clearSelection()
        window.sendEvent(event(.mouseMoved, margin))
        try check(NSCursor.current == .arrow, "指针离开文字进入页边留白时恢复箭头")
        r.setRegionMode(true)
        window.sendEvent(event(.mouseMoved, first))
        try check(NSCursor.current == .crosshair, "框选 PDF 图片时使用十字光标")
        r.setRegionMode(false)
        window.sendEvent(event(.mouseMoved, first))
        try check(NSCursor.current == .iBeam, "退出框选后可再次用工字形指针选字")
        paper.setCursorFor([.pageArea, .annotationArea, .textFieldArea])
        try check(NSCursor.current == .iBeam, "PDF 表单的文本输入区使用工字形指针")
    }
    static func testMemoLayout(_ r: Reader, _ window: NSWindow, resize: (CGFloat) throws -> Void) throws {
        let original = r.state, panel = r.panel, storedSize = r.prefs.memoFontSize
        defer {
            r.state = original; r.panel = panel
            r.prefs.memoFontSize = storedSize; r.persistPreferences()
        }
        func card(_ id: UUID, in view: NSView) -> CardMarkerView? {
            if let marker = view as? CardMarkerView, marker.reference.id == id { return marker }
            return view.subviews.lazy.compactMap { card(id, in: $0) }.first
        }
        let anchor = Anchor(page: 0, rect: CGRect(x: 12, y: 12, width: 250, height: 10))
        let memos = ["字号 Aa", "字号 Aa\n字号 Aa\n字号 Aa"]
        for list in [Panel.pins, .notes] {
            r.panel = list
            r.state.pins = memos.map { Pin(source: anchor, cardScale: 0.8, note: $0) }
            r.state.excerpts = memos.map { Excerpt(text: "", note: $0, lines: [anchor], cardScale: 0.8) }
            let ids = list == .pins ? r.state.pins.map(\.id) : r.state.excerpts.map(\.id)
            func frame(_ index: Int) throws -> CGRect {
                guard let view = card(ids[index], in: window.contentView!) else { throw ReaderError("备注测试卡片未显示") }
                return view.cardFrame
            }
            // Identical card chrome and artwork cancel out, leaving only two extra text lines.
            func extraLines() throws -> CGFloat {
                pause(0.12); paint(window)
                return try frame(1).height - frame(0).height
            }
            r.setMemoFontSize(14)
            try resize(258)
            let narrow = try extraLines(), smallWidth = try frame(0).width
            try resize(520)
            let wide = try extraLines(), largeWidth = try frame(0).width
            try check(largeWidth - smallWidth > 200 && narrow > 20 && abs(wide - narrow) <= 1,
                      list.rawValue + "备注在真实分隔线拖宽后保持相同行高")
            for i in memos.indices {
                r.state.pins[i].cardScale = 2; r.state.excerpts[i].cardScale = 2
            }
            let scaled = try extraLines()
            try check(abs(scaled - narrow) <= 1, list.rawValue + "卡片从 80% 放大到 200% 时备注字号固定")
            r.setMemoFontSize(24)
            let larger = try extraLines()
            try check(larger > scaled + 15, list.rawValue + "已有备注随独立字号设置即时放大")
        }
        r.state.excerpts[0].note = String(repeating: "这段备注随侧栏宽度自动换行。", count: 5)
        pause(0.15)
        let noteID = r.state.excerpts[0].id
        guard let row = card(noteID, in: window.contentView!) else { throw ReaderError("缺少换行测试备注") }
        let wideHeight = row.cardFrame.height
        try resize(258)
        try check(row.cardFrame.height > wideHeight + 25 && r.memoFontSize == 24, "收窄右栏时长备注换行并撑高卡片")
    }
    static func testInlinePlacement() throws {
        let canvas = PinDrawingSurface(frame: CGRect(x: 0, y: 0, width: 600, height: 450))
        let image = CGRect(x: 22, y: 17, width: 460, height: 320)
        let ink = PinColor(NSColor.systemBlue)!
        let label = PinTextLabel(string: "图例", orientation: 0, boxWidth: 0.37, fontSize: 0.035, boxHeight: 0.19)
        let box = PinInlineTextBox(label: label, ink: ink.color)
        canvas.addSubview(box)
        for rotation in [0, 90, 180, 270] {
            let layout = PinTextLayout(label: label, anchor: CGPoint(x: 0.32, y: 0.41), color: ink, size: image.size, rotation: rotation)
            box.place(layout, in: canvas, image: image, fontSize: 16)
            let corners = [CGPoint.zero, CGPoint(x: box.bounds.maxX, y: 0), CGPoint(x: box.bounds.maxX, y: box.bounds.maxY), CGPoint(x: 0, y: box.bounds.maxY)]
            let error = zip(corners, layout.corners).map { point, target in
                let p = box.convert(point, to: canvas)
                return hypot(p.x - target.x - image.minX, p.y - target.y - image.minY)
            }.max()!
            try check(error < 0.8, "图片旋转 \(rotation)° 后原位输入框四角对齐标注（偏差 \(error)）")
        }
    }
    static func testTimeline(_ r: Reader, _ window: NSWindow, _ work: URL) throws {
        let old = r.panel
        defer { r.resetChat(); r.panel = old }
        let legacyData = Data(#"{"id":"C467BB4A-CC03-450D-AF4B-09A5280157CA","role":"user","text":"旧版提问"}"#.utf8)
        let legacy = try JSONDecoder().decode(ChatLine.self, from: legacyData)
        var messages = [ChatLine]()
        for i in 0..<12 {
            messages.append(i == 0 ? legacy : ChatLine(role: "user", text: "第 \(i + 1) 轮的实验结果如何？"))
            messages.append(ChatLine(role: "assistant", text: String(repeating: "同一组输入下，绿色曲线收敛得更快。\n", count: 8)))
        }
        let session = PaperChat(messages: messages)
        let stored = try JSONDecoder().decode(PaperChat.self, from: JSONEncoder().encode(session))
        try check(stored.messages[2].createdAt != nil && stored.messages[2].forDisplay.createdAt == messages[2].createdAt &&
                  stored.messages[0].forDisplay.createdAt == nil, "问答时间随历史保存，兼容没有时间戳的旧记录")
        r.openChat(stored); r.panel = .chat; pause(0.45); paint(window)
        guard let marker = (window as? ReaderWindow)?.transcriptMarker, let scroll = marker.enclosingScrollView else { throw ReaderError("未找到时间线旁的对话视口") }
        func jump(_ index: Int) -> CGFloat {
            let frame = scroll.convert(scroll.bounds, to: nil)
            click(window, at: CGPoint(x: frame.maxX + 12, y: frame.maxY - 21 - CGFloat(index) * 24))
            pause(0.18); paint(window)
            return scroll.contentView.bounds.minY
        }
        let bottom = scroll.contentView.bounds.minY
        let first = jump(0), middle = jump(5), last = jump(11), again = jump(5)
        try check(bottom > 600 && first < 25 && middle > first + 250 && last > middle + 250 &&
                  abs(again - middle) < 4 && marker.awaitingJump == nil, "点击半透明圆点跳到首轮、中间轮和末轮，再次定位保持一致")
        r.question = "追加问题"
        r.sending = true; r.partialAnswer = "正在生成"; pause(0.2)
        let reading = jump(2)
        r.partialAnswer += String(repeating: "新的答案继续输出。\n", count: 15)
        pause(0.25)
        try check(abs(scroll.contentView.bounds.minY - reading) < 5, "生成期间点时间线回看前文时保留阅读位置")
        r.stopAnswer(); r.deleteExchange(messages[4].id)
        try check(!r.chat.contains { $0.id == messages[4].id }, "删除一轮对话后时间线同步更新")
        try capture(window, work.appendingPathComponent("chat-timeline.png"))
        r.deleteChat(session.id)
        let longSession = PaperChat(messages: (0..<42).flatMap { i in
            [ChatLine(role: "user", text: "实验 \(i + 1)"), ChatLine(role: "assistant", text: "测试记录")]
        })
        r.openChat(longSession); pause(0.45); paint(window)
        guard let longMarker = (window as? ReaderWindow)?.transcriptMarker, let longScroll = longMarker.enclosingScrollView else {
            throw ReaderError("长对话未打开")
        }
        let scrollFrame = longScroll.convert(longScroll.bounds, to: nil)
        let onRail = CGPoint(x: scrollFrame.maxX + 12, y: scrollFrame.midY)
        func railInside(_ view: NSView) -> NSScrollView? {
            if let candidate = view as? NSScrollView, candidate !== longScroll,
               candidate.bounds.width < 40, candidate.bounds.contains(candidate.convert(onRail, from: nil)) { return candidate }
            return view.subviews.lazy.compactMap(railInside).first
        }
        guard let content = window.contentView, let rail = railInside(content) else {
            throw ReaderError("未找到可滚动的长对话时间线")
        }
        let prior = longScroll.contentView.bounds.minY
        for _ in 0..<4 { imageWheel(window, at: onRail, delta: -9, flags: []) }
        let railOffset = rail.contentView.bounds.minY
        try check(rail.contentView.bounds.width >= 24, "常显系统滚动条时保留圆点的完整点击宽度")
        try check(railOffset > 30 && abs(prior - longScroll.contentView.bounds.minY) < 3, "长时间线可独立滚动查找更晚的提问")
        let index = Int((railOffset + scrollFrame.height * 0.7) / 24)
        click(window, at: CGPoint(x: onRail.x, y: scrollFrame.maxY - 21 - CGFloat(index) * 24 + railOffset))
        pause(0.2)
        try check(CGFloat(index) * 24 > scrollFrame.height && longScroll.contentView.bounds.minY < prior - 100 &&
                  longMarker.awaitingJump == nil, "滚动时间线后仍可跳到原先不可见的提问")
    }
    static func testPreferences(_ r: Reader, _ window: NSWindow, _ work: URL) throws {
        let oldMode = r.appearance, oldLanguage = r.language, oldTab = r.settingsTab
        defer { r.settings = false; r.setAppearance(oldMode); r.switchLanguage(oldLanguage); r.settingsTab = oldTab; pause(0.18) }
        r.switchLanguage(.chinese); r.setAppearance(.light); r.settingsTab = .appearance; r.settings = true; pause(0.4)
        guard let sheet = window.attachedSheet, let content = sheet.contentView else { throw ReaderError("设置窗口未打开") }
        let size = content.bounds.size
        try capture(sheet, work.appendingPathComponent("settings-zh-light.png"))
        let originalSize = r.memoFontSize
        try check(originalSize == 14, "没有字号配置时沿用 14 pt")
        click(sheet, at: CGPoint(x: size.width - 65, y: size.height - 248))
        try check(r.memoFontSize == originalSize + 1 && Reader(store: r.store).memoFontSize == r.memoFontSize,
                  "设置控件按 1 pt 增大备注字号，重新加载后保留")
        click(sheet, at: CGPoint(x: size.width - 65, y: size.height - 260))
        try check(r.memoFontSize == originalSize, "设置控件可缩小备注字号")
        click(sheet, at: CGPoint(x: 80, y: size.height - 130))
        try check(r.settingsTab == .tags, "点击设置侧栏可从外观切换到语义高亮")
        let originalTag = r.prefs.tags[0]
        click(sheet, at: CGPoint(x: 305, y: size.height - 116))
        guard let field = sheet.firstResponder as? NSTextView, field.isFieldEditor else { throw ReaderError("未能编辑语义标签") }
        field.selectAll(nil); field.insertText("方法细节", replacementRange: field.selectedRange())
        click(sheet, at: CGPoint(x: 80, y: size.height - 172))
        try check(r.settingsTab == .ai, "点击设置中的 AI 服务可打开模型与密钥表单")
        try check(r.prefs.tags[0].name == "方法细节", "离开设置标签页时保存名称编辑")
        r.updateTag(originalTag)
        r.switchLanguage(.english); r.setAppearance(.dark); pause(0.25)
        try capture(sheet, work.appendingPathComponent("settings-en-dark.png"))
        click(sheet, at: CGPoint(x: size.width - 53, y: size.height - 37))
        pause(0.25)
        try check(!r.settings && window.attachedSheet == nil, "英文深色设置页可从完成按钮返回阅读")
    }
    static func testWheelZoom(_ r: Reader, _ window: NSWindow) throws {
        let pdf = r.pdf!
        r.setZoom(.fixed, value: 1.8)
        r.go(2); pause(0.15); paint(window)
        let pointer = CGPoint(x: pdf.bounds.midX + 50, y: pdf.bounds.midY - 30)
        let inWindow = pdf.convert(pointer, to: nil)
        func wheel(_ delta: Int32, _ flags: CGEventFlags, at point: CGPoint, units: CGScrollEventUnit = .line, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil) throws {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { throw ReaderError("无法生成滚轮事件") }
            let screen = window.convertPoint(toScreen: point)
            cg.location = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.maxY - screen.y)
            cg.flags = flags
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            if let momentum { cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue)) }
            for field in [CGEventField.mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent] {
                cg.setIntegerValueField(field, value: Int64(window.windowNumber))
            }
            guard let event = NSEvent(cgEvent: cg) else { throw ReaderError("无法转换滚轮事件") }
            window.sendEvent(event)
            pause(0.12); paint(window)
        }
        guard let scrolling = pdf.documentView?.enclosingScrollView, let bar = scrolling.verticalScroller else { throw ReaderError("未找到 PDF 原生滚动条") }
        let previousStyle = scrolling.scrollerStyle
        scrolling.scrollerStyle = .legacy; pause(0.12); paint(window)
        let knob = bar.rect(for: .knob)
        let grip = bar.convert(CGPoint(x: knob.midX, y: knob.midY), to: nil)
        let moved = CGPoint(x: grip.x, y: grip.y - 45)
        let beforeDrag = scrolling.contentView.bounds.origin
        for (kind, location) in [(NSEvent.EventType.leftMouseDown, grip), (.leftMouseDragged, moved), (.leftMouseUp, moved)] {
            let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
        }
        pause(0.2); paint(window)
        try check(!knob.isEmpty && scrolling.contentView.bounds.origin != beforeDrag, "鼠标拖动原生 PDF 滚动条可移动正文")
        scrolling.scrollerStyle = previousStyle
        r.go(2); pause(0.12)
        let initial = pdf.scaleFactor
        guard let page = pdf.page(for: pointer, nearest: false) else { throw ReaderError("滚轮未指向 PDF 页面") }
        let anchor = pdf.convert(pointer, to: page)
        try wheel(1, .maskControl, at: inWindow)
        try check(pdf.scaleFactor > initial && r.state.zoom == .fixed && abs(r.scale - pdf.scaleFactor) < 0.001, "Control + 滚轮向上放大并更新缩放百分比")
        let after = pdf.convert(anchor, from: page)
        try check(hypot(after.x - pointer.x, after.y - pointer.y) < 3, "滚轮放大后指针仍指向同一段原文")
        try wheel(-1, .maskControl, at: inWindow)
        try check(abs(pdf.scaleFactor - initial) < 0.001, "Control + 滚轮向下缩小")
        try wheel(8, .maskControl, at: inWindow, units: .pixel)
        try check(pdf.scaleFactor > initial && pdf.scaleFactor < initial * 1.2, "精细滚动使用连续缩放")
        let manual = pdf.scaleFactor
        try wheel(1, .maskControl, at: CGPoint(x: window.contentView!.bounds.maxX - 80, y: inWindow.y))
        try check(abs(pdf.scaleFactor - manual) < 0.001, "侧栏滚动不改变 PDF 比例")
        let clip = pdf.documentView!.enclosingScrollView!.contentView
        let before = clip.bounds.origin
        try wheel(-4, [], at: inWindow)
        try check(pdf.scaleFactor == manual && clip.bounds.origin != before, "普通滚轮继续滚动正文")
        func key(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                                         isARepeat: false, keyCode: code)!
            window.sendEvent(event); pause(0.18); paint(window)
        }
        window.makeFirstResponder(nil)
        let beforeKey = clip.bounds.origin
        key(125, "\u{f701}", flags: [.function, .numericPad])
        try check(clip.bounds.origin != beforeKey, "无编辑焦点时方向键滚动正文")
        let beforeSpace = clip.bounds.origin
        key(49, " ")
        try check(clip.bounds.origin != beforeSpace, "空格向下滚动阅读")
        r.composerOpen = true; pause(0.18)
        guard let editor = window.firstResponder as? NSTextView else { throw ReaderError("问答输入框未获取编辑焦点") }
        let beforeEdit = clip.bounds.origin
        key(49, " ")
        try check(window.firstResponder === editor && r.question.contains(" ") && clip.bounds.origin == beforeEdit, "输入空格不触发正文滚动")
        try wheel(-3, [], at: inWindow)
        try check(clip.bounds.origin != beforeEdit && window.firstResponder === editor, "编辑时鼠标在正文仍可滚动且不抢输入焦点")
        r.composerOpen = false; r.question = ""
        r.setContinuous(false); r.setZoom(.page); r.go(1); pause(0.18)
        try wheel(-1, [], at: inWindow)
        try check(r.pageIndex == 2, "单页整页模式向下滚轮进入下一页")
        try wheel(1, [], at: inWindow)
        try check(r.pageIndex == 1, "单页整页模式向上滚轮返回上一页")
        try wheel(-12, [], at: inWindow, units: .pixel, phase: .began)
        try wheel(-14, [], at: inWindow, units: .pixel, phase: .changed)
        try wheel(-8, [], at: inWindow, units: .pixel, momentum: .begin)
        try check(r.pageIndex == 2, "一次触控板滑动及惯性只翻一页")
        r.go(1); pause(0.1)
        window.makeFirstResponder(pdf)
        key(121, "\u{f72d}", flags: .function)
        try check(r.pageIndex == 2, "单页模式 Page Down 翻页")
        key(123, "\u{f702}", flags: .function)
        try check(r.pageIndex == 1, "左方向键返回上一页")
        key(115, "\u{f729}", flags: .function)
        try wheel(1, [], at: inWindow)
        try check(r.pageIndex == 0, "首页向上滚动停留在首页")
        key(119, "\u{f72b}", flags: .function)
        try wheel(-1, [], at: inWindow)
        try check(r.pageIndex == (r.document!.pageCount - 1), "末页向下滚动停留在末页")
        r.setContinuous(true); r.go(2); pause(0.12)
        r.setZoom(.fixed, value: 0.081)
        try wheel(-1, .maskControl, at: inWindow)
        try check(abs(pdf.scaleFactor - pdf.minScaleFactor) < 0.001, "滚轮缩放遵守最小比例")
        for _ in 0..<4 { try wheel(1, .maskControl, at: inWindow, units: .pixel) }
        try check(pdf.scaleFactor > pdf.minScaleFactor, "低比例时细微滚动仍可逐步放大")
        r.setZoom(.width); r.go(0); pause(0.15); paint(window)
        guard let root = window.contentView, let parent = root.superview,
              let responder = root.hitTest(parent.convert(inWindow, from: nil)) else { throw ReaderError("未找到原生捏合手势响应视图") }
        let beforePinch = pdf.scaleFactor
        for phase: NSEvent.Phase in [.began, .changed, .ended] {
            let event = Pinch()
            event.samplePhase = phase; event.amount = phase == .changed ? 0.15 : 0
            event.target = window; event.point = inWindow
            responder.magnify(with: event); pause(0.07)
        }
        try check(pdf.scaleFactor > beforePinch, "触控板捏合经原生视图缩放")
        // AppKit commits its final live magnification asynchronously after the gesture ends.
        pause(0.5)
        let pinched = pdf.scaleFactor
        try wheel(1, .maskControl, at: inWindow)
        try check(abs(pdf.scaleFactor - pinched * 1.2) < 0.001, "滚轮可接续捏合后的缩放比例")
        r.setZoom(.width)
        r.go(0); pause(0.12)
    }

    static func testNavigation(_ r: Reader, _ window: NSWindow, _ work: URL) throws {
        guard let pdf = r.pdf, let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "navigation" }),
              let action = item.action else { throw ReaderError("未找到导航按钮") }
        func toggle() { NSApp.sendAction(action, to: item.target, from: item) }
        let originalWidth = pdf.bounds.width
        r.go(2); pause(0.12)
        let readingPage = r.pageIndex
        toggle()
        pause(0.2); paint(window)
        try check(r.showLeft && pdf.bounds.width < originalWidth - 100 && r.pageIndex == readingPage, "导航按钮展开并保留当前阅读页")
        try capture(window, work.appendingPathComponent("navigation.png"))
        toggle(); toggle(); toggle()
        pause(0.12); paint(window)
        try check(!r.showLeft && abs(pdf.bounds.width - originalWidth) < 1 && r.pageIndex == readingPage, "快速开合后恢复正文宽度和页码")
        for panel in [Panel.notes, .chat] {
            r.panel = panel; pause(0.07)
            try capture(window, work.appendingPathComponent(panel == .notes ? "empty-notes.png" : "empty-ai.png"))
        }
        r.panel = .pins; r.go(0); pause(0.1)
    }

    static func preview(_ store: PinPreviewStore?, _ pin: Pin, rotation: Int? = nil) -> CGImage? {
        awaitImage { await store?.image(for: pin, rotation: rotation, large: false) }
    }
    static func awaitImage(_ draw: @escaping () async -> CGImage?) -> CGImage? {
        var image: CGImage?
        var done = false
        Task {
            image = await draw()
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done && Date() < deadline { pause(0.01) }
        return image
    }
    static func chooseMarkupTool(_ tool: PinDrawingTool, in window: NSWindow) {
        func control(in view: NSView) -> NSSegmentedControl? {
            if let picker = view as? NSSegmentedControl, picker.identifier?.rawValue == "pin.markup.tools" { return picker }
            return view.subviews.lazy.compactMap(control(in:)).first
        }
        guard let picker = control(in: window.contentView!) else { return }
        picker.selectedSegment = PinDrawingTool.allCases.firstIndex(of: tool)!
        picker.sendAction(picker.action, to: picker.target)
        pause(0.1)
    }

    static func imageWheel(_ window: NSWindow, at point: CGPoint, delta: CGFloat, flags: NSEvent.ModifierFlags,
                           beforeDispatch: () -> Void = {}) {
        let event = LineWheel()
        event.target = window
        event.point = point
        event.lines = delta
        event.keys = flags
        beforeDispatch()
        NSApp.sendEvent(event)
        pause(0.12)
    }

    static func testMoveAndText(_ canvas: PinDrawingSurface, sheet: NSWindow, r: Reader, id: UUID, clipboard: NSPasteboard, work: URL) throws {
        func choose(_ tool: PinDrawingTool) { chooseMarkupTool(tool, in: sheet) }
        func mouse(_ start: CGPoint, _ end: CGPoint, clicks: Int = 1, cancel: Bool = false) {
            paint(sheet)
            let rect = canvas.imageRect
            let steps: [(NSEvent.EventType, CGPoint)] = start == end ? [(.leftMouseDown, start), (.leftMouseUp, end)] :
                [(.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)]
            for (type, p) in steps {
                let point = canvas.convert(CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height), to: nil)
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
                // Finish dispatching this canvas gesture before inspecting selection or sending a shortcut.
                NSApp.sendEvent(event)
                pause(0.08)
                if cancel && type == .leftMouseDragged { key(sheet, code: 53, chars: "\u{1b}", flags: []) }
            }
        }
        func key(_ window: NSWindow, code: UInt16, chars: String, flags: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
            pause(0.13)
        }
        func pin() -> Pin { r.state.pins.first { $0.id == id }! }
        func enterText(_ string: String, save: Bool = true) throws {
            let deadline = Date().addingTimeInterval(2)
            var editor: NSTextView?
            repeat {
                pause(0.05)
                if let input = sheet.firstResponder as? NSTextView, input.isEditable, input.isDescendant(of: canvas) {
                    editor = input
                }
            } while editor == nil && Date() < deadline
            guard let editor, let window = editor.window else { throw ReaderError("文本框未获得输入焦点") }
            try check(window === sheet && editor.isDescendant(of: canvas), "插入光标位于图片内的文本框")
            editor.selectAll(nil)
            editor.insertText(string, replacementRange: editor.selectedRange())
            pause(0.07)
            key(window, code: save ? 36 : 53, chars: save ? "\r" : "\u{1b}", flags: save ? .command : [])
        }
        choose(.rectangle)
        mouse(CGPoint(x: 0.08, y: 0.10), CGPoint(x: 0.32, y: 0.32))
        let box = pin().drawing!.last!
        choose(.arrow)
        mouse(CGPoint(x: 0.55, y: 0.72), CGPoint(x: 0.86, y: 0.72))
        let arrow = pin().drawing!.last!
        try check(canvas.tool == .hand && canvas.zoomControls?.selection?.id == arrow.id, "画完箭头立即回到手型并选中两个端点")
        let oldKey = pin().artworkID
        mouse(CGPoint(x: 0.16, y: 0.19), CGPoint(x: 0.32, y: 0.28))
        let moved = pin().drawing!.first { $0.id == box.id }!
        try check(moved.points != box.points && pin().drawing!.last == arrow && oldKey != pin().artworkID, "手型移动较低图层的线框，同时刷新便签缩略图")
        key(sheet, code: 6, chars: "z", flags: .command)
        try check(pin().drawing!.contains(box) && pin().drawing!.last == arrow, "撤销移动只恢复位置和原图层顺序")
        key(sheet, code: 6, chars: "Z", flags: [.command, .shift])
        try check(pin().drawing!.contains(moved), "重做移动恢复新位置")
        mouse(CGPoint(x: 0.70, y: 0.72), CGPoint(x: 0.76, y: 0.63))
        try check(pin().drawing!.last?.id == arrow.id && pin().drawing!.last?.points != arrow.points, "手型拖动箭头时两端一起移动")
        let blank = CGPoint(x: 0.48, y: 0.04)
        let beforeText = pin()
        choose(.text)
        mouse(blank, CGPoint(x: 0.88, y: blank.y))
        let original = "编码器 Encoder\n特征投影"
        try enterText(original)
        guard let label = pin().drawing?.last, label.tool == .text else { throw ReaderError("未保存文本框") }
        try check(label.label?.string == original && abs((label.label?.boxWidth ?? 0) - 0.4) < 0.02, "拖出文本框宽度并保存中英多行文字")
        try check(canvas.tool == .hand && canvas.zoomControls?.selection?.id == label.id, "文本输入完成后保留选中状态，可直接调整")
        let from = CGPoint(x: 0.46, y: 0.43), to = CGPoint(x: 0.78, y: 0.61)
        choose(.text)
        mouse(from, to)
        guard let inline = sheet.firstResponder as? NSTextView, inline.isDescendant(of: canvas) else { throw ReaderError("框选区域没有激活原位输入") }
        try check(canvas.tool == .hand && canvas.zoomControls?.editingText == true, "拖出文本框即回到手型，插入光标仍在框内")
        let lower = CGPoint(x: (from.x + to.x) / 2, y: to.y)
        mouse(lower, CGPoint(x: lower.x, y: lower.y + 0.08))
        try check(sheet.firstResponder === inline, "新建空白文本框时可直接拖底边，松手后继续输入")
        let border = CGPoint(x: from.x * 0.75 + to.x * 0.25, y: from.y)
        let oldOrigin = inline.convert(.zero as CGPoint, to: canvas)
        mouse(border, CGPoint(x: border.x + 0.04, y: border.y - 0.03))
        let newOrigin = inline.convert(.zero as CGPoint, to: canvas)
        try check(abs(newOrigin.x - oldOrigin.x - 0.04 * canvas.imageRect.width) < 1 &&
                  abs(newOrigin.y - oldOrigin.y + 0.03 * canvas.imageRect.height) < 1 && sheet.firstResponder === inline,
                  "输入期间抓住边框移动，文字光标随框一起保留")
        let zoomTarget = inline.convert(CGPoint(x: 8, y: 8), to: nil)
        // Window stacking can change between recording the event and dispatching it.
        let screenPoint = sheet.convertPoint(toScreen: zoomTarget)
        let overlay = NSPanel(contentRect: CGRect(x: screenPoint.x - 12, y: screenPoint.y - 12, width: 24, height: 24),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.level = .floating
        imageWheel(sheet, at: zoomTarget, delta: 1, flags: .control) { overlay.orderFront(nil) }
        overlay.orderOut(nil)
        try check(abs(canvas.zoom - 1.2) < 0.001 && sheet.firstResponder === inline, "输入文字时 Ctrl 滚轮可放大图片并保留插入光标")
        imageWheel(sheet, at: zoomTarget, delta: -1, flags: .control)
        try check(abs(canvas.zoom - 1) < 0.001 && sheet.firstResponder === inline, "反向滚轮恢复原图比例并保留输入焦点",
                  details: "zoom=\(canvas.zoom), keyWindow=\(sheet.isKeyWindow)")
        func fontField(in view: NSView) -> NSComboBox? {
            if view.identifier?.rawValue == "pin.markup.fontSize" { return view as? NSComboBox }
            return view.subviews.lazy.compactMap { fontField(in: $0) }.first
        }
        guard let font = fontField(in: sheet.contentView!) else { throw ReaderError("字号输入框未显示") }
        click(sheet, at: font.convert(CGPoint(x: 10, y: font.bounds.midY), to: nil))
        guard let fieldEditor = font.currentEditor() as? NSTextView else { throw ReaderError("字号栏无法键入自定义字号") }
        fieldEditor.selectAll(nil)
        fieldEditor.insertText("18.5", replacementRange: fieldEditor.selectedRange())
        key(sheet, code: 36, chars: "\r", flags: [])
        try check(sheet.firstResponder === inline && abs((inline.font?.pointSize ?? 0) - 18.5) < 0.01,
                  "输入自定义小数字号后可回到同一空白文本框继续打字",
                  details: "zoom=\(canvas.zoom), font=\(inline.font?.pointSize ?? 0), field=\(font.stringValue), inlineFocus=\(sheet.firstResponder === inline), keyWindow=\(sheet.isKeyWindow)")
        inline.insertText("实验说明", replacementRange: inline.selectedRange())
        mouse(CGPoint(x: 0.94, y: 0.9), CGPoint(x: 0.94, y: 0.9))
        if pin().drawing?.last?.label?.string != "实验说明" || !canvas.subviews.allSatisfy({ !($0 is PinInlineTextBox) }) {
            print("框外保存", pin().drawing?.last?.label as Any, canvas.subviews, sheet.firstResponder as Any)
        }
        try check(pin().drawing?.last?.label?.string == "实验说明" && abs((pin().drawing?.last?.label?.boxHeight ?? 0) - 0.26) < 0.015 &&
                  canvas.subviews.allSatisfy { !($0 is PinInlineTextBox) }, "二维拖框后在画布直接输入，点击框外保存所画高度与文字")
        key(sheet, code: 6, chars: "z", flags: .command)
        r.copyPin(id)
        let afterPNG = clipboard.data(forType: .png)
        guard let store = r.pinPreviews, let clean = preview(store, beforeText), let updated = preview(store, pin()) else { throw ReaderError("文本预览失败") }
        try check(afterPNG != nil && clean.dataProvider?.data != updated.dataProvider?.data, "文本框渲染进便签预览")
        let frame = label.bounds(size: canvas.imageRect.size, rotation: canvas.rotation)
        let p = CGPoint(x: frame.midX / canvas.imageRect.width, y: frame.midY / canvas.imageRect.height)
        let delta = CGPoint(x: -0.09, y: 0.07)
        mouse(p, CGPoint(x: p.x + delta.x, y: p.y + delta.y))
        let shifted = pin().drawing!.last!.bounds(size: canvas.imageRect.size, rotation: canvas.rotation)
        try check(abs(shifted.midX - frame.midX - delta.x * canvas.imageRect.width) < 1.5 &&
                  abs(shifted.midY - frame.midY - delta.y * canvas.imageRect.height) < 1.5, "文字工具中直接拖动文本框，位移与指针一一对应")
        key(sheet, code: 6, chars: "z", flags: .command)
        choose(.hand)
        mouse(p, p, clicks: 2)
        try enterText("已修改 Edited")
        try check(pin().drawing?.last?.id == label.id && pin().drawing?.last?.label?.string == "已修改 Edited", "双击文本框修改内容，保持标注身份")
        r.copyPin(id)
        try check(clipboard.data(forType: .png) != afterPNG, "复制图片反映文本修改")
        key(sheet, code: 6, chars: "z", flags: .command)
        try check(pin().drawing?.last?.label?.string == original, "撤销文字编辑恢复多行内容")
        mouse(p, p, clicks: 2)
        try enterText("取消输入", save: false)
        try check(pin().drawing?.last?.label?.string == original && canvas.zoomControls?.editingText == false &&
                  sheet.firstResponder === canvas, "取消文字编辑保留原文并将焦点还给画布")
        mouse(p, CGPoint(x: p.x - 0.15, y: p.y + 0.15))
        try check(pin().drawing?.last?.points != label.points && pin().drawing?.last?.label?.string == original, "手型移动文本框保留文字")
        var textSize: CGSize { canvas.imageRect.size }
        let textAngle = canvas.rotation
        func textUnit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / textSize.width, y: p.y / textSize.height) }
        func dragTextHandle(_ stroke: PinStroke, _ kind: PinShapeHandles.Kind, fraction: CGFloat) throws {
            guard let layout = stroke.textLayout(size: textSize, rotation: textAngle),
                  let grip = PinShapeHandles(stroke, size: textSize, rotation: textAngle)?.handles.first(where: { $0.kind == kind }) else {
                throw ReaderError("文本框缺少调整手柄")
            }
            let a = layout.corners[0], b = kind == .corner(2) ? layout.corners[2] : layout.corners[1]
            mouse(textUnit(grip.position), textUnit(CGPoint(x: grip.position.x + (b.x-a.x)*fraction, y: grip.position.y + (b.y-a.y)*fraction)))
        }
        let beforeResize = pin().drawing!.last!
        try dragTextHandle(beforeResize, .edge(1), fraction: -0.54)
        let narrowed = pin().drawing!.last!
        try check(narrowed.id == label.id && narrowed.label?.string == original && narrowed.label?.fontSize == label.label?.fontSize &&
                  narrowed.label!.boxWidth < beforeResize.label!.boxWidth * 0.55, "拖动文本框侧柄只改宽度，保留字号与文字")
        try dragTextHandle(narrowed, .corner(2), fraction: 0.35)
        let scaled = pin().drawing!.last!
        try check(scaled.id == narrowed.id && scaled.label!.fontSize == narrowed.label!.fontSize &&
                  abs(scaled.label!.boxWidth / narrowed.label!.boxWidth - 1.35) < 0.03, "拖右下角扩大文本框，独立调整宽高并保留字号")
        key(sheet, code: 6, chars: "z", flags: .command)
        try check(pin().drawing?.last == narrowed, "一次撤销恢复整次文本框缩放")
        key(sheet, code: 6, chars: "Z", flags: [.command, .shift])
        try check(pin().drawing?.last == scaled, "重做文本框缩放保留图层与内容")
        let bottomRight = scaled.textLayout(size: textSize, rotation: textAngle)!.corners[2]
        let pointer = CGPoint(x: canvas.imageRect.minX + bottomRight.x, y: canvas.imageRect.minY + bottomRight.y)
        canvas.setZoom(1.6, at: pointer)
        try dragTextHandle(scaled, .corner(2), fraction: -0.2)
        try check(pin().drawing!.last!.label!.fontSize == scaled.label!.fontSize && abs(pin().drawing!.last!.label!.boxWidth / scaled.label!.boxWidth - 0.8) < 0.03 && canvas.zoom == 1.6,
                  "图片放大后缩小文本框时字号仍固定")
        key(sheet, code: 6, chars: "z", flags: .command)
        try check(pin().drawing?.last == scaled && canvas.zoom == 1.6, "撤销只还原文本编辑，保留查看比例")
        canvas.fitImage()
        choose(.rectangle)
        mouse(CGPoint(x: 0.36, y: 0.30), CGPoint(x: 0.64, y: 0.60))
        let rectangle = pin().drawing!.last!
        try check(canvas.tool == .hand && canvas.zoomControls?.selection?.id == rectangle.id, "新矩形的控制点可立即拖动")
        key(sheet, code: 0, chars: "a", flags: [])
        guard let captionEditor = sheet.firstResponder as? NSTextView, captionEditor.isDescendant(of: canvas) else { throw ReaderError("选中矩形后键入文字未进入编辑") }
        try check(captionEditor.string == "a", "选中矩形直接打字保留首个字符")
        try enterText("系统框图")
        try check(pin().drawing!.last!.points == rectangle.points && pin().drawing!.last!.label?.string == "系统框图", "图形文字作为矩形的一部分保存")

        mouse(CGPoint(x: 0.64, y: 0.60), CGPoint(x: 0.69, y: 0.67))
        func currentBox() -> PinStroke { pin().drawing!.first { $0.id == rectangle.id }! }
        let size = canvas.imageRect.size, angle = canvas.rotation
        func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / size.width, y: p.y / size.height) }
        func dist(_ p: CGPoint, _ q: CGPoint) -> CGFloat { hypot(p.x - q.x, p.y - q.y) }
        let oldCorners = rectangle.rectangleVertices(size: size, rotation: angle)
        let grown = currentBox()
        let corners = grown.rectangleVertices(size: size, rotation: angle)
        try check(grown.points.count == 4 && dist(corners[0], oldCorners[0]) < 0.01 &&
                  dist(corners[2], oldCorners[2]) > 3, "拖动矩形角点调整宽高，对角固定")
        r.copyPin(id)
        let beforeRotation = clipboard.data(forType: .png)
        let center = CGPoint(x: (corners[0].x + corners[2].x) / 2, y: (corners[0].y + corners[2].y) / 2)
        let grips = PinShapeHandles(grown, size: size, rotation: angle)!
        let knob = grips.handles.first { $0.kind == .rotation }!.position
        let turn = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: .pi / 6).translatedBy(x: -center.x, y: -center.y)
        mouse(unit(knob), unit(knob.applying(turn)))
        let rotated = currentBox(), tilted = rotated.rectangleVertices(size: size, rotation: angle)
        let axis = CGPoint(x: tilted[1].x - tilted[0].x, y: tilted[1].y - tilted[0].y)
        let preAxis = CGPoint(x: corners[1].x - corners[0].x, y: corners[1].y - corners[0].y)
        let dot = (axis.x * preAxis.x + axis.y * preAxis.y) / (hypot(axis.x, axis.y) * hypot(preAxis.x, preAxis.y))
        try check(abs(dot - cos(.pi / 6)) < 0.01 && abs(dist(tilted[1], tilted[0]) - dist(corners[1], corners[0])) < 0.01 &&
                  abs(dist(tilted[3], tilted[0]) - dist(corners[3], corners[0])) < 0.01, "拖圆柄旋转矩形 30° 保留两条边长")
        r.copyPin(id)
        try check(clipboard.data(forType: .png) != beforeRotation, "复制的 PNG 反映矩形的新朝向")
        key(sheet, code: 6, chars: "z", flags: .command)
        try check(currentBox() == grown, "一次撤销还原整次旋转")
        key(sheet, code: 6, chars: "Z", flags: [.command, .shift])
        try check(currentBox() == rotated, "重做恢复矩形角度")
        let shrink = CGPoint(x: tilted[2].x * 0.75 + tilted[0].x * 0.25, y: tilted[2].y * 0.75 + tilted[0].y * 0.25)
        let resize = PinShapeHandles(rotated, size: size, rotation: angle)!.handles.first { $0.kind == .corner(2) }!.position
        mouse(unit(resize), unit(CGPoint(x: resize.x + shrink.x - tilted[2].x, y: resize.y + shrink.y - tilted[2].y)))
        let smaller = currentBox().rectangleVertices(size: size, rotation: angle)
        try check(dist(smaller[0], tilted[0]) < 0.01 && dist(smaller[2], shrink) < 1 &&
                  abs(dist(smaller[0], smaller[1]) / dist(tilted[0], tilted[1]) - 0.75) < 0.01, "倾斜矩形沿自身坐标轴缩放")
        let beforeCancel = currentBox()
        let currentGrip = PinShapeHandles(beforeCancel, size: size, rotation: angle)!.handles[0].position
        mouse(unit(currentGrip), unit(CGPoint(x: currentGrip.x + 14, y: currentGrip.y + 6)), cancel: true)
        try check(currentBox() == beforeCancel && sheet.isVisible, "拖动控制点时按 Esc 取消本次调整并保留编辑窗口")
        choose(.arrow)
        let tail = CGPoint(x: 0.1, y: 0.83), tip = CGPoint(x: 0.63, y: 0.83)
        mouse(tail, tip)
        let originalArrow = pin().drawing!.last!
        choose(.hand)
        let shaft = CGPoint(x: 0.42, y: 0.83)
        mouse(shaft, shaft)
        mouse(tip, CGPoint(x: 0.47, y: 0.70))
        let turnedArrow = pin().drawing!.last!
        try check(turnedArrow.id == originalArrow.id && turnedArrow.points.first == originalArrow.points.first &&
                  dist(turnedArrow.points.last!, originalArrow.points.last!) > 0.1, "拖箭尖改变箭头长度和方向，起点固定")
        mouse(tail, CGPoint(x: 0.18, y: 0.57))
        let finalArrow = pin().drawing!.last!
        try check(finalArrow.points.last == turnedArrow.points.last && finalArrow.points.first != turnedArrow.points.first,
                  "拖箭尾保留箭尖的位置")
        let originalMarks = pin().drawing, paperZoom = r.pdf!.scaleFactor
        let rect = canvas.imageRect
        let anchor = CGPoint(x: rect.midX - rect.width * 0.08, y: rect.midY)
        let target = canvas.convert(anchor, to: nil)
        func unitAnchor() -> CGPoint {
            let area = canvas.imageRect
            return CGPoint(x: (anchor.x - area.minX) / area.width, y: (anchor.y - area.minY) / area.height)
        }
        let beforeZoom = unitAnchor()
        r.copyPin(id)
        let unzoomedCopy = clipboard.data(forType: .png)
        imageWheel(sheet, at: target, delta: 1, flags: .control)
        if abs(canvas.zoom - 1.2) >= 0.001 || dist(beforeZoom, unitAnchor()) >= 0.005 {
            print("图片滚轮定位", canvas.zoom, beforeZoom, unitAnchor(), canvas.bounds, rect)
        }
        try check(abs(canvas.zoom - 1.2) < 0.001 && dist(beforeZoom, unitAnchor()) < 0.005 && r.pdf!.scaleFactor == paperZoom,
                  "Ctrl 滚轮以指针为中心放大便签，正文比例保持独立")
        imageWheel(sheet, at: target, delta: -1, flags: .control)
        try check(abs(canvas.zoom - 1) < 0.001, "Ctrl 反向滚动缩小图片")
        let pinch = Pinch()
        pinch.point = target
        pinch.target = sheet
        pinch.amount = 0.3
        NSApp.sendEvent(pinch)
        try check(abs(canvas.zoom - 1.3) < 0.001 && dist(beforeZoom, unitAnchor()) < 0.005, "触控板捏合在指针位置缩放")
        key(sheet, code: 29, chars: "0", flags: .command)
        key(sheet, code: 24, chars: "+", flags: [.command, .shift])
        try check(abs(canvas.zoom - 1.25) < 0.001, "⌘+ 放大图片")
        canvas.setZoom(4, at: anchor)
        let beforePan = canvas.imageRect.origin
        let shift: NSEvent.ModifierFlags = canvas.imageRect.height > canvas.bounds.height + 1 ? [] : .shift
        imageWheel(sheet, at: target, delta: 1, flags: shift)
        try check(canvas.zoom == 4 && canvas.imageRect.origin != beforePan, "放大后普通滚轮平移可视范围")
        choose(.pen)
        key(sheet, code: 49, chars: " ", flags: [])
        let panFrom = canvas.imageRect.origin, centerUnit = unitAnchor()
        mouse(centerUnit, CGPoint(x: centerUnit.x + 0.02, y: centerUnit.y + 0.02))
        let keyUp = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: sheet.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                     isARepeat: false, keyCode: 49)!
        NSApp.sendEvent(keyUp)
        try check(canvas.imageRect.origin != panFrom && pin().drawing == originalMarks, "画笔模式按住空格拖动只平移图片")
        r.copyPin(id)
        try check(unzoomedCopy != nil && clipboard.data(forType: .png) == unzoomedCopy, "查看局部后复制仍导出整张带标注的便签")
        canvas.setZoom(20, at: anchor)
        try check(canvas.zoom == 8, "图片放大上限为 800%")
        canvas.setZoom(0.01, at: anchor)
        try check(canvas.zoom == 0.25, "图片缩小下限为 25%")
        key(sheet, code: 29, chars: "0", flags: .command)
        try check(canvas.zoom == 1 && canvas.imageRect == rect && pin().drawing == originalMarks, "⌘0 恢复居中全图且保留全部标注")
        try check(r.saveNow(), "保存调整后的形状")
        let reloaded = try r.store.read(r.key! + ".json", fallback: PaperState())
        try check(reloaded.pins.first { $0.id == id }?.drawing == pin().drawing, "从磁盘读回旋转矩形和箭头的端点")
        guard let pinIndex = r.state.pins.firstIndex(where: { $0.id == id }) else { throw ReaderError("缺少标注便签") }
        let saved = pin()
        defer { r.state.pins[pinIndex] = saved }
        for tool in [PinDrawingTool.pen, .line, .oval] {
            choose(tool)
            mouse(CGPoint(x: 0.12, y: 0.12), CGPoint(x: 0.60, y: 0.52))
            let created = pin().drawing!.last!
            try check(created.tool == tool && canvas.tool == .hand && canvas.zoomControls?.selection?.id == created.id,
                      "新建" + tool.title + "后切回手型并选中刚画的对象")
            if tool == .oval {
                key(sheet, code: 36, chars: "\r", flags: [])
                try enterText("节点")
                let captioned = pin().drawing!.last!
                try check(captioned.id == created.id && captioned.label?.string == "节点", "椭圆可直接添加说明")
                key(sheet, code: 36, chars: "\r", flags: [])
                try enterText("")
                try check(pin().drawing?.last == created, "清空椭圆说明保留原图形")
            }
        }
        choose(.hand)
        let green = PinColor(NSColor.systemGreen)!
        for tool in PinDrawingTool.allCases where tool != .hand {
            let color = PinColor(NSColor.systemRed)!
            var mark = PinStroke(id: UUID(), tool: tool, color: color, width: 0.004, dashed: false,
                                 points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.7)])
            if tool == .text {
                mark.points = [CGPoint(x: 0.3, y: 0.4)]
                mark.label = PinTextLabel(string: "System diagram", orientation: 0, boxWidth: 0.4, fontSize: 0.035)
            }
            let under = PinStroke(id: UUID(), tool: .pen, color: color, width: 0.002, dashed: false, points: [.zero])
            let over = PinStroke(id: UUID(), tool: .pen, color: color, width: 0.002, dashed: false, points: [CGPoint(x: 1, y: 1)])
            r.state.pins[pinIndex].drawing = [under, mark, over]; pause(0.12)
            let currentSize = canvas.imageRect.size
            let box = mark.bounds(size: currentSize, rotation: canvas.rotation)
            let point = CGPoint(x: box.midX / currentSize.width, y: box.midY / currentSize.height)
            mouse(point, point)
            canvas.editStyle(.color(green))
            if tool == .text { canvas.editStyle(.font(26)) } else { canvas.editStyle(.width(0.009)) }
            if ![.pen, .text].contains(tool) { canvas.editStyle(.dashed(true)) }
            pause(0.08)
            let edited = pin().drawing![1]
            try check(edited.color == green && (tool == .text ? edited.label!.fontSize != mark.label!.fontSize : edited.width == 0.009) &&
                      ([.pen, .text].contains(tool) || edited.dashed), tool.title + "支持选中并编辑属性")
            if tool == .text { try capture(sheet, work.appendingPathComponent("markup-editor.png")) }
            key(sheet, code: 51, chars: "\u{7f}", flags: [])
            try check(pin().drawing == [under, over], tool.title + "可用 Delete 删除且保留其他图层")
            key(sheet, code: 6, chars: "z", flags: .command)
            try check(pin().drawing == [under, edited, over], tool.title + "撤销删除恢复原图层顺序和样式")
            key(sheet, code: 6, chars: "Z", flags: [.command, .shift])
            try check(pin().drawing == [under, over], tool.title + "可重做删除")
        }
    }

    static func testCardDrag(_ r: Reader, _ window: NSWindow, _ work: URL, _ clipboard: NSPasteboard) throws {
        let oldPanel = r.panel, oldPins = r.state.pins, oldNotes = r.state.excerpts
        defer { r.state.pins = oldPins; r.state.excerpts = oldNotes; r.panel = oldPanel }
        func findMarker(_ view: NSView, _ id: UUID) -> CardMarkerView? {
            if let grip = view as? CardMarkerView, grip.reference.id == id { return grip }
            for child in view.subviews { if let found = findMarker(child, id) { return found } }
            return nil
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        window.makeKeyAndOrderFront(nil)
        let root = window.contentView!
        func send(_ type: NSEvent.EventType, _ point: CGPoint) { NSApp.postEvent(mouse(type, point), atStart: false); pause(0.025) }
        func chooseCardItem(_ title: String, on marker: CardMarkerView) {
            let menuPoint = CGPoint(x: marker.cardFrame.maxX - 55, y: marker.cardFrame.maxY - 16)
            let menuWatch = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                guard let menu = note.object as? NSMenu, let item = menu.item(withTitle: title) else { return }
                RunLoop.main.perform(inModes: [.eventTracking, .default]) {
                    menu.cancelTrackingWithoutAnimation()
                    menu.performActionForItem(at: menu.index(of: item))
                }
            }
            send(.leftMouseDown, menuPoint)
            send(.leftMouseUp, menuPoint)
            pause(0.35)
            NotificationCenter.default.removeObserver(menuWatch)
        }
        func openCardMenu(_ title: String, on marker: CardMarkerView) throws -> NSWindow {
            chooseCardItem(title, on: marker)
            guard let sheet = window.attachedSheet else { throw ReaderError("未打开" + title) }
            return sheet
        }
        func clickSheet(_ sheet: NSWindow, _ point: CGPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.postEvent(event, atStart: false)
            }
            pause(0.12)
        }
        for list in [CardList.pins, .notes] {
            r.setAppearance(list == .pins ? .light : .dark)
            r.panel = list == .pins ? .pins : .notes
            pause(0.2); paint(window)
            func ids() -> [UUID] { list == .pins ? r.state.pins.map(\.id) : r.state.excerpts.map(\.id) }
            let original = ids()
            guard let first = findMarker(root, original[0]), let second = findMarker(root, original[1]),
                  let drag = first.drag, first.enclosingScrollView != nil else { throw ReaderError("未找到卡片或其滚动区域") }
            if list == .pins {
                guard let thumbnail = (window as? ReaderWindow)?.thumbnailSurfaces.allObjects.first(where: { !$0.visibleRect.isEmpty }),
                      let pdf = r.pdf else { throw ReaderError("未找到侧栏便签缩略图") }
                let point = thumbnail.convert(CGPoint(x: thumbnail.visibleRect.midX, y: thumbnail.visibleRect.midY), to: nil)
                let paperScale = pdf.scaleFactor
                imageWheel(window, at: point, delta: 1, flags: .control)
                try check(abs(thumbnail.zoom - 1.2) < 0.001 && pdf.scaleFactor == paperScale, "侧栏图片接受 Ctrl 滚轮，正文缩放独立")
                imageWheel(window, at: point, delta: -1, flags: .control)
                try check(abs(thumbnail.zoom - 1) < 0.001, "侧栏图片反向滚动恢复全图")
                imageWheel(window, at: point, delta: -1, flags: .control)
                try check(thumbnail.zoom < 1 && pdf.scaleFactor == paperScale, "侧栏图片也可以缩小到适合尺寸以下")
                imageWheel(window, at: point, delta: 1, flags: .control)
                send(.leftMouseDown, point)
                send(.leftMouseUp, point)
                pause(0.25)
                guard let viewer = window.attachedSheet else {
                    print("便签点击", point, thumbnail.convert(thumbnail.visibleRect, to: nil), root.hitTest(root.convert(point, from: nil)) as Any, drag.card(at: point, in: window) as Any)
                    try capture(window, work.appendingPathComponent("card-preview-test.png"), chrome: true)
                    throw ReaderError("单击缩略图未打开大图")
                }
                try check(viewer.isVisible, "在侧栏缩放后，单击同一图片进入标注编辑器")
                viewer.makeKeyAndOrderFront(nil)
                let viewerSize = viewer.contentView!.bounds.size
                clickSheet(viewer, CGPoint(x: viewerSize.width - 43, y: viewerSize.height - 31))
                let deadline = Date().addingTimeInterval(2)
                while window.attachedSheet != nil && Date() < deadline { pause(0.02) }
                try check(window.attachedSheet == nil, "关闭便签预览并返回阅读窗口")
            }
            paint(window)
            let clip = first.enclosingScrollView!.contentView
            let visibleColumn = clip.convert(clip.bounds, to: nil).insetBy(dx: 0, dy: -clip.bounds.height)
            let snapshotOrigin = first.cardFrame.intersection(visibleColumn)
            let start = CGPoint(x: first.cardFrame.midX, y: first.cardFrame.midY)
            let dest = CGPoint(x: start.x + 26, y: second.cardFrame.midY - 6)
            try check(drag.card(at: start, in: window) === first, "可从卡片正文中央起拖")
            NSApp.sendEvent(mouse(.leftMouseDown, start))
            NSApp.sendEvent(mouse(.leftMouseDragged, dest))
            try check(ids() == original && drag.placement?.target.id == original[1] && drag.placement?.after == true,
                      "拖动时显示插入位置且保留已保存顺序")
            pause(0.18); paint(window)
            if list == .pins { try capture(window, work.appendingPathComponent("card-drag.png"), chrome: true) }
            guard let layers = root.superview?.subviews, let lift = layers.compactMap({ $0 as? LiftedCard }).last,
                  layers.last is CardDeletionFeedback else { throw ReaderError("浮动卡片或边缘提示层缺失") }
            try check(abs(lift.convert(lift.bounds, to: nil).midX - snapshotOrigin.midX - 26) < 2, "浮层横向跟随抓取点，显示在其他卡片上方")
            NSApp.sendEvent(mouse(.leftMouseUp, dest))
            try check(ids() == Array(original.reversed()) && drag.placement == nil, "松手后完成卡片落位")
            paint(window)
            guard let handle = findMarker(root, original[1]) else { throw ReaderError("重新排序后未找到卡片") }
            var next = CGPoint(x: handle.cardFrame.maxX - 18, y: handle.cardFrame.maxY - 15)
            send(.leftMouseDown, next)
            send(.leftMouseDragged, CGPoint(x: next.x - 8, y: next.y - 14))
            try check(drag.placement?.source.id == handle.reference.id, "从折叠按钮上起拖")
            send(.leftMouseUp, CGPoint(x: 0, y: 5))
            try check(ids() == Array(original.reversed()) && drag.placement == nil, "拖出侧栏松手取消排序")
            if list == .pins {
                pause(0.2); paint(window)
                guard let current = findMarker(root, original[1]) else { throw ReaderError("找不到取消拖动后的卡片") }
                next = CGPoint(x: current.cardFrame.maxX - 18, y: current.cardFrame.maxY - 15)
                let before = r.state.pins[0].collapsed
                send(.leftMouseDown, next)
                send(.leftMouseUp, next)
                pause(0.1)
                try check(r.state.pins[0].collapsed != before, "原地单击仍可折叠便签")
                let targetID = r.state.pins[0].id
                guard let marker = findMarker(root, targetID) else { throw ReaderError("未找到便签菜单") }
                let sheet = try openCardMenu(L("卡片颜色…"), on: marker)
                let sheetView = sheet.contentView!
                try capture(sheet, work.appendingPathComponent("card-colors.png"))
                clickSheet(sheet, CGPoint(x: 30, y: sheetView.bounds.height - 62))
                try check(r.state.pins.first(where: { $0.id == targetID })?.color == PinColor(Ink.rose.color), "从卡片菜单打开选色器并选用预设色")
                clickSheet(sheet, CGPoint(x: sheetView.bounds.width - 42, y: 28))
                pause(0.25)
                try check(window.attachedSheet == nil, "完成选色并返回阅读")
            }
            let picked = list == .pins ? original[1] : original[0]
            let placed = ids()
            guard let victim = findMarker(root, picked), let trash = drag.trash else { throw ReaderError("便签删除区缺失") }
            if list == .pins {
                let pin = r.state.pins.first { $0.id == picked }!
                guard let expected = ClipRenderer.image(pin.source, in: r.document!, maxEdge: 4096, scale: 3) else { throw ReaderError("无法生成便签图片参照") }
                func copiedImageMatches() -> Bool {
                    guard let data = clipboard.data(forType: .png), let bitmap = NSBitmapImageRep(data: data),
                          clipboard.data(forType: .tiff) != nil else { return false }
                    return bitmap.pixelsWide == expected.width && bitmap.pixelsHigh == expected.height
                }
                r.region = nil
                chooseCardItem(L("复制图片"), on: victim)
                try check(copiedImageMatches(), "通过便签卡片菜单复制图像到独立剪贴板")
                clipboard.clearContents()
                let sheet = try openCardMenu(L("放大便签"), on: victim)
                let size = sheet.contentView!.bounds.size
                clickSheet(sheet, CGPoint(x: size.width - 125, y: size.height - 31))
                try check(copiedImageMatches(), "大图复制按钮导出 PDF 原始选区的 PNG 和 TIFF")
                clipboard.clearContents()
                let commandC = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                                                context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
                NSApp.sendEvent(commandC); pause(0.08)
                try check(copiedImageMatches(), "便签大图的 ⌘C 复制当前图片")
                func surface(_ view: NSView) -> PinDrawingSurface? {
                    if let canvas = view as? PinDrawingSurface { return canvas }
                    return view.subviews.lazy.compactMap(surface).first
                }
                guard let canvas = surface(sheet.contentView!), !canvas.imageRect.isEmpty else { throw ReaderError("图片画布尚未载入") }
                try check(canvas.tool == .hand, "打开便签默认使用手型浏览或选择标注")
                NSApp.activate(ignoringOtherApps: true)
                sheet.makeKeyAndOrderFront(nil)
                let focusDeadline = Date().addingTimeInterval(2)
                while !sheet.isKeyWindow && Date() < focusDeadline { pause(0.02) }
                chooseMarkupTool(.pen, in: sheet)
                try check(canvas.tool == .pen && sheet.isKeyWindow, "标注工具栏切换画笔并由当前便签窗口接收输入")
                let beforeDrawing = clipboard.data(forType: .png)
                for (type, fraction) in [(NSEvent.EventType.leftMouseDown, 0.2), (.leftMouseDragged, 0.5), (.leftMouseUp, 0.8)] {
                    let rect = canvas.imageRect
                    let point = canvas.convert(CGPoint(x: rect.minX + rect.width * fraction, y: rect.midY), to: nil)
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    NSApp.postEvent(event, atStart: false)
                    pause(0.03)
                }
                func currentDrawing() -> [PinStroke] { r.state.pins.first { $0.id == picked }?.drawing ?? [] }
                let inkDeadline = Date().addingTimeInterval(1)
                while currentDrawing().isEmpty && Date() < inkDeadline { pause(0.02) }
                if currentDrawing().first?.points.count != 3 {
                    print("画笔事件", sheet.isKeyWindow, sheet.firstResponder as Any, canvas.imageRect, currentDrawing().map { ($0.tool.rawValue, $0.points) })
                }
                try check(currentDrawing().first?.points.count == 3, "从放大便签的画布拖动画笔并保存一笔")
                NSApp.sendEvent(commandC); pause(0.08)
                try check(copiedImageMatches() && clipboard.data(forType: .png) != beforeDrawing, "复制图片包含刚画的笔迹")
                for redo in [false, true] {
                    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: redo ? [.shift, .command] : .command,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                                               context: nil, characters: redo ? "Z" : "z", charactersIgnoringModifiers: redo ? "Z" : "z", isARepeat: false, keyCode: 6)!
                    NSApp.sendEvent(key); pause(0.08)
                    try check(currentDrawing().count == (redo ? 1 : 0), redo ? "重做恢复便签笔迹" : "撤销移除便签笔迹")
                }
                try testMoveAndText(canvas, sheet: sheet, r: r, id: picked, clipboard: clipboard, work: work)
                clickSheet(sheet, CGPoint(x: size.width - 43, y: size.height - 31))
                pause(0.25)
            }
            let originalFont = r.memoFontSize
            r.setMemoFontSize(21); pause(0.1)
            let memoSheet = try openCardMenu(L("编辑备注"), on: victim)
            let memoSize = memoSheet.contentView!.bounds.size
            clickSheet(memoSheet, CGPoint(x: memoSize.width / 2, y: memoSize.height / 2))
            guard let memoEditor = memoSheet.firstResponder as? NSTextView,
                  let font = memoEditor.typingAttributes[.font] as? NSFont else { throw ReaderError("无法读取备注编辑器的输入字号") }
            try check(abs(font.pointSize - 21) < 0.01, "备注编辑框使用与卡片相同的自定义字号")
            clickSheet(memoSheet, CGPoint(x: memoSize.width - 50, y: 32))
            r.setMemoFontSize(originalFont); pause(0.25)
            let name = list == .pins ? "系统框图" : "伪代码"
            let renameSheet = try openCardMenu(L("重命名"), on: victim)
            let size = renameSheet.contentView!.bounds.size
            clickSheet(renameSheet, CGPoint(x: size.width / 2, y: size.height / 2))
            guard let editor = renameSheet.firstResponder as? NSTextView else { throw ReaderError("卡片名称输入框未获得焦点") }
            editor.selectAll(nil)
            editor.insertText(" " + name + " ", replacementRange: editor.selectedRange())
            clickSheet(renameSheet, CGPoint(x: size.width - 50, y: 32))
            pause(0.25)
            func cardName() -> String? {
                list == .pins ? r.state.pins.first(where: { $0.id == picked })?.customTitle :
                                r.state.excerpts.first(where: { $0.id == picked })?.customTitle
            }
            try check(window.attachedSheet == nil && cardName() == name, "从卡片菜单命名并保存“" + name + "”")
            let cardPoint = CGPoint(x: victim.cardFrame.midX, y: victim.cardFrame.midY)
            let edge = trash.convert(trash.bounds, to: nil)
            let viewport = clip.convert(clip.bounds, to: nil)
            try check(edge.width <= 44 && edge.height >= viewport.height - 2 && abs(edge.maxX - root.convert(root.bounds, to: nil).maxX) < 2,
                      "删除目标覆盖侧栏最右沿，列表宽度和高度保持稳定")
            let nearEdge = CGPoint(x: min(victim.cardFrame.maxX - 2, edge.maxX - 16), y: cardPoint.y)
            let vertical = CGPoint(x: nearEdge.x, y: nearEdge.y - 10)
            send(.leftMouseDown, nearEdge); send(.leftMouseDragged, vertical)
            try check(drag.placement?.source.id == picked && !drag.overTrash, "从卡片右侧起手纵向排序不会触发删除")
            send(.leftMouseUp, vertical); pause(0.15)
            let justOutside = CGPoint(x: edge.minX - 2, y: cardPoint.y)
            let drift = CGPoint(x: edge.minX + 2, y: cardPoint.y - 10)
            send(.leftMouseDown, justOutside); send(.leftMouseDragged, drift)
            try check(drag.placement?.source.id == picked && !drag.overTrash, "纵向拖动时轻微横移跨进右缘仍可排序")
            send(.leftMouseUp, drift); pause(0.15)
            if let last = ids().last.flatMap({ findMarker(root, $0) }) {
                let lastPoint = CGPoint(x: last.cardFrame.midX, y: last.cardFrame.intersection(viewport).midY)
                let bottom = CGPoint(x: viewport.midX, y: viewport.minY + 3)
                send(.leftMouseDown, lastPoint); send(.leftMouseDragged, bottom)
                try check(drag.placement != nil && !drag.overTrash, "拖至底部仍可排序")
                send(.leftMouseUp, bottom); pause(0.16)
                try check(ids() == placed, "在列表底部松手保留卡片")
            }
            send(.leftMouseDown, cardPoint)
            send(.leftMouseDragged, CGPoint(x: cardPoint.x - 8, y: cardPoint.y))
            try capture(window, work.appendingPathComponent(list == .pins ? "trash-idle-light.png" : "trash-idle-dark.png"), chrome: true)
            let target = CGPoint(x: edge.maxX - 2, y: cardPoint.y)
            send(.leftMouseDragged, target)
            try check(drag.overTrash && ids() == placed, "悬停删除区提示松手，卡片仍保留")
            for y in [viewport.minY + 3, edge.maxY - 3] {
                send(.leftMouseDragged, CGPoint(x: edge.maxX - 1, y: y))
                try check(drag.overTrash && ids() == placed, "侧栏右沿高低位置均可接收卡片")
            }
            send(.leftMouseDragged, cardPoint)
            try check(!drag.overTrash && ids() == placed, "离开删除区可继续整理")
            let annotationCount = r.document?.page(at: 0)?.annotations.count ?? 0
            send(.leftMouseDragged, target)
            pause(0.15)
            try capture(window, work.appendingPathComponent(list == .pins ? "drop-to-delete.png" : "drop-to-delete-dark.png"), chrome: true)
            send(.leftMouseUp, target)
            try check(ids() == placed.filter { $0 != picked } && r.lastDeletion?.panel == r.panel, "在删除区松手只删除抓取的卡片")
            try check(root.superview?.subviews.contains(where: { $0 is CardDeletionFeedback }) == false, "松手后边缘提示从窗口移除")
            if list == .notes {
                try check((r.document?.page(at: 0)?.annotations.count ?? 0) < annotationCount, "删除批注同步移除正文高亮")
            }
            try check(r.saveNow(), "保存拖动删除后的论文")
            let saved = try r.store.read(r.key! + ".json", fallback: PaperState())
            let savedIDs = list == .pins ? saved.pins.map(\.id) : saved.excerpts.map(\.id)
            try check(savedIDs == ids(), "被删除的卡片不再写回阅读记录")
            r.undoCardDeletion()
            try check(cardName() == name && ids() == placed && (r.document?.page(at: 0)?.annotations.count ?? 0) == annotationCount, "撤销删除恢复原位置及高亮")
            if list == .pins {
                let wasOpen = r.composerOpen, scope = r.wholePaper
                r.composerOpen = true; pause(0.15); paint(window)
                guard let restored = findMarker(root, picked), let drop = drag.chatTarget else { throw ReaderError("未找到便签或展开的提问框") }
                let start = CGPoint(x: restored.cardFrame.midX, y: restored.cardFrame.midY)
                let target = drop.convert(CGPoint(x: drop.bounds.midX, y: drop.bounds.midY), to: nil)
                send(.leftMouseDown, start); send(.leftMouseDragged, target)
                guard let lift = root.superview?.subviews.compactMap({ $0 as? LiftedCard }).last else { throw ReaderError("未显示便签缩略图") }
                let preview = lift.convert(lift.bounds, to: nil)
                try check(drag.overChat && preview.width <= 60.1 && preview.height <= 40.1 &&
                          (preview.width >= 59.9 || preview.height >= 39.9) && !preview.contains(target),
                          "图片便签进入展开的 AI 框时按 60 × 40 pt 等比缩放，避开落点")
                send(.leftMouseUp, target); pause(0.2)
                try check(r.attachments.filter { $0.id == picked }.count == 1 && ids() == placed && lift.superview == nil, "收进提问框后引用一张图片，保留原便签")
                r.attachments.removeAll { $0.id == picked }; r.composerOpen = wasOpen; r.wholePaper = scope
            }
            if list == .notes {
                pause(0.12); paint(window)
                guard let restored = findMarker(root, picked), let drop = drag.chatTarget else { throw ReaderError("未找到卡片或页面提问框") }
                let start = CGPoint(x: restored.cardFrame.midX, y: restored.cardFrame.midY)
                let point = drop.convert(CGPoint(x: drop.bounds.midX, y: drop.bounds.midY), to: nil)
                send(.leftMouseDown, start); send(.leftMouseDragged, CGPoint(x: start.x + 9, y: start.y))
                guard let lift = root.superview?.subviews.compactMap({ $0 as? LiftedCard }).last else { throw ReaderError("缺少卡片拖动预览") }
                let full = lift.bounds.size
                let approach = CGPoint(x: drop.convert(drop.bounds, to: nil).maxX + 38, y: point.y)
                send(.leftMouseDragged, approach)
                try check(lift.bounds.width < full.width && !drag.overChat && r.attachments.isEmpty, "接近 AI 胶囊时逐渐缩小卡片，尚未引用")
                send(.leftMouseDragged, point)
                let thumbnail = lift.convert(lift.bounds, to: nil)
                let expectedScale = min(1, 60 / full.width, 40 / full.height)
                try check(drag.overChat && abs(thumbnail.width - full.width * expectedScale) < 0.1 &&
                          abs(thumbnail.height - full.height * expectedScale) < 0.1 && !thumbnail.contains(point),
                          "投放到胶囊时，批注按 60 × 40 pt 等比缩放并露出指针落点")
                try capture(window, work.appendingPathComponent("card-over-composer.png"), chrome: true)
                send(.leftMouseDragged, start)
                try check(!drag.overChat && lift.bounds.size == full && r.attachments.isEmpty, "拖回侧栏恢复卡片原尺寸")
                send(.leftMouseDragged, point); send(.leftMouseUp, point)
                let landingDeadline = Date().addingTimeInterval(2)
                while (lift.superview != nil || !(window.firstResponder is NSTextView)) && Date() < landingDeadline { pause(0.02) }
                paint(window)
                try check(lift.superview == nil && drag.placement == nil, "引用后收起临时预览并清除拖动状态")
                try check(r.panel == .notes && r.composerOpen && r.attachments.contains { $0.id == picked } && ids() == placed, "批注拖入页面提问框且侧栏保留批注列表")
                guard let question = window.firstResponder as? NSTextView else { throw ReaderError("提问框未获得输入焦点") }
                let field = question.bounds.intersection(question.visibleRect)
                let fieldCenter = question.convert(CGPoint(x: field.midX, y: field.midY), to: nil)
                let hit = root.hitTest(root.superview!.convert(fieldCenter, from: nil))
                try check(!field.isEmpty && (hit === question || hit?.isDescendant(of: question) == true), "提问框可见区域实际命中原生文字编辑器")
                NSCursor.arrow.set()
                window.sendEvent(mouse(.mouseMoved, fieldCenter))
                try check(NSCursor.current == .iBeam, "鼠标进入浮窗提问框显示工字形指针")
                let draft = r.question
                question.insertText("输入测试", replacementRange: question.selectedRange())
                try check(r.question.contains("输入测试"), "提问框使用原生文字输入")
                r.question = draft
                let before = drop.convert(drop.bounds, to: nil)
                let handle = CGPoint(x: before.minX + 42, y: before.maxY - 21)
                let dx: CGFloat = before.midX > r.pdf!.convert(r.pdf!.bounds, to: nil).midX ? -65 : 65
                let canvas = r.pdf!.convert(r.pdf!.bounds, to: nil)
                let dy: CGFloat = before.midY > canvas.midY ? -52 : 52
                let moved = CGPoint(x: handle.x + dx, y: handle.y + dy)
                send(.leftMouseDown, handle); send(.leftMouseDragged, moved); send(.leftMouseUp, moved)
                pause(0.15); paint(window)
                var frame = drop.convert(drop.bounds, to: nil)
                try check(abs(frame.minX - before.minX - dx) < 3 && abs(frame.minY - before.minY - dy) < 3, "浮窗随指针沿两个方向移动")
                let footer = CGPoint(x: frame.midX, y: frame.minY + 15)
                let shift = CGPoint(x: footer.x - dx / 2, y: footer.y - dy / 2)
                send(.leftMouseDown, footer); send(.leftMouseDragged, shift); send(.leftMouseUp, shift); paint(window)
                try check(abs(drop.convert(drop.bounds, to: nil).minX - frame.minX + dx / 2) < 3, "从浮窗底部留白也可拖动")
                try capture(window, work.appendingPathComponent("floating-composer-dark.png"), chrome: true)
                r.setAppearance(.light); pause(0.12); paint(window)
                try capture(window, work.appendingPathComponent("floating-composer-light.png"), chrome: true)
                frame = drop.convert(drop.bounds, to: nil)
                let fold = CGPoint(x: frame.maxX - 22, y: frame.maxY - 17)
                send(.leftMouseDown, fold); send(.leftMouseUp, fold); paint(window)
                try check(!r.composerOpen && (122..<145).contains(drop.bounds.width) && drop.bounds.height == 46, "中文问答胶囊的点击区域")
                frame = drop.convert(drop.bounds, to: nil)
                let chip = CGPoint(x: frame.minX + 35, y: frame.midY)
                let dx2: CGFloat = frame.midX > canvas.midX ? -45 : 45
                let chipEnd = CGPoint(x: chip.x + dx2, y: chip.y)
                NSCursor.arrow.set()
                send(.leftMouseDown, chip); send(.leftMouseDragged, chipEnd)
                try check(NSCursor.current == .arrow, "拖动问答浮钮时保持箭头指针")
                send(.leftMouseUp, chipEnd)
                paint(window)
                try check(!r.composerOpen && abs(drop.convert(drop.bounds, to: nil).minX - frame.minX - dx2) < 3, "收起后可移动且不会误展开")
                try capture(window, work.appendingPathComponent("chat-launcher-light.png"), chrome: true)
                r.switchLanguage(.english); r.setAppearance(.dark); pause(0.12); paint(window)
                try check((122..<150).contains(drop.bounds.width) && drop.bounds.height == 46, "英文问答胶囊的尺寸")
                try capture(window, work.appendingPathComponent("chat-launcher-dark-en.png"), chrome: true)
                r.switchLanguage(.chinese); r.setAppearance(.light); pause(0.12); paint(window)
                let launcher = drop.convert(drop.bounds, to: nil)
                let label = CGPoint(x: launcher.maxX - 12, y: launcher.midY)
                send(.leftMouseDown, label); send(.leftMouseUp, label); pause(0.1)
                try check(r.composerOpen && drop.bounds.width > 200, "点击收起按钮的文字区域展开问答")
                r.resetChat(); r.composerOpen = false
            }
        }
        // Start on a partially visible row and hold the lifted card at the bottom edge.
        r.state.pins = (0..<12).map { _ in Pin(source: oldPins[0].source) }
        r.panel = .pins
        pause(0.25); paint(window)
        guard let anchor = r.state.pins.compactMap({ findMarker(root, $0.id) }).first,
              let scroll = anchor.enclosingScrollView, let drag = anchor.drag else { throw ReaderError("缺少长列表滚动区域") }
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 0, y: 90))
        scroll.reflectScrolledClipView(clip)
        pause(0.1); paint(window)
        guard let top = findMarker(root, r.state.pins[0].id) else { throw ReaderError("未找到部分可见的便签") }
        let visible = clip.convert(clip.bounds, to: nil)
        let start = CGPoint(x: top.cardFrame.midX, y: top.cardFrame.intersection(visible).midY)
        let ids = r.state.pins.map(\.id)
        let beforeScroll = clip.bounds.minY
        send(.leftMouseDown, start)
        send(.leftMouseDragged, CGPoint(x: start.x - 8, y: start.y))
        let edge = CGPoint(x: start.x, y: visible.minY + 4)
        send(.leftMouseDragged, edge)
        pause(0.2)
        try check(clip.bounds.minY > beforeScroll + 5 && drag.placement != nil && !drag.overTrash, "拖至列表底边时自动滚动")
        guard let bin = drag.trash else { throw ReaderError("未找到右侧删除区") }
        let right = CGPoint(x: bin.convert(bin.bounds, to: nil).maxX - 1, y: edge.y)
        send(.leftMouseDragged, right)
        let stopped = clip.bounds.origin
        pause(0.15)
        try check(drag.overTrash && clip.bounds.origin == stopped, "进入右侧删除区暂停自动滚动")
        let esc = NSEvent.keyEvent(with: .keyDown, location: edge, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(esc)
        send(.leftMouseUp, right)
        try check(r.state.pins.map(\.id) == ids && drag.placement == nil, "按 Esc 取消跨屏拖拽并还原顺序")
        r.panel = .notes
        let lines = (1...12).map { "第 \($0) 行批注原文。" }
        let long = Excerpt(text: lines.joined(separator: "\n"), lines: [])
        let short = Excerpt(text: lines.prefix(5).joined(separator: "\n"), lines: [])
        r.state.excerpts = [long, short]
        pause(0.22); paint(window)
        guard let longCard = findMarker(root, long.id), let shortCard = findMarker(root, short.id) else {
            throw ReaderError("未找到批注正文测试卡片")
        }
        let preview = longCard.cardFrame
        try check((18...30).contains(preview.height - shortCard.cardFrame.height), "只有超过五行的批注才显示展开入口")
        let showMore = CGPoint(x: preview.minX + 42, y: preview.minY + 56)
        send(.leftMouseDown, showMore); send(.leftMouseUp, showMore); pause(0.15)
        let full = longCard.cardFrame
        try check(full.height > preview.height + 120, "点击展开全文后可阅读全部十二行")
        let showLess = CGPoint(x: full.minX + 42, y: full.maxY - 46)
        send(.leftMouseDown, showLess); send(.leftMouseUp, showLess); pause(0.15)
        try check(abs(longCard.cardFrame.height - preview.height) < 1 && r.state.excerpts.first?.text == long.text,
                  "从正文顶部收起批注并保留完整原文")
    }
    static func testPresetColors(_ tags: [SemanticTag], _ work: URL) throws {
        try check(tags.count == 5 && Set(tags.map(\.ink)).count == 5, "五个预置高亮标签各有一种颜色")
        let store = LocalStore(root: work.appendingPathComponent("legacy-palette"))
        var legacy = Preferences()
        let question = SemanticTag(name: "疑问", ink: .rose, preset: "疑问")
        let reference = SemanticTag(name: "写作参考", ink: .gold, preset: "写作参考")
        let custom = SemanticTag(name: "疑问", ink: .rose)
        legacy.tags = [question, reference, custom]
        legacy.defaultTagID = question.id
        try store.write(legacy, to: "library.json")
        let upgraded = Reader(store: store)
        let saved = try store.read("library.json", fallback: Preferences())
        try check(upgraded.prefs.tags.map(\.ink) == [.blue, .violet, .rose] && saved.tags == upgraded.prefs.tags
                  && saved.tags.map(\.id) == legacy.tags.map(\.id) && saved.defaultTagID == question.id, "旧配色按原标签更新并保存，同名自建标签沿用其配色")
        var edited = upgraded.prefs.tags[0]
        edited.ink = .rose
        upgraded.updateTag(edited)
        try check(Reader(store: store).prefs.tags.first?.ink == .rose, "手动改回的高亮颜色在重启后保留")
    }
    static func clickLine(_ line: Anchor, _ r: Reader, _ window: NSWindow) throws {
        guard let paper = r.pdf, let page = r.document?.safePage(line.page) else { throw ReaderError("缺少高亮测试页") }
        r.go(line); pause(0.2); paint(window)
        let p = paper.convert(CGPoint(x: line.rect.midX, y: line.rect.midY), from: page)
        click(window, at: paper.convert(p, to: nil))
    }
    static func clickRemove(_ r: Reader, _ window: NSWindow) throws {
        guard let paper = r.pdf, let anchor = r.selectionFrame, r.focusedHighlight != nil else {
            throw ReaderError("单击高亮后没有显示操作栏")
        }
        let size = NSHostingView(rootView: SelectionBar(r: r)).fittingSize
        let center = SelectionLayout.center(anchor: anchor, viewport: paper.bounds.size, bar: size)
        let point = CGPoint(x: paper.bounds.minX + center.x, y: paper.isFlipped ? paper.bounds.minY + center.y : paper.bounds.maxY - center.y)
        click(window, at: paper.convert(point, to: nil))
    }
    static func testSourceHighlight(_ r: Reader, _ window: NSWindow, _ file: URL) throws {
        let original = try Data(contentsOf: file)
        r.panel = .pins
        r.open(file); pause(0.25); paint(window)
        guard let page = r.document?.page(at: 0), let (source, mark) = PDFHighlightID.annotations(on: page, index: 0).first,
              let entry = Excerpt(annotation: mark, source: source, page: page, canCopy: true), let line = entry.lines.first else {
            throw ReaderError("测试论文第一页没有可操作的高亮")
        }
        let otherMarks = Set(PDFHighlightID.annotations(on: page, index: 0).map { $0.0 }).subtracting([source])
        try clickLine(line, r, window)
        try check(r.focusedHighlight?.line == line, "真实论文：从原文点击既有高亮")
        try clickRemove(r, window)
        r.open(file); r.panel = .notes
        let deadline = Date().addingTimeInterval(8)
        while !r.highlightsLoaded && Date() < deadline { pause(0.05) }
        let remaining = Set(r.state.excerpts.compactMap(\.sourceHighlight))
        try check(r.highlightsLoaded && !remaining.contains(source) && otherMarks.isSubset(of: remaining) &&
                  r.state.deletedHighlights?.contains(source) == true, "真实论文：取消的高亮在重开后保持移除，保留同页其他高亮")
        let after = try Data(contentsOf: file)
        try check(after == original, "真实论文：原文件字节保持一致")
    }
    static func testEmbeddedHighlights(_ r: Reader, _ window: NSWindow, _ work: URL) throws {
        // This two-column fixture was written with PyMuPDF. It also contains a plain
        // yellow rectangle, an underline, and a rotated page with no text layer.
        let file = URL(fileURLWithPath: "Tests/Fixtures/embedded-highlights.pdf")
        let original = try Data(contentsOf: file)
        r.panel = .pins
        r.open(file); pause(0.2); paint(window)
        guard let page = r.document?.page(at: 0), let (source, mark) = PDFHighlightID.annotations(on: page, index: 0).first,
              let sample = Excerpt(annotation: mark, source: source, page: page, canCopy: true), let lastLine = sample.lines.last else {
            throw ReaderError("缺少多行内嵌高亮样本")
        }
        try clickLine(lastLine, r, window)
        try check(r.focusedHighlight?.line == lastLine && r.state.excerpts.count == 1, "首次打开后直接点击内嵌高亮的第二行，无需先打开批注栏")
        try clickRemove(r, window)
        try check(r.panel == .notes && r.showRight && r.state.excerpts.allSatisfy { $0.sourceHighlight != source } &&
                  !page.annotations.contains(mark) && r.focusedHighlight == nil, "点击取消高亮同步移除整条内嵌高亮和批注卡片")
        r.undoCardDeletion()
        try check(page.annotations.contains(mark) && r.state.excerpts.contains { $0.sourceHighlight == source && $0.note == sample.note },
                  "撤销正文取消操作恢复原来的高亮、卡片和备注")
        func openNotes() throws -> [Excerpt] {
            r.open(file)
            r.panel = .notes; r.showRight = true
            let deadline = Date().addingTimeInterval(6)
            while !r.highlightsLoaded && Date() < deadline { pause(0.02); paint(window) }
            guard r.highlightsLoaded else { throw ReaderError("未能载入 PDF 高亮") }
            return r.state.excerpts
        }
        let marks = try openNotes()
        try check(marks.count == 2 && marks.allSatisfy { $0.tag == r.prefs.defaultTagID }, "标准高亮自动归入普通默认标签")
        let first = marks.first { $0.sourceHighlight == source }!, second = marks.first { $0.sourceHighlight != source }!
        func thumbnailPixels() throws -> Data {
            guard let store = r.pageThumbnails else { throw ReaderError("缺少缩略图缓存") }
            let request = PageThumbnailRequest(page: 0, rotation: nil, marksRevision: r.thumbnailMarksRevision)
            let entries = r.state.excerpts, tags = r.prefs.tags, hidden = r.state.deletedHighlights ?? []
            guard let image = awaitImage({ await store.image(for: request, excerpts: entries, tags: tags, deleted: hidden) }),
                  let pixels = image.dataProvider?.data else { throw ReaderError("无法绘制批注缩略图") }
            return pixels as Data
        }
        let originalThumb = try thumbnailPixels()
        try check(first.text == "Alpha result\nBeta result" && first.lines.count == 2, "双栏 PDF 的跨行高亮合为一条摘录")
        try check(first.note == "Check against Table 2." && first.matches("beta") && first.matches("Table 2"), "原批注和摘录可搜索")
        try check(second.text.isEmpty && second.lines.first?.page == 1 && abs(second.lines[0].rect.minX - 70) < 0.01,
                  "旋转页上没有文字层的高亮仍保留定位")
        r.go(second.lines[0]); pause(0.1)
        try check(r.pdf?.visiblePages.contains(r.document!.page(at: 1)!) == true, "侧栏的批注可定位原文")
        let ref = r.cardReference(first.id, in: .notes)
        let added = SemanticTag(name: "Results", ink: .rose)
        r.prefs.tags.append(added)
        r.assignTag(added.id, to: first.id)
        r.renameCard(ref, to: "Comparison")
        r.setNote(first.id, text: "Review this comparison")
        func foregroundMarks() -> [PDFAnnotation] {
            r.document!.page(at: 0)!.annotations.filter { $0.type == "Highlight" }
        }
        try check(foregroundMarks().count == 2 && foregroundMarks().allSatisfy { $0.contents == "Review this comparison" },
                  "改标签后正文按行换色，备注可编辑")
        let reopened = try openNotes()
        let updated = reopened.first { $0.id == first.id }
        try check(reopened.count == 2 && updated?.tag == added.id && updated?.matches("comparison") == true && updated?.note == "Review this comparison",
                  "重开后保留标签、卡片名和备注，不重复导入")
        let md = work.appendingPathComponent("embedded.md")
        try NotebookExport.write(to: md, title: "Fixture", document: r.document!, state: r.state, tags: r.prefs.tags)
        let text = try String(contentsOf: md, encoding: .utf8)
        try check(text.contains("## Results") && text.contains("> Alpha result\n> Beta result") && text.contains("Review this comparison"),
                  "既有高亮和新建批注按相同标签导出")
        r.deleteTag(added.id)
        try check(r.state.excerpts.first(where: { $0.id == first.id })?.tag == r.prefs.defaultTagID, "删除标签保留摘录并归入默认标签")
        r.deleteCard(ref)
        try check(foregroundMarks().isEmpty, "删除批注同步移除纸面标记")
        let clearedThumb = try thumbnailPixels()
        try check(clearedThumb != originalThumb, "缩略图同步隐藏已删除的源高亮")
        r.undoCardDeletion()
        try check(r.state.excerpts.contains { $0.id == first.id } && !foregroundMarks().isEmpty, "撤销恢复批注和高亮")
        r.deleteCard(ref)
        let afterDelete = try openNotes()
        try check(afterDelete.map(\.id) == [second.id] && foregroundMarks().isEmpty, "重新打开后已删除的原始标记和卡片均不再出现")
        r.pdf?.setCurrentSelection(r.document!.page(at: 0)!.selection(for: CGRect(x: 225, y: 130, width: 85, height: 18)), animate: false)
        r.highlight(r.prefs.tags.first { $0.id == r.prefs.defaultTagID }!)
        let combined = try openNotes()
        try check(combined.count == 2 && combined.allSatisfy { $0.tag == r.prefs.defaultTagID }, "新建高亮与既有高亮使用同一标签和列表")
        guard let addedMark = combined.first(where: { $0.sourceHighlight == nil }), let line = addedMark.lines.first,
              let addedPage = r.document?.safePage(line.page) else { throw ReaderError("缺少新建高亮") }
        r.pdf?.setCurrentSelection(addedPage.selection(for: line.rect), animate: false)
        try check(r.highlightForSelection() == addedMark.id, "重新选中已高亮的文字可取消对应批注")
        r.pdf?.clearSelection()
        try clickLine(line, r, window)
        try check(r.focusedHighlight?.id == addedMark.id, "单击 Folio 新建的高亮命中原批注")
        try clickRemove(r, window)
        let remaining = try openNotes()
        try check(remaining.map(\.id) == [second.id] && foregroundMarks().isEmpty, "正文取消本地高亮后重开仍然生效，保留其他批注")
        _ = r.close()
        let final = try Data(contentsOf: file)
        try check(original == final, "阅读和导出保留原 PDF 文件")
        let subset = work.appendingPathComponent("embedded-reordered.pdf")
        try PageExport.write(source: file, password: nil, selection: "2,1", to: subset)
        let pages = PDFDocument(url: subset)
        let originalPages = PDFDocument(data: original)
        try check([1, 0].enumerated().allSatisfy { new, old in
            guard let extracted = pages?.page(at: new), let source = originalPages?.page(at: old) else { return false }
            let marks = source.annotations.filter { $0.type == "Highlight" }
            let copies = extracted.annotations.filter { $0.type == "Highlight" }
            return extracted.rotation == source.rotation && !copies.isEmpty && copies.count == marks.count &&
                zip(copies, marks).allSatisfy { copy, mark in
                    let a = copy.bounds, b = mark.bounds
                    let difference = [a.minX - b.minX, a.minY - b.minY, a.maxX - b.maxX, a.maxY - b.maxY]
                    return difference.allSatisfy { abs($0) < 0.000001 } &&
                        copy.quadrilateralPoints?.map(\.pointValue) == mark.quadrilateralPoints?.map(\.pointValue) && copy.contents == mark.contents
                }
        }, "重排后的 PDF 保留扫描页旋转、第三方高亮选区和原批注")
    }
    static func testPageExport(_ source: URL, _ work: URL) throws {
        let parsed = try PageExport.indices("3，1–2、3", count: 3)
        try check(parsed == [2,0,1], "页码提取保留输入顺序并合并重复页码")
        for entry in ["", "0", "4", "2-1", "1-", "1,,2", "1–999999999999999999999"] {
            try check((try? PageExport.indices(entry, count: 3)) == nil, "拒绝无效页码范围 " + entry)
        }
        let original = try Data(contentsOf: source)
        let file = work.appendingPathComponent("pages.pdf")
        try PageExport.write(source: source, password: nil, selection: "3,1-2", to: file)
        let document = PDFDocument(data: original)!, output = PDFDocument(url: file)
        try check(output?.pageCount == 3 && [2,0,1].enumerated().allSatisfy { copy, index in
            output?.page(at: copy)?.string == document.page(at: index)?.string
        }, "重新打开提取文件后逐页核对页数、原文与顺序")
        let overwrite: Void? = try? PageExport.write(source: file, password: nil, selection: "1", to: file)
        try check(overwrite == nil, "拒绝覆盖正在提取的 PDF")
        try PageExport.write(source: source, password: nil, selection: "2", to: file)
        let replaced = PDFDocument(url: file)
        try check(replaced?.pageCount == 1 && replaced?.page(at: 0)?.string == document.page(at: 1)?.string, "再次摘页以验证过的文件原子替换目标")
        let unchanged = try Data(contentsOf: source)
        try check(original == unchanged, "摘页后原 PDF 保持完整")
    }
    static func testPinDrawing(_ pin: Pin, in document: PDFDocument, store: PinPreviewStore, work: URL) throws {
        let blue = PinColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))!
        let start = CGPoint(x: 0.23, y: 0.32), end = CGPoint(x: 0.8, y: 0.76)
        var marked = pin
        let oldPin = try JSONDecoder().decode(Pin.self, from: JSONEncoder().encode(pin))
        try check(oldPin.drawing == nil, "已有图片便签可按原格式加载")
        func isBlue(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.blueComponent > 0.65 && c.redComponent < 0.35
        }
        for tool in [PinDrawingTool.pen, .line, .rectangle, .oval, .arrow] {
            let stroke = PinStroke(id: UUID(), tool: tool, color: blue, width: 0.04, dashed: true, points: [start, end])
            marked.drawing = [stroke]
            guard let cg = preview(store, marked) else { throw ReaderError("无法绘制便签标注预览") }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            let visible = (0..<bitmap.pixelsHigh).contains { y in (0..<bitmap.pixelsWide).contains { isBlue(bitmap, $0, y) } }
            try check(visible, "缩略图绘制彩色" + tool.title)
        }
        marked.drawing = [PinStroke(id: UUID(), tool: .pen, color: blue, width: 0.1, dashed: false, points: [start])]
        for angle in [0, 90, 180, 270] {
            guard let cg = preview(store, marked, rotation: angle) else { throw ReaderError("无法绘制旋转标注") }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            let p = PinStroke.rotate(start, by: angle)
            try check(isBlue(bitmap, Int(p.x * CGFloat(cg.width)), Int(p.y * CGFloat(cg.height))), "标注随便签旋转 \(angle)° 后仍锚定原图位置")
        }
        let clean = awaitImage { await store.image(for: pin, rotation: 0, large: true) }!
        let annotated = awaitImage { await store.image(for: marked, rotation: 0, large: true) }!
        let cleanAgain = awaitImage { await store.image(for: pin, rotation: 0, large: true) }!
        try check(clean === cleanAgain && clean !== annotated, "AI 引用的干净原图与带笔迹的本地大图分开缓存")
        let text = PinStroke(id: UUID(), tool: .text, color: blue, width: 0.004, dashed: false, points: [CGPoint(x: 0.08, y: 0.04)],
                             label: PinTextLabel(string: "图 A", orientation: 90, boxWidth: 0.8, fontSize: 0.10))
        var textPin = pin
        textPin.drawing = [text]
        for angle in [0, 90, 180, 270] {
            guard let image = preview(store, textPin, rotation: angle) else { throw ReaderError("文本预览失败") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            let extent = text.bounds(size: CGSize(width: image.width, height: image.height), rotation: angle)
            var inside = 0, outside = 0
            for y in 0..<image.height {
                for x in 0..<image.width where isBlue(bitmap, x, y) {
                    if extent.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: y)) { inside += 1 } else { outside += 1 }
                }
            }
            try check(inside > 1 && outside == 0, "旋转后文字像素位于可选文本框内 \(angle)°")
        }
        let paragraph = PinStroke(id: UUID(), tool: .text, color: blue, width: 0.004, dashed: false,
                                  points: [PinStroke.rotate(CGPoint(x: 0.28, y: 0.3), by: -90)],
                                  label: PinTextLabel(string: "编码器将输入映射为特征。Decoder reconstructs the original image.", orientation: 90, boxWidth: 0.42, fontSize: 0.025))
        for angle in [0, 90, 180, 270] {
            let size = angle % 180 == 0 ? CGSize(width: 500, height: 800) : CGSize(width: 800, height: 500)
            let layout = paragraph.textLayout(size: size, rotation: angle)!
            let controls = PinShapeHandles(paragraph, size: size, rotation: angle)!
            func drag(_ kind: PinShapeHandles.Kind, from i: Int, against j: Int, ratio: CGFloat) -> PinStroke {
                let grip = controls.handles.first { $0.kind == kind }!.position
                let a = layout.corners[i], b = layout.corners[j]
                return controls.adjusted(paragraph, handle: kind, from: grip,
                                         to: CGPoint(x: grip.x + (a.x - b.x) * ratio, y: grip.y + (a.y - b.y) * ratio))
            }
            let reflow = drag(.edge(3), from: 0, against: 1, ratio: -0.46)
            let newLayout = reflow.textLayout(size: size, rotation: angle)!
            let fixed = layout.corners[1], kept = newLayout.corners[1]
            try check(hypot(fixed.x-kept.x, fixed.y-kept.y) < 0.01 && newLayout.box.height > layout.box.height &&
                      reflow.label?.fontSize == paragraph.label?.fontSize, "旋转后收窄文本框仍沿书写方向换行 \(angle)°")
            let resized = drag(.corner(0), from: 0, against: 2, ratio: 0.2)
            let opposite = layout.corners[2], result = resized.textLayout(size: size, rotation: angle)!.corners[2]
            try check(hypot(opposite.x-result.x, opposite.y-result.y) < 0.01 &&
                      resized.label!.fontSize == paragraph.label!.fontSize && abs(resized.label!.boxWidth / paragraph.label!.boxWidth - 1.2) < 0.001, "旋转后文本框固定对角和字号 \(angle)°")
            var roomy = paragraph
            roomy.label?.string = "节点"
            roomy.label?.boxHeight = 0.40
            let room = roomy.textLayout(size: size, rotation: angle)!
            let grips = PinShapeHandles(roomy, size: size, rotation: angle)!
            let allTrack = grips.handles.allSatisfy { handle in
                let x: CGFloat, y: CGFloat
                let anchor: Int
                switch handle.kind {
                case .edge(let i):
                    x = i == 1 ? -9 : i == 3 ? 9 : 0
                    y = i == 0 ? 17 : i == 2 ? -17 : 0
                    anchor = (i + 2) % 4
                case .corner(let i):
                    x = i == 0 || i == 3 ? 9 : -9
                    y = i < 2 ? 17 : -17
                    anchor = (i + 2) % 4
                default: return false
                }
                var target = handle.position.applying(room.transform.inverted())
                target.x += x
                target.y += y
                let changed = grips.adjusted(roomy, handle: handle.kind, from: handle.position, to: target.applying(room.transform))
                let next = changed.textLayout(size: size, rotation: angle)!
                let a = room.corners[anchor], b = next.corners[anchor]
                return abs(next.box.width - room.box.width + abs(x)) < 0.01 && abs(next.box.height - room.box.height + abs(y)) < 0.01 &&
                    hypot(a.x - b.x, a.y - b.y) < 0.01 && changed.label?.fontSize == roomy.label?.fontSize
            }
            try check(grips.handles.count == 8 && allTrack, "有余量的文本框八个控制点分别跟手缩小，保持字号和对侧锚点 \(angle)°")
        }
        let savedText = try JSONDecoder().decode(Pin.self, from: JSONEncoder().encode(textPin))
        try check(savedText.drawing == textPin.drawing, "保存并重新读取文字、字号、方向与文本框宽度")
        let saved = try JSONDecoder().decode(Pin.self, from: JSONEncoder().encode(marked))
        try check(saved.drawing?.first?.points == [start] && saved.drawing?.first?.color == blue, "持久化保留标注位置和颜色")
        let legacyBox = PinStroke(id: UUID(), tool: .rectangle, color: blue, width: 0.032, dashed: false,
                                  points: [CGPoint(x: 0.27, y: 0.27), CGPoint(x: 0.68, y: 0.70)])
        let editorSize = CGSize(width: pin.source.rect.width * 8, height: pin.source.rect.height * 8)
        let arrow = PinStroke(id: UUID(), tool: .arrow, color: blue, width: 0.01, dashed: false,
                              points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.5)])
        let arrowHandles = PinShapeHandles(arrow, size: editorSize, rotation: 0)!
        let ends = arrowHandles.vertices
        let short = arrowHandles.adjusted(arrow, handle: .endpoint(1), from: ends[1], to: ends[0])
        let reverse = arrowHandles.adjusted(arrow, handle: .endpoint(1), from: ends[1], to: CGPoint(x: ends[0].x - 10, y: ends[0].y))
        let shortTip = PinStroke.displayPoint(short.points[1], size: editorSize, rotation: 0)
        try check(abs(hypot(shortTip.x - ends[0].x, shortTip.y - ends[0].y) - 2) < 0.001 &&
                  reverse.points[1].x < reverse.points[0].x && reverse.points[0] == arrow.points[0],
                  "箭尖经过箭尾时连续缩短并可反向")
        let handles = PinShapeHandles(legacyBox, size: editorSize, rotation: 0)!
        let verts = handles.vertices
        let pivot = CGPoint(x: (verts[0].x + verts[2].x) / 2, y: (verts[0].y + verts[2].y) / 2)
        let startKnob = handles.handles.first { $0.kind == .rotation }!.position
        let turn = CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: .pi / 6).translatedBy(x: -pivot.x, y: -pivot.y)
        let turned = handles.adjusted(legacyBox, handle: .rotation, from: startKnob, to: startKnob.applying(turn))
        var boxPin = pin
        boxPin.drawing = [turned]
        func showsTiltedEdges(_ bitmap: NSBitmapImageRep, rotation: Int) -> Bool {
            let size = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            let corners = turned.rectangleVertices(size: size, rotation: rotation)
            return corners.indices.allSatisfy { i in
                let a = corners[i], b = corners[(i + 1) % 4]
                let x = Int((a.x + b.x) / 2), y = Int((a.y + b.y) / 2)
                return (-1...1).contains { dy in (-1...1).contains { dx in isBlue(bitmap, x + dx, y + dy) } }
            } && !isBlue(bitmap, Int((corners[0].x + corners[2].x) / 2), Int((corners[0].y + corners[2].y) / 2))
        }
        for angle in [0, 90, 180, 270] {
            let cg = preview(store, boxPin, rotation: angle)!
            try check(showsTiltedEdges(NSBitmapImageRep(cgImage: cg), rotation: angle), "PDF 旋转后矩形四条斜边在正确位置 \(angle)°")
            let size = CGSize(width: cg.width, height: cg.height)
            let controls = PinShapeHandles(turned, size: size, rotation: angle)!
            let grip = controls.handles[0]
            let limited = controls.adjusted(turned, handle: grip.kind, from: grip.position, to: CGPoint(x: -1000, y: -1000))
            let c = limited.rectangleVertices(size: size, rotation: angle)
            let product = (c[1].x-c[0].x)*(c[3].x-c[0].x) + (c[1].y-c[0].y)*(c[3].y-c[0].y)
            try check(abs(product) < 0.001 && c.allSatisfy { CGRect(origin: .zero, size: size).insetBy(dx: -0.01, dy: -0.01).contains($0) },
                      "边缘缩放仍保持直角且矩形位于图内 \(angle)°")
        }
        let dir = work.appendingPathComponent("drawing-export")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var state = PaperState()
        state.pins = [marked, textPin, boxPin]
        try NotebookExport.write(to: dir.appendingPathComponent("drawing.md"), title: "Drawing", document: document, state: state, tags: [])
        let assets = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("figures-") }!
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: assets.appendingPathComponent("clip-001.png")))!
        try check(isBlue(bitmap, Int(start.x * CGFloat(bitmap.pixelsWide)), Int(start.y * CGFloat(bitmap.pixelsHigh))), "导出 Markdown 的 PNG 实际含有彩色标注")
        let exportedText = NSBitmapImageRep(data: try Data(contentsOf: assets.appendingPathComponent("clip-002.png")))!
        let hasLabel = (0..<exportedText.pixelsHigh).contains { y in (0..<exportedText.pixelsWide).contains { isBlue(exportedText, $0, y) } }
        try check(hasLabel, "Markdown 配图含彩色文本框字形")
        let exportedBox = NSBitmapImageRep(data: try Data(contentsOf: assets.appendingPathComponent("clip-003.png")))!
        try check(showsTiltedEdges(exportedBox, rotation: document.safePage(pin.source.page)!.rotation), "Markdown 导出保留旋转矩形的四条斜边")
    }
    static func testCrop(_ work: URL) throws {
        let url = work.appendingPathComponent("geometry.pdf")
        var media = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ctx = CGContext(url as CFURL, mediaBox: &media, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(media)
        let red = CGRect(x: 42, y: 52, width: 41, height: 23)
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(red)
        ctx.endPDFPage(); ctx.closePDF()
        let doc = PDFDocument(url: url)!, page = doc.page(at: 0)!
        let source = Anchor(page: 0, rect: red.insetBy(dx: 2, dy: 2))
        let store = PinPreviewStore(file: PaperFile(url), password: nil), pin = Pin(source: source)
        try testPinDrawing(pin, in: doc, store: store, work: work)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let cg = ClipRenderer.image(source, in: doc, maxEdge: 400, scale: 2)!
            // Zoom into a boundary between the red patch and the white page.
            let originalCenter = CGPoint(x: red.minX / media.width, y: 1 - red.midY / media.height)
            let center = PinStroke.rotate(originalCenter, by: rotation)
            let unit = CGRect(x: center.x - 0.04, y: center.y - 0.04, width: 0.08, height: 0.08)
            guard let detail = awaitImage({ await store.detail(for: Anchor(page: 0, rect: media), rotation: rotation, visible: unit, pixels: 500) }) else { throw ReaderError("缺少原始 PDF 局部重绘") }
            let detailRep = NSBitmapImageRep(cgImage: detail)
            func sample(_ dx: CGFloat) -> NSColor {
                let q = PinStroke.rotate(CGPoint(x: originalCenter.x + dx, y: originalCenter.y), by: rotation)
                return detailRep.colorAt(x: Int((q.x - unit.minX) / unit.width * CGFloat(detail.width)),
                                         y: Int((q.y - unit.minY) / unit.height * CGFloat(detail.height)))!.usingColorSpace(.deviceRGB)!
            }
            let reference = NSBitmapImageRep(cgImage: cg).colorAt(x: cg.width/2, y: cg.height/2)!.usingColorSpace(.deviceRGB)!
            let redPixel = sample(0.02), whitePixel = sample(-0.02)
            try check(abs(max(detail.width, detail.height) - 500) <= 1 && abs(redPixel.redComponent - reference.redComponent) < 0.02 &&
                      abs(redPixel.greenComponent - reference.greenComponent) < 0.02 && abs(redPixel.blueComponent - reference.blueComponent) < 0.02 &&
                      whitePixel.redComponent > 0.97 && whitePixel.greenComponent > 0.97 && whitePixel.blueComponent > 0.97, "图片放大局部从原始 PDF 重绘，位置和清晰度正确 \(rotation)°")
            let asyncImage = preview(store, pin, rotation: rotation)
            try check(asyncImage?.width == cg.width && asyncImage?.height == cg.height, "后台便签预览旋转 \(rotation)°")
            let rep = NSBitmapImageRep(cgImage: cg)
            let c = rep.colorAt(x: cg.width/2, y: cg.height/2)!.usingColorSpace(.deviceRGB)!
            try check(c.redComponent > 0.9 && c.redComponent - c.greenComponent > 0.7 && c.blueComponent < 0.2 && (cg.width > cg.height) == (rotation % 180 == 0), "扫描页区域裁切 \(rotation)°")
        }
        let encrypted = work.appendingPathComponent("locked.pdf")
        try check(doc.write(to: encrypted, withOptions: [.userPasswordOption: "test-reader", .ownerPasswordOption: "test-owner"]), "生成受保护样本")
        let locked = Reader(store: LocalStore(root: work.appendingPathComponent("locked-state")))
        locked.open(encrypted)
        try check(locked.locked != nil && locked.document == nil, "受保护文档提示密码")
        locked.unlock("wrong"); try check(locked.passwordError, "错误密码反馈")
        locked.unlock("test-reader"); try check(locked.document?.pageCount == 1, "密码解锁")
        let unlockedPages = work.appendingPathComponent("unlocked-pages.pdf")
        try PageExport.write(source: encrypted, password: "test-owner", selection: "1", to: unlockedPages)
        try check(PDFDocument(url: unlockedPages)?.pageCount == 1, "已获授权的加密 PDF 可提取页面")
        let priorExport = try Data(contentsOf: unlockedPages)
        let refused: Void? = try? PageExport.write(source: encrypted, password: "wrong", selection: "1", to: unlockedPages)
        let afterFailure = try Data(contentsOf: unlockedPages)
        try check(refused == nil && priorExport == afterFailure, "错误密码无法提取加密页面，已有目标文件保持完整")
        try check(preview(locked.pinPreviews, pin) != nil, "解锁后的后台便签预览")
        guard let thumbs = locked.pageThumbnails else { throw ReaderError("未创建导航预览缓存") }
        let tags = locked.prefs.tags
        func thumb(rotation: Int, revision: Int, excerpts: [Excerpt] = []) -> CGImage? {
            let request = PageThumbnailRequest(page: 0, rotation: rotation, marksRevision: revision)
            return awaitImage { await thumbs.image(for: request, excerpts: excerpts, tags: tags) }
        }
        guard let base = thumb(rotation: 0, revision: 0) else { throw ReaderError("无法绘制加密文档的导航缩略图") }
        try check(thumb(rotation: 0, revision: 0) === base, "再次展开时复用已解锁文档的页面缩略图")
        let note = Excerpt(tag: tags[0].id, text: "highlight", lines: [Anchor(page: 0, rect: CGRect(x: 100, y: 60, width: 80, height: 40))])
        func pixels(_ image: CGImage?) -> Data? { image?.dataProvider?.data as Data? }
        guard let marked = thumb(rotation: 0, revision: 1, excerpts: [note]),
              let cleared = thumb(rotation: 0, revision: 2), let rotated = thumb(rotation: 90, revision: 2) else {
            throw ReaderError("页面缩略图刷新失败")
        }
        try check(pixels(marked) != pixels(base) && pixels(cleared) == pixels(base), "页面缩略图反映新增和移除的高亮")
        try check(pixels(cleared) != pixels(rotated), "旋转后的缩略图重新绘制")
        let exported = work.appendingPathComponent("worker-notebook.md")
        var notebook = PaperState()
        notebook.pins = [pin]; notebook.rotations = [0: 90]
        try awaitResult { try await thumbs.exportNotebook(to: exported, title: "Fixture", state: notebook, tags: tags) }
        let md = try String(contentsOf: exported, encoding: .utf8)
        let relative = md.components(separatedBy: "](").last!.components(separatedBy: ")").first!
        let data = try Data(contentsOf: work.appendingPathComponent(relative))
        let rotatedImage = NSBitmapImageRep(data: data)
        try check(rotatedImage != nil && rotatedImage!.pixelsHigh > rotatedImage!.pixelsWide, "后台导出解锁文档中的便签，保留阅读器旋转方向")
        let oldDocument = locked.document
        let brokenRecord = locked.store.root.appendingPathComponent(LocalStore.identity(url) + ".json")
        let invalid = Data("incomplete record".utf8)
        try invalid.write(to: brokenRecord)
        locked.open(url)
        let afterAttempt = try Data(contentsOf: brokenRecord)
        try check(locked.document === oldDocument && locked.error != nil && afterAttempt == invalid, "打开损坏的阅读记录时保留当前论文与原记录")
        locked.open(encrypted)
        _ = locked.close()
        try check(locked.document == nil && locked.locked == nil, "关闭阅读器同时释放等待解锁的文档")
        let initialPath = work.appendingPathComponent("before-move.pdf"), movedPath = work.appendingPathComponent("after-move.pdf")
        try FileManager.default.copyItem(at: url, to: initialPath)
        locked.open(initialPath)
        try FileManager.default.moveItem(at: initialPath, to: movedPath)
        try check(preview(locked.pinPreviews, pin) != nil, "PDF 移动后仍可首次加载便签底图")
        let movedThumb = awaitImage { await locked.pageThumbnails?.image(for: PageThumbnailRequest(page: 0, rotation: 0, marksRevision: 0), excerpts: [], tags: []) }
        try check(movedThumb != nil, "PDF 移动后仍可首次打开导航缩略图")
        _ = locked.close()
    }
    static func testSwitchDuringRequest(_ paper: URL, work: URL) throws {
        var reply: CheckedContinuation<String, Never>?
        let reader = Reader(store: LocalStore(root: work.appendingPathComponent("switch-state"))) { _, _ in
            await withCheckedContinuation { reply = $0 }
        }
        reader.open(paper)
        let profile = Profile(.openAI)
        reader.prefs.profiles = [profile]; reader.prefs.active = profile.id
        reader.wholePaper = false; reader.includePage = true; reader.question = "First"
        let firstID = reader.key!
        reader.send()
        let deadline = Date().addingTimeInterval(5)
        while reply == nil && Date() < deadline { pause(0.01) }
        guard let reply else { throw ReaderError("测试服务未收到请求") }
        reader.query = "the"; reader.startSearch()
        reader.open(work.appendingPathComponent("geometry.pdf"))
        reader.query = "new paper"; reader.startSearch()
        reply.resume(returning: "Late response")
        let searchDeadline = Date().addingTimeInterval(5)
        while reader.searching && Date() < searchDeadline { pause(0.01) }
        let oldHistory = try reader.store.read(firstID + "-chats.json", fallback: [PaperChat]())
        try check(reader.key != firstID && !reader.sending && !reader.searching && reader.hits.isEmpty &&
                  reader.chat.isEmpty && reader.conversations.isEmpty && oldHistory.isEmpty, "切换论文后，旧搜索和迟到的模型回答均不会写入新会话")
        _ = reader.close()
    }

    static func testAITransport() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatFixtureProtocol.self]
        var completed = false, failure: Error?
        Task {
            defer { completed = true }
            do {
                var profile = Profile(.anthropic)
                profile.model = ""
                let models = try await AIClient.models(profile: profile, key: "fixture", configuration: config)
                try check(models == ["model-a", "model-b"], "留空模型 ID 可从服务获取多页模型列表")
                var updates: [String] = []
                let text = try await AIClient.stream(Profile(.openAI), [ChatLine(role: "user", text: "Hi")], key: "fixture", configuration: config) { updates.append($0) }
                try check(updates.first == "逐步" && text == "逐步回答", "SSE 首段单独显示，完成后拼合完整答案")
                for (provider, event) in [(Provider.anthropic, #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}"#),
                                          (.google, #"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#),
                                          (.custom, #"{"choices":[{"delta":{"content":"ok"}}]}"#)] {
                    let part = try AIClient.streamEvent(Data(event.utf8), provider: provider)
                    try check(part.text == "ok", provider.rawValue + " 流式文本解析")
                }
            } catch { failure = error }
        }
        let deadline = Date().addingTimeInterval(8)
        while !completed && Date() < deadline { pause(0.02) }
        if let failure { throw failure }
        try check(completed, "模型查询与流式请求正常结束")
    }

    static func protocols() throws {
        for vendor in Provider.allCases {
            var p = Profile(vendor)
            if p.base.isEmpty { p.base = "https://model.example.org/v1" }
            if p.model.isEmpty { p.model = "test-model" }
            let msg = [ChatLine(role: "user", text: "第一页的选区"), ChatLine(role: "assistant", text: "回答"), ChatLine(role: "user", text: "追问")]
            let req = try AIClient.request(profile: p, key: "local-fixture-only", history: msg)
            let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let response: String
            switch vendor {
            case .anthropic: response = #"{"content":[{"type":"text","text":"OK"}]}"#
            case .openAI: response = #"{"output":[{"content":[{"type":"output_text","text":"OK"}]}]}"#
            case .google: response = #"{"candidates":[{"content":{"parts":[{"text":"OK"}]}}]}"#
            default: response = #"{"choices":[{"message":{"content":"OK"}}]}"#
            }
            let result = try AIClient.decode(Data(response.utf8), provider: vendor)
            try check(req.url?.scheme == "https" && (json[vendor == .google ? "contents" : (vendor == .openAI ? "input" : "messages")] as? [Any])?.count == 3 && result == "OK", vendor.rawValue + " 请求与响应协议")
        }
    }
}
