import SwiftUI

struct ChatTimeline: View {
    let turns: [ChatLine]
    let selected: UUID?
    let choose: (UUID) -> Void
    @Environment(\.locale) private var locale
    @State private var hover: UUID?

    private func label(for turn: ChatLine, number: Int) -> String {
        let title = turn.createdAt.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)) }
            ?? bilingual("第 \(number) 轮提问", "Question \(number)")
        return title + " · " + turn.bubbleText.prefix(100)
    }
    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                    let active = selected == turn.id
                    let label = label(for: turn, number: index + 1)
                    Button { choose(turn.id) } label: {
                        ZStack {
                            Rectangle().fill(PaperStyle.line.opacity(0.55)).frame(width: 1)
                                .padding(.top, index == 0 ? 12 : 0)
                                .padding(.bottom, index == turns.count - 1 ? 12 : 0)
                            Circle().fill(active ? PaperStyle.accent : PaperStyle.muted.opacity(hover == turn.id ? 0.85 : 0.52))
                                .frame(width: active ? 9 : 7, height: active ? 9 : 7)
                        }.frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(ReaderButtonStyle()).onHover { inside in
                        if inside { hover = turn.id } else if hover == turn.id { hover = nil }
                    }.help(label).accessibilityLabel(label).accessibilityAddTraits(active ? .isSelected : [])
                        .accessibilityIdentifier("chat.timeline." + turn.id.uuidString)
                }
            }.padding(.vertical, 9)
                .background { ChatTimelineMarker().allowsHitTesting(false).accessibilityHidden(true) }
        }.scrollIndicators(.hidden).frame(width: 25)
            .accessibilityElement(children: .contain).accessibilityLabel(bilingual("对话时间线", "Conversation timeline"))
    }
}

private struct ChatTimelineMarker: NSViewRepresentable {
    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? ReaderWindow)?.timelineMarker = self
            configureScroller()
        }
        func configureScroller() {
            // A legacy 17-point scroller would cover the dots when macOS always shows scroll bars.
            guard let scroll = enclosingScrollView else { return }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
        }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.configureScroller() }
}

// ScrollViewReader realizes distant rows first. Align again using the final native row bounds.
struct ChatJumpAnchor: NSViewRepresentable {
    let id: UUID
    let landed: (UUID) -> Void
    final class AnchorView: NSView {
        var target: UUID?
        var landed: ((UUID) -> Void)?
        private var queued = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); align() }
        override func setFrameSize(_ size: CGSize) { super.setFrameSize(size); align() }
        func align() {
            guard window != nil, !queued else { return }
            queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.queued = false
                guard let id = self.target, let marker = (self.window as? ReaderWindow)?.transcriptMarker,
                      marker.land(on: self, id: id) else { return }
                self.landed?(id)
            }
        }
    }
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.target = id; view.landed = landed; view.align()
    }
}
