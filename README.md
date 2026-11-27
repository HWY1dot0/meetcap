# MeetCap

简体中文 | [English](README.en.md)

macOS 菜单栏会议录音工具：同时录系统声音（会议对方）和麦克风（自己），用 `mlx-whisper` 在本机流式转写，录音期间滚动生成要点提纲，停录后由 GPT 或 Claude 通读全文出一份结构化纪要。

- 录音与语音识别全在本机，原始音频不上传。
- 默认「自动」选模型：开录前检查这台 Mac 能用哪些 AI，清稿挑快的、纪要挑最强的，不用自己配。
- 支持 GPT、Claude，以及任何 OpenAI 兼容接口（Kimi、DeepSeek、Gemini、通义千问、智谱、OpenRouter…）；清稿和纪要可以各用一家。
- GPT / Claude 可以走已登录的命令行（`codex` / `claude`，复用订阅），也可以填自己的 API key 按量计费。
- 停录即出快版纪要，约两分钟后完整版自动覆盖。
- 附核对页：按对话排版、标出每段是谁说的，点任意一句就从那里回放录音。

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
- **只录一个应用**：只录选中的那个应用的声音（比如只录 Zoom），电脑上别的声音不进来。
- **再录一个会（分开录）**：录音中再开一场，两个会各出各的转录和纪要，见下节。
- **现场会模式**：线下会议用电脑麦克风收全场。
- 菜单里显示当前用哪个模型清稿、哪个出纪要。
- **设置…**（⌘,）：
  - **模型**：显示本机检测结果；清稿 / 提纲与最终纪要各选一个，或保持「自动」。下拉只列勾选的模型，点「管理…」在完整清单里勾选（可搜索）。
  - **保存位置**：纪要与录音存哪里（默认 `~/Recordings/meetings`）。
  - **我的署名**：转录里自己发言的标签（默认「本人」）。
  - **API Key**：填了哪家就直连该家 API；留空则用本机已登录的命令行。
  - **纪要模版**：自己规定纪要长什么样，再填上常出现的专有名词。见下节。
  - **其他 AI**：见下节。

每场会议一个文件夹（如 `20261029_1040/`），内含 `minutes.md`（纪要）、`transcript_full.md`（完整转录）、`review.html`（核对页，见下）和音频。

如果不是 MacBook Pro，把 `meeting_recorder.py` 里的 `MIC_DEV` 改成 `ffmpeg -f avfoundation -list_devices true -i ""` 列出的内建麦克风名称。

## 模型

选「自动」时：

| 用途 | 优先顺序 |
|---|---|
| 清稿 / 提纲（要快） | `gpt-6-luna` → Claude Haiku → `gpt-6.1-terra` → Claude Sonnet |
| 最终纪要（要强） | `gpt-6-astra` → Claude Fable → `gpt-6.1-sol` → Claude Opus |

「自动」只在勾选的模型里挑；都没有时（比如只配了其他 AI），用勾选的第一个模型清稿、最后一个出纪要。

**下拉里放哪些模型由你决定。** 检测到的模型可能很多（Codex 账号里的旧版本、某个接口返回的几十个模型），默认只勾选每家「快 → 最强」那几档，下拉里显示为「GPT-6 Luna · 快」「Claude Fable · 最强」这样；其他 AI 默认勾选 `MODELS` 里写的，没写就勾前三个。其余收在设置的「管理…」里，随时勾上或取消，「只留推荐」恢复默认。

可选模型来自实际检测：Codex 读它自己维护的账号可用清单，API key 和其他 AI 直接向接口要模型列表，Claude 命令行用 `haiku` / `sonnet` / `opus` / `fable` 这几个始终指向最新版的别名。也可以在设置里「手动填写模型名」。走 Anthropic API 时 Sonnet / Opus / Fable 遇到安全分类器拒答，会由服务端自动换模型重试。

## 纪要模版

默认的纪要是研究纪要的写法：一句话标题、要点速览、按发言人或话题分节的成段正文、值得关注的信息点。想换成别的样子，在设置的「纪要模版」里写出来即可，保存后下一场生效：

- **写几句要求**，比如「按 结论 / 待办 / 风险 三部分写，待办写清负责人和截止时间」。
- **或者给一份骨架**，把想要的标题列出来，每个标题下写一句要填什么。纪要会沿用这些标题和顺序，会上没提到的小节写「无」。
- 「填入示例」里有项目例会、客户沟通、访谈调研、课程讲座、英文纪要几份现成的，也可以先填入默认格式再改。留空或点「恢复默认」就回到内置格式。

