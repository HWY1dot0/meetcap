// MeetCap — 会议录音管线的菜单栏壳
// 点图标开录 / 停录, 菜单栏实时显示录音时长, 菜单内显示电平条。
// 真正干活的是 meeting_recorder.py(独立进程, app 退出不影响录音)。
// 编译打包: ./build_app.sh

import SwiftUI
import AppKit

// MARK: - 状态模型

final class RecorderVM: ObservableObject {
    enum RecState { case idle, recording, transcribing, summarizing }
    @Published var state: RecState = .idle
    @Published var elapsed: Int = 0
    @Published var rms: Double = 0
    @Published var lastSession: URL?
    @AppStorage("recordMic") var recordMic = true  // 是否同时录自己的麦克风
    @AppStorage("onsite") var onsite = false        // 现场会模式: 麦克风为主轨
    @AppStorage("draftModel") var draftModel = RecorderVM.defaultDraft
    @AppStorage("finalModel") var finalModel = RecorderVM.defaultFinal
    @Published var mode: String = "online"          // 管线回报的实际模式

    // 菜单可选模型(tag, 显示名)。GPT 走 codex CLI, Claude 用 claude CLI 别名(恒指最新版);
    // 管线按模型名自动选引擎, 所以清稿和终稿可以混用两家。
    static let gptModels = [
        ("gpt-6-luna", "GPT-6 Luna · 快"),
        ("gpt-6.1-terra", "GPT-6.1 Terra · 均衡"),
        ("gpt-6.1-sol", "GPT-6.1 Sol · 主力"),
        ("gpt-6-astra", "GPT-6 Astra · 最强"),
    ]
    static let claudeModels = [
        ("haiku", "Claude Haiku · 快"),
        ("sonnet", "Claude Sonnet · 均衡"),
        ("opus", "Claude Opus · 深入"),
        ("fable", "Claude Fable · 最强"),
    ]
    static let defaultDraft = "gpt-6-luna"
    static let defaultFinal = "gpt-6-astra"
    private static let allowed = Set((gptModels + claudeModels).map { $0.0 })

    static let defaultDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings/meetings")
    @Published private(set) var recDir = RecorderVM.defaultDir

    private var timer: Timer?
    private let home = FileManager.default.homeDirectoryForCurrentUser
    // 管线脚本位置由 build_app.sh 在打包时写进 Info.plist(即仓库所在目录)
    let script = Bundle.main.object(forInfoDictionaryKey: "MeetCapScript") as? String ?? ""
    var scriptMissing: Bool { !FileManager.default.isExecutableFile(atPath: script) }
    private var pidfile: URL { home.appendingPathComponent(".meeting_recorder.pid") }

    init() {
        reloadConfig()
        // 旧版存下的已下架模型(如 gpt-5.6-*)会让菜单无选中项: 迁到默认值
        if !Self.allowed.contains(draftModel) { draftModel = Self.defaultDraft }
        if !Self.allowed.contains(finalModel) { finalModel = Self.defaultFinal }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 0.3
        poll()
    }

