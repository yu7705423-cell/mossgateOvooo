import SwiftUI
import UIKit

/// 「我们」的正文页（网页版 apps/us/pages/ReadPage.js）。整个是线下正文页的同一套：同一批 beats、同一套分张、同一份外观（Stage）。
/// 差别只有几处：署名按这部作品里的身份来、菜单里多一个目录与下一章、「整篇由它写」开着时写的是整段、末尾可以给后续走向。
///
/// 翻页那一档里左缘往右滑留给翻页，不当作返回（网页版 data-edge="off"）；返回用导航栏上的返回键。
/// 每写一段调用一次接口；新建那一篇选了「让角色开场」时进来直接写第一段，只写一次（先记下再写，4.834）。
struct UsReadView: View {
    let chapterId: String
    @EnvironmentObject private var nav: UsNav

    @State private var chapter: Row?
    @State private var work: Row?
    @State private var beats: [Row] = []
    @State private var stageCfg = Stage.config()
    @State private var look = Stage.look(Stage.config())
    @State private var pageAt = 0
    @State private var draft = ""
    @State private var director = false
    @State private var hold = false
    @State private var writing = false
    @State private var live = ""
    @State private var job: Task<Void, Never>?
    @State private var problem: String?
    @State private var notice: String?
    @State private var editing: Row?
    @State private var editText = ""
    @State private var branching: Row?
    @State private var removing: Row?
    @State private var dropLast = false
    @State private var nextOpen = false
    @State private var showLook = false
    @State private var ownNext = ""
    @State private var askVolume: String?
    @State private var opened = false
    @FocusState private var typing: Bool

    private static let keys = ["A", "B", "C"]

    private var told: [Row] { beats.filter { $0.string("role") != Scenes.DIRECTOR } }
    private var lastBeat: Row? { told.last }
    private var canMore: Bool { lastBeat?.string("role") == Scenes.CHAR }
    private var isPage: Bool { Stage.layoutOf(stageCfg) == "page" }
    private var charName: String { work.map { Works.charOf($0).name } ?? "对方" }

    var body: some View {
        Group {
            if let w = work, let ch = chapter {
                page(w, ch)
            } else {
                ScrollView { EmptyState(title: "这一篇已经不在了") }.navigationTitle("我们")
            }
        }
        .onAppear {
            reload()
            guard !opened else { return }
            opened = true
            if Works.claimOpening(chapterId) { write() }
        }
        .onDisappear { job?.cancel() }
    }

    private func page(_ w: Row, _ ch: Row) -> some View {
        let next = Works.nextOf(w, ch, lastBeat: lastBeat)
        return VStack(spacing: 0) {
            if isPage && !writing && !told.isEmpty {
                pager(w, ch, next)
            } else {
                feed(w, ch, next)
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Theme.danger)
                    .padding(.horizontal, Theme.sp4).padding(.vertical, Theme.sp2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(look.bg)
            }
            composer(w)
        }
        .background(look.bg.ignoresSafeArea())
        .background(PopGestureOff(on: isPage))
        .navigationTitle(Works.chapterTitle(w, ch))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(look.bg, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .primaryAction) { menu(w) } }
        .navigationDestination(isPresented: $showLook) { StageLookView(sceneId: nil) }
        .sheet(isPresented: $nextOpen, onDismiss: reload) {
            NavigationStack { UsNextChapterView(workId: w.id) { id in nextOpen = false; nav.push(.read(id)) } }
        }
        .sheet(item: Binding(get: { editing.map { EditKey(id: $0.id) } }, set: { if $0 == nil { editing = nil } })) { _ in editSheet }
        .confirmationDialog("这一段及其之后的内容将被删除，然后重新往下写。", isPresented: Binding(get: { branching != nil }, set: { if !$0 { branching = nil } }),
                            titleVisibility: .visible, presenting: branching) { b in
            Button("删除并重写", role: .destructive) { act { _ = try Scenes.dropFrom(b.id) } }
        }
        .confirmationDialog("删除这一段。删除后无法恢复。", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { b in
            Button("删除", role: .destructive) { act { _ = try Scenes.dropBeat(b.id) } }
        }
        .confirmationDialog("删掉最后一段。删除后无法恢复。", isPresented: $dropLast, titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let b = lastBeat { act { _ = try Scenes.dropBeat(b.id) } } }
        }
        .confirmationDialog("这一卷的章纲还没有生成。先生成这一卷的章纲（调用一次接口），还是直接开始写这一章。",
                            isPresented: Binding(get: { askVolume != nil }, set: { if !$0 { askVolume = nil } }), titleVisibility: .visible, presenting: askVolume) { t in
            Button("先生成") { startNext(w, plan: t, volumeFirst: true) }
            Button("直接写") { startNext(w, plan: t, volumeFirst: false) }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好") { notice = nil } }
    }

