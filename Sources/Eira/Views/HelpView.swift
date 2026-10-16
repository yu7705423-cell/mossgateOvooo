import SwiftUI

/// 说明书（网页版 settings/HelpPage.js，ARCHITECTURE 4.527）：界面上收起来的说明集中在这一处，可以搜。
/// 内容由 scripts/gen-help.mjs 从代码里的 HelpNote 收集（Resources/help.json）。
/// 不搜的时候按 app 分组、点开再看；搜了就把命中的几条直接列出来，上面先列「位置」（FindMap，4.646），点了过去。
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

    /// 打开时搜索框里已经有的词（主屏搜索的「在说明书中搜索」带过来）
    var initialQuery = ""
    /// 能不能打开会话（从主屏搜索进来时能）。为空时「位置」里的「搜索聊天记录」只显示位置
    var openChat: ((String) -> Void)?
    /// 打开时直接把搜索框点开（设置首页的「搜索设置与功能」）
    var focus = false

    @State private var query = ""
    @State private var open: Set<String> = []
    @State private var searching = false
    @State private var started = false
    @State private var chats: [Chat] = []
    @State private var names: [String: String] = [:]

    var body: some View {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = key.isEmpty ? Self.all : Self.all.filter { "\($0.app) \($0.title) \($0.text)".localizedCaseInsensitiveContains(key) }
        let apps = hits.reduce(into: [String]()) { if !$0.contains($1.app) { $0.append($1.app) } }
        // 位置（4.646）：功能在哪儿，点了过去。说明书只说是什么，这一组带你过去
        let places = key.isEmpty ? [] : FindMap.find(key)
        List {
            if !places.isEmpty {
                Section {
                    ForEach(places) { e in
                        FindPlaceLink(entry: e, chats: chats, names: names, openChat: openChat) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.t).foregroundStyle(Theme.text)
                                Text(e.at).font(.footnote).foregroundStyle(Theme.text2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                } header: { Text("位置") }
            }
            if hits.isEmpty && places.isEmpty {
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
        .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索功能或关键词")
        .navigationTitle("说明书")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !started else { return }
            started = true
            query = initialQuery
            chats = (try? Repo.chats()) ?? []
            names = Dictionary(((try? Repo.characters()) ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
            if focus { searching = true }
        }
    }
}