    // ---- 轮询: pidfile 判活 + status.json 取状态 ----
    func poll() {
        lastSession = newestSession()
        guard let pidStr = try? String(contentsOf: pidfile, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else {
            state = .idle
            return
        }
        // 管线活着: 细分 recording / processing
        guard let sess = lastSession,
              let data = try? Data(contentsOf: sess.appendingPathComponent("status.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["state"] as? String else {
            state = .recording  // 状态文件未就绪时按录音中显示
            return
        }
        switch s {
        case "transcribing", "processing":
            state = .transcribing
        case "summarizing":
            state = .summarizing
        default:
            state = .recording
            elapsed = obj["elapsed"] as? Int ?? 0
            rms = obj["rms"] as? Double ?? 0
            mode = obj["mode"] as? String ?? "online"
        }
    }

    private func newestSession() -> URL? {
        (try? FileManager.default.contentsOfDirectory(
            at: recDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?
            // 只认管线建的场次目录(20261029_1040), 保存位置里可能还有别的文件夹
            .filter { $0.hasDirectoryPath
                && $0.lastPathComponent.range(of: #"^\d{8}_\d{4}$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    func reloadConfig() {
        let dir = MeetCapConfig.load()["output_dir"] ?? ""
        recDir = dir.isEmpty ? Self.defaultDir : URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    }

    // ---- 动作 ----
    private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func shell(_ cmd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]  // login shell: 带上用户完整 PATH(uv/codex/ffmpeg 都在)
        try? p.run()
    }

    func startRecording() {
        // AppStorage 可被外部 defaults 改写; 只把白名单模型拼进 shell 命令。
        let draft = Self.allowed.contains(draftModel) ? draftModel : Self.defaultDraft
        let final = Self.allowed.contains(finalModel) ? finalModel : Self.defaultFinal
        let flags = (onsite ? " --onsite" : "") + (recordMic ? "" : " --no-mic")
            + " --model \(draft) --final-model \(final)"
        // taskpolicy -c utility: 整条管线走效率档(效率核+低 GPU 优先级), 压发热;
        // 转写慢两三成但均为后台活, 仅停录后尾块多等十几秒
        shell("nohup taskpolicy -c utility \(shq(script))\(flags) >/dev/null 2>&1 &")
    }

    func stopRecording() {
        shell("\(shq(script)) --stop")
    }

    func openLatestMinutes() {
        guard let sess = newestSession() else { return }
        let minutes = sess.appendingPathComponent("minutes.md")
        if FileManager.default.fileExists(atPath: minutes.path) {
            NSWorkspace.shared.open(minutes)
        } else {
            NSWorkspace.shared.open(sess)
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recDir)
    }

    // ---- 展示辅助 ----
    var elapsedText: String { String(format: "%d:%02d", elapsed / 60, elapsed % 60) }
    var levelBar: String {
        // rms 典型范围 0.001(静)~0.1(响), 对数映射到 0-10 格
        let db = 20 * log10(max(rms, 1e-5))            // -100 ~ -20
        let n = max(0, min(10, Int((db + 60) / 4)))    // -60dB→0 格, -20dB→10 格
        return String(repeating: "▮", count: n) + String(repeating: "▯", count: 10 - n)
    }
    var levelChar: String {
        // 菜单栏单字符电平: 不点开也能看到声音在跳
        let db = 20 * log10(max(rms, 1e-5))
        let bars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let n = max(0, min(7, Int((db + 60) / 5)))
        return bars[n]
    }
}

// MARK: - 设置(与 meeting_recorder.py 共用一份 JSON)

enum MeetCapConfig {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MeetCap/config.json")

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }

    /// 空值即删除该项。里面可能有 API key: 目录 0700、文件 0600, 只有本人账户可读。
    static func save(_ values: [String: String]) throws {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let clean = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        let data = try JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

struct SettingsView: View {
    @EnvironmentObject var vm: RecorderVM
    @State private var outputDir = ""
    @State private var speaker = ""
    @State private var openaiKey = ""
    @State private var anthropicKey = ""
    @State private var status = ""

    var body: some View {
        Form {
            Section("纪要与录音") {
                LabeledContent("保存位置") {
                    Text(outputDir.isEmpty ? RecorderVM.defaultDir.path : outputDir)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("恢复默认") { outputDir = "" }.disabled(outputDir.isEmpty)
                    Button("选择文件夹…", action: chooseFolder)
                }
                TextField("我的署名", text: $speaker, prompt: Text("本人"))
            }
            Section {
                SecureField("OpenAI API Key", text: $openaiKey, prompt: Text("留空则用 codex 登录"))
                SecureField("Anthropic API Key", text: $anthropicKey, prompt: Text("留空则用 claude 登录"))
            } header: {
                Text("API Key(可选)")
            } footer: {
                Text("填了哪家就直连该家 API、按量计费；留空则用本机已登录的 codex / claude 命令行。"
                     + "Key 只保存在本机 ~/Library/Application Support/MeetCap/config.json，仅你的账户可读。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(vm.state == .idle ? status : "录音进行中，结束后再改设置")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .disabled(vm.state != .idle)  // 录音中换目录会让菜单找不到当前场次
        .onAppear {
            load()
            NSApp.activate(ignoringOtherApps: true)  // 菜单栏 app 的窗口默认不在最前
        }
    }

    private func load() {
        let cfg = MeetCapConfig.load()
        outputDir = cfg["output_dir"] ?? ""
        speaker = cfg["speaker"] ?? ""
        openaiKey = cfg["openai_api_key"] ?? ""
        anthropicKey = cfg["anthropic_api_key"] ?? ""
        status = ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: outputDir.isEmpty ? RecorderVM.defaultDir.path : outputDir)
        if panel.runModal() == .OK, let url = panel.url { outputDir = url.path }
    }

    private func save() {
        do {
            try MeetCapConfig.save(["output_dir": outputDir, "speaker": speaker,
                                    "openai_api_key": openaiKey, "anthropic_api_key": anthropicKey])
            vm.reloadConfig()
            status = "已保存，下次开录生效"
        } catch {
            status = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - App

@main
struct MeetCapApp: App {
    @StateObject private var vm = RecorderVM()

    @ViewBuilder private var modelOptions: some View {
        ForEach(RecorderVM.gptModels, id: \.0) { Text($0.1).tag($0.0) }
        Divider()
        ForEach(RecorderVM.claudeModels, id: \.0) { Text($0.1).tag($0.0) }
    }

    var body: some Scene {
        MenuBarExtra {
            switch vm.state {
            case .idle:
                if vm.scriptMissing {
                    Text("找不到 meeting_recorder.py，请在仓库里重新运行 build_app.sh")
                }
                Button(vm.onsite ? "开始录音 (现场会)" : "开始录音") { vm.startRecording() }
                    .keyboardShortcut("r")
                    .disabled(vm.scriptMissing)
                Toggle("现场会模式 (用麦克风收全场)", isOn: vm.$onsite)
                Toggle("同时录我的麦克风", isOn: vm.$recordMic)
                    .disabled(vm.onsite)  // 现场模式强制开麦
                Picker("清稿 / 提纲模型", selection: vm.$draftModel) { modelOptions }
                Picker("最终纪要模型", selection: vm.$finalModel) { modelOptions }
            case .recording:
                Text(vm.mode == "onsite"
                     ? "现场收音中 \(vm.elapsedText)"
                     : (vm.rms < 0.0001
                        ? "录音中 \(vm.elapsedText)   (等待声音…)"
                        : "录音中 \(vm.elapsedText)   \(vm.levelBar)"))
                Button("停止录音, 生成纪要") { vm.stopRecording() }
                    .keyboardShortcut("s")
            case .transcribing:
                Text("① 转写收尾中…")
                Button("打开快版纪要(如已生成)") { vm.openLatestMinutes() }
            case .summarizing:
                Text("② 纪要生成中…")
                Button("打开快版纪要(如已生成)") { vm.openLatestMinutes() }
            }
            Divider()
            Button("打开最近纪要") { vm.openLatestMinutes() }
            Button("打开录音文件夹") { vm.openFolder() }
            SettingsLink { Text("设置…") }
                .keyboardShortcut(",")
            Divider()
            Button("退出 MeetCap") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            switch vm.state {
            case .idle:
                Image(systemName: "mic")
            case .recording:
                HStack(spacing: 2) {
                    Image(systemName: vm.mode == "onsite" ? "mic.fill" : "record.circle.fill")
                    Text(vm.mode == "onsite" ? vm.elapsedText : "\(vm.elapsedText) \(vm.levelChar)")
                        .monospacedDigit()
                }
            case .transcribing:
                HStack(spacing: 3) {
                    Image(systemName: "waveform")
                    Text("转写…")
                }
            case .summarizing:
                HStack(spacing: 3) {
                    Image(systemName: "doc.text")
                    Text("纪要…")
                }
            }
        }

        Settings {
            SettingsView().environmentObject(vm)
        }
    }
}
