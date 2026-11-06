import Foundation

/// 原生库的变更记录：每写一行、删一行、写一次 kv 记一笔，带一个只增不减的序号。
///
/// 给常驻在 JavaScriptCore 里的那几张表用（docs/jscore-prompt.md 的「常驻表」）：拼装之前问一句「上次之后改了哪些」，
/// 只把变了的行交进去。导入、清空全部数据（整批换掉）时记录作废，下一次整表重灌。
///
/// 只在内存里，不落盘：app 重开之后 JSContext 本来就是新的，要整表灌一次。
/// 最多留 `cap` 笔，更早的丢掉；问的人要的比留着的还早，同样整表重灌。
/// 没有人问过之前（试点开关关着）只数序号、不留记录，不占内存。
final class ChangeLog: @unchecked Sendable {
    enum Change: Hashable, Sendable {
        /// 一个数据域里的一行（新写、改了、删了都是它，读的人自己去库里看现在是什么样）
        case row(String, String)
        /// 一个数据域里查询字段等于某个值的全部行（deleteAll）
        case group(String, String)
        /// kv 的一个键
        case kv(String)
    }

    /// 读到哪儿了。换了一个库（测试里每个用例一份）、整批换过、或者序号已经丢了，都要整表重灌
    struct Cursor: Equatable, Sendable {
        var db: UUID
        var epoch: Int
        var seq: Int
    }

    static let cap = 20_000

    let db = UUID()
    private let lock = NSLock()
    private var epoch = 0
    private var seq = 0
    /// 留着的最早一笔之前的序号：问的人的 seq 比它小，中间有丢掉的
    private var floor = 0
    private var seqs: [Int] = []
    private var items: [Change] = []
    /// 有人问过 since 没有。没问过时不留记录（谁要都整表）
    private var active = false

    func note(_ change: Change) {
        lock.lock(); defer { lock.unlock() }
        seq += 1
        guard active else { floor = seq; return }
        seqs.append(seq)
        items.append(change)
        if items.count > Self.cap {
            let drop = items.count / 2
            floor = seqs[drop - 1]
            seqs.removeFirst(drop)
            items.removeFirst(drop)
        }
    }

    /// 整批换掉了（导入、清空全部数据）：之前的记录一律作废
    func reset() {
        lock.lock(); defer { lock.unlock() }
        epoch += 1
        floor = seq
        seqs = []
        items = []
    }

    var cursor: Cursor {
        lock.lock(); defer { lock.unlock() }
        return Cursor(db: db, epoch: epoch, seq: seq)
    }

    /// from 之后的变更，和此刻的读到哪儿。nil：要整表重灌（from 是 nil、换了库、整批换过、或者中间有丢掉的）
    func since(_ from: Cursor?) -> (cursor: Cursor, changes: [Change]?) {
        lock.lock(); defer { lock.unlock() }
        active = true
        let now = Cursor(db: db, epoch: epoch, seq: seq)
        guard let from, from.db == db, from.epoch == epoch, from.seq >= floor, from.seq <= seq else { return (now, nil) }
        // seqs 是递增的：从后往前找到第一笔不比 from 新的
        var i = seqs.count
        while i > 0, seqs[i - 1] > from.seq { i -= 1 }
        return (now, Array(items[i...]))
    }
}
