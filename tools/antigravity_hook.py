#!/usr/bin/env python3
"""Antigravity lifecycle hook adapter for Lump (Desk Buddy).

Reads an Antigravity hook JSON payload on stdin (camelCase), translates it to the
snake_case payload expected by tools/buddy_bridge.py on http://127.0.0.1:47823/hook,
sends it with a short timeout so it never blocks Antigravity, and prints the
required JSON response for Antigravity on stdout.
"""
import json
import sys
import urllib.request

BRIDGE_URL = "http://127.0.0.1:47823/hook"


def translate(payload: dict) -> dict | None:
    ev = payload.get("hookEventName", "")
    sid = payload.get("conversationId") or "antigravity"
    cwd = payload.get("cwd") or ""
    out = {
        "session_id": sid,
        "cwd": cwd,
    }

    if ev == "SessionStart":
        out["hook_event_name"] = "SessionStart"
        out["source"] = "startup"
    elif ev == "PreInvocation":
        # Play "on_it" sound on the first invocation of a turn; stay quietly working after.
        inv = payload.get("invocationNum") or 0
        out["hook_event_name"] = "UserPromptSubmit" if inv <= 1 else "PostToolUse"
    elif ev == "PreToolUse":
        tool_name = (payload.get("toolCall") or {}).get("name", "")
        out["hook_event_name"] = "PreToolUse"
        out["tool_name"] = "AskUserQuestion" if tool_name == "ask_question" else tool_name
    elif ev == "PostToolUse":
        if payload.get("error"):
            out["hook_event_name"] = "PostToolUseFailure"
        else:
            out["hook_event_name"] = "PostToolUse"
    elif ev == "Stop":
        out["hook_event_name"] = "Stop"
    else:
        return None

    return out


def post_event(data: dict) -> None:
    body = json.dumps(data).encode("utf-8")
    req = urllib.request.Request(
        BRIDGE_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=0.35):
            pass
    except Exception:
        # Never block or fail Antigravity if the bridge is offline.
        pass


def main() -> int:
    raw = sys.stdin.read().strip()
    try:
        payload = json.loads(raw) if raw else {}
    except Exception:
        payload = {}

    ev = payload.get("hookEventName", "")
    mapped = translate(payload)
    if mapped:
        post_event(mapped)

    # Return the contract-compliant JSON response expected by Antigravity.
    if ev == "PreToolUse":
        resp = {"decision": "allow"}
    elif ev == "Stop":
        resp = {"decision": "stop"}
    else:
        resp = {}

    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
