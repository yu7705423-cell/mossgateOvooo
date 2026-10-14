import PhotosUI
import SwiftUI

/// 相册首页（网页版 album/App.js）：相册一排、新建、导入图片、未归类的照片网格
struct AlbumHomeView: View {
    @State private var tick = 0
    @State private var naming = false
    @State private var newName = ""
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var problem: String?
    @State private var importing = false

    var body: some View {
        let _ = tick
        let albums = Album.listAlbums()
        let loose = Album.listPhotos("")
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp4) {
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal, Theme.pad) }
                HStack {
                    GroupTitle("相册")
                    Spacer()
                    Button { newName = ""; naming = true } label: { Label("新建相册", systemImage: "plus") }.font(.footnote)
                }
                .padding(.horizontal, Theme.pad)
                if albums.isEmpty {
                    Text("尚无相册").font(.footnote).foregroundStyle(Theme.text3).padding(.horizontal, Theme.pad)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.sp3) {
                            ForEach(albums) { a in
                                NavigationLink { AlbumPageView(albumId: a.id) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        thumb(Album.coverImage(a), size: 110)
                                        Text(a.string("name")).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                                        Text("\(Album.listPhotos(a.id).count) 张").font(.caption).foregroundStyle(Theme.text3)
                                    }
                                    .frame(width: 110)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Theme.pad)
                    }
                }
                HStack {
                    GroupTitle("未归类")
                    Spacer()
                    Button { picking = true } label: { Label(importing ? "正在导入" : "导入图片", systemImage: "square.and.arrow.down") }
                        .font(.footnote).disabled(importing)
                }
                .padding(.horizontal, Theme.pad)
                PhotoGrid(photos: loose)
                if loose.isEmpty {
                    Text("会话里长按图片或表情，选择「存相册」，存下的图在这里。也可以从手机相册导入。")
                        .font(.footnote).foregroundStyle(Theme.text3).padding(.horizontal, Theme.pad)
                }
            }
            .padding(.vertical, Theme.sp3)
        }
        .background(Theme.background)
        .navigationTitle("相册")
        .onAppear { tick += 1 }
        .alert("新建相册", isPresented: $naming) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("新建") {
                do { try Album.createAlbum(newName); problem = nil } catch { problem = error.localizedDescription }
                tick += 1
            }
        }
        .photosPicker(isPresented: $picking, selection: $picked, maxSelectionCount: nil, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            importing = true
            Task {
                var failed = 0
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { failed += 1; continue }
                        let id = try Images.save(data)
                        try Album.saveImage(id)
                    } catch { failed += 1 }
                }
                await MainActor.run {
                    importing = false
                    problem = failed > 0 ? "有 \(failed) 张未能导入" : nil
                    tick += 1
                }
            }
        }
    }
}

/// 一格一张的照片网格，点进照片页
struct PhotoGrid: View {
    let photos: [Album.Photo]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(photos) { p in
                NavigationLink { PhotoPageView(photoId: p.id) } label: {
                    Group {
                        if p.kind == "card" && p.imageId.isEmpty {
                            ZStack {
                                Theme.surface2
                                VStack(spacing: 4) {
                                    Image(systemName: "text.bubble").foregroundStyle(Theme.text2)
                                    Text(p.title.isEmpty ? "消息卡片" : p.title).font(.caption2).foregroundStyle(Theme.text2).lineLimit(2)
                                }
                                .padding(6)
                            }
                        } else {
                            LocalImage(id: p.imageId, maxPixel: 300)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.pad)
    }
}

private func thumb(_ imageId: String, size: CGFloat) -> some View {
    Group {
        if imageId.isEmpty {
            ZStack { Theme.surface2; Image(systemName: "photo").foregroundStyle(Theme.text3) }
        } else {
            LocalImage(id: imageId, maxPixel: size * 3)
        }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
}

/// 一本相册（网页版 AlbumPage）：照片网格、改名、删除相册
struct AlbumPageView: View {
    let albumId: String
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var problem: String?

    var body: some View {
        let _ = tick
        let row = Album.album(albumId)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp3) {
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal, Theme.pad) }
                let list = Album.listPhotos(albumId)
                if list.isEmpty {
                    EmptyState(title: "这本相册是空的", desc: "在照片页的「所在相册」中可以把照片移进来。")
                }
                PhotoGrid(photos: list)
            }
            .padding(.vertical, Theme.sp3)
        }
        .background(Theme.background)
        .navigationTitle(row?.string("name") ?? "相册")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tick += 1 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("改名") { name = row?.string("name") ?? ""; renaming = true }
                    Button("删除相册", role: .destructive) { confirmDelete = true }
                } label: { NavIcon("more") }
            }
        }
        .alert("改名", isPresented: $renaming) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") { act { try Album.renameAlbum(albumId, name) } }
        }
        .confirmationDialog("删除这本相册。里面的照片不删，退回「未归类」。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除相册", role: .destructive) { act { try Album.removeAlbum(albumId) }; dismiss() }
        }
    }

    private func act(_ f: () throws -> Void) {
        do { try f(); problem = nil } catch { problem = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }
}

