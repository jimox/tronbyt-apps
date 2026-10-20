"""
Applet: Next Up
Summary: Next important meeting
Description: Shows the next important meeting from work calendar.
Author: Jim Oxenhandler
"""

load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

# Meetings are filtered by the Apps Script and relayed through pi-api; this
# app only decides which one is next and renders it.
DEFAULT_FEED_URL = "http://pi-api:8081/relay/feeds/nextup"
DEFAULT_TZ = "America/New_York"
CACHE_SECONDS = 60

# The Apps Script pushes every 5 minutes; flag the data after a few misses.
STALE_MINUTES = 15

# Keep showing a meeting this long after it starts before moving on.
GRACE_MINUTES = 10

def main(config):
    url = config.str("feed_url", "") or DEFAULT_FEED_URL
    tz = config.get("$tz", DEFAULT_TZ)

    resp = http.get(url, ttl_seconds = CACHE_SECONDS)
    if resp.status_code == 404:
        return message("No data from Apps Script yet")
    if resp.status_code != 200:
        return message("pi-api: HTTP %d" % resp.status_code)

    body = resp.json()
    now = time.now().in_location(tz)
    received = time.parse_time(body["received_at"])
    stale = now - received > time.parse_duration("%dm" % STALE_MINUTES)

    event = next_event(body["data"].get("events", []), now)
    if not event:
        # If pushes stopped, the list drains to empty; say so instead of
        # silently hiding.
        return message("Feed stale") if stale else []

    return render_event(event, now, tz, stale)

def next_event(events, now):
    cutoff = now - time.parse_duration("%dm" % GRACE_MINUTES)
    for ev in events:
        start = time.parse_time(ev["start"])
        end = time.parse_time(ev["end"])
        if end <= now or start < cutoff:
            continue
        return {
            "title": ev.get("title") or "(no title)",
            "start": start,
            "end": end,
            "color": ev.get("color") or "#D50000",
        }
    return None

def countdown(start, now):
    mins = int((start - now).minutes)
    if mins <= 0:
        return "NOW"
    if mins < 60:
        return "in %dm" % mins
    if mins < 10 * 60:
        return "in %dh%02dm" % (mins // 60, mins % 60)
    return start.format("Mon 3:04")

def render_event(ev, now, tz, stale):
    start = ev["start"].in_location(tz)
    end = ev["end"].in_location(tz)
    when = countdown(start, now)

    footer = [
        render.Text(
            "%s-%s" % (start.format("3:04"), end.format("3:04")),
            font = "tom-thumb",
            color = "#888888",
        ),
    ]
    if stale:
        footer.append(render.Text("OLD", font = "tom-thumb", color = "#ff8800"))

    return render.Root(
        delay = 80,
        child = render.Row(
            children = [
                render.Box(width = 2, height = 32, color = ev["color"]),
                render.Padding(
                    pad = (2, 1, 0, 0),
                    child = render.Column(
                        children = [
                            render.Text(
                                when,
                                font = "6x13",
                                color = "#ff4444" if when == "NOW" else "#ffffff",
                            ),
                            render.Marquee(
                                width = 60,
                                child = render.Text(ev["title"], font = "tb-8"),
                            ),
                            render.Box(
                                width = 60,
                                height = 6,
                                child = render.Row(
                                    expanded = True,
                                    main_align = "space_between",
                                    children = footer,
                                ),
                            ),
                        ],
                    ),
                ),
            ],
        ),
    )

def message(text):
    return render.Root(
        child = render.WrappedText(text, font = "tb-8", color = "#ff8800"),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "feed_url",
                name = "Feed URL",
                desc = "pi-api feed URL.",
                icon = "link",
                default = DEFAULT_FEED_URL,
            ),
        ],
    )
