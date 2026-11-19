import SwiftUI
import PDFKit

struct NavigationPane: View {
    @ObservedObject var r: Reader
    @State private var editing: Bookmark?
    var body: some View {
        VStack(spacing: 0) {
            SidebarTabs(items: NavigationTab.allCases, selection: r.nav, title: { L($0.rawValue) },
                        icon: { tab in
                            switch tab { case .pages: "rectangle.on.rectangle"; case .outline: "list.bullet"; case .marks: "bookmark" }
                        }, select: { r.nav = $0 })
            Divider()
            switch r.nav {
            case .pages:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 9) {
                            ForEach(0..<(r.document?.pageCount ?? 0), id: \.self) { i in
                                PageThumb(r: r, index: i).id(i)
                            }
                        }.padding(9)
                    }.onAppear { proxy.scrollTo(r.pageIndex, anchor: .center) }
                        .onChange(of: r.pageIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
                }
            case .outline:
                if let root = r.document?.outlineRoot, root.numberOfChildren > 0 {
                    ScrollView { VStack(alignment: .leading, spacing: 7) { OutlineChildren(r: r, item: root) }.frame(maxWidth: .infinity, alignment: .leading).padding(9) }
                } else { SectionEmpty(symbol: "list.bullet.indent", title: L("没有内置目录"), detail: L("可通过页面或书签定位。")) }
            case .marks:
                if r.state.bookmarks.isEmpty { SectionEmpty(symbol: "bookmark", title: L("还没有书签"), detail: bilingual("点更多菜单中的「添加书签」，或按 ⌘D。", "Choose Add bookmark from More, or press ⌘D.")) }
                else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(r.state.bookmarks) { mark in
                                HStack(spacing: 8) {
                                    Button { r.go(mark.page, point: mark.point) } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(mark.displayName).lineLimit(2)
                                            Text(pageName(mark.page)).font(.caption).foregroundStyle(PaperStyle.muted)
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(ReaderButtonStyle())
                                    Menu {
                                        Button(L("重命名")) { editing = mark }
                                        Button(L("删除书签")) { r.state.bookmarks.removeAll { $0.id == mark.id } }
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                }.padding(11).sidebarCardSurface()
                            }
                        }.padding(9)
                    }
                }
            }
            Spacer(minLength: 0)
        }.background(SidebarSurface(strength: r.glassStrength)).sheet(item: $editing) { mark in
            EditTextSheet(title: L("重命名书签"), initial: mark.displayName, multiline: false) { text in
                if let index = r.state.bookmarks.firstIndex(where: { $0.id == mark.id }) { r.state.bookmarks[index].name = text; r.state.bookmarks[index].automatic = false }
            }
        }
    }
}
private struct PageThumb: View {
    @ObservedObject var r: Reader
    let index: Int
    @State private var image: CGImage?
    var body: some View {
        let request = PageThumbnailRequest(page: index, rotation: r.state.rotations[index], marksRevision: r.thumbnailMarksRevision)
        Button { r.go(index) } label: {
            VStack(spacing: 7) {
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() } else { Rectangle().fill(.white.opacity(0.7)) }
                }.frame(width: 122, height: 150)
                    .padding(3).background(.white).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                Text(pageName(index)).font(InspectorType.detail.monospacedDigit()).foregroundStyle(r.pageIndex == index ? Color.blue : PaperStyle.muted)
            }.padding(.vertical, 8).frame(maxWidth: .infinity).sidebarCardSurface()
                .overlay { if r.pageIndex == index { RoundedRectangle(cornerRadius: 10).strokeBorder(.blue.opacity(0.55), lineWidth: 1) } }
        }.buttonStyle(ReaderButtonStyle(radius: 10)).accessibilityLabel(pageName(index))
            .task(id: request) {
                let result = await r.pageThumbnails?.image(for: request, excerpts: r.state.excerpts, tags: r.prefs.tags, deleted: r.state.deletedHighlights ?? [])
                if !Task.isCancelled { image = result }
            }.onDisappear { image = nil }
    }
}

