import SwiftUI

enum CardList { case pins, notes }

enum CardDeletion {
    case pin(Pin, Int)
    case note(Excerpt, Int)
    var panel: Panel {
        switch self { case .pin: .pins; case .note: .notes }
    }
}

struct CardReference: Equatable {
    var document: String
    var list: CardList
    var id: UUID
}

extension Reader {
    func cardReference(_ id: UUID, in list: CardList) -> CardReference {
        CardReference(document: key ?? "", list: list, id: id)
    }
    func renameCard(_ reference: CardReference, to name: String) {
        guard key == reference.document else { return }
        let trimmed = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? nil : trimmed
        switch reference.list {
        case .pins:
            guard let i = state.pins.firstIndex(where: { $0.id == reference.id }), state.pins[i].customTitle != title else { return }
            state.pins[i].customTitle = title
        case .notes:
            guard let i = state.excerpts.firstIndex(where: { $0.id == reference.id }), state.excerpts[i].customTitle != title else { return }
            state.excerpts[i].customTitle = title
        }
    }
    @discardableResult
    func moveCard(_ source: CardReference, relativeTo target: CardReference, after: Bool) -> Bool {
        guard source.document == key, target.document == key, source.list == target.list, source.id != target.id else { return false }
        let ids = source.list == .pins ? state.pins.map(\.id) : state.excerpts.map(\.id)
        guard let from = ids.firstIndex(of: source.id), let to = ids.firstIndex(of: target.id) else { return false }
        let destination = to + (after ? 1 : 0)
        guard destination != from && destination != from + 1 else { return true }
        if source.list == .pins { state.pins.move(fromOffsets: [from], toOffset: destination) }
        else { state.excerpts.move(fromOffsets: [from], toOffset: destination) }
        return true
    }
}

struct SidebarCard<Heading: View, Content: View, Actions: View>: View {
    let reference: CardReference
    let customTitle: String?
    let rename: (String) -> Void
    var tint: PinColor? = nil
    let collapsed: Bool
    let scale: Double
    let setScale: (Double) -> Void
    let toggle: () -> Void
    @ObservedObject var drag: CardDrag
    let commit: (CardReference, CardReference, Bool) -> Bool
    @ViewBuilder let heading: () -> Heading
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var scheme
    @State private var renaming = false
    @State private var hovered = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                heading()
                Spacer(minLength: 0)
                Menu {
                    Button(L("重命名")) { renaming = true }
                    Menu(L("卡片缩放")) {
                        ForEach([0.8, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                            Button { setScale(value) } label: {
                                if value == scale { Label(value.formatted(.percent), systemImage: "checkmark") }
                                else { Text(value, format: .percent) }
                            }
                        }
                    }
                    Divider()
                    actions()
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("卡片选项")).help(L("卡片选项"))
                    .opacity(hovered || voiceOver ? 1 : 0.28)
                GlyphButton(symbol: collapsed ? "chevron.right" : "chevron.down",
                            title: collapsed ? L("展开") : L("折叠"), action: toggle)
            }.padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 3)
            if !collapsed { content() }
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: 10)
            shape.fill(PaperStyle.surface.opacity(scheme == .dark ? 0.76 : 0.92))
            if let tint { shape.fill(Color(nsColor: tint.color).opacity(scheme == .dark ? 0.20 : 0.14)) }
        }
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(scheme == .dark ? 0.14 : 0.10), lineWidth: 0.7).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.045), radius: 2, y: 1)
        .opacity(drag.placement?.source == reference ? 0 : 1)
        .background {
            if drag.placement?.source == reference {
                RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.03))
                    .strokeBorder(PaperStyle.line.opacity(0.65), lineWidth: 0.5)
            }
        }
        .onHover { hovered = $0 }
        .overlay { CardMarker(reference: reference, drag: drag, commit: commit).allowsHitTesting(false) }
        .sheet(isPresented: $renaming) {
            EditTextSheet(title: L("重命名卡片"), initial: customTitle ?? "", multiline: false,
                          allowEmpty: true, prompt: L("卡片名称（留空使用默认名称）"), save: rename)
        }
    }
}

struct PinContent: View {
    let store: PinPreviewStore
    let pin: Pin
    let rotation: Int
    let aspect: CGFloat
    let scale: Double
    let enlarge: () -> Void
    @State private var zoom: CGFloat = 1
    @State private var reset = 0
    @State private var width: CGFloat = 248
    var body: some View {
        let displayWidth = max(1, min(width, 185 * aspect)) * scale
        ScrollView(.horizontal) {
            Button(action: enlarge) {
                PinArtwork(store: store, pin: pin, rotation: rotation, large: scale > 1 || zoom > 1) { image in
                    if let image {
                        PinThumbnailImage(image: image, reset: reset) { value in if zoom != value { zoom = value } }
                            .allowsHitTesting(false)
                    }
                    else { Rectangle().fill(Color.secondary.opacity(0.07)) }
                }.frame(width: displayWidth, height: displayWidth / aspect).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(L("放大便签")).help(bilingual("点击打开图片，Ctrl + 滚轮查看细节", "Open image · Ctrl-scroll to zoom")).frame(minWidth: width)
        }.scrollDisabled(displayWidth <= width)
            .frame(height: ceil(displayWidth / aspect))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 > 0 { width = $0 } }
            .overlay(alignment: .bottomTrailing) {
                if abs(zoom - 1) > 0.0001 {
                    Button { zoom = 1; reset += 1 } label: {
                        Label("\(Int((zoom * 100).rounded()))%", systemImage: "arrow.counterclockwise").font(.caption2.monospacedDigit())
                    }.buttonStyle(.bordered).controlSize(.mini).accessibilityLabel(bilingual("还原图片大小", "Reset image zoom")).help(bilingual("还原图片大小", "Reset image zoom")).padding(3)
                }
            }
            .onDisappear { zoom = 1 }
            .clipShape(RoundedRectangle(cornerRadius: 5)).padding(.horizontal, 8).padding(.bottom, 8)
    }
}
