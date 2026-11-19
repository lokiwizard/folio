import SwiftUI
import PDFKit
import UniformTypeIdentifiers

enum Panel: String, CaseIterable { case pins = "便签", notes = "批注", chat = "问 AI" }
enum NavigationTab: String, CaseIterable { case pages = "页面", outline = "目录", marks = "书签" }
struct SearchHit { var page: Int; var range: NSRange }
struct HighlightHit: Equatable {
    let id: UUID
    let line: Anchor
}
struct Citation: Identifiable, Codable { var id = UUID(); let documentKey: String; var text: String; var anchors: [Anchor]; var pages: [Int] { Array(Set(anchors.map(\.page))).sorted() } }

@MainActor
final class Reader: ObservableObject {
    @Published private(set) var language: InterfaceLanguage = .chinese
    func switchLanguage(_ next: InterfaceLanguage) {
        UIStrings.language = next
        language = next
        prefs.language = next
        if Bundle.main.bundleIdentifier == "app.folio.reader" {
            UserDefaults.standard.set([next.rawValue], forKey: "AppleLanguages")
        }
        persistPreferences()
        NotificationCenter.default.post(name: .interfaceLanguageChanged, object: nil)
    }
    let secrets: CredentialStore
    let store: LocalStore
    private let imagePasteboard: NSPasteboard
    @Published var prefs: Preferences
    @Published var state = PaperState() { didSet { scheduleSave() } }
    @Published var pdf: PaperView?
    var document: PDFDocument? { pdf?.document }
    var key: String?
    private var documentPassword: String?
    private var openedFile: PaperFile?
    var file: URL? { openedFile?.original }
    var title: String { file?.deletingPathExtension().lastPathComponent ?? "Folio" }
    @Published private(set) var lastDeletion: CardDeletion?
    @Published var pageIndex = 0
    @Published var scale: CGFloat = 1
    @Published var canBack = false
    @Published var showLeft = false
    @Published var showRight = true
    @Published var nav: NavigationTab = .pages
    @Published var panel: Panel = .pins { didSet { if panel == .notes { indexHighlightsIfNeeded() } } }
    @Published var settings = false
    @Published var settingsTab: SettingsTab = .appearance
    @Published private(set) var selectionFrame: CGRect?
    @Published private(set) var focusedHighlight: HighlightHit?
    @Published var showFind = false
    @Published var query = ""
    @Published var searching = false
    @Published var hits: [SearchHit] = []
    @Published var hitIndex = 0
    private var hitsByPage: [Int: Range<Int>] = [:]
    @Published var regionMode = false
    @Published var region: Anchor?
    @Published var hasText = false
    @Published var error: String?
    @Published var locked: (URL, PDFDocument)?
    @Published var passwordError = false
    @Published var citation: Citation?
    @Published var chat: [ChatLine] = []
    var transcript: [ChatLine] = []
    @Published var conversations: [PaperChat] = []
    @Published var conversationID = UUID()
    @Published var wholePaper = true
    @Published var attachments: [CardAttachment] = []
    @Published var composerOpen = false
    @Published var partialAnswer = ""
    @Published private(set) var pendingTurn: ChatLine?
    private var historyReadable = true
    @Published var question = ""
    @Published var includePage = false
    @Published var sending = false
    @Published var chatError = ""
    private var saveTimer: Timer?
    private var searchTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var restoring = false
    private var prefsReadable = true
    private(set) var pinPreviews: PinPreviewStore?
    private(set) var pageThumbnails: PageThumbnailStore?
    @Published private(set) var highlightsLoaded = false
    private var originals: [Int: [PDFHighlightID: PDFAnnotation]] = [:]
    private var highlightIndexTask: Task<Void, Never>?
    private(set) var thumbnailMarksRevision = 0
    private var marks: [UUID: [PDFAnnotation]] = [:]

