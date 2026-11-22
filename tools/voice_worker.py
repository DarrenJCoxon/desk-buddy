#!/usr/bin/env python3
"""Desk Buddy Voice Worker: local mlx-whisper STT -> Antigravity / Gemini CLI -> Kokoro neural TTS.

Runs a lightweight HTTP server on http://127.0.0.1:47824 that pairs with LumpDesk.app
and drives Lump's moods via buddy_bridge.py on http://127.0.0.1:47823/hook.

Endpoints:
  GET  /health               -> JSON status (state, last_transcript, last_reply, error, voice)
  GET  /voices               -> list available Kokoro voices
  POST /speak                -> JSON {"text": "...", "voice": "bm_fable", "speed": 1.05} (audition TTS)
  POST /transcribe_and_run   -> WAV bytes (audio/wav) or JSON {"text": "..."}
  POST /stop_speaking        -> stop current TTS playback
  POST /reset                -> reset the conversation session
"""
import asyncio
import http.server
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid

HOME = os.environ.get("DESKBUDDY_HOME") or os.path.expanduser("~/.desk-buddy")
VOICE_PORT = 47824
BRIDGE_HOOK_URL = "http://127.0.0.1:47823/hook"
DEFAULT_WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"
DEFAULT_WHISPER_LANG = "en"
DEFAULT_TTS_ENGINE = "edge"
DEFAULT_EDGE_VOICE = "en-GB-SoniaNeural"
DEFAULT_KOKORO_VOICE = "bm_fable"
DEFAULT_KOKORO_SPEED = 1.05
KOKORO_DIR = os.path.join(HOME, "kokoro")
PA_DIR = os.path.expanduser("~/Documents/Lump-PA")
MEETINGS_DIR = os.path.join(PA_DIR, "meetings")

os.makedirs(HOME, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(os.path.join(HOME, "voice.log")),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("voice_worker")


def read_config() -> dict:
    p = os.path.join(HOME, "config.json")
    try:
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def post_bridge_hook(payload: dict) -> None:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        BRIDGE_HOOK_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=0.5):
            pass
    except Exception as e:
        log.warning("bridge hook failed: %s", e)


