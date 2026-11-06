import SwiftUI

/// 会话页上的几张页：发红包、群里转账、红包详情、图片版本；以及本群页面打开时接着聊的计时（网页版 4.736、4.861、4.1018）。
/// 挂成一个修饰，会话页那边只多一行，不再往那一长串里加
struct ChatMediaState {
    var redPacket = false
    var groupTransfer = false
    /// 加号面板的「申请」「卡券」（网页版 RequestSheet；娱乐卡送进这段对话）
    var request = false
    var funcard = false
    var packetId: String?
    var versionsId: String?
}

struct ChatMediaSheets: ViewModifier {
    let chatId: String
    @Binding var state: ChatMediaState
    let draftEmpty: Bool
    let busy: Bool
    let onChange: () -> Void
    @Environment(\.scenePhase) private var phase

    private struct Target: Identifiable { let id: String }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $state.redPacket, onDismiss: onChange) {
                NavigationStack { RedPacketSendView(chatId: chatId) }
            }
            .sheet(isPresented: $state.groupTransfer, onDismiss: onChange) {
                NavigationStack { GroupTransferView(chatId: chatId) }
            }
            .sheet(isPresented: $state.request, onDismiss: onChange) {
                NavigationStack { LedgerRequestSheet(chatId: chatId) }
            }
            .sheet(isPresented: $state.funcard, onDismiss: onChange) {
                NavigationStack { NewFunCardView(chatId: chatId) }
            }
            .sheet(item: Binding(get: { state.packetId.map { Target(id: $0) } }, set: { state.packetId = $0?.id }), onDismiss: onChange) { t in
                NavigationStack { RedPacketDetailView(messageId: t.id) }
            }
            .sheet(item: Binding(get: { state.versionsId.map { Target(id: $0) } }, set: { state.versionsId = $0?.id }), onDismiss: onChange) { t in
                NavigationStack { ImageVersionsView(messageId: t.id) }
            }
            .onAppear { GroupAmbient.enter(chatId) }
            .onDisappear { GroupAmbient.leave(chatId) }
            // 输入框、生成状态、前后台一变就重排：每五秒问一次该不该接着聊（离开页面即停）
            .task(id: "\(chatId)|\(draftEmpty)|\(busy)|\(phase == .active)") { await ambientLoop() }
    }

    private func ambientLoop() async {
        guard phase == .active, ((try? Repo.chat(chatId)) ?? nil)?.isGroup == true else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            guard GroupAmbient.due(chatId: chatId, draftEmpty: draftEmpty, busy: busy) else { continue }
            do {
                _ = try await GroupAmbient.round(chatId: chatId)
            } catch {
                // 失败也算试过：等满一个间隔再试，不立即重试
                Problems.report("群里接着聊未能进行：\(error.localizedDescription)。等满一个间隔后再试。")
            }
            await MainActor.run { onChange() }
        }
    }
}

// MARK: - 红包

/// 发红包（网页版 RedPacketBits 的 SendRedPacketSheet）
struct RedPacketSendView: View {
    let chatId: String
    @Environment(\.dismiss) private var dismiss
    @State private var type = RedPacket.luck
    @State private var total = ""
    @State private var count = ""
    @State private var note = ""
    @State private var to = ""
    @State private var chat: Chat?
    @State private var members: [Character] = []
    @State private var problem: String?

    private var n: Int { type == RedPacket.only ? 1 : (Int(count.trimmingCharacters(in: .whitespaces)) ?? 0) }
    private var amount: Double { Double(total.trimmingCharacters(in: .whitespaces)) ?? 0 }

    /// 分得出来就是预览，分不出来是原因
    private var preview: (shares: [Double], total: Double, error: String) {
        guard amount > 0, n > 0 else { return ([], 0, "") }
        do {
            let r = try RedPacket.split(type, total: amount, count: n, code: Interact.currency().code, rng: { 0.5 })
            return (r.shares, r.total, "")
        } catch { return ([], 0, error.localizedDescription) }
    }

    private var ready: Bool { !preview.shares.isEmpty && (type != RedPacket.only || !to.isEmpty) }