    private struct EditKey: Identifiable { let id: String }

    // MARK: 菜单

    private func menu(_ w: Row) -> some View {
        Menu {
            if Works.chaptersOf(w.id).count > 1 { Button("目录") { nav.openWork(w.id) } }
            if canMore, let b = lastBeat {
                Button("重写最后一段") { write(rewrite: b.id) }.disabled(writing)
                Button("接着写") { write(more: true) }.disabled(writing)
            }
            if lastBeat != nil { Button("删掉最后一段", role: .destructive) { dropLast = true } }
            Button("这一篇的设定") { nav.push(.chapter(chapterId)) }
            Button("这一部的设定") { nav.push(.edit(w.id)) }
            Button("外观") { showLook = true }
            Button("收篇") { wrap() }
            if w.string("kind") == Works.SAGA { Button("下一章") { nextOpen = true } }
        } label: { SvgIcon(name: "more", size: 20, color: look.ink) }
        .accessibilityLabel("菜单")
    }

    // MARK: 滚动的那一份（明信片版式、生成中）

    private func feed(_ w: Row, _ ch: Row, _ next: [String]?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: look.paraGap * 1.6) {
                    header(w, ch)
                    ForEach(beats, id: \.id) { b in beatView(w, ch, b) }
                    if writing {
                        Text(live.isEmpty ? "正在写" : live)
                            .font(look.font()).foregroundStyle(live.isEmpty ? look.dim : look.ink)
                            .lineSpacing(look.lineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if told.isEmpty {
                        emptyStart(w)
                    } else if let next {
                        endNextPanel(w, ch, next)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, Theme.sp5)
                .padding(.vertical, Theme.sp6)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: beats.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: live) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    private func header(_ w: Row, _ ch: Row) -> some View {
        let facts = [ch.string("place"), Works.timeOf(ch.id)].filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 6) {
            Text(Works.chapterTitle(w, ch)).font(look.font(15)).foregroundStyle(look.ink)
            if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(look.dim) }
            look.line.frame(height: 1).padding(.top, 4)
        }
    }

    private func emptyStart(_ w: Row) -> some View {
        VStack(alignment: .leading, spacing: Theme.sp3) {
            Text("这一篇还没有正文。").font(.system(size: 13)).foregroundStyle(look.dim)
            HStack(spacing: Theme.sp4) {
                Button(w.bool("solo") ? "让它开篇" : "让\(charName)开场") { write() }
                    .buttonStyle(EiraButtonStyle(kind: .primary))
                Button("我先写") { director = false; typing = true }
                    .foregroundStyle(look.ink)
            }
            Text("每写一段调用一次接口。").font(.system(size: 12)).foregroundStyle(look.dim)
        }
    }

