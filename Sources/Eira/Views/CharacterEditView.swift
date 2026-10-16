import PhotosUI
import SwiftUI

/// 编辑资料。人设正文（人设、情境、开场白、说话示例、核心设定）只在这一页出现（网页版第 6 条）。
/// 只改这一页上的字段，网页版的其他开关与状态原样留着。
struct CharacterEditView: View {
    let charId: String
    @Binding var path: NavigationPath

    @State private var loaded: Character?
    @State private var name = ""
    @State private var remark = ""
    @State private var signature = ""
    @State private var gender = ""
    @State private var age = ""
    @State private var birthday = ""
    @State private var region = ""
    @State private var persona = ""
    @State private var scenario = ""
    @State private var firstMessage = ""
    @State private var exampleDialogue = ""
    @State private var core = ""
    @State private var avatar = ""
    @State private var appearance = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarBase = ""
    @State private var confirmDelete = false
    @State private var problem: String?
    @State private var saved = false
    @State private var archived = false
    @State private var abilityCount = ""
    /// 「从人设中生成 / 提取」：正在跑的那一栏、等用户确认覆盖的那一栏、各栏按钮下面的结果
    @State private var making: CardFields.Kind?
    @State private var askOverwrite: CardFields.Kind?
    @State private var pullNote: [CardFields.Kind: PullNote] = [:]

