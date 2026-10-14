import PhotosUI
import SwiftUI

/// 朋友圈、主页里的动态（网页版 MomentsTab、MomentBits、MomentPage、Profile）。

enum MomentText {
    /// 刚刚 / N分钟前 / 14:30 / 昨天 / 3月2日（网页版 helpers.js 的 relTime）
    static func rel(_ ms: Double, now: Date = Date()) -> String {
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let min = Int(now.timeIntervalSince(d) / 60)
        if min < 1 { return "刚刚" }
        if min < 60 { return "\(min)分钟前" }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if d >= today { f.dateFormat = "HH:mm"; return f.string(from: d) }
        if d >= today.addingTimeInterval(-86400) { return "昨天" }
        f.dateFormat = "M月d日"
        return f.string(from: d)
    }

    /// 动态作者显示的名字：角色走备注，我自己是身份名
    static func name(_ id: String) -> String {
        if id == "me" { return (try? Repo.activePersona())?.name ?? "我" }
        return (try? Repo.character(id))?.displayName ?? "已删除"
    }

    static func avatar(_ id: String) -> String {
        if id == "me" { return (try? Repo.activePersona())?.avatar ?? "" }
        return (try? Repo.character(id))?.avatar ?? ""
    }
}

/// 九宫格（.mo-photos）：一张时窄一些，两张、四张两列，其余三列
struct MomentPhotos: View {
    let ids: [String]
    var onView: (String) -> Void

    var body: some View {
        let n = min(ids.count, 9)
        let cols = n == 1 ? 1 : (n == 2 || n == 4) ? 2 : 3
        let frac: CGFloat = n == 1 ? 0.62 : (n == 2 || n == 4) ? 0.76 : 1
        GeometryReader { g in
            let w = g.size.width * frac
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: cols), spacing: 3) {
                ForEach(Array(ids.prefix(9).enumerated()), id: \.offset) { _, id in
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay(LocalImage(id: id, maxPixel: 400))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rXs, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { onView(id) }
                }
            }
            .frame(width: w, alignment: .leading)
        }
        .aspectRatio(gridRatio(n: n, cols: cols, frac: frac), contentMode: .fit)
    }

    private func gridRatio(n: Int, cols: Int, frac: CGFloat) -> CGFloat {
        let rows = CGFloat((n + cols - 1) / cols)
        return CGFloat(cols) / rows / frac
    }
}

/// 一条动态（.mo-card）。朋友圈、主页的列表分栏、详情页都用它
struct MomentCard: View {
    let mo: Moments.Moment
    var onComment: (Moments.Moment, Moments.Comment?) -> Void
    var onOpen: ((Moments.Moment) -> Void)?
    var onProblem: (String) -> Void
    @State private var viewing: String?
    @State private var expanded = false
    @State private var editing = false
    @State private var deleting = false

