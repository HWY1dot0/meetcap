# MeetCap

[简体中文](README.md) | English

A meeting recorder that lives in the macOS menu bar. It records system audio (the other side of the call) and your microphone at the same time, transcribes on-device with `mlx-whisper` as the meeting goes, keeps a rolling outline of key points while recording, and after you stop has GPT or Claude read the whole transcript and write structured minutes.

- Recording and speech recognition run entirely on your Mac. The raw audio is never uploaded.
- Models are picked automatically by default: before recording, MeetCap checks which AI this Mac can reach, then uses a fast one for cleanup and the strongest one for the minutes. Nothing to configure.
- Works with GPT, Claude, and any OpenAI-compatible API (Kimi, DeepSeek, Gemini, Qwen, Zhipu, OpenRouter…). Cleanup and minutes can use different providers.
- GPT and Claude can go through a command-line tool you are already signed in to (`codex` / `claude`, reusing your subscription), or through your own API key with pay-as-you-go billing.
- A quick version of the minutes is ready the moment you stop. The full version replaces it about two minutes later.
- Comes with a review page: the transcript laid out as a conversation with each speaker labelled. Click any sentence to play the recording from that point.

> **Language note.** The app's interface is in Chinese, so menu and settings labels below are given in English with the Chinese label in parentheses. Transcription detects the language of each chunk automatically, so English meetings work. Minutes are written in Chinese by default; to get English minutes, pick the English preset in the minutes template settings (see [Minutes template](#minutes-template)).

## Requirements