private struct OutlineChildren: View {
    @ObservedObject var r: Reader
    let item: PDFOutline
    var body: some View {
        ForEach(0..<item.numberOfChildren, id: \.self) { index in
            if let child = item.child(at: index) { OutlineRow(r: r, item: child) }
        }
    }
}
private struct OutlineRow: View {
    @ObservedObject var r: Reader
    let item: PDFOutline
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if item.numberOfChildren > 0 {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 13)
                    }.buttonStyle(ReaderButtonStyle()).accessibilityLabel(L("展开或收起章节"))
                }
                Button {
                    if let d = item.destination { r.pdf?.go(to: d) } else if let action = item.action { r.pdf?.perform(action) } else { expanded.toggle() }
                } label: { Text(item.label ?? L("未命名章节")).multilineTextAlignment(.leading).lineLimit(3).padding(.vertical, 4) }.buttonStyle(ReaderButtonStyle())
            }
            if expanded { OutlineChildren(r: r, item: item).padding(.leading, 8) }
        }.padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            .background { if item.parent?.parent == nil { RoundedRectangle(cornerRadius: 9).fill(PaperStyle.surface) } }
    }
}

struct Inspector: View {
    @ObservedObject var r: Reader
    @ObservedObject var drag: CardDrag
    @State private var enlarged: Pin?
    @State private var coloring: Pin?
    @State private var editing: Excerpt?
    @State private var editingPin: Pin?
    @State private var filter: UUID?
    @State private var noteSearch = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarTabs(items: Panel.allCases, selection: r.panel,
                        title: { $0 == .chat ? bilingual("对话", "Chat") : $0 == .notes ? bilingual("批注", "Marks") : L($0.rawValue) },
                        icon: { $0 == .pins ? "pin" : $0 == .notes ? "highlighter" : "bubble.left.and.bubble.right" },
                        count: { $0 == .notes ? r.state.excerpts.count : $0 == .pins ? r.state.pins.count : nil }) { panel in
                if panel == .chat { r.composerOpen = true }
                r.panel = panel
            }
            Group {
                switch r.panel {
                case .pins: pins
                case .notes: notes
                case .chat: ChatPane(r: r)
                }
            }
            if let deletion = r.lastDeletion, deletion.panel == r.panel, drag.placement == nil {
                Divider()
                HStack {
                    Text(L(deletion.panel == .pins ? "便签已删除" : "批注已删除")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("撤销"), action: r.undoCardDeletion)
                    Button(action: r.dismissCardDeletion) { Image(systemName: "xmark") }
                        .buttonStyle(ReaderButtonStyle()).accessibilityLabel(L("关闭"))
                }.font(InspectorType.detail).padding(.horizontal, 12).frame(height: 36)
            }
        }.background { SidebarSurface(strength: r.glassStrength) }.overlay(alignment: .trailing) {
            if r.panel != .chat {
                TrashMarker(drag: drag, remove: r.deleteCard)
                    .frame(width: CardDeletionFeedback.edgeWidth).frame(maxHeight: .infinity)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }.font(InspectorType.control).frame(maxHeight: .infinity, alignment: .top)
            .onDisappear { drag.cancel() }
            .onChange(of: r.key) { drag.cancel(); enlarged = nil; filter = nil; noteSearch = "" }
            .onChange(of: r.panel) { drag.cancel() }
            .onChange(of: filter) { drag.cancel() }
            .onChange(of: r.prefs.tags) {
                if let filter, !r.prefs.tags.contains(where: { $0.id == filter }) { self.filter = nil }
            }
            .sheet(item: $enlarged) { pin in
                PinDrawingEditor(r: r, reference: r.cardReference(pin.id, in: .pins)) { enlarged = nil }
            }.sheet(item: $coloring) { pin in
                if let key = r.key {
                    PinColorEditor(r: r, reference: CardReference(document: key, list: .pins, id: pin.id))
                }
            }.sheet(item: $editingPin) { pin in
                EditTextSheet(title: L("编辑个人备注"), initial: pin.note ?? "", multiline: true, editorFont: r.memoFont) { text in
                    r.setPinNote(pin.id, text: text)
                }
            }.sheet(item: $editing) { note in
                EditTextSheet(title: L("编辑个人备注"), initial: note.note, multiline: true, editorFont: r.memoFont) { text in
                    r.setNote(note.id, text: text)
                }
            }.onChange(of: r.state.excerpts.count) { old, new in if new > old { filter = nil } }
    }
    @ViewBuilder private var pins: some View {
        if r.state.pins.isEmpty {
            SectionEmpty(symbol: "pin", title: L("还没有便签"), detail: L("用右上角的虚线框选中图表。\n点「固定」后，翻页时也能对照。"))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(drag.arrange(r.state.pins)) { pin in
                            let ref = r.cardReference(pin.id, in: .pins)
                            SidebarCard(reference: ref, customTitle: pin.customTitle, rename: { r.renameCard(ref, to: $0) },
                                        tint: pin.color, collapsed: pin.collapsed, scale: pin.cardScale ?? 1, setScale: { size in
                                if let i = r.state.pins.firstIndex(where: { $0.id == pin.id }) { r.state.pins[i].cardScale = size }
                            }, toggle: {
                                if let i = r.state.pins.firstIndex(where: { $0.id == pin.id }) { r.state.pins[i].collapsed.toggle() }
                            }, drag: drag, commit: r.moveCard) {
                                if let title = pin.customTitle {
                                    Text(title).font(InspectorType.control.weight(.semibold)).lineLimit(1).help(title)
                                }
                                Button { r.go(pin.source) } label: {
                                    Label(pageName(pin.source.page), systemImage: "arrow.up.left").font(InspectorType.detail.weight(.medium))
                                }.buttonStyle(ReaderButtonStyle()).foregroundStyle(PaperStyle.accent).fixedSize()
                                Button { editingPin = pin } label: {
                                    Image(systemName: "square.and.pencil").frame(width: 24, height: 24)
                                }.buttonStyle(ReaderButtonStyle()).foregroundStyle(.secondary)
                                    .help(L("编辑备注")).accessibilityLabel(L("编辑备注"))
                            } content: {
                                if let store = r.pinPreviews {
                                    let page = r.document?.safePage(pin.source.page)
                                    let rotation = r.state.rotations[pin.source.page] ?? page?.rotation ?? 0
                                    let rect = pin.source.rect.intersection(page?.pageRef?.getBoxRect(.cropBox) ?? pin.source.rect)
                                    let ratio = max(1, rect.width) / max(1, rect.height)
                                    PinContent(store: store, pin: pin, rotation: rotation, aspect: rotation % 180 == 0 ? ratio : 1 / ratio,
                                               scale: pin.cardScale ?? 1) { enlarged = pin }
                                        .contextMenu { Button(L("复制图片")) { r.copyPin(pin.id) } }
                                }
                                if let note = pin.note {
                                    SidebarMemo(text: note, date: pin.noteEditedAt, font: r.memoFont) { editingPin = pin }
                                        .padding(.horizontal, 10).padding(.bottom, 10)
                                }
                            } actions: {
                                Button(L("编辑备注")) { editingPin = pin }
                                Button(L("卡片颜色…")) { coloring = pin }
                                moveCommands(ref, ids: r.state.pins.map(\.id))
                                Divider()
                                Button(bilingual("标注图片…", "Mark Up Image…")) { enlarged = pin }
                                Button(L("放大便签")) { enlarged = pin }
                                Button(L("复制图片")) { r.copyPin(pin.id) }
                                Button(L("移除便签")) { r.deleteCard(ref) }
                            }.id(pin.id).transition(.opacity)
                        }
                    }.padding(10)
                }.onChange(of: r.state.pins.count) { old, new in
                    if new > old, let last = r.state.pins.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
    @ViewBuilder private func moveCommands(_ ref: CardReference, ids: [UUID]) -> some View {
        if let index = ids.firstIndex(of: ref.id) {
            Button(L("上移")) {
                r.moveCard(ref, relativeTo: r.cardReference(ids[index - 1], in: ref.list), after: false)
            }.disabled(index == 0)
            Button(L("下移")) {
                r.moveCard(ref, relativeTo: r.cardReference(ids[index + 1], in: ref.list), after: true)
            }.disabled(index + 1 >= ids.count)
        }
    }
    @ViewBuilder private var notes: some View {
        if r.state.excerpts.isEmpty && !r.highlightsLoaded {
            ProgressView(L("正在读取批注…")).controlSize(.small).padding()
        } else if r.state.excerpts.isEmpty {
            SectionEmpty(symbol: "highlighter", title: L("还没有批注"), detail: L("选中文字并高亮后，可以在批注下写备注。"))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(bilingual("搜索批注…", "Search annotations…"), text: $noteSearch).textFieldStyle(.plain)
                    }.font(InspectorType.detail).padding(.horizontal, 9).frame(height: 29).sidebarFieldSurface()
                    Menu {
                        Picker(L("标签"), selection: $filter) {
                            Text(L("全部标签")).tag(nil as UUID?)
                            ForEach(r.prefs.tags) { tag in Text(tag.displayName).tag(Optional(tag.id)) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(r.prefs.tags.first { $0.id == filter }?.displayName ?? L("全部标签")).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2)
                        }.padding(.horizontal, 8).frame(height: 29).sidebarFieldSurface()
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .padding(.horizontal, 7).frame(height: 29).sidebarFieldSurface()
                }.padding(.horizontal, 9).padding(.bottom, 10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        let entries = r.state.excerpts.filter { entry in
                            (filter == nil || entry.tag == filter) && entry.matches(noteSearch)
                        }
                        ForEach(drag.arrange(entries)) { entry in
                            let tag = r.prefs.tags.first { $0.id == entry.tag }
                            let ref = r.cardReference(entry.id, in: .notes)
                            let size = entry.cardScale ?? 1
                            SidebarCard(reference: ref, customTitle: entry.customTitle, rename: { r.renameCard(ref, to: $0) },
                                        collapsed: entry.collapsed ?? false, scale: size, setScale: { value in
                                if let i = r.state.excerpts.firstIndex(where: { $0.id == entry.id }) { r.state.excerpts[i].cardScale = value }
                            }, toggle: {
                                if let i = r.state.excerpts.firstIndex(where: { $0.id == entry.id }) { r.state.excerpts[i].collapsed = !(entry.collapsed ?? false) }
                            }, drag: drag, commit: r.moveCard) {
                                HStack(spacing: 6) {
                                    if let tag { Circle().fill(Color(nsColor: tag.ink.color)).frame(width: 7, height: 7) }
                                    else { Image(systemName: "note.text").foregroundStyle(.secondary) }
                                    if let title = entry.customTitle {
                                        Text(title).font(InspectorType.control.weight(.semibold)).lineLimit(1).help(title).layoutPriority(1)
                                        if let tag { Text("· " + tag.displayName).font(InspectorType.detail).foregroundStyle(.secondary).lineLimit(1) }
                                    } else {
                                        Text(tag?.displayName ?? L("批注")).font(InspectorType.detail.weight(.semibold)).lineLimit(1)
                                    }
                                    if entry.collapsed == true, let line = entry.lines.first {
                                        Text("· " + String(line.page + 1)).font(InspectorType.detail).foregroundStyle(.secondary)
                                    }
                                }
                            } content: {
                                VStack(alignment: .leading, spacing: 9) {
                                    if !entry.text.isEmpty {
                                        AnnotationPassage(text: entry.text, scale: size)
                                    }
                                    if !entry.note.isEmpty {
                                        SidebarMemo(text: entry.note, date: entry.noteEditedAt, font: r.memoFont) { editing = entry }
                                    }
                                    Divider()
                                    HStack(spacing: 6) {
                                        if let anchor = entry.lines.first {
                                            Button {
                                                r.setRegionMode(false)
                                                r.go(anchor)
                                                r.focusHighlight(HighlightHit(id: entry.id, line: anchor))
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Text(pageName(anchor.page))
                                                    Image(systemName: "arrow.up.right").font(.caption)
                                                }
                                            }.buttonStyle(ReaderButtonStyle()).foregroundStyle(.blue)
                                        }
                                        Spacer(minLength: 0)
                                        if entry.note.isEmpty {
                                            Button { editing = entry } label: {
                                                Label(bilingual("添加备注", "Add comment"), systemImage: "pencil")
                                            }.buttonStyle(ReaderButtonStyle()).foregroundStyle(.secondary)
                                        } else {
                                            Text("ID: #ANN-" + entry.id.uuidString.prefix(6))
                                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                        }
                                    }.font(.system(size: 13))
                                }.padding(.horizontal, 13).padding(.bottom, 12)
                            } actions: {
                                moveCommands(ref, ids: entries.map(\.id))
                                Divider()
                                Menu(L("更改标签")) {
                                    ForEach(r.prefs.tags) { tag in
                                        Button { r.assignTag(tag.id, to: entry.id) } label: {
                                            if entry.tag == tag.id { Label(tag.displayName, systemImage: "checkmark") }
                                            else { Text(tag.displayName) }
                                        }
                                    }
                                }
                                Button(L("编辑备注")) { editing = entry }
                                Button(L("删除批注"), role: .destructive) { r.deleteCard(ref) }
                                    .help(L("取消高亮"))
                            }
                        }
                        if entries.isEmpty {
                            Text(L(noteSearch.isEmpty ? "此标签还没有批注。" : "没有匹配的批注。")).font(InspectorType.detail).foregroundStyle(PaperStyle.muted).padding(8)
                        }
                    }.padding(.horizontal, 9).padding(.top, 11).padding(.bottom, 12)
                }
            }
        }
    }
}