    var body: some View {
        if mo.recalled && !expanded {
            Button { expanded = true } label: {
                HStack(spacing: 4) {
                    Text("\(MomentText.name(mo.authorId))撤回了一条动态")
                    SvgIcon(name: "chevronDown", size: 13, color: Theme.text3)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.sp4)
            }
            .buttonStyle(.plain)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: Theme.sp3) {
            Avatar(imageId: MomentText.avatar(mo.authorId), name: MomentText.name(mo.authorId), size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(MomentText.name(mo.authorId)).font(.system(size: 13, weight: .medium))
                if !mo.text.isEmpty {
                    Text(mo.text).font(.system(size: 14)).lineSpacing(5).padding(.top, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen?(mo) }
                }
                if !mo.images.isEmpty {
                    MomentPhotos(ids: mo.images) { viewing = $0 }.padding(.top, Theme.sp2)
                }
                foot.padding(.top, Theme.sp2)
                if !mo.comments.isEmpty {
                    CommentList(mo: mo, onReply: mo.recalled ? nil : { c in onComment(mo, c) }, onProblem: onProblem)
                        .padding(Theme.sp2)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                        .padding(.top, Theme.sp2)
                }
            }
        }
        .padding(Theme.sp4)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
        .opacity(mo.recalled ? 0.6 : 1)
        .fullScreenCover(item: Binding(get: { viewing.map { ConversationView.ViewingImage(id: $0) } }, set: { viewing = $0?.id })) { v in
            ImageViewer(imageId: v.id)
        }
        .sheet(isPresented: $editing) { NavigationStack { EditMomentView(mo: mo) } }
        .confirmationDialog(mo.isMine ? "删除后不可恢复。" : "删除后不可恢复。评论与点赞一并删除。",
                            isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try Moments.remove(mo.id) } catch { onProblem("删除失败：\(error.localizedDescription)") }
            }
        }
    }

    private var foot: some View {
        let liked = mo.likes.contains("me")
        var time = MomentText.rel(mo.createdAt)
        if mo.editedAt > 0 { time += " · 已编辑" }
        if mo.isMine, let v = mo.visibleTo { time += v.isEmpty ? " · 仅自己可见" : " · \(v.count) 位角色可见" }
        return HStack {
            Text(time).font(.system(size: 11)).foregroundStyle(Theme.text3)
            Spacer()
            HStack(spacing: Theme.sp3) {
                if !mo.recalled {
                    act("heart", count: mo.likes.count, on: liked, label: liked ? "取消点赞" : "点赞") {
                        do { try Moments.toggleLike(mo.id) } catch { onProblem(error.localizedDescription) }
                    }
                    act("message", count: mo.comments.count, label: "评论") { onComment(mo, nil) }
                    if mo.isMine { act("edit", label: "编辑") { editing = true } }
                }
                act("trash", label: "删除") { deleting = true }
            }
        }
    }

    private func act(_ icon: String, count: Int = 0, on: Bool = false, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                SvgIcon(name: icon, size: 14, color: on ? Theme.text : Theme.text3)
                if count > 0 { Text("\(count)").font(.system(size: 11)).foregroundStyle(on ? Theme.text : Theme.text3) }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 评论列表：「我 回复 阿岚：…」。点一条可以回复、复制、删除
struct CommentList: View {
    let mo: Moments.Moment
    var onReply: ((Moments.Comment) -> Void)?
    var onProblem: (String) -> Void
    @State private var acting: Moments.Comment?
    @State private var removing: Moments.Comment?

    var body: some View {
        let byId = Dictionary(mo.comments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 2) {
            ForEach(mo.comments) { c in
                Group {
                    if let to = byId[c.replyTo] {
                        Text("\(Text(MomentText.name(c.authorId)).fontWeight(.medium)) 回复 \(Text(MomentText.name(to.authorId)).fontWeight(.medium))：\(c.text)")
                    } else {
                        Text("\(Text(MomentText.name(c.authorId)).fontWeight(.medium))：\(c.text)")
                    }
                }
                .font(.system(size: 12)).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { acting = c }
            }
        }
        .confirmationDialog(acting.map { "\(MomentText.name($0.authorId))：\(String($0.text.prefix(40)))" } ?? "",
                            isPresented: Binding(get: { acting != nil }, set: { if !$0 { acting = nil } }),
                            titleVisibility: .visible, presenting: acting) { c in
            if let onReply, c.authorId != "me" { Button("回复") { onReply(c) } }
            Button("复制") { UIPasteboard.general.string = c.text }
            Button("删除", role: .destructive) { removing = c }
        }
        .confirmationDialog("删除这条评论。删除后不可恢复，回复它的评论保留。",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { c in
            Button("删除", role: .destructive) {
                do { try Moments.removeComment(mo.id, commentId: c.id) } catch { onProblem(error.localizedDescription) }
            }
        }
    }
}

/// 写评论（整页）：输入框在最上面；我自己的动态下面可以点一位角色请它来评论
struct CommentSheet: View {
    let momentId: String
    var replyTo: Moments.Comment?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var reply: Moments.Comment?
    @State private var asking = ""
    @State private var sending = false
    @State private var problem: String?
    @State private var mo: Moments.Moment?
    @State private var chars: [Character] = []
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp4) {
                if let reply {
                    HStack {
                        Text("回复 \(MomentText.name(reply.authorId))").font(.system(size: 13)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button("取消回复") { self.reply = nil }.font(.system(size: 14))
                    }
                }
                HStack(alignment: .bottom, spacing: Theme.sp2) {
                    TextField(reply.map { "回复 \(MomentText.name($0.authorId))" } ?? "写下评论", text: $text, axis: .vertical)
                        .lineLimit(2...6).focused($focused)
                        .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    Button(action: send) {
                        SvgIcon(name: "send", size: 16, color: Theme.onAccent)
                            .frame(width: Theme.composerH, height: Theme.composerH)
                            .background(Circle().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                    .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.35 : 1)
                    .accessibilityLabel("发送")
                }
                if sending { Text("正在等待角色回复").font(.system(size: 12)).foregroundStyle(Theme.text3) }
                if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.dangerText) }
                if let mo, mo.isMine, !chars.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.sp2) {
                        GroupTitle("请角色评论")
                        Text("点一位角色，调用一次接口，由该角色看过这条动态后写一条评论并点赞。")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        FlowChips(items: chars.map { ($0.id, asking == $0.id ? "正在评论" : $0.displayName) }) { id in ask(id) }
                            .disabled(!asking.isEmpty)
                    }
                }
                if let mo {
                    if mo.comments.isEmpty {
                        Text("暂无评论。").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    } else {
                        CommentList(mo: mo, onReply: mo.recalled ? nil : { c in reply = c; focused = true },
                                    onProblem: { problem = $0 })
                    }
                }
            }
            .padding(Theme.sp4)
        }
        .navigationTitle("评论")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .onAppear {
            reply = replyTo
            reload()
            chars = ((try? Repo.characters()) ?? []).filter { !$0.archived && !$0.row.bool("isNpc") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in reload() }
    }

    private func reload() { mo = Moments.get(momentId) }

    private func send() {
        let t = text
        let r = reply?.id ?? ""
        text = ""
        reply = nil
        sending = true
        problem = nil
        Task {
            do { try await Moments.send(comment: t, on: momentId, replyTo: r) }
            catch { await MainActor.run { problem = error.localizedDescription } }
            await MainActor.run { sending = false }
        }
    }

    private func ask(_ charId: String) {
        guard asking.isEmpty else { return }
        guard AppSettings.load().mainPreset != nil else { problem = "尚未配置模型接口"; return }
        asking = charId
        problem = nil
        Task {
            do { try await Moments.comment(momentId: momentId, charId: charId) }
            catch { await MainActor.run { problem = error.localizedDescription } }
            await MainActor.run { asking = "" }
        }
    }
}

