import SwiftUI

/// 选一个回应（网页版 MsgMenu 的 ReactSheet，ARCHITECTURE 4.468）：最近用过的、网格里的一片，
/// 上面一个输入框，任何 emoji 都收。再选一次同一个即取消。整页，不叠在长按菜单上。
struct ReactPickerView: View {
    var onPick: (String) -> Void
    @State private var text = ""
    @ObservedObject private var settings = SettingsModel.shared

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sp4) {
                Text("在输入框中输入任意 emoji，或从下方选择。再次选择同一个即取消。")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                HStack(spacing: Theme.sp2) {
                    TextField("输入一个 emoji", text: $text)
                        .padding(.horizontal, Theme.sp3).padding(.vertical, Theme.sp2)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
                    Button("贴上") { onPick(text.trimmingCharacters(in: .whitespaces)) }
                        .buttonStyle(EiraButtonStyle(kind: .ghost))
                        .disabled(!Interact.isEmoji(text.trimmingCharacters(in: .whitespaces)))
                }
                let recent = Interact.recentReactions(settings.s)
                if !recent.isEmpty {
                    GroupTitle("最近使用")
                    grid(recent)
                }
                GroupTitle("全部")
                grid(Interact.grid)
            }
            .padding(Theme.sp4)
        }
        .background(Theme.bg)
        .navigationTitle("回应")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func grid(_ list: [String]) -> some View {
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(list, id: \.self) { e in
                Button { onPick(e) } label: {
                    Text(e).font(.system(size: 26)).frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
