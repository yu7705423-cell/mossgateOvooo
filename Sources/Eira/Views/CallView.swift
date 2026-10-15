import AVFoundation
import SwiftUI

/// 一通电话的状态。按回合：你说一句（打字或录一句），角色回一句；字幕是主角，出不出声由喇叭决定。
@MainActor
final class CallSession: ObservableObject {
    enum Phase { case ringing, connecting, active, ended }

    let chatId: String
    let char: Character
    /// out：我打出去；in：角色打进来（响铃，接了才接通）
    let direction: String
    /// 视频通话：角色把看得见的动作写成 [动作：…]；我这边开了摄像头、识图交给聊天模型时，角色看得见画面
    let video: Bool
    /// 我这边用真实摄像头，而不是头像（记住上次怎么选的，网页版 callSelfReal）
    @Published var selfReal: Bool
    let camera = CallCamera()
    @Published var phase: Phase = .connecting
    @Published var lines: [CallEngine.Line] = []
    @Published var draft = ""
    @Published var thinking = false
    @Published var error: String?
    @Published var seconds = 0
    /// 挂断时的结果：done / cancelled / declined / missed
    @Published var outcome = ""
    @Published var speak: Bool
    @Published var transcribing = false

    private var prepared: CallEngine.Prepared?
    private var job: Task<Void, Never>?
    private var clock: Timer?
    private var startedAt: Date?
    private let synth = AVSpeechSynthesizer()
    private var finished = false
    private var framedAt: Date?
    let recorder = VoiceRecorder()

    init(chatId: String, char: Character, incoming: Bool = false, video: Bool = false) {
        self.chatId = chatId
        self.char = char
        self.direction = incoming ? "in" : "out"
        self.video = video
        selfReal = AppSettings.load().raw["callSelfReal"]?.bool == true
        if incoming { phase = .ringing }
        // 喇叭：默认关，按了才记住开着（网页版 callSpeak === true）。开着且有音色时每句走一次语音合成接口，
        // 是会多花钱的那一种，登记在 ExtraCalls 的 callVoice（第 15 条：默认关）
        speak = AppSettings.load().raw["callSpeak"]?.bool == true
    }

    /// 能用语音接口出这个角色的声音时说明为空；否则说清楚为什么只能用系统合成。
    var voiceWhy: String {
        let s = AppSettings.load()
        if !s.voiceReady { return "尚未配置语音接口，当前使用系统自带的合成。" }
        if char.row["canSendVoice"]?.bool == false { return "该角色的语音已关闭，当前使用系统自带的合成。" }
        if !VoiceGen.canSpeak(char, s) { return "该角色在当前语音接口上尚未设置音色，当前使用系统自带的合成。" }
        return ""
    }