private struct AnnotationPassage: View {
    let text: String
    let scale: Double
    @State private var expanded = false
    @State private var visibleHeight: CGFloat = 0
    @State private var measuredHeight: CGFloat = 0

    private func passage(limit: Int?) -> some View {
        Text(verbatim: text).font(.system(size: 15 * scale)).lineSpacing(3)
            .lineLimit(limit).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var disclosure: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 4) {
                Text(expanded ? bilingual("收起全文", "Show less") : bilingual("展开全文", "Show full text"))
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
            }.font(.system(size: 13, weight: .medium)).padding(.vertical, 3)
        }.buttonStyle(ReaderButtonStyle()).foregroundStyle(PaperStyle.accent)
    }
    var body: some View {
        let overflows = abs(measuredHeight - visibleHeight) > 1
        VStack(alignment: .leading, spacing: 3) {
            if expanded && overflows { disclosure }
            passage(limit: expanded ? nil : 5)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
                .background(alignment: .topLeading) {
                    // One extra line detects truncation without laying out a long excerpt in full.
                    passage(limit: expanded ? 5 : 6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeight = $0 }
                        .hidden().accessibilityHidden(true).allowsHitTesting(false)
                }
            if !expanded && overflows { disclosure }
        }
    }
}

private struct SidebarMemo: View {
    let text: String
    let date: Date?
    let font: Font
    let edit: () -> Void
    var body: some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left").foregroundStyle(.orange)
                    Text(bilingual("我的思考", "My thoughts"))
                    Spacer(minLength: 0)
                    if let date {
                        Text(date.formatted(.dateTime.month().day().hour().minute())).lineLimit(1)
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                Text(verbatim: text).font(font)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading).sidebarFieldSurface()
        }.buttonStyle(ReaderButtonStyle()).help(L("编辑备注"))
    }
}

