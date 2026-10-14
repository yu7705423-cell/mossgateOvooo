import PhotosUI
import SwiftUI

/// 会话里的表情面板：占住键盘的位置（网页版第 23 条），按分组切换，点一下发出去。
struct StickerPanel: View {
    let onPick: (Stickers.Item) -> Void
    @State private var items: [Stickers.Item] = []
    @State private var group = ""
    @State private var managing = false
    @State private var problem: String?

    private var groups: [String] { Stickers.groups(items, settings: .load(), onlyUsed: true) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.gap) {
                        ForEach(groups, id: \.self) { g in
                            Button(g) { group = g }
                                .font(.footnote)
                                .foregroundStyle(g == current ? Theme.bubbleTheirsText : Theme.secondaryText)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(g == current ? Theme.placeholder : .clear, in: Capsule())
                        }
                    }
                }
                Button("管理") { managing = true }.font(.footnote)
            }
            .padding(.horizontal, Theme.pad).padding(.vertical, 6)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            if items.isEmpty {
                Text("表情库为空。点「管理」从相册添加。")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gap), count: 4), spacing: Theme.gap) {
                        ForEach(items.filter { $0.group == current }) { st in
                            Button { onPick(st) } label: {
                                VStack(spacing: 2) {
                                    StickerView(id: st.id, name: st.name).frame(width: 64, height: 64)
                                    Text(st.name).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                                }
                            }
                            .accessibilityLabel(st.name)
                        }
                    }
                    .padding(Theme.pad)
                }
            }
        }
        .frame(height: 280)
        .background(Theme.groupedBackground)
        .onAppear(perform: reload)
        .sheet(isPresented: $managing, onDismiss: reload) {
            NavigationStack { StickerManagerView() }
        }
    }

    private var current: String { groups.contains(group) ? group : (groups.first ?? "") }

    private func reload() {
        do { items = try Stickers.all(); problem = nil }
        catch { problem = "表情读取失败：\(error.localizedDescription)" }
    }
}

