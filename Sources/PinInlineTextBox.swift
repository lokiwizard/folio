import AppKit

// Keep TextKit's insertion point, selection and input method in the image's own coordinate system.
final class PinInlineTextBox: NSView {
    let editor = NSTextView()
    private let scroll = NSScrollView()
    private var placement: (origin: CGPoint, size: CGSize, angle: CGFloat)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(label: PinTextLabel, ink: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textColor = ink
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel(bilingual("标注文字", "Annotation text"))
        editor.string = label.string
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = editor
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    func place(_ layout: PinTextLayout, in canvas: NSView, image: CGRect, fontSize: CGFloat) {
        let unit = hypot(layout.transform.a, layout.transform.b)
        let size = CGSize(width: layout.box.width * unit, height: layout.box.height * unit)
        let origin = CGPoint(x: image.minX + layout.origin.x, y: image.minY + layout.origin.y)
        let angle = atan2(layout.transform.b, layout.transform.a) * 180 / .pi
        if placement?.origin != origin || placement?.size != size || placement?.angle != angle {
            placement = (origin, size, angle)
            frameRotation = 0
            frame = CGRect(origin: origin, size: size)
            if angle != 0 {
                frameRotation = angle
                let a = convert(.zero as CGPoint, to: canvas), b = convert(CGPoint(x: 1, y: 0), to: canvas)
                if (b.y - a.y) * layout.transform.b < 0 { frameRotation = -angle }
                let actual = convert(.zero as CGPoint, to: canvas)
                setFrameOrigin(CGPoint(x: frame.minX + origin.x - actual.x, y: frame.minY + origin.y - actual.y))
            }
            scroll.frame = bounds
            editor.minSize = CGSize(width: 0, height: size.height)
            editor.setFrameSize(size)
        }
        let font = NSFont.systemFont(ofSize: max(1, fontSize))
        if editor.font != font { editor.font = font }
    }
}
