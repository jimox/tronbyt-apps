# Next Up

Shows the next important meeting from Google Calendar. Hides itself when
nothing qualifies.

```
Apps Script (every 5 min, runs as you; filters RSVP + red)
  → POST https://<tunnel host>/relay/push/nextup
  → pi-api on the Pi (github.com/jimox/pi-api)
  ← GET http://pi-api:8081/relay/feeds/nextup
  ← next_up.star (Tronbyt)
```

Workspace blocks both "Anyone" web apps and third-party OAuth, so the
calendar is read by Apps Script and pushed out, rather than pulled.

## Setup

1. Get pi-api running on the Pi with a `nextup` feed and the Cloudflare
   tunnel route (see its README). Note the `NEXTUP_TOKEN`.
2. Go to https://script.google.com signed in to the work account, create a
   project and paste in `apps_script/Code.gs`.
3. Project Settings → Script Properties:
   - `PUSH_URL` = `https://<tunnel host>/relay/push/nextup`
   - `PUSH_TOKEN` = the `NEXTUP_TOKEN` value
   - optional: `RSVP`, `RED_ONLY`, `MAX_EVENTS`, `LOOKAHEAD_HOURS`
     (see the top of `Code.gs`)
4. Run `pushNextUp` once from the editor and approve the calendar and
   external-request permissions. Check the execution log for errors.
5. Run `installTrigger` once to push every 5 minutes.
6. Add the app in Tronbyt. The default feed URL assumes Tronbyt and pi-api
   share a Docker network.

## Display

- Countdown ("in 12m", "NOW" in red), title (scrolls), time range.
- The left bar is the event's color.
- "OLD" in the corner means the last push was over 15 minutes ago.
- A meeting stays up for 10 minutes after it starts, then the next one shows.

## Local render

```
pixlet serve next_up.star
```
