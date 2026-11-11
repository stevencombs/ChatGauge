# Changelog

## Unreleased — build 16

- Optional offline image generation with mflux (installed only after a click and a dry run). Catalog: FLUX.2 Klein 4B (4.6 GB, Apache 2.0), Z-Image Turbo (5.9 GB, Apache 2.0), and an optional uncensored Klein 4B text encoder (8.0 GB; model card license flux-non-commercial-v2.1). mflux cannot load that encoder as-is; Generate Image will not silently fall back to the official encoder.
- Generate image mode in the Chat Window, RAM-based model suggestion, and save to a ChatGauge Images folder on the models drive. ChatGauge never unloads an Ollama model it did not load.
- Each installed chat model has its own instructions (OT-79), replacing the single shared preset as the system prompt.
- Import ClipGauge glossary is a read-only, one-time import with a dry run first (OT-100).


## 0.1.0 — 2026-11-09

First public release.

- Local chat in a menu-bar popover or a Chat Window, with Markdown saved chats.
- Vision (drop or paste an image) and optional voice input via whisper.cpp.
- First-run setup guide: Homebrew tools, models folder, Ollama, optional uncensored models, and a test prompt.
- Chat organization: pin, search, date groups, move, and export.
- Model catalog with sizes and descriptions. Per-chat model picker in the header; Settings default for new chats.
- Optional uncensored vision models, installed only when you choose them.
- Remove a model from Settings with a confirm step that names the model and the space it will free.
- Free-space readout for the models drive.
- Fully local: prompts, images, and chats stay on this Mac.
