import SwiftUI

// The native grab surface receives only chrome clicks. Editors, menus and buttons
// keep their own mouse events, including text selection by dragging.
private struct ComposerGrip: NSViewRepresentable {
    var moved: (CGSize, Bool) -> Void
    var clicked: () -> Void
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) { view.moved = moved; view.clicked = clicked }

    final class Handle: NSView {
        var moved: ((CGSize, Bool) -> Void)?
        var clicked: (() -> Void)?
        private var down = CGPoint.zero
        private var dragging = false
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
        override func mouseDown(with event: NSEvent) {
            NSCursor.arrow.set()
            down = event.locationInWindow; dragging = false
        }
        private func delta(_ event: NSEvent) -> CGSize {
            CGSize(width: event.locationInWindow.x - down.x, height: down.y - event.locationInWindow.y)
        }
        override func mouseDragged(with event: NSEvent) {
            let offset = delta(event)
            guard dragging || hypot(offset.width, offset.height) >= 3 else { return }
            dragging = true; moved?(offset, false)
        }
        override func mouseUp(with event: NSEvent) {
            if dragging { moved?(delta(event), true) }
            else { clicked?() }
            dragging = false
        }
    }
}

struct ThinkingIndicator: View {
    static var title: String { bilingual("思考中", "Thinking") }
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = scheme == .dark
        let ink = dark ? Color(red: 0.67, green: 0.84, blue: 0.98) : Color(red: 0.14, green: 0.34, blue: 0.54)
        let fill = dark ? Color(red: 0.16, green: 0.24, blue: 0.33) : Color(red: 0.87, green: 0.93, blue: 0.98)
        ZStack {
            Image(systemName: "bubble.left.fill").foregroundStyle(fill)
            Image(systemName: "bubble.left").foregroundStyle(ink.opacity(contrast == .increased ? 0.95 : 0.68))
            Group {
                if reduceMotion {
                    dots(time: nil)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 10)) { frame in
                        dots(time: frame.date.timeIntervalSinceReferenceDate)
                    }
                }
            }.fixedSize().foregroundStyle(ink).offset(y: -size * 0.055)
        }
        .font(.system(size: size * 0.76, weight: .regular))
        .frame(width: size, height: size)
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func dots(time: TimeInterval?) -> some View {
        HStack(spacing: size * 0.065) {
            ForEach(0..<3) { index in
                Circle().frame(width: size * 0.09, height: size * 0.09)
                    .opacity(dotOpacity(index, at: time))
            }
        }
    }

    private func dotOpacity(_ index: Int, at time: TimeInterval?) -> Double {
        guard let time else { return 1 }
        let phase = time.truncatingRemainder(dividingBy: 1.5) / 1.5 - Double(index) / 3
        let minimum = contrast == .increased ? 0.72 : 0.52
        return minimum + (1 - minimum) * (1 + cos(phase * 2 * .pi)) / 2
    }
}

struct ChatLauncherLabel: View {
    static let size = CGSize(width: 122, height: 46)
    let title: String
    let waiting: Bool
    let receivingDrop: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let onInk: Color = scheme == .dark ? .black : .white
        HStack(spacing: 9) {
            if waiting && !receivingDrop {
                ThinkingIndicator(size: 32)
            } else {
                ZStack {
                    Circle().fill(receivingDrop ? PaperStyle.accent : PaperStyle.text)
                    Image(systemName: receivingDrop ? "plus" : "text.bubble")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(receivingDrop ? .white : onInk)
                }.frame(width: 32, height: 32)
            }
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 7).padding(.trailing, 14)
        .frame(minWidth: Self.size.width).frame(height: Self.size.height)
        .fixedSize().contentShape(Capsule())
    }
}

