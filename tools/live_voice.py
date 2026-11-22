#!/usr/bin/env python3
"""Lump Live Voice — real-time, human-grade audio-to-audio companion via Gemini Live API.

Streams your microphone directly to Gemini Live (sub-second, warm, interruptible voice),
drives Lump's live moods on :47823, and exposes a `run_pa_task` tool that hands real work
(opening apps/files, checking Calendar/Gmail, prepping meetings, editing today.md, coding)
off to Antigravity (`agy --mode auto`) in ~/Documents/Lump-PA.

Usage:
  1. Add `"gemini_api_key": "AIza..."` to ~/.desk-buddy/config.json (or export GEMINI_API_KEY).
  2. Install pyaudio or sounddevice in ~/.desk-buddy/venv:
       ~/.desk-buddy/venv/bin/pip install sounddevice
  3. Run:
       ~/.desk-buddy/venv/bin/python tools/live_voice.py
"""
import asyncio
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

HOME = os.path.expanduser("~/.desk-buddy")
PA_DIR = os.path.expanduser("~/Documents/Lump-PA")
BRIDGE_HOOK_URL = "http://127.0.0.1:47823/hook"
LIVE_MODEL = "gemini-2.5-flash-native-audio-preview-12-2025"
INPUT_RATE = 16000
OUTPUT_RATE = 24000
VOICE_NAME = "Aoede"  # Warm, natural voice (options: Aoede, Puck, Charon, Kore, Fenrir)


