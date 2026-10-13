import SwiftUI

/// 骨架阶段的首页：只证明这只 app 能编译、能启动。
struct RootView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Eiraowo")
                .font(.title2)
            Text("原生版骨架")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    RootView()
}
