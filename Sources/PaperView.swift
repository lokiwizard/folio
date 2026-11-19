import AppKit
import PDFKit
import SwiftUI

private final class Marquee: NSView {
    var region: CGRect? {
        didSet {
            guard oldValue != region else { return }
            if let oldValue { setNeedsDisplay(oldValue.insetBy(dx: -2, dy: -2)) }
            if let region { setNeedsDisplay(region.insetBy(dx: -2, dy: -2)) }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let region else { return }
        NSColor.systemBrown.withAlphaComponent(0.12).setFill()
        region.fill()
        let path = NSBezierPath(rect: region.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.5
        path.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.systemBrown.setStroke()
        path.stroke()
    }
}

private final class LinkHandler: NSObject, PDFViewDelegate {
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        if ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
    }
}

final class PaperView: PDFView {
    private let links = LinkHandler()
    weak var reader: Reader?
    private let marquee = Marquee()
    private var start: CGPoint?
    private weak var startPage: PDFPage?
    private var observations: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var scrollObserver: NSObjectProtocol?
    private weak var clip: NSClipView?
    private var lastSize = CGSize.zero
    private var fitQueued = false
    private var turnedDuringGesture = false

    init(reader: Reader) {
        self.reader = reader
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 620))
        delegate = links
        displayBox = .cropBox
        backgroundColor = .underPageBackgroundColor
        pageBreakMargins = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        minScaleFactor = 0.08
        maxScaleFactor = 8
        marquee.frame = bounds
        marquee.autoresizingMask = [.width, .height]
        addSubview(marquee)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            if let self, event.window === self.window {
                DispatchQueue.main.async { [weak self] in self?.reader?.refreshSelectionFrame() }
            }
            return event
        }
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewVisiblePagesChanged, .PDFViewChangedHistory, .PDFViewSelectionChanged] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] note in
                guard let self else { return }
                MainActor.assumeIsolated {
                    // PDFKit may track the drag inside mouseDown and reset the cursor between selection updates.
                    if note.name == .PDFViewSelectionChanged, (self.window as? ReaderWindow)?.selectingTextIn === self {
                        NSCursor.iBeam.set()
                    }
                    self.reader?.viewChanged(note.name, view: self)
                }
            })
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, reader != nil {
            (window as? ReaderWindow)?.readingPaper = self
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.reader?.restoreIfReady(self)
            }
        }
    }
    override func layout() {
        super.layout()
        if let found = documentView?.enclosingScrollView?.contentView, found !== clip {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            clip = found
            found.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: found, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reader?.refreshSelectionFrame()
                    self?.refreshMarquee()
                    self?.reader?.scheduleSave()
                }
            }
        }
        if lastSize != bounds.size {
            lastSize = bounds.size
            guard !fitQueued else { return }
            fitQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fitQueued = false
                guard self.reader?.pdf === self else { return }
                self.reader?.applyFit()
                self.reader?.refreshSelectionFrame()
                self.refreshMarquee()
            }
        }
    }
    func detach() {
        if let window {
            if let readerWindow = window as? ReaderWindow, readerWindow.readingPaper === self {
                readerWindow.readingPaper = nil
            }
            if let focused = window.firstResponder as? NSView, focused === self || focused.isDescendant(of: self) {
                window.makeFirstResponder(nil)
            }
        }
        isHidden = true
        reader = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        delegate = nil
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        highlightedSelections = nil
        // PDFKit still owns in-flight page draws when a paper is closed. Keep
        // the document with its retired view until AppKit releases that view.
    }
    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        observations.forEach(NotificationCenter.default.removeObserver)
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if reader?.regionMode == true, !isHidden, frame.contains(point) { return self }
        return super.hitTest(point)
    }
    func readingCursor(for area: PDFAreaOfInterest) -> NSCursor {
        if reader?.regionMode == true { return .crosshair }
        if (window as? ReaderWindow)?.selectingTextIn === self { return .iBeam }
        return area.contains(.textArea) || area.contains(.textFieldArea) ? .iBeam : .arrow
    }
    override func setCursorFor(_ area: PDFAreaOfInterest) { readingCursor(for: area).set() }
    func focusHighlight(for event: NSEvent) {
        guard let reader else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard !reader.regionMode, event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
              let page = page(for: point, nearest: false),
              !areaOfInterest(forMouse: event).contains(.linkArea) else {
            reader.focusHighlight(nil)
            return
        }
        reader.focusHighlight(reader.highlightHit(at: convert(point, to: page), on: page))
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if reader?.regionMode == true { addCursorRect(visibleRect, cursor: .crosshair) }
    }
    override func mouseDown(with event: NSEvent) {
        guard reader?.regionMode == true else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        startPage = page(for: p, nearest: false)
        start = startPage.map { convert(p, to: $0) }
        reader?.region = nil
        reader?.refreshSelectionFrame()
        clearSelection()
        refreshMarquee()
    }
    override func mouseDragged(with event: NSEvent) {
        guard reader?.regionMode == true else { super.mouseDragged(with: event); return }
        guard let start, let page = startPage, let document else { return }
        let end = convert(convert(event.locationInWindow, from: nil), to: page)
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            .intersection(page.bounds(for: displayBox))
        if rect.width >= 2, rect.height >= 2 { reader?.region = Anchor(page: document.index(for: page), rect: rect) }
        refreshMarquee()
    }
    override func mouseUp(with event: NSEvent) {
        guard reader?.regionMode == true else { super.mouseUp(with: event); return }
        mouseDragged(with: event)
        start = nil
        startPage = nil
        reader?.refreshSelectionFrame()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, reader?.focusedHighlight != nil { reader?.focusHighlight(nil); return }
        if event.keyCode == 53, reader?.regionMode == true { reader?.setRegionMode(false); return }
        guard Self.isReadingKey(event), let reader else { super.keyDown(with: event); return }
        let wholePage = displayMode == .singlePage && reader.state.zoom == .page
        switch event.keyCode {
        case 115: reader.go(0)
        case 119: reader.go((document?.pageCount ?? 1) - 1)
        case 123, 124:
            guard reader.state.zoom != .fixed else { super.keyDown(with: event); return }
            turnPage(forward: event.keyCode == 124)
        case 116, 121, 125, 126, 49:
            guard wholePage else { super.keyDown(with: event); return }
            let forward = event.keyCode == 121 || event.keyCode == 125 || (event.keyCode == 49 && !event.modifierFlags.contains(.shift))
            turnPage(forward: forward)
        default: super.keyDown(with: event)
        }
    }
    static func isReadingKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              !event.modifierFlags.contains(.shift) || event.keyCode == 49 else { return false }
        return [49, 115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode)
    }
    private func turnPage(forward: Bool) {
        if forward && canGoToNextPage { goToNextPage(nil) }
        if !forward && canGoToPreviousPage { goToPreviousPage(nil) }
    }

    func scrollPaper(with event: NSEvent) -> Bool {
        guard let scroll = documentView?.enclosingScrollView else { return false }
        let dy = event.scrollingDeltaY
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            turnedDuringGesture = false
        }
        if displayMode == .singlePage, abs(dy) > abs(event.scrollingDeltaX), !event.modifierFlags.contains(.shift) {
            if turnedDuringGesture { return true }
            let clip = scroll.contentView
            let step: CGFloat = (dy < 0) == clip.isFlipped ? 1 : -1
            let next = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: step))
            if reader?.state.zoom == .page || abs(next.minY - clip.bounds.minY) < 0.01 {
                if event.momentumPhase.isEmpty && event.phase.intersection([.ended, .cancelled]).isEmpty {
                    turnPage(forward: dy < 0)
                    turnedDuringGesture = !event.phase.isEmpty
                }
                return true
            }
        }
        scroll.scrollWheel(with: event)
        return true
    }
    override func copy(_ sender: Any?) {
        if reader?.region != nil { reader?.copyRegion() } else { super.copy(sender) }
    }
    func zoomWithWheel(_ event: NSEvent, at pointer: CGPoint) -> Bool {
        let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        guard delta.isFinite, delta != 0, let reader else { return false }
        if !event.momentumPhase.isEmpty { return true }
        guard let page = page(for: pointer, nearest: true) else { return false }
        let anchor = convert(pointer, to: page)
        let steps: CGFloat = event.hasPreciseScrollingDeltas ? min(3, max(-3, delta / 35)) : (delta > 0 ? 1 : -1)
        let current = scaleFactor
        let scale = min(maxScaleFactor, max(minScaleFactor, current * pow(1.2, steps)))
        guard scale != current else { return true }
        reader.setZoom(.fixed, value: scale)

        if let scroll = documentView?.enclosingScrollView {
            let clip = scroll.contentView
            let target = clip.convert(convert(anchor, from: page), from: self)
            let cursor = clip.convert(pointer, from: self)
            let shifted = clip.bounds.offsetBy(dx: target.x - cursor.x, dy: target.y - cursor.y)
            clip.scroll(to: clip.constrainBoundsRect(shifted).origin)
            scroll.reflectScrolledClipView(clip)
        }
        return true
    }
    override func magnify(with event: NSEvent) {
        reader?.state.zoom = .fixed
        super.magnify(with: event)
        reader?.state.scale = scaleFactor
    }
    // Local top-leading coordinates for SwiftUI. Prefer a visible page for multi-page selections.
    func visibleSelectionFrame() -> CGRect? {
        guard start == nil, window != nil, let reader else { return nil }
        let area: CGRect
        if let region = reader.region, let page = document?.safePage(region.page) {
            area = convert(region.rect, from: page).intersection(visibleRect)
        } else if let hit = reader.focusedHighlight, let page = document?.safePage(hit.line.page) {
            area = convert(hit.line.rect, from: page).intersection(visibleRect)
        } else if reader.hasText, NSEvent.pressedMouseButtons & 1 == 0, let selection = currentSelection {
            guard let page = visiblePages.first(where: { selection.pages.contains($0) &&
                convert(selection.bounds(for: $0), from: $0).intersects(visibleRect) }) else { return nil }
            area = convert(selection.bounds(for: page), from: page).intersection(visibleRect)
        } else { return nil }
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        return CGRect(x: area.minX - bounds.minX, y: isFlipped ? area.minY - bounds.minY : bounds.maxY - area.maxY,
                      width: area.width, height: area.height)
    }
    func refreshMarquee() {
        guard let source = reader?.region, let page = document?.safePage(source.page) else { marquee.region = nil; return }
        if subviews.last !== marquee { addSubview(marquee, positioned: .above, relativeTo: nil) }
        marquee.region = marquee.convert(convert(source.rect, from: page), from: self)
    }

}

struct PaperCanvas: NSViewRepresentable {
    let pdf: PaperView
    func makeNSView(context: Context) -> PaperView { pdf }
    func updateNSView(_ view: PaperView, context: Context) {}
}
