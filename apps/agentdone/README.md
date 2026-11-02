# Agent Done

Shows when Claude Code (or another agent) finishes working or needs your
input. The app is hidden unless a message arrived within the configured time
(default 10 minutes), so it only joins the normal rotation when there's
something to see.

```
Claude Code hook (Stop / Notification)
  → POST https://<tunnel host>/relay/push/agents   (pi-api relay)
  ← GET  http://pi-api:8081/relay/feeds/agents    (this app)
```

Only the latest message is kept; a new one replaces it.

## Display

- Header: `DONE` (green) or `INPUT` (amber), and how long ago.
- Claude spark and the project (folder) name.
- First line of Claude's last reply, or the notification text, scrolling if
  long.

Settings: **Show for** (5–60 min) and the feed URL.

## Setup

1. **pi-api**: add an `agents` feed to `config.yaml` and `AGENTS_TOKEN` to
   `.env`, then `docker compose up -d`:

   ```yaml
   relay:
     feeds:
       agents:
         token: ${AGENTS_TOKEN}
         max_bytes: 8192
   ```

   The existing Cloudflare Access rule for `relay/push` already covers it.

2. **Hook settings**: create `~/.config/agent-notify/env` (`chmod 600`):

   ```
   PUSH_URL=https://<tunnel host>/relay/push/agents
   PUSH_TOKEN=<AGENTS_TOKEN>
   CF_ACCESS_CLIENT_ID=<service token id>
   CF_ACCESS_CLIENT_SECRET=<service token secret>
   ```

3. **Claude Code hooks** in `~/.claude/settings.json`, for both `Stop` and
   `Notification`:

   ```json
   {"type": "command", "command": "python3 <repo>/apps/agentdone/hooks/claude_notify.py"}
   ```

   The script uses only the Python standard library, never prints, and
   always exits 0 within ~3s, so it can't block Claude Code.

4. **Tronbyt**: add the app with a 1-minute render interval so it appears and
   disappears promptly.

## Other agents

Anything can push the same JSON to the `agents` feed:

```json
{"agent": "claude", "event": "done", "project": "tronbyt-apps", "summary": "..."}
```

`event` is `done` or `input`. Agents other than `claude` show their initial
in place of the spark.

## Local render

```
pixlet render agent_done.star feed_url=http://<pi>:8081/relay/feeds/agents
```