- Apple Silicon Mac, macOS 14.4+ (system audio capture relies on Core Audio process taps)
- Xcode Command Line Tools (`swiftc`), [`ffmpeg`](https://ffmpeg.org), [`uv`](https://docs.astral.sh/uv/)
- At least one AI (without one you still get the recording and transcript, just no minutes):
  - GPT: [Codex CLI](https://github.com/openai/codex) with `codex login`, or an OpenAI API key
  - Claude: [Claude Code](https://claude.com/claude-code) with `claude auth login`, or an Anthropic API key
  - Other: the base URL and API key of any OpenAI-compatible API

## Install

```sh
git clone https://github.com/HWY1dot0/meetcap.git
cd meetcap
./build_app.sh
open ~/Applications/MeetCap.app
```

`build_app.sh` compiles `audiotap` (system audio capture) and the menu bar app, installs it to `~/Applications/MeetCap.app`, and remembers where this repository lives. If you move the repository, run it again. On the first recording macOS asks for microphone and system audio recording permission.

Optional: `MEETCAP_BUNDLE_ID=com.yourname.meetcap ./build_app.sh` sets a custom bundle ID (default `com.example.meetcap`; changing it means granting permissions again).

## Usage

Click the microphone icon in the menu bar:

- **Start recording / Stop recording** (开始录音 / 停止录音): while recording, the menu bar shows elapsed time and audio level.
- **Record one app only** (只录一个应用): records only the app you pick (Zoom, for example). Other sounds on the Mac stay out.
- **Record another meeting, separately** (再录一个会（分开录）): start a second recording while one is running. Each meeting gets its own transcript and minutes. See [Recording two meetings at once](#recording-two-meetings-at-once).
- **In-person mode** (现场会模式): for meetings in a room, the Mac's microphone picks up everyone.
- The menu shows which model is doing cleanup and which is writing the minutes.
- **Settings…** (设置…, ⌘,):
  - **Models** (模型): shows what was detected on this Mac. Choose one model for cleanup and outline and one for the final minutes, or leave both on Auto (自动). The dropdowns list only the models you have ticked; click Manage… (管理…) to tick models in the full, searchable list.
  - **Save location** (保存位置): where minutes and recordings go (default `~/Recordings/meetings`).
  - **My name** (我的署名): the label for your own speech in the transcript (default 「本人」, "me").
  - **API Key**: fill in a provider's key to call its API directly; leave it empty to use the signed-in command-line tool.
  - **Minutes template** (纪要模版): define what the minutes should look like and list proper nouns that come up often. See below.
  - **Other AI** (其他 AI): see below.

Each meeting gets its own folder (for example `20261029_1040/`) containing `minutes.md` (the minutes), `transcript_full.md` (the full transcript), `review.html` (the review page, see below) and the audio.

If you are not on a MacBook Pro, change `MIC_DEV` in `meeting_recorder.py` to the name of your built-in microphone as listed by `ffmpeg -f avfoundation -list_devices true -i ""`.

## Models

With Auto selected:

| Purpose | Order of preference |
|---|---|
| Cleanup / outline (needs to be fast) | `gpt-6-luna` → Claude Haiku → `gpt-6.1-terra` → Claude Sonnet |
| Final minutes (needs to be strong) | `gpt-6-astra` → Claude Fable → `gpt-6.1-sol` → Claude Opus |

Auto only chooses among the models you have ticked. If none of the above is available (say you only configured another AI), it uses the first ticked model for cleanup and the last one for the minutes.

**You decide which models appear in the dropdowns.** A lot of models may be detected (older versions on your Codex account, dozens returned by some API). By default only each provider's "fast → strongest" tiers are ticked. For other AI, the models listed in `MODELS` are ticked by default, or the first three if you listed none. The rest sit under Manage… (管理…) in settings, where you can tick or untick them at any time; "Recommended only" (只留推荐) restores the default.

The list of available models comes from real detection. For Codex, MeetCap reads the list of models your account can use, which Codex maintains itself. With an API key or another AI, it asks the API for its model list. The Claude command line uses the aliases `haiku` / `sonnet` / `opus` / `fable`, which always point to the latest version. You can also type a model name by hand in settings. When going through the Anthropic API, if Sonnet, Opus or Fable is refused by a safety classifier, the server retries with another model automatically.

## Minutes template

The default minutes follow a research-note format: a one-line title, a quick summary of key points, body paragraphs organised by speaker or topic, and a list of points worth watching. To change this, describe what you want under Minutes template (纪要模版) in settings. It takes effect from the next meeting after you save.

- **Write a few instructions**, such as "Use three sections: Conclusions / Action items / Risks. Give each action item an owner and a deadline."
- **Or provide a skeleton**: list the headings you want, with one sentence under each saying what belongs there. The minutes keep those headings in that order, and write "none" under any section the meeting did not cover.
- "Insert example" (填入示例) offers ready-made templates for a project stand-up, a client call, an interview, a lecture, and English minutes. You can also insert the default format and edit it. Leave the field empty or click "Restore default" (恢复默认) to go back to the built-in format.

**Frequently used proper nouns** go in as a comma-separated list (company names, product names, people, industry terms). Speech recognition becomes more likely to spell them correctly, and similar-sounding mistakes are corrected during cleanup and when the minutes are written. When the field is empty, a built-in list of Chinese macro-finance terms is used, so if you do not work in finance, fill in terms from your own field.

The template only affects the final minutes. The quick outline that updates during recording (the version you get the instant you stop, later replaced by the full one) keeps its format. On the command line, `--template FILE` applies a template to a single recording.

## Recording two meetings at once

By default MeetCap records everything playing on the Mac, mixed together. When you are listening to two meetings at once, each recording can capture only its own app so the audio does not cross over:

- While the first meeting is recording (recording all audio is fine), click "Record another meeting, separately" (再录一个会（分开录）) and pick the app the second meeting is in. The new recording captures only that app, and from that moment the first one, if it was recording all audio, stops picking that app up.
- You can also start both with "Record one app only" (只录一个应用).
- Each recording has its own status line and stop button in the menu. Stopping one does not affect the other. Each has its own folder, transcript and minutes.

Limitations:

- **The two meetings must be in different apps.** Two tabs in the same browser cannot be separated. Use two browsers, or a desktop client for one and a browser for the other.
- The microphone follows only the recording that started first, so your own speech does not end up in both sets of minutes.
- Two transcriptions run at once, so the Mac gets noticeably warmer and uses more battery.
- For a brief moment (under a second) when the separately recorded app first makes sound, the audio may leak into the all-audio recording or be missing from its own.

## Review page and speakers

`review.html` is for checking the transcript against the recording. The text is the cleaned-up transcript laid out as a conversation: consecutive speech by one person forms a paragraph, with the speaker named at the start. Click any sentence and the player jumps to that point in the recording. Space pauses and resumes. Sentences highlighted in yellow are ones the transcription was less sure about.

**Speakers are told apart by voice, not guessed by an AI from the text.** During recording, each audio chunk goes through on-device speaker diarization ([sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx); voiceprints are compared in memory only, never uploaded or written to disk), with consistent numbering across the whole meeting and support for multiple people. Once speakers are separated, the cleanup model works out names from the content (self-introductions, people addressing each other, the host's introductions). Speakers it can identify are labelled by name; the rest are labelled Speaker A, Speaker B and so on (发言人 A / B…). When only one voice is heard, no label is added.

- On first use, two models are downloaded to `~/Library/Application Support/MeetCap/models/` (about 34 MB in total), verified by sha256, and then run offline. If the download fails or is incomplete, recording and minutes work as usual; that meeting just has no speaker labels.
- For online meetings, only the meeting audio track is diarized, and the microphone track is you. In-person mode diarizes the microphone track.
- When several people talk at once, or someone interjects for only a second or two, speech may be attributed to the wrong person or not split into its own paragraph. Names come from the model's reading of the content, so check them when it matters.
- Add `--no-speakers` to turn this off.

For now speaker labels are used only on the review page. `minutes.md` and `transcript_full.md` are written as before.

## Other AI (Kimi, DeepSeek, Gemini, Qwen, Zhipu…)

Any service that offers an OpenAI-compatible API can be connected. Under Other AI (其他 AI) in settings, write a few lines:

```
BASE_URL=https://api.moonshot.cn/v1
API_KEY=your key
MODELS=fast-model-name,strong-model-name     # optional; if omitted, all of the API's models are listed
```

"Insert example" (填入示例) has the API base URLs and key sign-up pages for Kimi, DeepSeek, Gemini, Qwen, Zhipu, Tencent Hunyuan and OpenRouter.

Not sure what to enter? Click "Copy help prompt" (复制求助提示) and send it to whichever AI assistant you normally use. It will tell you where to get a key and give you the three lines ready to paste. After saving, the detection panel immediately lists that API's models; a wrong URL or key shows as unavailable (不可用).

## Command line

```sh
./meeting_recorder.py                                        # record in the foreground, Ctrl-C to stop
./meeting_recorder.py --detect                               # show which models this Mac can use and what Auto would pick
./meeting_recorder.py --model haiku --final-model gpt-6-astra
./meeting_recorder.py --out-dir ~/Documents/Meetings --onsite
./meeting_recorder.py --no-clean                             # local transcription only, no model calls
./meeting_recorder.py --no-speakers                          # skip voice-based speaker separation
./meeting_recorder.py --template ~/minutes-template.md       # use this minutes template for this recording
./meeting_recorder.py --app zoom.us                          # record only this app (app name or .app path)
./meeting_recorder.py --stop                                 # stop from another terminal (stops all running recordings)
./meeting_recorder.py --stop 20261124_1030                   # stop only this one
```

The command line reads the models from settings by default (Auto if unset). Model name rules: `custom:model-name` goes to the other AI, Claude aliases or `claude-*` go to Claude, and everything else goes to GPT. If only `--model` is given, the final minutes use the same model. With no AI available, recording and transcription work as usual, but no AI minutes are generated.

## On-done hook

To do something automatically after each meeting (file the minutes into your notes, send them somewhere), put an executable file at `~/Library/Application Support/MeetCap/on_done`:

```sh
#!/bin/sh
# $1 is this meeting's folder, containing minutes.md and transcript_full.md
cp "$1/minutes.md" ~/Documents/Notes/"$(basename "$1").md"
```

Once the full minutes are written to disk, MeetCap runs it in the background with the meeting folder as its only argument. If the file does not exist, nothing happens. An error in the hook does not affect recording or minutes. Delete the file to turn it off.

## Privacy

- The raw audio and speech recognition stay on your Mac. When AI is enabled, the transcript text is sent to the model you chose.
- The command-line route runs in a temporary empty directory, with no tools and without loading your configuration, plugins or MCP servers.
- API keys and other-AI settings are stored only on this Mac in `~/Library/Application Support/MeetCap/config.json` (permission 600, readable only by your account) and never enter the repository.
- If an AI call fails, the raw transcript is kept as usual. Logs do not record transcript content.

## Tests

```sh
python3 -m unittest -v test_meeting_recorder.py
```

These cover only text processing and how model calls are assembled. They do not record audio or touch the network.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): free for personal and noncommercial use. You may use, modify and distribute it for those purposes.

Commercial use (including use in your work at a company or other for-profit organization, or building it into a commercial product or service) requires a separate license. Please [open an issue](https://github.com/HWY1dot0/meetcap/issues) to get in touch.