    private struct PullNote: Equatable {
        let text: String
        let failed: Bool
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Avatar(imageId: avatar, name: name, size: 64)
                    PhotosPicker(selection: $avatarItem, matching: .images) { Text("更换头像") }
                        .padding(.leading, Theme.pad)
                }
                if !avatarBase.isEmpty {
                    Button("换回原本的头像") {
                        do {
                            try AvatarPool.restore(charId)
                            avatar = avatarBase; avatarBase = ""
                        } catch { problem = "保存失败：\(error.localizedDescription)" }
                    }
                    HelpNote("当前这张是角色在对话中自己换上的。换回之后，原本那张重新成为角色的头像。", title: "换回原本的头像")
                }
                NavigationLink("头像库") { AvatarPoolView(charId: charId) }
                TextField("名字", text: $name)
                TextField("备注（只有你看得到，显示时代替名字）", text: $remark)
                TextField("一句话签名（列表里显示这一句）", text: $signature)
            }
            Section("基本") {
                TextField("性别", text: $gender)
                TextField("年龄", text: $age)
                TextField("生日", text: $birthday)
                TextField("所在地区（城市名，用于天气与吃什么）", text: $region)
            }
            Section {
                TextField("人设", text: $persona, axis: .vertical).lineLimit(6...40)
            } header: {
                Text("人设")
            } footer: {
                HelpNote("每次请求都会带上。只在本页显示。")
            }
            Section("情境") { TextField("当前情境", text: $scenario, axis: .vertical).lineLimit(3...20) }
            Section {
                TextField("开场白", text: $firstMessage, axis: .vertical).lineLimit(2...20)
            } header: {
                Text("开场白")
            } footer: {
                HelpNote("会话中还没有消息时显示，不发给模型。")
            }
            Section {
                TextField("说话示例", text: $exampleDialogue, axis: .vertical).lineLimit(3...30)
                pullButton(.examples)
            } header: {
                Text("说话示例")
            } footer: {
                Text("读取上方的人设，调用一次接口写出几句该角色的典型发言。")
                HelpNote("提供几句角色的典型发言。示例比形容词更有效。这一栏已有内容时，生成前先确认是否覆盖。", title: "说话示例")
            }
            Section {
                TextField("核心设定", text: $core, axis: .vertical).lineLimit(2...20)
                pullButton(.core)
            } header: {
                Text("核心设定")
            } footer: {
                Text("读取上方的人设，调用一次接口整理出核心设定。")
                HelpNote("放在提示词末尾，每次请求都会带上。")
            }
            Section {
                TextField("外貌", text: $appearance, axis: .vertical).lineLimit(2...10)
                pullButton(.appearance)
            } header: {
                Text("外貌")
            } footer: {
                Text("读取上方的人设，调用一次接口整理出外貌。")
                HelpNote("仅用于生成图片。图片描述里出现这个角色的名字时，外貌随提示词一起发给生图接口。写发型、五官、身形、常穿什么，不写性格。")
            }
            Section {
                NavigationLink { AbilitiesPage(charId: charId) } label: {
                    LabeledContent("角色能力", value: abilityCount)
                }
            } footer: {
                HelpNote("语音、图片、表情、转账、通话等各项的开关，以及音色、生图提示词与锁脸，都在「角色能力」中设置。会话右上角菜单的「这个角色 - 角色能力」进入的是同一页。", title: "角色能力")
            }
            Section {
                Toggle("封存", isOn: Binding(get: { archived }, set: { setArchived($0) }))
            } footer: {
                HelpNote("封存后，角色不出现在联系人与发起群聊的名单里，与该角色的单聊可以翻看、不能继续对话，角色也不再主动发起对话。数据全部保留，关闭封存即恢复。", title: "封存")
            }
            Section {
                Button("删除角色", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText)
            } footer: {
                Text("同时删除与该角色的单聊、全部记忆与按角色存的数据，无法撤销。群聊中只移除该角色。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("编辑资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saved ? "已保存" : "保存", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("删除后无法恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除角色", role: .destructive, action: remove)
        }
        .confirmationDialog(askOverwrite.map { pullTitle($0) } ?? "", isPresented: Binding(
            get: { askOverwrite != nil }, set: { if !$0 { askOverwrite = nil } }),
            titleVisibility: .visible, presenting: askOverwrite) { k in
            Button("覆盖", role: .destructive) { pull(k) }
        } message: { k in
            Text("将以生成的内容覆盖这一栏现有的\(k.label)。")
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw StoreError(message: "无法读取所选图片") }
                    let id = try Images.save(data, maxPixel: Images.iconMax)
                    await MainActor.run { avatar = id; avatarBase = ""; saved = false }
                } catch {
                    await MainActor.run { problem = "头像未能保存：\(error.localizedDescription)" }
                }
            }
        }
        .onChange(of: [name, remark, signature, gender, age, birthday, persona, scenario, firstMessage, exampleDialogue, core]) { _, _ in
            saved = false
        }
        .onChange(of: appearance) { _, _ in saved = false }
        .onAppear {
            load()
            // 从「角色能力」返回时开关数要跟上
            abilityCount = Abilities.countLabel((try? Repo.character(charId)) ?? nil)
        }
    }

    // MARK: - 从人设中生成 / 提取（网页版 4.590）

    @ViewBuilder private func pullButton(_ k: CardFields.Kind) -> some View {
        Button(making == k ? (k == .appearance ? "正在提取" : "正在生成") : (k == .appearance ? "从人设中提取" : "从人设中生成")) {
            // 那一栏已经有内容时先问，免得盖掉自己写的
            if value(k).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pull(k) } else { askOverwrite = k }
        }
        .disabled(making != nil)
        if let n = pullNote[k] {
            Text(n.text).font(.footnote).foregroundStyle(n.failed ? Theme.danger : Theme.text2)
        }
    }

    private func pullTitle(_ k: CardFields.Kind) -> String {
        k == .appearance ? "重新提取外貌" : "重新生成\(k.label)"
    }

    private func value(_ k: CardFields.Kind) -> String {
        switch k {
        case .core: return core
        case .examples: return exampleDialogue
        case .appearance: return appearance
        }
    }

    /// 读输入框里的人设（可能尚未保存）调一次接口。结果当即写进库里的那一栏，不等「保存」，花了钱的结果不会因为没点保存而丢；
    /// 其他尚未保存的改动照旧等「保存」。失败写在按钮下面（第 20 条）
    private func pull(_ k: CardFields.Kind) {
        askOverwrite = nil
        making = k
        pullNote[k] = nil
        let text = persona
        Task {
            do {
                let out = try await CardFields.make(k, persona: text)
                await MainActor.run {
                    switch k {
                    case .core: core = out
                    case .examples: exampleDialogue = out
                    case .appearance: appearance = out
                    }
                    do {
                        guard let c = try Repo.character(charId) ?? loaded else { throw StoreError(message: "这个角色不存在") }
                        loaded = try People.update(c, [k.field: .string(out)])
                        pullNote[k] = PullNote(text: k == .appearance ? "已提取。" : "已生成\(k.label)。", failed: false)
                    } catch {
                        pullNote[k] = PullNote(text: "已生成，但未能保存：\(error.localizedDescription)。点右上角「保存」再试一次。", failed: true)
                    }
                }
            } catch {
                await MainActor.run { pullNote[k] = PullNote(text: error.localizedDescription, failed: true) }
            }
            await MainActor.run { making = nil }
        }
    }

    /// 封存（网页版 characters.archived，记的是封存那一刻的毫秒）：随改随存，不等「保存」
    private func setArchived(_ on: Bool) {
        do {
            guard var c = try Repo.character(charId) else { return }
            if on { c.row["archived"] = .number(Date().millis) } else { c.row["archived"] = .number(0) }
            c.row.touch()
            try Database.shared.put(Collections.characters, c.row)
            archived = on
            if on { Proactive.setNext(charId, 0) }
            NotificationCenter.default.post(name: .eiraChatChanged, object: nil)
        } catch {
            problem = "封存未能保存：\(error.localizedDescription)"
        }
    }

    private func load() {
        guard loaded == nil else { return }
        do {
            guard let c = try Repo.character(charId) else { problem = "这个角色不存在"; return }
            loaded = c
            archived = c.archived
            name = c.name; remark = c.remark; signature = c.signature
            gender = c.row.string("gender"); age = c.row.string("age"); birthday = c.row.string("birthday")
            region = c.row.string("region")
            persona = c.persona; scenario = c.scenario; firstMessage = c.firstMessage
            exampleDialogue = c.exampleDialogue; core = c.core; avatar = c.avatar
            avatarBase = AvatarPool.base(c.row)
            appearance = c.row.string("appearance")
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save() {
        guard let c = try? Repo.character(charId) ?? loaded else { problem = "这个角色不存在"; return }
        let fields: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)), "remark": .string(remark), "signature": .string(signature),
            "gender": .string(gender), "age": .string(age), "birthday": .string(birthday),
            "region": .string(String(region.trimmingCharacters(in: .whitespaces).prefix(20))),
            "persona": .string(persona), "scenario": .string(scenario), "firstMessage": .string(firstMessage),
            "exampleDialogue": .string(exampleDialogue), "core": .string(core),
            "avatar": avatar.isEmpty ? .null : .string(avatar),
            // 自己选了一张就是新的原本那张；角色换过的那张记录在 avatarBase
            "avatarBase": .string(avatarBase),
            "appearance": .string(appearance),
        ]
        // 音色、生图提示词、锁脸与各项能力在「角色能力」中随改随存，这里不写，免得拿打开时读到的旧值盖掉
        do {
            loaded = try People.update(c, fields)
            saved = true
            problem = nil
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
    }

    private func remove() {
        do {
            try People.deleteCharacter(charId)
            path = NavigationPath()
        } catch {
            problem = "删除失败：\(error.localizedDescription)"
        }
    }
}
