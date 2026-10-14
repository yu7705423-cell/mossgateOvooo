import PhotosUI
import SwiftUI

/// 建一个群：选至少两个角色，可以起群名（网页版 GroupBits 的新建群聊）。
struct NewGroupView: View {
    var onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chars: [Character] = []
    @State private var picked: Set<String> = []
    @State private var title = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextField("群名（可不填）", text: $title)
            } footer: {
                HelpNote("不填时用成员的名字拼成群名。")
            }
            Section {
                ForEach(chars) { c in
                    Button {
                        if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                    } label: {
                        HStack(spacing: Theme.gap) {
                            Avatar(imageId: c.avatar, name: c.name)
                            Text(c.name).foregroundStyle(Theme.bubbleTheirsText)
                            Spacer()
                            if picked.contains(c.id) { Image(systemName: "checkmark").foregroundStyle(Theme.secondaryText) }
                        }
                    }
                }
            } header: {
                Text("成员（已选 \(picked.count)）")
            } footer: {
                HelpNote("至少选择 \(GroupChat.minMembers) 名成员。每轮由一次调用写出开口的几个人。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("新建群聊")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("建立", action: create).disabled(picked.count < GroupChat.minMembers)
            }
        }
        .onAppear {
            chars = ((try? Repo.characters()) ?? []).filter { !$0.row.bool("isNpc") && $0.row.string("parentId").isEmpty }
        }
    }

    private func create() {
        do {
            let me = try People.ensureActivePersona()
            let ordered = chars.map(\.id).filter { picked.contains($0) }
            let chat = try GroupChat.create(memberIds: ordered, title: title, personaId: me.id)
            dismiss()
            onCreated(chat.id)
        } catch {
            problem = "建立失败：\(error.localizedDescription)"
        }
    }
}

/// 群资料（网页版 GroupBits 的 GroupPage）：群名、群头像、我的群昵称、全员禁言、成员（点进去改群昵称、设管理员、禁言、移出）、添加成员。
/// 你是群主；你做的每一件事在群里落一行提示，角色下一轮看得到。
struct GroupMembersSection: View {
    let chatId: String
    @State private var chat: Chat?
    @State private var members: [Character] = []
    @State private var others: [Character] = []
    @State private var title = ""
    @State private var myNick = ""
    @State private var problem: String?
    @State private var adding = false
    @State private var picking = false
    @State private var photo: PhotosPickerItem?

    var body: some View {
        Group {
            Section {
                TextField("群名", text: $title).onSubmit(saveTitle)
                HStack {
                    Text("群头像")
                    Spacer()
                    if let chat, !chat.avatar.isEmpty {
                        Avatar(imageId: chat.avatar, name: title, size: 32)
                        Button("恢复") { setAvatar("") }.font(.footnote).buttonStyle(.borderless)
                    }
                    Button(chat?.avatar.isEmpty == false ? "更换" : "选择") { picking = true }.font(.footnote).buttonStyle(.borderless)
                }
                TextField("我在群里的昵称", text: $myNick).onSubmit(saveMyNick)
                Toggle("全员禁言", isOn: Binding(get: { chat?.row.bool("muteAll") ?? false }, set: { v in act { try GroupChat.setMuteAll(chatId, v) } }))
            } header: {
                Text("群资料")
            } footer: {
                HelpNote("全员禁言开启后，只有管理员可以发言。改名、禁言、设管理员都会在群里留下一行提示，角色下一轮看得到。", title: "群资料")
            }
            Section {
                if let chat {
                    ForEach(members) { c in
                        NavigationLink {
                            GroupMemberPage(chatId: chatId, charId: c.id, canRemove: members.count > GroupChat.minMembers) { load() }
                        } label: {
                            HStack(spacing: Theme.gap) {
                                Avatar(imageId: c.avatar, name: c.name, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(GroupChat.nameIn(chat, c))
                                        let role = GroupChat.roleLabel[GroupChat.role(chat, c.id)] ?? ""
                                        if !role.isEmpty {
                                            Text(role).font(.system(size: 10)).foregroundStyle(Theme.text3)
                                                .padding(.horizontal, 4).overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                                        }
                                    }
                                    let sub = [GroupChat.nick(chat, c.id).isEmpty ? "" : c.name, GroupChat.muteText(chat, c.id)]
                                        .filter { !$0.isEmpty }.joined(separator: " · ")
                                    if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(Theme.text3) }
                                }
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    Button { adding = true } label: { Label("添加成员", systemImage: "plus") }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            } header: {
                Text("成员 \(members.count) 人")
            } footer: {
                HelpNote("群聊至少保留 \(GroupChat.minMembers) 名成员。成员各自的记忆、世界书照常读取。")
            }
        }
        .onAppear(perform: load)
        .onDisappear { saveTitle(); saveMyNick() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                AddMembersView(candidates: others) { ids in
                    adding = false
                    guard !ids.isEmpty else { return }
                    setMembers(members.map(\.id) + ids)
                }
            }
        }
        .photosPicker(isPresented: $picking, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let id = try Images.save(data, maxPixel: Images.iconMax)
                    await MainActor.run { setAvatar(id) }
                } catch {
                    await MainActor.run { problem = "群头像未能保存：\(error.localizedDescription)" }
                }
            }
        }
    }

    private func load() {
        do {
            guard let c = try Repo.chat(chatId) else { return }
            chat = c
            title = c.title
            myNick = GroupChat.nick(c, GroupChat.me)
            members = GroupChat.members(c)
            let ids = Set(c.characterIds)
            others = try Repo.characters().filter { !ids.contains($0.id) && !$0.row.bool("isNpc") && $0.row.string("parentId").isEmpty && !$0.archived }
        } catch {
            problem = "读取失败：\(error.localizedDescription)"
        }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = error.localizedDescription }
        load()
    }

    private func setMembers(_ ids: [String]) { act { try GroupChat.setMembers(chatId, ids) } }

    private func setAvatar(_ id: String) {
        act {
            guard var c = try Repo.chat(chatId) else { return }
            c.row["avatar"] = .string(id)
            c.row.touch()
            try Repo.save(c)
            NotificationCenter.default.post(name: .eiraChatChanged, object: chatId)
        }
    }

    private func saveMyNick() {
        guard let chat, myNick.trimmingCharacters(in: .whitespaces) != GroupChat.nick(chat, GroupChat.me) else { return }
        act { try GroupChat.setNick(chatId, GroupChat.me, myNick) }
    }

    private func saveTitle() {
        guard var c = try? Repo.chat(chatId), c.title != title.trimmingCharacters(in: .whitespaces) else { return }
        c.row["title"] = .string(title.trimmingCharacters(in: .whitespaces))
        c.row.touch()
        do { try Repo.save(c) } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}

