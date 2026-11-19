import SwiftUI

struct ServiceModelPicker: View {
    let service: Profile
    let fetch: () async throws -> Void
    let select: (String) -> Void
    var manage: (() -> Void)?
    @State private var query = ""
    @State private var refresh = 0
    @State private var loading = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L(service.provider.rawValue)).font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading).help(bilingual("刷新模型列表", "Refresh model list"))
                    .accessibilityLabel(bilingual("刷新模型列表", "Refresh model list"))
            }
            TextField(bilingual("搜索模型", "Search models"), text: $query).textFieldStyle(.roundedBorder)
            let models = service.modelChoices.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(models, id: \.self) { model in
                        Button { select(model) } label: {
                            HStack {
                                Text(verbatim: model).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if model == service.model { Image(systemName: "checkmark").foregroundStyle(PaperStyle.accent) }
                            }.padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
                        }.buttonStyle(ReaderButtonStyle()).help(model)
                    }
                    if models.isEmpty && !loading {
                        Text(bilingual("没有匹配的模型", "No matching models")).foregroundStyle(.secondary)
                    }
                }
            }
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if let manage { Divider(); Button(L("配置 AI 服务"), action: manage) }
        }.padding(12).frame(width: 320, height: 285)
            .task(id: refresh) {
                guard refresh > 0 || service.modelCatalog == nil else { return }
                loading = true; error = ""
                defer { loading = false }
                do { try await fetch() } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
    }
}
