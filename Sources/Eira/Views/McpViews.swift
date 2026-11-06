import SwiftUI

// MCP（网页版 apps/preset/mcp 与 chat/pages/ToolBits.js，ARCHITECTURE 4.179、4.180、4.973）。
// 设定集里一页：服务器（添加、连接、令牌与请求头、超时、调用前确认、逐个工具的开关与试用）与调用记录（等待允许的排最前）。
// 哪个角色能用哪几台在「角色能力」里勾（第 5 条）。会话里一次调用一张卡片：要确认的在卡片上允许或拒绝。

struct McpHomeView: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var tab = 0
    @State private var problem: String?
    @State private var adding: String?

    var body: some View {
        List {
            Section {
                Picker("", selection: $tab) {
                    Text("服务器").tag(0)
                    Text("调用记录").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if tab == 0 { serversList } else { McpCallsList() }
            ProblemSection(text: problem)
        }
        .navigationTitle("MCP 工具")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if tab == 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button { add() } label: { Image(systemName: "plus") }.accessibilityLabel("添加服务器")
                }
            }
        }
        .navigationDestination(item: Binding(get: { adding.map { McpRef(id: $0) } }, set: { adding = $0?.id })) { ref in
            McpServerEditView(serverId: ref.id)
        }
        .onAppear { model.reload() }
    }

    @ViewBuilder private var serversList: some View {
        let list = McpTools.servers(model.s)
        Section {
            if list.isEmpty {
                VStack(alignment: .leading, spacing: Theme.sp2) {
                    Text("还没有添加服务器").foregroundStyle(Theme.text2)
                    Button("添加服务器", action: add)
                }
            }
            ForEach(list) { sv in
                NavigationLink { McpServerEditView(serverId: sv.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sv.label)
                        Text(sv.error.isEmpty ? (sv.tools.isEmpty ? (sv.url.isEmpty ? "未填写地址" : "未连接") : "\(sv.tools.count) 个工具") : "连接失败")
                            .font(.caption).foregroundStyle(sv.error.isEmpty ? Theme.text3 : Theme.dangerText)
                    }
                }
            }
        } footer: {
            HelpNote("只支持 HTTP 的 MCP 服务器（Streamable HTTP 与旧版 SSE），不支持需要在本机运行的 stdio 服务器。工具清单在点「连接」时取回并保存，之后拼提示词时直接读。哪个角色能用哪几台，在会话菜单「角色能力」中勾选。调用工具本身不调用模型接口；工具结果回来后是否让角色接着回复，在「设置 - 用量与上限」中设置，默认关闭。", title: "MCP 服务器")
        }
    }

    private func add() {
        do { adding = try McpTools.add(); problem = nil } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}

private struct McpRef: Identifiable, Hashable { let id: String }

/// 一台服务器：地址、令牌、请求头、超时、调用前确认、连接、工具
struct McpServerEditView: View {
    let serverId: String
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var authName = ""
    @State private var authValue = ""
    @State private var headers = ""
    @State private var timeout: Double = 60
    @State private var approve = "ask"
    @State private var loaded = false
    @State private var busy = false
    @State private var problem: String?
    @State private var note: String?
    @State private var confirmDelete = false

    private var server: McpServer? { McpTools.server(serverId, model.s) }

