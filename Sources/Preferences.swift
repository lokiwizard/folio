import SwiftUI

enum SettingsTab: CaseIterable {
    case appearance, tags, ai
    var title: String {
        switch self { case .appearance: L("外观"); case .tags: L("语义高亮"); case .ai: L("AI 服务") }
    }
    var symbol: String {
        switch self { case .appearance: "circle.lefthalf.filled"; case .tags: "highlighter"; case .ai: "network" }
    }
}

struct PreferencesView: View {
    @ObservedObject var r: Reader
    @Environment(\.dismiss) private var dismiss
    @State private var serviceDraft = Profile(.openAI)
    @State private var secret = ""
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("设置")).font(.system(size: 23, weight: .semibold)).padding(.leading, 10).padding(.bottom, 16)
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    let active = tab == r.settingsTab
                    Button { r.settingsTab = tab } label: {
                        HStack(spacing: 9) {
                            Image(systemName: tab.symbol).frame(width: 20).foregroundStyle(active ? PaperStyle.accent : PaperStyle.muted)
                            Text(tab.title).font(.system(size: 15, weight: active ? .semibold : .regular)).fixedSize()
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 10).frame(height: 37).contentShape(Rectangle())
                            .background(active ? PaperStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(ReaderButtonStyle(radius: 8)).accessibilityAddTraits(active ? .isSelected : [])
                        .accessibilityIdentifier("settings.tab." + String(describing: tab))
                }
                Spacer()
                Divider().padding(.vertical, 4)
                LanguageMenu(r: r, showName: true).padding(.horizontal, 7).hoverHighlight()
            }.padding(.horizontal, 12).padding(.vertical, 21).frame(width: r.language == .english ? 206 : 160)
                .background { SidebarSurface(strength: r.glassStrength) }
            Divider()
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Text(r.settingsTab.title).font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Button(L("完成")) { dismiss() }.keyboardShortcut(.cancelAction).hoverHighlight()
                }
                switch r.settingsTab {
                case .appearance: ScrollView { AppearanceSettings(r: r) }
                case .tags: TagsSettings(r: r).id(r.language)
                case .ai: ServiceSettings(r: r, draft: $serviceDraft, secret: $secret)
                }
                Spacer(minLength: 0)
            }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(PaperStyle.paper)
        }.font(.system(size: 15)).controlSize(.regular)
            .frame(width: min(752, (NSScreen.main?.visibleFrame.width ?? 980) - 32),
                   height: min(490, (NSScreen.main?.visibleFrame.height ?? 720) - 80))
            .background { WindowSurface(strength: r.glassStrength) }
            .onAppear { serviceDraft = r.profile ?? Profile(.openAI) }
            .onDisappear { secret = "" }
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var r: Reader
    @Environment(\.accessibilityReduceTransparency) private var reduced
    @State private var adjusting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("窗口外观")).font(.system(size: 16, weight: .semibold))
                HStack(spacing: 10) {
                    ForEach(InterfaceAppearance.allCases, id: \.self) { mode in
                        let selected = mode == r.appearance
                        Button { r.setAppearance(mode) } label: {
                            VStack(spacing: 8) {
                                HStack(spacing: 0) {
                                    appearanceSwatch(dark: mode == .dark)
                                    if mode == .system { appearanceSwatch(dark: true) }
                                }.frame(height: 43).clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(PaperStyle.line, lineWidth: 0.6) }
                                Text(mode.title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                            }.padding(8).frame(maxWidth: .infinity)
                                .background(selected ? PaperStyle.accent.opacity(0.075) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? PaperStyle.accent : PaperStyle.line, lineWidth: selected ? 1.5 : 0.6) }
                        }.buttonStyle(ReaderButtonStyle(radius: 8)).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }.padding(15).sidebarCardSurface()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(L("备注字号")).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(verbatim: "\(r.memoFontSize) pt").monospacedDigit()
                    Stepper(L("备注字号"), value: Binding(get: { r.memoFontSize }, set: r.setMemoFontSize), in: Preferences.memoFontSizes)
                        .labelsHidden().accessibilityLabel(L("备注字号"))
                        .accessibilityValue("\(r.memoFontSize) pt")
                }
                Text(L("便签和批注的个人备注会以这个字号显示。"))
                    .font(r.memoFont).fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
            }.padding(15).sidebarCardSurface()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("毛玻璃强度")).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(r.glassStrength, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { r.glassStrength }, set: { r.setGlassStrength($0, persist: !adjusting) }), in: 0...1, step: 0.05,
                       onEditingChanged: { editing in adjusting = editing; if !editing { r.persistPreferences() } }) { Text(L("毛玻璃强度")) }
                    .labelsHidden().disabled(reduced)
                HStack { Text(L("不透明")); Spacer(); Text(L("通透")) }.font(.system(size: 13)).foregroundStyle(.secondary)
                GlassPreview(strength: r.glassStrength)
                if reduced { Text(L("系统已开启「降低透明度」。")).font(.system(size: 13)).foregroundStyle(.secondary) }
            }.padding(15).sidebarCardSurface()
        }.padding(1).onDisappear { if adjusting { r.persistPreferences() } }
    }
    private func appearanceSwatch(dark: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(white: dark ? 0.23 : 0.86)).frame(width: 12)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<3) { i in
                    Capsule().fill(Color(white: dark ? 0.48 : 0.78)).frame(maxWidth: i == 1 ? 34 : 45).frame(height: 2)
                }
            }.padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(white: dark ? 0.15 : 0.98)).accessibilityHidden(true)
    }
}

