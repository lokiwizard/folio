import SwiftUI

struct PaperPromptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: String?
    @State private var draft: [PaperPrompt]
    @State private var error = ""
    let save: ([PaperPrompt]) throws -> Void

    init(prompts: [PaperPrompt], save: @escaping ([PaperPrompt]) throws -> Void) {
        _draft = State(initialValue: prompts)
        self.save = save
    }

    var body: some View {
        ScrollViewReader { scroll in
            VStack(alignment: .leading, spacing: 14) {
                Text(bilingual("全文提示词", "Full-paper prompts")).font(.title2.weight(.semibold))
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach($draft) { $prompt in
                            let id = prompt.id
                            HStack(alignment: .top, spacing: 8) {
                                TextField(bilingual("输入问题", "Enter a question"), text: $prompt.displayText, axis: .vertical)
                                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...6)
                                    .focused($focused, equals: id).padding(.vertical, 5)
                                GlyphButton(symbol: "trash", title: bilingual("删除提示词", "Delete prompt")) {
                                    draft.removeAll { $0.id == id }
                                }
                            }.padding(.leading, 11).padding(.trailing, 5).padding(.vertical, 4)
                                .sidebarCardSurface().id(id)
                        }
                        if draft.isEmpty {
                            Text(bilingual("还没有提示词", "No prompts yet")).foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                    }.padding(2)
                }
                if !error.isEmpty { Text(verbatim: error).foregroundStyle(.red).font(.callout) }
                Divider()
                HStack {
                    Button {
                        draft.append(PaperPrompt(text: ""))
                    } label: { Label(bilingual("添加提示词", "Add prompt"), systemImage: "plus") }
                    Button(bilingual("恢复默认", "Restore defaults")) { draft = PaperPrompt.defaults }
                        .disabled(draft == PaperPrompt.defaults)
                    Spacer()
                    Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L("保存")) {
                        do { try save(draft); dismiss() } catch { self.error = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(draft.contains { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }
            .onChange(of: draft.count) { old, new in
                guard new > old, let added = draft.last, added.text.isEmpty else { return }
                scroll.scrollTo(added.id, anchor: .bottom)
                focused = added.id
            }
        }
        .padding(20)
        .frame(width: 530, height: min(438, (NSScreen.main?.visibleFrame.height ?? 720) - 80))
    }
}
