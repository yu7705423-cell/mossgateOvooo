import SwiftUI

/// 一次发好几张图：摞成一叠（网页版 ImageStack.js，ARCHITECTURE 4.98）。
///
/// 连着发的、同一个人发的那几张算一叠，中间夹了一句话就断开。带着状态的那几张不并进来
/// （还在生成的、出错的、还在识图的）：它们下面各自挂着一行说明，摞进叠里那行就没了。
/// 点这一叠换最上面那张；右下角「3 / 5」。展开就是平常的图片气泡，最后一张下面挂「收起这 N 张」。
enum ImageStacks {
    /// 能并进一叠的：有图、没有挂着状态
    static func stackable(_ m: Message) -> Bool {
        guard m.kind == "image", !m.imageId.isEmpty, !m.isError, !m.isRecalled else { return false }
        let media = m.row.string("media")
        let vision = m.row.string("vision")
        return media != "pending" && media != "error" && m.row.string("mediaError").isEmpty
            && vision != "pending" && vision != "error" && m.row.string("quoteText").isEmpty
    }

    /// 按顺序切成一段一段：单独一条，或者两张以上的一叠
    static func group(_ msgs: [Message]) -> [[Message]] {
        var out: [[Message]] = []
        for m in msgs {
            if stackable(m), var last = out.last, let head = last.first, stackable(head),
               head.role == m.role, head.authorId == m.authorId {
                last.append(m)
                out[out.count - 1] = last
            } else {
                out.append([m])
            }
        }
        return out
    }
}

/// 画出来的那一叠
struct ImageStackRow: View {
    let msgs: [Message]
    let mine: Bool
    let avatar: String
    let name: String
    var onOpen: (String) -> Void
    var onExpand: () -> Void

    @State private var top = 0

    var body: some View {
        HStack(alignment: .top, spacing: Theme.gap) {
            if mine { Spacer(minLength: 48) }
            if !mine { Avatar(imageId: avatar, name: name) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    ForEach(Array(order.enumerated().reversed()), id: \.element) { depth, i in
                        LocalImage(id: msgs[i].imageId, maxPixel: 600)
                            .frame(width: 168, height: 210)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous).strokeBorder(Theme.bg, lineWidth: 2))
                            .rotationEffect(.degrees(depth == 0 ? 0 : Double(depth) * (mine ? -4 : 4)), anchor: .bottom)
                            .offset(x: CGFloat(depth) * (mine ? -12 : 12), y: CGFloat(depth) * -4)
                    }
                    Text("\(top + 1) / \(msgs.count)")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .padding(6)
                }
                .contentShape(Rectangle())
                .onTapGesture { top = (top + 1) % msgs.count }
                .onLongPressGesture { onOpen(msgs[top].imageId) }
                .accessibilityElement()
                .accessibilityLabel("\(msgs.count) 张图片，当前第 \(top + 1) 张")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("点击查看下一张")
                Button("展开这 \(msgs.count) 张", action: onExpand)
                    .font(.footnote).foregroundStyle(Theme.text3).buttonStyle(.plain)
            }
            if !mine { Spacer(minLength: 48) }
        }
        .padding(.horizontal, Theme.pad)
    }

    /// 最上面那张在前，后面最多再漏两张
    private var order: [Int] {
        (0..<min(3, msgs.count)).map { (top + $0) % msgs.count }
    }
}
