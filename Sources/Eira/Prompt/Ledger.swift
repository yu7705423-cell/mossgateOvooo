import Foundation

extension Notification.Name {
    /// 账本、流水有了变化。记账与卡包的页面据此重读
    static let eiraLedgerChanged = Notification.Name("eira.ledgerChanged")
}

/// 记账（网页版 system/ledger.js，ARCHITECTURE 4.278、4.642、4.643、4.961）。逻辑照网页版一行一行搬过来，数据与网页版互通。
///
/// 三层：**账户**（谁有多少钱，内嵌在账本上）、**流水**（钱怎么动的，数据域 entries）、**动作**（手记、固定入账、亲属卡、申请、
/// 聊天里的转账）。动作只做一件事：生成流水。
///
/// **余额不入库，永远是流水折出来的。** 聊天里的转账、请客、代付、情侣账户的存入与动用也**不另存一份流水**：
/// 每次从会话里的消息现算（`chatEntries`）。所以那一轮被重新生成、那条消息被删掉，那笔钱跟着消失，不必有人负责撤销。
/// 收下又因删掉提示行而回到待收款的转账（`Interact.unsettle`）同理：消息的状态一变，余额就变。
///
/// 字段与默认值见 docs/web-fields.md「books 与 entries」。读一律经这里的视图，写只改动到的字段，不认得的字段原样留着。
enum Ledger {
    static let booksCollection = "books"
    static let entriesCollection = "entries"

    static let real = "real", play = "play"
    static let kinds = [real, play]
    static let me = "me", char = "char", joint = "joint"
    static let owners = [me, char, joint]
    /// 账户的种类（4.643）：空是普通账户，transit 是交通卡
    static let accountKinds = ["", "transit"]

