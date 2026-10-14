import AVFoundation
import SwiftUI

/// 一通电话的状态。按回合：你说一句（打字或录一句），角色回一句；字幕是主角，出不出声由喇叭决定。
@MainActor
final class CallSession: ObservableObject {
    enum Phase { case connecting, active, ended }

    let chatId: String
    let char: Character
    @Published var phase: Phase = .connecting
    @Published var lines: [CallEngine.Line] = []
    @Published var draft = ""
    @Published var thinking = false
    @Published var error: String?
    @Published var seconds = 0
    @Published var speak: Bool
    @Published var transcribing = false

    private var prepared: CallEngine.Prepared?
    private var job: Task<Void, Never>?
    private var clock: Timer?
    private var startedAt: Date?
    private let synth = AVSpeechSynthesizer()
    private var finished = false
    let recorder = VoiceRecorder()

    init(chatId: String, char: Character) {
        self.chatId = chatId
        self.char = char
        // 喇叭：手动按过就记住；没按过就看这个角色能不能用语音接口出声（网页版 prefs）
        let s = AppSettings.load()
        speak = s.raw["callSpeak"]?.bool ?? VoiceGen.canSpeak(char, s)
    }

    /// 能用语音接口出这个角色的声音时说明为空；否则说清楚为什么只能用系统合成。
    var voiceWhy: String {
        let s = AppSettings.load()
        if !s.voiceReady { return "尚未配置语音接口，当前使用系统自带的合成。" }
        if char.row["canSendVoice"]?.bool == false { return "该角色的语音已关闭，当前使用系统自带的合成。" }
        if !VoiceGen.canSpeak(char, s) { return "该角色在当前语音接口上尚未设置音色，当前使用系统自带的合成。" }
        return ""
    }

