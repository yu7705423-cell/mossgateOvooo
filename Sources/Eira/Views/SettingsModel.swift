import SwiftUI

/// 设置这一份 kv 在界面上的唯一入口。各页从这里读、经这里写，改完别的页面（主题、接口）跟着变。
///
/// 写之前一律重新读一遍库（`loadForWrite`）：读失败就不写，在屏幕上说。拿读失败时的空设置写回去，
/// 接口与密钥会全部没了（网页版第 20 条）。
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    @Published private(set) var s = AppSettings.load()
    @Published var problem: String?

    func reload() { s = AppSettings.load() }

    func update(_ change: (inout AppSettings) -> Void) {
        var next: AppSettings
        do { next = try AppSettings.loadForWrite() }
        catch { problem = "设置读取失败，这一项未保存：\(error.localizedDescription)"; return }
        change(&next)
        do {
            try next.save()
            s = next
            problem = nil
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
            Problems.report("设置保存失败：\(error.localizedDescription)")
        }
    }

    func set(_ key: String, _ value: JSONValue?) {
        update { $0.raw[key] = value }
    }

    // MARK: - 绑定

    /// 开关。def 是网页版 DEFAULT_SETTINGS 里的默认值。
    func bool(_ key: String, _ def: Bool) -> Binding<Bool> {
        Binding(get: { self.s.raw[key]?.bool ?? def },
                set: { self.set(key, .bool($0)) })
    }

    /// 数字。0 也照写，含义由各项自己说明（多数是「不限」）。
    func number(_ key: String, _ def: Double) -> Binding<Double> {
        Binding(get: { self.s.raw[key]?.number ?? def },
                set: { self.set(key, .number($0)) })
    }

    /// 文字。
    func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { self.s.raw[key]?.string ?? "" },
                set: { self.set(key, .string($0)) })
    }

    /// services 里某一项的一个字段。
    func service(_ name: String, _ field: String) -> Binding<String> {
        Binding(get: { self.s.raw["services"]?.object?[name]?.object?[field]?.string ?? "" },
                set: { v in self.update { $0.setService(name, [field: .string(v)]) } })
    }
}

/// 一行数字输入。空着表示用 placeholder 说的那个意思（多数是 0，即不限）。
struct NumberRow: View {
    let title: String
    @Binding var value: Double
    var unit = ""
    var placeholder = "0"
    var range: ClosedRange<Double> = 0...Double(Int32.max)

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                .focused($focused)
                .onSubmit(commit)
            if !unit.isEmpty { Text(unit).foregroundStyle(Theme.secondaryText) }
        }
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { _, v in if !focused { text = Self.format(v) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        let n = t.isEmpty ? 0 : (Double(t) ?? value)
        let clamped = min(max(n, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
        text = Self.format(clamped)
    }

    static func format(_ v: Double) -> String {
        v == 0 ? "" : (v == v.rounded() ? String(Int(v)) : String(v))
    }
}

/// 读不出来、写不进去时那一行红字。
struct ProblemSection: View {
    let text: String?
    var body: some View {
        if let text {
            Section { Text(text).foregroundStyle(Theme.danger) }
        }
    }
}