/// 一排可以换行的小按钮（.btn-row.is-chips）
struct FlowChips: View {
    let items: [(String, String)]
    var onTap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: Theme.sp2)], alignment: .leading, spacing: Theme.sp2) {
            ForEach(items.indices, id: \.self) { i in
                let id = items[i].0, label = items[i].1
                Button { onTap(id) } label: {
                    Text(label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, Theme.sp3).frame(maxWidth: .infinity, minHeight: 30)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rXs, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 改我自己那条的文字
struct EditMomentView: View {
    let mo: Moments.Moment
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextField("这一刻的想法", text: $text, axis: .vertical).lineLimit(4...12)
            } footer: {
                Text("只改文字，图片与可见范围不变。保存后显示「已编辑」，角色之后读到的是改过的文字。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.dangerText) } }
        }
        .navigationTitle("编辑动态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do { try Moments.edit(mo.id, text: text); dismiss() } catch { problem = error.localizedDescription }
                }
            }
        }
        .onAppear { text = mo.text }
    }
}

// MARK: - 朋友圈页签

struct MomentsTab: View {
    @Binding var path: NavigationPath
    @State private var list: [Moments.Moment] = []
    @State private var me: Persona?
    @State private var composing = false
    @State private var commenting: CommentTarget?
    @State private var busy = false
    @State private var notice: String?
    @State private var coverItem: PhotosPickerItem?

