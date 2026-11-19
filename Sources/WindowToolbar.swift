import AppKit
import Combine
import SwiftUI

private final class SymbolItem: NSToolbarItem {
    var originalImage: NSImage?
    var active = false {
        didSet {
            guard active != oldValue else { return }
            image = active ? originalImage?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) : originalImage
        }
    }
}

@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    private weak var window: NSWindow?
    private let r: Reader
    private var observation: AnyCancellable?
    private var updateQueued = false
    private var reading: Bool?
    private var language: InterfaceLanguage?
    private var identifiers: [NSToolbarItem.Identifier] = []

    init(window: NSWindow, reader: Reader) {
        self.window = window; self.r = reader
        super.init()
        update()
        observation = reader.objectWillChange.sink { [weak self] in
            guard let self, !self.updateQueued else { return }
            self.updateQueued = true
            DispatchQueue.main.async { [weak self] in
                self?.updateQueued = false
                self?.update()
            }
        }
    }
    private func update() {
        guard let window else { return }
        let hasPaper = r.pdf != nil
        let titleVisibility: NSWindow.TitleVisibility = hasPaper && r.showLeft ? .hidden : .visible
        if window.titleVisibility != titleVisibility { window.titleVisibility = titleVisibility }
        if window.title != r.title { window.title = r.title }
        if reading != hasPaper || language != r.language {
            reading = hasPaper; language = r.language
            let leading = ["navigation", "back"].map(NSToolbarItem.Identifier.init(_:))
            let trailing = (hasPaper ? ["find", "region", "inspector", "more"] : ["language", "settings"]).map(NSToolbarItem.Identifier.init(_:))
            identifiers = (hasPaper ? leading : []) + [.flexibleSpace] + trailing
            let bar = NSToolbar(identifier: hasPaper ? "FolioReading" : "FolioLibrary")
            bar.delegate = self
            bar.displayMode = .iconOnly
            bar.showsBaselineSeparator = false
            window.toolbar = bar
        }
        for item in window.toolbar?.items ?? [] {
            let id = item.itemIdentifier.rawValue
            if id == "back" { item.isEnabled = r.canBack }
            let selected: Bool
            switch id {
            case "region": selected = r.regionMode
            case "find": selected = r.showFind
            case "navigation": selected = r.showLeft
            case "inspector": selected = r.showRight
            default: continue
            }
            (item as? SymbolItem)?.active = selected
        }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let symbol: String, title: String
        switch id.rawValue {
        case "navigation": (symbol, title) = ("sidebar.left", L("显示或收起导航"))
        case "back": (symbol, title) = ("chevron.backward", L("返回跳转前的位置"))
        case "find": (symbol, title) = ("magnifyingglass", L("全文查找 ⌘F"))
        case "region": (symbol, title) = ("rectangle.dashed", L("框选图表、公式或扫描页"))
        case "inspector": (symbol, title) = ("sidebar.right", L("显示或收起精读侧栏"))
        case "more": (symbol, title) = ("ellipsis.circle", L("更多操作"))
        case "language": (symbol, title) = ("globe", L("界面语言"))
        case "settings": (symbol, title) = ("gearshape", L("设置"))
        default: return nil
        }
        let item: NSToolbarItem
        if id.rawValue == "more" || id.rawValue == "language" {
            let menuItem = NSMenuToolbarItem(itemIdentifier: id)
            menuItem.menu = id.rawValue == "more" ? moreMenu() : languageMenu()
            menuItem.showsIndicator = false
            item = menuItem
        } else {
            item = SymbolItem(itemIdentifier: id)
            item.target = self; item.action = #selector(activate(_:))
        }
        item.autovalidates = false
        item.isNavigational = ["navigation", "back"].contains(id.rawValue)
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        (item as? SymbolItem)?.originalImage = item.image
        return item
    }
    @objc private func activate(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier.rawValue {
        case "navigation":
            r.showLeft.toggle()
            (sender as? SymbolItem)?.active = r.showLeft
        case "back": r.pdf?.goBack(nil)
        case "find": if r.showFind { r.dismissFind() } else { r.showFind = true }
        case "region": r.setRegionMode(!r.regionMode)
        case "inspector": panelChange { r.showRight.toggle() }
        case "settings": r.settings = true
        default: break
        }
    }
    private func languageMenu() -> NSMenu {
        let menu = NSMenu()
        for language in InterfaceLanguage.allCases {
            let item = menu.addItem(withTitle: language.name, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = language.rawValue
            item.state = r.language == language ? .on : .off
        }
        return menu
    }
    @objc private func changeLanguage(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let language = InterfaceLanguage(rawValue: raw) { r.switchLanguage(language) }
    }
    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        func entry(_ title: String, _ command: String) {
            let item = menu.addItem(withTitle: L(title), action: #selector(command(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command
        }
        entry("打开 PDF…", "open"); entry("返回最近打开", "library")
        menu.addItem(.separator())
        entry("添加书签", "bookmark"); entry("导出 Markdown 笔记…", "export")
        entry("提取页面为 PDF…", "extract")
        entry("打印…", "print"); entry("打印当前页…", "printPage")
        menu.addItem(.separator())
        let language = menu.addItem(withTitle: L("界面语言"), action: nil, keyEquivalent: "")
        language.submenu = languageMenu()
        entry("设置…", "settings")
        return menu
    }
    @objc private func command(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "open": r.choose()
        case "library": r.close()
        case "bookmark": r.addBookmark()
        case "export": r.export()
        case "extract": r.exportPages()
        case "print": r.printPDF()
        case "printPage": r.printPDF(current: true)
        case "settings": r.settings = true
        default: break
        }
    }
}

@MainActor func panelChange(_ changes: () -> Void) {
    withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.14), changes)
}