    func start() {
        guard phase == .connecting else { return }
        do {
            guard let chat = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
            prepared = try CallEngine.prepare(chat: chat, char: char)
        } catch {
            self.error = "准备通话内容时出错：\(error.localizedDescription)"
            return
        }
        phase = .active
        startedAt = Date()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let at = self.startedAt, self.phase == .active else { return }
                self.seconds = Int(Date().timeIntervalSince(at))
            }
        }
        // 接通之后由角色先开口
        turn(opening: CallEngine.openingLine(outgoing: true))
    }

    /// 我说了一句。正在说的那一轮掐掉，已经出现在字幕上的半句留下来。
    func say(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, phase == .active else { return }
        hush()
        job?.cancel()
        let cut = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cut.isEmpty { lines.append(.init(role: "char", text: cut)) }
        draft = ""
        lines.append(.init(role: "user", text: t))
        turn(opening: "")
    }

    private func turn(opening: String) {
        guard let prepared else { return }
        let snapshot = lines
        thinking = true
        error = nil
        draft = ""
        job = Task {
            do {
                let text = try await CallEngine.turn(prepared, lines: snapshot, opening: opening) { whole in
                    Task { @MainActor in
                        guard !Task.isCancelled else { return }
                        self.thinking = false
                        self.draft = CallEngine.clean(whole)
                    }
                }
                guard !Task.isCancelled, phase == .active else { return }
                thinking = false
                draft = ""
                guard !text.isEmpty else { error = "对方那边没有声音"; return }
                lines.append(.init(role: "char", text: text))
                if speak { await voice(text, at: lines.count - 1) }
            } catch is CancellationError {
            } catch let e as AIError where e.cancelled {
            } catch {
                guard !Task.isCancelled else { return }
                thinking = false
                self.error = error.localizedDescription
            }
        }
    }

    /// 念一句：能用语音接口就用这个角色的声音（一轮一次，存进文件挂在这一句上），否则用系统合成，不花钱。
    private func voice(_ text: String, at index: Int) async {
        let spoken = CallEngine.prose(text)
        let s = AppSettings.load()
        if VoiceGen.canSpeak(char, s), let p = s.activeVoice {
            do {
                let st = VoiceGen.style(char, p)
                let speed = char.row.number("voiceSpeed") ?? 1
                let data = try await VoiceGen.speak(text: spoken, voiceId: VoiceGen.voiceId(char, presetId: p.id),
                                                    speed: speed > 0 ? speed : 1, prompt: st.prompt, lang: st.lang, preset: p)
                guard phase == .active else { return }
                let id = try Files.save(data, ext: "mp3", type: "audio/mpeg")
                if lines.indices.contains(index) { lines[index].audio.append(id) }
                VoicePlayer.shared.toggle("call-\(index)", audioId: id)
            } catch {
                self.error = "语音合成失败：\(error.localizedDescription)"
            }
        } else {
            let u = AVSpeechUtterance(string: spoken)
            synth.speak(u)
        }
    }

    private func hush() {
        synth.stopSpeaking(at: .immediate)
        VoicePlayer.shared.stop()
    }

    func toggleSpeak() {
        speak.toggle()
        SettingsModel.shared.set("callSpeak", .bool(speak))
        if !speak { hush() }
    }

    /// 录一句：配了识别接口就交给接口，没配用系统识别。
    func toggleRecord() {
        if recorder.recording {
            guard let got = recorder.stop() else { return }
            transcribing = true
            let useApi = AppSettings.load().asrReady
            Task {
                var text = ""
                do {
                    if useApi {
                        text = try await Asr.transcribe(wav: got.0).text
                    } else {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("call-\(UUID().uuidString).wav")
                        try got.0.write(to: url)
                        text = await Asr.local(url)
                        try? FileManager.default.removeItem(at: url)
                    }
                } catch {
                    self.error = error.localizedDescription
                }
                transcribing = false
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if error == nil { error = "未识别到语音，可改为输入文字。" }
                } else {
                    say(text)
                }
            }
        } else {
            hush()
            Task {
                do { try await recorder.start() }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    /// 挂断：落一条通话记录。接通过、有对白的按设置写总结（默认开，失败只记在那条记录上不重试）。
    func hangUp() {
        guard !finished else { return }
        finished = true
        job?.cancel()
        hush()
        recorder.cancel()
        clock?.invalidate()
        let outcome = phase == .active ? "done" : "cancelled"
        let secs = outcome == "done" ? max(1, Int(Date().timeIntervalSince(startedAt ?? Date()))) : 0
        var all = lines
        let cut = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cut.isEmpty { all.append(.init(role: "char", text: cut)) }
        phase = .ended
        do {
            let chat = try Repo.chat(chatId)
            let me = try chat.flatMap { c in try Repo.personas().first { $0.id == c.personaId } } ?? Repo.activePersona()
            let m = try CallEngine.finish(chatId: chatId, charId: char.id, direction: "out", outcome: outcome, seconds: secs,
                                          lines: all, userName: me?.name ?? "", charName: char.name)
            if CallEngine.autoSummary(outcome: outcome, lines: all) {
                let id = m.id
                Task.detached {
                    do { try await CallEngine.summarize(messageId: id) }
                    catch { Diagnostics.shared.record("call-summary-failed", ["error": error.localizedDescription]) }
                }
            }
        } catch {
            Problems.report("通话记录未能保存：\(error.localizedDescription)")
        }
    }
}

/// 通话界面：字幕、喇叭、录音、输入框、挂断。
struct CallView: View {
    @StateObject private var session: CallSession
    @ObservedObject private var recorder: VoiceRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    var onEnd: () -> Void

    init(chatId: String, char: Character, onEnd: @escaping () -> Void) {
        let s = CallSession(chatId: chatId, char: char)
        _session = StateObject(wrappedValue: s)
        _recorder = ObservedObject(wrappedValue: s.recorder)
        self.onEnd = onEnd
    }

    var body: some View {
        VStack(spacing: Theme.pad) {
            VStack(spacing: 6) {
                Avatar(imageId: session.char.avatar, name: session.char.displayName, size: 72)
                Text(session.char.displayName).font(.title3)
                Text(status).font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryText)
            }
            .padding(.top, Theme.pad * 2)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.gap) {
                        ForEach(Array(session.lines.enumerated()), id: \.offset) { _, l in
                            line(l.role == "user" ? "我" : session.char.displayName, l.text, mine: l.role == "user")
                        }
                        if !session.draft.isEmpty { line(session.char.displayName, session.draft, mine: false) }
                        if session.thinking { Text("对方正在说").font(.footnote).foregroundStyle(Theme.tertiaryText) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Theme.pad)
                }
                .onChange(of: session.lines.count) { _, _ in proxy.scrollTo("end") }
                .onChange(of: session.draft) { _, _ in proxy.scrollTo("end") }
            }
            if let e = session.error { Text(e).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal, Theme.pad) }
            if session.speak, !session.voiceWhy.isEmpty {
                Text(session.voiceWhy).font(.caption).foregroundStyle(Theme.secondaryText).padding(.horizontal, Theme.pad)
            }
            HStack(spacing: Theme.gap) {
                TextField("输入要说的话", text: $typed, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(.horizontal, Theme.pad).padding(.vertical, 8)
                    .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                Button {
                    session.say(typed)
                    typed = ""
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .accessibilityLabel("说")
                .disabled(session.phase != .active || typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, Theme.pad)
            HStack(spacing: Theme.pad * 3) {
                Button(action: session.toggleSpeak) {
                    Image(systemName: session.speak ? "speaker.wave.2.fill" : "speaker.slash").font(.title2)
                }
                .accessibilityLabel(session.speak ? "关闭声音" : "打开声音")
                Button(action: session.toggleRecord) {
                    Image(systemName: recorder.recording ? "stop.circle" : "mic").font(.title2)
                }
                .accessibilityLabel(recorder.recording ? "说完了" : "录一句")
                .disabled(session.phase != .active || session.transcribing)
                Button {
                    session.hangUp()
                    onEnd()
                    dismiss()
                } label: {
                    Image(systemName: "phone.down.fill").font(.title2).foregroundStyle(Theme.danger)
                }
                .accessibilityLabel("挂断")
            }
            .padding(.bottom, Theme.pad * 2)
        }
        .background(Theme.background)
        .onAppear { session.start() }
    }

    private var status: String {
        if recorder.recording { return "正在录音 \(recorder.seconds)\u{2033}" }
        if session.transcribing { return "正在识别" }
        switch session.phase {
        case .connecting: return "正在接通"
        case .active: return CallEngine.duration(session.seconds)
        case .ended: return "通话结束"
        }
    }

    private func line(_ who: String, _ text: String, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(who).font(.caption).foregroundStyle(Theme.secondaryText)
            Text(text).foregroundStyle(mine ? Theme.secondaryText : Theme.bubbleTheirsText)
        }
    }
}

