# Lump for Google Antigravity, Local Voice Dictation & Meeting Notes

This fork extends [joebentham/desk-buddy](https://github.com/joebentham/desk-buddy) so Lump works natively with **Google Antigravity** (and **Gemini CLI**) — with or without the physical ESP32 prism — and adds a **\$0/month local voice & Personal Assistant stack** on Apple Silicon Macs.

## What's Added

1. **Google Antigravity Lifecycle Hooks (`tools/antigravity_hook.py`, `tools/install_antigravity_hooks.py`)**
   - Translates Antigravity's camelCase hooks (`SessionStart`, `PreInvocation`, `PreToolUse`, `PostToolUse`, `Stop`) into Lump's bridge format (`http://127.0.0.1:47823/hook`).
   - Safe and non-blocking (350 ms timeout; only intercepts `ask_question` on `PreToolUse` so tool permission prompts are never bypassed).
2. **Claude-Free Mac Bridge Installer (`tools/install_bridge_google.sh`) & Custom Colour**
   - Installs `com.deskbuddy.bridge` + Lump's ocarina/gag sounds without the Claude desktop Accessibility watcher.
   - Set `"colour": "4285F4"` (e.g. Gemini Blue) in `~/.desk-buddy/config.json` to repaint Lump live on the fly.
3. **LumpDesk — Floating Virtual Glass Prism (`tools/lumpdesk/`)**
   - A borderless, draggable, always-on-top macOS companion (`~/Applications/LumpDesk.app`) rendering `design/lump.html?widget=1` at full resolution (`180 / 240 / 320 px`).
   - Click Lump for tap gags + sound effects, drag anywhere to reposition, right-click for size, sound, microphone, and meeting controls.
4. **\$0/month Local Voice Dictation + Agent Mode (`tools/voice_worker.py`, `tools/install_voice.sh`)**
   - **Dictation Mode (`⌥ ⌥` double-tap Option):** Local Apple Silicon `mlx-whisper` (`whisper-large-v3-turbo`, English pinned) transcribes your speech and auto-pastes straight into whichever app your cursor is in (restoring your clipboard afterward).
   - **Agent Mode (Mic button):** Sends your spoken request to `gemini` CLI (covered by your Google AI plan) or the `google-antigravity` Python SDK, animates Lump while working, and speaks the reply back locally using **Kokoro-82M neural TTS** (`bm_fable`, `am_puck`, `af_heart`, etc.).
   - **Smart Microphone Auto-Selection:** Automatically prefers connected Shure/external mics and falls back to the built-in MacBook mic when unplugged.
   - **Expressive States:** No text overlay clutter — Lump perks up (`awake`) with a voice-reactive pulsing prism rim while listening, switches to `working` while processing, and celebrates (`done`) while speaking.
5. **Zero-Bot Meeting Dictation Buddy (`tools/lumpdesk/MeetingRecorder.swift`)**
   - Dual-track capture: your microphone (`You`) + macOS **ScreenCaptureKit** system audio (`Others`) in 20-second rotating WAV chunks — no bots joining your calls.
   - Auto-records scheduled meetings when `calendar_ics` (or `~/.desk-buddy/meetings.json`) is configured.
   - On stop, summarizes into **Executive Summary**, **Key Decisions**, and **Action Items** under `~/Documents/Lump-PA/meetings/` and appends `- [ ]` action items to `~/Documents/Lump-PA/today.md`.

---

## Quick Start (macOS, Apple Silicon)

```bash
# 1. Install the bridge (without Claude's appwatch) and generate Lump's sounds
./tools/install_bridge_google.sh

# 2. Wire up Antigravity global hooks (~/.gemini/config/hooks.json)
python3 tools/install_antigravity_hooks.py

# 3. Optional: set Gemini Blue in ~/.desk-buddy/config.json
python3 -c 'import json, os; p=os.path.expanduser("~/.desk-buddy/config.json"); cfg=json.load(open(p)) if os.path.exists(p) else {}; cfg["colour"]="4285F4"; json.dump(cfg, open(p,"w"), indent=2)'

# 4. Install local voice stack (mlx-whisper + Kokoro-82M neural TTS)
~/.desk-buddy/venv/bin/pip install mlx-whisper kokoro-onnx soundfile google-antigravity
mkdir -p ~/.desk-buddy/kokoro
curl -L -o ~/.desk-buddy/kokoro/kokoro-v1.0.int8.onnx https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx
curl -L -o ~/.desk-buddy/kokoro/voices-v1.0.bin https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
./tools/install_voice.sh

# 5. Build and launch LumpDesk (floating virtual prism + voice + meeting recorder)
zsh tools/lumpdesk/build.sh
```

### macOS Permissions (for LumpDesk)
- **Microphone:** Prompted automatically on first recording.
- **Accessibility:** Required for `⌥ ⌥` global dictation auto-paste (`⌘V`) into other apps.
- **Screen & System Audio Recording:** Required for dual-track meeting recording (to capture remote participants' audio).

### Agent Mode Auth
- Run `gemini` once in Terminal and choose **Login with Google** to run Agent Mode & Meeting Summaries on your Google AI plan with no separate API key.
- Alternatively, set `"gemini_api_key"` in `~/.desk-buddy/config.json` (or `GEMINI_API_KEY` env var) to use the `google-antigravity` Python SDK directly.