    var body: some View {
        let p = preview
        Form {
            Section {
                Picker("种类", selection: $type) {
                    Text("拼手气").tag(RedPacket.luck)
                    Text("普通").tag(RedPacket.equal)
                    Text("专属").tag(RedPacket.only)
                }
                .pickerStyle(.segmented)
            }
            Section {
                if type == RedPacket.only {
                    Picker("发给", selection: $to) {
                        Text("选择成员").tag("")
                        ForEach(members) { c in Text(chat.map { GroupPay.nameIn($0, c.id) } ?? c.name).tag(c.id) }
                    }
                } else {
                    HStack {
                        Text("红包个数")
                        TextField("填写个数", text: $count).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
                HStack {
                    Text(type == RedPacket.equal ? "总金额（平均分成每个红包）" : type == RedPacket.only ? "金额" : "总金额（随机分成每个红包）")
                    TextField(Interact.format(0), text: $total).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                TextField("祝福语（\(RedPacket.defaultNote)）", text: $note)
            } footer: {
                if type != RedPacket.only { Text("群里共 \(members.count + 1) 人，含你自己。") }
                if !p.error.isEmpty { Text(p.error).foregroundStyle(Theme.danger) }
                if type == RedPacket.equal, let each = p.shares.first, abs(p.total - amount) > 1e-9 {
                    Text("每个 \(Interact.display(each, nil))，实际发出 \(Interact.display(p.total, nil))。")
                }
                HelpNote("拼手气红包的总额随机分成每个；普通红包每个金额相同，除不尽的零头不发；专属红包只有指定的成员能领。每份金额在发出时分好。每人限领一次，发出的人也可以领取；24 小时内未领完的部分退回发出的人。不调用接口。", title: "发红包")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("发红包")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("塞进红包", action: submit).disabled(!ready) }
        }
        .onAppear {
            chat = (try? Repo.chat(chatId)) ?? nil
            members = chat.map { GroupChat.members($0) } ?? []
        }
    }

    private func submit() {
        do {
            _ = try RedPacket.send(chatId: chatId, type: type, total: amount, count: n, note: note, to: to)
            dismiss()
        } catch { problem = "红包未能发出：\(error.localizedDescription)" }
    }
}

/// 点开一个红包：能领就先领，之后看谁领了多少（网页版 RedPacketSheet）
struct RedPacketDetailView: View {
    let messageId: String
    @Environment(\.dismiss) private var dismiss
    @State private var message: Message?
    @State private var chat: Chat?
    @State private var problem: String?

    var body: some View {
        Form {
            if let m = message, let rp = RedPacket.packet(m) {
                let why = RedPacket.whyNot(m, who: GroupChat.me)
                let mine = rp.claims.first { $0.who == GroupChat.me }
                let best = RedPacket.best(rp)
                let taken = Interact.round(rp.claims.reduce(0) { $0 + $1.amount }, rp.currency)
                Section {
                    VStack(spacing: Theme.gap) {
                        Text(rp.note).font(.headline)
                        if let mine {
                            Text(Interact.display(mine.amount, rp.currency)).font(.title2)
                        } else if why.isEmpty {
                            Button("领取") { open(m) }.buttonStyle(.bordered)
                        } else {
                            Text(why).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.gap)
                }
                Section {
                    ForEach(rp.claims, id: \.who) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name(c.who))
                                Text(Self.time(c.at)).font(.caption).foregroundStyle(Theme.text3)
                            }
                            Spacer()
                            Text(Interact.display(c.amount, rp.currency))
                            if best == c.who { Text("手气最佳").font(.caption).foregroundStyle(Theme.secondaryText) }
                        }
                    }
                } header: {
                    Text("已领取 \(rp.claims.count)/\(rp.shares.count) 个，共 \(Interact.display(taken, rp.currency))/\(Interact.display(rp.total, rp.currency))")
                } footer: {
                    if RedPacket.state(rp, at: m.createdAt) == "expired" {
                        Text("红包已过期，未领取的 \(Interact.display(RedPacket.left(rp), rp.currency)) 已退回\(name(m.role == .user ? GroupChat.me : m.authorId))。")
                    }
                    Text(RedPacket.typeLabel[rp.type] ?? "")
                    HelpNote("每人限领一次，发出的人也可以领取；24 小时内未领完的部分退回发出的人。", title: "红包")
                }
            } else {
                Section { Text("该红包已不存在").foregroundStyle(Theme.secondaryText) }
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle(message.map { "\(name($0.role == .user ? GroupChat.me : $0.authorId))的红包" } ?? "红包")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear(perform: load)
    }

    private func name(_ id: String) -> String { chat.map { GroupPay.nameIn($0, id) } ?? "" }

    static func time(_ ms: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy/M/d HH:mm:ss"
        return f.string(from: Date(millis: ms))
    }

    private func load() {
        message = (try? Database.shared.get(Collections.messages, id: messageId)).flatMap { $0 }.map(Message.init(row:))
        chat = message.flatMap { (try? Repo.chat($0.chatId)) ?? nil }
    }

    private func open(_ m: Message) {
        do {
            guard let notice = try RedPacket.claim(m.id, who: GroupChat.me) else {
                problem = RedPacket.whyNot(m, who: GroupChat.me).isEmpty ? "没有领到" : RedPacket.whyNot(m, who: GroupChat.me)
                return
            }
            _ = try Repo.append(notice)
            try GroupPay.touch(m.chatId)
            problem = nil
            load()
        } catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

/// 群里转账：选收款人、金额、留言（网页版 4.736）
struct GroupTransferView: View {
    let chatId: String
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var chat: Chat?
    @State private var members: [Character] = []
    @State private var problem: String?

    private var value: Double? {
        guard let v = Double(amount.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return Interact.round(v)
    }

    var body: some View {
        Form {
            Section {
                Picker("转给", selection: $to) {
                    Text("选择成员").tag("")
                    ForEach(members) { c in Text(chat.map { GroupPay.nameIn($0, c.id) } ?? c.name).tag(c.id) }
                }
                HStack {
                    Text("金额")
                    TextField(Interact.format(0), text: $amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                TextField("留言（可不填）", text: $note)
            } footer: {
                HelpNote("群里的成员都看得到这一笔，只有收款人可以收下或退回。不调用接口。", title: "群里转账")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("转账")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("转账", action: submit).disabled(to.isEmpty || value == nil) }
        }
        .onAppear {
            chat = (try? Repo.chat(chatId)) ?? nil
            members = chat.map { GroupChat.members($0) } ?? []
        }
    }

    private func submit() {
        guard let v = value else { return }
        do {
            _ = try GroupPay.sendTransfer(chatId: chatId, to: to, amount: v, note: note)
            dismiss()
        } catch { problem = "转账未能发出：\(error.localizedDescription)" }
    }
}

// MARK: - 图片版本

/// 一张图的几版并排比较，挑一版显示（网页版 ImageVersionsPage，4.861）。再生成几版由用户自己填，每版一次生图接口
struct ImageVersionsView: View {
    let messageId: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settingsModel = SettingsModel.shared
    @State private var message: Message?
    @State private var count: Double = 1
    @State private var running = 0
    @State private var problem: String?
    @State private var viewing: String?

    private struct Viewing: Identifiable { let id: String }

    var body: some View {
        Form {
            if let m = message {
                Section {
                    Text(m.row.string("prompt")).font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(6)
                } header: { Text("图片描述") }
                Section {
                    NumberRow(title: "一次生成", value: $count, unit: "版", placeholder: "1", range: 1...Double(Int32.max))
                    Button(running > 0 ? "正在生成 \(running) 版" : "生成") { generate() }
                        .disabled(running > 0 || !settingsModel.s.imageReady)
                    if !settingsModel.s.imageReady { Text("尚未配置生图接口。").font(.footnote).foregroundStyle(Theme.secondaryText) }
                } footer: {
                    Text("每生成一版调用一次生图接口。")
                }
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.gap), GridItem(.flexible(), spacing: Theme.gap)], spacing: Theme.gap) {
                        ForEach(ImageVersions.of(m), id: \.self) { vid in
                            VStack(spacing: 6) {
                                LocalImage(id: vid, maxPixel: 600, fit: true)
                                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                                    .contentShape(Rectangle())
                                    .onTapGesture { viewing = vid }
                                if vid == m.imageId {
                                    Text("正在显示").font(.caption).foregroundStyle(Theme.secondaryText)
                                } else {
                                    HStack {
                                        Button("使用此版") { pick(vid) }
                                        Button("删除", role: .destructive) { remove(vid) }
                                    }
                                    .font(.caption).buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                } header: {
                    Text("共 \(ImageVersions.of(m).count) 版")
                } footer: {
                    HelpNote("各版按生成先后排列。「使用此版」换掉对话里显示的那一张；正在显示的那一版不能删除。重画图片时原来的那一张保留在这里。", title: "图片版本")
                }
            } else {
                Section { Text("该消息已不存在").foregroundStyle(Theme.secondaryText) }
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("图片版本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .fullScreenCover(item: Binding(get: { viewing.map { Viewing(id: $0) } }, set: { viewing = $0?.id })) { v in
            ImageViewer(imageId: v.id)
        }
        .onAppear(perform: load)
    }

    private func load() {
        message = (try? Database.shared.get(Collections.messages, id: messageId)).flatMap { $0 }.map(Message.init(row:))
    }

    private func generate() {
        let n = max(1, Int(count.rounded()))
        running += n
        problem = nil
        let id = messageId
        for _ in 0..<n {
            Task {
                do { _ = try await ImageVersions.add(id) }
                catch { await MainActor.run { problem = "有一版未能生成：\(error.localizedDescription)" } }
                await MainActor.run {
                    running -= 1
                    load()
                }
            }
        }
    }

    private func pick(_ vid: String) {
        do { _ = try ImageVersions.pick(messageId, vid); load() } catch { problem = "未能保存：\(error.localizedDescription)" }
    }

    private func remove(_ vid: String) {
        do { _ = try ImageVersions.remove(messageId, vid); load() } catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

// MARK: - 每个角色的聊天接口

/// 会话菜单「回复用的接口」（4.828）：这个角色亲自开口的聊天回复与通话用哪一套
struct CharApiPage: View {
    let charId: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var pick = ""
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Picker("回复用的接口", selection: $pick) {
                    Text("跟随主用").tag("")
                    ForEach(model.s.chatPresets) { p in
                        Text((p.name.isEmpty ? "未命名接口" : p.name) + (p.usable ? "" : "（未填全）")).tag(p.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("回复用的接口")
            } footer: {
                Text(CharApi.label((try? Repo.character(charId)) ?? nil, model.s))
                HelpNote("这个角色的聊天回复与通话用这一套接口；主动发消息、总结记忆、心声单独生成等其余任务仍按「设置 - 接口」与「任务用哪套接口」的分配。群聊照旧使用主用。所选接口被删除或没有填全时改用主用。打开「失败后换一套再试」时，从这一套之后按主用、副用、其余的顺序换。", title: "回复用的接口")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("回复用的接口")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            pick = ((try? Repo.character(charId)) ?? nil)?.row.string("chatApiId") ?? ""
            loaded = true
        }
        .onChange(of: pick) { _, v in
            guard loaded else { return }
            do { try CharApi.set(charId, v); problem = nil } catch { problem = "保存失败：\(error.localizedDescription)" }
        }
    }
}

// MARK: - 群资料里的几项

/// 我在本群的身份（4.1018）：成员、旁观、画外音
struct GroupModeSection: View {
    let chatId: String
    @State private var mode = "member"
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Section {
            Picker("我在本群的身份", selection: $mode) {
                ForEach(GroupMore.modes, id: \.self) { Text(GroupMore.modeLabel[$0] ?? $0).tag($0) }
            }
            .pickerStyle(.segmented)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("我在本群的身份")
        } footer: {
            HelpNote("成员：照常发言，成员回复你的消息。旁观：你不在群里，只能查看，成员之间照常交谈；底栏可以手动让群里接着聊一轮。画外音：你不在群里，可以发送画外音，成员在群里看不到画外音，回复时会参考它。", title: "我在本群的身份")
        }
        .onAppear {
            mode = GroupMore.mode((try? Repo.chat(chatId)) ?? nil)
            loaded = true
        }
        .onChange(of: mode) { _, v in
            guard loaded else { return }
            do { try GroupMore.setMode(chatId, v); problem = nil } catch { problem = "保存失败：\(error.localizedDescription)" }
        }
    }
}

/// 本群页面打开时接着聊（4.1018，默认关）
struct GroupAmbientSection: View {
    let chatId: String
    @State private var cfg = GroupMore.Ambient()
    @State private var minutes: Double = 3
    @State private var rounds: Double = 10
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("本群页面打开时接着聊", isOn: $cfg.page)
            if cfg.page {
                NumberRow(title: "间隔", value: $minutes, unit: "分钟", placeholder: "3", range: 1...100000)
                NumberRow(title: "每次打开最多", value: $rounds, unit: "轮", placeholder: "0", range: 0...100000)
                let last = GroupAmbient.lastOf(chatId)
                if last.tryAt > 0 {
                    Text("上一轮：\(RedPacketDetailView.time(last.tryAt))，\(last.err.isEmpty ? (last.silent ? "无人发言" : "已进行") : "未能进行：\(last.err)")")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("本群页面打开时接着聊")
        } footer: {
            Text("每进行一轮调用一次接口。每次打开最多填 0 表示不限。")
            HelpNote("开启后，本群页面打开且在前台时，距最后一条消息与打开页面均满设定的间隔，成员接着交谈一轮，不必等你开口；没有人开口时不落消息。输入框里有字、正在生成时不进行。失败后等满一个间隔再试，不立即重试。离开页面即停止。达到每次打开的轮数后本次不再自动进行，重新打开页面后重新计数。关闭后只在你发言或「主动开口」时回复。", title: "本群页面打开时接着聊")
        }
        .onAppear {
            cfg = GroupMore.ambient((try? Repo.chat(chatId)) ?? nil)
            minutes = Double(cfg.pageMin)
            rounds = Double(cfg.perOpen)
            loaded = true
        }
        .onChange(of: cfg) { _, _ in save() }
        .onChange(of: minutes) { _, v in cfg.pageMin = max(1, Int(v.rounded())) }
        .onChange(of: rounds) { _, v in cfg.perOpen = max(0, Int(v.rounded())) }
    }

    private func save() {
        guard loaded else { return }
        do { try GroupMore.setAmbient(chatId, cfg); problem = nil } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}

/// 角色可以自行退群（4.733，默认关）
struct GroupLeaveSection: View {
    let chatId: String
    @State private var on = false
    @State private var loaded = false
    @State private var featOn = true
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("角色可以自行退群", isOn: $on)
            if on && !featOn {
                Text("这是新功能，群里尚无成员开启（在「设定集 - 能力开关」的「新功能」中开启），此处开启暂不生效。")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        } footer: {
            HelpNote("开启后，成员可以按对话自己退出这个群，群里落一行退出的提示，可以再把该成员拉回群里。退出后群里至少保留两名角色。不另外调用接口。", title: "角色可以自行退群")
        }
        .onAppear {
            let chat = (try? Repo.chat(chatId)) ?? nil
            on = chat.map(GroupMore.leaveOn) ?? false
            featOn = NewFeat.anyOn("groupleave", .load(), chars: chat.map { GroupChat.members($0) } ?? [])
            loaded = true
        }
        .onChange(of: on) { _, v in
            guard loaded else { return }
            do { try GroupMore.setLeaveOn(chatId, v); problem = nil } catch { problem = "保存失败：\(error.localizedDescription)" }
        }
    }
}

/// 旁观时的底栏（4.1018）：接着聊一轮（手动，一次调用）、加入群聊
struct GroupWatchBar: View {
    let chatId: String
    let busy: Bool
    let onContinue: () -> Void
    let onJoin: () -> Void
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: Theme.pad) {
                Text("旁观中").font(.system(size: 14)).foregroundStyle(Theme.text2)
                Spacer()
                Button(busy ? "正在生成" : "接着聊一轮", action: onContinue).disabled(busy)
                Button("加入群聊") {
                    do { try GroupMore.setMode(chatId, "member"); onJoin() } catch { problem = "保存失败：\(error.localizedDescription)" }
                }
            }
            .font(.system(size: 14))
            Text("接着聊一轮调用一次接口。").font(.caption).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
        }
        .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp3)
        .background(Theme.surface2)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
    }
}
