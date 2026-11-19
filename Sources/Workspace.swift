import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct Workspace: View {
    @ObservedObject var r: Reader
    @StateObject private var cardDrag = CardDrag()
    @State private var dragging = false
    @AppStorage("inspectorWidth") private var inspectorWidth = 336.0
    @AppStorage("twoPaneInspectorFraction") private var twoPaneInspectorFraction = 0.0
    @AppStorage("navigationWidth") private var preferredNavWidth = 244.0
    @State private var liveNavigation: CGFloat?
    @State private var liveInspector: CGFloat?
    private static let minimumPaperWidth: CGFloat = 410
    var body: some View {
        VStack(spacing: 0) {
            if let pdf = r.pdf {
                GeometryReader { size in
                let divider = ResizeEdge.thickness
                let sideSpace = size.size.width - Self.minimumPaperWidth
                let navLimit = max(180, min(360, sideSpace - (r.showRight ? 246 : 0)))
                let requestedNav = min(navLimit, max(180, liveNavigation ?? preferredNavWidth))
                // In a narrow window the navigation pane can yield space during an inspector drag.
                let navWidth = min(requestedNav, max(180, sideSpace - (liveInspector ?? 0)))
                HStack(spacing: 0) {
                    if r.showLeft {
                        NavigationPane(r: r).id(ObjectIdentifier(pdf)).frame(width: navWidth - divider).clipped()
                        ResizeEdge(width: navWidth, limit: navLimit, navigation: true) { width, ended in
                            if ended { preferredNavWidth = width; liveNavigation = nil } else { liveNavigation = width }
                        }.frame(width: divider)
                    }
                    VStack(spacing: 0) {
                        if r.showLeft {
                            Text(verbatim: r.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                .truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 13).frame(height: 28).clipped().help(r.title)
                            Divider()
                        }
                        if r.showFind { FindBar(r: r); Divider() }
                        PaperCanvas(pdf: pdf).id(ObjectIdentifier(pdf)).clipped()
                            .overlay(alignment: .bottom) {
                                if r.regionMode && r.region == nil {
                                    Text(L("拖动框选，按 Esc 取消")).font(.callout)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(PaperStyle.surface, in: Capsule()).padding(10).allowsHitTesting(false)
                                }
                            }
                            .overlay {
                                if let anchor = r.selectionFrame {
                                    SelectionLayout(anchor: anchor) { SelectionBar(r: r) }
                                }
                            }
                            .overlay { FloatingChat(r: r, drag: cardDrag).id(ObjectIdentifier(pdf)) }
                        Divider()
                        ReadingBar(r: r)
                    }.frame(minWidth: Self.minimumPaperWidth, maxWidth: .infinity, maxHeight: .infinity)
                    if r.showRight {
                        // Stored sidebar widths include the splitter. Only the visible panes share the ratio.
                        let paneSpace = max(1, size.size.width - divider)
                        let dragLimit = min(divider + paneSpace / 2, sideSpace - (r.showLeft ? 180 : 0))
                        let limit = min(dragLimit, sideSpace - (r.showLeft ? navWidth : 0))
                        let preferred = !r.showLeft && twoPaneInspectorFraction > 0
                            ? divider + paneSpace * twoPaneInspectorFraction : inspectorWidth
                        let width = max(246, min(liveInspector ?? preferred, limit))
                        Inspector(r: r, drag: cardDrag).id(ObjectIdentifier(pdf))
                            .frame(width: width - divider).padding(.leading, divider)
                            .overlay(alignment: .leading) {
                                // Center the grab area on the visible seam, above every inspector tab.
                                // The outer half lives in the gutter so the PDF scroller stays accessible.
                                ResizeEdge(width: width, limit: dragLimit, navigation: false) { value, ended in
                                    if ended {
                                        if r.showLeft {
                                            if value > sideSpace - requestedNav { preferredNavWidth = max(180, sideSpace - value) }
                                            inspectorWidth = value
                                        } else { twoPaneInspectorFraction = (value - divider) / paneSpace }
                                        liveInspector = nil
                                    } else { liveInspector = value }
                                }.frame(width: divider * 2)
                            }.transition(.opacity)
                    }
                }
                }
            } else { Library(r: r) }
        }.foregroundStyle(PaperStyle.text)
            .background { WindowSurface(strength: r.glassStrength).ignoresSafeArea() }
            .overlay { if dragging { RoundedRectangle(cornerRadius: 11).strokeBorder(PaperStyle.accent, lineWidth: 3).allowsHitTesting(false) } }
            .environment(\.locale, Locale(identifier: r.language.rawValue))
            .onDrop(of: [.fileURL], isTargeted: $dragging) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { r.open(url) } }
                }
                return true
            }
            .sheet(isPresented: $r.settings) { PreferencesView(r: r) }
            .sheet(isPresented: Binding(get: { r.locked != nil }, set: { if !$0 { r.locked = nil } })) { UnlockSheet(r: r) }
            .alert("Folio", isPresented: Binding(get: { r.error != nil }, set: { if !$0 { r.error = nil } })) {
                Button(L("好")) { r.error = nil }
            } message: { Text(r.error ?? "") }
    }

}

