import Foundation
import JavaScriptCore

/// 美化编辑器（生成器）：网页版 `system/skin-gen.js` 在 JavaScriptCore 里原样跑（docs/jscore-skin.md）。
///
/// 编辑器那一堆旋钮的定义（`groups`）、每组显示哪几项（`state`）、把设置编成一段 CSS（`emit`）都由网页版的代码算，
/// 原生不重抄一份：网页版加一组、改一项，下一次编译自动带进来。编出来的 CSS 与手写 CSS 一起交给 `CssSkin.compile`
/// 读成原生样式（`Skins.effectiveCss`），会话页照旧只有一条路。
///
/// 脚本是 `Resources/weblogic/shims.js`、`skin-host.js`、`skin.bundle.js`（编译时由 `scripts/sync-weblogic.mjs skin` 现打，
/// 不进仓库，随 app 打包，从不联网下载）。**包不在时**（复刻的仓库、打包失败）`available` 为假：编辑器只剩原生自己认的那几项
/// （`SkinEditView`：尺寸、气泡颜色、头像大小，`Skins.look` 照旧直接读这几项），存着的设置原样留着、写回时不丢。
///
/// 线程：一个 JSContext，第一次用时在自己的串行队列上建好，之后所有调用都在那条队列上排队。出错记进诊断记录，返回 nil。
final class SkinGen: @unchecked Sendable {
    static let shared = SkinGen()

    private let queue = DispatchQueue(label: "cn.eiraphone.skingen")
    // 以下几项只在 queue 上读写
    private var context: JSContext?
    private var api: JSValue?
    private var loadTried = false
    private var lastErrorStorage: String?
    private var errorCount = 0
    private var groupsCache: [Group]?
    private var emitCache: [String: String] = [:]

    /// 测试用：当作包不在（看退回原生的那条路）
    nonisolated(unsafe) static var forceMissing = false

    var lastError: String? { queue.sync { lastErrorStorage } }

    // MARK: - 旋钮的定义（网页版 GROUPS，去掉了函数）

    struct Option: Equatable, Hashable {
        let id: String
        let label: String
    }

    struct Item: Equatable {
        let id: String
        let label: String
        /// color、num、switch、pick、image、text、paint
        let type: String
        let def: JSONValue
        let unit: String
        let min: Double?
        let max: Double?
        let desc: String
        /// 收在「更多」里
        let more: Bool
        /// 文本框的行数（多行时有）
        let rows: Int?
        /// 有显示条件（前面某一项设了之后才出现）
        let cond: Bool
        let options: [Option]
    }

    struct Group: Equatable, Identifiable {
        let id: String
        let label: String
        let short: String
        let icon: String
        let desc: String
        /// 只在群聊（group）或面对面（face）里才有的那一块
        let scene: String
        let items: [Item]
    }

    struct Conflict: Equatable {
        let at: String
        let who: [String]
    }

    /// 一份设置下各组的情况（网页版 showItem、changedIn、groupValues、conflictsOf、weigh）
    struct State: Equatable {
        var visible: [String: [String]] = [:]
        var changed: [String: Int] = [:]
        var values: [String: [String: JSONValue]] = [:]
        /// 渐变与叠加那一项的摘要（「线性渐变 · 3 个色标」），键为「组.项」
        var paints: [String: String] = [:]
        var conflicts: [Conflict] = []
        /// 内嵌的图片几张、共多少字节；另有几处是网址
        var images = 0
        var bytes = 0
        var links = 0

        func value(_ g: String, _ i: String) -> JSONValue { values[g]?[i] ?? .string("") }
        func shows(_ g: String, _ i: String) -> Bool { visible[g]?.contains(i) ?? true }
        var touched: Bool { changed.values.contains { $0 > 0 } }
    }

    // MARK: - 入口

    /// 包在、加载得起来
    var available: Bool { groups() != nil }

    /// 全部分组。包不在或加载失败为 nil
    func groups() -> [Group]? {
        queue.sync {
            if Self.forceMissing { return nil }
            if let groupsCache { return groupsCache }
            guard let obj = callLocked("groups", nil)?.object, let list = obj["groups"]?.array else { return nil }
            let out = list.compactMap(Self.group)
            guard !out.isEmpty else { fail("groups 是空的"); return nil }
            groupsCache = out
            return out
        }
    }

    func state(_ gen: JSONValue?) -> State? {
        queue.sync {
            guard let o = callLocked("state", gen ?? .object([:]))?.object else { return nil }
            var s = State()
            for (g, v) in o["visible"]?.object ?? [:] { s.visible[g] = v.array?.compactMap(\.string) ?? [] }
            for (g, v) in o["changed"]?.object ?? [:] { s.changed[g] = Int(v.number ?? 0) }
            for (g, v) in o["values"]?.object ?? [:] { s.values[g] = v.object ?? [:] }
            for (k, v) in o["paints"]?.object ?? [:] { s.paints[k] = v.string ?? "" }
            s.conflicts = (o["conflicts"]?.array ?? []).map {
                Conflict(at: $0["at"]?.string ?? "", who: $0["who"]?.array?.compactMap(\.string) ?? [])
            }
            s.images = Int(o["weigh"]?["n"]?.number ?? 0)
            s.bytes = Int(o["weigh"]?["bytes"]?.number ?? 0)
            s.links = Int(o["weigh"]?["links"]?.number ?? 0)
            return s
        }
    }

