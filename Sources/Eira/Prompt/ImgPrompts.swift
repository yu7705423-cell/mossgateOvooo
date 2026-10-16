import Foundation

/// 生图提示词的预设（网页版 system/imgprompts.js，ARCHITECTURE 4.522）。全局一份清单，每个角色各一份清单。
///
/// 真正拼进提示词的仍然只是那一栏文字（settings.imagePrompt / character.imagePrompt），ImageGen 一行不用改；
/// 预设只是存起来的几段，点一份即把那一栏换成它。删掉一份预设不影响那一栏里正在用的文字。
/// 记一个「当前是哪一份」（…PresetId），界面据此标出选中，以及「改过了还没存回去」。
///
/// 字段与网页版一字不差：`imagePromptPresets`（[{ id, name, text }]）、`imagePromptPresetId`、`imagePrompt`，
/// 全局的在设置里，角色的在角色卡上。这里只读一份记录、算出要写回的字段，写由调用方经各自的出口（设置 / People.update）。
enum ImgPrompts {
    static let listKey = "imagePromptPresets"
    static let curKey = "imagePromptPresetId"
    static let textKey = "imagePrompt"

    struct Preset: Equatable, Identifiable, Sendable {
        let id: String
        var name: String
        var text: String
    }

    struct State: Equatable {
        var rows: [Preset]
        var current: Preset?
        var text: String
        /// 当前那份被改过、尚未存回
        var dirty: Bool { current.map { $0.text != text } ?? false }
        /// 那一栏里的文字是否已存进某一份
        var known: Bool { rows.contains { $0.text == text } }
    }

    /// 读一份记录（设置的 raw 或角色卡的 row）。get 按字段名取值
    static func state(_ get: (String) -> JSONValue?) -> State {
        let rows = clean(get(listKey))
        let cur = get(curKey)?.string ?? ""
        return State(rows: rows, current: rows.first(where: { $0.id == cur }), text: get(textKey)?.string ?? "")
    }

    /// 网页版 clean：没有 id 的丢掉，名字空着记作「未命名」
    static func clean(_ v: JSONValue?) -> [Preset] {
        (v?.array ?? []).compactMap { x -> Preset? in
            guard let o = x.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
            let name = (o["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Preset(id: id, name: name.isEmpty ? "未命名" : name, text: o["text"]?.string ?? "")
        }
    }

    static func encode(_ rows: [Preset]) -> JSONValue {
        .array(rows.map { .object(["id": .string($0.id), "name": .string($0.name), "text": .string($0.text)]) })
    }

    /// 当前那一栏存成一份新预设，并标成当前
    static func saveAs(_ st: State, name: String) -> (patch: [String: JSONValue], row: Preset) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = Preset(id: Ids.make("ipp"), name: n.isEmpty ? "预设 \(st.rows.count + 1)" : n, text: st.text)
        return ([listKey: encode(st.rows + [row]), curKey: .string(row.id)], row)
    }

    /// 当前那一栏写回当前那份预设；没有当前那份回 nil
    static func overwrite(_ st: State) -> [String: JSONValue]? {
        guard let cur = st.current else { return nil }
        return [listKey: encode(st.rows.map { $0.id == cur.id ? Preset(id: $0.id, name: $0.name, text: st.text) : $0 })]
    }

    /// 套用一份：那一栏换成它的文字
    static func apply(_ st: State, id: String) -> [String: JSONValue]? {
        guard let row = st.rows.first(where: { $0.id == id }) else { return nil }
        return [curKey: .string(row.id), textKey: .string(row.text)]
    }

    static func rename(_ st: State, id: String, name: String) -> [String: JSONValue]? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        return [listKey: encode(st.rows.map { $0.id == id ? Preset(id: $0.id, name: n, text: $0.text) : $0 })]
    }

    /// 只删这一份；那一栏里正在用的文字不动
    static func remove(_ st: State, id: String) -> [String: JSONValue] {
        var p: [String: JSONValue] = [listKey: encode(st.rows.filter { $0.id != id })]
        if st.current?.id == id { p[curKey] = .string("") }
        return p
    }

    /// 切换到 row 之前要不要先确认：那一栏里有没存进任何一份的文字，切换后会被替换掉
    static func needsConfirm(_ st: State, to row: Preset) -> Bool {
        !st.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !st.known && st.text != row.text
    }
}