    /// 网页版的真假：false、0、空串、null、没有都是假
    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0 && !n.isNaN
        case .string(let s)?: return !s.isEmpty
        case .array?, .object?: return true
        default: return false
        }
    }

    /// Number(v)，读不出来是 0（网页版 num）
    static func num(_ v: JSONValue?) -> Double {
        switch v {
        case .number(let n)?: return n.isFinite ? n : 0
        case .string(let s)?:
            let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return v.isFinite ? v : 0
        case .bool(let b)?: return b ? 1 : 0
        default: return 0
        }
    }

    /// 输入框里填的数（网页版 Number(v) || 0）
    static func parse(_ s: String) -> Double { num(JSONValue.string(s)) }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func base36(_ n: Double) -> String { String(Int64(n), radix: 36) }
    private static func rand36(_ n: Int) -> String {
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    // MARK: - 分类（4.642）

    struct Sub: Identifiable, Equatable {
        let id: String
        var label: String
        var custom = false
    }

    struct Cat: Identifiable, Equatable {
        let id: String
        var label: String
        var subs: [Sub]
        var custom = false
    }

    private static func s(_ id: String, _ label: String) -> Sub { Sub(id: id, label: label) }

    /// 内置的大类与小类。大类的 id 与网页版从前一样（老流水不用迁移）
    static let builtin: [Cat] = [
        Cat(id: "food", label: "餐饮", subs: [s("breakfast", "早餐"), s("lunch", "午餐"), s("dinner", "晚餐"), s("takeout", "外卖"),
                                             s("drink", "饮品"), s("snack", "零食"), s("fruit", "水果"), s("grocery", "买菜")]),
        Cat(id: "transit", label: "交通", subs: [s("metro", "地铁公交"), s("taxi", "打车"), s("fuel", "加油"), s("parking", "停车"),
                                                s("train", "火车"), s("flight", "机票"), s("bike", "单车")]),
        Cat(id: "shopping", label: "购物", subs: [s("clothes", "服饰"), s("beauty", "美妆"), s("digital", "数码"), s("daily", "日用"),
                                                 s("furnish", "家居"), s("books", "书籍")]),
        Cat(id: "home", label: "居住", subs: [s("rent", "房租"), s("utility", "水电燃气"), s("property", "物业"), s("phone", "话费网费"),
                                             s("repair", "维修")]),
        Cat(id: "fun", label: "娱乐", subs: [s("movie", "电影"), s("game", "游戏"), s("show", "演出"), s("sub", "会员订阅"),
                                            s("travel", "旅行"), s("sport", "运动")]),
        Cat(id: "health", label: "医疗", subs: [s("clinic", "看病"), s("medicine", "药品"), s("checkup", "体检")]),
        Cat(id: "social", label: "人情", subs: [s("gift", "礼物"), s("treat", "请客"), s("redpacket", "红包"), s("date", "约会")]),
        Cat(id: "study", label: "学习", subs: [s("course", "课程"), s("stationery", "文具"), s("exam", "考试")]),
        Cat(id: "pet", label: "宠物", subs: [s("petfood", "口粮"), s("petvet", "看病"), s("petstuff", "用品")]),
        Cat(id: "salary", label: "收入", subs: [s("wage", "工资"), s("bonus", "奖金"), s("parttime", "兼职"), s("invest", "理财"),
                                               s("gotred", "收红包")]),
        Cat(id: "transfer", label: "转账", subs: []),
        Cat(id: "other", label: "其他", subs: []),
    ]
    static var other: Cat { builtin[builtin.count - 1] }

    /// settings.ledgerCats：{ tops: [{ id, label, subs }], subs: { 大类id: [{ id, label }] } }，所有账本共用
    private static func customCats(_ st: AppSettings) -> (tops: [[String: JSONValue]], subs: [String: [[String: JSONValue]]]) {
        let c = st.raw["ledgerCats"]?.object ?? [:]
        let tops = (c["tops"]?.array ?? []).compactMap(\.object)
        var subs: [String: [[String: JSONValue]]] = [:]
        for (k, v) in c["subs"]?.object ?? [:] { subs[k] = (v.array ?? []).compactMap(\.object) }
        return (tops, subs)
    }

    private static func subOfJSON(_ o: [String: JSONValue], custom: Bool) -> Sub {
        Sub(id: o["id"]?.string ?? "", label: o["label"]?.string ?? "", custom: custom)
    }

    /// 全部大类：内置在前，自定义的接在「其他」前面，各自带上内置与自定义的小类
    static func categories(_ st: AppSettings = .load()) -> [Cat] {
        let c = customCats(st)
        func withSubs(_ t: Cat) -> Cat {
            var out = t
            out.subs = t.subs + (c.subs[t.id] ?? []).map { subOfJSON($0, custom: true) }
            return out
        }
        let mine = c.tops.map { t in
            withSubs(Cat(id: t["id"]?.string ?? "", label: t["label"]?.string ?? "",
                         subs: (t["subs"]?.array ?? []).compactMap(\.object).map { subOfJSON($0, custom: true) }, custom: true))
        }
        return builtin.dropLast().map(withSubs) + mine + [withSubs(other)]
    }

    static func categoryOf(_ id: String, _ st: AppSettings = .load()) -> Cat {
        categories(st).first { $0.id == id } ?? withOtherSubs(st)
    }

    private static func withOtherSubs(_ st: AppSettings) -> Cat { categories(st).last ?? other }

    /// 小类：不属于这个大类的不认
    static func subOf(_ catId: String, _ subId: String, _ st: AppSettings = .load()) -> Sub? {
        guard !subId.isEmpty else { return nil }
        return categoryOf(catId, st).subs.first { $0.id == subId }
    }

    /// 一笔显示成什么：有小类写小类，没有写大类
    static func labelOf(_ e: Entry, _ st: AppSettings = .load()) -> String {
        subOf(e.category, e.sub, st)?.label ?? categoryOf(e.category, st).label
    }

    private static func cid() -> String { "u" + base36(Date().millis) + rand36(3) }
    /// 有意截断：分类名排在一行标签里，网页版同样只留 8 个字（catName）
    private static func catName(_ v: String) -> String {
        String(v.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces).prefix(8))
    }

    private static func writeCats(_ tops: [[String: JSONValue]], _ subs: [String: [[String: JSONValue]]]) throws {
        var st = try AppSettings.loadForWrite()
        var o = st.raw["ledgerCats"]?.object ?? [:]
        o["tops"] = .array(tops.map { .object($0) })
        o["subs"] = .object(subs.mapValues { .array($0.map { .object($0) }) })
        st.raw["ledgerCats"] = .object(o)
        try st.save()
    }

    @discardableResult
    static func addCategory(_ label: String) throws -> Cat {
        let name = catName(label)
        guard !name.isEmpty else { throw StoreError(message: "请填写分类名") }
        let st = try AppSettings.loadForWrite()
        guard !categories(st).contains(where: { $0.label == name }) else { throw StoreError(message: "已经有这个分类") }
        let c = customCats(st)
        let top: [String: JSONValue] = ["id": .string(cid()), "label": .string(name), "subs": .array([])]
        try writeCats(c.tops + [top], c.subs)
        return Cat(id: top["id"]?.string ?? "", label: name, subs: [], custom: true)
    }

    @discardableResult
    static func addSub(_ catId: String, _ label: String) throws -> Sub {
        let name = catName(label)
        guard !name.isEmpty else { throw StoreError(message: "请填写分类名") }
        let st = try AppSettings.loadForWrite()
        let top = categoryOf(catId, st)
        guard top.id == catId else { throw StoreError(message: "这个分类已不存在") }
        guard !top.subs.contains(where: { $0.label == name }) else { throw StoreError(message: "这个分类下已经有它") }
        var c = customCats(st)
        let sub: [String: JSONValue] = ["id": .string(cid()), "label": .string(name)]
        c.subs[catId] = (c.subs[catId] ?? []) + [sub]
        try writeCats(c.tops, c.subs)
        return Sub(id: sub["id"]?.string ?? "", label: name, custom: true)
    }

    /// 改自定义的名字（大类或小类）。内置的不改
    static func renameCategory(_ id: String, _ label: String) throws {
        let name = catName(label)
        guard !name.isEmpty else { throw StoreError(message: "请填写分类名") }
        let c = customCats(try AppSettings.loadForWrite())
        let tops = c.tops.map { t -> [String: JSONValue] in
            var x = t
            if t["id"]?.string == id { x["label"] = .string(name) }
            return x
        }
        let subs = c.subs.mapValues { list in list.map { x -> [String: JSONValue] in
            var y = x
            if x["id"]?.string == id { y["label"] = .string(name) }
            return y
        } }
        try writeCats(tops, subs)
    }

    /// 删自定义的大类或小类。挂在它下面的流水照旧在：大类没了显示归「其他」，小类没了显示大类
    static func removeCategory(_ id: String) throws {
        let c = customCats(try AppSettings.loadForWrite())
        var subs: [String: [[String: JSONValue]]] = [:]
        for (k, list) in c.subs where k != id { subs[k] = list.filter { $0["id"]?.string != id } }
        try writeCats(c.tops.filter { $0["id"]?.string != id }, subs)
    }

    // MARK: - 视图

    struct Account: Identifiable, Equatable {
        var obj: [String: JSONValue]
        var id: String { obj["id"]?.string ?? "" }
        var name: String { obj["name"]?.string ?? "" }
        var owner: String { obj["owner"]?.string ?? "" }
        var secret: Bool { Ledger.truthy(obj["secret"]) }
        var pass: String { obj["pass"]?.string ?? obj["pass"]?.number.map { String(Int($0)) } ?? "" }
        var hint: String { obj["hint"]?.string ?? "" }
        var isUnlocked: Bool { obj["unlocked"]?.bool == true }
        var kind: String { obj["kind"]?.string ?? "" }
        /// 网页版 unlocked：不是私密的、或者解开过
        var open: Bool { !secret || isUnlocked }
    }

    struct Card: Identifiable, Equatable {
        var obj: [String: JSONValue]
        var id: String { obj["id"]?.string ?? "" }
        var from: String { obj["from"]?.string ?? "" }
        var to: String { obj["to"]?.string ?? "" }
        var limit: Double { Ledger.num(obj["limit"]) }
        var active: Bool { obj["active"]?.bool != false }
        var at: Double { Ledger.num(obj["at"]) }
    }

    struct Rule: Identifiable, Equatable {
        var obj: [String: JSONValue]
        var id: String { obj["id"]?.string ?? "" }
        var accountId: String { obj["accountId"]?.string ?? "" }
        var day: Double { Ledger.num(obj["day"]) }
        var amount: Double { Ledger.num(obj["amount"]) }
        var category: String { obj["category"]?.string ?? "" }
        var note: String { obj["note"]?.string ?? "" }
        var active: Bool { obj["active"]?.bool != false }
        var by: String { obj["by"]?.string ?? "" }
        var from: Double { Ledger.num(obj["from"]) }
    }

    struct Book: Identifiable, Equatable {
        var row: Row
        var id: String { row.id }
        var name: String { row.string("name") }
        var kind: String { row.string("kind") }
        var isReal: Bool { kind == Ledger.real }
        var chatId: String { row.string("chatId") }
        /// 这本账的币种；没有记的按设置里那一种（网页版 currency.get(undefined)）
        var code: String? { row.string("currency").isEmpty ? nil : row.string("currency") }
        var accounts: [Account] { (row["accounts"]?.array ?? []).compactMap(\.object).map(Account.init(obj:)) }
        var cards: [Card] { (row["cards"]?.array ?? []).compactMap(\.object).map(Card.init(obj:)) }
        var rules: [Rule] { (row["rules"]?.array ?? []).compactMap(\.object).map(Rule.init(obj:)) }
        var createdAt: Double { Ledger.num(row["createdAt"]) }
        var personaId: String { row.string("personaId") }
        /// 把余额告诉角色、余额不足时不予支付：默认开（网页版 injectOn / strictOn）
        var inject: Bool { row["inject"]?.bool != false }
        var strict: Bool { row["strict"]?.bool != false }
        /// 结算角色每天的花销：默认关（网页版 settleOn）
        var settle: Bool { Ledger.truthy(row["settle"]) }
        var charMoney: [String: JSONValue]? { row["charMoney"]?.object }
    }

    struct Entry: Identifiable, Equatable {
        var id: String
        var bookId: String
        var accountId: String
        var amount: Double
        var category: String
        var sub: String
        var note: String
        var at: Double
        var src: String
        var ref: String
        var pending: Bool
        var tripId: String
        /// 会话里现算的那几笔：哪一方动的钱、走了哪张亲属卡
        var by = ""
        var cardId = ""
        /// 库里的那一行；会话里现算的没有
        var stored = true

        init(row: Row) {
            id = row.id
            bookId = row.string("bookId")
            accountId = row.string("accountId")
            amount = Ledger.num(row["amount"])
            category = row.string("category")
            sub = row.string("sub")
            note = row.string("note")
            at = Ledger.num(row["at"])
            src = row.string("src")
            ref = row.string("ref")
            pending = Ledger.truthy(row["pending"])
            tripId = row.string("tripId")
        }

        init(id: String, bookId: String, accountId: String, amount: Double, note: String, at: Double, ref: String, by: String, cardId: String) {
            self.id = id; self.bookId = bookId; self.accountId = accountId; self.amount = amount
            category = "transfer"; sub = ""; self.note = note; self.at = at; src = "message"; self.ref = ref
            pending = false; tripId = ""; self.by = by; self.cardId = cardId; stored = false
        }
    }

    // MARK: - 账本

    private static var db: Database { .shared }

    static func changed() {
        Task { @MainActor in NotificationCenter.default.post(name: .eiraLedgerChanged, object: nil) }
    }

    static func all() -> [Book] {
        ((try? db.all(booksCollection)) ?? []).map(Book.init(row:)).sorted { $0.createdAt < $1.createdAt }
    }

    /// 账号隔离（4.961）：这个账号看得见的账本。跟着会话的账本算那段会话的账号，其余按建的时候记下的账号
    static func visible(viewer: String? = nil, settings st: AppSettings = .load()) -> [Book] {
        let ps = (try? Repo.personas()) ?? []
        return all().filter { b in
            let pid = b.chatId.isEmpty ? b.personaId : (((try? Repo.chat(b.chatId)) ?? nil)?.personaId ?? "")
            return Isolate.sees(personaId: pid, "wallet", viewer: viewer, all: ps, settings: st)
        }
    }

    static func get(_ id: String) -> Book? {
        guard !id.isEmpty else { return nil }
        return ((try? db.get(booksCollection, id: id)) ?? nil).map(Book.init(row:))
    }

    private static func patchBook(_ id: String, _ fields: [String: JSONValue]) throws {
        guard var row = try db.get(booksCollection, id: id) else { throw StoreError(message: "账本不存在") }
        for (k, v) in fields { row[k] = v }
        row.touch()
        try db.put(booksCollection, row)
        changed()
    }

    @discardableResult
    static func create(name: String = "", kind: String = play, chatId: String = "", currency code: String? = nil, start: Double = 0) throws -> Book {
        let k = kinds.contains(kind) ? kind : play
        let n = trim(name)
        let row = Row.new(prefix: "bk", [
            "name": .string(n.isEmpty ? (k == real ? "我的账本" : "未命名账本") : n),
            "kind": .string(k),
            "chatId": .string(chatId),
            "currency": .string(code ?? Interact.currency().code),
            "accounts": .array([]),
            "personaId": .string(Isolate.tagNow()),
        ])
        try db.put(booksCollection, row)
        // 一本新账至少要有一个账户，否则第一笔记不下去
        let mine = try addAccount(row.id, name: "现金", owner: me)
        if start > 0 { try seed(row.id, mine.id, start) }
        if !chatId.isEmpty { try ensureChar(row.id) }
        changed()
        guard let b = get(row.id) else { throw StoreError(message: "账本未能保存") }
        return b
    }

    /// 起始余额：一笔 src 为 seed 的流水。再设一次就换掉那一笔，不叠加
    @discardableResult
    static func seed(_ bookId: String, _ accountId: String, _ amount: Double) throws -> Row? {
        guard let book = get(bookId) else { throw StoreError(message: "账本不存在") }
        for e in entriesOf(bookId) where e.src == "seed" && e.accountId == accountId { try db.delete(entriesCollection, id: e.id) }
        let v = Interact.round(amount, book.code)
        guard v != 0 else { changed(); return nil }
        let row = Row.new(prefix: "en", [
            "bookId": .string(bookId), "accountId": .string(accountId), "amount": .number(v), "category": .string("other"),
            "note": .string("起始余额"), "at": .number(Date().millis), "src": .string("seed"), "ref": .string(""), "pending": .bool(false),
        ])
        try db.put(entriesCollection, row)
        changed()
        return row
    }

    /// 关联了对话的账本一定有角色的钱包。名字就是角色的名字；已经有的不动。顺带把从前的「共同账户」改叫「情侣账户」
    @discardableResult
    static func ensureChar(_ bookId: String) throws -> Account? {
        guard let book = get(bookId), !book.chatId.isEmpty else { return nil }
        let w = whoOf(bookId)
        if let j = book.accounts.first(where: { $0.owner == joint && $0.name == "共同账户" }) {
            try updateAccount(bookId, j.id, AccountPatch(name: "情侣账户"))
        }
        if let had = book.accounts.first(where: { $0.owner == char }) { return had }
        return try addAccount(bookId, name: w.char.isEmpty ? "角色" : w.char, owner: char)
    }

    /// 角色的钱生成过了吗。没生成过的视作「不知道有多少」：不注入余额、不拦支付
    static func charReady(_ bookId: String) -> Bool {
        guard let acc = defaultFor(bookId, char) else { return false }
        return allEntries(bookId).contains { $0.accountId == acc.id }
    }

    static func charMoneyOf(_ bookId: String) -> [String: JSONValue]? { get(bookId)?.charMoney }
    static func setCharMoney(_ bookId: String, _ info: JSONValue?) throws { try patchBook(bookId, ["charMoney": info ?? .null]) }

    struct BookPatch {
        var name: String?
        var kind: String?
        var chatId: String?
        var currency: String?
        var inject: Bool?
        var strict: Bool?
        var settle: Bool?
    }

    static func update(_ id: String, _ p: BookPatch) throws {
        var f: [String: JSONValue] = [:]
        if let v = p.name { f["name"] = .string(trim(v)) }
        if let v = p.kind, kinds.contains(v) { f["kind"] = .string(v) }
        if let v = p.chatId { f["chatId"] = .string(v) }
        if let v = p.currency { f["currency"] = .string(v) }
        if let v = p.inject { f["inject"] = .bool(v) }
        if let v = p.strict { f["strict"] = .bool(v) }
        if let v = p.settle { f["settle"] = .bool(v) }
        try patchBook(id, f)
        if let c = p.chatId, !c.isEmpty { try ensureChar(id) }
    }

    /// 删账本连同它的流水
    static func remove(_ id: String) throws {
        let cur = currentId()
        try db.deleteAll(entriesCollection, where: id)
        if cur == id { try setCurrent("") }
        try db.delete(booksCollection, id: id)
        changed()
    }

    /// 当前看的是哪一本：记在设置里（billBook），只认看得见的
    static func currentId(_ st: AppSettings = .load()) -> String {
        let id = st.raw["billBook"]?.string ?? ""
        let list = visible(settings: st)
        return !id.isEmpty && list.contains(where: { $0.id == id }) ? id : (list.first?.id ?? "")
    }

    static func current() -> Book? { get(currentId()) }

    static func setCurrent(_ id: String) throws {
        var st = try AppSettings.loadForWrite()
        st.raw["billBook"] = .string(id.isEmpty || get(id) == nil ? "" : id)
        try st.save()
        changed()
    }

    /// 至少有一本。第一次打开记账时建，不走迁移：不用记账的人不该凭空多一本
    @discardableResult
    static func ensure() throws -> Book? {
        if !visible().isEmpty { return current() }
        return try create(name: "我的账本", kind: real)
    }

    // MARK: - 账户（内嵌在账本上）

    static func accountsOf(_ id: String) -> [Account] { get(id)?.accounts ?? [] }
    static func accountOf(_ id: String, _ accId: String) -> Account? { accountsOf(id).first { $0.id == accId } }

    private static func writeAccounts(_ id: String, _ list: [Account]) throws { try patchBook(id, ["accounts": .array(list.map { .object($0.obj) })]) }

    @discardableResult
    static func addAccount(_ id: String, name: String, owner: String = me, secret: Bool = false, pass: String = "", hint: String = "", kind: String = "") throws -> Account {
        guard get(id) != nil else { throw StoreError(message: "账本不存在") }
        let n = trim(name)
        let acc = Account(obj: [
            "id": .string("ac" + base36(Date().millis) + rand36(4)),
            "name": .string(n.isEmpty ? "未命名" : n),
            "owner": .string(owners.contains(owner) ? owner : me),
            "secret": .bool(secret),
            // 有意截断：私密账户的密码，网页版同样只留 12 位
            "pass": .string(String(trim(pass).prefix(12))),
            "hint": .string(trim(hint)),
            "unlocked": .bool(false),
            "kind": .string(accountKinds.contains(kind) ? kind : ""),
        ])
        try writeAccounts(id, accountsOf(id) + [acc])
        return acc
    }

    struct AccountPatch {
        var name: String?
        var owner: String?
        var secret: Bool?
        var pass: String?
        var hint: String?
        var unlocked: Bool?
    }

    @discardableResult
    static func updateAccount(_ id: String, _ accId: String, _ p: AccountPatch) throws -> Account? {
        let next = accountsOf(id).map { a -> Account in
            guard a.id == accId else { return a }
            var o = a.obj
            if let v = p.name { o["name"] = .string(trim(v)) }
            if let v = p.owner, owners.contains(v) { o["owner"] = .string(v) }
            if let v = p.secret { o["secret"] = .bool(v) }
            if let v = p.pass { o["pass"] = .string(String(trim(v).prefix(12))) }
            if let v = p.hint { o["hint"] = .string(trim(v)) }
            if let v = p.unlocked { o["unlocked"] = .bool(v) }
            return Account(obj: o)
        }
        try writeAccounts(id, next)
        return accountOf(id, accId)
    }

    /// 删账户。它名下的流水一起删：留着就成了没有归属的钱
    static func removeAccount(_ id: String, _ accId: String) throws {
        for e in entriesOf(id) where e.accountId == accId { try db.delete(entriesCollection, id: e.id) }
        try writeAccounts(id, accountsOf(id).filter { $0.id != accId })
    }

    /// 从一个账户往另一个账户转钱（交通卡充值，4.643）：两笔，同一个 ref。src 为 move，收支统计不算
    @discardableResult
    static func moveBetween(_ bookId: String, _ fromId: String, _ toId: String, _ amount: Double, note: String = "") throws -> [Row] {
        let v = abs(amount.isFinite ? amount : 0)
        guard v != 0 else { throw StoreError(message: "请填写金额") }
        guard accountOf(bookId, fromId) != nil, accountOf(bookId, toId) != nil else { throw StoreError(message: "账户不存在") }
        guard fromId != toId else { throw StoreError(message: "请选择另一个账户") }
        let ref = "mv" + base36(Date().millis)
        let out = try add(bookId: bookId, accountId: fromId, amount: -v, category: "transfer", note: note.isEmpty ? "转出" : note, src: "move", ref: ref)
        let got = try add(bookId: bookId, accountId: toId, amount: v, category: "transfer", note: note.isEmpty ? "转入" : note, src: "move", ref: ref)
        return [out, got]
    }

    /// 这一类归属的默认账户：转账、外卖落到哪儿看它。先挑不私密的
    static func defaultFor(_ bookId: String, _ owner: String) -> Account? {
        let list = accountsOf(bookId)
        return list.first { $0.owner == owner && !$0.secret } ?? list.first { $0.owner == owner }
    }

    /// 这段会话绑的是哪一本账
    static func bookOfChat(_ chatId: String) -> Book? {
        guard !chatId.isEmpty else { return nil }
        return all().first { $0.chatId == chatId }
    }

    @discardableResult
    static func ensureJoint(_ bookId: String) throws -> Account {
        if let had = accountsOf(bookId).first(where: { $0.owner == joint }) { return had }
        return try addAccount(bookId, name: "情侣账户", owner: joint)
    }

    static func hasJoint(_ bookId: String) -> Bool { accountsOf(bookId).contains { $0.owner == joint } }

    // MARK: - 亲属卡（用掉多少不入库，见 chatEntries）

    static func cardsOf(_ bookId: String) -> [Card] { get(bookId)?.cards ?? [] }
    static func cardTo(_ bookId: String, _ owner: String) -> Card? { cardsOf(bookId).first { $0.to == owner && $0.active } }

    @discardableResult
    static func addCard(_ bookId: String, from: String, to: String, limit: Double) throws -> Card {
        guard let book = get(bookId) else { throw StoreError(message: "账本不存在") }
        let card = Card(obj: [
            "id": .string("cd" + base36(Date().millis) + rand36(4)),
            "from": .string(owners.contains(from) ? from : me),
            "to": .string(owners.contains(to) ? to : char),
            "limit": .number(Interact.round(abs(limit.isFinite ? limit : 0), book.code)),
            "active": .bool(true),
            "at": .number(Date().millis),
        ])
        // 同一个方向只留一张：再发一张就是换额度
        let rest = book.cards.filter { !($0.from == card.from && $0.to == card.to) }
        try patchBook(bookId, ["cards": .array((rest + [card]).map { .object($0.obj) })])
        return card
    }

    static func setCard(_ bookId: String, _ cardId: String, limit: Double? = nil, active: Bool? = nil) throws {
        let code = get(bookId)?.code
        let next = cardsOf(bookId).map { c -> JSONValue in
            guard c.id == cardId else { return .object(c.obj) }
            var o = c.obj
            if let l = limit { o["limit"] = .number(Interact.round(abs(l.isFinite ? l : 0), code)) }
            if let a = active { o["active"] = .bool(a) }
            return .object(o)
        }
        try patchBook(bookId, ["cards": .array(next)])
    }

    static func removeCard(_ bookId: String, _ cardId: String) throws {
        try patchBook(bookId, ["cards": .array(cardsOf(bookId).filter { $0.id != cardId }.map { .object($0.obj) })])
    }

    /// 这张卡已经被刷掉多少：扫一遍会话现算
    static func cardUsed(_ bookId: String, _ cardId: String) -> Double {
        let n = chatEntries(bookId).filter { $0.cardId == cardId }.reduce(0) { $0 - $1.amount }
        return Interact.round(n, get(bookId)?.code)
    }

    static func cardLeft(_ bookId: String, _ card: Card?) -> Double {
        Interact.round(max(0, (card?.limit ?? 0) - cardUsed(bookId, card?.id ?? "")), get(bookId)?.code)
    }

    // MARK: - 固定入账（不起定时器：谁打开账本谁把到期的补上）

    static func rulesOf(_ bookId: String) -> [Rule] { get(bookId)?.rules ?? [] }

    private static func clampDay(_ d: Double) -> Double { max(1, min(31, (d.isFinite && d != 0 ? d : 1).rounded())) }

    @discardableResult
    static func addRule(_ bookId: String, accountId: String = "", day: Double = 1, amount: Double = 0, category: String = "salary",
                        note: String = "", by: String = "", now: Date = Date()) throws -> Rule {
        guard let book = get(bookId) else { throw StoreError(message: "账本不存在") }
        let rule = Rule(obj: [
            "id": .string("rl" + base36(now.millis) + rand36(4)),
            "accountId": .string(accountId.isEmpty ? (book.accounts.first?.id ?? "") : accountId),
            "day": .number(clampDay(day)),
            "amount": .number(Interact.round(amount, book.code)),
            "category": .string(categoryOf(category).id),
            "note": .string(trim(note)),
            "active": .bool(true),
            // 谁建的：ai 是按角色卡生成的那几条，重新生成时整批换掉
            "by": .string(by),
            // 从建立的那一刻起算，不补历史
            "from": .number(now.millis),
        ])
        try patchBook(bookId, ["rules": .array((book.rules + [rule]).map { .object($0.obj) })])
        return rule
    }

    struct RulePatch {
        var accountId: String?
        var day: Double?
        var amount: Double?
        var category: String?
        var note: String?
        var active: Bool?
    }

    static func setRule(_ bookId: String, _ ruleId: String, _ p: RulePatch) throws {
        let code = get(bookId)?.code
        let next = rulesOf(bookId).map { r -> JSONValue in
            guard r.id == ruleId else { return .object(r.obj) }
            var o = r.obj
            if let v = p.accountId { o["accountId"] = .string(v) }
            if let v = p.day { o["day"] = .number(clampDay(v)) }
            if let v = p.amount { o["amount"] = .number(Interact.round(v, code)) }
            if let v = p.category { o["category"] = .string(categoryOf(v).id) }
            if let v = p.note { o["note"] = .string(trim(v)) }
            if let v = p.active { o["active"] = .bool(v) }
            return .object(o)
        }
        try patchBook(bookId, ["rules": .array(next)])
    }

    static func removeRule(_ bookId: String, _ ruleId: String) throws {
        try patchBook(bookId, ["rules": .array(rulesOf(bookId).filter { $0.id != ruleId }.map { .object($0.obj) })])
    }

    static func ymd(_ ms: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(millis: ms))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 这条规则从 from 到 now 应该落过哪几次。按月走，二月三十号这种落在当月最后一天
    static func dueDates(_ rule: Rule, now: Date = Date()) -> [Double] {
        let cal = Calendar.current
        let from = rule.from
        let start = Date(millis: from != 0 ? from : now.millis)
        var comps = cal.dateComponents([.year, .month], from: start)
        comps.day = 1
        guard var d = cal.date(from: comps) else { return [] }
        var out: [Double] = []
        while d <= now {
            let range = cal.range(of: .day, in: .month, for: d)
            let last = range?.count ?? 28
            var c = cal.dateComponents([.year, .month], from: d)
            c.day = Int(min(rule.day, Double(last)))
            c.hour = 9; c.minute = 0; c.second = 0
            if let at = cal.date(from: c), at.millis >= from, at <= now { out.append(at.millis) }
            guard let n = cal.date(byAdding: .month, value: 1, to: d) else { break }
            d = n
        }
        return out
    }

    /// 把到期还没落的固定入账补上。返回补了几笔
    @discardableResult
    static func runRules(_ bookId: String, now: Date = Date()) throws -> Int {
        guard get(bookId) != nil else { return 0 }
        let had = Set(entriesOf(bookId).filter { $0.src == "rule" }.map(\.ref))
        var made = 0
        for rule in rulesOf(bookId) where rule.active && rule.amount != 0 {
            for at in dueDates(rule, now: now) {
                let ref = "\(rule.id)@\(ymd(at))"
                if had.contains(ref) { continue }
                let row = Row.new(prefix: "en", [
                    "bookId": .string(bookId), "accountId": .string(rule.accountId), "amount": .number(rule.amount),
                    "category": .string(rule.category), "note": .string(rule.note), "at": .number(at),
                    "src": .string("rule"), "ref": .string(ref), "pending": .bool(false),
                ])
                try db.put(entriesCollection, row)
                made += 1
            }
        }
        if made > 0 { changed() }
        return made
    }

    // MARK: - 流水（amount 带符号：正数进账，负数出账）

    static func entriesOf(_ bookId: String) -> [Entry] {
        ((try? db.all(entriesCollection, where: bookId)) ?? []).map(Entry.init(row:))
    }

    private struct Move { var owner: String; var amount: Double; var noCard = false }

    /// 一条消息折成几笔（网页版 moveOf）。只认已经落定的
    private static func moves(_ m: Message) -> [Move] {
        let r = m.row
        switch m.kind {
        case "transfer":
            guard r.string("transfer") == "taken" else { return [] }
            let v = num(r["amount"])
            let from = m.role == .user ? me : char
            return [Move(owner: from, amount: -v), Move(owner: from == me ? char : me, amount: v)]
        case "takeout":
            let v = num(r["amount"])
            guard v != 0 else { return [] }
            let who = m.role == .user ? me : char
            let other = who == me ? char : me
            // 自己点自己吃自己付：一落库就算数
            if r.string("takeoutKind") == "self" { return [Move(owner: who, amount: -v)] }
            guard r.string("takeout") == "taken" else { return [] }
            // 请客：点的人付。代付：对方付
            return [Move(owner: r.string("takeoutKind") == "treat" ? who : other, amount: -v)]
        case "request":
            let k = r.string("requestKind")
            guard r.string("request") == LedgerRequest.approved else { return [] }
            let v = num(r["amount"])
            // 动用情侣账户：批准了才算，钱从情侣账户出
            if k == LedgerRequest.spend { return [Move(owner: joint, amount: -v, noCard: true)] }
            // 存入情侣账户：发出即落定，从存入方的钱包出、进情侣账户
            if k == LedgerRequest.deposit {
                let from = m.role == .user ? me : char
                return [Move(owner: from, amount: -v, noCard: true), Move(owner: joint, amount: v, noCard: true)]
            }
            return []
        default:
            return []
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (key: String, rows: [Entry]) = ("", [])

    /// 这本账从会话里读出来的那几笔，形状和 entries 一样。库没变就不重扫
    static func chatEntries(_ bookId: String) -> [Entry] {
        guard let book = get(bookId), !book.chatId.isEmpty else { return [] }
        let cur = db.changes.cursor
        let cardsKey = (try? JSONValue.array(book.cards.map { .object($0.obj) }).encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let key = "\(bookId):\(book.chatId):\(cur.db):\(cur.epoch):\(cur.seq):\(book.accounts.map(\.id).joined(separator: ",")):\(cardsKey)"
        cacheLock.lock()
        if cache.key == key { let hit = cache.rows; cacheLock.unlock(); return hit }
        cacheLock.unlock()

        // 按时间顺序扫，边扫边算亲属卡还剩多少额度：第 N 笔走不走得了卡，取决于前 N-1 笔刷掉了多少
        let cards = book.cards.filter(\.active)
        var used: [String: Double] = [:]
        var rows: [Entry] = []
        let raw = (try? db.containing(Collections.messages, where: book.chatId, any: [["transfer"], ["takeout"], ["request"]])) ?? []
        let list = raw.map(Message.init(row:)).filter { ["transfer", "takeout", "request"].contains($0.kind) }
            .enumerated().sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }.map(\.element)
        for m in list {
            for mv in moves(m) {
                var owner = mv.owner
                var cardId = ""
                // 出账才走卡，进账不走；情侣账户那一笔不走卡
                if mv.amount < 0 && !mv.noCard, let card = cards.first(where: { $0.to == owner }) {
                    let left = card.limit - (used[card.id] ?? 0)
                    // 额度够就整笔记在发卡方账上；不够就照旧记在自己账上
                    if left >= -mv.amount {
                        used[card.id, default: 0] += -mv.amount
                        owner = card.from
                        cardId = card.id
                    }
                }
                guard let acc = book.accounts.first(where: { $0.owner == owner && !$0.secret }) ?? book.accounts.first(where: { $0.owner == owner }) else { continue }
                let r = m.row
                let note: String
                switch m.kind {
                case "takeout": note = r.string("item").isEmpty ? "外卖" : r.string("item")
                case "request": note = r.string("requestKind") == LedgerRequest.deposit ? "存入情侣账户" : (r.string("note").isEmpty ? "情侣账户" : r.string("note"))
                default: note = r.string("note")
                }
                rows.append(Entry(id: "msg:\(m.id):\(mv.owner)", bookId: bookId, accountId: acc.id, amount: Interact.round(mv.amount, book.code),
                                  note: note, at: m.createdAt, ref: m.id, by: mv.owner, cardId: cardId))
            }
        }
        cacheLock.lock()
        cache = (key, rows)
        cacheLock.unlock()
        return rows
    }

    /// 手记的加上会话里现算的
    static func allEntries(_ id: String) -> [Entry] { entriesOf(id) + chatEntries(id) }

    /// 按时间倒序，界面上从新到旧读
    static func recent(_ id: String, limit: Int = 0) -> [Entry] {
        let list = allEntries(id).enumerated().sorted { a, b in
            a.element.at != b.element.at ? a.element.at > b.element.at : a.offset < b.offset
        }.map(\.element)
        return limit > 0 ? Array(list.prefix(limit)) : list
    }

    /// 记一笔。tripId 是这一笔属于哪一次出行
    @discardableResult
    static func add(bookId: String, accountId: String, amount: Double, category: String = "other", sub: String = "", note: String = "",
                    at: Double? = nil, src: String = "manual", pending: Bool = false, ref: String = "", tripId: String = "") throws -> Row {
        guard let book = get(bookId) else { throw StoreError(message: "账本不存在") }
        guard let acc = book.accounts.first(where: { $0.id == accountId }) ?? book.accounts.first else { throw StoreError(message: "这本账还没有账户") }
        let v = Interact.round(amount.isFinite ? amount : 0, book.code)
        guard v != 0 else { throw StoreError(message: "金额不能为零") }
        let st = AppSettings.load()
        let cat = categoryOf(category, st).id
        let when = (at ?? 0).isFinite && (at ?? 0) != 0 ? at! : Date().millis
        let row = Row.new(prefix: "en", [
            "bookId": .string(bookId), "accountId": .string(acc.id), "amount": .number(v),
            "category": .string(cat), "sub": .string(subOf(cat, sub, st)?.id ?? ""), "note": .string(trim(note)),
            "at": .number(when), "src": .string(src), "pending": .bool(pending), "ref": .string(ref), "tripId": .string(tripId),
        ])
        try db.put(entriesCollection, row)
        changed()
        return row
    }

    struct EntryPatch {
        var amount: Double?
        var accountId: String?
        var category: String?
        var sub: String?
        var note: String?
        var at: Double?
        var pending: Bool?
    }

    @discardableResult
    static func edit(_ entryId: String, _ p: EntryPatch) throws -> Row? {
        guard var row = try db.get(entriesCollection, id: entryId) else { return nil }
        let e = Entry(row: row)
        let code = get(e.bookId)?.code
        let st = AppSettings.load()
        if let v = p.amount { row["amount"] = .number(Interact.round(v.isFinite ? v : 0, code)) }
        if let v = p.accountId { row["accountId"] = .string(v) }
        var cat: String?
        if let v = p.category { cat = categoryOf(v, st).id; row["category"] = .string(cat!) }
        if p.sub != nil || p.category != nil {
            row["sub"] = .string(subOf(cat ?? e.category, p.sub ?? e.sub, st)?.id ?? "")
        }
        if let v = p.note { row["note"] = .string(trim(v)) }
        if let v = p.at { row["at"] = .number(v.isFinite && v != 0 ? v : e.at) }
        if let v = p.pending { row["pending"] = .bool(v) }
        row.touch()
        try db.put(entriesCollection, row)
        changed()
        return row
    }

    static func drop(_ entryId: String) throws {
        try db.delete(entriesCollection, id: entryId)
        changed()
    }

    /// 待确认的那几条：对话总结时提取的先落在这儿，确认过才算数
    static func pendingOf(_ id: String) -> [Entry] { entriesOf(id).filter(\.pending) }
    static func confirm(_ entryId: String) throws { try edit(entryId, EntryPatch(pending: false)) }

    // MARK: - 余额。全部现算

    static func balanceOf(_ bookId: String, _ accId: String) -> Double {
        let n = allEntries(bookId).filter { !$0.pending && $0.accountId == accId }.reduce(0) { $0 + $1.amount }
        return Interact.round(n, get(bookId)?.code)
    }

    /// 一本账上某一类归属的总额（owner 为 nil 是全部）。还锁着的私密账户不计入：计入的话合计一减就推得出来
    static func totalOf(_ bookId: String, _ owner: String? = nil) -> Double {
        let ids = Set(accountsOf(bookId).filter { (owner == nil || $0.owner == owner) && $0.open }.map(\.id))
        let n = allEntries(bookId).filter { !$0.pending && ids.contains($0.accountId) }.reduce(0) { $0 + $1.amount }
        return Interact.round(n, get(bookId)?.code)
    }

    // MARK: - 统计

    static func monthKey(_ ms: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date(millis: ms))
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func thisMonth(_ now: Date = Date()) -> String { monthKey(now.millis) }

    /// 有流水的那几个月（加上本月），新的在前
    static func months(_ bookId: String, now: Date = Date()) -> [String] {
        var set = Set(allEntries(bookId).filter { !$0.pending }.map { monthKey($0.at) })
        set.insert(thisMonth(now))
        return set.sorted(by: >)
    }

    struct SpendSub: Identifiable, Equatable { let id: String; let label: String; let amount: Double; let count: Int; let share: Double }
    struct SpendRow: Identifiable, Equatable {
        let id: String
        let label: String
        let amount: Double
        let count: Int
        let share: Double
        let subs: [SpendSub]
    }
    struct Spending: Equatable { let month: String; let total: Double; let rows: [SpendRow] }

    /// 钱都花在哪儿了：按分类摊开，带占比与笔数
    static func spending(_ bookId: String, month: String? = nil) -> Spending {
        let mo = month ?? thisMonth()
        let st = AppSettings.load()
        struct Sum { var amount = 0.0; var count = 0 }
        struct Group { var sum = Sum(); var subOrder: [String] = []; var subs: [String: Sum] = [:] }
        var order: [String] = []
        var by: [String: Group] = [:]
        var total = 0.0
        for e in allEntries(bookId) where !e.pending && e.src != "move" && monthKey(e.at) == mo && e.amount < 0 {
            let v = -e.amount
            let cat = categoryOf(e.category, st).id
            if by[cat] == nil { order.append(cat) }
            var had = by[cat] ?? Group()
            let sk = subOf(cat, e.sub, st)?.id ?? ""
            if had.subs[sk] == nil { had.subOrder.append(sk) }
            var hs = had.subs[sk] ?? Sum()
            hs.amount += v
            hs.count += 1
            had.subs[sk] = hs
            had.sum.amount += v
            had.sum.count += 1
            by[cat] = had
            total += v
        }
        let code = get(bookId)?.code
        let rows = order.compactMap { id -> SpendRow? in
            guard let g = by[id] else { return nil }
            let v = g.sum
            let subs = g.subOrder.compactMap { sid -> SpendSub? in
                guard let x = g.subs[sid] else { return nil }
                return SpendSub(id: sid, label: sid.isEmpty ? "未细分" : (subOf(id, sid, st)?.label ?? "未细分"),
                                amount: Interact.round(x.amount, code), count: x.count, share: v.amount != 0 ? x.amount / v.amount : 0)
            }
            return SpendRow(id: id, label: categoryOf(id, st).label, amount: Interact.round(v.amount, code), count: v.count,
                            share: total != 0 ? v.amount / total : 0, subs: stableSorted(subs) { $0.amount > $1.amount })
        }
        return Spending(month: mo, total: Interact.round(total, code), rows: stableSorted(rows) { $0.amount > $1.amount })
    }

    /// 网页版 Array.sort 是稳定的：相等的保持原来的先后
    static func stableSorted<T>(_ list: [T], by less: (T, T) -> Bool) -> [T] {
        list.enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    struct CatAmount: Identifiable, Equatable { let id: String; let label: String; let amount: Double }
    struct Stats: Equatable {
        let month: String
        let income: Double
        let expense: Double
        let net: Double
        let byCategory: [CatAmount]
    }

    static func stats(_ bookId: String, month: String? = nil) -> Stats {
        let mo = month ?? thisMonth()
        let st = AppSettings.load()
        var income = 0.0, expense = 0.0
        var order: [String] = []
        var by: [String: Double] = [:]
        for e in allEntries(bookId) where !e.pending && e.src != "move" && monthKey(e.at) == mo {
            if e.amount > 0 { income += e.amount } else {
                expense -= e.amount
                let cat = categoryOf(e.category, st).id
                if by[cat] == nil { order.append(cat) }
                by[cat, default: 0] -= e.amount
            }
        }
        let code = get(bookId)?.code
        let cats = order.map { CatAmount(id: $0, label: categoryOf($0, st).label, amount: Interact.round(by[$0] ?? 0, code)) }
        return Stats(month: mo, income: Interact.round(income, code), expense: Interact.round(expense, code),
                     net: Interact.round(income - expense, code), byCategory: stableSorted(cats) { $0.amount > $1.amount })
    }

    // MARK: - 显示

    /// 带货币符号与千分位，只给界面用
    static func money(_ bookId: String, _ n: Double) -> String { Interact.display(n, get(bookId)?.code) }

    struct Who { var me: String; var char: String; var chat: Chat?; var charRow: Character? }

    /// 这本账挂在谁身上。没绑会话就只有「我」
    static func whoOf(_ bookId: String) -> Who {
        let book = get(bookId)
        let chat = (book?.chatId).flatMap { (try? Repo.chat($0)) ?? nil }
        let c = chat.flatMap { $0.characterIds.first }.flatMap { (try? Repo.character($0)) ?? nil }
        let ps = (try? Repo.personas()) ?? []
        let mine = chat.flatMap { ch in ps.first { $0.id == ch.personaId } } ?? Isolate.current(ps, .load())
        let meName = mine?.row.string("name") ?? ""
        return Who(me: meName.isEmpty ? "我" : meName, char: c?.row.string("name") ?? "", chat: chat, charRow: c)
    }

    static func ownerLabel(_ bookId: String, _ owner: String) -> String {
        let w = whoOf(bookId)
        if owner == char { return w.char.isEmpty ? "角色" : w.char }
        if owner == joint { return "情侣账户" }
        return w.me
    }

    // MARK: - 钱不能无中生有（第二道关：真要付的时候再算一次）

    /// 这一方付得起这笔钱吗。没绑账本、或者没开严格模式，一律付得起
    static func affordable(_ chatId: String, _ owner: String, _ amount: Double) -> Bool {
        guard let book = bookOfChat(chatId), book.strict else { return true }
        // 角色的钱还没生成：不知道有多少，也就无从说不够
        if owner == char && !charReady(book.id) { return true }
        let v = abs(amount.isFinite ? amount : 0)
        // 手里有额度够用的亲属卡，付的就是发卡方的钱
        let card = cardTo(book.id, owner)
        let payer = card.map { cardLeft(book.id, $0) >= v ? $0.from : owner } ?? owner
        guard let acc = defaultFor(book.id, payer) else { return true }
        return balanceOf(book.id, acc.id) >= v
    }

    struct CardFact: Equatable { let limit: String; let left: String; let name: String }
    struct Context: Equatable {
        let name: String
        let selfBalance: String
        let selfName: String
        let other: String
        let otherName: String
        let joint: String
        let month: String
        let strict: Bool
        let hasJoint: Bool
        let cardHeld: CardFact?
        let cardGiven: CardFact?
    }

    /// 注入用的那一份（网页版 context，context/bill.js 读它）。私密账户任何时候都不进来
    static func context(_ chatId: String, now: Date = Date()) -> Context? {
        guard let book = bookOfChat(chatId), book.inject else { return nil }
        let w = whoOf(book.id)
        let mine = defaultFor(book.id, me), hers = defaultFor(book.id, char), j = defaultFor(book.id, joint)
        let st = stats(book.id, month: thisMonth(now))
        let fmt = { (n: Double) in Interact.format(n, book.code) }
        let hidden = Set(hiddenFromPrompt(book.id))
        if [hers?.id, mine?.id, j?.id].contains(where: { $0 != nil && hidden.contains($0!) }) {
            Diagnostics.shared.record("ledger-secret-default", [:])
        }
        let ready = charReady(book.id)
        let held = cardTo(book.id, char).map { CardFact(limit: fmt($0.limit), left: fmt(cardLeft(book.id, $0)), name: w.me) }
        let given = cardTo(book.id, me).map { CardFact(limit: fmt($0.limit), left: fmt(cardLeft(book.id, $0)), name: w.me) }
        return Context(name: book.name,
                       selfBalance: hers != nil && ready ? fmt(balanceOf(book.id, hers!.id)) : "",
                       selfName: hers?.name ?? "",
                       other: mine.map { fmt(balanceOf(book.id, $0.id)) } ?? "",
                       otherName: w.me,
                       joint: j.map { fmt(balanceOf(book.id, $0.id)) } ?? "",
                       month: fmt(st.expense), strict: book.strict, hasJoint: hasJoint(book.id),
                       cardHeld: held, cardGiven: given)
    }

    /// [你的钱] 那一段（网页版 context/bill.js，一字不差）。只写数字，不写该怎么花（第 16 条）
    static func block(_ chat: Chat, now: Date = Date()) -> String {
        guard let c = context(chat.id, now: now) else { return "" }
        var lines: [String] = []
        if !c.selfBalance.isEmpty { lines.append("Your balance: \(c.selfBalance)\(c.selfName.isEmpty ? "" : " (\(c.selfName))").") }
        if !c.other.isEmpty { lines.append("Balance of \(c.otherName): \(c.other).") }
        if !c.joint.isEmpty { lines.append("Couple account (shared by the two of you): \(c.joint).") }
        if lines.isEmpty { return "" }
        lines.append("Your spending this month: \(c.month).")
        lines.append("These figures are computed by the system from the recorded entries."
            + " Write them exactly as given when an amount comes up. Do not substitute"
            + " another figure, and do not estimate one yourself.")
        if c.strict {
            lines.append("An amount you send is deducted from the balance above."
                + " A payment larger than the balance does not go through.")
        }
        return "\n\n[你的钱]\n" + lines.joined(separator: "\n")
    }

    /// 付不起就落一行说明（网页版 reply.js 的 broke）。付得起返回 nil
    static func broke(_ base: Message, amount: Double, what: String) -> Message? {
        let owner = base.role == .user ? me : char
        if affordable(base.chatId, owner, amount) { return nil }
        let book = bookOfChat(base.chatId)
        let acc = book.flatMap { defaultFor($0.id, owner) }
        let left = (book != nil && acc != nil) ? money(book!.id, balanceOf(book!.id, acc!.id)) : ""
        var m = base
        m.row["kind"] = .string("notice")
        m.row["content"] = .string("[余额不足，\(what) 没有付成。当前余额 \(left)]")
        m.row["status"] = .string("done")
        return m
    }

    // MARK: - 结算角色前一天花了多少（不另调接口：花销随日程一起生成）

    @discardableResult
    static func settleDay(_ bookId: String, charId: String, date: String) throws -> Int {
        guard let book = get(bookId) else { return 0 }
        guard let row = try DayPlan.day(charId, date: date) else { return 0 }
        guard let acc = defaultFor(bookId, char) else { return 0 }
        let had = Set(entriesOf(bookId).filter { $0.src == "day" }.map(\.ref))
        var parts = DateComponents()
        let ymdParts = date.split(separator: "-").compactMap { Int($0) }
        if ymdParts.count == 3 { parts.year = ymdParts[0]; parts.month = ymdParts[1]; parts.day = ymdParts[2]; parts.hour = 20 }
        let at = (ymdParts.count == 3 ? Calendar.current.date(from: parts)?.millis : nil) ?? Date().millis
        var made = 0
        func put(_ key: String, _ amount: Double, _ category: String, _ note: String) throws {
            let ref = "\(charId)@\(date)#\(key)"
            if had.contains(ref) || amount == 0 { return }
            try db.put(entriesCollection, Row.new(prefix: "en", [
                "bookId": .string(bookId), "accountId": .string(acc.id), "amount": .number(Interact.round(-abs(amount), book.code)),
                "category": .string(category), "note": .string(trim(note)), "at": .number(at), "src": .string("day"),
                "ref": .string(ref), "pending": .bool(false),
            ]))
            made += 1
        }
        // 取消掉的那几项不算：没做的事不花钱
        for (i, it) in (row["items"]?.array ?? []).enumerated() {
            if it["state"]?.string == DayPlan.drop { continue }
            let idv = it["id"]
            let iid = truthy(idv) ? (idv?.string ?? idv?.number.map(jsNumber) ?? "\(i)") : "\(i)"
            try put("i\(iid)", num(it["cost"]), "other", it["text"]?.string ?? "")
        }
        for (i, m) in (row["meals"]?.array ?? []).enumerated() {
            let key = m["meal"].flatMap { truthy($0) ? $0.string : nil } ?? "\(i)"
            try put("m\(key)", num(m["price"]), "food", m["name"]?.string ?? "")
        }
        if made > 0 { changed() }
        return made
    }

    /// 网页版把数字拼进字符串的写法：整数不带小数点
    private static func jsNumber(_ n: Double) -> String { n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n) }

    /// 前一天的结算。排新一天日程时顺手结掉昨天（网页版 tasks/day.js）。默认关（账本上的 settle）
    @discardableResult
    static func settleYesterday(_ charId: String, now: Date = Date()) throws -> Int {
        guard let book = all().first(where: { b in
            guard !b.chatId.isEmpty, let c = (try? Repo.chat(b.chatId)) ?? nil else { return false }
            return c.characterIds.first == charId
        }), book.settle else { return 0 }
        guard (try Repo.character(charId)) != nil else { return 0 }
        return try settleDay(book.id, charId: charId, date: ymd(now.millis - 86_400_000))
    }

    // MARK: - 私密账户（密码与余额都不进 prompt，猜这件事只发生在记账里）

    static func secretOf(_ bookId: String) -> Account? { accountsOf(bookId).first { $0.owner == char && $0.secret } }
    static func hiddenFromPrompt(_ bookId: String) -> [String] { secretOf(bookId).map { [$0.id] } ?? [] }

    /// 猜对了就永久解开。密码只在这台设备上，这是个游戏，不是安全边界
    @discardableResult
    static func tryPass(_ bookId: String, _ accId: String, _ input: String) throws -> Bool {
        guard let acc = accountOf(bookId, accId), acc.secret else { return true }
        let ok = trim(input) == acc.pass
        if ok { try updateAccount(bookId, accId, AccountPatch(unlocked: true)) }
        return ok
    }
}
