import AppKit
import SwiftUI

// Pointer movement repositions the lifted bitmap and edge hint without laying out the list.
@MainActor
final class CardDrag: ObservableObject {
    struct Placement: Equatable {
        let source: CardReference
        var target: CardReference
        var after: Bool
    }
    @Published private(set) var placement: Placement?
    @Published private(set) var overTrash = false
    weak var trash: CardTrashView?
    weak var chatTarget: CardTrashView?
    @Published private(set) var overChat = false
    private let markers = NSMapTable<NSUUID, CardMarkerView>.strongToWeakObjects()
    private var source: CardReference?
    private var commit: ((CardReference, CardReference, Bool) -> Bool)?
    private weak var window: NSWindow?
    private weak var scroll: NSScrollView?
    private var down = CGPoint.zero
    private var pointer = CGPoint.zero
    private var original = CGRect.zero
    private var crop = CGRect.zero
    private var image: LiftedCard?
    private var edgeTimer: Timer?
    private var deletionFeedback: CardDeletionFeedback?
    private var leftmostX: CGFloat = 0

    func arrange<T: Identifiable>(_ items: [T]) -> [T] where T.ID == UUID {
        guard let p = placement, p.source.id != p.target.id,
              let from = items.firstIndex(where: { $0.id == p.source.id }),
              let to = items.firstIndex(where: { $0.id == p.target.id }) else { return items }
        var result = items
        result.move(fromOffsets: [from], toOffset: to + (p.after ? 1 : 0))
        return result
    }