struct ResizeEdge: NSViewRepresentable {
    static let thickness: CGFloat = 8
    let width: CGFloat
    let limit: CGFloat
    let navigation: Bool
    let resize: (CGFloat, Bool) -> Void

    final class Handle: NSView {
        var width: CGFloat = 0
        var limit: CGFloat = 0
        var navigation = false
        var resize: ((CGFloat, Bool) -> Void)?
        private var start: (x: CGFloat, width: CGFloat)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(visibleRect, cursor: .resizeLeftRight)
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            CGRect(x: bounds.midX, y: 0, width: 1 / (window?.backingScaleFactor ?? 1), height: bounds.height).fill()
        }
        override func mouseDown(with event: NSEvent) {
            start = (event.locationInWindow.x, width)
            NSCursor.resizeLeftRight.set()
        }
        private func update(_ event: NSEvent, ended: Bool) {
            guard let start else { return }
            let delta = event.locationInWindow.x - start.x
            let result = min(limit, max(navigation ? 180 : 246, start.width + (navigation ? delta : -delta)))
            resize?(result, ended)
            if ended { self.start = nil }
        }
        override func mouseDragged(with event: NSEvent) {
            update(event, ended: false)
            NSCursor.resizeLeftRight.set()
        }
        override func mouseUp(with event: NSEvent) { update(event, ended: true) }
    }
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ handle: Handle, context: Context) {
        handle.identifier = NSUserInterfaceItemIdentifier(navigation ? "navigation.splitter" : "inspector.splitter")
        handle.width = width; handle.limit = limit; handle.navigation = navigation; handle.resize = resize
        handle.setAccessibilityLabel(navigation ? bilingual("调整导航栏宽度", "Resize navigation sidebar") : L("调整精读侧栏宽度"))
    }
}

