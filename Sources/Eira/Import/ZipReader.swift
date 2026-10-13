import Foundation

/// 读 ZIP。照网页版 `src/system/zip.js` 的读法：
///
/// - 按中央目录读；偏移量指错了按「结尾记录减去目录长度」再找一次；
/// - 中央目录读不出东西时，退回去从头顺着本地头爬（被别的工具改过的包常常是这样）；
/// - 只认 store（0）与 deflate（8），别的压缩方式跳过；不做 ZIP64。
///
/// 文件按内存映射打开，几百兆的备份不会整个读进内存；每一条要用时才切出来。
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let dataAt: Int
    }

    private let data: Data
    private(set) var entries: [Entry] = []

    private static let local: UInt32 = 0x04034b50
    private static let central: UInt32 = 0x02014b50
    private static let end: UInt32 = 0x06054b50
    private static let descriptor: UInt32 = 0x08074b50

    static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4b
    }

    init(data: Data) throws {
        self.data = data
        entries = readCentral() ?? []
        if entries.isEmpty { entries = scanLocal() }
        if entries.isEmpty {
            throw StoreError(message: "这不是一个 ZIP 文件，或者里面一条记录都读不出来")
        }
    }

    var names: [String] { entries.map(\.name) }

    func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// 取出一条的内容。解不开的返回 nil，不连累其余的。
    func contents(of e: Entry) -> Data? {
        guard e.dataAt >= 0, e.dataAt + e.compressedSize <= data.count else { return nil }
        let raw = data.subdata(in: (data.startIndex + e.dataAt)..<(data.startIndex + e.dataAt + e.compressedSize))
        switch e.method {
        case 0: return raw
        // Apple 的 .zlib 是裸 DEFLATE（RFC 1951），正是 ZIP 里那一种
        case 8: return try? (raw as NSData).decompressed(using: .zlib) as Data
        default: return nil
        }
    }

    // MARK: - 中央目录

    private func readCentral() -> [Entry]? {
        guard data.count >= 22 else { return nil }
        let tailLen = min(data.count, 66000)
        let tailAt = data.count - tailLen
        var eocd = -1
        var i = data.count - 22
        while i >= tailAt {
            if u32(i) == Self.end { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }

        let count = Int(u16(eocd + 10))
        let dirSize = Int(u32(eocd + 12))
        var dirAt = Int(u32(eocd + 16))
        if !isSig(dirAt, Self.central) {
            let guess = eocd - dirSize
            guard isSig(guess, Self.central) else { return nil }
            dirAt = guess
        }

        var out: [Entry] = []
        var at = dirAt
        for _ in 0..<count {
            guard at + 46 <= data.count, u32(at) == Self.central else { break }
            let method = u16(at + 10)
            let size = Int(u32(at + 20))
            let nameLen = Int(u16(at + 28))
            let extraLen = Int(u16(at + 30))
            let commentLen = Int(u16(at + 32))
            let localAt = Int(u32(at + 42))
            let name = string(at + 46, nameLen)
            at += 46 + nameLen + extraLen + commentLen
            // 本地头里的两个长度可能和中央目录里的不一样，数据起点按本地头算
            guard isSig(localAt, Self.local), localAt + 30 <= data.count else { continue }
            let dataAt = localAt + 30 + Int(u16(localAt + 26)) + Int(u16(localAt + 28))
            out.append(Entry(name: name, method: method, compressedSize: size, dataAt: dataAt))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - 顺着本地头爬

    private func scanLocal() -> [Entry] {
        var out: [Entry] = []
        var at = 0
        while at + 30 <= data.count {
            guard u32(at) == Self.local else {
                guard let next = find(Self.local, from: at + 1) else { break }
                at = next
                continue
            }
            let flags = u16(at + 6)
            let method = u16(at + 8)
            var size = Int(u32(at + 18))
            let nameLen = Int(u16(at + 26))
            let extraLen = Int(u16(at + 28))
            let name = string(at + 30, nameLen)
            let dataAt = at + 30 + nameLen + extraLen
            var after = dataAt + size

            // 长度写在后面的数据描述符里：往后找下一条记录的开头，中间那一段就是数据
            if flags & 8 != 0 && size == 0 {
                let ends = [find(Self.descriptor, from: dataAt), find(Self.local, from: dataAt), find(Self.central, from: dataAt)]
                    .compactMap { $0 }
                guard let endAt = ends.min() else { break }
                size = endAt - dataAt
                after = endAt == find(Self.descriptor, from: dataAt) ? endAt + 16 : endAt
            }
            guard size >= 0, dataAt + size <= data.count else { break }
            out.append(Entry(name: name, method: method, compressedSize: size, dataAt: dataAt))
            at = max(after, at + 1)
        }
        return out
    }

    // MARK: - 字节

    private func byte(_ at: Int) -> UInt8 { data[data.startIndex + at] }
    private func u16(_ at: Int) -> UInt16 { UInt16(byte(at)) | UInt16(byte(at + 1)) << 8 }
    private func u32(_ at: Int) -> UInt32 {
        UInt32(byte(at)) | UInt32(byte(at + 1)) << 8 | UInt32(byte(at + 2)) << 16 | UInt32(byte(at + 3)) << 24
    }
    private func isSig(_ at: Int, _ sig: UInt32) -> Bool { at >= 0 && at + 4 <= data.count && u32(at) == sig }
    private func string(_ at: Int, _ len: Int) -> String {
        guard at + len <= data.count else { return "" }
        let bytes = data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + len))
        return String(decoding: bytes, as: UTF8.self)
    }
    private func find(_ sig: UInt32, from: Int) -> Int? {
        var i = max(0, from)
        while i + 4 <= data.count {
            if u32(i) == sig { return i }
            i += 1
        }
        return nil
    }
}
