import SwiftUI

/// 新功能第一次用到时问一次（网页版 shell/Root.js 的 pendingFor，ARCHITECTURE 4.486、4.905）。
///
/// 打开功能所在的 app 时，还没问过的合成一问：全部角色开启 / 选择角色开启 / 暂不。选的结果写进「设定集 - 能力开关」
/// 「新功能」那一组的同一个设置（settings.featureOpt）；选角色开启时全局记成不开、选中的角色各自记成开启（char.featOpt），
/// 和「角色能力 - 新功能」改的是同一份（第 5 条）。没回答就关掉的不算问过，下次打开再问。
struct NewFeatAsk: ViewModifier {
    let app: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var asking: [NewFeat.Feature] = []
    @State private var picking = false

    func body(content: Content) -> some View {
        content
            .onAppear { asking = NewFeat.pending(app: app, model.s) }
            .confirmationDialog(title, isPresented: Binding(get: { !asking.isEmpty && !picking }, set: { if !$0 && !picking { asking = [] } }),
                                titleVisibility: .visible) {
                Button("全部角色开启") { decide(true) }
                Button("选择角色开启") { picking = true }
                Button(asking.count > 1 ? "全部暂不" : "暂不") { decide(false) }
                Button("稍后再说", role: .cancel) { asking = [] }
            } message: {
                Text(message)
            }
            .sheet(isPresented: $picking, onDismiss: { asking = [] }) {
                NavigationStack {
                    NewFeatPickChars(labels: asking.map(\.label)) { ids in
                        let list = asking
                        model.update { s in for f in list { NewFeat.set(f.id, false, &s) } }
                        do {
                            for id in ids { for f in list { try NewFeat.setFor(id, f.id, "on") } }
                        } catch { model.problem = "未能保存：\(error.localizedDescription)" }
                        picking = false
                    }
                }
            }
    }

    private var title: String {
        asking.count > 1 ? "让角色使用这 \(asking.count) 项新功能" : "让角色使用「\(asking.first?.label ?? "")」"
    }

    private var message: String {
        if asking.count > 1 {
            return asking.map { "「\($0.label)」" }.joined() + "。各项的说明与开关在「设定集 - 能力开关」的「新功能」中，之后可以在那里逐项更改。"
        }
        return (asking.first?.desc ?? "") + "。之后可以在「设定集 - 能力开关」的「新功能」中更改全局，在每个角色的「角色能力」中单独更改。"
    }

    private func decide(_ on: Bool) {
        let list = asking
        model.update { s in for f in list { NewFeat.set(f.id, on, &s) } }
        asking = []
    }
}

extension View {
    func newFeatAsk(app: String) -> some View { modifier(NewFeatAsk(app: app)) }
}

/// 选择开启的角色（网页版 pickChars）。没选就关掉不算问过
private struct NewFeatPickChars: View {
    let labels: [String]
    var done: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chars: [Character] = []
    @State private var picked: Set<String> = []

    var body: some View {
        List {
            Section {
                ForEach(chars) { c in
                    Button { if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) } } label: {
                        HStack {
                            Avatar(imageId: c.avatar, name: c.displayName, size: 32)
                            Text(c.displayName).foregroundStyle(Theme.text)
                            Spacer()
                            if picked.contains(c.id) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
                if chars.isEmpty { Text("还没有角色。").foregroundStyle(Theme.text3) }
            } footer: {
                Text("\(labels.map { "「\($0)」" }.joined())只对选中的角色开启，其余角色不开启。")
            }
        }
        .navigationTitle("选择开启的角色")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("确定") { done(Array(picked)) }.disabled(picked.isEmpty) }
        }
        .onAppear { chars = ((try? Repo.characters()) ?? []).filter { !$0.archived && !$0.isNpc } }
    }
}

/// 「角色能力」最下面的「新功能」（网页版 4.882）：这个角色自己选跟随全局、开启或关闭。存在角色卡上（char.featOpt）
struct NewFeatCharSection: View {
    let charId: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var tick = 0
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let char = (try? Repo.character(charId)) ?? nil
        Section {
            ForEach(NewFeat.features, id: \.id) { f in
                Picker(f.label, selection: Binding(get: { NewFeat.ownOf(char, f.id) }, set: { v in
                    do { try NewFeat.setFor(charId, f.id, v); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
                    tick += 1
                })) {
                    Text("跟随全局（\(NewFeat.isOn(f.id, model.s) ? "开启" : "关闭")）").tag("")
                    Text("开启").tag("on")
                    Text("关闭").tag("off")
                }
            }
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            HelpNote("这个角色单独开启或关闭新功能，选过的不看全局。群聊中有一名成员开启就算开启。全局的开关在「设定集 - 能力开关」最上面的「新功能」。", title: "角色能力：新功能")
        } header: {
            Text("新功能")
        }
    }
}
