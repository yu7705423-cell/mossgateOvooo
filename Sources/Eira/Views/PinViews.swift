import SwiftUI

/// 数字键盘（网页版 ui/pinpad.js）：几个圆点、十个数字与删除，输满就交出去
struct PinPad: View {
    let length: Int
    let note: String
    var wrong = false
    var disabled = false
    var onDone: (String) -> Void
    var tint: Color = Theme.text

    @State private var code = ""

    var body: some View {
        VStack(spacing: 22) {
            Text(note).font(.system(size: 14)).foregroundStyle(wrong ? Theme.danger : tint.opacity(0.75))
                .multilineTextAlignment(.center)
            HStack(spacing: 14) {
                ForEach(0..<length, id: \.self) { i in
                    Circle()
                        .strokeBorder(tint, lineWidth: 1)
                        .background(Circle().fill(i < code.count ? tint : .clear))
                        .frame(width: 12, height: 12)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 22), count: 3), spacing: 16) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "del"], id: \.self) { k in
                    if k.isEmpty {
                        Color.clear.frame(width: 76, height: 76)
                    } else {
                        Button { press(k) } label: {
                            Group {
                                if k == "del" { Image(systemName: "delete.left").font(.system(size: 20)) }
                                else { Text(k).font(.system(size: 28, weight: .light)) }
                            }
                            .frame(width: 76, height: 76)
                            .background(Circle().fill(k == "del" ? Color.clear : tint.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tint)
                        .accessibilityLabel(k == "del" ? "删除" : k)
                    }
                }
            }
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
        }
    }

    private func press(_ k: String) {
        if k == "del" { if !code.isEmpty { code.removeLast() }; return }
        guard code.count < length else { return }
        code += k
        if code.count == length {
            let done = code
            code = ""
            onDone(done)
        }
    }
}

/// 锁屏上要密码的那一层（网页版 LockScreen 的 PinGate）
struct PinGate: View {
    var tint: Color = Theme.text
    var onPass: () -> Void
    var onCancel: () -> Void

    @State private var wrong = false
    @State private var wait = PinLock.waitLeft()
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 20) {
            PinPad(length: PinLock.length(), note: note, wrong: wrong || wait > 0, disabled: wait > 0,
                   onDone: { code in
                       if PinLock.check(code) { onPass() } else { wrong = true; wait = PinLock.waitLeft() }
                   }, tint: tint)
            HStack(spacing: 40) {
                Button("忘记密码") { Task { await forgot() } }
                Button("取消", action: onCancel)
            }
            .font(.system(size: 14))
            .foregroundStyle(tint)
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger).multilineTextAlignment(.center) }
        }
        .task(id: wait) {
            guard wait > 0 else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            wait = PinLock.waitLeft()
        }
    }

    private var note: String {
        if wait > 0 { return "输错次数过多，\(wait) 秒后可再试" }
        if wrong { return "密码错误，已错 \(PinLock.failCount()) 次" }
        return "输入 \(PinLock.length()) 位锁屏密码"
    }

    private func forgot() async {
        guard await PinLock.verifyOwner() else {
            problem = "未通过验证。需要本机已设置面容 ID、触控 ID 或手机密码。"
            return
        }
        do {
            try PinLock.clear()
            SettingsModel.shared.reload()
            onPass()
        } catch {
            problem = "未能清除：\(error.localizedDescription)"
        }
    }
}

/// 「设置 - 主题 - 锁屏密码」：设、改、清（网页版 LockPinPage）
struct LockPinView: View {
    /// lockOff：从「关闭锁屏」进来，核对过后密码与锁屏一并关掉
    var lockOff = false
    var done: () -> Void = {}

    enum Step: Equatable { case verify, choose, confirm(String), finished(String) }

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .choose
    @State private var len = 4
    @State private var wrong = false
    @State private var problem: String?
    /// 核对旧密码之后要做的：改（choose）还是清（clear）
    @State private var afterVerify = "choose"

    var body: some View {
        VStack(spacing: 28) {
            switch step {
            case .verify:
                PinGate(onPass: { verified() }, onCancel: { dismiss() })
            case .choose:
                Picker("位数", selection: $len) {
                    Text("4 位").tag(4)
                    Text("6 位").tag(6)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                PinPad(length: len, note: "输入新的 \(len) 位密码", onDone: { step = .confirm($0) }).id("choose-\(len)")
            case .confirm(let first):
                PinPad(length: first.count, note: wrong ? "两次输入不一致，请重新输入" : "再输入一次", wrong: wrong, onDone: { second in
                    guard second == first else { wrong = true; step = .choose; return }
                    do {
                        try PinLock.set(second)
                        SettingsModel.shared.reload()
                        step = .finished("锁屏密码已设置，每次打开应用时需要输入。")
                    } catch { problem = error.localizedDescription }
                }).id("confirm")
            case .finished(let text):
                Text(text).multilineTextAlignment(.center)
                Button("完成") { done(); dismiss() }.buttonStyle(.bordered)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
            if case .choose = step, PinLock.hasPin() == false, !lockOff {
                Text("密码只保存在本机。忘记时可用面容 ID 或手机密码验证后清除。").font(.footnote).foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
            }
            // 已经核对过旧密码、正在设新的：也可以直接清掉
            if PinLock.hasPin() && !lockOff && step == .choose {
                Button("清除锁屏密码", role: .destructive) { afterVerify = "clear"; verified() }
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 20)
        .navigationTitle("锁屏密码")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if lockOff { afterVerify = "clear"; step = PinLock.hasPin() ? .verify : .finished("锁屏已关闭。") }
            else if PinLock.hasPin() { afterVerify = "choose"; step = .verify }
        }
    }

    private func verified() {
        if afterVerify == "clear" {
            do {
                try PinLock.clear(lockOff: lockOff)
                SettingsModel.shared.reload()
                step = .finished(lockOff ? "锁屏密码已清除，锁屏已关闭。" : "锁屏密码已清除。")
            } catch { problem = "未能清除：\(error.localizedDescription)" }
        } else {
            step = .choose
        }
    }
}
