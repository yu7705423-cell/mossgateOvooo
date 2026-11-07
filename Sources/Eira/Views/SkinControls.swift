import PhotosUI
import SwiftUI

// 编辑器里那一个个旋钮怎么画（网页版 apps/skin/Controls.js）。照着 SkinGen.Item 的 type 走，
// 这一层不认识任何具体的旋钮名：网页版加一项，这里不用改。

/// 一个旋钮。value 是这一项现在的值（没设过时是默认值），onChange 交回新值；空串表示回到默认
struct SkinControl: View {
    let item: SkinGen.Item
    let value: JSONValue
    /// 渐变与叠加那一项的摘要
    var paintSummary = ""
    var onChange: (JSONValue) -> Void

    var body: some View {
        switch item.type {
        case "switch":
            Toggle(item.label, isOn: Binding(get: { value.bool == true }, set: { onChange(.bool($0)) }))
        case "color":
            VStack(alignment: .leading, spacing: 6) {
                head
                GreySwatches(value: value.string ?? "", alpha: true) { onChange(.string($0)) }
            }
        case "num":
            SkinNumber(item: item, value: value, onChange: onChange)
        case "pick":
            if item.options.count <= 4 {
                VStack(alignment: .leading, spacing: 6) {
                    head
                    Picker(item.label, selection: Binding(get: { value.string ?? "" }, set: { onChange(.string($0)) })) {
                        ForEach(item.options, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } else {
                Picker(item.label, selection: Binding(get: { value.string ?? "" }, set: { onChange(.string($0)) })) {
                    ForEach(item.options, id: \.id) { Text($0.label).tag($0.id) }
                }
            }
        case "text":
            VStack(alignment: .leading, spacing: 6) {
                head
                if (item.rows ?? 0) > 1 {
                    TextEditor(text: Binding(get: { value.string ?? "" }, set: { onChange(.string($0)) }))
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .frame(minHeight: CGFloat(max(3, item.rows ?? 3)) * 20)
                } else {
                    TextField("留空表示不改", text: Binding(get: { value.string ?? "" }, set: { onChange(.string($0)) }))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            }
        case "image":
            SkinImageControl(item: item, value: value.string ?? "", onChange: { onChange(.string($0)) })
        case "paint":
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.label)
                    Spacer()
                    Text(paintSummary.isEmpty ? "未设置" : paintSummary).font(.system(size: 13)).foregroundStyle(Theme.text3)
                    if value.object != nil {
                        Button("清除") { onChange(.string("")) }.font(.footnote).buttonStyle(.borderless)
                    }
                }
                Text("多色渐变与叠加在网页版的编辑器中编辑，原生版照常显示。").font(.caption).foregroundStyle(Theme.text3)
            }
        default:
            LabeledContent(item.label, value: "原生版暂不支持这一项")
        }
    }

    private var head: some View {
        HStack {
            Text(item.label)
            Spacer()
            if changed {
                Button("默认") { onChange(.string("")) }.font(.footnote).buttonStyle(.borderless)
            }
        }
    }

    private var changed: Bool { value != item.def && !(value.string == "" && item.def.string == "") }
}

/// 数字：滑杆加一个数字框。数字框可以填出滑杆的范围（网页版第 13 条：不设上限）
struct SkinNumber: View {
    let item: SkinGen.Item
    let value: JSONValue
    var onChange: (JSONValue) -> Void
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    private var lo: Double { item.min ?? 0 }
    private var hi: Double { max(item.max ?? 100, lo + 1) }
    private var current: Double? { value.number ?? value.string.flatMap { Double($0) } }
    private var fallback: Double { item.def.number ?? lo }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.label)
                Spacer()
                TextField("默认", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .focused($focused)
                    .onSubmit(commit)
                    .font(.system(size: 14).monospacedDigit())
                if !item.unit.isEmpty { Text(item.unit).font(.system(size: 13)).foregroundStyle(Theme.text3) }
                if current != nil, value != item.def {
                    Button("默认") { onChange(.string("")) }.font(.footnote).buttonStyle(.borderless)
                }
            }
            Slider(value: Binding(get: { min(hi, max(lo, current ?? fallback)) },
                                  set: { onChange(.number(($0 * 10).rounded() / 10)) }),
                   in: lo...hi, step: hi - lo > 20 ? 1 : 0.5)
        }
        .onAppear(perform: sync)
        .onChange(of: value) { _, _ in if !focused { sync() } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func sync() {
        guard let n = current else { text = ""; return }
        text = n == n.rounded() ? String(Int(n)) : String(n)
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { onChange(.string("")); return }
        if let n = Double(t), n.isFinite { onChange(.number(n)) } else { sync() }
    }
}

/// 图片：从相册选一张内嵌（data:），或填 https 网址（网页版 PickImage 的前两条路；图床原生版没有）
struct SkinImageControl: View {
    let item: SkinGen.Item
    let value: String
    var onChange: (String) -> Void
    @State private var picked: PhotosPickerItem?
    @State private var link = ""
    @State private var problem: String?

    private var isLink: Bool { value.range(of: #"^https://[^\s"'()\\<>]{1,2000}$"#, options: .regularExpression) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.label)
                Spacer()
                if !value.isEmpty {
                    Button("移除") { link = ""; onChange("") }.font(.footnote).buttonStyle(.borderless)
                }
            }
            HStack(spacing: Theme.sp3) {
                if let img = Self.thumb(value) {
                    Image(uiImage: img).resizable().scaledToFit().frame(width: 44, height: 44)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.rXs))
                } else if isLink {
                    Image(systemName: "link").frame(width: 44, height: 44).foregroundStyle(Theme.text3)
                }
                PhotosPicker(selection: $picked, matching: .images) {
                    Text(value.isEmpty || isLink ? "选择图片" : "换一张")
                }
                .buttonStyle(.borderless)
            }
            TextField("或填写 https:// 开头的图片网址", text: $link)
                .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                .font(.system(size: 13))
                .onSubmit(typed)
            if let problem { Text(problem).font(.caption).foregroundStyle(Theme.danger) }
        }
        .onAppear { link = isLink ? value : "" }
        .onChange(of: picked) { _, it in
            guard let it else { return }
            picked = nil
            Task {
                do {
                    guard let data = try await it.loadTransferable(type: Data.self) else { return }
                    let url = try Self.dataURL(data)
                    await MainActor.run { link = ""; problem = nil; onChange(url) }
                } catch {
                    await MainActor.run { problem = "图片未能读取：\(error.localizedDescription)" }
                }
            }
        }
    }

    private func typed() {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { if isLink { onChange("") }; problem = nil; return }
        if t.range(of: #"^https://[^\s"'()\\<>]{1,2000}$"#, options: .regularExpression) != nil { problem = nil; onChange(t) }
        else { problem = "只认 https:// 开头、不含引号与括号的网址。" }
    }

    /// 存成多大（网页版 FRAME_MAX）：整张图放进 512 见方，不裁切，留得住透明
    static let maxSide: CGFloat = 512

    static func dataURL(_ data: Data) throws -> String {
        guard let img = UIImage(data: data) else { throw StoreError(message: "这张图读不出来") }
        let s = img.size
        let k = min(1, maxSide / max(s.width, s.height, 1))
        let size = CGSize(width: max(1, (s.width * k).rounded()), height: max(1, (s.height * k).rounded()))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = out.pngData() else { throw StoreError(message: "这张图转不成可嵌入的格式") }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    static func thumb(_ v: String) -> UIImage? {
        guard v.hasPrefix("data:image/"), let comma = v.firstIndex(of: ","),
              let data = Data(base64Encoded: String(v[v.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }
}
