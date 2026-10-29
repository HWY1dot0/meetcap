# MeetCap

macOS 菜单栏会议录音工具：同时录系统声音（会议对方）和麦克风（自己），用 `mlx-whisper` 在本机流式转写，录音期间滚动生成要点提纲，停录后由 GPT 或 Claude 通读全文出一份结构化纪要。

- 录音与语音识别全在本机，原始音频不上传。
- 默认「自动」选模型：开录前检查这台 Mac 能用哪些 AI，清稿挑快的、纪要挑最强的，不用自己配。
- 支持 GPT、Claude，以及任何 OpenAI 兼容接口（Kimi、DeepSeek、Gemini、通义千问、智谱、OpenRouter…）；清稿和纪要可以各用一家。
- GPT / Claude 可以走已登录的命令行（`codex` / `claude`，复用订阅），也可以填自己的 API key 按量计费。
- 停录即出快版纪要，约两分钟后完整版自动覆盖；附点句回放的转录审计页。

## 环境要求

- Apple Silicon Mac，macOS 14.4+（系统声音抓取依赖 Core Audio process tap）
- Xcode 命令行工具（`swiftc`）、[`ffmpeg`](https://ffmpeg.org)、[`uv`](https://docs.astral.sh/uv/)
- 至少一种 AI（没有也能录音和转写，只是不出纪要）：
  - GPT：[Codex CLI](https://github.com/openai/codex) 并 `codex login`，或 OpenAI API key
  - Claude：[Claude Code](https://claude.com/claude-code) 并 `claude auth login`，或 Anthropic API key
  - 其他：任意 OpenAI 兼容接口的地址和 API key

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
- 菜单里显示当前用哪个模型清稿、哪个出纪要。
- **设置…**（⌘,）：
  - **模型**：显示本机检测结果；清稿 / 提纲与最终纪要各选一个，或保持「自动」。
  - **保存位置**：纪要与录音存哪里（默认 `~/Recordings/meetings`）。
  - **我的署名**：转录里自己发言的标签（默认「本人」）。
  - **API Key**：填了哪家就直连该家 API；留空则用本机已登录的命令行。
  - **其他 AI**：见下节。

每场会议一个文件夹（如 `20261029_1040/`），内含 `minutes.md`（纪要）、`transcript_full.md`（完整转录）、`review.html`（点句回放核对）和音频。

如果不是 MacBook Pro，把 `meeting_recorder.py` 里的 `MIC_DEV` 改成 `ffmpeg -f avfoundation -list_devices true -i ""` 列出的内建麦克风名称。

## 模型

选「自动」时：

| 用途 | 优先顺序 |
|---|---|
| 清稿 / 提纲（要快） | `gpt-6-luna` → Claude Haiku → `gpt-6.1-terra` → Claude Sonnet |
| 最终纪要（要强） | `gpt-6-astra` → Claude Fable → `gpt-6.1-sol` → Claude Opus |

都没有时（比如只配了其他 AI），用第一家检测到的第一个模型清稿、最后一个出纪要。

可选模型来自实际检测：Codex 读它自己维护的账号可用清单，API key 和其他 AI 直接向接口要模型列表，Claude 命令行用 `haiku` / `sonnet` / `opus` / `fable` 这几个始终指向最新版的别名。也可以在设置里「手动填写模型名」。走 Anthropic API 时 Sonnet / Opus / Fable 遇到安全分类器拒答，会由服务端自动换模型重试。

## 其他 AI（Kimi、DeepSeek、Gemini、通义千问、智谱…）

凡是提供「OpenAI 兼容」接口的服务都能接。在设置的「其他 AI」里写几行：

```
BASE_URL=https://api.moonshot.cn/v1
API_KEY=你的 key
MODELS=快的模型名,强的模型名     # 可不填，不填就列出该接口全部模型
```

「填入示例」里有 Kimi、DeepSeek、Gemini、通义千问、智谱、腾讯混元、OpenRouter 的接口地址和申请 key 的网址。

不知道怎么填：点「复制求助提示」，发给你常用的 AI（Kimi、Gemini、WorkBuddy、豆包都行），它会告诉你去哪申请 key，并给出可以直接粘贴的三行。保存后「本机检测」会立刻列出这个接口的模型；地址或 key 不对会显示「不可用」。

## 命令行

```sh
./meeting_recorder.py                                        # 前台录音, Ctrl-C 停录
./meeting_recorder.py --detect                               # 看本机能用哪些模型、自动会挑谁
./meeting_recorder.py --model haiku --final-model gpt-6-astra
./meeting_recorder.py --out-dir ~/Documents/Meetings --onsite
./meeting_recorder.py --no-clean                             # 只做本地转录, 不调任何模型
./meeting_recorder.py --stop                                 # 从另一个终端停录
```

命令行默认读设置里的模型（未设置即「自动」）。模型名规则：`custom:模型名` 走其他 AI，Claude 别名或 `claude-*` 走 Claude，其余走 GPT。只指定 `--model` 时终稿沿用同一模型。没有可用的 AI 时照常录音和转写，只是不生成 AI 纪要。

## 隐私

- 原始音频和语音识别只在本机进行。启用 AI 时，转录文字会发给所选模型。
- 命令行通道在临时空目录里调用，不给工具、不加载你的配置、插件和 MCP。
- API key 和其他 AI 配置只存在本机 `~/Library/Application Support/MeetCap/config.json`（权限 600，仅你的账户可读），不进仓库。
- AI 调用失败时原始转录照常保留，日志里不记录转录内容。

## 测试

```sh
python3 -m unittest -v test_meeting_recorder.py
```

只测文本处理与模型调用的组装，不录音、不联网。