    func register(_ marker: CardMarkerView) {
        markers.setObject(marker, forKey: marker.reference.id as NSUUID)
        (marker.window as? ReaderWindow)?.cards = self
    }
    func unregister(_ marker: CardMarkerView) {
        let key = marker.reference.id as NSUUID
        if markers.object(forKey: key) === marker { markers.removeObject(forKey: key) }
    }
    func card(at point: CGPoint, in window: NSWindow?) -> CardMarkerView? {
        let cards = markers.objectEnumerator()?.allObjects as? [CardMarkerView] ?? []
        return cards.first { card in
            guard card.window === window, !card.isHiddenOrHasHiddenAncestor, card.cardFrame.contains(point),
                  let clip = card.enclosingScrollView?.contentView else { return false }
            return clip.convert(clip.bounds, to: nil).contains(point)
        }
    }
    func arm(_ marker: CardMarkerView, at point: CGPoint) {
        cancel()
        guard let window = marker.window, let scroll = marker.enclosingScrollView else { return }
        self.window = window; self.scroll = scroll
        source = marker.reference
        commit = marker.commit
        down = point; pointer = point
        leftmostX = point.x
        original = marker.cardFrame
    }
    private var viewport: CGRect {
        guard let clip = scroll?.contentView else { return .null }
        return clip.convert(clip.bounds, to: nil)
    }
    func move(to point: CGPoint) {
        guard let source, let content = window?.contentView, let host = content.superview else { return }
        if image == nil {
            guard let documentView = scroll?.documentView else { cancel(); return }
            // Include off-screen portions of normal cards, and bound the bitmap for an unusually long note.
            crop = original.intersection(viewport.insetBy(dx: 0, dy: -viewport.height))
            let rect = documentView.convert(crop, from: nil)
            guard !crop.isEmpty, let rep = documentView.bitmapImageRepForCachingDisplay(in: rect) else { cancel(); return }
            documentView.cacheDisplay(in: rect, to: rep)
            let snapshot = NSImage(size: rect.size)
            snapshot.addRepresentation(rep)
            let lifted = LiftedCard(frame: host.convert(crop, from: nil), snapshot: snapshot)
            host.addSubview(lifted, positioned: .above, relativeTo: nil)
            image = lifted
            if let trash, trash.window === window {
                let feedback = CardDeletionFeedback()
                host.addSubview(feedback, positioned: .above, relativeTo: lifted)
                deletionFeedback = feedback
            }
            placement = Placement(source: source, target: source, after: false)
        }
        pointer = point
        let full = crop.offsetBy(dx: point.x - down.x, dy: point.y - down.y)
        var frame = full
        var onChat = false
        if let chatTarget, chatTarget.window === window, !chatTarget.isHiddenOrHasHiddenAncestor {
            let target = chatTarget.convert(chatTarget.bounds, to: nil)
            onChat = target.contains(point)
            if onChat || point.x < viewport.minX || down.x - point.x > 4 {
                frame = previewFrame(full, at: point, approaching: target, in: content.convert(content.bounds, to: nil))
            }
        }
        image?.frame = host.convert(frame, from: nil)
        if onChat != overChat { overChat = onChat }
        if let trash, trash.window === window {
            let edge = trash.convert(trash.bounds, to: nil)
            leftmostX = min(leftmostX, point.x)
            // A vertical reorder can start on or just beside the edge. Arm on intentional rightward travel.
            let aimed = point.x - leftmostX >= 8
            let armed = !onChat && aimed && trash.contains(point, in: window)
            if overTrash != armed { overTrash = armed }
            deletionFeedback?.isHidden = onChat
            deletionFeedback?.track(edge: edge, point: point, armed: armed, in: host)
        }
        if overTrash || onChat {
            edgeTimer?.invalidate(); edgeTimer = nil
            return
        }
        updateTarget()
        updateEdgeScroll()
    }
    private func previewFrame(_ full: CGRect, at point: CGPoint, approaching target: CGRect, in content: CGRect) -> CGRect {
        func distance(_ p: CGPoint) -> CGFloat {
            hypot(max(0, target.minX - p.x, p.x - target.maxX), max(0, target.minY - p.y, p.y - target.maxY))
        }
        let approach = 1 - distance(point) / min(120, max(1, distance(down)))
        let departure = (viewport.minX - point.x) / 80
        let t = min(1, max(0, approach, departure))
        guard t > 0 else { return full }
        let progress = t * t * (3 - 2 * t)
        let scale = min(1, 60 / full.width, 40 / full.height)
        let size = CGSize(width: full.width * scale, height: full.height * scale)
        let x = min(point.x + 10, content.maxX - size.width - 4)
        let y = point.y + 10 + size.height < content.maxY ? point.y + 10 : point.y - size.height - 10
        return CGRect(x: full.minX + (x - full.minX) * progress, y: full.minY + (y - full.minY) * progress,
                      width: full.width + (size.width - full.width) * progress,
                      height: full.height + (size.height - full.height) * progress)
    }
    private func updateTarget() {
        let area = viewport
        guard let source, area.contains(pointer) else { return }
        let cards = markers.objectEnumerator()?.allObjects as? [CardMarkerView] ?? []
        let visible = cards.filter { $0.window === window && $0.reference.document == source.document &&
            $0.reference.list == source.list && $0.cardFrame.intersects(area) && !$0.isHiddenOrHasHiddenAncestor }
        // Clamp to the ends of real cards, so the gaps and bottom padding are valid drop locations.
        func distance(_ frame: CGRect) -> CGFloat { max(0, max(frame.minY - pointer.y, pointer.y - frame.maxY)) }
        guard let target = visible.min(by: { distance($0.cardFrame) < distance($1.cardFrame) }),
              target.reference.id != source.id else { return }
        let next = Placement(source: source, target: target.reference, after: pointer.y < target.cardFrame.midY)
        guard placement != next else { return }
        withAnimation(motion) { placement = next }
    }
    private var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)
    }
    private var scrollSpeed: CGFloat {
        let v = viewport
        guard v.contains(pointer) else { return 0 }
        let edge: CGFloat = 36
        if pointer.y > v.maxY - edge { return -11 * (pointer.y - (v.maxY - edge)) / edge }
        if pointer.y < v.minY + edge { return 11 * ((v.minY + edge) - pointer.y) / edge }
        return 0
    }
    private func updateEdgeScroll() {
        if scrollSpeed == 0 { edgeTimer?.invalidate(); edgeTimer = nil; return }
        guard edgeTimer == nil else { return }
        let timer = Timer(timeInterval: 1/60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollStep() }
        }
        edgeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func scrollStep() {
        guard let scroll, source != nil, let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        var proposed = clip.bounds
        proposed.origin.y += doc.isFlipped ? scrollSpeed : -scrollSpeed
        let next = clip.constrainBoundsRect(proposed).origin
        guard next != clip.bounds.origin else { edgeTimer?.invalidate(); edgeTimer = nil; return }
        clip.scroll(to: next)
        scroll.reflectScrolledClipView(clip)
        updateTarget()
    }
    func finish(at point: CGPoint) {
        guard let source else { return }
        if image != nil && point != pointer { move(to: point) }
        if placement != nil, let chatTarget, chatTarget.contains(point, in: window) {
            stopTracking()
            if motion != nil, let outgoing = image, let host = outgoing.superview {
                // The composer can expand as soon as the attachment is added. Land inside the original target.
                let target = chatTarget.convert(chatTarget.bounds, to: nil).insetBy(dx: 8, dy: 8)
                let x = min(target.maxX, max(target.minX, point.x))
                let y = min(target.maxY, max(target.minY, point.y))
                let scale = 4 / max(4, outgoing.bounds.width, outgoing.bounds.height)
                let width = outgoing.bounds.width * scale, height = outgoing.bounds.height * scale
                let end = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
                image = nil
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    outgoing.animator().frame = host.convert(end, from: nil)
                    outgoing.animator().alphaValue = 0
                } completionHandler: { outgoing.removeFromSuperview() }
            }
            clearLift()
            chatTarget.remove?(source)
            return
        }
        if placement != nil, overTrash, let trash, trash.contains(point, in: window) {
            stopTracking()
            // Commit on mouse-up. Let the outgoing snapshot finish independently of the next drag.
            if motion != nil, let outgoing = image {
                image = nil
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    outgoing.animator().frame = outgoing.frame.offsetBy(dx: 24, dy: 0)
                    outgoing.animator().alphaValue = 0
                } completionHandler: { outgoing.removeFromSuperview() }
            }
            clearLift()
            trash.remove?(source)
            return
        }
        guard let p = placement, viewport.contains(point), let image, let host = image.superview else { cancel(); return }
        // The dimmed source row already occupies its final slot; replace its draft with the saved order once.
        window?.contentView?.layoutSubtreeIfNeeded()
        let target = markers.object(forKey: source.id as NSUUID)?.cardFrame
        if p.target != source && commit?(source, p.target, p.after) != true { cancel(); return }
        stopTracking()
        guard let target, !target.isEmpty, motion != nil else { clearLift(); return }
        let end = CGRect(x: target.minX + crop.minX - original.minX, y: target.maxY + crop.minY - original.maxY,
                         width: crop.width, height: crop.height)
        // The model owns the row again on mouse-up. Only the outgoing bitmap is still moving.
        self.image = nil
        clearLift()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            image.animator().frame = host.convert(end, from: nil)
            image.animator().alphaValue = 0
        } completionHandler: { image.removeFromSuperview() }
    }
    func cancel() {
        stopTracking()
        if placement != nil { withAnimation(motion) { placement = nil } }
        clearLift()
    }
    private func stopTracking() {
        deletionFeedback?.removeFromSuperview(); deletionFeedback = nil
        edgeTimer?.invalidate(); edgeTimer = nil
        source = nil; commit = nil
    }
    private func clearLift() {
        if overChat { overChat = false }
        if overTrash { overTrash = false }
        image?.removeFromSuperview(); image = nil
        if placement != nil { placement = nil }
    }
}
// This window-level view draws above every list row and follows both axes without relaying out the list.
final class LiftedCard: NSView {
    private let originalSize: CGSize
    private let face = NSImageView()
    init(frame: CGRect, snapshot: NSImage) {
        originalSize = frame.size
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        face.frame = bounds
        face.image = snapshot
        face.imageScaling = .scaleAxesIndependently
        face.autoresizingMask = [.width, .height]
        face.wantsLayer = true
        face.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        face.layer?.cornerRadius = 10
        face.layer?.masksToBounds = true
        addSubview(face)
        updateShadow()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { updateShadow() }
    }
    private func updateShadow() {
        let scale = min(1, bounds.width / max(1, originalSize.width), bounds.height / max(1, originalSize.height))
        let radius = max(1, 10 * scale)
        face.layer?.cornerRadius = radius
        layer?.shadowRadius = max(1, 6 * scale)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Delay only a card's primary click until the pointer chooses a click or a reorder.
// Native menus can enter their own tracking loop, so queue the matching release before delivering the click.
final class ReaderWindow: NSWindow {
    let thumbnailSurfaces = NSHashTable<PinThumbnailSurface>.weakObjects()
    weak var readingPaper: PaperView?
    weak var cards: CardDrag?
    weak var transcriptMarker: TranscriptScrollMarker.Marker?
    weak var timelineMarker: NSView?
    private var press: NSEvent?
    private weak var pressedCard: CardMarkerView?
    private var draggingCard = false
    private(set) weak var selectingTextIn: PaperView?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, attachedSheet == nil,
           abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            let point = event.window == nil ? convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
            if scroll(event, at: point, in: timelineMarker) { return }
            if scroll(event, at: point, in: transcriptMarker) {
                transcriptMarker?.rememberPosition()
                return
            }
        }
        switch event.type {
        case .scrollWheel where attachedSheet == nil:
            let point = event.window == nil ? convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
            if event.modifierFlags.intersection([.control, .command, .option]) == .control {
                for thumbnail in thumbnailSurfaces.allObjects where !thumbnail.isHiddenOrHasHiddenAncestor {
                    let local = thumbnail.convert(point, from: nil)
                    if thumbnail.visibleRect.contains(local) {
                        thumbnail.wheelZoom(event, at: local)
                        return
                    }
                }
            }
            if let paper = paper(at: point) {
                if event.modifierFlags.contains(.control) {
                    if paper.zoomWithWheel(event, at: paper.convert(point, from: nil)) { return }
                } else if event.modifierFlags.intersection([.option, .command]).isEmpty,
                          paper.scrollPaper(with: event) { return }
            }
        case .keyDown where press == nil && attachedSheet == nil && firstResponder === self && PaperView.isReadingKey(event):
            if let paper = readingPaper, paper.window === self, makeFirstResponder(paper) {
                paper.keyDown(with: event)
                return
            }
        case .leftMouseDown:
            endTextSelection()
            if attachedSheet == nil, let paper = paper(at: event.locationInWindow) {
                makeFirstResponder(paper)
                paper.focusHighlight(for: event)
                if paper.readingCursor(for: paper.areaOfInterest(forMouse: event)) == .iBeam {
                    selectingTextIn = paper
                    NSCursor.iBeam.set()
                }
            }
            if let marker = transcriptMarker, let bar = marker.enclosingScrollView?.verticalScroller,
               bar.bounds.contains(bar.convert(event.locationInWindow, from: nil)) { marker.trackingScroller = true }
            if attachedSheet == nil, !event.modifierFlags.contains(.control),
               let marker = cards?.card(at: event.locationInWindow, in: self) {
                if !isKeyWindow { makeKeyAndOrderFront(nil) }
                press = event; pressedCard = marker; draggingCard = false
                marker.showPress(true)
                return
            }
        case .leftMouseDragged:
            if let press {
                let point = event.locationInWindow
                if !draggingCard {
                    guard hypot(point.x - press.locationInWindow.x, point.y - press.locationInWindow.y) >= 4 else { return }
                    draggingCard = true
                    pressedCard?.showPress(false)
                    if let marker = pressedCard { cards?.arm(marker, at: press.locationInWindow) }
                }
                cards?.move(to: point)
                return
            }
        case .keyDown where event.keyCode == 53 && draggingCard:
            cards?.cancel()
            return
        case .leftMouseUp:
            if let press {
                let didDrag = draggingCard
                let target = cards?.card(at: event.locationInWindow, in: self)
                let validClick = pressedCard != nil && pressedCard === target
                resetCardPress()
                if didDrag { cards?.finish(at: event.locationInWindow) }
                else if validClick {
                    NSApp.postEvent(event, atStart: true)
                    super.sendEvent(press)
                }
                return
            }
        default: break
        }
        super.sendEvent(event)
        // SwiftUI and PDFKit both track the canvas. Resolve the cursor for the
        // frontmost PDF surface after native mouse handling has finished.
        switch event.type {
        case .leftMouseDown where selectingTextIn != nil && NSEvent.pressedMouseButtons & 1 == 0:
            // PDFKit may have consumed the matching release in its nested mouseDown loop.
            endTextSelection()
        case .leftMouseDragged where selectingTextIn != nil:
            NSCursor.iBeam.set()
        case .mouseMoved, .leftMouseUp:
            endTextSelection()
            if attachedSheet == nil {
                var hit = contentHit(at: event.locationInWindow)
                while let view = hit {
                    if let editor = view as? NSTextView, editor.isEditable { NSCursor.iBeam.set(); break }
                    if let paper = view as? PaperView { paper.setCursorFor(paper.areaOfInterest(forMouse: event)); break }
                    hit = view.superview
                }
            }
        default: break
        }
        // Native scrollers can track the whole gesture inside mouseDown.
        if let marker = transcriptMarker, marker.trackingScroller {
            marker.rememberPosition()
            marker.trackingScroller = false
        }
    }
    // Route a wheel event to exactly one viewport, even over a SwiftUI button or a WebKit answer.
    private func scroll(_ event: NSEvent, at point: CGPoint, in marker: NSView?) -> Bool {
        guard let marker, marker.window === self, !marker.isHiddenOrHasHiddenAncestor,
              let scroll = marker.enclosingScrollView else { return false }
        let clip = scroll.contentView
        guard clip.bounds.contains(clip.convert(point, from: nil)) else { return false }
        let unit = event.hasPreciseScrollingDeltas ? 1 : max(1, scroll.verticalLineScroll)
        let dy = event.scrollingDeltaY * unit * (clip.isFlipped ? -1 : 1)
        let target = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: dy))
        clip.scroll(to: target.origin)
        scroll.reflectScrolledClipView(clip)
        return true
    }
    private func contentHit(at point: CGPoint) -> NSView? {
        guard let content = contentView, let parent = content.superview else { return nil }
        return content.hitTest(parent.convert(point, from: nil))
    }
    private func paper(at point: CGPoint) -> PaperView? {
        var hit = contentHit(at: point)
        while let view = hit {
            if let paper = view as? PaperView { return paper }
            hit = view.superview
        }
        return nil
    }

    func endTextSelection() {
        guard let paper = selectingTextIn else { return }
        selectingTextIn = nil
        paper.reader?.refreshSelectionFrame()
    }
    override func resignKey() {
        endTextSelection()
        resetCardPress()
        cards?.cancel()
        super.resignKey()
    }
    private func resetCardPress() {
        pressedCard?.showPress(false)
        pressedCard = nil; draggingCard = false; press = nil
    }
}

