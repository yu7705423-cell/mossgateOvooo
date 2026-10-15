import SwiftUI

/// 锁屏（网页版 screens/LockScreen.js）：打开应用时先显示时间、日期与未读的会话，上滑或点「上滑解锁」进入主界面。
/// 开关在「设置 - 主题 - 锁屏」（showLockScreen，与网页版同一个字段，没写过按开启）。
/// 原生版没有网页版那份应用内通知列表，这里列有未读的会话，点一条解锁并进入那段会话。
struct LockScreenView: View {
    let wallpaper: String
    var unlock: (_ openChat: String?) -> Void

    struct Note: Identifiable { var id: String; var title: String; var body: String; var count: Int }
    @State private var notes: [Note] = []
    @State private var drag: CGFloat = 0
    /// 设了锁屏密码：先要密码，对了再放开；点了哪一条先记着
    @State private var asking = false
    @State private var after: String?

    private var onImage: Bool { !wallpaper.isEmpty }

    var body: some View {
        GeometryReader { g in
            ZStack {
                Theme.bg.ignoresSafeArea()
                if onImage {
                    LocalImage(id: wallpaper, maxPixel: max(g.size.width, g.size.height) * 3)
                        .frame(width: g.size.width, height: g.size.height + g.safeAreaInsets.top + g.safeAreaInsets.bottom)
                        .clipped()
                        .ignoresSafeArea()
                }
                if asking {
                    VStack(spacing: 30) {
                        TimelineView(.periodic(from: .now, by: 20)) { ctx in
                            Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                                .font(.system(size: 44, weight: .thin).monospacedDigit())
                        }
                        PinGate(tint: onImage ? .white : Theme.text, onPass: { asking = false; unlock(after) },
                                onCancel: { after = nil; asking = false })
                    }
                    .foregroundStyle(onImage ? Color.white : Theme.text)
                    .padding(.top, 50)
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                VStack(spacing: 0) {
                    TimelineView(.periodic(from: .now, by: 20)) { ctx in
                        VStack(spacing: 6) {
                            Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                                .font(.system(size: 76, weight: .thin).monospacedDigit())
                            Text(Self.dateLine(ctx.date)).font(.system(size: 15))
                        }
                    }
                    .foregroundStyle(onImage ? Color.white : Theme.text)
                    .shadow(color: onImage ? .black.opacity(0.35) : .clear, radius: 3, y: 1)
                    .padding(.top, 70)

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(notes) { n in
                                Button { go(n.id) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        SvgIcon(name: "message", size: 16, color: Theme.text2)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(n.count > 1 ? "\(n.title)（\(n.count) 条）" : n.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                            if !n.body.isEmpty { Text(n.body).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(2) }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface.opacity(onImage ? 0.86 : 1)))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border, lineWidth: onImage ? 0 : 1))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.text)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 28)
                    }

                    Button { go(nil) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "chevron.up").font(.system(size: 16))
                            Text("上滑解锁").font(.system(size: 13))
                        }
                        .foregroundStyle(onImage ? Color.white : Theme.text2)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
                .offset(y: min(0, drag))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 12)
            .onChanged { v in drag = v.translation.height }
            .onEnded { v in
                if !asking && v.translation.height < -70 { go(nil) }
                withAnimation(.easeOut(duration: 0.2)) { drag = 0 }
            })
        .task { load() }
    }

    /// 设了密码先要密码
    private func go(_ chat: String?) {
        if PinLock.hasPin() { after = chat; asking = true } else { unlock(chat) }
    }

    static func dateLine(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .weekday], from: d)
        let week = Array("日一二三四五六")
        return "\(c.month ?? 1)月\(c.day ?? 1)日 星期\(week[max(0, min(6, (c.weekday ?? 1) - 1))])"
    }

    /// 当前身份下有未读的会话，最近的在前，最多八条
    private func load() {
        let s = AppSettings.load()
        let active = s.raw["activePersonaId"]?.string ?? ""
        var chats = ((try? Repo.chats()) ?? []).filter { $0.unread > 0 }
        let mine = chats.filter { $0.personaId == active }
        if !active.isEmpty { chats = mine }
        chats.sort { $0.lastMessageAt > $1.lastMessageAt }
        let showText = Notifier.showsText(s)
        notes = chats.prefix(8).map { c in
            let first = c.characterIds.first.flatMap { (try? Repo.character($0)) ?? nil }
            let title = c.isGroup ? (c.title.isEmpty ? "群聊" : c.title) : (first?.displayName ?? (c.title.isEmpty ? "会话" : c.title))
            let last = ((try? Repo.messages(chatId: c.id, limit: 1)) ?? []).last
            let body = showText ? (last.map { $0.isRecalled ? "撤回了一条消息" : $0.content } ?? "") : ""
            return Note(id: c.id, title: title, body: body, count: c.unread)
        }
    }
}
