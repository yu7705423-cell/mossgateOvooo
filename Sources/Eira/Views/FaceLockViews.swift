import PhotosUI
import SwiftUI

/// 锁脸照片（网页版角色卡的锁脸那一段，4.402）。角色与「我」各一份，逻辑一样。
struct FaceLockView: View {
    let owner: FaceLock.Owner
    @State private var faces: [String] = []
    @State private var one: String?
    @State private var mode = "self"
    @State private var desc = ""
    @State private var failed = false
    @State private var items: [PhotosPickerItem] = []
    @State private var problem: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                if faces.isEmpty { Text("尚无照片。").foregroundStyle(Theme.text2) }
                ForEach(faces, id: \.self) { id in
                    HStack(spacing: Theme.gap) {
                        LocalImage(id: id, maxPixel: 200).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                        Spacer()
                        Button(one == id ? "只传一张时用这张" : "设为只传一张时用") { setOne(id) }
                            .font(.footnote).buttonStyle(.borderless).disabled(one == id)
                    }
                }
                .onDelete { idx in
                    var list = faces
                    list.remove(atOffsets: idx)
                    save(list)
                }
                PhotosPicker(selection: $items, maxSelectionCount: 6, matching: .images) { Label("添加照片", systemImage: "plus") }
            } header: {
                Text("照片")
            } footer: {
                HelpNote("同一个人的几张清晰正脸照片。生图时用到锁脸，照片直接随请求发给支持参考图的生图接口；接口不支持时，照片先读成一段外貌描述（只读一次，之后用缓存），拼进提示词。左滑删除。增减照片后外貌描述重新读取。", title: "锁脸照片")
            }
            Section {
                Picker("何时使用", selection: $mode) {
                    Text(owner.isMe ? "提到名字或合照时" : "自拍或提到名字时").tag("self")
                    Text("每张图都用").tag("always")
                    Text("关闭").tag("off")
                }
            } footer: {
                HelpNote(owner.isMe
                         ? "提到名字或合照时：图片描述里写了你的名字，或有「合照」「我们」「一起」这类词时使用。每张图都用：所有图片都带上你的照片。"
                         : "自拍或提到名字时：图片描述里写了角色的名字，或有「自拍」「镜子」这类词时使用。每张图都用：该角色发的所有图片都带上照片。", title: "锁脸何时使用")
            }
            Section {
                if !desc.isEmpty {
                    Text(desc).font(.footnote)
                } else {
                    Text(failed ? "上次读取失败，不再自动读取。" : "尚未读取。需要时自动读取一次。").font(.footnote).foregroundStyle(Theme.text2)
                }
                Button("重新读取") {
                    do { try FaceLock.set(owner, ["faceDesc": .string(""), "faceDescFailed": .string("")]); load() }
                    catch { problem = "保存失败：\(error.localizedDescription)" }
                }
                .disabled(desc.isEmpty && !failed)
            } header: {
                Text("读出来的外貌")
            } footer: {
                Text("读取一次调用一次识图。")
                HelpNote("识图设为「交给聊天模型」或配好了识图接口时才能读取。清除后，下次需要时重新读取一次。", title: "读出来的外貌")
            }
            ProblemSection(text: problem)
        }
        .navigationTitle(owner.isMe ? "我的锁脸" : "锁脸")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: mode) { _, v in
            guard loaded else { return }
            do { try FaceLock.set(owner, ["faceLock": .string(v)]) } catch { problem = "保存失败：\(error.localizedDescription)" }
        }
        .onChange(of: items) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                var ids = faces
                for it in picked {
                    do {
                        guard let data = try await it.loadTransferable(type: Data.self) else { continue }
                        ids.append(try Images.save(data, maxPixel: Images.photoMax))
                    } catch { problem = "照片未能保存：\(error.localizedDescription)" }
                }
                items = []
                save(ids)
            }
        }
    }

    private func load() {
        let r = FaceLock.row(owner)
        faces = FaceLock.faces(r)
        one = FaceLock.one(r)
        mode = FaceLock.mode(r)
        desc = r?.string("faceDesc") ?? ""
        failed = !(r?.string("faceDescFailed") ?? "").isEmpty
        loaded = true
    }

    private func save(_ list: [String]) {
        do { try FaceLock.setFaces(owner, list); load() } catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func setOne(_ id: String) {
        do { try FaceLock.set(owner, ["faceOne": .string(id)]); load() } catch { problem = "保存失败：\(error.localizedDescription)" }
    }
}