struct FloatingChat: View {
    @ObservedObject var r: Reader
    @ObservedObject var drag: CardDrag
    @AppStorage("chatPositionX") private var x = 1.0
    @AppStorage("chatPositionY") private var y = 1.0
    @State private var translation = CGSize.zero
    @State private var panelSize = ChatLauncherLabel.size
    @State private var focusRequest = 0
    @State private var choosingModel = false
    @State private var fileTarget = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var preview = false
    @State private var previewMessages: [ChatLine] = []
    @State private var previewError = ""

    private let accent = Color(nsColor: .controlAccentColor)
    private var glass: Double { reduceTransparency ? 0 : r.glassStrength }
    private var waiting: Bool { r.sending && r.partialAnswer.isEmpty }
    private var heading: String {
        if drag.overChat { return bilingual("松开引用", "Drop here") }
        if waiting { return ThinkingIndicator.title }
        if r.sending { return bilingual("正在回答", "Answering") }
        return L("问 AI")
    }
    private var count: Int { r.attachments.count }
    private var scope: String {
        if r.wholePaper { return bilingual("全文", "Full paper") }
        if count > 0 { return bilingual("引用 · \(count)", "Sources · \(count)") }
        if r.includePage { return pageName(r.pageIndex) }
        if r.citation != nil { return bilingual("选区", "Selection") }
        return r.chat.isEmpty ? bilingual("引用范围", "Sources") : bilingual("对话上下文", "Conversation")
    }

