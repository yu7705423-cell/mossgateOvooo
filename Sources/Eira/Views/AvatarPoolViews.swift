import PhotosUI
import SwiftUI

/// 角色的头像库（网页版 chat/pages/AvatarPool.js）。用户先传几张进去，角色按名字挑一张换上。
struct AvatarPoolView: View {
    let charId: String
    @State private var items: [AvatarPool.Item] = []
    @State private var current = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                if items.isEmpty { Text("尚无可换的头像。").foregroundStyle(Theme.text2) }
                ForEach(items) { it in
                    HStack(spacing: Theme.gap) {
                        LocalImage(id: it.imageId, maxPixel: 200).frame(width: 44, height: 44).clipShape(Circle())
                        TextField("名字", text: Binding(get: { it.name }, set: { rename(it, $0) }))
                        if current == it.imageId { Text("使用中").font(.footnote).foregroundStyle(Theme.text2) }
                    }
                }
                .onDelete { idx in
                    for i in idx { remove(items[i]) }
                }
                PhotosPicker(selection: $picked, maxSelectionCount: 9, matching: .images) { Label("添加", systemImage: "plus") }
            } header: {
                Text("头像库")
            } footer: {
                HelpNote("角色在对话中按名字从这里挑一张换上，名字需要彼此分得开，例如「白猫」「黑底」。头像库为空时，角色不知道可以换头像。左滑移出。", title: "头像库")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle("头像库")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: picked) { _, list in
            guard !list.isEmpty else { return }
            Task {
                for it in list {
                    do {
                        guard let data = try await it.loadTransferable(type: Data.self) else { throw StoreError(message: "无法读取所选图片") }
                        let id = try Images.save(data, maxPixel: Images.iconMax)
                        try AvatarPool.add(charId, imageId: id, name: "")
                    } catch {
                        await MainActor.run { problem = "添加失败：\(error.localizedDescription)" }
                    }
                }
                await MainActor.run { picked = []; load() }
            }
        }
    }

    private func load() {
        guard let c = (try? Repo.character(charId)) ?? nil else { return }
        items = AvatarPool.pool(c.row)
        current = c.avatar
    }

    private func rename(_ it: AvatarPool.Item, _ name: String) {
        guard let i = items.firstIndex(where: { $0.imageId == it.imageId }) else { return }
        items[i] = AvatarPool.Item(imageId: it.imageId, name: String(name.prefix(20)))
        do { try AvatarPool.save(charId, items) } catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func remove(_ it: AvatarPool.Item) {
        do { try AvatarPool.remove(charId, imageId: it.imageId); load() } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
