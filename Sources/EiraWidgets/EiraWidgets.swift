import AppIntents
import SwiftUI
import WidgetKit

/// iPhone 桌面组件（网页版 ARCHITECTURE 4.941）：角色此刻、健康，小号与中号。
///
/// 组件读不到应用的库：应用把要显示的东西整理好写进 App Group（WidgetStore），这里只读、只画。
/// 健康组件上的喝水、排便、服药点一下就记（可交互组件，App Intents）：先在这边把数字加上，记进队列，
/// 下次打开应用时应用取走、记进健康记录。不调任何接口。
/// 网页版还有一个「桌宠」组件，那边仍挂在测试版（4.942），原生版没有桌宠，这里不放。

let store = WidgetStore.group
let gray = Color(UIColor.secondaryLabel)

/// 点了打开应用的链接（应用的 DeepLink 认这几种）
enum Links {
    static func chat(_ id: String) -> URL { URL(string: id.isEmpty ? "eiraowo://open" : "eiraowo://chat/\(id)")! }
    static let health = URL(string: "eiraowo://open?app=health")!
}

// MARK: - 点一下就记

struct TapIntent: AppIntent {
    static var title: LocalizedStringResource = "记一次"
    static var isDiscoverable: Bool = false
    @Parameter(title: "种类") var kind: String

    init() { kind = "" }
    init(kind: String) { self.kind = kind }

    func perform() async throws -> some IntentResult {
        store.record(kind)
        WidgetCenter.shared.reloadTimelines(ofKind: "eira.health")
        return .result()
    }
}

extension View {
    func widgetBack() -> some View {
        containerBackground(for: .widget) { Color(UIColor.systemBackground) }
    }
}

// MARK: - 角色此刻

struct CharEntry: TimelineEntry {
    let date: Date
    let name: String
    let slot: String
    let text: String
    let chatId: String
    let avatar: UIImage?
}

struct CharProvider: TimelineProvider {
    func placeholder(in context: Context) -> CharEntry {
        CharEntry(date: Date(), name: "角色", slot: "下午", text: "在工作", chatId: "", avatar: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (CharEntry) -> Void) {
        completion(entries().first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CharEntry>) -> Void) {
        let list = entries()
        let after = (list.last?.date ?? Date()).addingTimeInterval(3600)
        completion(Timeline(entries: list, policy: .after(after)))
    }

    private func entries(now: Date = Date()) -> [CharEntry] {
        guard let d = store.readJSON(WidgetStore.charKey) else {
            return [CharEntry(date: now, name: "", slot: "", text: "在 Eiraowo 的「设置 - 主题 - iPhone 桌面组件」中选择角色", chatId: "", avatar: nil)]
        }
        let name = d["name"] as? String ?? ""
        let chatId = d["chatId"] as? String ?? ""
        let avatar = store.image(d["avatar"] as? String)
        let rows = (d["entries"] as? [[String: Any]]) ?? []
        func at(_ r: [String: Any]) -> Date { Date(timeIntervalSince1970: ((r["at"] as? Double) ?? 0) / 1000) }
        var out: [CharEntry] = []
        for (i, r) in rows.enumerated() {
            let next = i + 1 < rows.count ? at(rows[i + 1]) : .distantFuture
            if next <= now { continue }   // 已经过去的时段不排
            out.append(CharEntry(date: max(at(r), now), name: name, slot: r["slot"] as? String ?? "", text: r["text"] as? String ?? "",
                                 chatId: chatId, avatar: avatar))
        }
        if out.isEmpty {
            out = [CharEntry(date: now, name: name, slot: "", text: d["fallback"] as? String ?? "今天的日程尚未生成", chatId: chatId, avatar: avatar)]
        }
        return out
    }
}

struct Face: View {
    let image: UIImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(UIColor.systemGray5) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct CharView: View {
    let e: CharEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemMedium {
                HStack(spacing: 14) {
                    Face(image: e.avatar, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.name).font(.headline).lineLimit(1)
                        if !e.slot.isEmpty { Text("此刻 · \(e.slot)").font(.caption).foregroundStyle(gray) }
                        Text(e.text).font(.subheadline).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Face(image: e.avatar, size: 36)
                    Text(e.name).font(.headline).lineLimit(1)
                    if !e.slot.isEmpty { Text(e.slot).font(.caption).foregroundStyle(gray) }
                    Text(e.text).font(.footnote).lineLimit(3)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .widgetURL(Links.chat(e.chatId))
        .widgetBack()
    }
}

struct CharWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "eira.char", provider: CharProvider()) { CharView(e: $0) }
            .configurationDisplayName("角色此刻")
            .description("角色今天的日程中此刻这一时段的安排。到点自动切换，点按进入聊天。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 健康

struct HealthEntry: TimelineEntry {
    let date: Date
    let water: Int
    let poop: Int
    let medTaken: Int
    let medTotal: Int
    let weight: String
}

struct HealthProvider: TimelineProvider {
    func placeholder(in context: Context) -> HealthEntry {
        HealthEntry(date: Date(), water: 3, poop: 1, medTaken: 1, medTotal: 2, weight: "—")
    }

    func getSnapshot(in context: Context, completion: @escaping (HealthEntry) -> Void) { completion(entry()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HealthEntry>) -> Void) {
        // 过了零点数字归零：明天零点再排一格
        let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
        completion(Timeline(entries: [entry(), entry(at: tomorrow)], policy: .after(tomorrow.addingTimeInterval(60))))
    }

    private func entry(at: Date = Date()) -> HealthEntry {
        let h = store.readJSON(WidgetStore.healthKey) ?? [:]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let stale = (h["date"] as? String ?? "") != f.string(from: at)
        func n(_ k: String) -> Int { stale ? 0 : ((h[k] as? NSNumber)?.intValue ?? 0) }
        return HealthEntry(date: at, water: n("water"), poop: n("poop"), medTaken: n("medTaken"),
                           medTotal: (h["medTotal"] as? NSNumber)?.intValue ?? 0,
                           weight: stale ? "—" : (h["weight"] as? String ?? "—"))
    }
}

struct Chip: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
    }
}

struct HealthView: View {
    let e: HealthEntry
    @Environment(\.widgetFamily) private var family

    private func tap(_ kind: String, _ title: String, _ value: String) -> some View {
        Button(intent: TapIntent(kind: kind)) { Chip(title: title, value: value) }.buttonStyle(.plain)
    }

    var body: some View {
        Group {
            if family == .systemMedium {
                VStack(alignment: .leading, spacing: 8) {
                    Text("今天").font(.caption).foregroundStyle(gray)
                    HStack(spacing: 8) {
                        tap("water", "喝水 +1", "\(e.water)")
                        tap("poop", "排便 +1", "\(e.poop)")
                        tap("med", "服药", e.medTotal > 0 ? "\(e.medTaken)/\(e.medTotal)" : "—")
                        Link(destination: Links.health) { Chip(title: "体重", value: e.weight) }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    tap("water", "喝水 +1", "\(e.water)")
                    tap("poop", "排便 +1", "\(e.poop)")
                }
            }
        }
        .widgetURL(Links.health)
        .widgetBack()
    }
}

struct HealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "eira.health", provider: HealthProvider()) { HealthView(e: $0) }
            .configurationDisplayName("健康")
            .description("点按记一杯水、一次排便、一样药；体重在应用中填写。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct EiraWidgetBundle: WidgetBundle {
    var body: some Widget {
        CharWidget()
        HealthWidget()
    }
}
