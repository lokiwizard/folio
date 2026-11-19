import SwiftUI
import AppKit

// Zoom is relative to the fitted image. Viewport changes never write to the pin.
class PinImageSurface: NSView {
    override var isFlipped: Bool { true }
    var baseImage: NSImage?
    private(set) var zoom: CGFloat = 1
    static let minimumZoom: CGFloat = 0.25
    static let maximumZoom: CGFloat = 8
    private var center = CGPoint(x: 0.5, y: 0.5)
    var zoomChanged: ((CGFloat) -> Void)?
    var acceptsViewportInput: Bool { true }
    var scrollsImage: Bool { true }

    private func origin(_ proposed: CGPoint, size: CGSize) -> CGPoint {
        func axis(_ value: CGFloat, low: CGFloat, high: CGFloat, length: CGFloat) -> CGFloat {
            let far = high - length
            return min(max(low, far), max(min(low, far), value))
        }
        return CGPoint(x: axis(proposed.x, low: bounds.minX, high: bounds.maxX, length: size.width),
                       y: axis(proposed.y, low: bounds.minY, high: bounds.maxY, length: size.height))
    }
    var imageRect: CGRect {
        guard let pixels = baseImage?.size, pixels.width > 0, pixels.height > 0, !bounds.isEmpty else { return .zero }
        let fit = min(bounds.width / pixels.width, bounds.height / pixels.height) * zoom
        let size = CGSize(width: pixels.width * fit, height: pixels.height * fit)
        let proposed = CGPoint(x: bounds.midX - center.x * size.width, y: bounds.midY - center.y * size.height)
        return CGRect(origin: origin(proposed, size: size), size: size)
    }

    private func place(_ proposed: CGPoint, size: CGSize) {
        let p = origin(proposed, size: size)
        center = CGPoint(x: (bounds.midX - p.x) / size.width, y: (bounds.midY - p.y) / size.height)
        viewportChanged()
    }
    func setZoom(_ value: CGFloat, at point: CGPoint) {
        let previous = imageRect, next = min(Self.maximumZoom, max(Self.minimumZoom, value))
        guard acceptsViewportInput, value.isFinite, !previous.isEmpty, next != zoom else { return }
        let ratio = next / zoom
        zoom = next
        let newSize = CGSize(width: previous.width * ratio, height: previous.height * ratio)
        let proposed = CGPoint(x: point.x - (point.x - previous.minX) * ratio, y: point.y - (point.y - previous.minY) * ratio)
        place(proposed, size: newSize)
        zoomChanged?(zoom)
    }
    func fitImage() {
        guard acceptsViewportInput else { return }
        zoom = 1
        center = CGPoint(x: 0.5, y: 0.5)
        viewportChanged()
        zoomChanged?(zoom)
    }
    func panImage(dx: CGFloat, dy: CGFloat) {
        let rect = imageRect
        guard !rect.isEmpty else { return }
        let p = CGPoint(x: rect.minX + (rect.width > bounds.width ? dx : 0),
                        y: rect.minY + (rect.height > bounds.height ? dy : 0))
        if origin(p, size: rect.size) != rect.origin { place(p, size: rect.size) }
    }
    var canPan: Bool { imageRect.width > bounds.width + 0.01 || imageRect.height > bounds.height + 0.01 }

    func viewportChanged() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    func wheelZoom(_ event: NSEvent, at point: CGPoint) {
        guard acceptsViewportInput, event.momentumPhase.isEmpty else { return }
        let dy = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        guard dy != 0, dy.isFinite else { return }
        let steps = event.hasPreciseScrollingDeltas ? min(3, max(-3, dy / 35)) : (dy > 0 ? 1.0 : -1.0)
        setZoom(zoom * pow(1.2, steps), at: point)
    }
    func localPoint(for event: NSEvent) -> CGPoint {
        let point = event.window == nil ? window?.convertPoint(fromScreen: event.locationInWindow) ?? event.locationInWindow : event.locationInWindow
        return convert(point, from: nil)
    }
    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .command])
        if flags == .control {
            wheelZoom(event, at: localPoint(for: event))
        } else if scrollsImage && flags.isEmpty && canPan {
            guard acceptsViewportInput else { return }
            let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 22
            let horizontal = event.modifierFlags.contains(.shift) && event.scrollingDeltaX == 0
            panImage(dx: (horizontal ? event.scrollingDeltaY : event.scrollingDeltaX) * unit,
                     dy: (horizontal ? 0 : event.scrollingDeltaY) * unit)
        } else { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), at: localPoint(for: event))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        baseImage?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