def clean_for_speech(text: str) -> str:
    """Strip markdown formatting so neural TTS reads cleanly."""
    s = re.sub(r"```[\s\S]*?```", " I've put the code details in the log. ", text)
    s = re.sub(r"`([^`]+)`", r"\1", s)
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)
    s = re.sub(r"[#*_~>]+", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    if len(s) > 600:
        s = s[:597].rsplit(" ", 1)[0] + "..."
    return s


SYSTEM_PROMPT = (
    "You are Lump, a friendly, capable desk buddy and Personal Assistant powered by Google Antigravity and Gemini. "
    "You help the user with coding, meetings, and organising their day. "
    f"The user's PA files live in {PA_DIR} (today.md for today's priorities & action items, inbox.md for quick captures, meetings/ for meeting notes). "
    "Your final response will be spoken aloud, so keep it warm, natural, and concise "
    "(1 to 3 short sentences, no markdown formatting or raw code blocks in your spoken reply)."
)


class VoiceCoordinator:
    def __init__(self):
        self.lock = threading.Lock()
        self.state = "idle"
        self.last_transcript = ""
        self.last_reply = ""
        self.last_error = ""
        self.session_id = f"lump-voice-{uuid.uuid4().hex[:8]}"
        self._play_proc: subprocess.Popen | None = None
        self._kokoro = None
        self._kokoro_lock = threading.Lock()
        self._history: list[tuple[str, str]] = []
        self._meeting: dict | None = None
        self._meeting_lock = threading.Lock()

        # Dedicated background asyncio event loop for the Antigravity SDK (when API key is used)
        self._loop = asyncio.new_event_loop()
        self._agent = None
        self._agent_cm = None
        threading.Thread(target=self._loop.run_forever, daemon=True).start()

    def _get_kokoro(self):
        with self._kokoro_lock:
            if self._kokoro is not None:
                return self._kokoro
            model_path = os.path.join(KOKORO_DIR, "kokoro-v1.0.int8.onnx")
            voices_path = os.path.join(KOKORO_DIR, "voices-v1.0.bin")
            if not (os.path.exists(model_path) and os.path.exists(voices_path)):
                return None
            from kokoro_onnx import Kokoro
            self._kokoro = Kokoro(model_path, voices_path)
            log.info("Loaded Kokoro-82M neural TTS (%d voices)", len(self._kokoro.get_voices()))
            return self._kokoro

    def list_voices(self) -> list[str]:
        k = self._get_kokoro()
        return sorted(k.get_voices()) if k else []

    def status(self) -> dict:
        cfg = read_config()
        with self._meeting_lock:
            m = self._meeting
            meeting_info = {"active": True, "title": m["title"], "path": m["path"], "lines": m["lines"]} if m else {"active": False}
        with self.lock:
            return {
                "ok": True,
                "state": self.state,
                "session_id": self.session_id,
                "voice": cfg.get("kokoro_voice") or DEFAULT_KOKORO_VOICE,
                "meeting": meeting_info,
                "last_transcript": self.last_transcript,
                "last_reply": self.last_reply,
                "last_error": self.last_error,
            }

    def set_state(self, st: str, error: str = "") -> None:
        with self.lock:
            self.state = st
            if error:
                self.last_error = error

    def stop_speaking(self) -> None:
        with self.lock:
            p = self._play_proc
            self._play_proc = None
        if p and p.poll() is None:
            try:
                p.terminate()
            except Exception:
                pass

    def speak(self, text: str, voice_override: str | None = None, speed_override: float | None = None) -> None:
        spoken = clean_for_speech(text)
        if not spoken:
            return
        self.stop_speaking()
        cfg = read_config()
        engine = (cfg.get("tts_engine") or DEFAULT_TTS_ENGINE).lower()
        # Allow explicit Kokoro voice override (e.g. bf_emma) or Edge voice override (e.g. en-GB-SoniaNeural)
        if voice_override and "Neural" in voice_override:
            engine = "edge"
        elif voice_override and "_" in voice_override:
            engine = "kokoro"

        self.set_state("speaking")
        tmp_path = None
        try:
            if engine == "edge":
                try:
                    import edge_tts

                    edge_voice = voice_override or cfg.get("edge_voice") or DEFAULT_EDGE_VOICE
                    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
                        tmp_path = tmp.name
                    t0 = time.time()
                    asyncio.run(edge_tts.Communicate(spoken, edge_voice).save(tmp_path))
                    log.info("edge-tts synthesized (%s) in %.2fs", edge_voice, time.time() - t0)
                except Exception as e:
                    log.warning("edge-tts failed (%s); falling back to Kokoro offline TTS", e)
                    if tmp_path:
                        try: os.unlink(tmp_path)
                        except OSError: pass
                        tmp_path = None
                    engine = "kokoro"

            if engine != "edge":
                voice = voice_override or cfg.get("kokoro_voice") or DEFAULT_KOKORO_VOICE
                speed = float(speed_override or cfg.get("kokoro_speed") or DEFAULT_KOKORO_SPEED)
                lang = "en-gb" if voice.startswith(("bf_", "bm_")) else "en-us"
                k = self._get_kokoro()
                if k is None:
                    log.warning("Kokoro model not ready; skipping speech")
                    return
                import soundfile as sf

                t0 = time.time()
                samples, sample_rate = k.create(spoken, voice=voice, speed=speed, lang=lang)
                with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                    tmp_path = tmp.name
                sf.write(tmp_path, samples, sample_rate)
                log.info("Kokoro synthesized (%s) in %.2fs", voice, time.time() - t0)

            proc = subprocess.Popen(["afplay", tmp_path])
            with self.lock:
                self._play_proc = proc
            proc.wait()
        except Exception as e:
            log.warning("TTS failed: %s", e)
        finally:
            with self.lock:
                self._play_proc = None
            if tmp_path:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
            self.set_state("idle")

    def transcribe_wav(self, audio_bytes: bytes, ext: str = ".m4a") -> str:
        import mlx_whisper

        cfg = read_config()
        model_repo = cfg.get("whisper_model") or DEFAULT_WHISPER_MODEL
        # Detect WAV vs M4A automatically from header bytes
        suffix = ".wav" if audio_bytes[:4] == b"RIFF" else ext
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp_path = tmp.name
        try:
            log.info("received audio: %d bytes (%s)", len(audio_bytes), suffix)
            # Quick silence check via ffmpeg so Whisper never hallucinates "Thank you." on muted/blocked mics
            try:
                vd = subprocess.run(
                    ["ffmpeg", "-hide_banner", "-i", tmp_path, "-af", "volumedetect", "-f", "null", "-"],
                    capture_output=True, text=True, timeout=5,
                )
                m = re.search(r"max_volume:\s*([-\d.]+)\s*dB", vd.stderr)
                if m:
                    max_db = float(m.group(1))
                    log.info("audio max_volume=%.1f dB", max_db)
                    if max_db < -55.0:
                        log.warning("audio is silent (%.1f dB); skipping whisper", max_db)
                        return ""
            except Exception:
                pass
            t0 = time.time()
            lang = cfg.get("whisper_language") or DEFAULT_WHISPER_LANG
            result = mlx_whisper.transcribe(
                tmp_path,
                path_or_hf_repo=model_repo,
                language=lang,
                condition_on_previous_text=False,
            )
            text = (result.get("text") or "").strip()
            log.info("transcribed in %.2fs: %r", time.time() - t0, text)
            return text
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    async def _ensure_sdk_agent(self, api_key: str):
        if self._agent is not None:
            return self._agent
        from google.antigravity import Agent, LocalAgentConfig, CapabilitiesConfig

        cfg = read_config()
        workspace = os.path.expanduser(cfg.get("voice_workspace") or os.getcwd())
        agent_cfg = LocalAgentConfig(
            system_instructions=SYSTEM_PROMPT,
            capabilities=CapabilitiesConfig(),
            workspaces=[workspace],
            api_key=api_key,
        )
        self._agent_cm = Agent(agent_cfg)
        self._agent = await self._agent_cm.__aenter__()
        log.info("Antigravity SDK Agent started (workspace=%s)", workspace)
        return self._agent

    async def _reset_agent_async(self):
        if self._agent_cm is not None:
            try:
                await self._agent_cm.__aexit__(None, None, None)
            except Exception:
                pass
        self._agent = None
        self._agent_cm = None
        self._history.clear()
        self.session_id = f"lump-voice-{uuid.uuid4().hex[:8]}"

    def reset(self) -> None:
        fut = asyncio.run_coroutine_threadsafe(self._reset_agent_async(), self._loop)
        try:
            fut.result(timeout=5)
        except Exception as e:
            log.warning("reset error: %s", e)

    async def _run_sdk_turn(self, prompt: str, api_key: str) -> str:
        agent = await self._ensure_sdk_agent(api_key)
        response = await agent.chat(prompt)
        chunks = []
        async for token in response:
            chunks.append(str(token))
        return "".join(chunks).strip()

    def _run_cli_turn(self, prompt: str) -> str:
        """Run via installed `agy` or `gemini` CLI (uses Google AI Ultra OAuth login at $0 extra)."""
        cfg = read_config()
        workspace = os.path.expanduser(cfg.get("voice_workspace") or os.getcwd())
        cli = (
            shutil.which("agy")
            or (os.path.expanduser("~/.local/bin/agy") if os.path.exists(os.path.expanduser("~/.local/bin/agy")) else None)
            or ("/opt/homebrew/bin/agy" if os.path.exists("/opt/homebrew/bin/agy") else None)
            or shutil.which("gemini")
        )
        if not cli:
            raise RuntimeError("Antigravity CLI (`agy`) not found. Install via `brew install --cask antigravity-cli`.")

        # Include brief rolling context from recent voice turns
        ctx_lines = [SYSTEM_PROMPT, ""]
        for u, a in self._history[-4:]:
            ctx_lines.append(f"User: {u}")
            ctx_lines.append(f"Lump: {a}")
        ctx_lines.append(f"User: {prompt}")
        full_prompt = "\n".join(ctx_lines)

        cmd = [cli, "-p", full_prompt]
        if os.path.basename(cli) == "agy":
            cmd = [cli, "--effort", "low", "-p", full_prompt]
        proc = subprocess.run(
            cmd,
            cwd=workspace,
            capture_output=True,
            text=True,
            timeout=240,
        )
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or f"exit {proc.returncode}").strip()
            raise RuntimeError(err)
        reply = (proc.stdout or "").strip()
        self._history.append((prompt, reply))
        return reply

    def _run_agent(self, prompt: str) -> str:
        cfg = read_config()
        api_key = cfg.get("gemini_api_key") or os.environ.get("GEMINI_API_KEY")
        if api_key:
            fut = asyncio.run_coroutine_threadsafe(self._run_sdk_turn(prompt, api_key), self._loop)
            return fut.result(timeout=300)
        return self._run_cli_turn(prompt)

    def _append_history(self, transcript: str, reply: str, error: str = "", mode: str = "agent") -> None:
        p = os.path.join(HOME, "voice_history.jsonl")
        entry = {
            "ts": time.time(),
            "session_id": self.session_id,
            "mode": mode,
            "transcript": transcript,
            "reply": reply,
            "error": error,
        }
        try:
            with open(p, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry) + "\n")
        except Exception:
            pass

    # ---- Meeting Dictation Buddy ----

    def meeting_start(self, title: str = "") -> dict:
        os.makedirs(MEETINGS_DIR, exist_ok=True)
        now = time.localtime()
        clean_title = (title or "").strip() or time.strftime("Meeting %H:%M", now)
        slug = re.sub(r"[^a-z0-9]+", "-", clean_title.lower()).strip("-") or "meeting"
        fname = f"{time.strftime('%Y-%m-%d-%H%M', now)}-{slug}.md"
        path = os.path.join(MEETINGS_DIR, fname)
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# {clean_title}\n\n")
            f.write(f"- **Date:** {time.strftime('%Y-%m-%d %H:%M', now)}\n\n")
            f.write("## Transcript\n\n")
        with self._meeting_lock:
            self._meeting = {
                "id": uuid.uuid4().hex[:8],
                "title": clean_title,
                "path": path,
                "started": time.time(),
                "lines": 0,
            }
            info = dict(self._meeting)
        post_bridge_hook({
            "hook_event_name": "UserPromptSubmit",
            "session_id": f"meeting-{info['id']}",
            "cwd": PA_DIR,
        })
        log.info("Meeting started: %s -> %s", clean_title, path)
        return info

    def meeting_chunk(self, wav_bytes: bytes, speaker: str = "You") -> dict:
        with self._meeting_lock:
            m = self._meeting
        if not m:
            return {"ignored": True, "reason": "no active meeting"}
        text = self.transcribe_wav(wav_bytes)
        if not text:
            return {"appended": False, "text": ""}
        stamp = time.strftime("%H:%M:%S")
        line = f"- **[{stamp}] {speaker}:** {text}\n"
        with self._meeting_lock:
            if self._meeting and self._meeting["id"] == m["id"]:
                with open(m["path"], "a", encoding="utf-8") as f:
                    f.write(line)
                self._meeting["lines"] += 1
        return {"appended": True, "text": text, "speaker": speaker}

    def meeting_stop_bg(self) -> dict:
        with self._meeting_lock:
            m = self._meeting
            self._meeting = None
        if not m:
            return {"stopped": False, "reason": "no active meeting"}
        threading.Thread(target=self._finalize_meeting, args=(m,), daemon=True).start()
        return {"stopped": True, "path": m["path"], "title": m["title"]}

    def _finalize_meeting(self, m: dict) -> None:
        path = m["path"]
        sid = f"meeting-{m['id']}"
        try:
            with open(path, "r", encoding="utf-8") as f:
                raw_md = f.read()

            transcript_part = raw_md.split("## Transcript", 1)[-1].strip()
            if not transcript_part:
                log.info("Meeting %s had empty transcript; skipping summary.", m["title"])
                post_bridge_hook({"hook_event_name": "Stop", "session_id": sid})
                self.speak("Meeting recording stopped, though I didn't catch any speech.")
                return

            self.set_state("working")
            summary_prompt = (
                "You are Lump, an executive assistant. Turn the following meeting transcript into "
                "crisp, actionable Markdown notes with exactly these three headings:\n"
                "## Executive Summary\n(2-4 bullet points)\n\n"
                "## Key Decisions\n(bullet points, or 'None noted.')\n\n"
                "## Action Items\n(Markdown checkboxes `- [ ] Owner: task`)\n\n"
                "Do not add preamble or wrap in code fences.\n\n"
                f"Meeting title: {m['title']}\n\nTranscript:\n{transcript_part}"
            )
            summary_md = self._run_agent(summary_prompt).strip()

            # Prepend AI summary above the raw transcript
            header, _, rest = raw_md.partition("## Transcript")
            final_md = f"{header}{summary_md}\n\n---\n\n## Transcript{rest}"
            with open(path, "w", encoding="utf-8") as f:
                f.write(final_md)

            # Extract action items (- [ ] ...) and append to ~/Documents/Lump-PA/today.md
            todos = [ln.strip() for ln in summary_md.splitlines() if ln.strip().startswith("- [ ]")]
            if todos:
                today_path = os.path.join(PA_DIR, "today.md")
                os.makedirs(PA_DIR, exist_ok=True)
                with open(today_path, "a", encoding="utf-8") as f:
                    f.write(f"\n### From {m['title']} ({time.strftime('%Y-%m-%d %H:%M')})\n")
                    for t in todos:
                        f.write(f"{t}\n")

            post_bridge_hook({"hook_event_name": "Stop", "session_id": sid})
            n = len(todos)
            if n:
                self.speak(f"Meeting notes saved! I also added {n} action {'item' if n == 1 else 'items'} to your today list.")
            else:
                self.speak("Meeting notes are summarized and saved to your meetings folder.")
        except Exception as e:
            log.exception("meeting finalize failed")
            self.set_state("idle", error=str(e))
            post_bridge_hook({"hook_event_name": "Stop", "session_id": sid})
            self.speak("Your meeting transcript is saved, though I couldn't run the AI summary yet. Make sure you're signed in to Gemini.")

    def handle_request_bg(self, wav_bytes: bytes | None = None, text: str | None = None) -> None:
        threading.Thread(
            target=self._process,
            kwargs={"wav_bytes": wav_bytes, "text": text},
            daemon=True,
        ).start()

    def _process(self, wav_bytes: bytes | None = None, text: str | None = None) -> None:
        self.stop_speaking()
        try:
            if wav_bytes is not None:
                self.set_state("transcribing")
                text = self.transcribe_wav(wav_bytes)
            prompt = (text or "").strip()
            if not prompt:
                log.info("empty transcript, ignoring")
                self.set_state("idle")
                return

            with self.lock:
                self.last_transcript = prompt
                self.last_error = ""

            post_bridge_hook({
                "hook_event_name": "UserPromptSubmit",
                "session_id": self.session_id,
                "cwd": os.getcwd(),
            })
            self.set_state("working")

            reply = self._run_agent(prompt)

            with self.lock:
                self.last_reply = reply

            self._append_history(prompt, reply)

            post_bridge_hook({
                "hook_event_name": "Stop",
                "session_id": self.session_id,
            })

            self.speak(reply or "All done!")
        except Exception as e:
            log.exception("voice turn failed")
            self.set_state("idle", error=str(e))
            self._append_history(self.last_transcript, "", error=str(e))
            post_bridge_hook({
                "hook_event_name": "PostToolUseFailure",
                "session_id": self.session_id,
            })
            post_bridge_hook({
                "hook_event_name": "Stop",
                "session_id": self.session_id,
            })


