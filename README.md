# MeetCap

macOS 菜单栏会议录音工具：同时录系统声音（会议对方）和麦克风（自己），用 `mlx-whisper` 在本机流式转写，录音期间滚动生成要点提纲，停录后由 GPT 或 Claude 通读全文出一份结构化纪要。

- 录音与语音识别全在本机，原始音频不上传。
- 清稿 / 提纲与最终纪要可各选一个模型，GPT 与 Claude 可混用。
- 每个模型可以走已登录的命令行（`codex` / `claude`，复用订阅），也可以填自己的 API key 按量计费。
- 停录即出快版纪要，约两分钟后完整版自动覆盖；附点句回放的转录审计页。

## 环境要求

- Apple Silicon Mac，macOS 14.4+（系统声音抓取依赖 Core Audio process tap）
- Xcode 命令行工具（`swiftc`）、[`ffmpeg`](https://ffmpeg.org)、[`uv`](https://docs.astral.sh/uv/)
- 至少一种模型通道：
  - GPT：[Codex CLI](https://github.com/openai/codex) 并 `codex login`，或 OpenAI API key
  - Claude：[Claude Code](https://claude.com/claude-code) 并 `claude auth login`，或 Anthropic API key

## 安装

```sh
git clone https://github.com/HWY1dot0/meetcap.git
cd meetcap
./build_app.sh
open ~/Applications/MeetCap.app
```

`build_app.sh` 会编译 `audiotap`（系统声音抓取）和菜单栏应用，安装到 `~/Applications/MeetCap.app`，并记下本仓库的位置；仓库挪了位置就重跑一次。首次录音时 macOS 会请求麦克风和系统录音权限。

可选：`MEETCAP_BUNDLE_ID=com.yourname.meetcap ./build_app.sh` 自定义应用 ID（默认 `com.example.meetcap`；改 ID 后需重新授权）。

## 使用

点菜单栏的麦克风图标：

- **开始录音 / 停止录音**：录音中菜单栏显示时长和电平。
- **现场会模式**：线下会议用电脑麦克风收全场。
- **清稿 / 提纲模型**、**最终纪要模型**：开录前选择。
- **设置…**（⌘,）：
  - **保存位置**：纪要与录音存哪里（默认 `~/Recordings/meetings`）。
  - **我的署名**：转录里自己发言的标签（默认「本人」）。
  - **API Key**：填了哪家就直连该家 API；留空则用本机已登录的命令行。

每场会议一个文件夹（如 `20261029_1040/`），内含 `minutes.md`（纪要）、`transcript_full.md`（完整转录）、`review.html`（点句回放核对）和音频。

如果不是 MacBook Pro，把 `meeting_recorder.py` 里的 `MIC_DEV` 改成 `ffmpeg -f avfoundation -list_devices true -i ""` 列出的内建麦克风名称。

## 模型

| 菜单项 | 模型名 | 通道 |
|---|---|---|
| GPT-6 Luna · 快 / GPT-6.1 Terra · 均衡 / GPT-6.1 Sol · 主力 / GPT-6 Astra · 最强 | `gpt-6-luna` / `gpt-6.1-terra` / `gpt-6.1-sol` / `gpt-6-astra` | `codex` CLI 或 OpenAI API |
| Claude Haiku · 快 / Sonnet · 均衡 / Opus · 深入 / Fable · 最强 | `haiku` / `sonnet` / `opus` / `fable` | `claude` CLI 或 Anthropic API |

默认清稿用 `gpt-6-luna`、终稿用 `gpt-6-astra`。走 CLI 时 Claude 别名始终指向该档最新版；走 API 时换成对应的现行模型 ID（如 `claude-sonnet-5-5`），Sonnet / Opus / Fable 遇到安全分类器拒答会由服务端自动换模型重试。

## 命令行

```sh
./meeting_recorder.py                                        # 前台录音, Ctrl-C 停录
./meeting_recorder.py --model haiku --final-model gpt-6-astra
./meeting_recorder.py --out-dir ~/Documents/Meetings --onsite
./meeting_recorder.py --no-clean                             # 只做本地转录, 不调任何模型
./meeting_recorder.py --stop                                 # 从另一个终端停录
```

命令行的模型名不限于菜单所列：Claude 别名或 `claude-*` 走 Claude，其余走 GPT。只指定 `--model` 时终稿沿用同一模型。

## 隐私

- 原始音频和语音识别只在本机进行。启用 AI 时，转录文字会发给所选模型。
- 命令行通道在临时空目录里调用，不给工具、不加载你的配置、插件和 MCP。
- API key 只存在本机 `~/Library/Application Support/MeetCap/config.json`（权限 600，仅你的账户可读），不进仓库。
- AI 调用失败时原始转录照常保留，日志里不记录转录内容。

## 测试

```sh
python3 -m unittest -v test_meeting_recorder.py
```

只测文本处理与模型调用的组装，不录音、不联网。
