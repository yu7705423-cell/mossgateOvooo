import SwiftUI

/// 场外（网页版 chat/pages/OocBits.js，ARCHITECTURE 4.819）的界面：这段会话的「场外」页、场外问答的那一块、
/// 每轮回复下面那一行检查结果、存为世界书的确认页。数据与规则在 Prompt/Ooc.swift
struct OocPageView: View {
    let chatId: String
    @State private var chat: Chat?
    @State private var trigger = ""
    @State private var review = ""
    @State private var checkRule = ""
    @State private var problem: String?

    var body: some View {
        Form {
            if let c = chat {
                let x = Ooc.cfg(c)
                Section {
                    Toggle("场外问答", isOn: bind("on", x.on))
                    HelpNote("开启后，输入栏上方出现「场外」，或以触发词开头发送，即向模型本身提问：对照角色卡与世界书指出偏离之处，写出一条纠偏条目与修正后的片段。问答单独显示，不计入记忆。每次提问调用一次聊天接口。", title: "场外问答")
                    if x.on {
                        TextField("触发词", text: $trigger)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { save(["trigger": .string(trigger)]) }
                        HelpNote("消息以该词开头时按场外发送，不区分大小写，后面跟空格或冒号。留空则只能从输入栏上方的「场外」发送。", title: "场外：触发词")
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("角色可见", isOn: bind("visible", x.visible))
                            if x.visible { Text("场外问答随上下文发送，每轮多占一些字数。").font(.footnote).foregroundStyle(Theme.text2) }
                        }
                        HelpNote("开启后，场外的问与答以 [场外：…] 与 [场外回复：…] 的形式留在之后每一轮的上下文中；关闭时角色读不到场外的内容。", title: "场外：角色可见")
                    }
                } header: { Text("场外问答") }
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("自动检查", isOn: bind("check", x.check))
                        if x.check { Text("每轮回复之后多调用一次接口。").font(.footnote).foregroundStyle(Theme.text2) }
                    }
                    HelpNote("开启后，每轮回复之后另外调用一次接口，对照角色卡与这一轮触发的世界书检查这一轮是否与设定明确冲突，结果显示在这一轮下方。使用的接口在「设置 - 接口 - 任务用哪套接口」中指定。同一轮只自动检查一次，失败不重试。", title: "场外：自动检查")
                    if x.check {
                        VStack(alignment: .leading, spacing: 2) {
                            Picker("发现冲突时", selection: Binding(get: { x.checkMode }, set: { save(["checkMode": .string($0)]) })) {
                                Text("只标出").tag("mark")
                                Text("自动重写").tag("rewrite")
                            }
                            if x.checkMode == "rewrite" { Text("每次重写多调用一次回复与一次检查。").font(.footnote).foregroundStyle(Theme.text2) }
                        }
                        HelpNote("只标出：在这一轮下方列出冲突，可手动选择重写、存为世界书或忽略。自动重写：按检查结果重新生成这一轮，原回复保留在候选中，重写后的回复再检查一次。", title: "场外：发现冲突时")
                        if x.checkMode == "rewrite" {
                            Stepper("最多自动重写 \(x.rewriteMax) 次", value: Binding(get: { x.rewriteMax }, set: { save(["rewriteMax": .number(Double($0))]) }), in: 0...20)
                            HelpNote("达到次数后仍有冲突时只标出。填 0 则不自动重写。", title: "场外：最多自动重写几次")
                        }
                    }
                } header: { Text("自动检查") }
                Section {
                    Picker("提示词版本", selection: Binding(get: { x.style }, set: { save(["style": .string($0)]) })) {
                        ForEach(Ooc.styles, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    if x.style == "auto" {
                        let s = AppSettings.load()
                        let label: (String) -> String = { task in
                            let st = Ooc.styleOf(c, model: AIService.chain(task: task, group: RouteGroup.of(task: task), settings: s).first?.model ?? "")
                            return Ooc.styles.first { $0.value == st }?.label ?? st
                        }
                        Text("场外问答当前为 \(label("chat.ooc"))，自动检查当前为 \(label("ooc.check"))。").font(.footnote).foregroundStyle(Theme.text2)
                    }
                    HelpNote("Claude、GPT、Gemini、DeepSeek 四个版本分别按各厂商官方的提示词写法编写，输出格式一致。按模型自动选择时，按这一轮使用的模型名称选择对应厂商的版本，无法识别时使用 Claude 版。内置文字可在「设定集 - 预设 - 提示词模板」中查看。", title: "场外：提示词版本")
                } header: { Text("提示词") }
                if x.style == "custom" {
                    Section {
                        TextField("场外问答，留空则使用 Claude 版", text: $review, axis: .vertical).lineLimit(4...12)
                        HelpNote("接在这一轮上下文末尾发送。可使用 {{note}}（提问的内容）与 {{char}}；不写 {{note}} 时，提问的内容接在最后。", title: "场外：自定义场外问答")
                        TextField("自动检查，留空则使用 Claude 版", text: $checkRule, axis: .vertical).lineLimit(4...12)
                        HelpNote("作为系统提示词发送，角色卡、世界书、最近的对话与这一轮回复作为用户消息发送。回复须为 JSON：{\"ok\": true} 或 {\"ok\": false, \"issues\": [{\"card\": \"\", \"reply\": \"\", \"fix\": \"\"}]}。", title: "场外：自定义自动检查")
                        Button("保存两段提示词") { save(["customReview": .string(review), "customCheck": .string(checkRule)]) }
                    } header: { Text("自定义提示词") }
                }
                Section {
                    Picker("存入的世界书", selection: Binding(get: { x.bookId }, set: { save(["bookId": .string($0)]) })) {
                        let charId = c.characterIds.first ?? ""
                        let books = ((try? Repo.lorebooks()) ?? []).filter { $0.purpose == "chat" }
                        let own = books.first { $0.row.string("oocFor") == charId }
                        Text(own?.name ?? "角色的纠偏世界书（首次存入时创建）").tag("")
                        ForEach(books.filter { $0.row.string("oocFor") != charId }) { b in Text(b.name.isEmpty ? "未命名世界书" : b.name).tag(b.id) }
                    }
                    HelpNote("场外答复、检查结果与长按的消息「存为世界书」时存入这一本，存为常驻条目。默认存入该角色的纠偏世界书，首次存入时创建并挂到角色上。", title: "场外：存入的世界书")
                } header: { Text("世界书") }
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("场外")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear {
            // 触发词与自定义提示词离开时存一次（没改的不写）
            guard let c = chat else { return }
            let x = Ooc.cfg(c)
            var patch: [String: JSONValue] = [:]
            if trigger.trimmingCharacters(in: .whitespaces) != x.trigger { patch["trigger"] = .string(trigger) }
            if review != x.customReview { patch["customReview"] = .string(review) }
            if checkRule != x.customCheck { patch["customCheck"] = .string(checkRule) }
            if !patch.isEmpty { save(patch) }
        }
    }

    private func bind(_ key: String, _ v: Bool) -> Binding<Bool> {
        Binding(get: { v }, set: { save([key: .bool($0)]) })
    }

    private func load() {
        do {
            chat = try Repo.chat(chatId)
            let x = Ooc.cfg(chat)
            trigger = x.trigger
            review = x.customReview
            checkRule = x.customCheck
            problem = chat == nil ? "这段会话不存在" : nil
        } catch { problem = error.localizedDescription }
    }

    private func save(_ patch: [String: JSONValue]) {
        do { try Ooc.set(chatId, patch); chat = try Repo.chat(chatId); problem = nil }
        catch { problem = "未能保存：\(error.localizedDescription)" }
    }
}

/// 场外的问与答（kind ooc）：虚线框的一块，答复按 Markdown 画
struct OocBubble: View {
    let message: Message
    var onSave: () -> Void = {}
    var onDelete: () -> Void = {}

