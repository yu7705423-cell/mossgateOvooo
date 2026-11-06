import SwiftUI

/// 按 Markdown 画一段（网页版 ui/markdown.js）：块由 MarkdownBlocks 切，行内的粗体、斜体、行内代码、链接交给 AttributedString。
/// 只画文字，不跑网页、不取网络图片。代码块里的长行折行（网页版 4.880）
struct MarkdownView: View {
    let text: String
    var size: CGFloat = 15
    var color: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sp2) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }

    @ViewBuilder private func block(_ b: MarkdownBlocks.Block) -> some View {
        switch b {
        case .heading(let level, let t):
            inline(t).font(.system(size: size + CGFloat(max(0, 4 - level)) * 2 + 1, weight: .semibold)).foregroundStyle(color)
        case .paragraph(let t):
            inline(t).font(.system(size: size)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").font(.system(size: size)).foregroundStyle(Theme.text3)
                        inline(it).font(.system(size: size)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .ordered(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(start + i).").font(.system(size: size).monospacedDigit()).foregroundStyle(Theme.text3)
                        inline(it).font(.system(size: size)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let t):
            HStack(spacing: Theme.sp2) {
                Rectangle().fill(Theme.border).frame(width: 3)
                inline(t).font(.system(size: size)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
        case .code(_, let t):
            Text(t).font(.system(size: size - 2, design: .monospaced)).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.sp2)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1)
        case .table(let rows):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    inline(r.joined(separator: "  |  "))
                        .font(.system(size: size - 1, weight: i == 0 ? .semibold : .regular)).foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.sp2)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