    struct CommentTarget: Identifiable { var id: String { mo.id + (reply?.id ?? "") }; var mo: Moments.Moment; var reply: Moments.Comment? }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                if let notice {
                    Text(notice).font(.system(size: 13)).foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.sp4).padding(.bottom, Theme.sp2)
                }
                if list.isEmpty {
                    EmptyState(title: "暂无动态", desc: "可自行发布，也可由角色依据人设与近期对话生成。图片从本地选取，仅保存在本设备。")
                } else {
                    ForEach(list) { mo in
                        MomentCard(mo: mo, onComment: { m, c in commenting = CommentTarget(mo: m, reply: c) },
                                   onOpen: { path.append(ChatAppView.ChatRoute.moment($0.id)) },
                                   onProblem: { notice = $0 })
                    }
                }
            }
            .padding(.bottom, Theme.sp6)
        }
        .background(Theme.bg)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in reload() }
        .sheet(isPresented: $composing) { NavigationStack { ComposeMomentView { notice = $0 } } }
        .sheet(item: $commenting) { t in NavigationStack { CommentSheet(momentId: t.mo.id, replyTo: t.reply) } }
        .onChange(of: coverItem) { _, item in setCover(item) }
    }

    /// 顶部（.mo-header）：封面、右上角三个圆键（换封面、刷新、发布），右下角名字与头像
    private var header: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let cover = me?.row.string("cover"), !cover.isEmpty {
                    LocalImage(id: cover, maxPixel: 1200)
                } else {
                    Theme.surface3
                }
            }
            .frame(height: 210)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .topTrailing) {
                HStack(spacing: Theme.sp2) {
                    PhotosPicker(selection: $coverItem, matching: .images) { headerIcon("image") }.accessibilityLabel("更换封面")
                    Button(action: refresh) { headerIcon("refresh") }.disabled(busy).accessibilityLabel("请一位角色发动态")
                    Button { composing = true } label: { headerIcon("camera") }.accessibilityLabel("发布")
                }
                .padding(Theme.sp3)
                .padding(.top, 0)
            }
            HStack(alignment: .bottom, spacing: Theme.sp3) {
                Text(me?.name ?? "我").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                    .padding(.bottom, 34)
                Avatar(imageId: me?.avatar ?? "", name: me?.name ?? "我", size: 62)
                    .overlay(RoundedRectangle(cornerRadius: 62 * 14 / 44, style: .continuous).stroke(Theme.bg, lineWidth: 3))
            }
            .padding(.trailing, Theme.sp4)
            .offset(y: 28)
        }
        .padding(.bottom, 34)
    }

    private func headerIcon(_ name: String) -> some View {
        SvgIcon(name: name, size: 17, color: .white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.black.opacity(0.4)))
    }

    private func reload() {
        list = Moments.all()
        me = try? Repo.activePersona()
    }

    /// 随机一位角色写一条动态（一次调用）
    private func refresh() {
        let chars = ((try? Repo.characters()) ?? []).filter { !$0.archived && !$0.row.bool("isNpc") }
        guard let c = chars.randomElement() else { notice = "请先创建角色卡"; return }
        guard AppSettings.load().mainPreset != nil else { notice = "尚未配置模型接口"; return }
        busy = true
        notice = "\(c.displayName)正在写动态"
        Task {
            do {
                try await Moments.createMoment(charId: c.id)
                await MainActor.run { notice = "\(c.displayName)发布了一条动态" }
            } catch {
                await MainActor.run { notice = error.localizedDescription }
            }
            await MainActor.run { busy = false }
        }
    }

    private func setCover(_ item: PhotosPickerItem?) {
        guard let item, let pid = me?.id else { return }
        coverItem = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let id = try Images.save(data)
                guard var row = try Database.shared.get(Collections.personas, id: pid) else { return }
                row["cover"] = .string(id)
                row.touch()
                try Database.shared.put(Collections.personas, row)
                await MainActor.run { reload() }
            } catch {
                await MainActor.run { notice = "封面保存失败：\(error.localizedDescription)" }
            }
        }
    }
}