    @ViewBuilder
    private func beatView(_ w: Row, _ ch: Row, _ b: Row) -> some View {
        if b.string("role") == Scenes.DIRECTOR {
            HStack(alignment: .top, spacing: 6) {
                Text(b.bool("hold") ? "场外指示 · 一直有效" : "场外指示").font(.system(size: 12)).foregroundStyle(look.mark)
                Text(b.string("text")).font(.system(size: 13)).foregroundStyle(look.dim)
            }
            .padding(Theme.sp2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(look.line))
            .contextMenu {
                Button(b.bool("hold") ? "改为只管紧接着的一段" : "改为一直有效") { act { _ = try Scenes.updateBeat(b.id, ["hold": .bool(!b.bool("hold"))]) } }
                Button("删除", role: .destructive) { act { _ = try Scenes.dropBeat(b.id) } }
            }
        } else {
            let sign = Works.signOf(b, chapter: ch, work: w)
            VStack(alignment: .leading, spacing: Theme.sp2) {
                signLine(sign, pinned: b.bool("pinned"))
                Text(Scenes.withTrans(b.string("text"), b["trans"]?.array ?? []))
                    .font(look.font()).foregroundStyle(look.ink)
                    .lineSpacing(look.lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                versionsBar(b)
                if look.sign == "full" { look.line.frame(height: 1).padding(.top, Theme.sp2) }
            }
            .contextMenu { beatMenu(b) }
        }
    }

    @ViewBuilder
    private func signLine(_ sign: Scenes.Sign, pinned: Bool) -> some View {
        if look.sign != "none" {
            HStack(spacing: Theme.sp2) {
                if look.sign == "full" && !sign.face.isEmpty { Avatar(imageId: sign.face, name: sign.name, size: 24) }
                Text(sign.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(look.ink)
                if !sign.time.isEmpty { Text(sign.time).font(.system(size: 12)).foregroundStyle(look.dim) }
                if pinned { Text("已钉住").font(.system(size: 11)).foregroundStyle(look.mark) }
            }
        }
    }

    @ViewBuilder
    private func versionsBar(_ b: Row) -> some View {
        let n = Scenes.versions(b).count
        if n > 1 {
            let idx = Scenes.swipeIndex(b)
            HStack(spacing: Theme.sp3) {
                Button { act { _ = try Scenes.pickSwipe(b.id, idx - 1) } } label: { Image(systemName: "chevron.left") }.disabled(idx == 0 || writing)
                Text("\(idx + 1) / \(n)").font(.system(size: 12)).foregroundStyle(look.dim)
                Button { act { _ = try Scenes.pickSwipe(b.id, idx + 1) } } label: { Image(systemName: "chevron.right") }.disabled(idx >= n - 1 || writing)
            }
            .foregroundStyle(look.ink)
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func beatMenu(_ b: Row) -> some View {
        Button("复制") { UIPasteboard.general.string = b.string("text") }
        Button("编辑") { editText = b.string("text"); editing = b }
        if b.string("role") == Scenes.CHAR { Button("重写") { write(rewrite: b.id) }.disabled(writing) }
        Button(b.bool("pinned") ? "取消钉住" : "钉住") { act { _ = try Scenes.togglePin(b.id) } }
        if Scenes.versions(b).count > 1 { Button("删这一版", role: .destructive) { act { _ = try Scenes.dropSwipe(b.id) } } }
        Button("分叉") { branching = b }
        Button("删除", role: .destructive) { removing = b }
    }

    // MARK: 结尾的后续选项（反馈 10）

    private func endNextPanel(_ w: Row, _ ch: Row, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.sp2) {
            Text("接下来").font(.system(size: 12)).foregroundStyle(look.dim)
            ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                Button { pickNext(w, ch, Self.keys[min(i, 2)], t) } label: {
                    HStack(alignment: .top, spacing: Theme.sp2) {
                        Text(Self.keys[min(i, 2)]).font(.system(size: 13, weight: .semibold))
                        Text(t).font(.system(size: 14)).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(look.ink)
                    .padding(Theme.sp2)
                    .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(look.line))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: Theme.sp2) {
                Text("D").font(.system(size: 13, weight: .semibold)).foregroundStyle(look.ink)
                TextField("自己写一个走向", text: $ownNext)
                Button { pickNext(w, ch, "D", ownNext) } label: { SvgIcon(name: "send", size: 16, color: look.ink) }
                    .disabled(ownNext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("用这个写下一篇")
            }
            Text("选择后新建下一篇，所选内容作为该篇的走向写入提示词。").font(.system(size: 12)).foregroundStyle(look.dim)
        }
    }

    private func pickNext(_ w: Row, _ ch: Row, _ letter: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var e = ch["endNext"]?.object ?? [:]
        e["picked"] = .string(letter)
        do { try Works.updateChapter(ch.id, ["endNext": .object(e)]) } catch { problem = "保存失败：\(error.localizedDescription)"; return }
        ownNext = ""
        if w.string("kind") == Works.SAGA, Novel.hasOutline(w), Novel.volumeMissing(Novel.outlineOf(w), Works.nextNo(w.id)) != nil {
            askVolume = t
            return
        }
        startNext(w, plan: t, volumeFirst: false)
    }

    private func startNext(_ w: Row, plan: String, volumeFirst: Bool) {
        let id = w.id, from = chapterId
        Task { @MainActor in
            if volumeFirst, let cur = Works.get(id), let miss = Novel.volumeMissing(Novel.outlineOf(cur), Works.nextNo(id)) {
                do { try Novel.applyVolume(id, miss.no, try await WorkTasks.volume(cur, miss)) } catch { problem = error.localizedDescription }
            }
            do {
                let saga = w.string("kind") == Works.SAGA
                let line = saga ? Novel.lineOf(Novel.outlineOf(Works.get(id)), Works.nextNo(id)) : nil
                if let row = try Works.addChapter(id, title: line?.title ?? "", plan: plan, planFrom: "end", fromChapterId: from) {
                    nav.push(.read(row.id))
                }
            } catch { problem = "新建失败：\(error.localizedDescription)" }
            reload()
        }
    }

    // MARK: 翻页

    private struct Leaf: Identifiable {
        let id: String
        let beat: Row
        let text: String
        let first: Bool
    }

    private func leaves(_ w: Row, _ ch: Row) -> [Leaf] {
        let n = Int(stageCfg["pageChars"]?.number ?? 700)
        var out: [Leaf] = []
        for b in told {
            let shown = Scenes.withTrans(b.string("text"), b["trans"]?.array ?? [])
            for (i, t) in Stage.pages(shown, max: n).enumerated() { out.append(Leaf(id: "\(b.id)#\(i)", beat: b, text: t, first: i == 0)) }
        }
        return out
    }

    private func pager(_ w: Row, _ ch: Row, _ next: [String]?) -> some View {
        let list = leaves(w, ch)
        let tap = stageCfg["tapTurn"]?.bool != false
        return VStack(spacing: 0) {
            TabView(selection: $pageAt) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, leaf in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.sp3) {
                            if i == 0 { header(w, ch) }
                            if leaf.first { signLine(Works.signOf(leaf.beat, chapter: ch, work: w), pinned: leaf.beat.bool("pinned")) }
                            Text(leaf.text).font(look.font()).foregroundStyle(look.ink).lineSpacing(look.lineSpacing)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if i == list.count - 1 {
                                versionsBar(leaf.beat)
                                if let next { endNextPanel(w, ch, next) }
                            }
                        }
                        .padding(.horizontal, Theme.sp5).padding(.vertical, Theme.sp6)
                    }
                    .contextMenu { beatMenu(leaf.beat) }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // 点两侧翻页（关掉之后左右滑动照常翻页，网页版 4.706）
            .overlay {
                if tap {
                    HStack(spacing: 0) {
                        Color.clear.contentShape(Rectangle()).frame(width: 56)
                            .onTapGesture { withAnimation { pageAt = max(0, pageAt - 1) } }
                        Spacer(minLength: 0).allowsHitTesting(false)
                        Color.clear.contentShape(Rectangle()).frame(width: 56)
                            .onTapGesture { withAnimation { pageAt = min(list.count - 1, pageAt + 1) } }
                    }
                }
            }
            Text("\(min(pageAt, max(0, list.count - 1)) + 1) / \(list.count)").font(.system(size: 12)).foregroundStyle(look.dim)
                .padding(.vertical, Theme.sp2)
        }
        .onAppear { pageAt = max(0, list.count - 1) }
        .onChange(of: list.count) { _, n in pageAt = max(0, n - 1) }
    }

    // MARK: 底栏

    private func composer(_ w: Row) -> some View {
        VStack(spacing: Theme.sp2) {
            HStack {
                Picker("写的是", selection: $director) {
                    Text("我这一段").tag(false)
                    Text("场外指示").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                Spacer()
                if director { Toggle("一直有效", isOn: $hold).toggleStyle(.button).font(.system(size: 13)) }
            }
            HStack(alignment: .bottom, spacing: Theme.sp2) {
                TextField(director ? "写给角色的指示，不出现在正文里" : "写我这一段", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
                if writing {
                    Button { job?.cancel() } label: { Image(systemName: "stop.circle").font(.title2) }
                        .accessibilityLabel("停止")
                } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { write() } label: { Image(systemName: "text.append").font(.title2) }
                        .accessibilityLabel(w.bool("solo") ? "让它往下写" : "让\(charName)往下写")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .accessibilityLabel("发送")
                }
            }
            .foregroundStyle(look.ink)
            HelpNote("底栏写的是「我这一段」时，发送后角色接着写一段；输入框空着时点右侧的按钮，角色直接写下一段（「整篇由它写」开着时写的是整段）。「场外指示」作为指令写进提示词，不出现在正文里，只管紧接着的一段；勾选「一直有效」后整篇都生效。长按一段可以复制、编辑、重写、钉住、分叉或删除；重写不删旧的，在这一段下方左右切换版本。每写一段调用一次接口。", title: "我们：写正文")
        }
        .padding(.horizontal, Theme.sp4)
        .padding(.vertical, Theme.sp3)
        .background(look.bg)
        .overlay(alignment: .top) { look.line.frame(height: 1) }
    }

    private var editSheet: some View {
        NavigationStack {
            Form {
                TextField("正文", text: $editText, axis: .vertical).lineLimit(6...40)
                Text("\(editText.filter { !$0.isWhitespace }.count) 字").font(.footnote).foregroundStyle(Theme.text2)
            }
            .navigationTitle("编辑这一段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let b = editing {
                            if editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                problem = "内容不能为空。如需移除请使用删除"
                            } else { act { _ = try Scenes.editBeat(b.id, editText) } }
                        }
                        editing = nil
                    }
                }
            }
        }
    }

    // MARK: 动作

    private func act(_ f: () throws -> Void) {
        do { try f(); reload() } catch { problem = "操作失败：\(error.localizedDescription)" }
    }

    private func reload() {
        chapter = Works.getChapter(chapterId)
        work = chapter.flatMap { Works.get($0.string("workId")) }
        beats = Scenes.beatsOf(chapterId)
        stageCfg = Works.stageOf(work, chapter)
        look = Stage.look(stageCfg)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            if director {
                try Scenes.addBeat(sceneId: chapterId, role: Scenes.DIRECTOR, text: text, hold: hold)
                draft = ""
                hold = false
                director = false
                reload()
                return
            }
            try Scenes.addBeat(sceneId: chapterId, role: Scenes.ME, authorId: "me", text: text)
            draft = ""
            reload()
            write()
        } catch {
            problem = "写入失败，这一段未保存：\(error.localizedDescription)"
        }
    }

    private func write(more: Bool = false, rewrite: String = "") {
        guard !writing else { return }
        writing = true
        live = ""
        problem = nil
        typing = false
        let id = chapterId
        job = Task { @MainActor in
            do {
                _ = try await WorkRun.write(chapterId: id, more: more, rewrite: rewrite) { text in
                    Task { @MainActor in live = text }
                }
            } catch is CancellationError {
            } catch let e as AIError where e.cancelled {
            } catch {
                problem = error.localizedDescription
            }
            writing = false
            live = ""
            reload()
        }
    }

    /// 收篇：把这一篇压成一段摘要，后面几篇的设定区里带上它。开关在「设置 - 用量与上限」，默认关
    private func wrap() {
        guard WorkTasks.summaryOn() else { notice = "收篇摘要尚未开启。可在「设置 - 用量与上限」中开启"; return }
        let id = chapterId
        Task { @MainActor in
            do {
                let text = try await WorkTasks.wrap(id)
                notice = text.isEmpty ? "没有可供摘要的内容" : "已生成摘要"
                reload()
            } catch { problem = "生成摘要失败：\(error.localizedDescription)" }
        }
    }
}