/// 一张照片（网页版 PhotoPage）：大图、来自谁、存到手机、所在相册、设为封面、删除
struct PhotoPageView: View {
    let photoId: String
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0
    @State private var viewing = false
    @State private var notice: String?
    @State private var confirmDelete = false

    var body: some View {
        let _ = tick
        Form {
            if let p = Album.photo(photoId) {
                Section {
                    if p.kind == "card" {
                        VStack(alignment: .leading, spacing: Theme.sp2) {
                            if !p.title.isEmpty { Text(p.title).font(.headline) }
                            ForEach(Array(p.cardLines.enumerated()), id: \.offset) { _, l in
                                VStack(alignment: l.mine ? .trailing : .leading, spacing: 2) {
                                    Text(l.name).font(.caption).foregroundStyle(Theme.text3)
                                    Text(SpecialCards.stripped(l.text)).font(.system(size: 14))
                                        .padding(.horizontal, Theme.bubblePadX).padding(.vertical, Theme.bubblePadY)
                                        .background(l.mine ? Theme.surface3 : Theme.surface2,
                                                    in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                                }
                                .frame(maxWidth: .infinity, alignment: l.mine ? .trailing : .leading)
                            }
                        }
                    } else {
                        LocalImage(id: p.imageId, maxPixel: 1200, fit: true)
                            .frame(maxWidth: .infinity, maxHeight: 420)
                            .onTapGesture { viewing = true }
                    }
                }
                .listRowBackground(Color.clear)
                Section {
                    if p.hasFrom {
                        LabeledContent("来自", value: "\(p.fromName.isEmpty ? "对方" : p.fromName) · \(Self.at(p.fromAt))")
                    }
                    if p.kind == "card" {
                        LabeledContent("包含", value: "\(p.cardLines.count) 条消息")
                    }
                    if !p.imageId.isEmpty {
                        Button("存到手机") { Task { notice = await Album.toDevice(p.imageId) } }
                    }
                    Picker("所在相册", selection: Binding(get: { p.albumId }, set: { v in act { try Album.move(photoId, to: v) } })) {
                        Text("未归类").tag("")
                        ForEach(Album.listAlbums()) { a in Text(a.string("name")).tag(a.id) }
                    }
                    if !p.albumId.isEmpty {
                        Button("设为相册封面") { act { try Album.setCover(p.albumId, photoId) }; notice = "已设为封面" }
                    }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
                }
                Section {
                    Button("删除", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText)
                } footer: {
                    if p.hasFrom { Text("只从相册里移除，会话里那一条不受影响。") }
                }
            } else {
                Text("这张已经不在了").foregroundStyle(Theme.text3)
            }
        }
        .navigationTitle(Album.photo(photoId)?.kind == "card" ? "消息卡片" : "照片")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tick += 1 }
        .fullScreenCover(isPresented: $viewing) {
            if let p = Album.photo(photoId) { ImageViewer(imageId: p.imageId) }
        }
        .confirmationDialog("删除这一张", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { act { try Album.removePhoto(photoId) }; dismiss() }
        }
    }

    static func at(_ ms: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy 年 M 月 d 日 HH:mm"
        return f.string(from: Date(millis: ms))
    }

    private func act(_ f: () throws -> Void) {
        do { try f() } catch { notice = "未能保存：\(error.localizedDescription)" }
        tick += 1
    }
}
