import SwiftUI

enum PaperStyle {
    static let paper = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let text = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let line = Color(nsColor: .separatorColor)
    static let accent = Color(nsColor: .controlAccentColor)
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.15 : 0.95, alpha: 1)
    })
    static let tint = accent.opacity(0.10)

}

private struct HoverHighlight: ViewModifier {
    let radius: CGFloat
    var pressed = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(enabled ? (pressed ? 0.10 : hovered ? 0.06 : 0) : 0))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
                .allowsHitTesting(false).accessibilityHidden(true)
        }.onHover { hovered = $0 }
    }
}

struct ReaderButtonStyle: ButtonStyle {
    var radius: CGFloat = 6
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .modifier(HoverHighlight(radius: radius, pressed: configuration.isPressed))
    }
}

struct GlyphButton: View {
    var symbol: String
    var title: String
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 29)
                .foregroundStyle(active ? PaperStyle.accent : PaperStyle.text)
                .background(active ? PaperStyle.tint : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(ReaderButtonStyle()).help(title).accessibilityLabel(title)
    }
}
struct SectionEmpty: View {
    var symbol: String
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 23, weight: .light)).foregroundStyle(PaperStyle.accent)
                .frame(width: 46, height: 46).background(PaperStyle.tint, in: RoundedRectangle(cornerRadius: 12))
            Text(title).font(.system(size: 16, weight: .semibold))
            if !detail.isEmpty { Text(detail).font(.system(size: 14)).foregroundStyle(PaperStyle.muted).multilineTextAlignment(.center).lineSpacing(3) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct SidebarTabs<Item: Hashable>: View {
    let items: [Item]
    let selection: Item
    let title: (Item) -> String
    let icon: (Item) -> String
    var count: (Item) -> Int? = { _ in nil }
    let select: (Item) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items, id: \.self) { item in
                let active = item == selection
                Button { select(item) } label: {
                    ViewThatFits(in: .horizontal) {
                        segment(item, active: active, showIcon: true)
                        segment(item, active: active, showIcon: false)
                    }
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background { if active {
                        RoundedRectangle(cornerRadius: 7).fill(PaperStyle.surface)
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    } }
                }.buttonStyle(ReaderButtonStyle()).accessibilityLabel(title(item))
                    .accessibilityAddTraits(active ? .isSelected : [])
            }
        }.padding(2).background(Color.primary.opacity(0.062), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 9).padding(.vertical, 10)
    }

    private func segment(_ item: Item, active: Bool, showIcon: Bool) -> some View {
        HStack(spacing: 5) {
            if showIcon {
                Image(systemName: icon(item)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.blue : PaperStyle.muted)
            }
            Text(title(item)).font(.system(size: 14, weight: active ? .semibold : .medium)).lineLimit(1)
            if active, let value = count(item) {
                Text(String(value)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }.foregroundStyle(active ? PaperStyle.text : PaperStyle.muted).fixedSize()
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = 6) -> some View {
        modifier(HoverHighlight(radius: radius))
    }

    func sidebarCardSurface() -> some View {
        background(PaperStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09), lineWidth: 0.7).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.035), radius: 2, y: 1)
    }
    func sidebarFieldSurface() -> some View {
        background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.07), lineWidth: 0.6).allowsHitTesting(false) }
    }
}
