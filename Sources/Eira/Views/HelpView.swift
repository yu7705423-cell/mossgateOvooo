import SwiftUI

/// 说明书（网页版 settings/HelpPage.js，ARCHITECTURE 4.527）：界面上收起来的说明集中在这一处，可以搜。
/// 内容由 scripts/gen-help.mjs 从代码里的 HelpNote 收集（Resources/help.json）。
/// 不搜的时候按 app 分组、点开再看；搜了就把命中的几条直接列出来。
struct HelpView: View {
    struct Entry: Decodable, Hashable {
        let app: String
        let title: String
        let text: String
    }

    static let all: [Entry] = {
        guard let url = Bundle.main.url(forResource: "help", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }()

    @State private var query = ""
    @State private var open: Set<String> = []

    var body: some View {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = key.isEmpty ? Self.all : Self.all.filter { "\($0.app) \($0.title) \($0.text)".localizedCaseInsensitiveContains(key) }
        let apps = hits.reduce(into: [String]()) { if !$0.contains($1.app) { $0.append($1.app) } }
        List {
            if hits.isEmpty {
                Text(key.isEmpty ? "说明书为空" : "没有找到，换一个关键词再试。").foregroundStyle(Theme.text3)
            }
            ForEach(apps, id: \.self) { app in
                let rows = hits.filter { $0.app == app }
                let shown = !key.isEmpty || open.contains(app)
                Section {
                    Button {
                        if open.contains(app) { open.remove(app) } else { open.insert(app) }
                    } label: {
                        HStack {
                            Text(app).foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(rows.count)").foregroundStyle(Theme.text3).monospacedDigit()
                            if key.isEmpty {
                                Image(systemName: shown ? "chevron.up" : "chevron.down").font(.footnote).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                    if shown {
                        ForEach(rows, id: \.self) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                if !r.title.isEmpty { Text(r.title).font(.subheadline.weight(.medium)) }
                                Text(r.text).font(.footnote).foregroundStyle(Theme.text2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索功能或关键词")
        .navigationTitle("说明书")
        .navigationBarTitleDisplayMode(.inline)
    }
}
