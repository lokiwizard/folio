import SwiftUI
import WebKit

struct MathAnswer: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 0

    static let page = Bundle.main.url(forResource: "answer", withExtension: "html", subdirectory: "Math")
    static func containsMarkup(_ text: String) -> Bool {
        if text.contains("**") || text.contains("__") || text.contains(#"\("#) || text.contains(#"\["#) { return true }
        guard let first = text.firstIndex(of: "$") else { return false }
        return text[text.index(after: first)...].contains("$")
    }

    static func nativeEmphasis(_ text: String) -> AttributedString? {
        guard text.contains("**") || text.contains("__"),
              !text.contains("$"), !text.contains(#"\("#), !text.contains(#"\["#),
              let rich = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return nil }
        let visible = String(rich.characters)
        // Fall back to the math-aware renderer for delimiter pairs Foundation leaves in CJK prose.
        return visible.contains("**") || visible.contains("__") ? nil : rich
    }
    var body: some View {
        if let rich = Self.nativeEmphasis(text) {
            Text(rich).textSelection(.enabled).font(InspectorType.reading).lineSpacing(4)
        } else if let page = Self.page, Self.containsMarkup(text) {
            ZStack(alignment: .topLeading) {
                if height == 0 { plainText }
                MathSurface(page: page, text: text, dark: scheme == .dark, height: $height)
                    .frame(height: max(1, height)).opacity(height == 0 ? 0 : 1)
            }
        } else { plainText }
    }
    private var plainText: some View {
        Text(text).textSelection(.enabled).font(InspectorType.reading).lineSpacing(4)
    }
}

struct MathSurface: NSViewRepresentable {
    let page: URL
    let text: String
    let dark: Bool
    @Binding var height: CGFloat

    // All formula views display bundled, offline resources in the same ephemeral store.
    private static let formulaStore = WKWebsiteDataStore.nonPersistent()
    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.formulaStore
        config.userContentController.add(context.coordinator, name: "answerHeight")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let state = context.coordinator
        state.source = text
        state.dark = dark
        state.update(view)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "answerHeight")
        view.navigationDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var source = ""
        var dark = false
        private var rendered: String?
        private var renderedDark = false
        private var ready = false
        private var inFlight = false
        private let height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            rendered = nil
            update(view)
        }
        func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
            ready = false
            inFlight = false
            height.wrappedValue = 0
            view.reload()
        }
        func update(_ view: WKWebView) {
            guard ready, !inFlight, source != rendered || dark != renderedDark else { return }
            rendered = source
            renderedDark = dark
            inFlight = true
            view.callAsyncJavaScript("renderAnswer(source, dark); return true", arguments: ["source": source, "dark": dark],
                                     in: nil, in: .page) { [weak self, weak view] result in
                guard let self, let view else { return }
                self.inFlight = false
                if case .failure = result { self.height.wrappedValue = 0 }
                self.update(view)
            }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let measured = message.body as? Double, measured > 0, measured.isFinite else { return }
            if height.wrappedValue != CGFloat(measured) { height.wrappedValue = CGFloat(measured) }
        }
    }
}
