import SwiftUI
import UniformTypeIdentifiers

// 我的人设分区与一次性导入（网页版 apps/contact/SelfPages.js 的 SectionsList、SectionPage、SelfImportPage，ARCHITECTURE 4.347、4.959）。
// 人设正文只在编辑页的输入框里出现（网页版第 6 条）：账号页上的分区列表只写多少字。

/// 账号页上「我的人设」一组：一次性导入在最上面（网页版第 28 条：添加在顶上），六个分区只写多少字
struct SelfSectionsList: View {
    let personaId: String
    @State private var counts: [String: Int] = [:]

    var body: some View {
        Section {
            NavigationLink { SelfImportView(personaId: personaId) } label: { IconRow(title: "一次性导入", icon: "plus") }
            HelpNote("粘贴一整段或读取文件，全部存入基础资料，或调用一次接口按分区拆分", title: "一次性导入")
            ForEach(SelfProfile.sections) { s in
                NavigationLink { SectionEditView(personaId: personaId, secId: s.id) } label: {
                    LabeledContent(s.label, value: (counts[s.id] ?? 0) > 0 ? "\(counts[s.id] ?? 0) 字" : "未填写")
                }
            }
        } header: { GroupTitle("我的人设 · 对所有角色可见") } footer: {
            Text("人设按分区写入「对方是谁」。仅填写「基础资料」时，写入内容与原「基本介绍」一致。")
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let p = ((try? Repo.personas()) ?? []).first { $0.id == personaId }
        var out: [String: Int] = [:]
        for s in SelfProfile.sections { out[s.id] = SelfProfile.text(p, s.id).trimmingCharacters(in: .whitespacesAndNewlines).count }
        counts = out
    }
}

/// 一个分区的编辑页。随改随存
struct SectionEditView: View {
    let personaId: String
    @State var secId: String
    @State private var text = ""
    @State private var meName = ""
    @State private var problem: String?

    init(personaId: String, secId: String) {
        self.personaId = personaId
        _secId = State(initialValue: secId)
    }

    var body: some View {
        Form {
            Picker("分区", selection: $secId) { ForEach(SelfProfile.sections) { Text($0.label).tag($0.id) } }
                .pickerStyle(.menu)
            Section {
                TextField("一行写一件事。留空则不写入。", text: $text, axis: .vertical).lineLimit(8...40)
            } footer: {
                let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                Text("\(lines) 行 · \(text.trimmingCharacters(in: .whitespacesAndNewlines).count) 字")
                HelpNote("以该账号聊天时，所有角色均可读到此分区。自「角色眼中的你」合并的内容将另起一行追加至末尾。留空则不写入。", title: "我的人设分区")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle(SelfProfile.sections.first { $0.id == secId }?.label ?? "人设")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: secId) { _, _ in load() }
        .onChange(of: text) { _, v in
            let p = ((try? Repo.personas()) ?? []).first { $0.id == personaId }
            guard SelfProfile.text(p, secId) != v else { return }
            do { try SelfProfile.setText(personaId, secId, v); problem = nil } catch { problem = "保存失败：\(error.localizedDescription)" }
        }
    }

    private func load() {
        let p = ((try? Repo.personas()) ?? []).first { $0.id == personaId }
        text = SelfProfile.text(p, secId)
        meName = p?.name ?? ""
    }
}

/// 一次性导入我的人设（4.959）。全部存入基础资料不调接口；按分区拆分调一次接口，拆出来的先在这一页看过、可改，再存。
/// 这一页是生成结果的确认页，人设正文可以出现（网页版第 6 条的例外）
struct SelfImportView: View {
    let personaId: String
    @State private var text = ""
    @State private var replace = false
    @State private var busy = ""
    @State private var got: SelfProfile.Split?
    @State private var picking = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    private static let types: [UTType] = [.plainText, UTType(filenameExtension: "md") ?? .plainText,
                                          UTType(filenameExtension: "docx") ?? .data]

    var body: some View {
        Form {
            Section {
                TextField("粘贴一整段人设", text: $text, axis: .vertical).lineLimit(8...40)
                Button(busy == "file" ? "正在读取" : "读取文件") { picking = true }.disabled(!busy.isEmpty)
            } header: { Text("人设内容") } footer: {
                HelpNote("可以直接粘贴，也可以读取 .txt、.md、.docx 文件。读取的内容接在已粘贴的内容后面。", title: "人设内容")
            }
            Section("已有内容的分区") {
                Picker("已有内容的分区", selection: $replace) {
                    Text("接在后面").tag(false)
                    Text("替换").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if let g = got {
                Section {
                    ForEach(SelfProfile.sections) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.label).font(.system(size: 12)).foregroundStyle(Theme.text3)
                            TextField("没有拆到内容", text: binding(s.id), axis: .vertical).lineLimit(2...20)
                        }
                    }
                    ForEach(SelfProfile.profileKeys.indices, id: \.self) { i in
                        let f = SelfProfile.profileKeys[i]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(f.label).font(.system(size: 12)).foregroundStyle(Theme.text3)
                            TextField("未拆到", text: profile(f.id))
                        }
                    }
                } header: { Text("拆分结果") } footer: {
                    Text(replace ? "资料项填写时替换资料里的这一项。" : "资料项在资料里这一项为空时才写入。")
                }
                Section {
                    Button("按分区存入") { saveSplit(g) }.buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    Button("全部存入基础资料", action: saveAll).buttonStyle(EiraButtonStyle(kind: .primary, full: true)).disabled(!busy.isEmpty)
                    Button(busy == "split" ? "正在拆分" : "按分区拆分", action: split).buttonStyle(EiraButtonStyle(kind: .ghost, full: true)).disabled(!busy.isEmpty)
                } footer: {
                    Text("全部存入基础资料：原文不经接口，原样存入。按分区拆分会调用一次接口，原文照抄进基础资料、性格、喜好、习惯、雷点、生活状态六个分区，拆完先在这一页确认再存入。")
                }
                .listRowBackground(Color.clear)
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("导入人设")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: text) { _, _ in got = nil }
        .documentPicker(isPresented: $picking, types: Self.types) { urls in
            guard let url = urls.first else { return }
            busy = "file"
            do {
                let raw = try DocText.read(url).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { throw StoreError(message: "这个文件是空的") }
                let cur = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = cur.isEmpty ? raw : "\(cur)\n\n\(raw)"
                problem = nil
            } catch { problem = error.localizedDescription }
            busy = ""
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { got?.parts[id] ?? "" }, set: { got?.parts[id] = $0 })
    }

    private func profile(_ id: String) -> Binding<String> {
        Binding(get: {
            switch id { case "gender": return got?.gender ?? ""; case "birthday": return got?.birthday ?? ""; default: return got?.city ?? "" }
        }, set: { v in
            switch id { case "gender": got?.gender = v; case "birthday": got?.birthday = v; default: got?.city = v }
        })
    }

    private func saveAll() {
        do { try SelfProfile.saveAll(personaId, text, replace: replace); dismiss() }
        catch { problem = error.localizedDescription }
    }

    private func split() {
        let t = text
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { problem = "请先粘贴或读取内容"; return }
        busy = "split"; problem = nil
        Task {
            do { got = try await SelfProfile.parse(t) } catch { problem = error.localizedDescription }
            busy = ""
        }
    }

    private func saveSplit(_ g: SelfProfile.Split) {
        do { try SelfProfile.save(personaId, g, replace: replace); dismiss() }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
