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
    @State private var persona = ""
    @State private var scenario = ""
    @State private var firstMessage = ""
    @State private var exampleDialogue = ""
    @State private var core = ""
    @State private var avatar = ""
    @State private var appearance = ""
    @State private var imagePrompt = ""
    @State private var voiceId = ""
    @State private var voicePrompt = ""
    @State private var voiceLang = ""
    @State private var voiceSpeed = 1.0
    @State private var avatarItem: PhotosPickerItem?
    @State private var confirmDelete = false
    @State private var problem: String?
    @State private var saved = false
    @State private var archived = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Avatar(imageId: avatar, name: name, size: 64)
                    PhotosPicker(selection: $avatarItem, matching: .images) { Text("更换头像") }
                        .padding(.leading, Theme.pad)
                }
                TextField("名字", text: $name)
                TextField("备注（只有你看得到，显示时代替名字）", text: $remark)
                TextField("一句话签名（列表里显示这一句）", text: $signature)
            }
            Section("基本") {
                TextField("性别", text: $gender)
                TextField("年龄", text: $age)
                TextField("生日", text: $birthday)
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
            Section("说话示例") { TextField("说话示例", text: $exampleDialogue, axis: .vertical).lineLimit(3...30) }
            Section {
                TextField("核心设定", text: $core, axis: .vertical).lineLimit(2...20)
            } header: {
                Text("核心设定")
            } footer: {
                HelpNote("放在提示词末尾，每次请求都会带上。")
            }
            Section {
                TextField("外貌", text: $appearance, axis: .vertical).lineLimit(2...10)
                TextField("这个角色的固定生图提示词", text: $imagePrompt, axis: .vertical).lineLimit(2...10)
            } header: {
                Text("生图")
            } footer: {
                HelpNote("图片描述里出现这个角色的名字时，外貌随提示词一起发给生图接口；固定提示词接在这个角色发的每一张图后面。")
            }
            Section {
                TextField("音色 ID", text: $voiceId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("风格（留空用接口的默认风格）", text: $voicePrompt)
                Picker("语种", selection: $voiceLang) {
                    ForEach(VoicePreset.langs) { Text($0.id.isEmpty ? "跟随接口" : $0.label).tag($0.id) }
                }
                Stepper("语速 \(String(format: "%.1f", voiceSpeed))", value: $voiceSpeed, in: 0.5...2, step: 0.1)
            } header: {
                Text("语音")
            } footer: {
                HelpNote(voiceFooter)
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
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw StoreError(message: "无法读取所选图片") }
                    let id = try Images.save(data, maxPixel: Images.iconMax)
                    await MainActor.run { avatar = id; saved = false }
                } catch {
                    await MainActor.run { problem = "头像未能保存：\(error.localizedDescription)" }
                }
            }
        }
        .onChange(of: [name, remark, signature, gender, age, birthday, persona, scenario, firstMessage, exampleDialogue, core]) { _, _ in
            saved = false
        }
        .onChange(of: [appearance, imagePrompt, voiceId, voicePrompt, voiceLang]) { _, _ in saved = false }
        .onChange(of: voiceSpeed) { _, _ in saved = false }
        .onAppear(perform: load)
    }

    private var voiceFooter: String {
        let s = AppSettings.load()
        guard let vp = s.activeVoice, s.voiceEnabled else { return "「设置 - 接口与服务 - 语音合成」开启后，填写了音色的角色可以发语音。" }
        return "音色填在当前语音接口「\(vp.name)」上，换一套接口需另填。填写后角色可以在回复里发语音，每条调用一次语音接口。"
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
            persona = c.persona; scenario = c.scenario; firstMessage = c.firstMessage
            exampleDialogue = c.exampleDialogue; core = c.core; avatar = c.avatar
            appearance = c.row.string("appearance"); imagePrompt = c.row.string("imagePrompt")
            voiceId = VoiceGen.voiceId(c, presetId: AppSettings.load().activeVoice?.id ?? "")
            voicePrompt = c.row.string("voicePrompt"); voiceLang = c.row.string("voiceLang")
            voiceSpeed = c.row.number("voiceSpeed") ?? 1
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save() {
        guard let c = try? Repo.character(charId) ?? loaded else { problem = "这个角色不存在"; return }
        let fields: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)), "remark": .string(remark), "signature": .string(signature),
            "gender": .string(gender), "age": .string(age), "birthday": .string(birthday),
            "persona": .string(persona), "scenario": .string(scenario), "firstMessage": .string(firstMessage),
            "exampleDialogue": .string(exampleDialogue), "core": .string(core),
            "avatar": avatar.isEmpty ? .null : .string(avatar),
            "appearance": .string(appearance), "imagePrompt": .string(imagePrompt),
            "voicePrompt": .string(voicePrompt), "voiceLang": .string(voiceLang), "voiceSpeed": .number(voiceSpeed),
        ]
        var all = fields
        // 音色按语音接口分别存；没有语音接口时不写
        if let vp = AppSettings.load().activeVoice {
            for (k, v) in VoiceGen.voiceIdPatch(c, presetId: vp.id, id: voiceId.trimmingCharacters(in: .whitespaces)) { all[k] = v }
        }
        do {
            loaded = try People.update(c, all)
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