/// 表情库管理（网页版 StickerManager）：按分组列出，从相册添加，改名字、关键词、分组，删除；分组的新建、改名、删除。
struct StickerManagerView: View {
    @ObservedObject private var settings = SettingsModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Stickers.Item] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var targetGroup = Stickers.defaultGroup
    @State private var editing: Stickers.Item?
    @State private var problem: String?
    @State private var progress: String?
    @State private var newGroup = false
    @State private var groupName = ""
    @State private var renaming: String?
    @State private var removingGroup: String?

    private var groups: [String] { Stickers.groups(items, settings: settings.s) }

    var body: some View {
        List {
            Section {
                Picker("添加到分组", selection: $targetGroup) {
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                PhotosPicker(selection: $picked, maxSelectionCount: nil, matching: .images) {
                    Label("从相册添加", systemImage: "plus")
                }
                Button { groupName = ""; newGroup = true } label: { Label("新建分组", systemImage: "folder.badge.plus") }
                if let progress { Text(progress).font(.footnote).foregroundStyle(Theme.secondaryText) }
            } footer: {
                Text("一次选几张不设上限。名字取自图片的文件名，可逐个修改；角色按名字挑选表情，名字写清楚含义更容易被选中。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
            ForEach(groups, id: \.self) { g in
                Section {
                    let list = items.filter { $0.group == g }
                    if list.isEmpty {
                        Text("这个分组还没有表情。").font(.footnote).foregroundStyle(Theme.secondaryText)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gap), count: 4), spacing: Theme.gap) {
                            ForEach(list) { st in
                                Button { editing = st } label: {
                                    VStack(spacing: 2) {
                                        StickerView(id: st.id, name: st.name).frame(width: 60, height: 60)
                                        Text(st.name).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack {
                        Text("\(g)（\(items.filter { $0.group == g }.count)）")
                        Spacer()
                        Menu {
                            Button("改名") { groupName = g; renaming = g }
                            if g != Stickers.defaultGroup {
                                Button("删除分组", role: .destructive) { removingGroup = g }
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("分组操作")
                    }
                }
            }
        }
        .navigationTitle("表情库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear(perform: reload)
        .onChange(of: picked) { _, list in
            guard !list.isEmpty else { return }
            picked = []
            add(list)
        }
        .sheet(item: $editing, onDismiss: reload) { st in
            NavigationStack { StickerEditView(item: st, groups: groups) }
        }
        .alert("新建分组", isPresented: $newGroup) {
            TextField("分组名", text: $groupName)
            Button("取消", role: .cancel) {}
            Button("建立") {
                var g = ""
                settings.update { g = Stickers.addGroup(&$0, groupName) }
                if !g.isEmpty { targetGroup = g }
            }
        }
        .alert("分组改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("分组名", text: $groupName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                guard let from = renaming else { return }
                var failure: String?
                settings.update { do { try Stickers.renameGroup(&$0, from: from, to: groupName) } catch { failure = error.localizedDescription } }
                problem = failure.map { "改名未完成：\($0)" }
                reload()
            }
        }
        .confirmationDialog("分组里的表情移到「默认」，不删除。", isPresented: Binding(get: { removingGroup != nil }, set: { if !$0 { removingGroup = nil } }),
                            titleVisibility: .visible) {
            Button("删除分组", role: .destructive) {
                guard let g = removingGroup else { return }
                var failure: String?
                settings.update { do { try Stickers.removeGroup(&$0, g) } catch { failure = error.localizedDescription } }
                problem = failure.map { "删除未完成：\($0)" }
                reload()
            }
        }
    }

    private func reload() {
        do { items = try Stickers.all(); problem = nil }
        catch { problem = "表情读取失败：\(error.localizedDescription)" }
        if !groups.contains(targetGroup) { targetGroup = Stickers.defaultGroup }
    }

    private func add(_ list: [PhotosPickerItem]) {
        let group = targetGroup
        Task {
            var ok = 0
            var failed = 0
            var last = ""
            for (i, item) in list.enumerated() {
                await MainActor.run { progress = "正在添加 \(i + 1)/\(list.count)" }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw StoreError(message: "无法读取所选图片")
                    }
                    try Stickers.add(imageData: data, name: "表情 \(items.count + ok + 1)", group: group)
                    ok += 1
                } catch {
                    failed += 1
                    last = error.localizedDescription
                }
            }
            await MainActor.run {
                progress = "已添加 \(ok) 个。"
                problem = failed > 0 ? "有 \(failed) 张未能添加：\(last)" : nil
                reload()
            }
        }
    }
}

/// 一个表情：名字、关键词、分组、删除。
struct StickerEditView: View {
    let item: Stickers.Item
    let groups: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keywords = ""
    @State private var group = ""
    @State private var confirmDelete = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    StickerView(id: item.id, name: item.name).frame(width: 120, height: 120)
                    Spacer()
                }
            }
            Section {
                TextField("名字", text: $name)
                TextField("关键词，用空格或逗号分开", text: $keywords)
                Picker("分组", selection: $group) {
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                Text("角色按名字挑选表情。关键词用于搜索与联想。")
            }
            Section { Button("删除这个表情", role: .destructive) { confirmDelete = true } }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("表情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .confirmationDialog("删除后无法恢复。已经发出的表情显示为文字。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Stickers.remove(item.id); dismiss() }
                catch { problem = "删除失败：\(error.localizedDescription)" }
            }
        }
        .onAppear {
            name = item.name
            keywords = item.keywords.joined(separator: " ")
            group = item.group
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        do {
            try Stickers.update(item.id) {
                $0["name"] = .string(n.isEmpty ? "未命名" : n)
                $0["keywords"] = .array(Stickers.splitKeywords(keywords).map { .string($0) })
                $0["group"] = .string(group)
            }
            dismiss()
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
        }
    }
}