final class PinThumbnailSurface: PinImageSurface {
    weak var readerWindow: ReaderWindow?
    override var scrollsImage: Bool { false }
    // SwiftUI owns the button, context menu and card drag gestures.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        readerWindow?.thumbnailSurfaces.remove(self)
        readerWindow = window as? ReaderWindow
        readerWindow?.thumbnailSurfaces.add(self)
    }
}

struct PinThumbnailImage: NSViewRepresentable {
    let image: CGImage
    let reset: Int
    let changed: (CGFloat) -> Void
    final class Coordinator { var image: CGImage?; var reset = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PinThumbnailSurface { PinThumbnailSurface() }
    func updateNSView(_ view: PinThumbnailSurface, context: Context) {
        let state = context.coordinator
        view.zoomChanged = changed
        if state.image !== image {
            state.image = image
            view.baseImage = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            view.needsDisplay = true
        }
        if state.reset != reset { state.reset = reset; view.fitImage() }
    }
}

// Only the readout observes scroll updates. The editor and PDF preview stay in place.
@MainActor
final class PinZoomControls: ObservableObject {
    weak var surface: PinDrawingSurface?
    weak var optionsArea: NSView?
    @Published private(set) var percentage = 100
    @Published var selection: PinStroke?
    @Published var editingText = false
    func update(_ zoom: CGFloat) {
        let value = Int((zoom * 100).rounded())
        if percentage != value { percentage = value }
    }
    func step(_ factor: CGFloat) {
        guard let surface else { return }
        surface.setZoom(surface.zoom * factor, at: CGPoint(x: surface.bounds.midX, y: surface.bounds.midY))
    }
}

struct PinCanvasFooter: View {
    @ObservedObject var controls: PinZoomControls
    let tool: PinDrawingTool
    private var hint: String {
        if controls.editingText { return bilingual("回车换行 · ⌘↩ 完成 · Esc 取消", "Return for a new line · ⌘↩ to finish · Esc to cancel") }
        if tool == .hand || tool == .text {
            switch controls.selection?.tool {
            case .text: return bilingual("拖动控制点调宽高 · 双击编辑文字", "Drag handles to resize · Double-click to edit")
            case .rectangle: return bilingual("拖角点调大小 · 拖圆柄旋转 · 键入文字", "Drag corners to resize · Drag the round handle to rotate · Type to add text")
            case .oval: return bilingual("拖角点调大小 · 键入文字", "Drag corners to resize · Type to add text")
            case .pen: return bilingual("拖动笔迹移动 · 拖角点调大小", "Drag the stroke to move · Drag corners to resize")
            case .arrow, .line: return bilingual("拖端点调整方向和长度", "Drag an endpoint to change direction and length")
            default: break
            }
        }
        if tool == .text { return bilingual("拖出文本框即可输入 · ⌘↩ 完成 · Esc 取消", "Drag a text box to type · ⌘↩ to finish · Esc to cancel") }
        return bilingual("Ctrl + 滚轮缩放 · 空格拖动平移", "Ctrl-scroll to zoom · Space-drag to pan")
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button { controls.step(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(controls.percentage <= 25).help(bilingual("缩小图片 (⌘−)", "Zoom out (⌘−)"))
                .accessibilityLabel(bilingual("缩小图片", "Zoom out"))
            Text("\(controls.percentage)%").font(.caption.monospacedDigit()).frame(minWidth: 38)
                .help(bilingual("100% 表示完整图片适合窗口", "100% fits the entire image in the window"))
            Button { controls.step(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(controls.percentage >= 800).help(bilingual("放大图片 (⌘+)", "Zoom in (⌘+)"))
                .accessibilityLabel(bilingual("放大图片", "Zoom in"))
            Divider().frame(height: 12)
            Button(bilingual("适合窗口", "Fit")) { controls.surface?.fitImage() }
                .help(bilingual("显示完整图片 (⌘0)", "Fit the entire image (⌘0)"))
        }.controlSize(.small)
    }
}