    /// 这一份设置编出来的 CSS（网页版 emit）。一项都没调是空串；包不在或出错为 nil
    func emit(_ gen: JSONValue?) -> String? {
        guard let gen, let o = gen.object, !o.isEmpty else { return "" }
        guard let key = (try? gen.encoded()).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        return queue.sync {
            if Self.forceMissing { return nil }
            if let hit = emitCache[key] { return hit }
            guard let css = callLocked("emit", gen)?["css"]?.string else { return nil }
            if emitCache.count >= 32 { emitCache.removeAll() }
            emitCache[key] = css
            return css
        }
    }

    /// 打包时记下的网页版提交号
    var webCommit: String? {
        queue.sync {
            guard loadLocked() != nil else { return nil }
            return context?.evaluateScript("weblogic.skin.commit()")?.toString()
        }
    }

    // MARK: - 加载与调用

    private static func scriptURL(_ name: String) -> URL? {
        for bundle in [Bundle.main, Bundle(for: SkinGen.self)] {
            if let u = bundle.url(forResource: name, withExtension: "js", subdirectory: "weblogic")
                ?? bundle.url(forResource: name, withExtension: "js") { return u }
        }
        return nil
    }

    /// 包在不在（不加载）。设置页、说明里用
    static var bundled: Bool { !forceMissing && scriptURL("skin.bundle") != nil }

    /// 在 queue 上调用
    private func loadLocked() -> JSValue? {
        if Self.forceMissing { return nil }
        if let api { return api }
        if loadTried { return nil }
        loadTried = true
        let made: JSContext? = JSContext()
        guard let ctx = made else { fail("建不出 JSContext"); return nil }
        ctx.name = "skingen"
        ctx.exceptionHandler = { [weak self] _, exc in self?.fail("脚本异常：\(exc?.toString() ?? "未知")") }
        for name in ["shims", "skin-host", "skin.bundle"] {
            guard let url = Self.scriptURL(name), let src = try? String(contentsOf: url, encoding: .utf8) else {
                // 包不在是常事（复刻的仓库）：不当错误记
                if name != "skin.bundle" { fail("找不到 \(name).js") }
                return nil
            }
            let before = errorCount
            ctx.evaluateScript(src, withSourceURL: url)
            if errorCount != before { return nil }
        }
        guard let fn = ctx.objectForKeyedSubscript("weblogic")?.objectForKeyedSubscript("skin"), !fn.isUndefined else {
            fail("脚本里没有 weblogic.skin")
            return nil
        }
        context = ctx
        api = fn
        return fn
    }

    private func callLocked(_ method: String, _ arg: JSONValue?) -> JSONValue? {
        guard let api = loadLocked() else { return nil }
        var args: [Any] = []
        if let arg {
            guard let data = try? arg.encoded() else { fail("\(method)：设置无法编码"); return nil }
            args.append(String(decoding: data, as: UTF8.self))
        }
        guard let out = api.objectForKeyedSubscript(method)?.call(withArguments: args), out.isString, let text = out.toString(),
              let v = try? JSONValue.parse(Data(text.utf8)) else {
            fail("\(method) 没有返回 JSON")
            return nil
        }
        guard v["ok"]?.bool == true else {
            fail("\(method) 出错：\(v["error"]?.string ?? "未知")")
            return nil
        }
        return v
    }

    private func fail(_ message: String) {
        lastErrorStorage = message
        errorCount += 1
        Diagnostics.shared.record("skingen-failed", ["error": message])
    }

    private static func group(_ v: JSONValue) -> Group? {
        guard let id = v["id"]?.string, !id.isEmpty else { return nil }
        let items: [Item] = (v["items"]?.array ?? []).compactMap { it in
            guard let iid = it["id"]?.string, let type = it["type"]?.string else { return nil }
            return Item(id: iid, label: it["label"]?.string ?? iid, type: type, def: it["def"] ?? .string(""),
                        unit: it["unit"]?.string ?? "", min: it["min"]?.number, max: it["max"]?.number,
                        desc: it["desc"]?.string ?? "", more: it["more"]?.bool == true,
                        rows: it["rows"]?.number.map { Int($0) }, cond: it["cond"]?.bool == true,
                        options: (it["options"]?.array ?? []).compactMap { o in
                            o["id"]?.string.map { Option(id: $0, label: o["label"]?.string ?? $0) }
                        })
        }
        return Group(id: id, label: v["label"]?.string ?? id, short: v["short"]?.string ?? (v["label"]?.string ?? id),
                     icon: v["icon"]?.string ?? "", desc: v["desc"]?.string ?? "", scene: v["scene"]?.string ?? "", items: items)
    }
}
