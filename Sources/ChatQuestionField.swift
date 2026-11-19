import SwiftUI

// Keep normal text editing and IME composition in AppKit. Only file and image
// pasteboard items take the attachment path.
struct ChatQuestionField: NSViewRepresentable {
    @Binding var text: String
    let pasteboard: NSPasteboard
    let editable: Bool
    let focusRequest: Int
    let attach: ([ChatFile.Input]) -> Void
    let submit: () -> Void

    final class Editor: NSTextView {
        var attach: (([ChatFile.Input]) -> Void)?
        var submit: (() -> Void)?
        var inputBoard = NSPasteboard.general
        private var needsFocus = false
        func requestFocus() {
            needsFocus = true
            focusWhenAttached()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if needsFocus { focusWhenAttached() }
        }
        private func focusWhenAttached() {
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsFocus, self.isEditable, let window = self.window, window.attachedSheet == nil else { return }
                self.needsFocus = !window.makeFirstResponder(self)
            }
        }
        func accept(_ board: NSPasteboard) -> Bool {
            guard isEditable else { return false }
            let items = ChatFile.inputs(on: board)
            guard !items.isEmpty else { return false }
            attach?(items)
            return true
        }
        override func paste(_ sender: Any?) {
            if accept(inputBoard) { return }
            if let plain = inputBoard.string(forType: .string) {
                insertText(plain, replacementRange: selectedRange())
            } else { super.pasteAsPlainText(sender) }
        }
        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            super.readablePasteboardTypes + [.fileURL, .pdf] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        }
        override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            accept(pboard) || super.readSelection(from: pboard, type: type)
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            accept(sender.draggingPasteboard) || super.performDragOperation(sender)
        }
        override func keyDown(with event: NSEvent) {
            if [36, 76].contains(event.keyCode), !hasMarkedText(), event.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty {
                submit?()
            } else { super.keyDown(with: event) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var value: Binding<String>
        var lastFocus: Int?
        init(_ value: Binding<String>) { self.value = value }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? Editor { value.wrappedValue = editor.string }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($text) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = Editor()
        view.isRichText = false; view.allowsUndo = true; view.drawsBackground = false
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = .zero
        view.font = .systemFont(ofSize: 15)
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? Editor else { return }
        context.coordinator.value = $text
        view.inputBoard = pasteboard
        view.attach = attach; view.submit = submit; view.isEditable = editable
        view.setAccessibilityLabel(bilingual("输入问题", "Question"))
        if view.string != text && !view.hasMarkedText() { view.string = text }
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            view.requestFocus()
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let editor = nsView.documentView as? Editor, let font = editor.font else { return nil }
        let measured = (text + " ").boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        return CGSize(width: width, height: min(74, max(36, ceil(measured) + 2)))
    }
}
