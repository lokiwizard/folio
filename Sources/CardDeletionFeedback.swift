import SwiftUI
import AppKit

// This overlay shares the lifted card's window layer. Its badge stays readable even over a tall card.
final class CardDeletionFeedback: NSView {
    static let edgeWidth: CGFloat = 40
    private let badge = NSHostingView(rootView: EdgeBadge(armed: false))
    private var armed = false

    init() {
        super.init(frame: .zero)
        badge.sizingOptions = []
        addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func track(edge: CGRect, point: CGPoint, armed: Bool, in host: NSView) {
        let width = max(148, edge.width)
        let area = CGRect(x: edge.maxX - width, y: edge.minY, width: width, height: edge.height)
        let target = host.convert(area, from: nil)
        if frame != target { frame = target }
        let y = convert(point, from: nil).y
        // Offset the prompt from the pointer, keeping it inside the sidebar at either end.
        let badgeY = min(max(0, bounds.height - 37), max(5, y + 8))
        badge.frame = CGRect(x: 0, y: badgeY, width: width - 6, height: 32)
        if self.armed != armed {
            self.armed = armed
            badge.rootView = EdgeBadge(armed: armed)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let tint = NSColor.systemRed
        let edge = CGRect(x: bounds.maxX - Self.edgeWidth, y: 0, width: Self.edgeWidth, height: bounds.height)
        NSGradient(starting: tint.withAlphaComponent(0), ending: tint.withAlphaComponent(armed ? 0.25 : 0.13))?
            .draw(in: edge, angle: 0)
    }
}

private struct EdgeBadge: View {
    let armed: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tint = Color(nsColor: .systemRed)
        HStack(spacing: 0) {
            if armed {
                Text(L("松开删除")).font(.system(size: 12, weight: .semibold))
                    .fixedSize().padding(.leading, 11).transition(.opacity)
            }
            Image(systemName: armed ? "trash.fill" : "trash")
                .font(.system(size: 14, weight: .medium)).frame(width: 28)
        }.frame(height: 28)
            .foregroundStyle(scheme == .dark ? Color(red: 1, green: 0.74, blue: 0.72) : Color(red: 0.60, green: 0.19, blue: 0.20))
            .background { Capsule().fill(PaperStyle.surface).overlay { Capsule().fill(tint.opacity(armed ? 0.16 : 0.08)) } }
            .overlay { Capsule().strokeBorder(tint.opacity(0.19), lineWidth: 0.7) }
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: armed)
            .accessibilityLabel(L(armed ? "松开删除" : "向右拖动删除"))
    }
}