private struct GlassPreview: View {
    let strength: Double
    var body: some View {
        ZStack {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<28) { i in
                    Rectangle().fill([Color.gray, .teal, .secondary][(i / 4) % 3].opacity(0.32))
                        .frame(height: CGFloat(26 + (i * 13) % 48))
                }
            }
            ChatLauncherLabel(title: L("问 AI"), waiting: false, receivingDrop: false)
                .background { PaperGlass(strength: strength, corner: ChatLauncherLabel.size.height / 2) }
                .overlay { Capsule().strokeBorder(PaperStyle.line, lineWidth: 0.6) }
        }.frame(height: 58).frame(maxWidth: .infinity)
            .background(PaperStyle.surface).clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bilingual("问答胶囊材质预览", "Chat button material preview"))
            .allowsHitTesting(false)
    }
}

private struct TagsSettings: View {
    @ObservedObject var r: Reader
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("语义标签")).font(.headline)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(r.prefs.tags) { tag in TagRow(r: r, tag: tag).padding(.horizontal, 9).padding(.vertical, 4).sidebarCardSurface() }
                }.padding(2)
            }
            Button { let tag = SemanticTag(name: L("新标签"), ink: .blue); r.prefs.tags.append(tag); r.persistPreferences() } label: { Label(L("添加标签"), systemImage: "plus") }.hoverHighlight()
        }
    }
}
private struct TagRow: View {
    @ObservedObject var r: Reader
    var tag: SemanticTag
    @State private var name: String
    @State private var edited = false
    @FocusState private var naming: Bool
    init(r: Reader, tag: SemanticTag) { self.r = r; self.tag = tag; _name = State(initialValue: tag.displayName) }
    private func saveName() {
        guard edited, var current = r.prefs.tags.first(where: { $0.id == tag.id }) else { return }
        edited = false
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value != current.displayName {
            current.name = value; current.preset = nil; r.updateTag(current)
        }
        name = current.displayName
    }
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(nsColor: tag.ink.color)).frame(width: 13, height: 13)
            TextField(L("标签名称"), text: Binding(get: { name }, set: { name = $0; edited = true }))
                .textFieldStyle(.roundedBorder).focused($naming)
                .onSubmit(saveName).onChange(of: naming) { _, focused in if !focused { saveName() } }
                .onDisappear(perform: saveName)
            Picker(L("颜色"), selection: Binding(get: { tag.ink }, set: { var edit = tag; edit.ink = $0; r.updateTag(edit) })) {
                ForEach(Ink.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 95).hoverHighlight()
            if r.prefs.defaultTagID == tag.id { Image(systemName: "star.fill").font(.system(size: 13)).foregroundStyle(.secondary).help(L("默认")).accessibilityLabel(L("默认")) }
            Menu {
                Button(L("设为默认标签")) { r.prefs.defaultTagID = tag.id; r.persistPreferences() }
                    .disabled(r.prefs.defaultTagID == tag.id)
                Button(L("删除标签"), role: .destructive) { r.deleteTag(tag.id) }.disabled(r.prefs.tags.count == 1)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("标签选项"))
        }.padding(.vertical, 3)
    }
}

