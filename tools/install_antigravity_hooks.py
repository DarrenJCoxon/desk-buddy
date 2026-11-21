#!/usr/bin/env python3
"""Install (or uninstall) Lump's Antigravity lifecycle hooks in ~/.gemini/config/hooks.json.

    python3 tools/install_antigravity_hooks.py
    python3 tools/install_antigravity_hooks.py --uninstall

Preserves any existing hooks in hooks.json and creates a timestamped backup before editing.
"""
import argparse
import json
import os
import shutil
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNTIME = os.path.expanduser("~/.desk-buddy")
DEFAULT_HOOKS_PATH = os.path.expanduser("~/.gemini/config/hooks.json")
HOOK_KEY = "desk-buddy-lump"


def build_hook_spec(cmd: str) -> dict:
    handler = {"type": "command", "command": cmd, "timeout": 5}
    return {
        "enabled": True,
        "SessionStart": [handler],
        "PreInvocation": [handler],
        "PreToolUse": [
            {
                "matcher": "ask_question",
                "hooks": [handler],
            }
        ],
        "PostToolUse": [
            {
                "matcher": "*",
                "hooks": [handler],
            }
        ],
        "Stop": [handler],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hooks-file", default=DEFAULT_HOOKS_PATH, help=f"Path to hooks.json (default: {DEFAULT_HOOKS_PATH})")
    ap.add_argument("--uninstall", action="store_true", help="Remove Lump's Antigravity hooks")
    args = ap.parse_args()

    path = os.path.expanduser(args.hooks_file)
    data = {}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        shutil.copy2(path, f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}")

    if args.uninstall:
        removed = data.pop(HOOK_KEY, None) is not None
        if removed:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
                f.write("\n")
            print(f"Removed '{HOOK_KEY}' from {path}")
        else:
            print(f"Nothing to remove in {path}")
        return 0

    os.makedirs(RUNTIME, exist_ok=True)
    adapter_dst = os.path.join(RUNTIME, "antigravity_hook.py")
    shutil.copy2(os.path.join(ROOT, "tools", "antigravity_hook.py"), adapter_dst)
    os.chmod(adapter_dst, 0o755)

    cmd = f"python3 {adapter_dst}"
    data[HOOK_KEY] = build_hook_spec(cmd)

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

    print(f"Installed '{HOOK_KEY}' into {path}")
    print(f"Adapter copied to {adapter_dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