    /// 角色打进来时先响铃：响够 20 秒没人接就是未接来电（网页版 call.ring）
    func ring() {
        guard phase == .ringing else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .ringing else { return }
                self.end(outcome: "missed")
            }
        }
    }

    func accept() {
        guard phase == .ringing else { return }
        clock?.invalidate()
        phase = .connecting
        start()
    }

    func start() {
        guard phase == .connecting else { return }
        do {
            guard let chat = try Repo.chat(chatId) else { throw StoreError(message: "这段会话不存在") }
            prepared = try CallEngine.prepare(chat: chat, char: char, video: video)
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
        if video && selfReal { Task { await openCamera() } }
        // 接通之后由角色先开口
        turn(opening: CallEngine.openingLine(outgoing: direction == "out"))
    }

    /// 角色看不看得见我：视频通话、开着摄像头、识图是「交给聊天模型」那一档（另配识图接口要先多调一次，通话里不用）
    var charCanSee: Bool { video && selfReal && camera.running && AppSettings.load().visionMode == "chat" }

    /// 开着摄像头却看不见时说清楚为什么
    var seeWhy: String {
        guard video && selfReal else { return "" }
        if AppSettings.load().visionMode != "chat" { return "识图未设为「交给聊天模型」，角色看不到画面。" }
        return ""
    }

    private func openCamera() async {
        do { try await camera.start() }
        catch {
            selfReal = false
            self.error = "打不开摄像头：\(error.localizedDescription)"
        }
    }

    /// 我这边给对方看头像还是摄像头
    func toggleSelf() {
        selfReal.toggle()
        SettingsModel.shared.set("callSelfReal", .bool(selfReal))
        if !selfReal { camera.stop(); return }
        if phase == .active && video { Task { await openCamera() } }
    }

    /// 这一轮要不要带一帧画面：两帧之间至少隔 callFrameGap 秒（默认 0，每轮都带）
    private func frame() -> AIImage? {
        guard charCanSee else { return nil }
        let gap = max(0, AppSettings.load().raw["callFrameGap"]?.number ?? 0)
        if let at = framedAt, Date().timeIntervalSince(at) < gap { return nil }
        guard let img = camera.grab() else { return nil }
        framedAt = Date()
        return img
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
        let image = frame()
        thinking = true
        error = nil
        draft = ""
        job = Task {
            do {
                let text = try await CallEngine.turn(prepared, lines: snapshot, opening: opening, image: image) { whole in
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
        let spoken = CallEngine.speakable(text)
        guard !spoken.isEmpty else { return }
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
            let u = AVSpeechUtterance(string: VoiceScript.plain(spoken))
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
        // 响铃时挂掉是拒接，拨号中挂掉是已取消
        end(outcome: phase == .active ? "done" : phase == .ringing ? "declined" : "cancelled")
    }

    func end(outcome: String) {
        guard !finished else { return }
        finished = true
        self.outcome = outcome
        job?.cancel()
        hush()
        recorder.cancel()
        camera.stop()
        clock?.invalidate()
        let secs = outcome == "done" ? max(1, Int(Date().timeIntervalSince(startedAt ?? Date()))) : 0
        var all = lines
        let cut = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cut.isEmpty { all.append(.init(role: "char", text: cut)) }
        phase = .ended
        do {
            let chat = try Repo.chat(chatId)
            let me = try chat.flatMap { c in try Repo.personas().first { $0.id == c.personaId } } ?? Repo.activePersona()
            let m = try CallEngine.finish(chatId: chatId, charId: char.id, direction: direction, outcome: outcome, seconds: secs,
                                          lines: all, userName: me?.name ?? "", charName: char.name, video: video)
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
    @ObservedObject private var camera: CallCamera
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    var onEnd: () -> Void

    init(chatId: String, char: Character, incoming: Bool = false, video: Bool = false, onEnd: @escaping () -> Void) {
        let s = CallSession(chatId: chatId, char: char, incoming: incoming, video: video)
        _session = StateObject(wrappedValue: s)
        _recorder = ObservedObject(wrappedValue: s.recorder)
        _camera = ObservedObject(wrappedValue: s.camera)
        self.onEnd = onEnd
    }

    var body: some View {
        VStack(spacing: Theme.pad) {
            if session.video {
                screen
            } else {
                VStack(spacing: 6) {
                    Avatar(imageId: session.char.avatar, name: session.char.displayName, size: 72)
                    Text(session.char.displayName).font(.title3)
                    Text(status).font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
                .padding(.top, Theme.pad * 2)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.gap) {
                        ForEach(Array(session.lines.enumerated()), id: \.offset) { _, l in
                            line(l.role == "user" ? "我" : session.char.displayName, CallEngine.subtitle(l.text), mine: l.role == "user")
                        }
                        if !CallEngine.subtitle(session.draft).isEmpty { line(session.char.displayName, CallEngine.subtitle(session.draft), mine: false) }
                        if session.thinking { Text("对方正在说").font(.footnote).foregroundStyle(Theme.tertiaryText) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Theme.pad)
                }
                .onChange(of: session.lines.count) { _, _ in proxy.scrollTo("end") }
                .onChange(of: session.draft) { _, _ in proxy.scrollTo("end") }
            }
            if let e = session.error { Text(e).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal, Theme.pad) }
            if !session.seeWhy.isEmpty {
                Text(session.seeWhy).font(.caption).foregroundStyle(Theme.secondaryText).padding(.horizontal, Theme.pad)
            }
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
                if session.video {
                    Button(action: session.toggleSelf) {
                        Image(systemName: session.selfReal ? "video.fill" : "video.slash").font(.title2)
                    }
                    .accessibilityLabel(session.selfReal ? "关闭摄像头" : "打开摄像头")
                }
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
        .overlay(alignment: .bottom) { if session.phase == .ringing { ringingBar } }
        .onAppear { session.phase == .ringing ? session.ring() : session.start() }
        .onChange(of: session.outcome) { _, o in
            // 响够了没人接：未接来电已经记下，收起来电页
            if o == "missed" { onEnd(); dismiss() }
        }
    }

    private var status: String {
        if recorder.recording { return "正在录音 \(recorder.seconds)\u{2033}" }
        if session.transcribing { return "正在识别" }
        switch session.phase {
        case .ringing: return session.video ? "邀请你视频通话" : "邀请你语音通话"
        case .connecting: return "正在接通"
        case .active: return CallEngine.duration(session.seconds)
        case .ended: return "通话结束"
        }
    }

    /// 视频通话的画面：对方是头像（或「见面」时的形象），最近一个动作叠在下沿；右上角是我这边
    private var screen: some View {
        let act = CallEngine.lastAct(session.draft.isEmpty ? (session.lines.last(where: { $0.role == "char" })?.text ?? "") : session.draft)
        return ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottom) {
                Group {
                    if session.char.avatar.isEmpty {
                        Avatar(imageId: "", name: session.char.displayName, size: 120)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        LocalImage(id: session.char.avatar, maxPixel: 900)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                }
                VStack(spacing: 4) {
                    if !act.isEmpty {
                        Text(act).font(.footnote).multilineTextAlignment(.center)
                    }
                    Text("\(session.char.displayName)  \(status)").font(.caption.monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.pad).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.45))
            }
            Group {
                if session.selfReal && camera.running {
                    CameraPreview(session: camera.session)
                } else {
                    ZStack {
                        Theme.bubbleTheirs
                        Image(systemName: "video.slash").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .frame(width: 90, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
            .padding(Theme.gap)
        }
        .frame(height: 320)
        .background(Theme.bubbleTheirs)
    }

    /// 响铃时盖在底部：拒接、接听
    private var ringingBar: some View {
        HStack(spacing: Theme.pad * 4) {
            Button {
                session.hangUp()
                onEnd()
                dismiss()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "phone.down.fill").font(.title).foregroundStyle(Theme.danger)
                    Text("拒接").font(.footnote).foregroundStyle(Theme.text2)
                }
            }
            .accessibilityLabel("拒接")
            Button { session.accept() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "phone.fill").font(.title).foregroundStyle(Theme.text)
                    Text("接听").font(.footnote).foregroundStyle(Theme.text2)
                }
            }
            .accessibilityLabel("接听")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.pad * 2)
        .background(Theme.background)
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
                if open { CallLogLines(message: message, fallback: lines.dropFirst().joined(separator: "\n")) }
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

/// 通话记录展开后的对白：一句一行，通话时合成过声音的那几句可以再听（网页版逐句播放）
struct CallLogLines: View {
    let message: Message
    let fallback: String
    @ObservedObject private var player = VoicePlayer.shared

    var body: some View {
        let log = (message.row["callLog"]?.array ?? []).compactMap(\.object)
        if log.isEmpty {
            Text(fallback).font(.footnote)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(log.indices, id: \.self) { i in
                    let l = log[i]
                    let audio = (l["audio"]?.array ?? []).compactMap(\.string).first ?? ""
                    let key = "\(message.id)-\(i)"
                    HStack(alignment: .top, spacing: 6) {
                        Text(CallEngine.subtitle(l["text"]?.string ?? ""))
                            .font(.footnote)
                            .foregroundStyle(l["role"]?.string == "user" ? Theme.secondaryText : Theme.bubbleTheirsText)
                        Spacer(minLength: 0)
                        if !audio.isEmpty {
                            Button { player.toggle(key, audioId: audio) } label: {
                                Image(systemName: player.playing == key ? "stop.circle" : "play.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(player.playing == key ? "停止" : "播放这一句")
                        }
                    }
                }
            }
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
