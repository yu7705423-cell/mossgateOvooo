import SwiftUI
import UIKit

/// 一份美化的详情（网页版 apps/skin/App.js 的 OnePage）：预览、编辑器、原生主题的格子、尺寸、自定义 CSS、复制 CSS、
/// 使用情况与挂到一段会话、生效范围与全部会话的默认、复制一份、导出、删除。会话菜单「主题」里点「修改」进来的也是这一页。
/// 内置的几套不能改：只能挂上、设为默认、复制一份后修改。
struct SkinOneView: View {
    let id: String
    @State private var tick = 0
    @State private var problem: String?
    @State private var notice: String?
    @State private var renaming = false
    @State private var newName = ""
    @State private var deleting = false
    @State private var attaching = false
    @State private var exporting = false
    @State private var exportNotes: [String] = []
    @State private var confirmExport = false
    @State private var copied: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var env

    private var row: Row? { _ = tick; return ChatTheme.row(id) }
    private var builtin: Bool { ChatTheme.isBuiltin(id) }
    private var settings: AppSettings { _ = tick; return AppSettings.load() }

    var body: some View {
        Group {
            if let r = row {
                content(r)
            } else {
                EmptyState(title: "该美化已删除")
            }
        }
        .navigationTitle(row.map(ThemeGalleryView.name) ?? "美化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !builtin, row != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("改名") { newName = row.map(ThemeGalleryView.name) ?? ""; renaming = true }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraSkinChanged)) { _ in tick += 1 }
        .alert("改名", isPresented: $renaming) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                run { try Skins.update(id) { $0["name"] = .string(n.isEmpty ? "未命名" : n) } }
            }
        }
        .confirmationDialog("删除这一份", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Skins.remove(id); dismiss() } catch { problem = "未能删除：\(error.localizedDescription)" }
            }
        } message: {
            let n = Skins.usedBy(id)
            Text(n > 0 ? "挂着它的 \(n) 段会话会一并取下，那几段会话恢复为默认样式。删除后无法恢复。" : "删除后无法恢复。")
        }
        .alert("导出美化包", isPresented: $confirmExport) {
            Button("取消", role: .cancel) {}
            Button("继续导出") { exporting = true }
        } message: {
            Text(exportNotes.joined() + "美化包仅包含名称、尺寸、头像框与样式，不包含它挂在哪些会话上。")
        }
        .sheet(isPresented: $exporting) { if let r = row { NavigationStack { SkinExportSheet(row: r) } } }
        .sheet(isPresented: $attaching) { NavigationStack { attachPage } }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        }
        .navigationDestination(isPresented: Binding(get: { copied != nil }, set: { if !$0 { copied = nil } })) {
            if let copied { SkinOneView(id: copied) }
        }
    }

    @ViewBuilder private func content(_ r: Row) -> some View {
        let t = ChatTheme.resolve(row: r)
        let dark = t.scheme == "dark" ? true : t.scheme == "light" ? false : env == .dark
        Form {
            Section {
                ThemePreview(theme: t, dark: dark)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
                    .listRowInsets(EdgeInsets())
            } footer: {
                HelpNote("这是示例会话，与会话页走同一套样式。真实效果请在挂着它的会话中查看。", title: "美化：预览")
            }
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            if builtin { builtinSections(r) } else { styleSections(r) }
            usageSections(r)
            scopeSection(r)
            if !builtin {
                Section {
                    Button { duplicate(r) } label: { IconRow(title: "复制一份", icon: "copy") }
                    Button { startExport(r) } label: { IconRow(title: "导出美化包", icon: "download") }
                } footer: {
                    HelpNote("复制一份：在现有的基础上修改。导出：导出为 JSON、TXT 或 DOCX 文件，或复制为文字，可分享给他人导入；不包含它挂在哪些会话上。", title: "美化：复制与导出")
                }
                Section {
                    Button("删除这一份", role: .destructive) { deleting = true }
                }
            }
        }
    }

    @ViewBuilder private func builtinSections(_ r: Row) -> some View {
        Section {
            Button { duplicate(r) } label: { IconRow(title: "复制一份后修改", icon: "copy") }
        } footer: {
            Text("内置主题不能修改。")
        }
    }

    @ViewBuilder private func styleSections(_ r: Row) -> some View {
        let css = r.string("css").trimmingCharacters(in: .whitespacesAndNewlines)
        Section {
            NavigationLink { SkinEditorView(id: id) } label: {
                IconRow(title: "打开编辑器", icon: "edit", value: editorState(r))
            }
            NavigationLink { ThemeEditView(id: id) } label: { IconRow(title: "主题格子", icon: "palette") }
            NavigationLink { SkinEditView(id: id) } label: { IconRow(title: "尺寸", icon: "layers") }
            NavigationLink { SkinCssView(id: id) } label: {
                IconRow(title: "自定义 CSS", icon: "code", value: css.isEmpty ? "尚未填写" : "已写 \(css.components(separatedBy: "\n").count) 行")
            }
            Button { copyCss(r) } label: { IconRow(title: "复制 CSS", icon: "copy") }
            if Skins.compiled(r) != nil {
                NavigationLink { SkinCssReportView(id: id) } label: {
                    IconRow(title: "原生版的还原情况", icon: "book",
                            value: Skins.compiled(r).map { "未还原 \($0.report.skipped) 条" } ?? "")
                }
            }
        } header: { GroupTitle("样式") } footer: {
            HelpNote("编辑器：顶栏、气泡、头像、底栏等各块的设置，与网页版的编辑器读写同一份设置。主题格子：原生版自己的一组格子（配色、背景、气泡、上下栏），原生版中盖过网页版美化的同一项，网页版不读取。尺寸：消息间距、气泡圆角与内距、字号等。自定义 CSS 排在编辑器之后；之后再调编辑器或尺寸，调过的样式排到自定义 CSS 之后。复制 CSS：复制这一份最终生效的全部样式（尺寸、头像框、编辑器与自定义 CSS）。", title: "美化：样式")
        }
    }

    private func editorState(_ r: Row) -> String {
        guard SkinGen.shared.available else { return "仅原生的几项" }
        let n = SkinGen.shared.state(r["gen"])?.changed.values.filter { $0 > 0 }.count ?? 0
        return n > 0 ? "改过 \(n) 块" : "未改动"
    }

    @ViewBuilder private func usageSections(_ r: Row) -> some View {
        let chats = ((try? Repo.chats()) ?? []).filter { $0.row.string("skinId") == id }
        Section {
            if chats.isEmpty {
                Text("尚未用于任何会话").foregroundStyle(Theme.text3)
            }
            ForEach(chats, id: \.id) { c in
                LabeledContent(Forward.titleOf(c), value: c.characterIds.count > 1 ? "群聊" : "单聊")
            }
            Button { attaching = true } label: { IconRow(title: "挂到一段会话", icon: "edit") }
        } header: { GroupTitle(chats.isEmpty ? "使用情况" : "使用情况 · \(chats.count)") } footer: {
            HelpNote("挂上之后在那段会话里生效。会话右上角菜单的「主题」中可以换一份或取下。", title: "美化：挂到一段会话")
        }
    }

    private var attachPage: some View {
        let chats = ((try? Repo.chats()) ?? []).filter { !$0.characterIds.isEmpty }
            .sorted { ($0.row.number("lastMessageAt") ?? 0) > ($1.row.number("lastMessageAt") ?? 0) }
        return List {
            if chats.isEmpty { Text("还没有任何会话").foregroundStyle(Theme.text3) }
            ForEach(chats, id: \.id) { c in
                Button {
                    run { try Skins.attach(c.id, id) }
                    attaching = false
                    notice = "已挂到「\(Forward.titleOf(c))」。"
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Forward.titleOf(c)).foregroundStyle(Theme.text)
                        let cur = c.row.string("skinId")
                        if cur == id { Text("已经挂着这一份").font(.caption).foregroundStyle(Theme.text3) }
                        else if !cur.isEmpty { Text("当前挂着别的美化，将被替换").font(.caption).foregroundStyle(Theme.text3) }
                    }
                }
            }
        }
        .navigationTitle("挂载会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { attaching = false } } }
    }

    @ViewBuilder private func scopeSection(_ r: Row) -> some View {
        let scopes = ChatTheme.scopes(r)
        let isGlobal = (settings.raw["globalSkinId"]?.string ?? "") == id
        Section {
            if !builtin {
                Toggle("单段会话", isOn: Binding(get: { scopes.contains("chat") || scopes.isEmpty }, set: { toggleScope("chat", $0, r) }))
                Toggle("整个应用", isOn: Binding(get: { scopes.contains("shell") }, set: { toggleScope("shell", $0, r) }))
            }
            if builtin || scopes.contains("shell") {
                Toggle("设为全部会话的默认", isOn: Binding(get: { isGlobal }, set: { v in run { try ChatTheme.setGlobal(v ? id : "") } }))
            }
        } header: { GroupTitle("生效范围") } footer: {
            HelpNote("单段会话：挂在一段会话上，只在那段会话里生效。整个应用：可以设为全部会话的默认，没有单独挂主题的会话都使用它；网页版中还用于消息列表、联系人等页面，原生版这些页面不套美化。设置页永不套美化，总开关在「设置 - 主题」。至少保留一档。", title: "美化：生效范围")
        }
    }

    // MARK: - 动作

    private func toggleScope(_ sc: String, _ on: Bool, _ r: Row) {
        var list = ChatTheme.scopes(r)
        if list.isEmpty { list = ["chat"] }
        if on { if !list.contains(sc) { list.append(sc) } } else { list.removeAll { $0 == sc } }
        // 一档都不留等于它永远不生效，而界面上看不出来
        guard !list.isEmpty else { notice = "至少要保留一档生效范围。"; return }
        run {
            try Skins.update(id) { $0["scope"] = .array(list.map { JSONValue.string($0) }) }
            if !list.contains("shell"), (AppSettings.load().raw["globalSkinId"]?.string ?? "") == id { try ChatTheme.setGlobal("") }
        }
    }

    private func copyCss(_ r: Row) {
        let css = Skins.effectiveCss(r)
        guard !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { notice = "这一份还没有任何样式。"; return }
        UIPasteboard.general.string = css
        notice = "已复制 \(css.components(separatedBy: "\n").count) 行 CSS。"
    }

    private func duplicate(_ r: Row) {
        do {
            let base = "\(ThemeGalleryView.name(r)) 副本"
            let taken = Set(Skins.all().map { $0.string("name") })
            var name = base
            var i = 2
            while taken.contains(name) { name = "\(base) \(i)"; i += 1 }
            let made = try ChatTheme.create(name: name, from: r)
            problem = nil
            copied = made.id
        } catch { problem = "未能复制：\(error.localizedDescription)" }
    }

    private func startExport(_ r: Row) {
        exportNotes = SkinFile.exportNotes(r)
        if exportNotes.isEmpty { exporting = true } else { confirmExport = true }
    }

    private func run(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "无法保存美化：\(error.localizedDescription)" }
        tick += 1
    }
}