    var body: some View {
        let mine = message.role == .user
        VStack(alignment: .leading, spacing: Theme.sp1) {
            Text(mine ? "场外提问" : "场外答复").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
            if mine {
                Text(message.content).font(.system(size: 15)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            } else {
                MarkdownView(text: message.content)
            }
        }
        .padding(Theme.sp3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous).strokeBorder(Theme.text3, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .padding(.horizontal, Theme.sp4)
        .contextMenu {
            Button { UIPasteboard.general.string = message.content } label: { Label("复制", systemImage: "doc.on.doc") }
            // 存为世界书：场外的答复（网页版 4.819）
            if !mine { Button(action: onSave) { Label("存为世界书", systemImage: "book") } }
            Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
        }
    }
}

/// 一轮回复下面的检查结果（网页版 OocCheckLine）。没问题、还在检查时什么都不画
struct OocCheckLine: View {
    let head: Message
    let canRewrite: Bool
    var onRewrite: ([Ooc.Issue]) -> Void
    var onSave: (String) -> Void
    var onDismiss: () -> Void
    @State private var open = false

    var body: some View {
        let issues = Ooc.issues(of: head)
        Group {
            if head.row.string("oocCheck") == "failed" {
                Text("OOC 检查未完成：\(head.row.string("oocError").isEmpty ? "接口出错" : head.row.string("oocError"))")
                    .font(.system(size: 12)).foregroundStyle(Theme.dangerText)
            } else if !issues.isEmpty {
                VStack(alignment: .leading, spacing: Theme.sp2) {
                    Button { open.toggle() } label: {
                        Text("OOC 检查：发现 \(issues.count) 处与角色卡冲突\(open ? "" : "，点按查看")").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                    .buttonStyle(.plain)
                    if open {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, it in
                            VStack(alignment: .leading, spacing: 2) {
                                if !it.card.isEmpty { pair("角色卡", it.card) }
                                if !it.reply.isEmpty { pair("回复", it.reply) }
                                if !it.fix.isEmpty { pair("修正", it.fix) }
                            }
                            .padding(Theme.sp2)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        HStack(spacing: Theme.sp3) {
                            if canRewrite { Button("按检查结果重写") { onRewrite(issues) } }
                            Button("存为世界书") { onSave(Ooc.issuesText(issues)) }
                            Button("忽略") { onDismiss() }
                        }
                        .font(.system(size: 13))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.sp4).padding(.top, Theme.sp1)
    }

    private func pair(_ k: String, _ v: String) -> some View {
        (Text(k + "  ").foregroundColor(Theme.text3) + Text(v).foregroundColor(Theme.text))
            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
}

/// 存为世界书（网页版 saveToLore）：先给看一眼、能改，再存成一条常驻条目
struct OocSaveSheet: View {
    let chatId: String
    let initial: String
    /// 元模式（4.832）的存法：存进这个元自己的那一本
    var meta = false
    var done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("内容", text: $text, axis: .vertical).lineLimit(6...20)
                } footer: {
                    Text(meta ? "存为一条常驻条目，存入《\(Meta.ownBook(chatId)?.name ?? "\(Meta.nameOf((try? Repo.chat(chatId)) ?? nil)) · 世界书")》，并挂到这个元上。"
                              : "存为一条常驻条目，存入《\(Ooc.targetName(chatId))》。存入的世界书在「场外」页中选择。")
                }
                ProblemSection(text: problem)
            }
            .navigationTitle("存为世界书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存入") {
                        do {
                            let name = meta ? try Meta.saveToBook(chatId, text: text) : try Ooc.save(chatId, text: text)
                            done("已存入《\(name)》，之后每一轮常驻生效。")
                            dismiss()
                        } catch { problem = "未能存入世界书：\(error.localizedDescription)" }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { text = initial.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}
