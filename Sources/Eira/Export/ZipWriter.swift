import Foundation

/// 写 ZIP。照网页版 `src/system/zip.js` 的 zip：只做 store（不压缩），文件名按 UTF-8，不做 ZIP64，超过 4 GB 报错。
/// 一条一条直接写进文件，不把整包握在内存里。
final class ZipWriter {
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var central = Data()
    private var count = 0
    private let time: UInt16
    private let date: UInt16
    private static let limit: UInt64 = 0xffff_ffff

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) >> 1))
        date = UInt16((((c.year ?? 1980) - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    func add(name: String, data: Data) throws {
        let nameBytes = Data(name.utf8)
        let crc = CRC32.of(data)
        let size = UInt32(data.count)
        guard offset + 30 + UInt64(nameBytes.count) + UInt64(data.count) <= Self.limit else {
            throw StoreError(message: "备份超过 4 GB，请去掉视频与音频后重试")
        }
        var local = Data()
        local.u32(0x04034b50); local.u16(20); local.u16(0x0800); local.u16(0)
        local.u16(time); local.u16(date); local.u32(crc); local.u32(size); local.u32(size)
        local.u16(UInt16(nameBytes.count)); local.u16(0); local.append(nameBytes)
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)

        central.u32(0x02014b50); central.u16(20); central.u16(20); central.u16(0x0800); central.u16(0)
        central.u16(time); central.u16(date); central.u32(crc); central.u32(size); central.u32(size)
        central.u16(UInt16(nameBytes.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
        central.u32(0); central.u32(UInt32(offset)); central.append(nameBytes)

        offset += UInt64(local.count + data.count)
        count += 1
    }

    func finish() throws {
        guard offset + UInt64(central.count) + 22 <= Self.limit, count <= 0xffff else {
            throw StoreError(message: "备份超过 4 GB 或条目过多，请去掉视频与音频后重试")
        }
        var end = Data()
        end.u32(0x06054b50); end.u16(0); end.u16(0); end.u16(UInt16(count)); end.u16(UInt16(count))
        end.u32(UInt32(central.count)); end.u32(UInt32(offset)); end.u16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func of(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        data.withUnsafeBytes { buf in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        }
        return c ^ 0xffff_ffff
    }
}

extension Data {
    mutating func u16(_ v: UInt16) { append(UInt8(v & 0xff)); append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xff)) } }
}
