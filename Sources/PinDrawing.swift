import SwiftUI
import AppKit

final class PinDrawingSurface: PinImageSurface, NSTextViewDelegate {
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var strokes: [PinStroke] = [] {
        didSet {
            guard (tool == .hand || tool == .text), let selected else { return }
            if oldValue.first(where: { $0.id == selected }) != strokes.first(where: { $0.id == selected }) {
                window?.invalidateCursorRects(for: self)
                if !strokes.contains(where: { $0.id == selected }) { self.selected = nil } else { publishSelection() }
            }
        }
    }
    var rotation = 0
    var tool = PinDrawingTool.pen {
        didSet {
            guard oldValue != tool else { return }
            if inlineBox == nil { cancelGesture() }
            if tool != .hand { selected = nil }
            window?.invalidateCursorRects(for: self)
        }
    }
    var fontSize: CGFloat = 16
    var ink = NSColor.systemRed
    var thickness: CGFloat = 0.004
    var dashed = false
    var commit: ((PinStroke) -> Void)?
    var stepHistory: ((Bool) -> Void)?
    var copyImage: (() -> Void)?
    var removeStroke: ((UUID) -> Void)?
    var chooseHand: (() -> Void)?
    private var inputMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var pending: PinStroke?
    weak var zoomControls: PinZoomControls?
    private var selected: UUID? {
        didSet {
            guard selected != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            publishSelection()
        }
    }
    private var selectedStroke: PinStroke? { strokes.first { $0.id == selected } }
    private func publishSelection() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let controls = self.zoomControls else { return }
            let stroke = self.inlineBox != nil ? self.pending : self.selectedStroke
            if controls.selection != stroke { controls.selection = stroke }
        }
    }
    private struct Drag {
        let stroke: PinStroke
        let start: CGPoint
        var bounds: CGRect = .zero
        var visibleTextOrigin: CGPoint?
        var control: (shape: PinShapeHandles, kind: PinShapeHandles.Kind)?
    }
    private var moving: Drag?
    private var textStart: CGPoint?
    private var inlineBox: PinInlineTextBox?
    private var finishingTextClick = false
    private var usingTextOptions = false
    private var lastSample = CGPoint.zero

    private var spaceHeld = false
    private var panStart: CGPoint?
    private var detailTask: Task<Void, Never>?
    private var detailTile: (image: NSImage, unitRect: CGRect)?
    var detailSource: (store: PinPreviewStore, anchor: Anchor)?
    override var acceptsViewportInput: Bool { moving == nil && panStart == nil && (pending == nil || inlineBox != nil) }

    override func viewportChanged() {
        super.viewportChanged()
        refreshDetail()
        positionEditor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previous = frame.size
        super.setFrameSize(newSize)
        if newSize != previous { viewportChanged() }
    }

    func refreshDetail(clear: Bool = false) {
        detailTask?.cancel()
        if clear { detailTile = nil }
        let full = imageRect, visible = full.intersection(bounds)
        guard let source = detailSource, let density = window?.backingScaleFactor, !visible.isEmpty,
              let baseImage, full.width * density > baseImage.size.width * 1.05 else {
            detailTile = nil
            return
        }
        let unit = CGRect(x: (visible.minX - full.minX) / full.width, y: (visible.minY - full.minY) / full.height,
                          width: visible.width / full.width, height: visible.height / full.height)
        let pixels = ceil(max(visible.width, visible.height) * density), angle = rotation
        detailTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let cg = await source.store.detail(for: source.anchor, rotation: angle, visible: unit, pixels: pixels),
                  !Task.isCancelled, let self else { return }
            self.detailTile = (NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)), unit)
            self.needsDisplay = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        spaceHeld = false
        guard let window else { detailTask?.cancel(); detailTile = nil; return }
        refreshDetail()
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.spaceHeld = false
            if self.panStart != nil { self.cancelGesture() }
            self.window?.invalidateCursorRects(for: self)
        }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel, .magnify, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .scrollWheel || event.type == .magnify {
                // SwiftUI can hit-test the context menu's hosting view before its AppKit canvas.
                guard let window = self.window else { return event }
                let flags = event.modifierFlags.intersection([.option, .command, .control])
                if self.inlineBox != nil, event.type == .scrollWheel, flags != .control { return event }
                if let target = event.window {
                    guard target === window else { return event }
                } else {
                    let target = NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0)
                    guard target == window.windowNumber else { return event }
                }
                let point = self.localPoint(for: event)
                guard self.visibleRect.contains(point) else { return event }
                if event.type == .magnify {
                    self.magnify(with: event)
                } else {
                    guard flags == .control || (flags.isEmpty && self.canPan) else { return event }
                    self.scrollWheel(with: event)
                }
                return nil
            }
            if let box = self.inlineBox, event.window === self.window {
                if self.moving != nil, event.type == .leftMouseDragged || event.type == .leftMouseUp {
                    self.sample(event, final: event.type == .leftMouseUp)
                    if event.type == .leftMouseUp {
                        self.moving = nil
                        self.window?.invalidateCursorRects(for: self)
                    }
                    return nil
                }
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    let p = self.convert(event.locationInWindow, from: nil)
                    if event.type == .leftMouseDown, self.visibleRect.contains(p), let stroke = self.pending,
                       let drag = self.handleDrag(for: stroke, at: p) ?? self.textBorderDrag(for: stroke, at: p) {
                        self.moving = drag
                        self.window?.invalidateCursorRects(for: self)
                        self.window?.makeFirstResponder(box.editor)
                        return nil
                    }
                    self.usingTextOptions = self.zoomControls?.optionsArea.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
                    if !self.usingTextOptions, !box.bounds.contains(box.convert(p, from: self)) {
                        self.finishingTextClick = event.type == .leftMouseDown && self.visibleRect.contains(p) && self.stroke(at: p) == nil
                        self.finishText(save: true)
                    }
                    return event
                }
                if event.type == .keyDown, self.window?.firstResponder === box.editor {
                    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
                    if event.keyCode == 53, flags.isEmpty, !box.editor.hasMarkedText() {
                        if let drag = self.moving { self.pending = drag.stroke; self.moving = nil; self.positionEditor(); self.needsDisplay = true }
                        else { self.finishText(save: false) }
                        return nil
                    }
                    if [36, 76].contains(event.keyCode), flags == .command { self.finishText(save: true); return nil }
                    if flags == .command, event.charactersIgnoringModifiers == "c" { box.editor.copy(nil); return nil }
                }
                return event
            }
            guard event.type == .keyDown || event.type == .keyUp else { return event }
            guard event.window === self.window, self.window != nil, !(self.window?.firstResponder is NSTextView) else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 49, flags.isEmpty, self.canPan || self.spaceHeld {
                self.spaceHeld = event.type == .keyDown
                self.window?.invalidateCursorRects(for: self)
                return nil
            }
            guard event.type == .keyDown else { return event }
            if let key = event.charactersIgnoringModifiers, flags == .command || (key == "+" && flags == [.command, .shift]) {
                let center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
                switch key {
                case "c": self.copyImage?(); return nil
                case "0": self.fitImage(); return nil
                case "=", "+": self.setZoom(self.zoom * 1.25, at: center); return nil
                case "-": self.setZoom(self.zoom / 1.25, at: center); return nil
                default: break
                }
            }
            let dragging = self.moving != nil || self.pending != nil || self.panStart != nil
            if (event.keyCode == 51 || event.keyCode == 117), flags.isEmpty, self.selectedStroke != nil, !dragging {
                self.deleteSelected()
                return nil
            }
            if event.keyCode == 53, flags.isEmpty, dragging {
                self.cancelGesture()
                return nil
            }
            if !dragging, self.window?.firstResponder === self, self.tool == .hand,
               let stroke = self.selectedStroke, stroke.tool.acceptsText,
               flags.intersection([.command, .control]).isEmpty {
                let enter = [36, 76].contains(event.keyCode)
                let printable = event.characters?.unicodeScalars.first.map { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) } == true
                if enter || printable {
                    self.editSelectedText()
                    if let editor = self.inlineBox?.editor {
                        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                        if !enter { editor.keyDown(with: event) }
                        return nil
                    }
                }
            }
            guard event.charactersIgnoringModifiers?.lowercased() == "z" else { return event }
            guard flags == .command || flags == [.command, .shift] else { return event }
            if dragging { self.cancelGesture() }
            else { self.stepHistory?(flags.contains(.shift)) }
            return nil
        }
    }
    deinit {
        detailTask?.cancel()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = imageRect
        guard rect.width > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        super.draw(dirtyRect)
        if let tile = detailTile {
            let area = tile.unitRect
            let destination = CGRect(x: rect.minX + area.minX * rect.width, y: rect.minY + area.minY * rect.height,
                                     width: area.width * rect.width, height: area.height * rect.height)
            tile.image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        for original in strokes {
            let stroke = pending?.id == original.id ? (pending ?? original) : original
            stroke.draw(in: ctx, size: rect.size, rotation: rotation, showText: inlineBox == nil || stroke.id != pending?.id)
        }
        if inlineBox == nil, let pending, !strokes.contains(where: { $0.id == pending.id }) {
            pending.draw(in: ctx, size: rect.size, rotation: rotation)
        }
        let chosen = pending ?? strokes.first { $0.id == selected }
        if (tool == .hand || tool == .text), let chosen {
            if textStart == nil, (tool == .hand || chosen.tool == .text), let shape = controls(for: chosen) {
                drawHandles(shape, outline: [.text, .pen, .oval].contains(chosen.tool), in: ctx)
                return
            }
            let box = chosen.bounds(size: rect.size, rotation: rotation).insetBy(dx: -3, dy: -3)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(box)
        }
    }

    private func controls(for stroke: PinStroke) -> PinShapeHandles? {
        let active = moving?.control
        return PinShapeHandles(stroke, size: imageRect.size, rotation: rotation,
                               preferredEdge: active?.kind == .rotation ? active?.shape.rotationEdge : nil)
    }

    private func drawHandles(_ shape: PinShapeHandles, outline: Bool, in ctx: CGContext) {
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.setLineWidth(1.5)
        if outline {
            ctx.saveGState()
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.addLines(between: shape.vertices)
            ctx.closePath()
            ctx.strokePath()
            ctx.restoreGState()
        }
        for handle in shape.handles {
            let point = handle.position
            let grip = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            switch handle.kind {
            case .corner, .edge:
                ctx.addRect(grip)
            case .rotation:
                if let stem = shape.stem {
                    ctx.move(to: stem)
                    ctx.addLine(to: point)
                    ctx.strokePath()
                }
                ctx.addEllipse(in: grip.insetBy(dx: -0.75, dy: -0.75))
            case .endpoint:
                ctx.addEllipse(in: grip)
            }
            ctx.drawPath(using: .fillStroke)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let control = moving?.control, let grip = control.shape.handles.first(where: { $0.kind == control.kind }) {
            addCursorRect(visibleRect, cursor: control.shape.cursor(for: grip))
            return
        }
        if spaceHeld || panStart != nil {
            addCursorRect(bounds, cursor: panStart == nil ? .openHand : .closedHand)
            return
        }
        if tool == .hand { addCursorRect(bounds, cursor: moving == nil ? .openHand : .closedHand) }
        if tool == .text {
            addCursorRect(imageRect.intersection(bounds), cursor: .crosshair)
            for stroke in strokes where stroke.tool == .text {
                let box = stroke.bounds(size: imageRect.size, rotation: rotation)
                    .offsetBy(dx: imageRect.minX, dy: imageRect.minY).intersection(bounds)
                if !box.isEmpty { addCursorRect(box, cursor: moving == nil ? .openHand : .closedHand) }
            }
        }
        if (tool == .hand || tool == .text), let stroke = pending ?? strokes.first(where: { $0.id == selected }),
           let shape = controls(for: stroke) {
            for handle in shape.handles {
                let r = shape.hitRadius
                let area = CGRect(x: imageRect.minX + handle.position.x - r, y: imageRect.minY + handle.position.y - r, width: 2 * r, height: 2 * r).intersection(bounds)
                guard !area.isEmpty else { continue }
                addCursorRect(area, cursor: shape.cursor(for: handle))
            }
        }
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        let rect = imageRect
        let x = min(1, max(0, (p.x - rect.minX) / rect.width))
        let y = min(1, max(0, (p.y - rect.minY) / rect.height))
        return PinStroke.rotate(CGPoint(x: x, y: y), by: -rotation)
    }

    private func stroke(at point: CGPoint, textOnly: Bool = false) -> PinStroke? {
        let rect = imageRect
        let local = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
        for interior in [false, true] {
            if let found = strokes.reversed().first(where: {
                (!textOnly || $0.tool == .text) && $0.hit(local, size: rect.size, rotation: rotation, interior: interior)
            }) { return found }
        }
        return nil
    }

    private func handleDrag(for stroke: PinStroke, at point: CGPoint) -> Drag? {
        let local = CGPoint(x: point.x - imageRect.minX, y: point.y - imageRect.minY)
        guard let shape = controls(for: stroke), let handle = shape.handle(at: local) else { return nil }
        return Drag(stroke: stroke, start: point, control: (shape, handle.kind))
    }

    private func textBorderDrag(for stroke: PinStroke, at point: CGPoint) -> Drag? {
        guard stroke.tool == .text, let layout = stroke.textLayout(size: imageRect.size, rotation: rotation) else { return nil }
        let local = CGPoint(x: point.x - imageRect.minX, y: point.y - imageRect.minY)
        let box = layout.bounds
        guard box.insetBy(dx: -3, dy: -3).contains(local), !box.insetBy(dx: 1.5, dy: 1.5).contains(local) else { return nil }
        return Drag(stroke: stroke, start: point, bounds: box, visibleTextOrigin: layout.origin)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if finishingTextClick { finishingTextClick = false; return }
        if inlineBox != nil {
            finishText(save: true)
            if stroke(at: p) == nil { return }
        }
        window?.makeFirstResponder(self)
        if spaceHeld && canPan { beginPan(at: p); return }
        guard imageRect.contains(p), let color = PinColor(ink) else {
            if tool == .hand && canPan { beginPan(at: p) }
            return
        }
        lastSample = p
        needsDisplay = true
        if tool == .hand || tool == .text {
            if let stroke = selectedStroke, let drag = handleDrag(for: stroke, at: p) {
                moving = drag
                window?.invalidateCursorRects(for: self)
                return
            }
        }
        switch tool {
        case .hand, .text:
            let hit = stroke(at: p, textOnly: tool == .text)
            selected = hit?.id
            if let hit {
                if event.clickCount == 2 && hit.tool.acceptsText { editText(hit, at: p) }
                else {
                    let layout = hit.tool == .text ? hit.textLayout(size: imageRect.size, rotation: rotation) : nil
                    moving = Drag(stroke: hit, start: p, bounds: layout?.bounds ?? hit.bounds(size: imageRect.size, rotation: rotation),
                                  visibleTextOrigin: layout?.origin)
                    window?.invalidateCursorRects(for: self)
                }
            } else if tool == .text { textStart = p; pending = newText(from: p, to: p, color: color) }
            else if canPan { beginPan(at: p) }
        default:
            selected = nil
            pending = PinStroke(id: UUID(), tool: tool, color: color, width: thickness, dashed: dashed, points: [normalized(p)])
        }
    }

    private func newText(from start: CGPoint, to end: CGPoint, color: PinColor) -> PinStroke {
        let rect = imageRect
        let end = CGPoint(x: min(rect.maxX, max(rect.minX, end.x)), y: min(rect.maxY, max(rect.minY, end.y)))
        let span = abs(end.x - start.x)
        let width = span < 6 ? min(210 * zoom, rect.width * 0.58) : max(36, span)
        let origin = CGPoint(x: min(start.x, end.x), y: min(start.y, end.y))
        let label = PinTextLabel(string: "", orientation: rotation, boxWidth: min(1, width / rect.width),
                                 fontSize: fontSize * zoom / max(rect.width, rect.height),
                                 boxHeight: abs(end.y - start.y) >= 5 ? abs(end.y - start.y) / rect.height : nil)
        return PinStroke(id: UUID(), tool: .text, color: color, width: thickness, dashed: false, points: [normalized(origin)], label: label)
    }

    private func move(_ drag: Drag, to end: CGPoint) -> PinStroke {
        let size = imageRect.size, box = drag.bounds, stroke = drag.stroke, start = drag.start
        func offset(_ delta: CGFloat, low: CGFloat, high: CGFloat, limit: CGFloat) -> CGFloat {
            let a = -low, b = limit - high
            return min(max(a, b), max(min(a, b), delta)) / limit
        }
        let dx = offset(end.x - start.x, low: box.minX, high: box.maxX, limit: size.width)
        let dy = offset(end.y - start.y, low: box.minY, high: box.maxY, limit: size.height)
        var result = stroke
        if let origin = drag.visibleTextOrigin {
            result.points = [PinStroke.rotate(CGPoint(x: origin.x / size.width + dx, y: origin.y / size.height + dy), by: -rotation)]
            return result
        }
        result.points = stroke.points.map { point in
            let p = PinStroke.rotate(point, by: rotation)
            return PinStroke.rotate(CGPoint(x: p.x + dx, y: p.y + dy), by: -rotation)
        }
        return result
    }

    enum StyleChange { case color(PinColor), width(CGFloat), dashed(Bool), font(CGFloat) }

    func editStyle(_ change: StyleChange) {
        guard var stroke = inlineBox != nil ? pending : selectedStroke, moving == nil else { return }
        switch change {
        case let .color(color): stroke.color = color
        case let .width(width): stroke.width = width
        case let .dashed(dashed): stroke.dashed = dashed
        case let .font(points):
            guard stroke.label != nil, !imageRect.isEmpty else { return }
            stroke.label?.fontSize = points * zoom / max(imageRect.width, imageRect.height)
        }
        if let box = inlineBox {
            pending = stroke
            box.editor.textColor = stroke.color.color
            positionEditor()
            window?.makeFirstResponder(box.editor)
            publishSelection()
            needsDisplay = true
        } else { commitStroke(stroke) }
    }

    private func selectForAdjustment(_ id: UUID) {
        if tool != .hand { tool = .hand; chooseHand?() }
        selected = id
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func commitStroke(_ stroke: PinStroke) {
        guard let commit else { return }
        if let index = strokes.firstIndex(where: { $0.id == stroke.id }) {
            guard strokes[index] != stroke else { return }
            strokes[index] = stroke
        } else { strokes.append(stroke) }
        commit(stroke)
        needsDisplay = true
    }

    @objc func deleteSelected() {
        if inlineBox != nil { finishText(save: false) }
        guard let stroke = selectedStroke, acceptsViewportInput, let removeStroke else { return }
        selected = nil
        strokes.removeAll { $0.id == stroke.id }
        removeStroke(stroke.id)
        needsDisplay = true
    }

    @objc func editSelectedText() {
        guard let stroke = selectedStroke, stroke.tool.acceptsText, acceptsViewportInput else { return }
        let box = stroke.bounds(size: imageRect.size, rotation: rotation).offsetBy(dx: imageRect.minX, dy: imageRect.minY)
        let visible = box.intersection(bounds)
        editText(stroke, at: visible.isEmpty ? CGPoint(x: bounds.midX, y: bounds.midY) : CGPoint(x: visible.midX, y: visible.midY))
    }

    @objc private func copyCurrentImage() { copyImage?() }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard acceptsViewportInput else { return nil }
        let p = convert(event.locationInWindow, from: nil), menu = NSMenu()
        if imageRect.contains(p), let hit = stroke(at: p) {
            if tool != .hand { chooseHand?() }
            selected = hit.id
            needsDisplay = true
            if hit.tool.acceptsText {
                menu.addItem(withTitle: bilingual("编辑文字…", "Edit text…"), action: #selector(editSelectedText), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: bilingual("删除标注", "Delete annotation"), action: #selector(deleteSelected), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: L("复制图片"), action: #selector(copyCurrentImage), keyEquivalent: "").target = self
        return menu
    }

    private func editText(_ stroke: PinStroke, at p: CGPoint) {
        guard inlineBox == nil, stroke.tool.acceptsText, !imageRect.isEmpty, let window else { return }
        var draft = stroke
        let label = stroke.label ?? PinTextLabel(string: "", orientation: rotation, boxWidth: 1,
                                                 fontSize: fontSize * zoom / max(imageRect.width, imageRect.height))
        draft.label = label
        pending = draft
        let box = PinInlineTextBox(label: label, ink: stroke.color.color)
        inlineBox = box
        usingTextOptions = false
        box.editor.alignment = stroke.tool == .text ? .natural : .center
        selectForAdjustment(stroke.id)
        publishSelection()
        zoomControls?.editingText = true
        addSubview(box)
        positionEditor()
        box.editor.delegate = self
        window.makeFirstResponder(box.editor)
        let index = box.editor.characterIndexForInsertion(at: box.editor.convert(p, from: self))
        box.editor.setSelectedRange(NSRange(location: min(index, label.string.utf16.count), length: 0))
        needsDisplay = true
    }

    private func positionEditor() {
        guard let box = inlineBox, let stroke = pending, let label = stroke.label, !imageRect.isEmpty,
              let layout = stroke.textLayout(size: imageRect.size, rotation: rotation) else { return }
        box.place(layout, in: self, image: imageRect, fontSize: label.fontSize * max(imageRect.width, imageRect.height))
    }
    func textDidChange(_ notification: Notification) {
        guard let box = inlineBox, notification.object as? NSTextView === box.editor else { return }
        pending?.label?.string = box.editor.string
        positionEditor()
    }
    func textDidEndEditing(_ notification: Notification) {
        if !usingTextOptions, let box = inlineBox, notification.object as? NSTextView === box.editor { finishText(save: true, restoreFocus: false) }
    }
    func finishText(save: Bool, restoreFocus: Bool = true) {
        guard let box = inlineBox else { return }
        inlineBox = nil
        zoomControls?.editingText = false
        box.editor.delegate = nil
        if save, var stroke = pending {
            stroke.label?.string = box.editor.string
            let empty = box.editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if stroke.tool != .text {
                if empty { stroke.label = nil }
                commitStroke(stroke)
            } else if empty {
                if strokes.contains(where: { $0.id == stroke.id }) {
                    strokes.removeAll { $0.id == stroke.id }
                    removeStroke?(stroke.id)
                }
            } else if let layout = stroke.textLayout(size: imageRect.size, rotation: rotation), !imageRect.isEmpty {
                stroke.points = [PinStroke.rotate(CGPoint(x: layout.origin.x / imageRect.width, y: layout.origin.y / imageRect.height), by: -rotation)]
                commitStroke(stroke)
            }
        }
        if restoreFocus, window?.firstResponder === box.editor { window?.makeFirstResponder(self) }
        box.removeFromSuperview()
        usingTextOptions = false
        if selectedStroke == nil { selected = nil }
        publishSelection()
        cancelGesture()
    }

    private func beginPan(at point: CGPoint) {
        panStart = point
        window?.invalidateCursorRects(for: self)
    }
    private func cancelGesture() {
        panStart = nil
        moving = nil
        textStart = nil
        pending = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    private func sample(_ event: NSEvent, final: Bool) {
        let p = convert(event.locationInWindow, from: nil)
        if let previous = panStart {
            panImage(dx: p.x - previous.x, dy: p.y - previous.y)
            panStart = p
            return
        }
        if let moving {
            if hypot(p.x - moving.start.x, p.y - moving.start.y) >= 2 || pending != nil {
                if let control = moving.control {
                    let rect = imageRect
                    let from = CGPoint(x: moving.start.x - rect.minX, y: moving.start.y - rect.minY)
                    let to = CGPoint(x: p.x - rect.minX, y: p.y - rect.minY)
                    pending = control.shape.adjusted(moving.stroke, handle: control.kind, from: from, to: to)
                } else { pending = move(moving, to: p) }
                if inlineBox != nil { positionEditor() }
                needsDisplay = true
            }
            return
        }
        if let start = textStart, let color = pending?.color {
            pending = newText(from: start, to: p, color: color)
            needsDisplay = true
            return
        }
        guard inlineBox == nil, let kind = pending?.tool else { return }
        guard p != lastSample, final || hypot(p.x - lastSample.x, p.y - lastSample.y) >= 1 else { return }
        lastSample = p
        let end = normalized(p)
        if kind != .pen, pending?.points.count == 2 { pending?.points[1] = end }
        else { pending?.points.append(end) }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { sample(event, final: false) }
    override func mouseUp(with event: NSEvent) {
        sample(event, final: true)
        if panStart != nil { cancelGesture(); return }
        if let start = textStart, let stroke = pending {
            textStart = nil
            editText(stroke, at: start)
            return
        }
        guard inlineBox == nil else { return }
        if let moving {
            if let pending, pending != moving.stroke { commitStroke(pending) }
            cancelGesture()
            return
        }
        guard let stroke = pending else { return }
        cancelGesture()
        if stroke.tool == .pen || stroke.points.first != stroke.points.last {
            commitStroke(stroke)
            selectForAdjustment(stroke.id)
        }
    }
    override func cancelOperation(_ sender: Any?) {
        if inlineBox != nil { finishText(save: false) }
        else if pending != nil || moving != nil { cancelGesture() }
        else { super.cancelOperation(sender) }
    }
}

private struct DrawingCanvas: NSViewRepresentable {
    let image: CGImage?
    let store: PinPreviewStore
    let source: Anchor
    let zoomControls: PinZoomControls
    let strokes: [PinStroke]
    let rotation: Int
    let tool: PinDrawingTool
    let ink: NSColor
    let width: CGFloat
    let dashed: Bool
    let fontSize: CGFloat
    let removeStroke: (UUID) -> Void
    let chooseHand: () -> Void
    let copyImage: () -> Void
    let stepHistory: (Bool) -> Void
    let commit: (PinStroke) -> Void

    final class Coordinator { var previous: CGImage? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PinDrawingSurface {
        let view = PinDrawingSurface()
        view.setAccessibilityLabel(bilingual("图片标注画布", "Image markup canvas"))
        return view
    }
    func updateNSView(_ view: PinDrawingSurface, context: Context) {
        let refresh = context.coordinator.previous !== image || view.rotation != rotation
        zoomControls.surface = view
        view.zoomControls = zoomControls
        view.zoomChanged = { [weak zoomControls] in zoomControls?.update($0) }
        view.detailSource = (store, source)
        if context.coordinator.previous !== image {
            context.coordinator.previous = image
            view.baseImage = image.map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }
        }
        view.rotation = rotation
        if refresh { view.refreshDetail(clear: true) }
        view.strokes = strokes
        view.tool = tool
        view.ink = ink
        view.thickness = width
        view.dashed = dashed
        view.fontSize = fontSize
        view.removeStroke = removeStroke
        view.chooseHand = chooseHand
        view.copyImage = copyImage
        view.stepHistory = stepHistory
        view.commit = commit
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: PinDrawingSurface, coordinator: Coordinator) {
        view.commit = nil
        view.removeStroke = nil
        view.chooseHand = nil
        view.copyImage = nil
        view.stepHistory = nil
    }
}

private struct PinToolPicker: NSViewRepresentable {
    @Binding var tool: PinDrawingTool

    final class Coordinator: NSObject {
        var selection: Binding<PinDrawingTool>
        init(_ selection: Binding<PinDrawingTool>) { self.selection = selection }
        @objc func change(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard PinDrawingTool.allCases.indices.contains(index) else { return }
            selection.wrappedValue = PinDrawingTool.allCases[index]
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($tool) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.identifier = NSUserInterfaceItemIdentifier("pin.markup.tools")
        control.segmentCount = PinDrawingTool.allCases.count
        control.trackingMode = .selectOne
        control.controlSize = .regular
        control.target = context.coordinator
        control.action = #selector(Coordinator.change(_:))
        for (index, item) in PinDrawingTool.allCases.enumerated() {
            control.setImage(NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title), forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $tool
        control.setAccessibilityLabel(bilingual("标注工具", "Markup tool"))
        for (index, item) in PinDrawingTool.allCases.enumerated() {
            control.setLabel(item.title, forSegment: index)
            control.setToolTip(item.title, forSegment: index)
        }
        control.selectedSegment = PinDrawingTool.allCases.firstIndex(of: tool) ?? 0
    }
}

struct PinDrawingEditor: View {
    @ObservedObject var r: Reader
    let reference: CardReference
    let dismiss: () -> Void
    @State private var tool = PinDrawingTool.hand
    @State private var zoomControls = PinZoomControls()
    @State private var ink = Color(nsColor: .systemRed)
    @State private var width: CGFloat = 0.004
    @State private var dashed = false
    private struct Change {
        let id: UUID
        let position: Int
        let before: PinStroke?
        let after: PinStroke?
    }
    @State private var history: [Change] = []
    @State private var redo: [Change] = []
    @State private var fontSize: CGFloat = 16

    private var index: Int? {
        guard r.key == reference.document else { return nil }
        return r.state.pins.firstIndex { $0.id == reference.id }
    }
    private func apply(_ change: Change, forward: Bool) {
        guard let i = index else { return }
        var pin = r.state.pins[i], strokes = pin.drawing ?? []
        let value = forward ? change.after : change.before
        if let j = strokes.firstIndex(where: { $0.id == change.id }) {
            if let value { strokes[j] = value } else { strokes.remove(at: j) }
        } else if let value { strokes.insert(value, at: min(strokes.count, change.position)) }
        pin.drawing = strokes.isEmpty ? nil : strokes
        pin.drawingRevision = UUID()
        r.state.pins[i] = pin
    }
    private func change(_ id: UUID, to value: PinStroke?) {
        guard let i = index else { return }
        let strokes = r.state.pins[i].drawing ?? []
        let position = strokes.firstIndex { $0.id == id } ?? strokes.count
        let old = position < strokes.count ? strokes[position] : nil
        guard old != value else { return }
        let operation = Change(id: id, position: position, before: old, after: value)
        apply(operation, forward: true)
        history.append(operation)
        redo.removeAll()
    }
    private func undo() {
        let operation: Change
        if let edit = history.popLast() { operation = edit }
        else if let i = index, let strokes = r.state.pins[i].drawing, let last = strokes.last {
            operation = Change(id: last.id, position: strokes.count - 1, before: nil, after: last)
        } else { return }
        apply(operation, forward: false)
        redo.append(operation)
    }
    private func redoLast() {
        guard let operation = redo.popLast() else { return }
        apply(operation, forward: true)
        history.append(operation)
    }
    var body: some View {
        if let i = index {
            let pin = r.state.pins[i]
            VStack(spacing: 12) {
                HStack {
                    Text(pin.customTitle ?? bilingual("图片标注", "Image Markup")).font(.headline).lineLimit(1)
                    Text(pageName(pin.source.page)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button { r.copyPin(pin.id) } label: { Label(L("复制图片"), systemImage: "doc.on.doc") }
                        .keyboardShortcut("c", modifiers: .command)
                    Button(L("完成")) { zoomControls.surface?.finishText(save: true); dismiss() }.keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 10) {
                    PinToolPicker(tool: $tool).fixedSize()
                    Spacer()
                    Button(action: undo) { Image(systemName: "arrow.uturn.backward") }
                        .disabled(history.isEmpty && pin.drawing?.isEmpty != false)
                        .help(bilingual("撤销", "Undo")).accessibilityLabel(bilingual("撤销", "Undo"))
                    Button(action: redoLast) { Image(systemName: "arrow.uturn.forward") }
                        .disabled(redo.isEmpty)
                        .help(bilingual("重做", "Redo")).accessibilityLabel(bilingual("重做", "Redo"))
                }.controlSize(.small)
                PinMarkupOptions(controls: zoomControls, tool: tool, ink: $ink, width: $width, dashed: $dashed, fontSize: $fontSize)
                if let store = r.pinPreviews {
                    let rotation = r.state.rotations[pin.source.page] ?? r.document?.safePage(pin.source.page)?.rotation ?? 0
                    let clean = Pin(id: pin.id, source: pin.source)
                    PinArtwork(store: store, pin: clean, rotation: rotation, large: true) { image in
                        DrawingCanvas(image: image, store: store, source: pin.source, zoomControls: zoomControls, strokes: pin.drawing ?? [], rotation: rotation, tool: tool,
                                      ink: NSColor(ink), width: width, dashed: dashed, fontSize: fontSize,
                                      removeStroke: { change($0, to: nil) }, chooseHand: { tool = .hand }, copyImage: { r.copyPin(pin.id) }, stepHistory: { forward in if forward { redoLast() } else { undo() } }, commit: { change($0.id, to: $0) })
                            .overlay { if image == nil { ProgressView().controlSize(.small) } }
                    }.background(Color(nsColor: .underPageBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                PinCanvasFooter(controls: zoomControls, tool: tool)
            }.padding(20)
                .frame(width: min(780, (NSScreen.main?.visibleFrame.width ?? 980) * 0.75),
                       height: min(590, (NSScreen.main?.visibleFrame.height ?? 800) * 0.72))
        }
    }
}
