import Foundation

/// 一条记录。`fields` 是它的全部字段，原样保存（见 JSONValue 开头那段）。
///
/// 网页版建记录时一律带 `id`、`createdAt`、`updatedAt`，后两个是毫秒时间戳（db/collection.js 的 create）。
struct Row: Identifiable, Equatable, Sendable {
    var fields: [String: JSONValue]

    init(fields: [String: JSONValue]) { self.fields = fields }

    init(data: Data) throws {
        guard case .object(let o) = try JSONValue.parse(data) else {
            throw StoreError(message: "库里有一条记录不是对象，已无法读取")
        }
        fields = o
    }

    /// 新建一条：和网页版同样的 id 写法（前缀加随机串）与时间戳。
    static func new(prefix: String, _ fields: [String: JSONValue] = [:]) -> Row {
        let now = Date().millis
        var f: [String: JSONValue] = ["id": .string(Ids.make(prefix)), "createdAt": .number(now), "updatedAt": .number(now)]
        f.merge(fields) { _, new in new }
        return Row(fields: f)
    }

    var id: String { fields["id"]?.string ?? "" }
    var created: Double? { fields["createdAt"]?.number }

    subscript(key: String) -> JSONValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    func string(_ key: String) -> String { fields[key]?.string ?? "" }
    func number(_ key: String) -> Double? { fields[key]?.number }
    func bool(_ key: String) -> Bool { fields[key]?.bool ?? false }
    func strings(_ key: String) -> [String] { fields[key]?.array?.compactMap(\.string) ?? [] }

    /// 改了之后要碰一下 updatedAt，和网页版的 update 一样。
    mutating func touch() { fields["updatedAt"] = .number(Date().millis) }

    func encoded() throws -> Data { try JSONValue.object(fields).encoded() }
}

extension Date {
    var millis: Double { (timeIntervalSince1970 * 1000).rounded() }
    init(millis: Double) { self.init(timeIntervalSince1970: millis / 1000) }
}

enum Ids {
    /// 网页版 store.js 的 uid：前缀、下划线、时间与随机数拼的短串。原生版只需要不撞，写法不必一字不差。
    static func make(_ prefix: String) -> String {
        let time = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let rand = String(UInt64.random(in: 0..<UInt64(1) << 40), radix: 36)
        return "\(prefix)_\(time)\(rand)"
    }
}