final class CardMarkerView: NSView {
    var reference: CardReference
    weak var drag: CardDrag?
    var commit: ((CardReference, CardReference, Bool) -> Bool)?
    init(_ reference: CardReference) { self.reference = reference; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    var cardFrame: CGRect { convert(bounds, to: nil) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func showPress(_ pressed: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = pressed ? NSColor.labelColor.withAlphaComponent(0.055).cgColor : nil
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { drag?.register(self) } else { drag?.unregister(self) }
    }
}

struct CardMarker: NSViewRepresentable {
    let reference: CardReference
    let drag: CardDrag
    let commit: (CardReference, CardReference, Bool) -> Bool
    func makeNSView(context: Context) -> CardMarkerView { CardMarkerView(reference) }
    func updateNSView(_ view: CardMarkerView, context: Context) {
        if view.reference != reference || view.drag !== drag { view.drag?.unregister(view) }
        view.reference = reference; view.drag = drag; view.commit = commit
        drag.register(view)
    }
    static func dismantleNSView(_ view: CardMarkerView, coordinator: ()) { view.drag?.unregister(view) }
}

final class CardTrashView: NSView {
    var remove: ((CardReference) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func contains(_ point: CGPoint, in window: NSWindow?) -> Bool {
        self.window != nil && self.window === window && convert(bounds, to: nil).contains(point)
    }
}

struct TrashMarker: NSViewRepresentable {
    var chat = false
    let drag: CardDrag
    let remove: (CardReference) -> Void
    func makeNSView(context: Context) -> CardTrashView {
        let view = CardTrashView()
        view.identifier = NSUserInterfaceItemIdentifier(chat ? "chatDropTarget" : "cardTrashTarget")
        return view
    }
    func updateNSView(_ view: CardTrashView, context: Context) {
        view.remove = remove
        if chat { drag.chatTarget = view } else { drag.trash = view }
    }
}
