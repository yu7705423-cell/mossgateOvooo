import PhotosUI
import SwiftUI

/// 我的身份：大号与小号。点一个切换为当前身份；消息列表只列当前身份的会话。
struct PersonaListView: View {
    @State private var personas: [Persona] = []
    @State private var activeId = ""
    @State private var problem: String?
    @State private var editing: EditTarget?

    struct Item: Identifiable {
        let persona: Persona
        let isAlt: Bool
        var id: String { persona.id }
    }

    struct EditTarget: Identifiable, Hashable { let id: String }

    var body: some View {
        List {
            ForEach(ordered) { item in
                HStack(spacing: Theme.pad) {
                    Avatar(imageId: item.persona.avatar, name: item.persona.name, size: 36)
                        .padding(.leading, item.isAlt ? Theme.pad * 2 : 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.persona.name)
                        if item.isAlt { Text("小号").font(.caption).foregroundStyle(Theme.secondaryText) }
                    }
                    Spacer()
                    if item.persona.id == activeId { Image(systemName: "checkmark").foregroundStyle(Theme.secondaryText) }
                    Button { editing = EditTarget(id: item.persona.id) } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("编辑「\(item.persona.name)」")
                }
                .contentShape(Rectangle())
                .onTapGesture { activate(item.persona.id) }
            }
            Section {
                Button("新建大号") { create(parent: nil) }
                if let root = rootOfActive { Button("为「\(root.name)」新建小号") { create(parent: root.id) } }
            } footer: {
                HelpNote("小号与大号共用记忆；用小号找同一个角色，开的是另一段会话。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("我的身份")
        .navigationDestination(item: $editing) { t in PersonaEditView(personaId: t.id) }
        .onAppear(perform: reload)
    }

    private var ordered: [Item] {
        let roots = personas.filter { ($0.parentId ?? "").isEmpty }
        var out: [Item] = []
        for r in roots {
            out.append(Item(persona: r, isAlt: false))
            out += personas.filter { $0.parentId == r.id }.map { Item(persona: $0, isAlt: true) }
        }
        // 大号已经不在的小号也列出来，不让它消失
        let listed = Set(out.map(\.id))
        out += personas.filter { !listed.contains($0.id) }.map { Item(persona: $0, isAlt: true) }
        return out
    }

    private var rootOfActive: Persona? {
        guard let a = personas.first(where: { $0.id == activeId }) else { return nil }
        let rootId = Repo.rootId(of: a.id, in: personas)
        return personas.first { $0.id == rootId }
    }

    private func reload() {
        do {
            personas = try Repo.personas()
            activeId = try Repo.activePersona()?.id ?? ""
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func activate(_ id: String) {
        do { try People.setActivePersona(id); activeId = id }
        catch { problem = "切换失败：\(error.localizedDescription)" }
    }

    private func create(parent: String?) {
        do {
            let name = parent.flatMap { id in personas.first { $0.id == id }?.name }.map { "\($0)的小号" } ?? "新账号"
            _ = try People.createPersona(name: name, parentId: parent)
            reload()
        } catch {
            problem = "新建失败：\(error.localizedDescription)"
        }
    }
}

/// 编辑一个身份。基本介绍会以「对方是谁」写进提示词。
struct PersonaEditView: View {
    let personaId: String
    @State private var loaded: Persona?
    @State private var name = ""
    @State private var signature = ""
    @State private var gender = ""
    @State private var description = ""
    @State private var avatar = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var saved = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Avatar(imageId: avatar, name: name, size: 64)
                    PhotosPicker(selection: $avatarItem, matching: .images) { Text("更换头像") }.padding(.leading, Theme.pad)
                }
                TextField("名字", text: $name)
                TextField("一句话签名", text: $signature)
                TextField("性别", text: $gender)
            }
            Section {
                TextField("基本介绍", text: $description, axis: .vertical).lineLimit(4...30)
            } header: {
                Text("基本介绍")
            } footer: {
                HelpNote("角色在对话中看到的「你是谁」。")
            }
            Section {
                NavigationLink("我的锁脸") { FaceLockView(owner: .me(personaId)) }
            } footer: {
                HelpNote("图片里出现你时（描述里写了你的名字，或是合照），照片随生图请求发出，或读成外貌描述拼进提示词，和角色的锁脸同一套规则。", title: "我的锁脸")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("编辑身份")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saved ? "已保存" : "保存", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
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
        .onChange(of: [name, signature, gender, description]) { _, _ in saved = false }
        .onAppear {
            guard loaded == nil, let p = (try? Repo.personas())?.first(where: { $0.id == personaId }) else { return }
            loaded = p
            name = p.name; signature = p.signature; gender = p.row.string("gender"); description = p.description; avatar = p.avatar
        }
    }

    private func save() {
        guard let p = loaded else { return }
        do {
            loaded = try People.update(p, [
                "name": .string(name.trimmingCharacters(in: .whitespaces)), "signature": .string(signature),
                "gender": .string(gender), "description": .string(description),
                "avatar": avatar.isEmpty ? .null : .string(avatar),
            ])
            saved = true
            problem = nil
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
    }
}