/// 聊天记录里的那一条通话记录：时长、总结，点开看整段对白。
struct CallCard: View {
    let message: Message
    @State private var open = false
    @State private var summarizing = false
    @State private var problem: String?
    @State private var summary: String?

    var body: some View {
        let lines = message.content.components(separatedBy: "\n")
        let head = ConversationRowHelpers.unbracket(lines.first ?? "")
        let text = summary ?? message.row.string("callSummary")
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.gap) {
                Image(systemName: "phone").foregroundStyle(Theme.secondaryText)
                Text(head)
            }
            if !text.isEmpty { Text(text).font(.footnote).foregroundStyle(Theme.secondaryText) }
            if lines.count > 1 {
                Button(open ? "收起对白" : "查看对白") { open.toggle() }.font(.footnote)
                if open { Text(lines.dropFirst().joined(separator: "\n")).font(.footnote) }
                if text.isEmpty {
                    Button(summarizing ? "正在生成" : "生成总结") { run() }
                        .font(.footnote).disabled(summarizing)
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(Theme.danger) }
        }
        .padding(Theme.pad)
        .foregroundStyle(Theme.bubbleTheirsText)
        .background(Theme.bubbleTheirs, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
    }

    /// 用户点的，手动一次。
    private func run() {
        summarizing = true
        problem = nil
        let id = message.id
        Task {
            do {
                let t = try await CallEngine.summarize(messageId: id)
                await MainActor.run { summary = t }
            } catch {
                await MainActor.run { problem = "总结未能生成：\(error.localizedDescription)" }
            }
            await MainActor.run { summarizing = false }
        }
    }
}

enum ConversationRowHelpers {
    static func unbracket(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.first == "[", t.last == "]" else { return t }
        return String(t.dropFirst().dropLast())
    }
}