/// 发布动态（整页）：文字、图片、谁可以看。发布后看得见的角色各写一条评论，页上写明共几次调用
struct ComposeMomentView: View {
    var onNotice: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var images: [String] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var vis = "all"
    @State private var chosen: Set<String> = []
    @State private var chars: [Character] = []
    @State private var problem: String?
    @AppStorage("eira.moment.vis") private var lastVis = "all"

    private var visibleTo: [String]? { vis == "all" ? nil : vis == "none" ? [] : Array(chosen) }
    private var viewerCount: Int { Moments.viewers(visibleTo: visibleTo).count }

    var body: some View {
        Form {
            Section {
                TextField("此刻的想法", text: $text, axis: .vertical).lineLimit(4...12)
            }
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.sp2), count: 4), spacing: Theme.sp2) {
                    ForEach(images, id: \.self) { id in
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay(LocalImage(id: id, maxPixel: 300))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rXs, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button { images.removeAll { $0 == id } } label: {
                                    SvgIcon(name: "close", size: 12, color: .white).frame(width: 20, height: 20)
                                        .background(Circle().fill(Color.black.opacity(0.5)))
                                }
                                .buttonStyle(.plain).padding(3).accessibilityLabel("移除")
                            }
                    }
                    if images.count < 9 {
                        PhotosPicker(selection: $picked, maxSelectionCount: 9 - images.count, matching: .images) {
                            SvgIcon(name: "plus", size: 20, color: Theme.text2)
                                .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rXs, style: .continuous))
                        }
                        .accessibilityLabel("添加图片")
                    }
                }
                .padding(.vertical, Theme.sp1)
            } footer: { Text("最多九张。") }
            Section {
                Picker("谁可以看", selection: $vis) {
                    Text("所有角色").tag("all")
                    Text("选定的角色").tag("some")
                    Text("仅自己").tag("none")
                }
                if vis == "some" {
                    ForEach(chars) { c in
                        Button {
                            if chosen.contains(c.id) { chosen.remove(c.id) } else { chosen.insert(c.id) }
                        } label: {
                            HStack {
                                Avatar(imageId: c.avatar, name: c.displayName, size: 28)
                                Text(c.displayName).foregroundStyle(Theme.text)
                                Spacer()
                                if chosen.contains(c.id) { SvgIcon(name: "check", size: 16, color: Theme.text) }
                            }
                        }
                    }
                }
            } footer: {
                Text(viewerCount == 0
                     ? "聊天时这些角色知道你发了这条动态。当前没有角色可以看到，发布后不调用接口。"
                     : "聊天时这些角色知道你发了这条动态。发布后，可以看到的 \(viewerCount) 位角色各调用一次接口，写一条评论并点赞，共 \(viewerCount) 次。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.dangerText) } }
            Section {
                Button("发布", action: post)
                    .buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("发布动态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .onAppear {
            chars = ((try? Repo.characters()) ?? []).filter { !$0.archived && !$0.row.bool("isNpc") }
            vis = lastVis == "some" ? "all" : lastVis
        }
        .onChange(of: picked) { _, items in addPhotos(items) }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        picked = []
        Task {
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let id = try Images.save(data)
                    await MainActor.run { if images.count < 9 { images.append(id) } }
                } catch {
                    await MainActor.run { problem = "图片处理失败：\(error.localizedDescription)" }
                }
            }
        }
    }

    private func post() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !images.isEmpty else { return }
        if vis == "some" && chosen.isEmpty { problem = "请选择可以看到的角色"; return }
        do {
            let mo = try Moments.create(authorId: "me", text: t, images: images, visibleTo: visibleTo)
            lastVis = vis
            dismiss()
            guard !Moments.viewers(visibleTo: visibleTo).isEmpty, AppSettings.load().mainPreset != nil else { return }
            Task {
                let r = await Moments.reactToMine(mo.id)
                if let first = r.failed.first {
                    await MainActor.run { onNotice("\(r.failed.count) 位角色的评论没有生成。\(first)") }
                }
            }
        } catch {
            problem = "发布失败：\(error.localizedDescription)"
        }
    }
}