struct EditTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let multiline: Bool
    let editorFont: Font
    let allowEmpty: Bool
    let prompt: String
    let save: (String) -> Void
    @State private var text: String
    init(title: String, initial: String, multiline: Bool, editorFont: Font = .body, allowEmpty: Bool? = nil, prompt: String = L("书签名称"), save: @escaping (String) -> Void) {
        self.title = title; self.multiline = multiline; self.allowEmpty = allowEmpty ?? multiline; self.prompt = prompt; self.save = save; _text = State(initialValue: initial)
        self.editorFont = editorFont
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            if multiline { TextEditor(text: $text).font(editorFont).frame(height: 110).border(PaperStyle.line) }
            else { TextField(prompt, text: $text) }
            HStack { Spacer(); Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction); Button(L("保存")) { save(text); dismiss() }.disabled(!allowEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 360)
    }
}

// Register the native transcript viewport so embedded WebKit answers cannot consume vertical wheel events.
struct TranscriptScrollMarker: NSViewRepresentable {
    let conversation: UUID
    let sending: Bool
    let showsPrompts: Bool

    final class Marker: NSView {
        private var readingY: CGFloat?
        private var pending = false
        private weak var observedDocument: NSView?
        private var conversation: UUID?
        private var sending = false
        private var showsPrompts = false
        var trackingScroller = false
        var awaitingJump: UUID?