def read_config() -> dict:
    try:
        with open(os.path.join(HOME, "config.json"), "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def post_hook(ev: str, sid: str = "lump-live"):
    try:
        req = urllib.request.Request(
            BRIDGE_HOOK_URL,
            data=json.dumps({"hook_event_name": ev, "session_id": sid, "cwd": PA_DIR}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=0.3).read()
    except Exception:
        pass


def load_pa_context() -> str:
    """Load current PA snapshot (today.md + meetings.json) so Live Voice answers schedule/task questions instantly."""
    parts = []
    today_path = os.path.join(PA_DIR, "today.md")
    if os.path.isfile(today_path):
        try:
            parts.append("=== TODAY & WEEK AHEAD (today.md) ===\n" + open(today_path, encoding="utf-8").read()[:4000])
        except OSError:
            pass
    mtg_path = os.path.join(HOME, "meetings.json")
    if os.path.isfile(mtg_path):
        try:
            ms = json.load(open(mtg_path, encoding="utf-8"))
            now = time.time()
            upcoming = [m for m in ms if (m.get("end") or m.get("start", 0) + 3600) > now - 600][:10]
            if upcoming:
                lines = [
                    f"- {time.strftime('%a %d %b %H:%M', time.localtime(m['start']))}: {m.get('summary') or m.get('title')}"
                    for m in upcoming
                ]
                parts.append("=== UPCOMING CALENDAR EVENTS (meetings.json) ===\n" + "\n".join(lines))
        except Exception:
            pass
    return "\n\n".join(parts)


def open_on_mac(target: str) -> str:
    """Instantly open a URL, file path, or macOS application on Darren's desktop."""
    t = (target or "").strip()
    if not t:
        return "Nothing specified to open."
    try:
        if t.startswith(("http://", "https://")):
            subprocess.Popen(["open", t])
            return f"Opened {t} in your default browser."
        expanded = os.path.expanduser(t)
        if os.path.exists(expanded):
            subprocess.Popen(["open", expanded])
            return f"Opened {expanded}."
        # Try opening as a macOS application name
        res = subprocess.run(["open", "-a", t], capture_output=True, text=True)
        if res.returncode == 0:
            return f"Opened application {t}."
        # Fallback: treat as domain if it looks like a URL without scheme
        if "." in t and " " not in t:
            url = f"https://{t}"
            subprocess.Popen(["open", url])
            return f"Opened {url} in your default browser."
        return f"Could not open '{t}': {res.stderr.strip()}"
    except Exception as e:
        return f"Failed to open '{t}': {e}"


def run_antigravity_task(instruction: str) -> str:
    """Delegate real PA / coding actions to Antigravity CLI (`agy --mode auto`)."""
    cli = (
        shutil.which("agy")
        or (os.path.expanduser("~/.local/bin/agy") if os.path.exists(os.path.expanduser("~/.local/bin/agy")) else None)
        or ("/opt/homebrew/bin/agy" if os.path.exists("/opt/homebrew/bin/agy") else None)
    )
    if not cli:
        return "Antigravity CLI (agy) is not installed."
    post_hook("UserPromptSubmit")
    try:
        os.makedirs(PA_DIR, exist_ok=True)
        enriched = (
            f"Darren's PA files are in {PA_DIR} (today.md, inbox.md, meetings/, prep/) "
            f"and synced calendar events are in {os.path.join(HOME, 'meetings.json')}.\n\n"
            f"Task: {instruction}"
        )
        proc = subprocess.run(
            [cli, "--mode", "auto", "--effort", "low", "-p", enriched],
            cwd=PA_DIR,
            capture_output=True,
            text=True,
            timeout=180,
        )
        out = (proc.stdout or proc.stderr or "Done.").strip()
        return out[:1500]
    except Exception as e:
        return f"Task failed: {e}"
    finally:
        post_hook("Stop")


async def run_live_session():
    cfg = read_config()
    api_key = cfg.get("gemini_api_key") or os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("Set 'gemini_api_key' in ~/.desk-buddy/config.json or export GEMINI_API_KEY first.")
        print("Get a free/pay-as-you-go key at https://aistudio.google.com/apikey")
        return 1

    try:
        import sounddevice as sd
    except ImportError:
        print("Install sounddevice first: ~/.desk-buddy/venv/bin/pip install sounddevice")
        return 1

    from google import genai
    from google.genai import types

    client = genai.Client(api_key=api_key, http_options={"api_version": "v1alpha"})
    voice = cfg.get("live_voice") or VOICE_NAME
    model = cfg.get("live_model") or LIVE_MODEL

    tools = [
        types.Tool(
            function_declarations=[
                types.FunctionDeclaration(
                    name="open_on_mac",
                    description=(
                        "Instantly open a webpage URL (https://...), local file path, or macOS app directly "
                        "on Darren's desktop. ALWAYS use this tool immediately whenever Darren asks to open a "
                        "website, link, document, folder, or application."
                    ),
                    parameters=types.Schema(
                        type=types.Type.OBJECT,
                        properties={
                            "target": types.Schema(
                                type=types.Type.STRING,
                                description="Full URL (e.g. https://calendar.google.com), file path (e.g. ~/Documents/Lump-PA/today.md), or macOS app name (e.g. Notion).",
                            )
                        },
                        required=["target"],
                    ),
                ),
                types.FunctionDeclaration(
                    name="run_pa_task",
                    description=(
                        "Execute a multi-step PA or coding task via Antigravity: update today.md or inbox.md, "
                        "create a meeting/training prep brief in ~/Documents/Lump-PA/prep/, search local files, "
                        "or run coding/CI tasks."
                    ),
                    parameters=types.Schema(
                        type=types.Type.OBJECT,
                        properties={
                            "instruction": types.Schema(
                                type=types.Type.STRING,
                                description="Clear instruction for Antigravity to execute.",
                            )
                        },
                        required=["instruction"],
                    ),
                ),
            ]
        )
    ]

    pa_snapshot = load_pa_context()
    sys_text = (
        "You are Lump, Darren's warm, sharp, conversational Executive PA and thought-partner living on his desk. "
        f"Current local time: {time.strftime('%A %d %B %Y, %H:%M')}. "
        "Chat naturally like a smart, trusted colleague — you can brainstorm ideas, help Darren think through "
        "presentations, training sessions, strategy, or tough decisions, ask good follow-up questions, and keep "
        "the conversation flowing effortlessly. "
        "You also have Darren's current schedule, watch-outs, and priorities below — answer schedule and task questions immediately from it. "
        "Only call `run_pa_task` when Darren explicitly asks you to take an action on his Mac (open a file/URL/app, "
        "edit today.md or inbox.md, write a prep sheet in prep/, or run a coding/CI task).\n\n"
        + pa_snapshot
    )

    live_cfg = types.LiveConnectConfig(
        response_modalities=[types.Modality.AUDIO],
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=voice)
            )
        ),
        system_instruction=types.Content(
            parts=[types.Part.from_text(text=sys_text)]
        ),
        tools=tools,
    )

    loop = asyncio.get_running_loop()
    in_q: asyncio.Queue[bytes] = asyncio.Queue(maxsize=30)
    out_stream = sd.RawOutputStream(samplerate=OUTPUT_RATE, channels=1, dtype="int16", blocksize=1024)
    out_stream.start()

    def mic_callback(indata, frames, time_info, status):
        try:
            loop.call_soon_threadsafe(in_q.put_nowait, bytes(indata))
        except asyncio.QueueFull:
            pass

    in_stream = sd.RawInputStream(
        samplerate=INPUT_RATE, channels=1, dtype="int16", blocksize=1024, callback=mic_callback
    )
    in_stream.start()

    started = time.time()
    playing_until = 0.0
    print(f"Lump Live Voice connected ({model}, voice={voice}). Speak naturally — Ctrl+C to stop.")
    post_hook("SessionStart")

    try:
        async with client.aio.live.connect(model=model, config=live_cfg) as session:
            async def send_audio():
                while True:
                    pcm = await in_q.get()
                    # Flat 0.25s tail after playback finishes (never accumulates per chunk)
                    if time.time() < playing_until + 0.25:
                        continue
                    await session.send_realtime_input(
                        audio=types.Blob(data=pcm, mime_type="audio/pcm;rate=16000")
                    )

            async def recv_loop():
                nonlocal playing_until
                while True:
                    async for msg in session.receive():
                        if msg.server_content and msg.server_content.model_turn:
                            for part in msg.server_content.model_turn.parts:
                                if part.inline_data and part.inline_data.data:
                                    data = part.inline_data.data
                                    dur = len(data) / float(OUTPUT_RATE * 2)
                                    playing_until = max(playing_until, time.time()) + dur
                                    out_stream.write(data)
                        if msg.tool_call:
                            for fc in msg.tool_call.function_calls:
                                if fc.name == "open_on_mac":
                                    target = (fc.args or {}).get("target", "")
                                    print(f"[Lump] Opening: {target}", flush=True)
                                    result = open_on_mac(target)
                                    await session.send_tool_response(
                                        function_responses=[
                                            types.FunctionResponse(
                                                id=fc.id,
                                                name=fc.name,
                                                response={"result": result},
                                            )
                                        ]
                                    )
                                elif fc.name == "run_pa_task":
                                    instr = (fc.args or {}).get("instruction", "")
                                    print(f"[Lump PA] Running: {instr}", flush=True)
                                    result = await asyncio.to_thread(run_antigravity_task, instr)
                                    await session.send_tool_response(
                                        function_responses=[
                                            types.FunctionResponse(
                                                id=fc.id,
                                                name=fc.name,
                                                response={"result": result},
                                            )
                                        ]
                                    )

            await asyncio.gather(send_audio(), recv_loop())
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        in_stream.stop(); in_stream.close()
        out_stream.stop(); out_stream.close()
        mins = (time.time() - started) / 60.0
        # Rough Gemini 2.5 Flash Native Audio Live estimate (~$0.015–$0.03/min depending on talk ratio)
        print(f"\nSession ended ({mins:.1f} min). Est. Live API cost: ~${mins * 0.02:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run_live_session()))
