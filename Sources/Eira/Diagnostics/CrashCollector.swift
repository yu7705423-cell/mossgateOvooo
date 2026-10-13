import Foundation
import MetricKit

/// 闪退摘要。系统在下次启动时把上次的闪退报告交给 MetricKit，这里只取摘要记进诊断：
/// 异常类型、信号、终止原因、出事时的版本。调用栈只留前 2000 个字符（不含任何用户数据，是代码位置）。
final class CrashCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashCollector()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var fields: [String: Any] = ["version": crash.applicationVersion]
                if let t = crash.exceptionType { fields["exceptionType"] = t.intValue }
                if let c = crash.exceptionCode { fields["exceptionCode"] = c.intValue }
                if let s = crash.signal { fields["signal"] = s.intValue }
                if let r = crash.terminationReason { fields["reason"] = r }
                let stack = String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self)
                fields["stack"] = String(stack.prefix(2000))
                Diagnostics.shared.record("crash", fields)
            }
        }
    }
}
