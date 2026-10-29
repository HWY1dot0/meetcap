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
    @Published var mode: String = "online"          // 管线回报的实际模式
    // 模型选择存在设置文件里, "auto" = 每次按本机可用的模型自动挑
    @Published private(set) var draftModel = "auto"
    @Published private(set) var finalModel = "auto"
    @Published private(set) var detection: Detection?  // 本机可用的 AI(管线 --detect 的结果)
    @Published private(set) var detecting = false

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
        detect()
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
        let cfg = MeetCapConfig.load()
        let dir = cfg["output_dir"] ?? ""
        recDir = dir.isEmpty ? Self.defaultDir : URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        draftModel = cfg["draft_model"] ?? "auto"
        finalModel = cfg["final_model"] ?? "auto"
    }

    /// 后台跑一次管线的 --detect: 哪些通道已登录 / 填了 key, 各有哪些模型, 自动会挑谁
    func detect() {
        guard !scriptMissing, !detecting else { return }
        detecting = true
        let cmd = "\(shq(script)) --detect"
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            let out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var result: Detection?
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last {
                    result = try? JSONDecoder().decode(Detection.self, from: Data(line.utf8))
                }
            }
            DispatchQueue.main.async {
                self.detection = result
                self.detecting = false
            }
        }
    }

    func modelName(_ id: String) -> String {
        detection?.models.first { $0.id == id }?.name ?? id
    }

    func modelLabel(_ id: String) -> String {
        detection?.models.first { $0.id == id }?.label ?? id
    }

    /// 菜单里的一行: 「自动 · GPT-6-Luna」或具体模型名
    func describe(_ choice: String, auto: String?) -> String {
        guard choice == "auto" else { return modelLabel(choice) }
        if let auto { return "自动 · \(modelLabel(auto))" }
        return detecting ? "自动 · 检测中…" : "自动"
    }

    var noAI: Bool { detection.map { $0.models.isEmpty } ?? false }

    // ---- 动作 ----
    private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func shell(_ cmd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]  // login shell: 带上用户完整 PATH(uv/codex/ffmpeg 都在)
        try? p.run()
    }

    func startRecording() {
        // 已检测过就把「自动」的结果直接传下去, 省掉管线开录前再检测的一两秒;
        // 没检测完则不传, 管线自己读设置并检测
        let draft = draftModel == "auto" ? detection?.auto.draft : draftModel
        let final = finalModel == "auto" ? detection?.auto.finalModel : finalModel
        var flags = (onsite ? " --onsite" : "") + (recordMic ? "" : " --no-mic")
        if let draft, let final { flags += " --model \(shq(draft)) --final-model \(shq(final))" }
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

struct Detection: Decodable {
    struct Model: Decodable, Hashable {
        let id: String
        let name: String
        let provider: String
        let tier: String?        // 快 / 均衡 / 最强…, 未知型号为空
        let recommended: Bool    // 默认勾进下拉
        let enabled: Bool        // 按已保存的勾选(没勾过就是推荐)
        var label: String { tier.map { "\(name) · \($0)" } ?? name }
    }
    struct Channel: Decodable { let via: String?; let note: String }
    struct Auto: Decodable {
        let draft: String?
        let finalModel: String?
        enum CodingKeys: String, CodingKey { case draft, finalModel = "final" }
    }
    let channels: [String: Channel]
    let models: [Model]
    let auto: Auto
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
    @State private var customEnv = ""
    @State private var draftChoice = "auto"
    @State private var finalChoice = "auto"
    @State private var draftTyped = ""
    @State private var finalTyped = ""
    @State private var status = ""
    @State private var savedEnabled: String?       // 设置文件里的勾选(没勾过为空)
    @State private var editedEnabled: Set<String>?  // 本次在「管理」里改过的勾选
    @State private var showLibrary = false

    private static let typedTag = "__typed__"
    static let groups = [("GPT", "codex"), ("Claude", "claude"), ("其他 AI", "custom")]
    // 常见的 OpenAI 兼容接口: (名称, 接口地址, 申请 API key 的网址)
    private static let presets = [
        ("Kimi（月之暗面）", "https://api.moonshot.cn/v1", "https://platform.moonshot.cn"),
        ("DeepSeek", "https://api.deepseek.com/v1", "https://platform.deepseek.com"),
        ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai/", "https://aistudio.google.com/apikey"),
        ("通义千问（阿里云百炼）", "https://dashscope.aliyuncs.com/compatible-mode/v1", "https://bailian.console.aliyun.com"),
        ("智谱 GLM", "https://open.bigmodel.cn/api/paas/v4", "https://open.bigmodel.cn"),
        ("腾讯混元", "https://api.hunyuan.cloud.tencent.com/v1", "https://console.cloud.tencent.com/hunyuan"),
        ("OpenRouter（一个 key 用多家模型）", "https://openrouter.ai/api/v1", "https://openrouter.ai/keys"),
    ]
    // 让用户把这段话发给自己常用的 AI, 由它告诉用户该填什么
    private static let helpPrompt = """
        我在用一个叫 MeetCap 的会议纪要工具，它能接任何「OpenAI 兼容」的 AI 接口。\
        我想用【在这里写你想用的 AI，比如 Kimi / DeepSeek / Gemini / 通义千问 / 智谱】。请告诉我：
        1. 去哪个网址注册、怎么一步步创建 API key；
        2. 它的 OpenAI 兼容接口地址（base URL）；
        3. 适合整理长篇中文会议纪要的模型名：一个速度快的、一个能力最强的。
        最后严格按下面格式给我一段可以直接粘贴的配置，不要加别的内容：
        BASE_URL=接口地址
        API_KEY=（留空，我自己填）
        MODELS=快的模型名,强的模型名
        """

    var body: some View {
        Form {
            Section {
                LabeledContent("本机检测") {
                    HStack {
                        Text(detectSummary).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        Button("重新检测") { vm.detect() }.disabled(vm.detecting)
                    }
                }
                LabeledContent("下拉里的模型") {
                    HStack {
                        Text("已选 \(enabledIDs.count) 个 / 共检测到 \(vm.detection?.models.count ?? 0) 个")
                            .foregroundStyle(.secondary)
                        Button("管理…") { showLibrary = true }.disabled(vm.detection?.models.isEmpty ?? true)
                    }
                }
                modelPicker("清稿 / 提纲", choice: $draftChoice, typed: $draftTyped, auto: vm.detection?.auto.draft)
                modelPicker("最终纪要", choice: $finalChoice, typed: $finalTyped, auto: vm.detection?.auto.finalModel)
            } header: {
                Text("模型")
            } footer: {
                Text("下拉只列你勾选的模型（默认是各家快→强的几档），其余收在「管理…」里。"
                     + "不确定就选「自动」：清稿挑快的、纪要挑最强的，也只在勾选的模型里挑。")
                    .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showLibrary) {
                ModelLibrary(models: vm.detection?.models ?? [], enabled: Binding(
                    get: { enabledIDs }, set: { editedEnabled = $0 }))
            }
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
            Section {
                HStack {
                    Menu("填入示例") {
                        ForEach(Self.presets, id: \.0) { name, url, keyURL in
                            Button(name) {
                                customEnv = "# \(name)：在 \(keyURL) 创建 API key\nBASE_URL=\(url)\nAPI_KEY=\n"
                                    + "# MODELS=快的模型名,强的模型名   可不填，不填就列出该接口全部模型\n"
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("复制求助提示") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.helpPrompt, forType: .string)
                        status = "已复制：粘贴给你常用的 AI，把它给的三行贴到下面"
                    }
                }
                TextEditor(text: $customEnv)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 96)
            } header: {
                Text("其他 AI（Kimi、DeepSeek、Gemini、通义千问、智谱…）")
            } footer: {
                Text("凡是提供「OpenAI 兼容」接口的服务都能用，填 BASE_URL 和 API_KEY 两行即可。"
                     + "不知道怎么填：点「复制求助提示」，发给你常用的 AI（Kimi、Gemini、WorkBuddy、豆包都行），"
                     + "把它回复的三行粘进来，填上 key，保存。")
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
        .frame(width: 580, height: 720)
        .disabled(vm.state != .idle)  // 录音中换目录会让菜单找不到当前场次
        .onAppear {
            load()
            vm.detect()
            Self.bringToFront()
        }
    }

    /// 菜单栏 app 的窗口默认可能开在别的窗口后面或另一块屏幕上: 拉到主屏正中、置前
    static func bringToFront() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            for w in NSApp.windows where w.styleMask.contains(.titled) && !(w is NSOpenPanel) {
                if let f = NSScreen.main?.visibleFrame {
                    w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
                }
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
        }
    }

    private var detectSummary: String {
        if vm.detecting { return "检测中…" }
        guard let d = vm.detection else { return "未检测" }
        let notes = ["codex", "claude", "custom"].compactMap { d.channels[$0] }
            .filter { $0.via != nil || $0.note.contains("不可用") }.map(\.note)
        if d.models.isEmpty {
            return (notes + ["没有可用的 AI：登录 codex / claude，或填下面的 API key / 其他 AI"])
                .joined(separator: "；")
        }
        return notes.joined(separator: "、") + "，共 \(d.models.count) 个模型"
    }

    @ViewBuilder
    private func modelPicker(_ title: String, choice: Binding<String>, typed: Binding<String>,
                             auto: String?) -> some View {
        let models = (vm.detection?.models ?? []).filter { enabledIDs.contains($0.id) }
        let current = choice.wrappedValue
        Picker(title, selection: choice) {
            Text(auto.map { "自动（推荐）· \(vm.modelLabel($0))" } ?? "自动（推荐）").tag("auto")
            // 设置里存的模型这次没检测到(比如退出了登录), 仍列出来, 不让选择凭空消失
            if current != "auto", current != Self.typedTag, !models.contains(where: { $0.id == current }) {
                Text("\(vm.modelName(current))（不在下拉清单里）").tag(current)
            }
            ForEach(Self.groups, id: \.1) { label, provider in
                let group = models.filter { $0.provider == provider }
                if !group.isEmpty {
                    Section(label) {
                        ForEach(group, id: \.self) { Text($0.label).tag($0.id) }
                    }
                }
            }
            Text("手动填写模型名…").tag(Self.typedTag)
        }
        if current == Self.typedTag {
            TextField("模型名", text: typed, prompt: Text("如 gpt-6-sol、claude-opus-5、custom:kimi-k2"))
        }
    }

    private func load() {
        let cfg = MeetCapConfig.load()
        outputDir = cfg["output_dir"] ?? ""
        speaker = cfg["speaker"] ?? ""
        openaiKey = cfg["openai_api_key"] ?? ""
        anthropicKey = cfg["anthropic_api_key"] ?? ""
        customEnv = cfg["custom_env"] ?? ""
        savedEnabled = cfg["enabled_models"]
        editedEnabled = nil
        draftChoice = cfg["draft_model"] ?? "auto"
        finalChoice = cfg["final_model"] ?? "auto"
        status = ""
    }

    /// 下拉里显示的模型: 本次改过的勾选优先, 否则用检测结果(已含保存过的勾选)
    private var enabledIDs: Set<String> {
        editedEnabled ?? Set((vm.detection?.models ?? []).filter(\.enabled).map(\.id))
    }

    private func resolved(_ choice: String, _ typed: String) -> String {
        guard choice == Self.typedTag else { return choice }
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "auto" : name
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
                                    "openai_api_key": openaiKey, "anthropic_api_key": anthropicKey,
                                    "custom_env": customEnv,
                                    // 一个都不勾时存 "-", 否则空值会被当成「没勾过」而回到推荐
                                    "enabled_models": editedEnabled.map { $0.isEmpty ? "-" : $0.sorted().joined(separator: ",") }
                                        ?? savedEnabled ?? "",
                                    "draft_model": resolved(draftChoice, draftTyped),
                                    "final_model": resolved(finalChoice, finalTyped)])
            vm.reloadConfig()
            vm.detect()  // key 或其他 AI 可能变了, 重新看能用哪些模型
            load()
            status = "已保存，下次开录生效"
        } catch {
            status = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 「管理…」: 检测到的全部模型, 勾选哪些进下拉; 模型多时可搜索
struct ModelLibrary: View {
    let models: [Detection.Model]
    @Binding var enabled: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("下拉里显示哪些模型").font(.headline)
            Text("只有勾选的模型会出现在清稿 / 纪要的下拉里，「自动」也只在勾选的里面挑。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("搜索模型", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(SettingsView.groups, id: \.1) { label, provider in
                    let rows = models.filter { $0.provider == provider && matches($0) }
                    if !rows.isEmpty {
                        Section(label) {
                            ForEach(rows, id: \.self) { m in
                                Toggle(isOn: Binding(
                                    get: { enabled.contains(m.id) },
                                    set: { on in if on { enabled.insert(m.id) } else { enabled.remove(m.id) } })) {
                                    HStack {
                                        Text(m.label)
                                        Spacer()
                                        if m.name != m.id { Text(m.id).font(.caption).foregroundStyle(.tertiary) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 340)
            HStack {
                Button("只留推荐") { enabled = Set(models.filter(\.recommended).map(\.id)) }
                Spacer()
                Text("已选 \(enabled.count) 个").foregroundStyle(.secondary)
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func matches(_ m: Detection.Model) -> Bool {
        query.isEmpty || m.name.localizedCaseInsensitiveContains(query) || m.id.localizedCaseInsensitiveContains(query)
    }
}

/// 先激活 app 再开设置窗口; 直接用 SettingsLink 时窗口常被压在别的窗口后面, 看起来像没反应
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            SettingsView.bringToFront()
        }
        .keyboardShortcut(",")
    }
}

// MARK: - App

@main
struct MeetCapApp: App {
    @StateObject private var vm = RecorderVM()

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
                if vm.noAI {
                    Text("没检测到可用的 AI：只会生成转录，点「设置…」配置")
                } else {
                    Text("清稿：\(vm.describe(vm.draftModel, auto: vm.detection?.auto.draft))")
                    Text("纪要：\(vm.describe(vm.finalModel, auto: vm.detection?.auto.finalModel))")
                }
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
            SettingsButton()
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
