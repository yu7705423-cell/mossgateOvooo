import CommonCrypto
import CryptoKit
import Foundation

/// 解开网页版加了口令的备份。格式见网页版 `src/system/vault.js`（ARCHITECTURE 4.555），这里只读不写：
///
///     EIRAVLT1 (8)  迭代次数 (4, 大端)  盐 (16)  基础 IV (12)  段长 (4, 大端)     文件头共 44 字节
///     然后每段：密文长度 (4, 大端) + 密文（含末尾 16 字节校验）
///
/// PBKDF2-SHA256 把口令拉成 AES-GCM 256 的钥匙。第 i 段的 IV = 基础 IV 末四个字节异或 i；
/// 附加数据 = 文件头 + 段号（4, 大端）+ 是不是最后一段（1 字节）。
enum Vault {
    enum Failure: LocalizedError {
        case needPass, badPass, broken(String)
        var errorDescription: String? {
            switch self {
            case .needPass: return "这份备份已加密，请输入备份口令"
            case .badPass: return "口令不正确，或文件已损坏"
            case .broken(let why): return why
            }
        }
    }

    static let headLength = 44
    private static let magic = Array("EIRAVLT1".utf8)

    static func isSealed(_ data: Data) -> Bool {
        data.count >= headLength && Array(data.prefix(8)) == magic
    }

    /// 解密到一个临时文件，返回它的地址。一段一段写，不把明文整份握在内存里。
    static func open(_ data: Data, pass: String, to out: URL) throws {
        guard isSealed(data) else { throw Failure.broken("不是加密的备份") }
        guard !pass.isEmpty else { throw Failure.needPass }
        let head = Data(data.prefix(headLength))
        let iterations = be32(head, 8)
        let salt = head.subdata(in: (head.startIndex + 12)..<(head.startIndex + 28))
        let ivBase = Array(head.subdata(in: (head.startIndex + 28)..<(head.startIndex + 40)))
        let chunk = be32(head, 40)
        guard iterations > 0, iterations <= 10_000_000, chunk > 0 else {
            throw Failure.broken("加密备份的文件头已损坏")
        }
        let key = try derive(pass: pass, salt: salt, iterations: iterations)

        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }

        var at = headLength
        var i: UInt32 = 0
        var last = false
        while at < data.count {
            if last { throw Failure.broken("加密备份的末尾多出了内容，文件已损坏") }
            guard at + 4 <= data.count else { throw Failure.broken("加密备份不完整，可能没有下载完") }
            let len = Int(be32(data, at))
            at += 4
            guard len > 16, at + len <= data.count else { throw Failure.broken("加密备份不完整，可能没有下载完") }
            let ct = data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + len))
            at += len
            last = at >= data.count

            var aad = head
            var n = i.bigEndian
            aad.append(Data(bytes: &n, count: 4))
            aad.append(last ? 1 : 0)
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv(ivBase, i)),
                                                ciphertext: ct.prefix(len - 16), tag: ct.suffix(16))
                let plain = try AES.GCM.open(box, using: key, authenticating: aad)
                try handle.write(contentsOf: plain)
            } catch {
                throw Failure.badPass
            }
            i += 1
        }
        if !last { throw Failure.broken("加密备份不完整，可能没有下载完") }
    }

    private static func derive(pass: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(pass.utf8)
        var bits = [UInt8](repeating: 0, count: 32)
        let rc = salt.withUnsafeBytes { saltBuf in
            password.withUnsafeBufferPointer { pw in
                pw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: password.count) { pwChars in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwChars, password.count,
                        saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        &bits, bits.count)
                }
            }
        }
        guard rc == Int32(kCCSuccess) else { throw Failure.broken("无法由口令生成密钥") }
        defer { bits = [UInt8](repeating: 0, count: 32) }
        return SymmetricKey(data: bits)
    }

    private static func iv(_ base: [UInt8], _ i: UInt32) -> [UInt8] {
        var out = base
        let x = (UInt32(out[8]) << 24 | UInt32(out[9]) << 16 | UInt32(out[10]) << 8 | UInt32(out[11])) ^ i
        out[8] = UInt8(x >> 24 & 0xff); out[9] = UInt8(x >> 16 & 0xff)
        out[10] = UInt8(x >> 8 & 0xff); out[11] = UInt8(x & 0xff)
        return out
    }

    private static func be32(_ d: Data, _ at: Int) -> Int {
        let s = d.startIndex + at
        return Int(UInt32(d[s]) << 24 | UInt32(d[s + 1]) << 16 | UInt32(d[s + 2]) << 8 | UInt32(d[s + 3]))
    }
}
