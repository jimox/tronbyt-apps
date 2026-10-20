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
   - `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` = the Cloudflare
     Access service token, if the tunnel host is behind Access (needs an
     Access app for the `relay/push` path with a Service Auth policy)
   - optional: `RSVP`, `RED_ONLY`, `MAX_EVENTS`, `LOOKAHEAD_HOURS`
     (see the top of `Code.gs`)
4. Run `pushNextUp` once from the editor and approve the calendar and
   external-request permissions. Check the execution log for errors.
5. Run `installTrigger` once to push every 5 minutes.
6. Add the app in Tronbyt. The default feed URL assumes Tronbyt and pi-api
   share a Docker network.

## Display

- Header in the event's color: countdown and start time ("in 12m · 2:30pm"),
  or "NOW · til 3:00pm" during the meeting. It pulses from 5 minutes before
  the start until 1 minute after.
- Fanatics flag on the left; title wraps to two lines and scrolls if longer.
- Bottom bar: fills over the last hour before a meeting, then shows progress
  through it.
- An orange dot in the bottom-right corner means the last push was over 15
  minutes ago.
- A meeting in progress stays up until it ends. If meetings overlap, the one
  that started most recently is shown. Otherwise the next upcoming meeting is
  shown.

## Pinning while a meeting starts

The **Only when starting** setting makes the app render only from 5 minutes
before a meeting starts until 1 minute after (the same window as the header
pulse), and render nothing otherwise, including on errors. Tronbyt's
**Auto Pin** pins an app while it renders and unpins it when it renders
nothing, so together they pin the meeting to the screen for that window.

Typical setup: install Next Up twice.

1. Normal install, in regular rotation.
2. Second install with **Only when starting** on, **Auto Pin** on, and a
   1-minute render interval so the pin starts and ends promptly.

## Local render

```
pixlet serve next_up.star
```
