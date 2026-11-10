# ChatGauge

A local, on-device chat app for the Mac. ChatGauge talks to a vision-capable model that runs on your computer through Ollama, so your questions, images, and conversations stay on this Mac.

It is a popover or a chat window, with pinned chats, projects, a first-run setup guide, and a model picker — including optional uncensored models you can install yourself.

**Download:** [latest release](https://github.com/stevencombs/ChatGauge/releases/latest) · [Website](https://stevencombs.github.io/ChatGauge/)

## Requirements

- A Mac running macOS 14 Sonoma or later. Apple silicon is recommended; Intel Macs are supported if they have enough RAM.
- **RAM guidance:** 16 GB is enough for the 3B chat model. 32 GB is comfortable for the 7B vision model. The optional 32B model wants 48 GB or more. Leave headroom for macOS and your other apps.
- Disk space for models (the 7B vision model is about 6 GB). You choose the folder during setup.

## Install with Homebrew

```bash
brew install --cask stevencombs/tap/chatgauge
```

Or download the zip from the [latest release](https://github.com/stevencombs/ChatGauge/releases/latest), move ChatGauge into `/Applications`, and open it. The app is ad-hoc signed and is not notarized, so macOS may ask you to allow it under System Settings › Privacy & Security.

ChatGauge does not download models when you install the cask. The first-run setup guide walks you through Homebrew tools (Ollama, ffmpeg, whisper.cpp), a models folder, and the chat model you want.

## First-run setup guide

The first time you open ChatGauge it offers a setup guide. You can skip it and come back later from Settings.

1. Check whether Homebrew and the chat tools are already on this Mac.
2. Pick a models folder (an external drive is fine).
3. Review the recommended tools and models, including optional voice (whisper.cpp).
4. Optionally install uncensored vision models, if you want them. They only download when you click Install.
5. Point ChatGauge at an Ollama server that is already running, or start one that serves your models folder. ChatGauge will not restart a shared Ollama LaunchAgent.
6. Send a short test prompt, then start chatting.

## Using ChatGauge

- **Chat:** type in the popover or the Chat Window. Drop in an image for vision models. Hold the mic to talk when voice is set up.
- **Chats:** conversations are Markdown files in `~/Library/Application Support/ChatGauge/Chats`. Pin, search, group, move, and export from the Chat Window.
- **Models:** the chat header has a picker for the model used in that chat. Settings has the default for new chats, plus Install and Remove. Remove names the model and the space it will free, then asks you to confirm. ChatGauge only unloads a model first if it loaded it; it will not evict a model another app is using.
- **Privacy:** ChatGauge is fully local. Prompts, images, and saved chats do not leave this Mac. There is no account and no telemetry.

## Uncensored models

The catalog includes two optional uncensored vision models (`huihui_ai/qwen2.5-vl-abliterated:7b` and `huihui_ai/qwen3-vl-abliterated:8b-instruct`). They are not installed unless you choose them in Settings or the setup guide.

## Build from source

Needs Xcode Command Line Tools on a Mac.

```bash
swift build -c release --disable-sandbox
./scripts/test.sh
./scripts/build-app.sh
```

`scripts/build-app.sh` writes `dist/ChatGauge-<version>.zip`. CI and release builds set `REQUIRE_UNIVERSAL=1`.

## Support and the other Gauges

ChatGauge is made by [retroCombs](https://youtube.com/@retroCombs). Tech notes live at [youtube.com/@retroCombs-tech](https://youtube.com/@retroCombs-tech).

- [GrokGauge](https://github.com/stevencombs/GrokGauge) — your Grok usage, right in the menu bar
- [ClipGauge](https://github.com/stevencombs/ClipGauge) — local transcription and summarization

Questions: [retroCombs@icloud.com](mailto:retroCombs@icloud.com). Support the project on [PayPal](https://paypal.me/stevencombs).

## License

[MIT](LICENSE) © 2026 Steven Combs (retroCombs)
