# Changelog

All notable changes to ChatGauge. Versions follow [Semantic Versioning](https://semver.org).

## 0.1.0 (unreleased preview)

First test build.

### Added
- Menu bar chat with a local Ollama model: streaming replies, Stop, New chat, Copy, and the ⌃⌥C hotkey
  (changeable in Settings).
- Images by drag, drop or paste on the composer, the chat window and the menu bar icon; vision support is
  detected per model.
- Model picker with Automatic (by memory tier) as the default, and a clear Starting / Loading model / Ready
  status line for cold loads.
- Models folder on this Mac or an external drive, with a "Models drive not connected" card that clears when the
  drive mounts.
- Low-memory fallback to a smaller installed model, with a note; never downloads a model on its own. A one-time
  note when a memory-hungry video editor is open.
- Instructions: standing instructions, presets, a glossary, a prompt preview, and a one-time glossary import.
- Chats saved as Markdown or JSON in a folder you choose, with a searchable history window.
- Hold-to-talk voice input with whisper.cpp, entirely on this Mac.
- Settings in eight tabs, with Export, Import and Reset, launch at login and a scrubbed Diagnostics report.
- Daily read-only update checks for ChatGauge, Ollama, whisper.cpp, ffmpeg and installed models, with
  notifications, an Updates tab and an optional install-when-idle mode that never runs while a reply is
  generating or a video editor is open.
