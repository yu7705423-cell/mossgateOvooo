import SwiftUI
import UniformTypeIdentifiers

/// 从 txt、md、docx 读一张角色卡。读完先在这一页看一遍、可以改，点「创建角色」才入库。
/// 这一页是生成结果的确认页，人设可以在这里出现（网页版第 6 条的例外）。
struct CardImportView: View {
    var onCreated: (String) -> Void

    @State private var picking = false
    @State private var fileName = ""
    @State private var running = false
    @State private var job: Task<Void, Never>?
    @State private var draft: CardImport.Draft?
    @State private var withCore = AppSettings.load().raw["coreAuto"]?.bool ?? true
    @State private var problem: String?

    private static let types: [UTType] = [.plainText, UTType(filenameExtension: "md") ?? .plainText,
                                          UTType("org.openxmlformats.wordprocessingml.document") ?? .data]

    var body: some View {
        Form {
            Section {
                Button(fileName.isEmpty ? "选择文件" : "重新选择") { picking = true }.disabled(running)
                if !fileName.isEmpty { LabeledContent("文件", value: fileName) }
                if running {
                    HStack { ProgressView(); Text("正在读取").foregroundStyle(Theme.secondaryText); Spacer(); Button("停止") { job?.cancel() } }
                }
            } footer: {
                Text("支持 txt、md、docx。由副用接口读取，调用一次。资料整份发给模型，不截字数：资料越长，这一次的用量越大。")
            }
            if let problem { Section { Text(problem).foregroundStyle(Theme.danger) } }
            if draft != nil { draftSections }
        }
        .navigationTitle("从资料读取角色卡")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.types) { result in
            switch result {
            case .success(let url): read(url)
            case .failure(let e): problem = e.localizedDescription
            }
        }
    }

    @ViewBuilder private var draftSections: some View {
        let d = Binding(get: { draft ?? .init() }, set: { draft = $0 })
        Section("基本") {
            TextField("名字", text: d.name)
            TextField("一句话签名", text: d.signature)
            TextField("性别", text: d.gender)
            TextField("年龄", text: d.age)
            TextField("生日", text: d.birthday)
        }
        Section("人设") { TextField("人设", text: d.persona, axis: .vertical).lineLimit(6...40) }
        Section("外貌") { TextField("外貌", text: d.appearance, axis: .vertical).lineLimit(2...12) }
        Section("情境") { TextField("情境", text: d.scenario, axis: .vertical).lineLimit(2...20) }
        Section("开场白") { TextField("开场白", text: d.firstMessage, axis: .vertical).lineLimit(2...20) }
        Section("说话示例") { TextField("说话示例", text: d.exampleDialogue, axis: .vertical).lineLimit(2...30) }
        Section {
            Toggle("同时生成核心设定", isOn: $withCore)
            Button("创建角色", action: create)
        } footer: {
            Text("核心设定是从人设中压缩出的三到五行，放在提示词末尾。开启后创建时另调用一次接口；生成失败不影响角色的创建，之后可在编辑资料中填写。")
        }
    }

    private func read(_ url: URL) {
        fileName = url.lastPathComponent
        draft = nil
        problem = nil
        running = true
        job = Task {
            do {
                let raw = try DocText.read(url)
                let d = try await CardImport.parse(raw: raw)
                await MainActor.run { draft = d }
            } catch let e as AIError where e.cancelled {
            } catch is CancellationError {
            } catch {
                let message = error.localizedDescription
                await MainActor.run { problem = message }
            }
            await MainActor.run { running = false }
        }
    }

    private func create() {
        guard let d = draft else { return }
        do {
            let c = try CardImport.save(d)
            if withCore && !d.persona.isEmpty {
                let persona = d.persona
                Task.detached {
                    let core = await CardImport.makeCore(persona: persona)
                    guard !core.isEmpty, let fresh = try? Repo.character(c.id) else { return }
                    do { _ = try People.update(fresh, ["core": .string(core)]) }
                    catch { Problems.report("核心设定未能保存：\(error.localizedDescription)") }
                }
            }
            onCreated(c.id)
        } catch {
            problem = "创建失败：\(error.localizedDescription)"
        }
    }
}
