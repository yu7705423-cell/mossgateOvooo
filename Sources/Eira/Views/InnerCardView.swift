import SwiftUI

/// 心声那张卡（心声「显示方式」选「打开一页」时，网页版 InnerSheet，ARCHITECTURE 4.274）。
///
/// 正中一张纸：上面是谁、什么时候；中间是那一句心声；底下写着第几张。左右翻到上一张、下一张，
/// 这段会话里以前的每一条都能翻到。点头像列出全部，点一条翻过去。
struct InnerCardView: View {
    let chatId: String
    let msgId: String
    let char: Character?

    @State private var all: [Message] = []
    @State private var i = 0
    @State private var listing = false

    /// 这段会话里有心声的角色消息，新的在前（网页版 extras.innerHistory）
    static func history(_ chatId: String) -> [Message] {
        ((try? Repo.messages(chatId: chatId)) ?? [])
            .filter { $0.role == .char && !($0.row["inner"]?.string ?? "").isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 卡上的字：心声、心声的译文、那一句说出口的话
    @MainActor @ViewBuilder private func cardText(_ cur: Message) -> some View {
        VStack(spacing: Theme.sp3) {
            Text(cur.row.string("inner")).font(.system(size: 17)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.center).lineSpacing(5)
            let trans = cur.row.string("innerTrans")
            if !trans.isEmpty {
                Text(trans).font(.system(size: 13)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
            }
            // 那一句有译文写译文（只看原文那一档除外），写全、换行，不截断（网页版 4.521、4.570）
            let said = SettingsModel.shared.s.raw["translateShow"]?.string == "orig" ? "" : cur.row.string("translation")
            Text(said.isEmpty ? cur.content : said).font(.system(size: 12)).foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        let name = char?.displayName ?? "角色"
        let cur = all.indices.contains(i) ? all[i] : nil
        VStack(spacing: Theme.sp4) {
            Button { listing.toggle() } label: {
                HStack(spacing: Theme.sp2) {
                    Avatar(imageId: char?.avatar ?? "", name: name, size: 28)
                    Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(listing ? "共 \(all.count) 条" : cur.map { Receipt.stampOf($0.createdAt) } ?? "")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("历史心声")
            Divider()
            if listing {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.sp3) {
                        ForEach(Array(all.indices), id: \.self) { k in
                            Button { i = k; listing = false } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Receipt.stampOf(all[k].createdAt)).font(.system(size: 11)).foregroundStyle(Theme.text3)
                                    Text(all[k].row.string("inner")).font(.system(size: 14))
                                        .foregroundStyle(k == i ? Theme.text : Theme.text2).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if let cur {
                // 写全之后可能超出一屏：放得下就居中，放不下从顶上开始滚动（网页版 4.570）
                ViewThatFits(in: .vertical) {
                    cardText(cur).frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView { cardText(cur).frame(maxWidth: .infinity).padding(.vertical, Theme.sp2) }
                }
            } else {
                Text("这段会话里还没有心声").font(.footnote).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !listing {
                HStack {
                    Button { i = min(all.count - 1, i + 1) } label: { SvgIcon(name: "chevronLeft", size: 16, color: Theme.text) }
                        .disabled(i >= all.count - 1).accessibilityLabel("上一张")
                    Spacer()
                    Text(all.isEmpty ? "" : "\(all.count - i) / \(all.count)")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text3)
                    Spacer()
                    Button { i = max(0, i - 1) } label: { SvgIcon(name: "chevronRight", size: 16, color: Theme.text) }
                        .disabled(i <= 0).accessibilityLabel("下一张")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.sp5)
        .background(Theme.bg)
        .onAppear {
            all = Self.history(chatId)
            i = max(0, all.firstIndex { $0.id == msgId } ?? 0)
        }
    }
}