    var body: some View {
        Form {
            if let sv = server {
                Section {
                    TextField("名称", text: $name).onSubmit(save)
                    TextField("地址，例如 https://example.com/mcp", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit(readConfig)
                    HelpNote("填写服务器的 HTTP 地址。也可以把别处复制来的整段 JSON 配置（含 mcpServers 或 url 与 headers）粘贴在这一栏，读出地址与请求头。", title: "MCP：地址")
                } header: { Text("服务器") }
                Section {
                    SecureField("令牌", text: $authValue)
                    TextField("令牌的请求头名称（留空为 Authorization）", text: $authName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("其他请求头，一行一个，例如 X-Api-Key: xxx", text: $headers, axis: .vertical)
                        .lineLimit(2...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HelpNote("令牌写在请求头 Authorization 中，没写 Bearer 之类的方案时自动补上 Bearer；整行粘贴「Authorization: Bearer xxx」同样可以。其他请求头认「名称: 值」、带引号与逗号的行、「名称=值」与 JSON。与令牌同名时以令牌一栏为准。令牌与请求头和接口密钥一样，只在连同密钥备份时进入备份。", title: "MCP：令牌与请求头")
                } header: { Text("鉴权") }
                Section {
                    NumberRow(title: "超时", value: $timeout, unit: "秒", placeholder: "60")
                    Picker("调用前确认", selection: $approve) {
                        Text("每次确认").tag("ask")
                        Text("只读工具免确认").tag("read")
                        Text("直接调用").tag("auto")
                    }
                    HelpNote("每次确认：角色每调用一次，聊天里的卡片停在「等待允许」，由你允许或拒绝。只读工具免确认：服务器标为只读的工具直接调用，其余仍要确认。直接调用：一律不问。工具可能有副作用（发消息、写文件），调用之后无法撤回。", title: "MCP：调用前确认")
                }
                Section {
                    Button(busy ? "正在连接" : "保存并连接") { save(); connect() }.disabled(busy || url.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !sv.error.isEmpty {
                        Text("上一次连接失败：\(sv.error)").font(.footnote).foregroundStyle(Theme.dangerText)
                    } else if sv.checkedAt > 0 {
                        Text("上一次连接：\(TimeText.format(Date(millis: sv.checkedAt)))，\(sv.tools.count) 个工具").font(.footnote).foregroundStyle(Theme.text3)
                    }
                    if let note { Text(note).font(.footnote).foregroundStyle(Theme.text2) }
                }
                if !sv.tools.isEmpty {
                    Section {
                        ForEach(sv.tools, id: \.name) { t in
                            Toggle(isOn: Binding(get: { !sv.toolsOff.contains(t.name) }, set: { on in setTool(t.name, on) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title.isEmpty ? t.name : t.title)
                                    if !t.description.isEmpty {
                                        Text(t.description).font(.caption).foregroundStyle(Theme.text3).lineLimit(2)
                                    }
                                }
                            }
                        }
                    } header: { Text("工具") } footer: {
                        HelpNote("关掉的工具不告诉角色。", title: "MCP：工具")
                    }
                    Section {
                        ForEach(sv.tools, id: \.name) { t in
                            NavigationLink(t.title.isEmpty ? t.name : t.title) { McpToolTryView(serverId: serverId, tool: t) }
                        }
                    } header: { Text("试用") } footer: {
                        HelpNote("直接调用一次看结果，不经过角色、不落消息。", title: "MCP：试用")
                    }
                }
                Section {
                    Button("删除这台服务器", role: .destructive) { confirmDelete = true }
                }
            } else {
                Text("这台服务器已删除。").foregroundStyle(Theme.text2)
            }
            ProblemSection(text: problem)
        }
        .navigationTitle(name.isEmpty ? "服务器" : name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear(perform: save)
        .confirmationDialog("删除这台服务器", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try McpTools.remove(serverId); dismiss() } catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        } message: { Text("角色卡上勾选的这台服务器一并失效。已有的调用记录保留。") }
    }

    private func load() {
        guard !loaded, let sv = server else { return }
        loaded = true
        name = sv.name; url = sv.url; authName = sv.authName; authValue = sv.authValue; headers = sv.headers
        timeout = sv.timeout; approve = sv.approve
    }

    /// 地址栏里粘贴的是整段 JSON 配置：读出地址与请求头，名称还是默认的「服务器 N」时一并改名
    private func readConfig() {
        guard let c = Mcp.parseConfig(url) else { return }
        url = c.url
        if !c.headers.isEmpty { headers = c.headers }
        if !c.name.isEmpty && (name.isEmpty || name.range(of: #"^服务器 \d+$"#, options: .regularExpression) != nil) { name = c.name }
        save()
    }

    private func save() {
        guard loaded, server != nil else { return }
        if url.trimmingCharacters(in: .whitespaces).hasPrefix("{") { readConfig(); return }
        do {
            try McpTools.update(serverId, [
                "name": .string(name.trimmingCharacters(in: .whitespaces)), "url": .string(url.trimmingCharacters(in: .whitespaces)),
                "authName": .string(authName.trimmingCharacters(in: .whitespaces)), "authValue": .string(authValue),
                "headers": .string(headers), "timeout": .number(max(1, timeout)), "approve": .string(approve),
            ])
            problem = nil
        } catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func setTool(_ name: String, _ on: Bool) {
        guard let sv = server else { return }
        var off = sv.toolsOff.filter { $0 != name }
        if !on { off.append(name) }
        do { try McpTools.update(serverId, ["toolsOff": .array(off.map { .string($0) })]) }
        catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func connect() {
        busy = true; note = nil
        Task {
            do {
                let r = try await McpTools.refresh(serverId)
                let who = r.info["name"]?.string ?? ""
                note = "已连接\(who.isEmpty ? "" : "：\(who)")，取回 \(r.tools.count) 个工具"
                problem = nil
            } catch {
                problem = "连接失败：\(error.localizedDescription)"
            }
            busy = false
            model.reload()
        }
    }
}

/// 试用一个工具：按参数 schema 先填一个样子，直接调一次看结果（不经过角色、不落消息）
struct McpToolTryView: View {
    let serverId: String
    let tool: McpTool
    @State private var args = ""
    @State private var result = ""
    @State private var isError = false
    @State private var busy = false

    var body: some View {
        Form {
            if !tool.description.isEmpty { Section { Text(tool.description).font(.footnote).foregroundStyle(Theme.text2) } }
            Section {
                TextField("{}", text: $args, axis: .vertical).lineLimit(4...14).font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("参数（JSON 对象）") }
            Section {
                Button(busy ? "正在调用" : "调用一次", action: run).disabled(busy)
                if !result.isEmpty {
                    Text(result).font(.system(.footnote, design: .monospaced)).foregroundStyle(isError ? Theme.dangerText : Theme.text)
                        .textSelection(.enabled)
                }
            } footer: {
                HelpNote("直接调用这台服务器上的这个工具，不经过角色、不落消息，也不调用模型接口。工具可能有副作用。", title: "MCP：试用工具")
            }
        }
        .navigationTitle(tool.title.isEmpty ? tool.name : tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if args.isEmpty { args = McpTools.sampleArgs(tool.inputSchema) } }
    }

    private func run() {
        guard let v = try? JSONValue.parse(Data(args.utf8)), v.object != nil else {
            result = "参数不是一个合法的 JSON 对象"; isError = true; return
        }
        busy = true
        Task {
            do {
                let r = try await McpTools.tryTool(serverId, name: tool.name, args: v)
                result = (r.text.isEmpty ? "工具没有返回内容" : r.text) + "\n（\(r.ms) 毫秒）"
                isError = r.isError
            } catch {
                result = "调用失败：\(error.localizedDescription)"; isError = true
            }
            busy = false
        }
    }
}

/// 调用记录：所有会话里的工具调用，等待允许的排最前。人在别处时角色发起、停在等待允许的那一次在这里找得到
private struct McpCallsList: View {
    @State private var list: [Message] = []
    @State private var names: [String: String] = [:]

    var body: some View {
        Section {
            if list.isEmpty { Text("还没有调用记录").foregroundStyle(Theme.text2) }
            ForEach(list, id: \.id) { m in
                VStack(alignment: .leading, spacing: Theme.sp2) {
                    HStack {
                        Text(m.row.string("toolTitle").isEmpty ? m.row.string("toolName") : m.row.string("toolTitle"))
                        Spacer()
                        Text(McpTools.stateText[m.row.string("toolState")] ?? "").font(.caption).foregroundStyle(Theme.text3)
                    }
                    Text("\(names[m.chatId] ?? "会话") · \(TimeText.format(Date(millis: m.createdAt)))").font(.caption).foregroundStyle(Theme.text3)
                    ToolBubble(message: m)
                }
            }
        } footer: {
            HelpNote("所有会话里角色发起的工具调用，等待允许的排在最前，可以在这里直接允许或拒绝。", title: "MCP：调用记录")
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .eiraChatChanged)) { _ in load() }
    }

    private func load() {
        list = McpTools.calls()
        var n: [String: String] = [:]
        for c in (try? Repo.chats()) ?? [] {
            let first = c.characterIds.first.flatMap { (try? Repo.character($0)) ?? nil }
            n[c.id] = c.isGroup ? GroupChat.title(c, members: GroupChat.members(c)) : (first?.displayName ?? "会话")
        }
        names = n
    }
}

/// 会话里一次工具调用的卡片：调了什么、参数、走到哪一步；要确认的在这里允许或拒绝，结果回来了显示前几行，点开看全文
struct ToolBubble: View {
    let message: Message
    @State private var open = false
    @State private var tick = 0

    private var state: String { message.row.string("toolState") }

    private static func argsLine(_ args: [String: JSONValue]) -> String {
        guard !args.isEmpty else { return "无参数" }
        return args.keys.sorted().map { k -> String in
            let v = args[k] ?? .null
            if let s = v.string { return "\(k): \(s)" }
            let d = (try? v.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return "\(k): \(d)"
        }.joined(separator: "，")
    }

    var body: some View {
        let server = McpTools.server(message.row.string("toolServerId"))
        // 状态是 running 却不在跑：应用重开时正在调的那一次。不自动重调（工具可能有副作用）
        let lost = state == "running" && !McpTools.isRunning(message.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.system(size: 12))
                Text(message.row.string("toolTitle").isEmpty ? message.row.string("toolName") : message.row.string("toolTitle"))
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let server { Text(server.label).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1) }
            }
            Text(Self.argsLine(message.row["toolArgs"]?.object ?? [:])).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
            Group {
                if state == "ask" {
                    Text("等待你允许后执行").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    HStack {
                        Button("拒绝") { McpTools.deny(message.id) }.buttonStyle(.bordered)
                        Button("允许") { McpTools.approve(message.id); tick += 1 }.buttonStyle(.borderedProminent)
                    }
                    .font(.system(size: 13))
                } else if lost {
                    Text("调用在应用重新打开时中断，结果未知").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    Button("重试") { McpTools.launch(message.id); tick += 1 }.font(.system(size: 13)).buttonStyle(.bordered)
                } else if state == "running" {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在调用").font(.system(size: 12)) }
                } else if state == "denied" {
                    Text("已拒绝").font(.system(size: 12)).foregroundStyle(Theme.text3)
                } else if state == "error" {
                    Text("调用失败：\(message.row.string("toolError").isEmpty ? "未知原因" : message.row.string("toolError"))")
                        .font(.system(size: 12)).foregroundStyle(Theme.dangerText).lineLimit(4)
                    if server != nil {
                        Button("重试") { McpTools.launch(message.id); tick += 1 }.font(.system(size: 13)).buttonStyle(.bordered)
                    }
                } else {
                    let r = message.row.string("toolResult")
                    Text(r.isEmpty ? "工具没有返回内容" : r).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(4)
                }
            }
        }
        .frame(minWidth: 180, maxWidth: 260, alignment: .leading)
        .padding(Theme.pad)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open = true }
        .sheet(isPresented: $open) {
            NavigationStack {
                Form {
                    Section("服务器") { Text(server.map { "\($0.label)（\($0.url)）" } ?? "已删除") }
                    Section("工具") { Text(message.row.string("toolName")) }
                    Section("参数") {
                        Text((try? JSONSerialization.data(withJSONObject: (message.row["toolArgs"] ?? .object([:])).any, options: [.prettyPrinted, .sortedKeys]))
                            .map { String(decoding: $0, as: UTF8.self) } ?? "{}")
                            .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                    if !message.row.string("toolResult").isEmpty {
                        Section("结果") { Text(message.row.string("toolResult")).font(.footnote).textSelection(.enabled) }
                    }
                    if !message.row.string("toolError").isEmpty && message.row.string("toolError") != message.row.string("toolResult") {
                        Section("错误") { Text(message.row.string("toolError")).font(.footnote).textSelection(.enabled) }
                    }
                }
                .navigationTitle(message.row.string("toolTitle").isEmpty ? message.row.string("toolName") : message.row.string("toolTitle"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { open = false } } }
            }
        }
    }
}

/// 「角色能力」里这个角色能用哪几台服务器（char.mcpServers，第 5 条）
struct McpCharSection: View {
    let charId: String
    @ObservedObject private var model = SettingsModel.shared
    @State private var ids: [String] = []
    @State private var problem: String?

    var body: some View {
        let list = McpTools.servers(model.s)
        Section {
            if list.isEmpty {
                NavigationLink { McpHomeView() } label: { LabeledContent("MCP 工具", value: "未添加服务器") }
            }
            ForEach(list) { sv in
                Toggle(isOn: Binding(get: { ids.contains(sv.id) }, set: { on in set(sv.id, on) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sv.label)
                        Text(sv.tools.isEmpty ? "未连接" : "\(sv.tools.count) 个工具").font(.caption).foregroundStyle(Theme.text3)
                    }
                }
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.dangerText) }
        } header: { Text("可以调用的 MCP 工具") } footer: {
            HelpNote("勾选的服务器上的工具写进提示词，角色可以按对话自己调用。调用前是否需要你确认，在「设定集 - MCP 工具」各台服务器中设置。群聊不提供这一项。", title: "角色能力：MCP 工具")
        }
        .onAppear { ids = ((try? Repo.character(charId)) ?? nil)?.row.strings("mcpServers") ?? [] }
    }

    private func set(_ id: String, _ on: Bool) {
        var next = ids.filter { $0 != id }
        if on { next.append(id) }
        do {
            guard var c = try Repo.character(charId) else { return }
            c.row["mcpServers"] = .array(next.map { .string($0) })
            c.row.touch()
            try Database.shared.put(Collections.characters, c.row)
            ids = next
            problem = nil
        } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