struct Library: View {
    @ObservedObject var r: Reader
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 12) {
                        Text(L("最近打开")).font(.system(size: 23, weight: .semibold))
                        Spacer()
                        Button(action: r.choose) { Label(L("打开 PDF"), systemImage: "folder") }
                            .controlSize(.regular).buttonStyle(.bordered)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()
                        if r.prefs.recents.isEmpty {
                            HStack(spacing: 12) {
                                Image(systemName: "clock").font(.title3).foregroundStyle(PaperStyle.muted)
                                Text(L("将 PDF 拖入窗口，或从本机选择论文。")).font(.callout).foregroundStyle(PaperStyle.muted)
                            }.padding(.vertical, 13)
                        } else {
                            ForEach(r.prefs.recents) { item in
                                Button {
                                    r.open(URL(fileURLWithPath: item.path))
                                } label: {
                                    HStack(spacing: 13) {
                                        Image(systemName: "doc.text").font(.system(size: 16)).foregroundStyle(PaperStyle.accent)
                                            .frame(width: 34, height: 38).background(PaperStyle.tint, in: RoundedRectangle(cornerRadius: 6))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text(URL(fileURLWithPath: item.path).deletingLastPathComponent().lastPathComponent + bilingual("  ·  \(item.pages) 页", "  ·  \(item.pages) pages"))
                                                .font(.caption).foregroundStyle(PaperStyle.muted)
                                        }
                                        Spacer()
                                        Text(item.date.formatted(.dateTime.month().day().locale(Locale(identifier: r.language.rawValue)))).font(.caption).foregroundStyle(PaperStyle.muted)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(PaperStyle.muted)
                                    }.padding(.vertical, 2).contentShape(Rectangle())
                                }.buttonStyle(ReaderButtonStyle()).contextMenu {
                                    Button(L("从最近打开中移除")) { r.prefs.recents.removeAll { $0.id == item.id }; r.persistPreferences() }
                                }
                                Divider()
                            }
                        }
                    }
                }.frame(maxWidth: 780).padding(.horizontal, 40).padding(.top, max(33, min(geo.size.height * 0.1, 72))).padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct ReadingBar: View {
    @ObservedObject var r: Reader
    @State private var number = ""
    @FocusState private var editingPage: Bool
    @State private var zoomEntry = false
    @State private var percent = ""
    var body: some View {
        HStack(spacing: 5) {
            GlyphButton(symbol: "chevron.left", title: L("上一页")) { r.go(r.pageIndex - 1) }.disabled(r.pageIndex == 0)
            TextField(L("页"), text: $number).textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
                .focused($editingPage).help(L("跳转到页…") + " ⌘L")
                .onReceive(NotificationCenter.default.publisher(for: .focusPage, object: r)) { _ in
                    editingPage = true
                    DispatchQueue.main.async { (r.pdf?.window?.firstResponder as? NSTextView)?.selectAll(nil) }
                }
                .frame(width: 41).accessibilityLabel(L("跳转页码")).onAppear { number = String(r.pageIndex + 1) }
                .onChange(of: r.pageIndex) { _, n in number = String(n + 1) }
                .onSubmit {
                    if let n = Int(number.trimmingCharacters(in: .whitespaces)), n > 0, n <= (r.document?.pageCount ?? 0) { r.go(n - 1) }
                    number = String(r.pageIndex + 1)
                    editingPage = false
                    // The field editor resigns at the end of the Return event.
                    DispatchQueue.main.async {
                        if let paper = r.pdf, let window = paper.window, window.attachedSheet == nil {
                            window.makeFirstResponder(paper)
                        }
                    }
                }
            Text("/  \(r.document?.pageCount ?? 0)").font(.system(size: 13).monospacedDigit()).foregroundStyle(PaperStyle.muted)
            GlyphButton(symbol: "chevron.right", title: L("下一页")) { r.go(r.pageIndex + 1) }.disabled(r.pageIndex + 1 >= (r.document?.pageCount ?? 0))
            Spacer()
            GlyphButton(symbol: "minus", title: L("缩小")) { r.setZoom(.fixed, value: r.scale / 1.2) }
            Menu {
                Button(L("适合页宽")) { r.setZoom(.width) }
                Button(L("适合整页")) { r.setZoom(.page) }
                Divider()
                ForEach([50, 75, 100, 125, 150, 200], id: \.self) { n in Button("\(n)%") { r.setZoom(.fixed, value: CGFloat(n)/100) } }
                Button(L("指定比例…")) { percent = String(Int(r.scale * 100)); zoomEntry = true }
            } label: { Text("\(Int((r.scale * 100).rounded()))%").font(.system(size: 13).monospacedDigit()) }
            .menuStyle(.borderlessButton).fixedSize().help(L("按住 Control 并滚动可缩放页面")).popover(isPresented: $zoomEntry) {
                HStack { TextField("8–800", text: $percent).frame(width: 60).onSubmit { applyPercent() }; Text("%"); Button(L("应用")) { applyPercent() } }.padding()
            }
            GlyphButton(symbol: "plus", title: L("放大")) { r.setZoom(.fixed, value: r.scale * 1.2) }
            Menu {
                Picker(L("显示模式"), selection: Binding(get: { r.state.continuous }, set: r.setContinuous)) {
                    Text(L("连续滚动")).tag(true); Text(L("单页翻阅")).tag(false)
                }
                Divider()
                Button(L("顺时针旋转当前页"), action: r.rotate)
                Button(L("切换全屏")) { NSApp.keyWindow?.toggleFullScreen(nil) }
            } label: { Image(systemName: "rectangle.on.rectangle").frame(width: 23) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("显示选项"))
        }.padding(.horizontal, 10).frame(height: 39)
    }
    private func applyPercent() {
        if let n = Double(percent), n.isFinite, (8...800).contains(n) { r.setZoom(.fixed, value: n / 100); zoomEntry = false }
        else { NSSound.beep() }
    }
}

