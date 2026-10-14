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

/// 群资料里的群名与成员（从会话设置进来）。
struct GroupMembersSection: View {
    let chatId: String
    @State private var chat: Chat?
    @State private var members: [Character] = []
    @State private var others: [Character] = []
    @State private var title = ""
    @State private var problem: String?

    var body: some View {
        Group {
            Section {
                TextField("群名", text: $title).onSubmit(saveTitle)
                ForEach(members) { c in
                    HStack(spacing: Theme.gap) {
                        Avatar(imageId: c.avatar, name: c.name, size: 28)
                        Text(c.name)
                        if let chat, GroupChat.isMuted(chat, c.id) {
                            Text("禁言中").font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        if members.count > GroupChat.minMembers {
                            Button("移出") { setMembers(members.map(\.id).filter { $0 != c.id }) }
                                .font(.footnote).foregroundStyle(Theme.danger)
                        }
                    }
                }
                if !others.isEmpty {
                    Menu("添加成员") {
                        ForEach(others) { c in
                            Button(c.name) { setMembers(members.map(\.id) + [c.id]) }
                        }
                    }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            } header: {
                Text("群资料")
            } footer: {
                HelpNote("群聊至少保留 \(GroupChat.minMembers) 名成员。成员各自的记忆、世界书照常读取。")
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: saveTitle)
    }

    private func load() {
        do {
            guard let c = try Repo.chat(chatId) else { return }
            chat = c
            title = c.title
            members = GroupChat.members(c)
            let ids = Set(c.characterIds)
            others = try Repo.characters().filter { !ids.contains($0.id) && !$0.row.bool("isNpc") && $0.row.string("parentId").isEmpty }
        } catch {
            problem = "读取失败：\(error.localizedDescription)"
        }
    }

    private func setMembers(_ ids: [String]) {
        do { try GroupChat.setMembers(chatId, ids); problem = nil; load() }
        catch { problem = error.localizedDescription }
    }

    private func saveTitle() {
        guard var c = try? Repo.chat(chatId), c.title != title.trimmingCharacters(in: .whitespaces) else { return }
        c.row["title"] = .string(title.trimmingCharacters(in: .whitespaces))
        c.row.touch()
        do { try Repo.save(c) } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
