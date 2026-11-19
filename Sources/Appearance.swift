import SwiftUI

enum InterfaceAppearance: String, Codable, CaseIterable {
    case system, light, dark
    var title: String {
        switch self { case .system: L("跟随系统"); case .light: L("浅色"); case .dark: L("深色") }
    }
    var native: NSAppearance? {
        switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
}

private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PaperGlass: View {
    let strength: Double
    let corner: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduced
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let level = reduced ? 0 : strength
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            if level > 0 {
                shape.fill(.ultraThinMaterial)
                    .opacity(1 - (scheme == .dark ? 0.18 : 0.32) * level)
            }
            shape.fill(Color(white: scheme == .dark ? 0.13 : 0.96).opacity(1 - level))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

// One system backdrop per window. The opaque wash controls how much of it shows through.
struct WindowSurface: View {
    let strength: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if !reduceTransparency && strength > 0 { WindowMaterial() }
            Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency ? 1 : 1 - strength)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct SidebarSurface: View {
    let strength: Double
    @Environment(\.accessibilityReduceTransparency) private var reduced
    var body: some View {
        PaperStyle.sidebar.opacity(reduced ? 1 : 1 - strength)
    }
}

enum InspectorType {
    static let reading = Font.system(size: 15.5)
    static let control = Font.system(size: 14, weight: .medium)
    static let detail = Font.system(size: 14)
}
