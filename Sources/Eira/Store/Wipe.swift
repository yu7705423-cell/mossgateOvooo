import Foundation

/// 「设置 - 存储 - 清空全部数据」。接口配置与密钥留着（网页版同样）。
enum Wipe {
    /// 先清库里的记录，再删图片与文件。库清不掉就一个文件都不删：图在而记录没了，比两样都在更难收拾。
    /// 文件删不掉的只是占着空间，库里已经没有指向它们的记录，下次清空或导入时一并换掉。
    static func all() throws {
        try Database.shared.wipe()
        try? FileManager.default.removeItem(at: AppPaths.media)
        Diagnostics.shared.record("wipe", [:])
    }
}