/// 一条动态的详情：卡片加下面直接写评论
struct MomentDetailView: View {
    let momentId: String
    @Binding var path: NavigationPath
    @State private var mo: Moments.Moment?
    @State private var commenting: MomentsTab.CommentTarget?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            if let mo {
                MomentCard(mo: mo, onComment: { m, c in commenting = MomentsTab.CommentTarget(mo: m, reply: c) },
                           onOpen: nil, onProblem: { problem = $0 })
                if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.dangerText).padding(Theme.sp4) }
            } else {
                EmptyState(title: "这条动态已不在了")
            }
        }
        .background(Theme.bg)
        .navigationTitle("动态")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { mo = Moments.get(momentId) }
        .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in mo = Moments.get(momentId) }
        .sheet(item: $commenting) { t in NavigationStack { CommentSheet(momentId: t.mo.id, replyTo: t.reply) } }
    }
}

// MARK: - 主页（角色与我共用，网页版 Profile）

/// 版式照 Instagram 的个人页：头像与三个数字一行，名字与签名，按钮，一排精选，「网格 / 列表」两栏。
/// 页面上只出签名，人设一个字不露（网页版第 6 条）。
struct ProfileView: View {
    let subjectId: String
    @Binding var path: NavigationPath
    var embedded = false

    @State private var char: Character?
    @State private var me: Persona?
    @State private var moments: [Moments.Moment] = []
    @State private var tab = "grid"
    @State private var commenting: MomentsTab.CommentTarget?
    @State private var problem: String?
    @State private var viewing: String?
    @State private var hlItem: PhotosPickerItem?
    @State private var naming: String?
    @State private var hlName = ""
    @State private var hlOpen: Highlight?
    @State private var contactCount = 0

    struct Highlight: Identifiable, Equatable { var id: String; var imageId: String; var title: String }

    private var isMe: Bool { subjectId == "me" }
    private var subjectRow: Row? { isMe ? me?.row : char?.row }
    private var name: String { isMe ? (me?.name ?? "我") : (char?.displayName ?? "") }
    private var highlights: [Highlight] {
        (subjectRow?["highlights"]?.array ?? []).compactMap { v in
            guard let o = v.object else { return nil }
            return Highlight(id: o["id"]?.string ?? UUID().uuidString, imageId: o["imageId"]?.string ?? "", title: o["title"]?.string ?? "")
        }
    }

