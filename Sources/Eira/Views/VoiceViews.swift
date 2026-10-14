import SwiftUI

/// 一条语音：播放、时长、文字，以及生成或识别的状态。
struct VoiceBubble: View {
    let message: Message
    let mine: Bool
    var onRevoice: () -> Void

    @ObservedObject private var player = VoicePlayer.shared
    @State private var synthesizing = true
    @State private var length = 0

    var body: some View {
        let audioId = message.row.string("audioId")
        let media = message.row.string("media")
        let err = message.row.string("mediaError")
        let text = message.row.string("voiceText")
        let playing = player.playing == message.id
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            HStack(spacing: Theme.gap) {
                if !audioId.isEmpty {
                    Button { player.toggle(message.id, audioId: audioId) } label: {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playing ? "停止播放" : "播放语音")
                } else {
                    Image(systemName: "waveform").foregroundStyle(Theme.secondaryText)
                }
                Text(seconds > 0 ? "\(seconds)\u{2033}" : "语音").font(.footnote.monospacedDigit())
            }
            if !text.isEmpty {
                Text(text).font(.footnote)
            }
            status(media: media, err: err)
        }
        .padding(Theme.pad)
        .foregroundStyle(mine ? Theme.bubbleMineText : Theme.bubbleTheirsText)
        .background(mine ? Theme.bubbleMine : Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
        .task(id: "\(message.id)|\(media)|\(audioId)") {
            synthesizing = media == "pending" && MediaJobs.isRunning(message.id)
            if message.row.number("seconds") == nil && !audioId.isEmpty { length = VoicePlayer.duration(audioId) }
        }
    }

    private var seconds: Int {
        if let s = message.row.number("seconds") { return Int(s) }
        return length
    }

    @ViewBuilder private func status(media: String, err: String) -> some View {
        if mine {
            switch message.row.string("asr") {
            case "pending": Text("正在识别").font(.caption).foregroundStyle(Theme.secondaryText)
            case "error": Text(err.isEmpty ? "识别失败" : err).font(.caption).foregroundStyle(Theme.danger)
            default: EmptyView()
            }
        } else {
            if media == "pending" {
                if synthesizing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在合成语音").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    Text("合成已中断").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            } else if !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(media == "error" ? Theme.danger : Theme.secondaryText)
            }
            if media != "done" && !(media == "pending" && synthesizing) && SettingsModel.shared.s.voiceReady {
                Button("重新合成", action: onRevoice).font(.footnote).buttonStyle(.bordered)
            }
        }
    }
}

/// 发一条语音：录音，或者改为输入文字。
struct VoiceComposeView: View {
    let chatId: String
    let quote: Message?
    var onSent: (Message) -> Void

    @StateObject private var recorder = VoiceRecorder()
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var typing = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.pad * 2) {
                if typing {
                    TextField("语音内容", text: $typed, axis: .vertical)
                        .lineLimit(3...8)
                        .padding(Theme.pad)
                        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                    Text("将作为一条语音发出，角色收到的内容与录音一致。")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                    Button("发送", action: sendTyped)
                        .buttonStyle(.bordered)
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Text(recorder.recording ? "\(recorder.seconds)\u{2033}" : "点按开始录音")
                        .font(.title3.monospacedDigit())
                    Button(action: toggle) {
                        Image(systemName: recorder.recording ? "stop.circle" : "mic.circle")
                            .font(.system(size: 64))
                    }
                    .accessibilityLabel(recorder.recording ? "停止并发送" : "开始录音")
                    Text(AppSettings.load().asrReady
                         ? "录音结束后交给语音识别接口转成文字，每条调用一次。"
                         : "未配置语音识别接口，录音结束后由系统识别转成文字，不调用接口。")
                        .font(.footnote).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
                Spacer()
            }
            .padding(Theme.pad * 2)
            .navigationTitle("语音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { recorder.cancel(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(typing ? "改为录音" : "改为输入") {
                        recorder.cancel()
                        typing.toggle()
                    }
                }
            }
        }
        .onDisappear { recorder.cancel() }
    }

    private func toggle() {
        problem = nil
        if recorder.recording {
            guard let got = recorder.stop() else { problem = "录音为空，未发送。"; return }
            do {
                let m = try Asr.sendRecording(got.0, seconds: got.1, chatId: chatId, quote: quote) { updated in
                    Task { @MainActor in onSent(updated) }
                }
                onSent(m)
                dismiss()
            } catch {
                problem = "语音未能保存：\(error.localizedDescription)"
            }
        } else {
            Task {
                do { try await recorder.start() }
                catch { await MainActor.run { problem = error.localizedDescription } }
            }
        }
    }

    private func sendTyped() {
        do {
            onSent(try Asr.sendTyped(typed, chatId: chatId, quote: quote))
            dismiss()
        } catch {
            problem = "语音未能保存：\(error.localizedDescription)"
        }
    }
}

/// 「设置 - 接口与服务 - 语音合成」：总开关与几套接口（网页版 settings/VoicePage.js）。
struct VoiceSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                Toggle("角色发送语音", isOn: Binding(get: { model.s.voiceEnabled },
                                                    set: { v in model.update { $0.setVoiceEnabled(v) } }))
            } footer: {
                Text("每条语音调用一次语音接口。")
                HelpNote("开启且当前接口填全后，在角色卡上为角色填写音色，角色即可在回复里发语音：每条语音调用一次语音接口，失败不自动重试。关闭后角色不再发语音，已有的语音照常播放。")
            }
            Section {
                ForEach(model.s.voicePresets) { p in
                    NavigationLink { VoicePresetEditView(id: p.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text((VoicePreset.kinds.first { $0.id == p.kind }?.label ?? p.kind) + (p.model.isEmpty ? "" : " · \(p.model)"))
                                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            if p.id == model.s.activeVoice?.id { Text("当前").foregroundStyle(Theme.secondaryText) }
                        }
                    }
                }
                Button("新建语音接口") { model.update { $0.addVoicePreset() } }
            } header: {
                Text("语音接口")
            } footer: {
                HelpNote("角色的音色按接口分别填写：换一套接口后，需在角色卡上为这一套另填音色。")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("语音合成")
        .onAppear { model.reload() }
    }
}