/// 导出：作者、格式，导出文件或复制为文字（网页版 OnePage 的导出那一页）
struct SkinExportSheet: View {
    let row: Row
    @State private var who = SkinFile.author()
    @State private var format: SkinFile.Format = .json
    @State private var file: URL?
    @State private var problem: String?
    @State private var done: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                TextField("作者名", text: $who)
            } header: { GroupTitle("作者") } footer: {
                Text(who.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "填写后，导出的名称后缀「by 作者」，并记住供之后的导出使用。留空则不署名。"
                     : "导出的名称为「\(SkinFile.signed(row.string("name"), who))」。作者名会被记住，之后导出自动带上。")
            }
            Section {
                Picker("格式", selection: $format) {
                    ForEach(SkinFile.Format.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: { GroupTitle("格式") } footer: {
                Text(format == .json ? "JSON 以文件形式分享时可靠；经聊天软件复制粘贴时，引号可能被改动而无法导入。"
                     : "TXT 与 DOCX 中的内容经过编码，复制粘贴、转发时不受引号与换行改动的影响。")
            }
            Section {
                Button("导出文件") { exportFile() }
                if let file {
                    ShareLink(item: file) { Label("存储或发送 \(file.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
                Button("复制为文字") { copyText() }
            }
        }
        .navigationTitle("导出美化包")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .alert(done ?? "", isPresented: Binding(get: { done != nil }, set: { if !$0 { done = nil } })) {
            Button("好") { done = nil }
        }
        .onChange(of: format) { _, _ in file = nil }
    }

    private func remember() {
        do { try SkinFile.setAuthor(who) } catch { problem = "作者名未能保存：\(error.localizedDescription)" }
    }

    private func exportFile() {
        remember()
        do { file = try SkinFile.export(row, format: format, who: who); problem = nil }
        catch { problem = "导出失败：\(error.localizedDescription)" }
    }

    private func copyText() {
        remember()
        do {
            UIPasteboard.general.string = try SkinFile.toText(row, who: who)
            problem = nil
            done = "已复制美化包文字，对方可在「粘贴导入」中粘贴。"
        } catch { problem = "复制失败：\(error.localizedDescription)" }
    }
}

/// 手写的那一段（网页版 CssPage），下面摆出编辑器编出来的那一段（4.957）：只读，可复制，可并入自定义 CSS
struct SkinCssView: View {
    let id: String
    @State private var text = ""
    @State private var loaded = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var merging = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        let row = Skins.get(id)
        let made = SkinGen.shared.emit(row?["gen"]) ?? ""
        Form {
            if let problem { Text(problem).foregroundStyle(Theme.danger) }
            Section {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .frame(minHeight: 280)
            } header: { GroupTitle("自定义 CSS") } footer: {
                HelpNote("挂着这一份的会话打开时生效。最后改的一层排在后面：改这里之后，这一段排在编辑器与尺寸之后，要覆盖编辑器的样式需要写 !important；之后再调编辑器或尺寸，调过的样式排到这一段之后生效。可用的类名以网页版「美化 - 写给作者」为准（ph- 开头的类名与 --ph- 开头的变量）。", title: "自定义 CSS")
            }
            if !made.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    DisclosureGroup("编辑器生成的 CSS（\(made.components(separatedBy: "\n").count) 行）") {
                        Text(made).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2).textSelection(.enabled)
                    }
                    Button("复制") { UIPasteboard.general.string = made; notice = "已复制编辑器生成的 CSS。" }
                    Button("并入自定义 CSS") { merging = true }
                } footer: {
                    Text("编辑器里的设置单独保存，打开会话时编成这一段，与上面手写的一起生效。这里只读；并入之后编辑器的设置恢复默认，只能在自定义 CSS 里修改。")
                }
            }
        }
        .navigationTitle("自定义 CSS")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = row?.string("css") ?? ""
        }
        .onChange(of: text) { _, v in
            guard loaded else { return }
            saveTask?.cancel()
            saveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                save(v)
            }
        }
        .onDisappear { if saveTask != nil { saveTask?.cancel(); save(text) } }
        .confirmationDialog("并入自定义 CSS", isPresented: $merging, titleVisibility: .visible) {
            Button("并入") { merge(made) }
        } message: {
            Text("编辑器生成的样式将写在自定义 CSS 的末尾，编辑器的设置全部恢复默认。之后在编辑器里看不到这些设置，只能在自定义 CSS 里修改。")
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        }
    }

    private func save(_ v: String) {
        saveTask = nil
        do { try Skins.setCss(id, v); problem = nil } catch { problem = "无法保存自定义 CSS：\(error.localizedDescription)" }
    }

    private func merge(_ made: String) {
        let cur = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (cur.isEmpty ? "" : cur + "\n\n") + made
        do {
            try Skins.update(id) { $0["gen"] = .object([:]) }
            try Skins.setCss(id, next)
            saveTask?.cancel(); saveTask = nil
            text = next
            problem = nil
            notice = "已并入自定义 CSS。"
        } catch { problem = "未能并入：\(error.localizedDescription)" }
    }
}

extension Skins {
    /// 改手写 CSS。内容变了：late 清掉，回到手写 CSS 在后（网页版 skin.js 的 update，4.615）。之后在后台按新的 CSS 重画
    static func setCss(_ id: String, _ css: String) throws {
        guard let r = get(id), r.string("css") != css else { return }
        try update(id) { row in
            row["css"] = .string(css)
            row["late"] = .bool(false)
        }
        Task { @MainActor in await CssRasterizer.ensure(skinId: id) }
    }
}