        func update(conversation: UUID, sending: Bool, showsPrompts: Bool) {
            if conversation != self.conversation || (sending && !self.sending) || showsPrompts != self.showsPrompts {
                readingY = showsPrompts ? 0 : nil
                awaitingJump = nil
                scheduleLayout()
            }
            self.conversation = conversation
            self.sending = sending
            self.showsPrompts = showsPrompts
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? ReaderWindow)?.transcriptMarker = self
            scheduleLayout()
        }
        override func setFrameSize(_ size: NSSize) {
            let changed = size != frame.size
            super.setFrameSize(size)
            if changed { scheduleLayout() }
        }
        func rememberPosition() {
            guard let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            let bottom = bottomOrigin(scroll)
            readingY = clip.bounds.minY < bottom - 3 ? clip.bounds.minY : nil
        }
        func land(on target: NSView, id: UUID) -> Bool {
            guard awaitingJump == id, let scroll = enclosingScrollView, let doc = scroll.documentView,
                  target.window === window, target.isDescendant(of: doc), target.bounds.height > 0 else { return false }
            let box = doc.convert(target.bounds, from: target), clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin.y = doc.isFlipped ? box.minY - 10 : box.maxY - bounds.height + 10
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
            awaitingJump = nil
            rememberPosition()
            return true
        }
        private func bottomOrigin(_ scroll: NSScrollView) -> CGFloat {
            var bounds = scroll.contentView.bounds
            bounds.origin.y = scroll.documentView?.frame.maxY ?? bounds.minY
            return scroll.contentView.constrainBoundsRect(bounds).minY
        }
        @objc private func documentChanged(_ note: Notification) { scheduleLayout() }
        private func scheduleLayout() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in self?.applyLayout() }
        }
        private func applyLayout() {
            pending = false
            guard window != nil, let scroll = enclosingScrollView, let doc = scroll.documentView else { return }
            if observedDocument !== doc {
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: observedDocument)
                observedDocument = doc
                doc.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(documentChanged(_:)),
                                                       name: NSView.frameDidChangeNotification, object: doc)
            }
            guard !trackingScroller, awaitingJump == nil else { return }
            let clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin.y = readingY ?? bottomOrigin(scroll)
            let origin = clip.constrainBoundsRect(bounds).origin
            if abs(origin.y - clip.bounds.minY) > 0.5 {
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
            }
        }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.update(conversation: conversation, sending: sending, showsPrompts: showsPrompts) }
}
struct ChatPane: View {
    @ObservedObject var r: Reader
    @State private var deleting: UUID?
    @State private var selectedTurn: UUID?
    @State private var jump: UUID?
    @State private var editingPrompts = false
    private var scrollMarker: TranscriptScrollMarker.Marker? { (r.pdf?.window as? ReaderWindow)?.transcriptMarker }
    @ViewBuilder private func anchor(_ id: UUID) -> some View {
        if jump == id {
            ChatJumpAnchor(id: id) { landed in if jump == landed { jump = nil } }
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    var body: some View {
        let turns = r.chat.filter { $0.role == "user" } + (r.pendingTurn.map { [$0] } ?? [])
        let showsPrompts = r.chat.isEmpty && !r.sending && r.citation == nil && r.attachments.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    ForEach(r.conversations) { session in
                        Button(session.title) { r.openChat(session) }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        Text(r.conversations.first { $0.id == r.conversationID }?.title ?? bilingual("聊天记录", "Chat history"))
                            .font(InspectorType.control).lineLimit(1)
                    }
                }.menuStyle(.borderlessButton).disabled(r.conversations.isEmpty)
                Spacer(minLength: 0)
                Button { editingPrompts = true } label: {
                    Text(bilingual("提示词", "Prompts")).font(InspectorType.control).fixedSize().padding(.horizontal, 7).frame(height: 29)
                }.buttonStyle(ReaderButtonStyle()).help(bilingual("编辑全文提示词", "Edit full-paper prompts"))
                GlyphButton(symbol: "plus", title: bilingual("新对话", "New chat")) { r.resetChat(); r.composerOpen = true }
                if r.conversations.contains(where: { $0.id == r.conversationID }) {
                    GlyphButton(symbol: "trash", title: bilingual("删除对话", "Delete chat")) { deleting = r.conversationID }
                }
            }.padding(10)
            Divider()
            HStack(spacing: 0) {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if showsPrompts {
                                ForEach(r.paperPrompts) { prompt in
                                    Button {
                                        r.wholePaper = true; r.question = prompt.displayText; r.composerOpen = true
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text(verbatim: prompt.displayText).lineLimit(3).multilineTextAlignment(.leading)
                                            Spacer()
                                            Image(systemName: "arrow.up.left").font(.caption).accessibilityHidden(true)
                                        }.font(InspectorType.detail).padding(11)
                                            .background(PaperStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                                            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(PaperStyle.line, lineWidth: 0.5) }
                                    }.buttonStyle(ReaderButtonStyle())
                                }
                            }
                            ForEach(r.chat) { line in
                                bubble(line.role, line.text, selection: line.selection, time: line.createdAt).contextMenu {
                                    if line.role == "user" {
                                        Button(bilingual("删除这轮问答", "Delete this exchange"), role: .destructive) { r.deleteExchange(line.id) }
                                            .disabled(r.sending)
                                    }
                                }
                                .background { anchor(line.id) }.id(line.id)
                            }
                            if !r.sending, let pending = r.citation {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(bilingual("待发送的选区", "Selected for your next question")).font(InspectorType.control)
                                    SourceChips(r: r, cite: pending)
                                    Text(verbatim: pending.text).font(InspectorType.detail).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                            }
                            if r.sending {
                                if let turn = r.pendingTurn {
                                    bubble("user", turn.text, selection: turn.selection, time: turn.createdAt).background { anchor(turn.id) }.id(turn.id)
                                } else { bubble("user", r.question, selection: r.citation) }
                                if r.partialAnswer.isEmpty {
                                    HStack(spacing: 6) {
                                        ThinkingIndicator(size: 22)
                                        Text(ThinkingIndicator.title).font(InspectorType.detail).foregroundStyle(.secondary)
                                    }
                                }
                                else { bubble("assistant", r.partialAnswer) }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background { TranscriptScrollMarker(conversation: r.conversationID, sending: r.sending, showsPrompts: showsPrompts) }
                    }.onChange(of: jump) { _, id in
                        if let id { reader.scrollTo(id, anchor: .top) }
                    }
                }
                if !turns.isEmpty {
                    ChatTimeline(turns: turns, selected: selectedTurn) { id in
                        selectedTurn = id
                        scrollMarker?.awaitingJump = id
                        jump = id
                    }
                }
            }
            .onChange(of: r.conversationID) { _, _ in selectedTurn = nil; jump = nil; scrollMarker?.awaitingJump = nil }
            .onChange(of: turns.map(\.id)) { _, ids in
                if let selectedTurn, !ids.contains(selectedTurn) { self.selectedTurn = nil }
                if let jump, !ids.contains(jump) { self.jump = nil; scrollMarker?.awaitingJump = nil }
            }
            if r.sending { Button(bilingual("停止回答", "Stop response"), action: r.stopAnswer).padding(8) }
        }.sheet(isPresented: $editingPrompts) {
            PaperPromptEditor(prompts: r.paperPrompts, save: r.savePaperPrompts)
        }.alert(bilingual("删除这段对话？", "Delete this conversation?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("删除"), role: .destructive) { if let deleting { r.deleteChat(deleting) } }
            Button(L("取消"), role: .cancel) {}
        }
    }
    private func bubble(_ role: String, _ text: String, selection: Citation? = nil, time: Date? = nil) -> some View {
        let user = role == "user"
        return VStack(alignment: user ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: user ? "person" : "text.bubble.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 21, height: 21)
                    .background((user ? Color.secondary : PaperStyle.accent).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                Text(user ? L("提问") : L("回答")).font(.system(size: 13, weight: .semibold))
                if user, let time {
                    Text(time, format: .dateTime.hour().minute()).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }.foregroundStyle(user ? PaperStyle.muted : PaperStyle.text)
            if let selection {
                VStack(alignment: .leading, spacing: 5) {
                    SourceChips(r: r, cite: selection)
                    Text(verbatim: selection.text).font(InspectorType.detail).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.leading, 9).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { Rectangle().fill(PaperStyle.accent.opacity(0.5)).frame(width: 2) }
            }
            Group {
                if user { Text(text).textSelection(.enabled).font(InspectorType.reading).lineSpacing(4) }
                else { MathAnswer(text: text) }
            }
                .padding(.horizontal, user ? 10 : 0).padding(.vertical, user ? 8 : 0)
                .background { if user { RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.055)) } }
        }.padding(.leading, user ? 18 : 0)
            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)

    }
}
private struct SourceChips: View {
    @ObservedObject var r: Reader
    let cite: Citation
    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(cite.pages, id: \.self) { page in
                    Button { if let a = cite.anchors.first(where: { $0.page == page }) { r.go(a) } } label: {
                        Label(pageName(page), systemImage: "arrow.up.left").font(InspectorType.detail)
                    }.buttonStyle(ReaderButtonStyle()).foregroundStyle(PaperStyle.accent)
                }
            }
        }.scrollIndicators(.hidden)
    }
}
