import SwiftUI
import AppKit

@MainActor
final class Application: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let reader: Reader
    var window: NSWindow!
    private var nativeToolbar: WindowToolbar?
    init(reader: Reader) { self.reader = reader }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupMenus()
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: .interfaceLanguageChanged, object: nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func setupWindow() {
        window = ReaderWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Folio"
        NSApp.appearance = reader.appearance.native
        window.isOpaque = false
        window.backgroundColor = .clear
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 870, height: 490)
        window.delegate = self
        nativeToolbar = WindowToolbar(window: window, reader: reader)
        window.contentView = NSHostingView(rootView: Workspace(r: reader))
        window.center()
        window.setFrameAutosaveName("FolioMainWindow")
    }
    func application(_ sender: NSApplication, open urls: [URL]) {
        if let url = urls.first { reader.open(url); window?.makeKeyAndOrderFront(nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        reader.saveNow() ? .terminateNow : .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { reader.close() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func setupMenus() {
        let menu = NSMenu()
        func submenu(_ name: String) -> NSMenu {
            let top = NSMenuItem(); menu.addItem(top)
            let child = NSMenu(title: name); top.submenu = child
            return child
        }
        let app = submenu("Folio")
        app.addItem(withTitle: L("关于 Folio"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("设置…"), action: #selector(settings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: L("隐藏 Folio"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("退出 Folio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu(L("文件"))
        file.addItem(withTitle: L("打开 PDF…"), action: #selector(open), keyEquivalent: "o")
        file.addItem(withTitle: L("返回最近打开"), action: #selector(library), keyEquivalent: "")
        file.addItem(withTitle: L("导出 Markdown 笔记…"), action: #selector(exportNotes), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: L("提取页面为 PDF…"), action: #selector(exportPages), keyEquivalent: "")
        file.addItem(withTitle: L("打印…"), action: #selector(printDoc), keyEquivalent: "p")
        file.addItem(withTitle: L("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu(L("编辑"))
        for (name, selector, key) in [(L("撤销"), "undo:", "z"), (L("重做"), "redo:", "Z"), (L("剪切"), "cut:", "x"), (L("复制"), "copy:", "c"), (L("粘贴"), "paste:", "v"), (L("全选"), "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        edit.addItem(.separator())
        edit.addItem(withTitle: L("全文查找…"), action: #selector(find), keyEquivalent: "f")
        let view = submenu(L("阅读"))
        view.addItem(withTitle: L("跳转到页…"), action: #selector(focusPage), keyEquivalent: "l")
        view.addItem(withTitle: L("添加书签"), action: #selector(bookmark), keyEquivalent: "d")
        view.addItem(withTitle: L("返回跳转前的位置"), action: #selector(back), keyEquivalent: "[")
        let full = view.addItem(withTitle: L("切换全屏"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.control, .command]
        let win = submenu(L("窗口"))
        win.addItem(withTitle: L("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: L("缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = win
        NSApp.mainMenu = menu
    }
    @objc func languageChanged() { setupMenus() }
    @objc func open() { reader.choose() }
    @objc func settings() { reader.settings = true }
    @objc func find() { if reader.pdf != nil { reader.showFind = true; NotificationCenter.default.post(name: .focusFind, object: nil) } }
    @objc func focusPage() { if reader.pdf != nil { NotificationCenter.default.post(name: .focusPage, object: reader) } }
    @objc func exportPages() { reader.exportPages() }
    @objc func printDoc() { reader.printPDF() }
    @objc func library() { reader.close() }
    @objc func exportNotes() { reader.export() }
    @objc func bookmark() { if reader.pdf != nil { reader.addBookmark() } }
    @objc func back() { reader.pdf?.goBack(nil) }
}
extension Notification.Name {
    static let focusFind = Notification.Name("FolioFocusFind")
    static let focusPage = Notification.Name("FolioFocusPage")
}

#if !VERIFY
@main
enum Folio {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Application(reader: Reader())
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