**常出现的专有名词**用逗号分隔填进去（公司名、产品名、人名、行业术语）：语音识别会更倾向于写对它们，清稿和写纪要时也会把发音相近的错词改回来。留空时用的是内置的一组宏观金融词汇（美联储、议息会议、久期这类），不做金融的话建议填上自己行业的词。

模版只管最终纪要。录音期间滚动更新的快版提纲（停录瞬间先给出、随后被完整版覆盖的那份）格式不变。命令行可以用 `--template 文件` 临时指定一份模版。

## 同时录两个会

MeetCap 默认录这台 Mac 上所有程序混在一起的声音。同时听两个会时，可以让每个会只录自己那个应用，声音互不串：

- 第一场已经在录（录全部声音也行）时，点菜单里的「再录一个会（分开录）」，选第二个会所在的应用。新的一场只录这个应用；原来录全部声音的那场从这一刻起自动不再收它。
- 也可以两场都用「只录一个应用」开始。
- 菜单里每场各有一行状态和一个停止按钮，停一场不影响另一场；每场有自己的文件夹、转录和纪要。

限制：

- **两个会必须在不同的应用里。** 同一个浏览器开两个标签页分不开，请用两个浏览器，或一个用客户端、一个用浏览器。
- 麦克风只跟先开的那一场，免得你的发言重复进两份纪要。
- 两路转写同时跑，发热和耗电会明显增加。
- 被单独录的应用刚开始出声的一瞬间（不到一秒），可能漏进录全部声音的那场，或在自己那场缺一小截。

## 核对页与说话人

`review.html` 用来对着录音核对转录：正文是清稿后的文字，按对话排版，一个人连续说的话是一段，段首标出是谁。点任意一句，播放器跳到那句话在录音里的位置；空格键暂停 / 继续；黄底的句子是转写把握低的地方。

**谁在说话是按声音分的，不是让 AI 看文字猜的。** 录音期间每块音频在本机做一次说话人分辨（[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)，声纹只在内存里比对，不上传也不落盘），全场统一编号，支持多人。分出人之后，再让清稿模型根据内容（自我介绍、互相称呼、主持人介绍）认名字：认得出的标名字，认不出的标「发言人 A / B…」。只听出一个人时不标代称。

- 首次使用会自动下载两个模型到 `~/Library/Application Support/MeetCap/models/`，共约 34 MB，校验 sha256 后离线运行。下载失败或没下完时照常录音出纪要，只是那一场不标说话人。
- 线上会议只分「会议声音」这一轨，麦克风轨就是你自己；现场会模式分麦克风轨。
- 几个人同时说话、只有一两秒的插话，可能归错人或不单独成段。名字来自模型对内容的判断，重要场合请核对。
- 不需要时加 `--no-speakers`。

目前说话人标注只用在核对页上，`minutes.md` 和 `transcript_full.md` 的写法不变。

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
./meeting_recorder.py --no-speakers                          # 不按声音分辨说话人
./meeting_recorder.py --template ~/minutes-template.md       # 这一场用这份纪要模版
./meeting_recorder.py --app zoom.us                          # 只录这个应用(应用名或 .app 路径)
./meeting_recorder.py --stop                                 # 从另一个终端停录(同时录着几场就全停)
./meeting_recorder.py --stop 20261124_1030                   # 只停这一场
```

命令行默认读设置里的模型（未设置即「自动」）。模型名规则：`custom:模型名` 走其他 AI，Claude 别名或 `claude-*` 走 Claude，其余走 GPT。只指定 `--model` 时终稿沿用同一模型。没有可用的 AI 时照常录音和转写，只是不生成 AI 纪要。

## 完成后钩子

想在每场会议结束后自动做点事（把纪要归档到笔记库、发到某个地方），放一个可执行文件到 `~/Library/Application Support/MeetCap/on_done`：

```sh
#!/bin/sh
# $1 是本场会议的文件夹，里面有 minutes.md 和 transcript_full.md
cp "$1/minutes.md" ~/Documents/Notes/"$(basename "$1").md"
```

完整版纪要落盘后，MeetCap 以会议文件夹为唯一参数在后台运行它。没有这个文件就什么都不做；钩子出错不影响录音和纪要。删掉文件即停用。

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

## 许可证

[PolyForm Noncommercial 1.0.0](LICENSE.md)：个人使用和非商业用途免费，可以自由使用、修改和分发。

用于商业目的（包括在公司或营利性机构的工作中使用、集成到商业产品或服务里）需要另行取得授权，请[开一个 issue](https://github.com/HWY1dot0/meetcap/issues) 联系。