private struct ServiceSettings: View {
    @ObservedObject var r: Reader
    @Binding var draft: Profile
    @Binding var secret: String
    @State private var feedback = ""
    @State private var testing = false
    @State private var confirmingDelete = false
    @State private var choosingModel = false
    @State private var testTask: Task<Void, Never>?
    private var existing: Profile? { r.savedService(for: draft) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !r.prefs.profiles.isEmpty {
                    HStack {
                        Menu {
                            ForEach(r.prefs.profiles) { service in
                                Button((service.id == r.prefs.active ? "✓ " : "") + service.title + " · " + service.base) {
                                    do { load(try r.saveService(service, key: "")) }
                                    catch { feedback = error.localizedDescription }
                                }
                            }
                        } label: { Text(bilingual("已保存的服务", "Saved services")) }
                        Spacer()
                        if existing != nil {
                            Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                                .help(bilingual("删除服务和密钥", "Delete service and key")).hoverHighlight()
                        }
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 11) {
                    GridRow {
                        Text(L("厂商"))
                        Picker(L("厂商"), selection: Binding(get: { draft.provider }, set: { provider in
                            let saved = r.profile.flatMap { $0.provider == provider ? $0 : nil }
                                ?? r.prefs.profiles.first { $0.provider == provider }
                            load(saved ?? Profile(provider))
                        })) { ForEach(Provider.allCases) { Text(L($0.rawValue)).tag($0) } }.labelsHidden()
                    }
                    if draft.provider.endpoints.count > 1 {
                        GridRow {
                            Text(L("地域"))
                            Menu(draft.provider.endpoints.first(where: { $0.1 == draft.base })?.0 ?? L("自定义地域")) {
                                ForEach(draft.provider.endpoints, id: \.1) { item in Button(item.0) { changeAddress(item.1) } }
                            }
                        }
                    }
                    GridRow {
                        Text(L("服务地址"))
                        TextField("https://…", text: Binding(get: { draft.base }, set: changeAddress)).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("API Key")
                        SecureField(existing == nil ? L("输入密钥") : L("留空沿用原密钥，输入可替换"), text: $secret)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: secret) { _, value in
                                draft.modelCatalog = value.isEmpty ? existing?.modelCatalog : nil
                            }
                    }
                    GridRow {
                        Text(L("模型 ID"))
                        HStack {
                            TextField(L("输入模型或推理接入点 ID"), text: $draft.model).textFieldStyle(.roundedBorder)
                            Button(bilingual("选择模型", "Choose model")) { choosingModel = true }.hoverHighlight()
                                .popover(isPresented: $choosingModel) {
                                    ServiceModelPicker(service: draft, fetch: {
                                        let models = try await AIClient.models(profile: draft, key: r.serviceKey(for: draft, input: secret))
                                        try Task.checkCancellation()
                                        draft.modelCatalog = models
                                    }, select: { model in draft.model = model; choosingModel = false })
                                }
                        }
                    }
                }
                HStack {
                    Button(L("测试连接")) { test() }.hoverHighlight()
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(L("保存并使用")) { save() }.buttonStyle(.borderedProminent).hoverHighlight()
                }
                if !feedback.isEmpty { Text(feedback).font(.callout).textSelection(.enabled) }
                Divider()
                Text(bilingual("每个服务地址只需保存一次密钥。点「选择模型」获取账号可用的模型，也可以直接填写模型 ID。",
                               "Save one key per service endpoint. Choose a model from your account or enter a model ID."))
                    .font(.system(size: 13)).foregroundStyle(PaperStyle.muted).lineSpacing(3)
            }.padding(15).sidebarCardSurface().padding(1).disabled(testing)
        }.onDisappear { testTask?.cancel() }
            .alert(bilingual("删除这项服务及其密钥？", "Delete this service and its key?"), isPresented: $confirmingDelete) {
                Button(L("取消"), role: .cancel) {}
                Button(L("删除"), role: .destructive) {
                    guard let existing else { return }
                    do { try r.deleteService(existing.id); load(r.profile ?? Profile(.openAI)) }
                    catch { feedback = error.localizedDescription }
                }
            }
    }
    private func load(_ service: Profile) { secret = ""; draft = service; feedback = ""; choosingModel = false }
    private func changeAddress(_ address: String) {
        var service = Profile(draft.provider)
        service.base = address
        if draft.sharesService(with: service) { draft.base = address; return }
        if let saved = r.savedService(for: service) { service = saved; service.base = address }
        load(service)
    }
    private func save() {
        do {
            let saved = try r.saveService(draft, key: secret)
            load(saved)
            feedback = L("已保存，当前使用 ") + saved.title
        } catch { feedback = error.localizedDescription }
    }
    private func test() {
        do {
            _ = try draft.validatedBase()
            let key = try r.serviceKey(for: draft, input: secret)
            let p = draft
            testing = true; feedback = ""
            testTask = Task {
                defer { testing = false }
                do {
                    _ = try await AIClient.send(profile: p, key: key, history: [ChatLine(role: "user", text: "Reply OK.")])
                    if !Task.isCancelled { feedback = L("连接成功，模型已返回文本。") }
                } catch { if !Task.isCancelled { feedback = error.localizedDescription } }
            }
        } catch { feedback = error.localizedDescription }
    }
}

struct LanguageMenu: View {
    @ObservedObject var r: Reader
    var showName = false
    var body: some View {
        Menu {
            Picker(L("界面语言"), selection: Binding(get: { r.language }, set: r.switchLanguage)) {
                ForEach(InterfaceLanguage.allCases, id: \.self) { lang in Text(verbatim: lang.name).tag(lang) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                if showName { Text(verbatim: r.language.name) }
            }
        }.menuStyle(.borderlessButton).fixedSize().help(L("界面语言")).accessibilityLabel(L("界面语言"))
    }
}