    var body: some View {
        GeometryReader { geo in
            let width = min(324.0, max(1, geo.size.width - 24))
            let rangeX = max(0, geo.size.width - (r.composerOpen ? width : panelSize.width) - 24)
            let rangeY = max(0, geo.size.height - panelSize.height - 24)
            let grip = ComposerGrip { offset, ended in
                if ended {
                    if rangeX > 0 { x = min(1, max(0, x + offset.width / rangeX)) }
                    if rangeY > 0 { y = min(1, max(0, y + offset.height / rangeY)) }
                    translation = .zero
                } else { translation = offset }
            } clicked: { if !r.composerOpen { r.composerOpen = true } }
            let radius: CGFloat = r.composerOpen ? 14 : ChatLauncherLabel.size.height / 2
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            VStack(alignment: .leading, spacing: 0) {
                if r.composerOpen {
                    HStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Group {
                                if waiting {
                                    ThinkingIndicator(size: 22)
                                } else {
                                    Image(systemName: "text.bubble").font(.system(size: 14, weight: .semibold))
                                }
                            }.frame(width: 22, height: 22).foregroundStyle(accent)
                            Text(heading).font(.system(size: 13, weight: .semibold)).fixedSize()
                            Spacer(minLength: 0)
                        }.overlay { grip.help(bilingual("拖动以移动浮窗", "Drag to move")) }
                        sourceMenu
                        Button { r.composerOpen = false } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 26).contentShape(Rectangle())
                        }.buttonStyle(ReaderButtonStyle()).foregroundStyle(.secondary)
                            .accessibilityLabel(L("折叠"))
                    }.padding(.horizontal, 10).padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 8) {
                        if let cite = r.citation {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(cite.pages.map(pageName).joined(separator: ", "), systemImage: "text.quote")
                                    Spacer()
                                    Button { r.citation = nil } label: { Image(systemName: "xmark").frame(width: 18, height: 18) }
                                        .buttonStyle(ReaderButtonStyle()).disabled(r.sending).accessibilityLabel(bilingual("移除选区", "Remove selection"))
                                }.font(.caption.weight(.medium)).foregroundStyle(accent)
                                let quote = Text(verbatim: cite.text).font(InspectorType.detail)
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                quote.hidden().accessibilityHidden(true)
                                    .frame(maxHeight: min(132, geo.size.height * 0.22), alignment: .top).clipped()
                                    .overlay { ScrollView { quote.textSelection(.enabled) } }
                            }.padding(8).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                            HStack(spacing: 6) {
                                ForEach([("解释", "请解释这段文字。"), ("翻译", "请把这段文字翻译成中文。"), ("总结", "请用中文总结这段文字。")], id: \.0) { title, prompt in
                                    Button {
                                        r.question = L(prompt)
                                        focusRequest += 1
                                    } label: {
                                        Text(L(title)).lineLimit(1).frame(maxWidth: .infinity)
                                    }
                                    .hoverHighlight()
                                    .accessibilityIdentifier("selectionPrompt." + title)
                                }
                            }.buttonStyle(.bordered).controlSize(.regular).disabled(r.sending)
                        }
                        if count > 0 { sources }
                        ChatQuestionField(text: $r.question, pasteboard: r.imagePasteboard, editable: !r.sending, focusRequest: focusRequest,
                                          attach: r.attachFiles, submit: r.send)
                            .overlay(alignment: .topLeading) {
                                if r.question.isEmpty {
                                    Text(bilingual("输入问题…", "Ask a question…")).font(.system(size: 15))
                                        .foregroundStyle(.tertiary).allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                        if !r.chatError.isEmpty { Text(r.chatError).font(InspectorType.detail).foregroundStyle(.red).lineLimit(3).help(r.chatError) }
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                        .background(PaperStyle.surface.opacity(0.82 - 0.66 * glass), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.09), lineWidth: 0.6).allowsHitTesting(false) }
                        .padding(.horizontal, 7)
                    HStack(spacing: 8) {
                        Button {
                            if r.profile != nil { choosingModel = true }
                            else { r.settingsTab = .ai; r.settings = true }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "cpu")
                                Text(r.profile.map { $0.model.isEmpty ? bilingual("选择模型", "Choose model") : $0.model } ?? L("配置 AI 服务")).lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 8))
                            }.font(.system(size: 12, weight: .medium))
                        }.buttonStyle(ReaderButtonStyle()).foregroundStyle(.secondary).disabled(r.sending)
                            .popover(isPresented: $choosingModel) {
                                if let service = r.profile {
                                    ServiceModelPicker(service: service, fetch: {
                                        let models = try await AIClient.models(profile: service, key: r.serviceKey(for: service))
                                        try Task.checkCancellation()
                                        try r.cacheModels(models, for: service)
                                    }, select: { id in
                                        do { try r.selectModel(id, for: service.id); choosingModel = false }
                                        catch { r.chatError = error.localizedDescription }
                                    }, manage: { choosingModel = false; r.settingsTab = .ai; r.settings = true })
                                }
                            }
                        Spacer(minLength: 8)
                        GlyphButton(symbol: "paperclip", title: bilingual("添加文件", "Attach files")) { pickFiles() }
                            .disabled(r.sending)
                        GlyphButton(symbol: "eye", title: L("查看发送内容")) { previewError = ""; previewMessages = []; preview = true }
                            .disabled(r.importingFiles)
                        Button { if r.sending { r.stopAnswer() } else { r.send() } } label: {
                            Image(systemName: r.sending ? "stop.fill" : "arrow.up")
                                .font(.system(size: r.sending ? 11 : 14, weight: .bold)).frame(width: 25, height: 25)
                                .foregroundStyle(.white).background(accent, in: Circle())
                        }.buttonStyle(ReaderButtonStyle(radius: 13))
                            .disabled(!r.sending && !canSend)
                            .opacity(r.sending || canSend ? 1 : 0.54)
                            .help(r.sending ? bilingual("停止", "Stop") : L("发送"))
                            .accessibilityLabel(r.sending ? bilingual("停止", "Stop") : L("发送"))
                    }.padding(.horizontal, 10).padding(.vertical, 4)
                } else {
                    Button { r.composerOpen = true } label: {
                        ChatLauncherLabel(title: heading, waiting: waiting, receivingDrop: drag.overChat)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(heading)
                    .accessibilityHint(bilingual("展开提问框", "Open question field"))
                    .overlay { grip.accessibilityHidden(true) }
                    .hoverHighlight(radius: radius)
                    .help(bilingual("点按提问，拖动可移动", "Click to ask, drag to move"))
                }
            }.frame(width: r.composerOpen ? width : nil)
                .background { if r.composerOpen { grip } }
                .background {
                    PaperGlass(strength: glass, corner: radius)
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(drag.overChat || fileTarget ? accent : Color.primary.opacity(0.17), lineWidth: drag.overChat || fileTarget ? 2 : 0.7).allowsHitTesting(false) }
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !r.sending, !files.isEmpty else { return false }
                    r.attachFiles(files.map(ChatFile.Input.file))
                    return true
                } isTargeted: { fileTarget = $0 && !r.sending }
                .shadow(color: .black.opacity(scheme == .dark ? 0.26 : 0.12), radius: r.composerOpen ? 8 : 4, y: r.composerOpen ? 3 : 2)
                .background { if !r.sending { TrashMarker(chat: true, drag: drag, remove: r.attachCard) } }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
                .offset(x: 12 + min(rangeX, max(0, x * rangeX + translation.width)),
                        y: 12 + min(rangeY, max(0, y * rangeY + translation.height)))
        }
        .onChange(of: r.composerOpen) { if r.composerOpen { focusRequest += 1 } }
        .onChange(of: count) { if r.composerOpen { focusRequest += 1 } }
        .sheet(isPresented: $preview, onDismiss: { previewMessages = []; previewError = "" }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("发送内容")).font(.headline)
                Text(r.profile?.title ?? L("尚未选择服务"))
                Text(r.profile?.base ?? "").font(.caption)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(previewMessages) { line in
                            Text(line.text).textSelection(.enabled)
                            ForEach(Array((line.images ?? []).enumerated()), id: \.offset) { _, data in
                                if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
                            }
                        }
                        if !previewError.isEmpty { Text(previewError).foregroundStyle(.red) }
                        else if previewMessages.isEmpty { ProgressView().controlSize(.small) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(L("完成")) { preview = false }.keyboardShortcut(.cancelAction)
            }.padding(18).frame(width: 460, height: 440).task {
                do {
                    let messages = try await r.outgoingMessages()
                    if !Task.isCancelled { previewMessages = messages }
                } catch { if !Task.isCancelled { previewError = error.localizedDescription } }
            }
        }
    }

    private var canSend: Bool {
        r.profile?.model.isEmpty == false && !r.importingFiles && r.hasQuestionInput
    }
    private func pickFiles() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ChatFile.contentTypes
        let session = r.conversationID
        panel.beginSheetModal(for: window) { result in
            if result == .OK && r.conversationID == session { r.attachFiles(panel.urls.map(ChatFile.Input.file)) }
        }
    }
    private var sourceMenu: some View {
        Menu {
            Toggle(bilingual("引用全文文字", "Include full paper text"), isOn: Binding(get: { r.wholePaper }, set: { full in
                r.wholePaper = full
                if full { r.citation = nil; r.includePage = false }
            }))
            if !r.wholePaper { Toggle(bilingual("附加当前页", "Include current page"), isOn: $r.includePage) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: r.wholePaper ? "doc.text" : "paperclip")
                Text(scope).lineLimit(1)
                if !r.sending { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).frame(height: 23)
                .background(Color.primary.opacity(0.055), in: Capsule())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverHighlight(radius: 12).disabled(r.sending)
    }
    private var sources: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(r.attachments) { source in
                    let symbol = switch source.content { case .passage: "highlighter"; case .clip: "pin"; case .loading: "clock"; case .file: "paperclip" }
                    chip(symbol, source.label) { r.removeAttachment(source.id) }
                }
            }
        }.scrollIndicators(.hidden)
    }
    private func chip(_ symbol: String, _ title: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title).lineLimit(1).frame(maxWidth: 140)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).frame(width: 16, height: 20) }
                .buttonStyle(ReaderButtonStyle()).accessibilityLabel(bilingual("移除引用", "Remove attachment"))
        }.font(.system(size: 12, weight: .medium)).foregroundStyle(accent).padding(.leading, 8).padding(.trailing, 3)
            .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6)).help(title).disabled(r.sending)
    }
}