/// 群里的一位成员：群昵称、管理员、禁言、移出
struct GroupMemberPage: View {
    let chatId: String
    let charId: String
    let canRemove: Bool
    var changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chat: Chat?
    @State private var char: Character?
    @State private var nick = ""
    @State private var problem: String?
    @State private var confirmRemove = false

    var body: some View {
        Form {
            if let chat, let char {
                Section {
                    HStack(spacing: Theme.sp3) {
                        Avatar(imageId: char.avatar, name: char.name, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(GroupChat.nameIn(chat, char)).font(.headline)
                            Text(char.name).font(.caption).foregroundStyle(Theme.text3)
                        }
                    }
                    TextField("群昵称（留空为原名）", text: $nick).onSubmit(saveNick)
                }
                Section {
                    Toggle("管理员", isOn: Binding(get: { GroupChat.role(chat, charId) == "admin" },
                                                 set: { v in act { try GroupChat.setAdmin(chatId, charId, v) } }))
                    let left = GroupChat.muteText(chat, charId)
                    if !left.isEmpty && chat.row["mutes"]?[charId] != nil {
                        LabeledContent("禁言", value: left)
                        Button("解除禁言") { act { try GroupChat.unmute(chatId, charId) } }
                    } else {
                        Menu("禁言") {
                            ForEach(GroupChat.muteSteps, id: \.minutes) { st in
                                Button(st.label) { act { try GroupChat.mute(chatId, charId, minutes: st.minutes) } }
                            }
                        }
                    }
                } footer: {
                    HelpNote("禁言中的成员在这一轮不发言；全员禁言时只有管理员发言。", title: "禁言")
                }
                if canRemove {
                    Section {
                        Button("移出群聊", role: .destructive) { confirmRemove = true }.foregroundStyle(Theme.dangerText)
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
            }
        }
        .navigationTitle("成员")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear(perform: saveNick)
        .confirmationDialog("将该成员移出群聊。聊天记录保留。", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移出", role: .destructive) {
                act {
                    guard let c = try Repo.chat(chatId) else { return }
                    try GroupChat.setMembers(chatId, c.characterIds.filter { $0 != charId })
                }
                dismiss()
            }
        }
    }

    private func load() {
        chat = try? Repo.chat(chatId)
        char = try? Repo.character(charId)
        if let chat { nick = GroupChat.nick(chat, charId) }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = error.localizedDescription }
        load()
        changed()
    }

    private func saveNick() {
        guard let chat, nick.trimmingCharacters(in: .whitespaces) != GroupChat.nick(chat, charId) else { return }
        act { try GroupChat.setNick(chatId, charId, nick) }
    }
}

/// 一次添加几位成员
struct AddMembersView: View {
    let candidates: [Character]
    var done: ([String]) -> Void
    @State private var picked: Set<String> = []

    var body: some View {
        List(candidates) { c in
            Button {
                if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
            } label: {
                HStack(spacing: Theme.gap) {
                    Avatar(imageId: c.avatar, name: c.name, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.displayName).foregroundStyle(Theme.text)
                        if !c.signature.isEmpty { Text(c.signature).font(.caption).foregroundStyle(Theme.text3).lineLimit(1) }
                    }
                    Spacer()
                    Image(systemName: picked.contains(c.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked.contains(c.id) ? Theme.accent : Theme.text3)
                }
            }
        }
        .navigationTitle("添加成员")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { done([]) } }
            ToolbarItem(placement: .confirmationAction) { Button("添加 \(picked.count)") { done(Array(picked)) }.disabled(picked.isEmpty) }
        }
    }
}
