#!/usr/bin/env python3
"""
Claude Code hook: push "done" / "needs input" to pi-api for the Agent Done app.

Register for the Stop and Notification events in ~/.claude/settings.json:

    {"type": "command", "command": "python3 /path/to/claude_notify.py"}

Settings come from ~/.config/agent-notify/env (KEY=value lines, chmod 600):

    PUSH_URL=https://<tunnel host>/relay/push/agents
    PUSH_TOKEN=<AGENTS_TOKEN on the Pi>
    CF_ACCESS_CLIENT_ID=<Cloudflare Access service token id>        (optional)
    CF_ACCESS_CLIENT_SECRET=<Cloudflare Access service token secret> (optional)

The hook never prints and always exits 0, so it can't block or change
Claude's behavior if the Pi or the tunnel is unreachable.
"""

import json
import os
import pathlib
import re
import sys
import urllib.request

ENV_FILE = pathlib.Path(os.environ.get("AGENT_NOTIFY_ENV", pathlib.Path.home() / ".config" / "agent-notify" / "env"))
TIMEOUT_SECONDS = 3
SUMMARY_CHARS = 90


def load_env():
    env = {}
    try:
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return env


def clean(text):
    """First non-empty line, without markdown markers, capped in length."""
    for line in text.splitlines():
        line = re.sub(r"^\s*(#+|[-*>]|\d+\.)\s+", "", line)
        line = re.sub(r"[*`_]{1,3}", "", line).strip()
        if line:
            return line if len(line) <= SUMMARY_CHARS else line[: SUMMARY_CHARS - 1].rstrip() + "…"
    return ""


def last_assistant_text(transcript_path):
    """Text of the last assistant message in a Claude Code transcript (JSONL)."""
    text = ""
    try:
        with open(transcript_path, encoding="utf-8") as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("type") != "assistant":
                    continue
                content = entry.get("message", {}).get("content", [])
                if isinstance(content, str):
                    parts = [content]
                else:
                    parts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
                joined = "\n".join(p for p in parts if p.strip())
                if joined:
                    text = joined
    except OSError:
        pass
    return text


def payload(event):
    name = event.get("hook_event_name", "")
    if name == "Notification":
        kind, summary = "input", clean(event.get("message", "")) or "Needs your input"
    else:
        kind, summary = "done", clean(last_assistant_text(event.get("transcript_path", ""))) or "Finished"
    return {
        "agent": "claude",
        "event": kind,
        "project": os.path.basename(os.path.normpath(event.get("cwd") or os.getcwd())),
        "summary": summary,
        "session": (event.get("session_id") or "")[:8],
    }


def push(env, body):
    headers = {"Content-Type": "application/json", "Authorization": "Bearer " + env["PUSH_TOKEN"]}
    if env.get("CF_ACCESS_CLIENT_ID") and env.get("CF_ACCESS_CLIENT_SECRET"):
        headers["CF-Access-Client-Id"] = env["CF_ACCESS_CLIENT_ID"]
        headers["CF-Access-Client-Secret"] = env["CF_ACCESS_CLIENT_SECRET"]
    req = urllib.request.Request(env["PUSH_URL"], data=json.dumps(body).encode(), headers=headers, method="POST")
    urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS).close()


def main():
    try:
        env = load_env()
        if not env.get("PUSH_URL") or not env.get("PUSH_TOKEN"):
            return
        event = json.load(sys.stdin)
        push(env, payload(event))
    except Exception:
        # Never let a notification problem affect Claude Code.
        pass


if __name__ == "__main__":
    main()
    sys.exit(0)