struct VoicePresetEditView: View {
    let id: String
    @ObservedObject private var model = SettingsModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sample = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOk = false
    @State private var confirmDelete = false

    private var preset: VoicePreset? { model.s.voicePresets.first { $0.id == id } }

    var body: some View {
        Form {
            if let p = preset {
                Section {
                    TextField("名称", text: field("name"))
                    Picker("类型", selection: field("kind", def: "minimax")) {
                        ForEach(VoicePreset.kinds) { Text($0.label).tag($0.id) }
                    }
                    if p.id != model.s.activeVoice?.id {
                        Button("设为当前") { model.update { $0.setActiveVoice(id) } }
                    }
                } footer: {
                    HelpNote(kindNote(p.kind))
                }
                Section("连接") {
                    TextField(VoicePreset.kinds.first { $0.id == p.kind }?.base ?? "接口地址", text: field("baseUrl"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API Key", text: field("apiKey"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if p.kind == "minimax" {
                        TextField("GroupId（新版密钥可留空）", text: field("groupId"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    TextField(p.kind == "eleven" ? "模型（可留空）" : p.kind == "minimax" ? "模型，如 speech-02-hd" : "模型，如 gpt-4o-mini-tts",
                              text: field("model"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Picker("语种", selection: field("lang")) {
                        ForEach(VoicePreset.langs) { Text($0.label).tag($0.id) }
                    }
                    TextField("风格", text: field("prompt"), axis: .vertical)
                } header: {
                    Text("默认风格")
                } footer: {
                    HelpNote("角色卡上填写了风格与语种时以角色卡为准。MiniMax 的风格只接受固定的情绪词（高兴、难过、生气、害怕、厌恶、惊讶、平静），其余不发送。")
                }
                Section {
                    TextField("试听用的音色 ID", text: $sample)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(testing ? "正在合成" : "试听") { runTest(p) }.disabled(testing || !p.ready)
                    if let testResult { Text(testResult).font(.footnote).foregroundStyle(testOk ? Theme.secondaryText : Theme.danger) }
                } footer: {
                    Text("按一次语音合成计费。")
                    HelpNote("合成一句短句并播放，按一次语音合成计费。")
                }
                Section {
                    Button("删除这套接口", role: .destructive) { confirmDelete = true }.foregroundStyle(Theme.dangerText)
                }
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle(preset?.name ?? "语音接口")
        .confirmationDialog("删除这套语音接口？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                model.update { $0.removeVoicePreset(id) }
                dismiss()
            }
        }
    }

    private func kindNote(_ k: String) -> String {
        switch k {
        case "openai": return "走 /v1/audio/speech。OpenAI 本身与绝大多数中转站都是这一种。"
        case "eleven": return "音色填 voice id。模型留空时使用该账号的默认模型。"
        default: return "国内账号用 api.minimaxi.com，国际账号用 api.minimax.io。新版密钥不需要 GroupId。"
        }
    }

    private func field(_ key: String, def: String = "") -> Binding<String> {
        Binding(get: { preset?.json[key]?.string ?? def },
                set: { v in model.update { $0.patchVoicePreset(id, [key: .string(v)]) } })
    }

    private func runTest(_ p: VoicePreset) {
        testing = true
        testResult = nil
        let vid = sample.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let data = try await VoiceGen.speak(text: "你好，这是一段试听。", voiceId: vid, preset: p)
                let fid = try Files.save(data, ext: "mp3", type: "audio/mpeg")
                await MainActor.run {
                    VoicePlayer.shared.toggle("voice-test", audioId: fid)
                    testResult = "合成成功，正在播放。"
                    testOk = true
                }
            } catch {
                await MainActor.run { testResult = error.localizedDescription; testOk = false }
            }
            await MainActor.run { testing = false }
        }
    }
}

/// 「设置 - 接口与服务 - 语音识别」：你发的语音交给哪套接口读成文字（网页版 settings/AsrPage.js）。
struct AsrSettingsView: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                Picker("识别方式", selection: Binding(get: { model.s.asrMode },
                                                      set: { v in model.update { $0.setService("asr", ["mode": .string(v)]) } })) {
                    Text("只转文字").tag("text")
                    Text("连语气一起读").tag("tone")
                }
                .pickerStyle(.segmented)
            } footer: {
                HelpNote(model.s.asrMode == "tone"
                     ? "走 chat/completions，把录音交给能听声音的多模态模型，同时读出文字、语气、情绪与语速。普通的 whisper 端点不支持这一档。"
                     : "走 /audio/transcriptions（whisper 一类），只转成文字。绝大多数中转站都提供。")
            }
            ServiceConnSection(name: "asr", modelHint: "", showTest: false,
                               endpointNote: "OpenAI 兼容的端点。地址留空时使用 https://api.openai.com/v1。") { nil }
            Section {
                Button("清空配置", role: .destructive) {
                    model.update { $0.setService("asr", ["apiKey": .string(""), "model": .string(""), "baseUrl": .string(""), "endpointId": .string("")]) }
                }
            } footer: {
                Text("配置后每条语音调用一次识别接口。")
                HelpNote("未配置时，录音由系统识别转成文字，不调用接口。配置后每条语音调用一次识别接口。")
            }
            ProblemSection(text: model.problem)
        }
        .navigationTitle("语音识别")
    }
}