struct FindBar: View {
    @ObservedObject var r: Reader
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(PaperStyle.muted)
            TextField(L("在论文中查找"), text: $r.query).textFieldStyle(.plain).focused($focused)
                .onChange(of: r.query) { _, _ in r.startSearch() }.onSubmit { r.stepHit(1) }
            if r.searching { ProgressView().controlSize(.small) }
            else if !r.query.isEmpty { Text(r.hits.isEmpty ? L("0 处") : "\(r.hitIndex + 1) / \(r.hits.count)").font(.system(size: 13).monospacedDigit()) }
            GlyphButton(symbol: "chevron.up", title: L("上一处")) { r.stepHit(-1) }.disabled(r.hits.isEmpty)
            GlyphButton(symbol: "chevron.down", title: L("下一处")) { r.stepHit(1) }.disabled(r.hits.isEmpty)
            GlyphButton(symbol: "xmark", title: L("关闭查找"), action: r.dismissFind)
        }.padding(.horizontal, 12).frame(height: 40).background(PaperStyle.surface).onAppear { focused = true }.onReceive(NotificationCenter.default.publisher(for: .focusFind)) { _ in focused = true }.onExitCommand(perform: r.dismissFind)
    }
}

struct SelectionLayout: Layout {
    let anchor: CGRect
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bar = subviews.first else { return }
        let fit = ProposedViewSize(width: max(1, bounds.width - 16), height: nil)
        let size = bar.sizeThatFits(fit)
        let center = Self.center(anchor: anchor, viewport: bounds.size, bar: size)
        bar.place(at: CGPoint(x: bounds.minX + center.x, y: bounds.minY + center.y),
                  anchor: .center, proposal: ProposedViewSize(size))
    }
    static func center(anchor: CGRect, viewport: CGSize, bar: CGSize) -> CGPoint {
        let margin: CGFloat = 8
        let x = min(max(margin, anchor.midX - bar.width / 2), max(margin, viewport.width - bar.width - margin))
        let above = anchor.minY - bar.height - margin
        let y = above >= margin ? above : min(anchor.maxY + margin, viewport.height - bar.height - margin)
        return CGPoint(x: x + bar.width / 2, y: max(margin, y) + bar.height / 2)
    }
}

struct SelectionBar: View {
    @ObservedObject var r: Reader
    @State private var palette = false
    var body: some View {
        HStack(spacing: 2) {
            if let hit = r.focusedHighlight {
                removeHighlight(hit.id)
            } else {
                if r.hasText && r.region == nil {
                    if let id = r.highlightForSelection() { removeHighlight(id) }
                    else { highlightPicker }
                }
                action(L("固定"), "pin") { panelChange { r.pin() } }
                if r.region != nil {
                    action(L("复制图片"), "doc.on.doc", r.copyRegion)
                } else {
                    action(L("问 AI"), "text.bubble", r.askSelection).disabled(r.sending)
                }
            }
        }.padding(4).fixedSize()
            .background(PaperStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PaperStyle.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
    private var highlightPicker: some View {
        action(L("高亮"), "highlighter") { palette.toggle() }
            .popover(isPresented: $palette) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(r.prefs.tags) { tag in
                        Button {
                            palette = false
                            r.highlight(tag)
                        } label: {
                            HStack {
                                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: tag.ink.color)).frame(width: 15, height: 11)
                                Text(tag.displayName)
                                Spacer()
                            }.padding(5).contentShape(Rectangle())
                        }.buttonStyle(ReaderButtonStyle())
                    }
                }.padding(8).frame(minWidth: 135)
            }
    }
    private func removeHighlight(_ id: UUID) -> some View {
        action(L("取消高亮"), "eraser") { r.cancelHighlight(id) }
            .accessibilityIdentifier("selection.removeHighlight")
    }
    private func action(_ name: String, _ symbol: String, _ block: @escaping () -> Void) -> some View {
        Button(action: block) {
            Label(name, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 7).frame(height: 26)
                .contentShape(Rectangle())
        }.buttonStyle(ReaderButtonStyle(radius: 5)).help(name)
    }
}

struct UnlockSheet: View {
    @ObservedObject var r: Reader
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("打开受保护的 PDF"), systemImage: "lock").font(.title3.bold())
            Text(r.locked?.0.lastPathComponent ?? "").lineLimit(2)
            SecureField(L("打开密码"), text: $password).onSubmit { r.unlock(password) }
            if r.passwordError { Text(L("密码不正确，请重试。")).foregroundStyle(.red) }
            HStack { Spacer(); Button(L("取消")) { r.locked = nil }; Button(L("打开")) { r.unlock(password) }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 360)
    }
}