coord = VoiceCoordinator()


def build_dashboard_payload() -> dict:
    today_md = ""
    inbox_md = ""
    try:
        with open(os.path.join(PA_DIR, "today.md"), "r", encoding="utf-8") as f:
            today_md = f.read()
    except OSError:
        pass
    try:
        with open(os.path.join(PA_DIR, "inbox.md"), "r", encoding="utf-8") as f:
            inbox_md = f.read()
    except OSError:
        pass

    meetings_cal = []
    try:
        with open(os.path.join(HOME, "meetings.json"), "r", encoding="utf-8") as f:
            meetings_cal = json.load(f)
    except Exception:
        pass

    meeting_notes = []
    if os.path.isdir(MEETINGS_DIR):
        for name in sorted(os.listdir(MEETINGS_DIR), reverse=True):
            if not name.endswith(".md"):
                continue
            fpath = os.path.join(MEETINGS_DIR, name)
            title = name[:-3]
            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    first = f.readline().strip()
                    if first.startswith("# "):
                        title = first[2:].strip()
                st = os.stat(fpath)
                meeting_notes.append({
                    "name": name,
                    "title": title,
                    "date": time.strftime("%a %d %b %H:%M", time.localtime(st.st_mtime)),
                    "size_kb": round(st.st_size / 1024.0, 1),
                })
            except OSError:
                pass

    voice_history = []
    hp = os.path.join(HOME, "voice_history.jsonl")
    if os.path.isfile(hp):
        try:
            with open(hp, "r", encoding="utf-8") as f:
                for line in f.readlines()[-20:]:
                    line = line.strip()
                    if line:
                        voice_history.append(json.loads(line))
        except Exception:
            pass

    bridge_status = {}
    try:
        with urllib.request.urlopen("http://127.0.0.1:47823/status", timeout=0.4) as r:
            bridge_status = json.loads(r.read().decode("utf-8"))
    except Exception:
        pass

    cfg = read_config()
    safe_cfg = {k: v for k, v in cfg.items() if "key" not in k.lower() and "token" not in k.lower()}

    build_monitor_md = ""
    bm_path = cfg.get("build_monitor_file")
    if bm_path:
        bm_full = os.path.expanduser(bm_path)
        if os.path.isfile(bm_full):
            try:
                with open(bm_full, "r", encoding="utf-8") as f:
                    build_monitor_md = f.read()
            except OSError:
                pass

    return {
        "today_md": today_md,
        "inbox_md": inbox_md,
        "meetings_cal": meetings_cal,
        "meeting_notes": meeting_notes,
        "voice_history": voice_history,
        "bridge_status": bridge_status,
        "voice_status": coord.status(),
        "build_monitor_md": build_monitor_md,
        "config": safe_cfg,
    }


class VoiceHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _reply(self, code: int, body: bytes = b"", ctype: str = "application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            dash_path = os.path.join(HOME, "dashboard.html")
            if not os.path.exists(dash_path):
                dash_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboard.html")
            if os.path.exists(dash_path):
                with open(dash_path, "rb") as f:
                    self._reply(200, f.read(), "text/html; charset=utf-8")
            else:
                self._reply(404, b"dashboard.html not found", "text/plain")
        elif path == "/api/dashboard":
            self._reply(200, json.dumps(build_dashboard_payload()).encode("utf-8"))
        elif path.startswith("/api/meeting/"):
            fname = os.path.basename(urllib.request.unquote(path[len("/api/meeting/"):]))
            fpath = os.path.join(MEETINGS_DIR, fname)
            if fname.endswith(".md") and os.path.isfile(fpath):
                with open(fpath, "rb") as f:
                    self._reply(200, f.read(), "text/markdown; charset=utf-8")
            else:
                self._reply(404, b"Meeting note not found", "text/plain")
        elif path == "/health":
            self._reply(200, json.dumps(coord.status(), indent=2).encode("utf-8"))
        elif path == "/voices":
            self._reply(200, json.dumps(coord.list_voices(), indent=2).encode("utf-8"))
        else:
            self._reply(404, b'{"error":"not found"}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length > 0 else b""
        if self.path == "/transcribe":
            try:
                coord.set_state("transcribing")
                text = coord.transcribe_wav(body)
                with coord.lock:
                    if text:
                        coord.last_transcript = text
                if text:
                    coord._append_history(text, "", mode="dictate")
                coord.set_state("idle")
                self._reply(200, json.dumps({"text": text}).encode("utf-8"))
            except Exception as e:
                log.exception("dictation transcribe failed")
                coord.set_state("idle", error=str(e))
                self._reply(500, json.dumps({"error": str(e)}).encode("utf-8"))
        elif self.path == "/transcribe_and_run":
            ctype = (self.headers.get("Content-Type") or "").lower()
            if "application/json" in ctype:
                try:
                    data = json.loads(body.decode("utf-8") or "{}")
                    coord.handle_request_bg(text=data.get("text", ""))
                    self._reply(202, b'{"accepted":true}')
                except Exception as e:
                    self._reply(400, json.dumps({"error": str(e)}).encode("utf-8"))
            else:
                coord.handle_request_bg(wav_bytes=body)
                self._reply(202, b'{"accepted":true}')
        elif self.path == "/speak":
            try:
                data = json.loads(body.decode("utf-8") or "{}")
                threading.Thread(
                    target=coord.speak,
                    args=(data.get("text", ""), data.get("voice"), data.get("speed")),
                    daemon=True,
                ).start()
                self._reply(202, b'{"speaking":true}')
            except Exception as e:
                self._reply(400, json.dumps({"error": str(e)}).encode("utf-8"))
        elif self.path == "/stop_speaking":
            coord.stop_speaking()
            self._reply(200, b'{"stopped":true}')
        elif self.path == "/reset":
            coord.reset()
            self._reply(200, b'{"reset":true}')
        elif self.path == "/meeting/start":
            try:
                data = json.loads(body.decode("utf-8") or "{}") if body else {}
                info = coord.meeting_start(data.get("title", ""))
                self._reply(200, json.dumps(info).encode("utf-8"))
            except Exception as e:
                self._reply(500, json.dumps({"error": str(e)}).encode("utf-8"))
        elif self.path.startswith("/meeting/chunk"):
            speaker = "Others" if "speaker=Others" in self.path else "You"
            try:
                res = coord.meeting_chunk(body, speaker=speaker)
                self._reply(200, json.dumps(res).encode("utf-8"))
            except Exception as e:
                log.exception("meeting chunk failed")
                self._reply(500, json.dumps({"error": str(e)}).encode("utf-8"))
        elif self.path == "/meeting/stop":
            res = coord.meeting_stop_bg()
            self._reply(202, json.dumps(res).encode("utf-8"))
        elif self.path == "/api/todo/toggle":
            try:
                data = json.loads(body.decode("utf-8") or "{}")
                idx = int(data.get("line", -1))
                today_path = os.path.join(PA_DIR, "today.md")
                if os.path.isfile(today_path):
                    lines = open(today_path, "r", encoding="utf-8").read().splitlines()
                    if 0 <= idx < len(lines):
                        if "- [ ]" in lines[idx]:
                            lines[idx] = lines[idx].replace("- [ ]", "- [x]", 1)
                        elif "- [x]" in lines[idx] or "- [X]" in lines[idx]:
                            lines[idx] = re.sub(r"- \[[xX]\]", "- [ ]", lines[idx], count=1)
                        with open(today_path, "w", encoding="utf-8") as f:
                            f.write("\n".join(lines) + "\n")
                self._reply(200, b'{"ok":true}')
            except Exception as e:
                self._reply(400, json.dumps({"error": str(e)}).encode("utf-8"))
        elif self.path == "/api/todo/add":
            try:
                data = json.loads(body.decode("utf-8") or "{}")
                text = (data.get("text") or "").strip()
                target = data.get("target") or "today"
                if text:
                    os.makedirs(PA_DIR, exist_ok=True)
                    if target == "inbox":
                        p = os.path.join(PA_DIR, "inbox.md")
                        with open(p, "a", encoding="utf-8") as f:
                            f.write(f"\n- {text}")
                    else:
                        p = os.path.join(PA_DIR, "today.md")
                        with open(p, "a", encoding="utf-8") as f:
                            f.write(f"\n- [ ] {text}")
                self._reply(200, b'{"ok":true}')
            except Exception as e:
                self._reply(400, json.dumps({"error": str(e)}).encode("utf-8"))
        elif self.path == "/api/voice/clear":
            try:
                hp = os.path.join(HOME, "voice_history.jsonl")
                if os.path.isfile(hp):
                    os.unlink(hp)
                self._reply(200, b'{"ok":true}')
            except Exception as e:
                self._reply(500, json.dumps({"error": str(e)}).encode("utf-8"))
        elif self.path == "/api/colour":
            try:
                data = json.loads(body.decode("utf-8") or "{}")
                col = (data.get("colour") or "").strip().lstrip("#").upper()
                if len(col) == 6:
                    p = os.path.join(HOME, "config.json")
                    cfg = read_config()
                    cfg["colour"] = col
                    with open(p, "w", encoding="utf-8") as f:
                        json.dump(cfg, f, indent=2)
                self._reply(200, b'{"ok":true}')
            except Exception as e:
                self._reply(400, json.dumps({"error": str(e)}).encode("utf-8"))
        else:
            self._reply(404, b'{"error":"not found"}')


def main():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", VOICE_PORT), VoiceHandler)
    log.info("Desk Buddy voice worker listening on http://127.0.0.1:%d", VOICE_PORT)
    srv.serve_forever()


if __name__ == "__main__":
    main()