    private let askModel: ((Profile, [ChatLine]) async throws -> String)?
    init(store: LocalStore = LocalStore(), imagePasteboard: NSPasteboard = .general, askModel: ((Profile, [ChatLine]) async throws -> String)? = nil) {
        self.askModel = askModel
        self.store = store
        secrets = CredentialStore(root: store.root)
        self.imagePasteboard = imagePasteboard
        do { prefs = try store.read("library.json", fallback: Preferences()) }
        catch {
            prefs = Preferences()
            prefsReadable = false
            self.error = bilingual("无法读取本地设置。请检查 \(store.root.path)/library.json。", "Could not read settings at \(store.root.path)/library.json.")
        }
        if prefs.defaultTagID == nil {
            if !prefs.tags.contains(where: { $0.id == SemanticTag.general.id }) { prefs.tags.append(.general) }
            prefs.defaultTagID = SemanticTag.general.id
        }
        language = prefs.language ?? .chinese
        UIStrings.language = language
        if prefs.migratePresetColors() { persistPreferences() }
    }
    var profile: Profile? { prefs.profiles.first { $0.id == prefs.active } }
    var paperPrompts: [PaperPrompt] { prefs.paperPrompts ?? PaperPrompt.defaults }
    func savePaperPrompts(_ prompts: [PaperPrompt]) throws {
        guard prefsReadable else { throw ReaderError(bilingual("无法读取本机设置。", "Could not read local settings.")) }
        var next = prefs
        next.paperPrompts = try prompts.map { prompt in
            var clean = prompt
            clean.text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.text.isEmpty else { throw ReaderError(bilingual("请填写或删除空白提示词。", "Fill in or remove empty prompts.")) }
            return clean
        }
        try store.write(next, to: "library.json")
        prefs = next
    }
    func persistPreferences() {
        guard prefsReadable else { return }
        do { try store.write(prefs, to: "library.json") } catch { self.error = error.localizedDescription }
    }
    var appearance: InterfaceAppearance { prefs.appearance ?? .system }
    var glassStrength: Double { min(1, max(0, prefs.glassStrength ?? 0.65)) }
    var memoFontSize: Int {
        let range = Preferences.memoFontSizes
        return min(range.upperBound, max(range.lowerBound, prefs.memoFontSize ?? Preferences.defaultMemoFontSize))
    }
    var memoFont: Font { .system(size: CGFloat(memoFontSize)) }
    func setMemoFontSize(_ size: Int) {
        guard Preferences.memoFontSizes.contains(size), size != memoFontSize else { return }
        prefs.memoFontSize = size
        persistPreferences()
    }
    func setAppearance(_ value: InterfaceAppearance) {
        prefs.appearance = value
        NSApp.appearance = value.native
        persistPreferences()
    }
    func setGlassStrength(_ value: Double, persist: Bool = true) {
        let level = min(1, max(0, value))
        guard level != glassStrength else { return }
        prefs.glassStrength = level
        if persist { persistPreferences() }
    }
    func refreshSelectionFrame() {
        let next = pdf?.visibleSelectionFrame()
        if selectionFrame != next { selectionFrame = next }
    }
    func choose() {
        let panel = NSOpenPanel()
        panel.title = L("打开 PDF"); panel.prompt = L("打开")
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL) {
        guard url.isFileURL, let doc = PDFDocument(url: url) else { error = L("无法打开文件。请检查文件位置和 PDF 格式。"); return }
        if doc.isLocked { locked = (url, doc); passwordError = false; return }
        install(doc, url: url)
    }
    func unlock(_ password: String) {
        guard let (url, doc) = locked else { return }
        guard doc.unlock(withPassword: password) else { passwordError = true; return }
        locked = nil
        install(doc, url: url, password: password)
    }
    func install(_ doc: PDFDocument, url: URL, password: String? = nil) {
        guard doc.pageCount > 0 else { error = L("这份 PDF 没有可读取的页面。"); return }
        let id = LocalStore.identity(url)
        var saved: PaperState
        if id == key && !saveNow() { return }
        do { saved = try store.read(id + ".json", fallback: PaperState()) }
        catch { self.error = bilingual("无法读取这篇论文的阅读记录。", "Could not read the saved paper state. ") + error.localizedDescription; return }
        guard close() else { return }
        restoring = true
        key = id
        let source = PaperFile(url)
        openedFile = source
        documentPassword = password
        do { conversations = try store.read(id + "-chats.json", fallback: [PaperChat]()) }
        catch { historyReadable = false; self.error = error.localizedDescription }
        if let latest = conversations.first { openChat(latest) }
        pinPreviews = PinPreviewStore(file: source, password: password)
        pageThumbnails = PageThumbnailStore(file: source, password: password)
        let tags = Set(prefs.tags.map(\.id))
        let recolored = Set(prefs.tags.filter { $0.overridesSourceColor == true }.map(\.id))
        for i in saved.excerpts.indices {
            if saved.excerpts[i].tag.map(tags.contains) != true {
                saved.excerpts[i].tag = prefs.defaultTagID.flatMap { tags.contains($0) ? $0 : nil } ?? prefs.tags.first?.id
                if saved.excerpts[i].sourceHighlight != nil { saved.excerpts[i].usesTagColor = true }
            } else if let id = saved.excerpts[i].tag, recolored.contains(id), saved.excerpts[i].sourceHighlight != nil {
                saved.excerpts[i].usesTagColor = true
            }
        }
        state = saved
        let view = PaperView(reader: self)
        view.displayMode = saved.continuous ? .singlePageContinuous : .singlePage
        pdf = view
        view.document = doc
        for (index, rotation) in saved.rotations { doc.safePage(index)?.rotation = rotation }
        for source in saved.deletedHighlights ?? [] { setOriginal(source, visible: false) }
        for entry in saved.excerpts { installMark(entry) }
        view.layoutDocumentView()
        prefs.recents.removeAll { $0.id == id || $0.path == url.path }
        prefs.recents.insert(Recent(id: id, path: url.path, date: Date(), pages: doc.pageCount), at: 0)
        prefs.recents = Array(prefs.recents.prefix(30))
        persistPreferences()
        if view.window != nil { restoreIfReady(view) }
        if panel == .notes { indexHighlightsIfNeeded() }
    }
    func restoreIfReady(_ view: PaperView) {
        guard restoring, pdf === view, view.window != nil else { return }
        view.window?.contentView?.layoutSubtreeIfNeeded()
        applyFit()
        view.layoutDocumentView()
        go(state.page, point: state.point)
        // PDFKit clamps a destination to its crop box. A saved viewport can
        // start in the inter-page margin, particularly with both sidebars open.
        if let point = state.point, let page = document?.safePage(state.page),
           let actual = view.currentDestination, let actualPage = actual.page,
           let scroll = view.documentView?.enclosingScrollView {
            let clip = scroll.contentView
            let wanted = clip.convert(view.convert(point, from: page), from: view)
            let landed = clip.convert(view.convert(actual.point, from: actualPage), from: view)
            let target = clip.bounds.offsetBy(dx: wanted.x - landed.x, dy: wanted.y - landed.y)
            clip.scroll(to: clip.constrainBoundsRect(target).origin)
            scroll.reflectScrolledClipView(clip)
        }
        restoring = false
        syncStatus()
    }
    @discardableResult func close() -> Bool {
        guard saveNow() else { return false }
        restoring = true
        locked = nil; passwordError = false
        searchTask?.cancel(); searchTask = nil
        resetChat(); composerOpen = false; conversations = []; historyReadable = true
        focusedHighlight = nil
        selectionFrame = nil
        query = ""; hits = []; hitsByPage = [:]; showFind = false; searching = false
        region = nil; regionMode = false; hasText = false; canBack = false
        pinPreviews = nil
        pageThumbnails = nil
        highlightIndexTask?.cancel()
        highlightIndexTask = nil
        highlightsLoaded = false
        originals.removeAll()
        thumbnailMarksRevision = 0
        lastDeletion = nil
        marks.removeAll()
        pdf?.detach()
        pdf = nil; key = nil; openedFile = nil; documentPassword = nil
        pageIndex = 0; scale = 1
        state = PaperState()
        restoring = false
        return true
    }
    func scheduleSave() {
        guard key != nil, !restoring else { return }
        let deadline = Date(timeIntervalSinceNow: 0.4)
        if let saveTimer { saveTimer.fireDate = deadline; return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.saveNow() }
        }
        timer.tolerance = 0.05
        saveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @discardableResult func saveNow() -> Bool {
        saveTimer?.invalidate(); saveTimer = nil
        guard let key, let view = pdf else { return true }
        var snapshot = state
        if !restoring, let d = view.currentDestination, let p = d.page, let doc = document {
            snapshot.page = doc.index(for: p)
            snapshot.point = d.point
            snapshot.scale = view.scaleFactor
        }
        do { try store.write(snapshot, to: key + ".json"); return true }
        catch { self.error = bilingual("阅读记录保存失败。", "Could not save the reading state. ") + error.localizedDescription; return false }
    }
    func viewChanged(_ name: Notification.Name, view: PaperView) {
        guard pdf === view, !restoring else { return }
        if name == .PDFViewSelectionChanged {
            let value = !(view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if hasText != value { hasText = value }
            if value && focusedHighlight != nil { focusedHighlight = nil }
        } else {
            syncStatus()
            if name == .PDFViewPageChanged || name == .PDFViewVisiblePagesChanged { showSearchMarks() }
            view.refreshMarquee()
            scheduleSave()
        }
        refreshSelectionFrame()
    }
    func syncStatus() {
        guard let view = pdf, let p = view.currentPage, let doc = view.document else { return }
        let index = doc.index(for: p)
        if pageIndex != index { pageIndex = index }
        if abs(scale - view.scaleFactor) > 0.001 { scale = view.scaleFactor }
        if canBack != view.canGoBack { canBack = view.canGoBack }
    }
    func go(_ index: Int, point: CGPoint? = nil) {
        guard let page = document?.safePage(index) else { return }
        if let point { pdf?.go(to: PDFDestination(page: page, at: point)) }
        else { pdf?.go(to: page) }
        syncStatus()
    }
    func go(_ anchor: Anchor) {
        guard let p = document?.safePage(anchor.page) else { return }
        pdf?.go(to: anchor.rect, on: p)
        syncStatus()
    }
    func setZoom(_ mode: Zoom, value: CGFloat? = nil) {
        if state.zoom != mode { state.zoom = mode }
        if let value { state.scale = min(8, max(0.08, value)) }
        applyFit()
    }
    func applyFit() {
        guard let view = pdf, let p = view.currentPage ?? document?.safePage(0), view.bounds.width > 50, view.bounds.height > 50 else { return }
        let rect = view.convert(p.bounds(for: .cropBox), from: p)
        guard rect.width > 0, rect.height > 0 else { return }
        let width = (view.bounds.width - 36) * view.scaleFactor / rect.width
        let height = (view.bounds.height - 28) * view.scaleFactor / rect.height
        let result: CGFloat
        switch state.zoom { case .fixed: result = state.scale; case .width: result = width; case .page: result = min(width, height) }
        let fitted = min(8, max(0.08, result))
        let tolerance: CGFloat = state.zoom == .fixed ? 0 : 0.001
        if abs(view.scaleFactor - fitted) > tolerance { view.scaleFactor = fitted }
        syncStatus()
    }
    func setContinuous(_ continuous: Bool) {
        guard let view = pdf, let page = view.currentPage else { return }
        state.continuous = continuous
        view.displayMode = continuous ? .singlePageContinuous : .singlePage
        view.go(to: page)
        applyFit()
        syncStatus()
    }
    func rotate() {
        guard let view = pdf, let doc = document, let page = view.currentPage else { return }
        let index = doc.index(for: page)
        page.rotation = (page.rotation + 90) % 360
        state.rotations[index] = page.rotation
        view.layoutDocumentView()
        view.go(to: page)
        applyFit()
        view.refreshMarquee()
        syncStatus()
    }
    func startSearch() {
        searchTask?.cancel()
        hits = []; hitsByPage = [:]; hitIndex = 0; searching = false
        pdf?.highlightedSelections = nil
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let worker = pageThumbnails else { return }
        searching = true
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let result = await worker.search(needle)
            guard !Task.isCancelled, let self, self.pageThumbnails === worker else { return }
            self.hitsByPage = result.byPage
            self.hits = result.hits
            self.searching = false
            self.stepHit(0)
        }
    }
    func stepHit(_ delta: Int) {
        guard !hits.isEmpty else { return }
        hitIndex = (hitIndex + delta + hits.count) % hits.count
        let hit = hits[hitIndex]
        if let match = document?.safePage(hit.page)?.selection(for: hit.range) { pdf?.go(to: match) }
        showSearchMarks()
    }
    func showSearchMarks() {
        guard let view = pdf, let doc = document, !hits.isEmpty else { return }
        var selections: [PDFSelection] = []
        for page in view.visiblePages {
            for i in hitsByPage[doc.index(for: page)] ?? (0..<0) {
                if let match = page.selection(for: hits[i].range) {
                    match.color = (i == hitIndex ? NSColor.systemOrange : .systemYellow).withAlphaComponent(0.55)
                    selections.append(match)
                }
            }
        }
        view.highlightedSelections = selections
    }
    func dismissFind() { showFind = false; query = ""; startSearch() }
    func addBookmark() {
        let d = pdf?.currentDestination
        let idx = d?.page.flatMap { document?.index(for: $0) } ?? pageIndex
        state.bookmarks.append(Bookmark(name: "第 \(idx + 1) 页", page: idx, point: d?.point, automatic: true))
        showLeft = true; nav = .marks
    }
    func setRegionMode(_ value: Bool) {
        regionMode = value
        if focusedHighlight != nil { focusedHighlight = nil }
        region = nil
        pdf?.clearSelection()
        pdf?.refreshMarquee()
        refreshSelectionFrame()
        if let pdf { pdf.window?.invalidateCursorRects(for: pdf) }
    }
    func selectedCitation() -> Citation? {
        guard let sel = pdf?.currentSelection, let text = sel.string, !text.isEmpty, let doc = document, let key else { return nil }
        let lines = sel.selectionsByLine().flatMap { line in
            line.pages.map { Anchor(page: doc.index(for: $0), rect: line.bounds(for: $0)) }
        }.filter { !$0.rect.isEmpty && !$0.rect.isInfinite }
        return lines.isEmpty ? nil : Citation(documentKey: key, text: text, anchors: lines)
    }
    func highlight(_ tag: SemanticTag) {
        guard let cite = selectedCitation() else { return }
        let entry = Excerpt(tag: tag.id, text: cite.text, lines: cite.anchors)
        state.excerpts.append(entry)
        installMark(entry)
        pdf?.clearSelection()
        showRight = true; panel = .notes
    }
    func focusHighlight(_ hit: HighlightHit?) {
        guard hit != focusedHighlight else { return }
        focusedHighlight = hit
        refreshSelectionFrame()
    }
    func highlightHit(at point: CGPoint, on page: PDFPage) -> HighlightHit? {
        guard let document else { return nil }
        let index = document.index(for: page)
        let candidates = page.annotations.reversed().filter {
            $0.type == "Highlight" && $0.shouldDisplay && $0.bounds.contains(point)
        }
        guard !candidates.isEmpty else { return nil }
        let originals = originalMarks(index, on: page)
        for mark in candidates {
            if let id = marks.first(where: { $0.value.contains { $0 === mark } })?.key,
               let line = state.excerpts.first(where: { $0.id == id })?.lines.first(where: { $0.page == index && $0.rect.contains(point) }) {
                return HighlightHit(id: id, line: line)
            }
            guard let source = originals.first(where: { $0.value === mark })?.key else { continue }
            if let entry = state.excerpts.first(where: { $0.sourceHighlight == source }) {
                if let line = entry.lines.first(where: { $0.rect.contains(point) }) { return HighlightHit(id: entry.id, line: line) }
            } else if let entry = Excerpt(annotation: mark, source: source, page: page, canCopy: document.allowsCopying),
                      let line = entry.lines.first(where: { $0.rect.contains(point) }) {
                // A source highlight can be clicked before the sidebar indexes this document.
                mergeHighlights([entry])
                return HighlightHit(id: entry.id, line: line)
            }
        }
        return nil
    }
    func highlightForSelection() -> UUID? {
        guard !state.excerpts.isEmpty, let selection = selectedCitation() else { return nil }
        return state.excerpts.last { entry in
            selection.anchors.allSatisfy { selected in
                entry.lines.contains { line in
                    let box = line.rect.insetBy(dx: -1, dy: -1)
                    return line.page == selected.page && box.minX <= selected.rect.minX && box.maxX >= selected.rect.maxX
                        && box.minY <= selected.rect.midY && box.maxY >= selected.rect.midY
                }
            }
        }?.id
    }
    func cancelHighlight(_ id: UUID) {
        guard state.excerpts.contains(where: { $0.id == id }) else { return }
        pdf?.clearSelection()
        deleteCard(cardReference(id, in: .notes))
        showRight = true
        panel = .notes
    }
    // Snapshot the source objects before applying any local overlays to this page.
    private func originalMarks(_ index: Int, on page: PDFPage) -> [PDFHighlightID: PDFAnnotation] {
        if let cached = originals[index] { return cached }
        let cached = Dictionary(uniqueKeysWithValues: PDFHighlightID.annotations(on: page, index: index))
        originals[index] = cached
        return cached
    }
    @discardableResult
    private func setOriginal(_ source: PDFHighlightID, visible: Bool) -> PDFAnnotation? {
        guard let page = document?.safePage(source.page), let mark = originalMarks(source.page, on: page)[source] else { return nil }
        if visible && !page.annotations.contains(mark) { page.addAnnotation(mark) }
        if !visible && page.annotations.contains(mark) { page.removeAnnotation(mark) }
        return mark
    }
    private func installMark(_ entry: Excerpt) {
        thumbnailMarksRevision += 1
        if let source = entry.sourceHighlight {
            let originalStyle = entry.usesTagColor != true
            if let mark = setOriginal(source, visible: originalStyle), originalStyle {
                if (mark.contents ?? "") != entry.note { mark.contents = entry.note }
                return
            }
        }
        guard let ink = prefs.tags.first(where: { $0.id == entry.tag })?.ink else { return }
        marks[entry.id] = entry.lines.compactMap { line in
            guard let page = document?.safePage(line.page) else { return nil }
            _ = originalMarks(line.page, on: page)
            let mark = ink.highlight(in: line.rect)
            if !entry.note.isEmpty { mark.contents = entry.note }
            page.addAnnotation(mark)
            return mark
        }
    }
    private func removeOverlay(_ id: UUID) {
        for mark in marks.removeValue(forKey: id) ?? [] { mark.page?.removeAnnotation(mark) }
    }
    func setPinNote(_ id: UUID, text: String) {
        guard let i = state.pins.firstIndex(where: { $0.id == id }) else { return }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (state.pins[i].note ?? "") != note else { return }
        state.pins[i].note = note.isEmpty ? nil : note
        state.pins[i].noteEditedAt = note.isEmpty ? nil : Date()
    }
    func setNote(_ id: UUID, text: String) {
        guard let i = state.excerpts.firstIndex(where: { $0.id == id }) else { return }
        guard state.excerpts[i].note != text else { return }
        state.excerpts[i].note = text
        state.excerpts[i].noteEditedAt = text.isEmpty ? nil : Date()
        if let source = state.excerpts[i].sourceHighlight, state.excerpts[i].usesTagColor != true {
            setOriginal(source, visible: true)?.contents = text
        }
        for mark in marks[id] ?? [] { mark.contents = text }
    }
    func assignTag(_ tagID: UUID, to id: UUID) {
        guard prefs.tags.contains(where: { $0.id == tagID }),
              let i = state.excerpts.firstIndex(where: { $0.id == id }) else { return }
        removeOverlay(id)
        state.excerpts[i].tag = tagID
        if state.excerpts[i].sourceHighlight != nil { state.excerpts[i].usesTagColor = true }
        installMark(state.excerpts[i])
    }
    func updateTag(_ tag: SemanticTag) {
        guard let index = prefs.tags.firstIndex(where: { $0.id == tag.id }) else { return }
        let recolor = prefs.tags[index].ink != tag.ink
        prefs.tags[index] = tag
        if recolor {
            prefs.tags[index].overridesSourceColor = true
            for entry in state.excerpts where entry.tag == tag.id { assignTag(tag.id, to: entry.id) }
        }
        persistPreferences()
    }
    func deleteTag(_ id: UUID) {
        guard prefs.tags.count > 1, prefs.tags.contains(where: { $0.id == id }) else { return }
        prefs.tags.removeAll { $0.id == id }
        if prefs.defaultTagID == id { prefs.defaultTagID = prefs.tags[0].id }
        if let fallback = prefs.defaultTagID {
            for entry in state.excerpts where entry.tag == id { assignTag(fallback, to: entry.id) }
        }
        persistPreferences()
    }
    func deleteCard(_ reference: CardReference) {
        guard key == reference.document else { return }
        switch reference.list {
        case .pins:
            guard let index = state.pins.firstIndex(where: { $0.id == reference.id }) else { return }
            lastDeletion = .pin(state.pins.remove(at: index), index)
        case .notes:
            guard let index = state.excerpts.firstIndex(where: { $0.id == reference.id }) else { return }
            if focusedHighlight?.id == reference.id { focusHighlight(nil) }
            removeOverlay(reference.id)
            if let source = state.excerpts[index].sourceHighlight {
                setOriginal(source, visible: false)
                if state.deletedHighlights == nil { state.deletedHighlights = [] }
                state.deletedHighlights?.insert(source)
            }
            thumbnailMarksRevision += 1
            lastDeletion = .note(state.excerpts.remove(at: index), index)
        }
    }
    func undoCardDeletion() {
        guard let lastDeletion else { return }
        switch lastDeletion {
        case let .pin(pin, index):
            state.pins.insert(pin, at: min(index, state.pins.count))
        case let .note(deleted, index):
            var note = deleted
            if let tag = note.tag, !prefs.tags.contains(where: { $0.id == tag }) {
                note.tag = prefs.defaultTagID
                if note.sourceHighlight != nil { note.usesTagColor = true }
            }
            if let source = note.sourceHighlight { state.deletedHighlights?.remove(source) }
            state.excerpts.insert(note, at: min(index, state.excerpts.count))
            installMark(note)
        }
        self.lastDeletion = nil
    }
    func dismissCardDeletion() { lastDeletion = nil }
    func pin() {
        if let region { state.pins.append(Pin(source: region)) }
        else if let cite = selectedCitation() {
            for p in cite.pages {
                let rect = cite.anchors.filter { $0.page == p }.reduce(CGRect.null) { $0.union($1.rect) }
                state.pins.append(Pin(source: Anchor(page: p, rect: rect)))
            }
        } else { return }
        setRegionMode(false)
        showRight = true; panel = .pins
    }
    func copyRegion() {
        if let region { copyImage(region) }
    }
    func copyPin(_ id: UUID) {
        if let pin = state.pins.first(where: { $0.id == id }) { copyImage(pin.source, drawing: pin.drawing ?? []) }
    }
    private func copyImage(_ source: Anchor, drawing: [PinStroke] = []) {
        guard let document, let image = ClipRenderer.image(source, in: document, maxEdge: 4096, scale: 3, drawing: drawing) else {
            error = L("无法复制这张图片。")
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            error = L("无法复制这张图片。")
            return
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = bitmap.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        imagePasteboard.clearContents()
        if !imagePasteboard.writeObjects([item]) { error = L("无法复制这张图片。") }
    }
    private func indexHighlightsIfNeeded() {
        guard !highlightsLoaded, highlightIndexTask == nil, let store = pageThumbnails else { return }
        highlightIndexTask = Task(priority: .utility) { [weak self] in
            let found = await store.embeddedHighlights()
            guard !Task.isCancelled, let self, self.pageThumbnails === store else { return }
            self.mergeHighlights(found)
            self.highlightsLoaded = true
            self.highlightIndexTask = nil
        }
    }
    private func mergeHighlights(_ found: [Excerpt]) {
        let known = Set(state.excerpts.compactMap(\.sourceHighlight)).union(state.deletedHighlights ?? [])
        let defaultTag = prefs.tags.first { $0.id == prefs.defaultTagID }
        let additions = found.compactMap { item -> Excerpt? in
            guard let source = item.sourceHighlight, !known.contains(source) else { return nil }
            var entry = item
            entry.tag = defaultTag?.id
            entry.usesTagColor = defaultTag?.overridesSourceColor
            return entry
        }
        if !additions.isEmpty {
            state.excerpts.append(contentsOf: additions)
            for entry in additions where entry.usesTagColor == true { installMark(entry) }
        }
    }

    func export() {
        guard let worker = pageThumbnails else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title + bilingual(" · 阅读笔记.md", " - Reading notes.md")
        panel.title = L("导出 Markdown 笔记"); panel.prompt = L("保存")
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            indexHighlightsIfNeeded()
            let indexing = highlightIndexTask
            Task {
                await indexing?.value
                guard pageThumbnails === worker else { return }
                do { try await worker.exportNotebook(to: url, title: title, state: state, tags: prefs.tags) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    func exportPages() {
        guard let source = openedFile?.currentURL, let doc = document, let window = pdf?.window else { return }
        guard doc.allowsCopying else { error = L("无法从这份 PDF 提取页面。"); return }
        let range = ExportPageRange(current: pageIndex, count: doc.pageCount)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = source.deletingLastPathComponent()
        panel.title = L("提取页面为 PDF…")
        panel.nameFieldStringValue = title + bilingual(" · 摘页.pdf", " - Extract.pdf")
        panel.message = bilingual("按输入顺序提取原文件中的页面，例如 1, 3–5。", "Extract original pages in the order entered, for example 1, 3–5.")
        if doc.isEncrypted { panel.message += bilingual(" 导出的文件不设密码。", " The exported file will have no password.") }
        let row = NSStackView(views: [NSTextField(labelWithString: L("页码范围")), range.field])
        range.field.widthAnchor.constraint(equalToConstant: 180).isActive = true
        panel.accessoryView = row
        panel.delegate = range
        let password = documentPassword
        panel.beginSheetModal(for: window) { answer in
            guard answer == .OK, let destination = panel.url else { return }
            let selection = range.field.stringValue
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try PageExport.write(source: source, password: password, selection: selection, to: destination)
                    }.value
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    func printPDF(current: Bool = false) {
        guard let doc = document else { return }
        guard doc.allowsPrinting else { error = L("这份 PDF 限制了打印。"); return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        if current {
            info.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
            info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = pageIndex + 1
            info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = pageIndex + 1
        }
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else { error = L("无法创建打印任务。"); return }
        op.printPanel.options.insert(.showsPageRange)
        op.run()
    }
    func resetChat() {
        stopAnswer()
        conversationID = UUID()
        citation = nil; chat = []; transcript = []; question = ""; includePage = false; chatError = ""
        wholePaper = true; attachments = []
    }
    func stopAnswer() {
        sendTask?.cancel(); sendTask = nil; sending = false; partialAnswer = ""; pendingTurn = nil
    }
    func openChat(_ session: PaperChat) {
        resetChat(); conversationID = session.id; wholePaper = session.wholePaper
        transcript = session.messages
        if let legacy = session.citation,
           let i = transcript.firstIndex(where: { $0.role == "user" && $0.text.contains(legacy.text) && $0.selection == nil }) {
            transcript[i].selection = legacy
        }
        chat = transcript.map(\.forDisplay)
    }
    private func saveHistory() {
        guard historyReadable, let key else { return }
        do { try store.write(conversations, to: key + "-chats.json") } catch { self.error = error.localizedDescription }
    }
    func deleteChat(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if conversationID == id { resetChat() }
        saveHistory()
    }
    private func saveCurrentChat() {
        conversations.removeAll { $0.id == conversationID }
        conversations.insert(PaperChat(id: conversationID, messages: transcript, wholePaper: wholePaper, citation: nil), at: 0)
        saveHistory()
    }
    func deleteExchange(_ lineID: UUID) {
        guard !sending, let index = transcript.firstIndex(where: { $0.id == lineID && $0.role == "user" }) else { return }
        let end = transcript[(index + 1)...].firstIndex { $0.role == "user" } ?? transcript.endIndex
        transcript.removeSubrange(index..<end)
        chat.removeSubrange(index..<end)
        if transcript.isEmpty { deleteChat(conversationID) }
        else { saveCurrentChat() }
    }
    func askSelection() {
        guard !sending, let cite = selectedCitation() else { return }
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { question = L("请解释这段文字。") }
        chatError = ""; composerOpen = true; wholePaper = false; citation = cite; panel = .chat; showRight = true
        pdf?.clearSelection()
    }
    func attachCard(_ ref: CardReference) {
        guard !sending, ref.document == key, !attachments.contains(where: { $0.id == ref.id }) else { return }
        switch ref.list {
        case .notes:
            guard let card = state.excerpts.first(where: { $0.id == ref.id }) else { return }
            attachments.append(CardAttachment(card))
        case .pins:
            guard let pin = state.pins.first(where: { $0.id == ref.id }) else { return }
            attachments.append(CardAttachment(pin))
        }
        if transcript.isEmpty && citation == nil { wholePaper = false }
        composerOpen = true
    }
    var contextPageText: String { document?.safePage(pageIndex)?.string ?? "" }
    func outgoingMessages() async throws -> [ChatLine] {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        let history = transcript.map(\.forFollowUp)
        let needsPaper = !history.contains { $0.includesSource == true && $0.selection == nil }
        let selected = citation
        if let cite = selected {
            parts.append(cite.pages.map(pageName).joined(separator: ", "))
            parts.append(cite.text)
        }
        var images: [Data] = []
        let includeFull = wholePaper && needsPaper
        let fullSource = pageThumbnails
        let pageExtra = includePage ? pageName(pageIndex) + "\n" + contextPageText : nil
        let rotations = state.rotations, previews = pinPreviews, tags = prefs.tags
        for source in attachments {
            switch source.content {
            case let .passage(text, pages, tag):
                parts.append([source.title, tags.first { $0.id == tag }?.displayName,
                              pages.map(pageName).joined(separator: ", "), text].compactMap { $0 }.joined(separator: "\n"))
            case let .clip(anchor):
                let clip = Pin(id: source.id, source: anchor)
                guard let image = await previews?.jpeg(for: clip, rotation: rotations[anchor.page]) else {
                    throw ReaderError(bilingual("无法读取便签图片。", "Could not read the pinned image."))
                }
                images.append(image)
                parts.append([source.title ?? bilingual("便签图片", "Pinned image"), pageName(anchor.page)].joined(separator: " · "))
            }
        }
        if let pageExtra { parts.append(pageExtra) }
        if includeFull, let source = fullSource { parts.insert(try await source.paperText(), at: 0) }
        parts.append(bilingual("问题：\n", "Question:\n") + prompt)
        return history + [ChatLine(role: "user", text: parts.joined(separator: "\n\n"), displayText: prompt, includesSource: includeFull, images: images.isEmpty ? nil : images, selection: selected, sourceFormatVersion: 2)]
    }
    func send() {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, historyReadable, document != nil, !prompt.isEmpty, let profile else { return }
        guard wholePaper || includePage || citation != nil || !attachments.isEmpty || !transcript.isEmpty else {
            chatError = bilingual("请添加批注或选择全文。", "Add a note or choose the full paper."); return
        }
        panel = .chat; showRight = true
        let turn = ChatLine(role: "user", text: prompt, selection: citation)
        pendingTurn = turn
        sending = true; partialAnswer = ""; chatError = ""
        sendTask = Task {
            do {
                var payload = try await outgoingMessages()
                payload[payload.count - 1].id = turn.id
                payload[payload.count - 1].createdAt = turn.createdAt
                try Task.checkCancellation()
                let answer: String
                if let askModel { answer = try await askModel(profile, payload) }
                else { answer = try await AIClient.stream(profile, payload, key: secrets.get(profile.id)) { value in
                    if !Task.isCancelled { self.partialAnswer = value }
                } }
                try Task.checkCancellation()
                let reply = ChatLine(role: "assistant", text: answer)
                transcript = payload + [reply]
                chat += transcript.suffix(2).map(\.forDisplay)
                saveCurrentChat()
                question = ""; citation = nil; includePage = false; attachments = []
            } catch { if !Task.isCancelled { chatError = error.localizedDescription } }
            if !Task.isCancelled { sending = false; partialAnswer = ""; pendingTurn = nil }
        }
    }
}