    var body: some View {
        ScrollView {
            if subjectRow == nil && !isMe {
                EmptyState(title: "该角色已不存在")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    head
                    bio
                    actions
                    highlightRow
                    tabs
                    if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.dangerText).padding(Theme.sp4) }
                    content
                }
                .padding(.bottom, Theme.sp6)
            }
        }
        .background(Theme.bg)
        .modifier(TitleIf(on: !embedded, title: name))
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .eiraMomentsChanged)) { _ in reload() }
        .sheet(item: $commenting) { t in NavigationStack { CommentSheet(momentId: t.mo.id, replyTo: t.reply) } }
        .fullScreenCover(item: Binding(get: { viewing.map { ConversationView.ViewingImage(id: $0) } }, set: { viewing = $0?.id })) { v in
            ImageViewer(imageId: v.id)
        }
        .onChange(of: hlItem) { _, item in addHighlight(item) }
        .alert("精选名称", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("显示在圆圈下方", text: $hlName)
            Button("保存") { if let id = naming { saveHighlight(imageId: id, title: hlName) }; naming = nil }
            Button("取消", role: .cancel) { naming = nil }
        }
        .confirmationDialog(hlOpen?.title.isEmpty == false ? hlOpen!.title : "精选",
                            isPresented: Binding(get: { hlOpen != nil }, set: { if !$0 { hlOpen = nil } }),
                            titleVisibility: .visible, presenting: hlOpen) { h in
            Button("查看") { viewing = h.imageId }
            Button("删除", role: .destructive) { removeHighlight(h) }
        }
    }

    private var head: some View {
        HStack(spacing: Theme.sp5) {
            Avatar(imageId: subjectRow?.string("avatar") ?? "", name: name, size: 84)
                .clipShape(Circle())
            HStack {
                stat("\(moments.count)", "动态") { tab = "list" }
                stat("\(moments.filter { !$0.recalled }.reduce(0) { $0 + $1.images.count })", "照片") { tab = "grid" }
                stat("\(isMe ? contactCount : (char?.row["relations"]?.array?.count ?? 0))", isMe ? "联系人" : "关系") {}
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.sp4).padding(.top, Theme.sp4).padding(.bottom, Theme.sp3)
    }

    private func stat(_ n: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(n).font(Theme.serif(17)).foregroundStyle(Theme.text)
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.sp1)
        }
        .buttonStyle(.plain)
    }

    private var bio: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(Theme.serif(20))
            let sign = subjectRow?.string("signature") ?? ""
            if !sign.isEmpty { Text(sign).font(.system(size: 13)).foregroundStyle(Theme.text2) }
        }
        .padding(.horizontal, Theme.sp4)
    }

    private var actions: some View {
        HStack(spacing: Theme.sp2) {
            if isMe {
                if let pid = me?.id {
                    Button("编辑本人人设") { path.append(ChatAppView.ChatRoute.editPersona(pid)) }
                        .buttonStyle(EiraButtonStyle(kind: .ghost, full: true))
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rBtn, style: .continuous))
                }
            } else {
                Button("发消息", action: openChat).buttonStyle(EiraButtonStyle(kind: .primary, full: true))
                Button("编辑资料") { path.append(ChatAppView.ChatRoute.editChar(subjectId)) }
                    .buttonStyle(EiraButtonStyle(kind: .ghost, full: true))
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rBtn, style: .continuous))
            }
        }
        .padding(.horizontal, Theme.sp4).padding(.top, Theme.sp3).padding(.bottom, Theme.sp2)
    }

    private var highlightRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.sp3) {
                ForEach(highlights) { h in
                    Button { hlOpen = h } label: { ring(imageId: h.imageId, title: h.title.isEmpty ? " " : h.title) }
                        .buttonStyle(.plain)
                }
                PhotosPicker(selection: $hlItem, matching: .images) {
                    VStack(spacing: Theme.sp1) {
                        SvgIcon(name: "plus", size: 20, color: Theme.text2)
                            .frame(width: 56, height: 56)
                            .overlay(Circle().strokeBorder(Theme.border2, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).padding(-2))
                        Text("新建").font(.system(size: 11)).foregroundStyle(Theme.text2)
                    }
                    .frame(width: 64)
                }
                .accessibilityLabel("新建精选")
            }
            .padding(.horizontal, Theme.sp4).padding(.top, Theme.sp2).padding(.bottom, Theme.sp3)
        }
    }

    private func ring(imageId: String, title: String) -> some View {
        VStack(spacing: Theme.sp1) {
            LocalImage(id: imageId, maxPixel: 200)
                .frame(width: 56, height: 56).clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.border2, lineWidth: 1).padding(-2))
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
        }
        .frame(width: 64)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { i in
                let id = i == 0 ? "grid" : "list", icon = i == 0 ? "grid" : "notes", label = i == 0 ? "网格" : "列表"
                Button { tab = id } label: {
                    SvgIcon(name: icon, size: 20, color: tab == id ? Theme.text : Theme.text3)
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.sp3)
                        .overlay(alignment: .bottom) { (tab == id ? Theme.text : Color.clear).frame(height: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
            }
        }
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    @ViewBuilder private var content: some View {
        let live = moments.filter { !$0.recalled }
        let withPics = live.filter { !$0.images.isEmpty }
        if tab == "grid" {
            if withPics.isEmpty {
                EmptyState(title: "暂无照片", desc: "带图片的动态会显示在这里。")
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(withPics) { m in
                        Button { path.append(ChatAppView.ChatRoute.moment(m.id)) } label: {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay(LocalImage(id: m.images[0], maxPixel: 400))
                                .clipped()
                                .overlay(alignment: .topTrailing) {
                                    if m.images.count > 1 { SvgIcon(name: "layers", size: 13, color: .white).padding(6) }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开这条动态")
                    }
                }
            }
        } else if moments.isEmpty {
            EmptyState(title: "暂无动态")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(moments) { m in
                    MomentCard(mo: m, onComment: { mo, c in commenting = MomentsTab.CommentTarget(mo: mo, reply: c) },
                               onOpen: { path.append(ChatAppView.ChatRoute.moment($0.id)) }, onProblem: { problem = $0 })
                }
            }
        }
    }

    private func reload() {
        me = try? Repo.activePersona()
        if !isMe { char = try? Repo.character(subjectId) }
        moments = Moments.by(subjectId)
        contactCount = ((try? Repo.characters()) ?? []).filter { $0.row.string("parentId").isEmpty }.count
    }

    private func openChat() {
        do {
            let p = try People.ensureActivePersona()
            let chat = try People.chatFor(charId: subjectId, personaId: p.id)
            path.append(chat.id)
        } catch { problem = "无法打开会话：\(error.localizedDescription)" }
    }

    // MARK: 精选：一张图配一个名字，挂在这个人身上

    private func addHighlight(_ item: PhotosPickerItem?) {
        guard let item else { return }
        hlItem = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let id = try Images.save(data)
                await MainActor.run { hlName = ""; naming = id }
            } catch {
                await MainActor.run { problem = "图片处理失败：\(error.localizedDescription)" }
            }
        }
    }

    private func patchSubject(_ highlights: [JSONValue]) {
        let collection = isMe ? Collections.personas : Collections.characters
        let id = isMe ? (me?.id ?? "") : subjectId
        do {
            guard var row = try Database.shared.get(collection, id: id) else { return }
            row["highlights"] = .array(highlights)
            row.touch()
            try Database.shared.put(collection, row)
            reload()
        } catch { problem = "保存失败：\(error.localizedDescription)" }
    }

    private func saveHighlight(imageId: String, title: String) {
        let item: JSONValue = .object(["id": .string(Ids.make("hl")), "imageId": .string(imageId),
                                       "title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines))])
        patchSubject((subjectRow?["highlights"]?.array ?? []) + [item])
    }

    private func removeHighlight(_ h: Highlight) {
        patchSubject((subjectRow?["highlights"]?.array ?? []).filter { $0.object?["id"]?.string != h.id })
    }
}

/// 不是嵌在页签里时，顶栏写主页主人的名字
private struct TitleIf: ViewModifier {
    let on: Bool
    let title: String
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.navigationTitle(title).navigationBarTitleDisplayMode(.inline) } else { content }
    }
}
