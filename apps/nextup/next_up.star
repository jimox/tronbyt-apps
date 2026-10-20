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

# The countdown bar drains over this window before a meeting starts.
COUNTDOWN_BAR_MINUTES = 60

WIDTH = 64
HEADER_HEIGHT = 9
BODY_HEIGHT = 16
BAR_HEIGHT = 2

# Fanatics flag, hand-drawn from the logo for the 7px footer row. The
# progress bar takes the rest of the row.
FLAG = [
    "XX...XXXX",
    ".XXXXXXXX",
    ".XXX.....",
    ".........",
    "..XXXXXX.",
    "...XXX...",
    "....X....",
]
FLAG_COLOR = "#E63E30"
FLAG_GAP = 2

CONTENT_WIDTH = 60
BAR_WIDTH = CONTENT_WIDTH - len(FLAG[0]) - FLAG_GAP

# Rough tb-8 capacity of the two-line title area; longer titles scroll.
TITLE_FIT_CHARS = 22

# Frames per half-cycle of the NOW pulse (Root delay is 80ms).
PULSE_FRAMES = 8

# Used for the am/pm suffix and "til" so the header fits in 64px.
SMALL_FONT = "tom-thumb"

# Pseudo-font for header runs: one blank pixel per character.
GAP = "gap"

TRACK_COLOR = "#222222"
STALE_COLOR = "#ff8800"

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

def render_event(ev, now, tz, stale):
    start = ev["start"].in_location(tz)
    end = ev["end"].in_location(tz)
    color = ev["color"]
    started = start <= now

    if started:
        left, right = "NOW", [("til", SMALL_FONT), (" ", GAP)] + clock(end)
        progress = (now - start).seconds / (end - start).seconds
        bar_color = color
    else:
        mins = int((start - now).minutes)
        left, right = countdown(start, mins), clock(start)
        progress = 1 - mins / COUNTDOWN_BAR_MINUTES if mins < COUNTDOWN_BAR_MINUTES else 0
        bar_color = "#ffffff" if mins < 5 else "#888888"

    if started:
        frames = [header(left, right, color)] * PULSE_FRAMES
        frames += [header(left, right, dim(color, 0.55))] * PULSE_FRAMES
        top = render.Animation(children = frames)
    else:
        top = header(left, right, color)

    screen = render.Column(
        children = [
            top,
            render.Padding(pad = (2, 0, 0, 0), child = title(ev["title"])),
            render.Padding(pad = (2, 0, 0, 0), child = footer(progress, bar_color)),
        ],
    )

    if stale:
        # Small orange corner dot: last push is older than STALE_MINUTES.
        screen = render.Stack(
            children = [
                screen,
                render.Padding(
                    pad = (WIDTH - 3, 29, 0, 0),
                    child = render.Box(width = 3, height = 3, color = STALE_COLOR),
                ),
            ],
        )

    return render.Root(delay = 80, child = screen)

def header(left, right, color):
    """right is a list of (text, font) runs, bottom-aligned."""
    fg = text_color(color)
    return render.Box(
        width = WIDTH,
        height = HEADER_HEIGHT,
        color = color,
        child = render.Padding(
            pad = (1, 1, 1, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                cross_align = "end",
                children = [
                    render.Text(left, font = "tb-8", color = fg),
                    render.Row(
                        cross_align = "end",
                        children = [run(t, f, fg) for t, f in right],
                    ),
                ],
            ),
        ),
    )

def run(text, font, color):
    if font == GAP:
        return render.Box(width = len(text), height = 1)
    return render.Text(text, font = font, color = color)

def title(text):
    wrapped = render.WrappedText(text, width = CONTENT_WIDTH, font = "tb-8", color = "#ffffff")
    if len(text) <= TITLE_FIT_CHARS:
        return render.Box(width = CONTENT_WIDTH, height = BODY_HEIGHT, child = wrapped)
    return render.Marquee(
        width = CONTENT_WIDTH,
        height = BODY_HEIGHT,
        scroll_direction = "vertical",
        offset_start = 0,
        child = wrapped,
    )

def footer(progress, color):
    return render.Row(
        cross_align = "end",
        children = [
            flag(),
            render.Box(width = FLAG_GAP, height = 1),
            bar(progress, color),
        ],
    )

def flag():
    rows = []
    for line in FLAG:
        cells = []
        for ch in line.elems():
            if ch == "X":
                cells.append(render.Box(width = 1, height = 1, color = FLAG_COLOR))
            else:
                cells.append(render.Box(width = 1, height = 1))
        rows.append(render.Row(children = cells))
    return render.Column(children = rows)

def bar(progress, color):
    fill = int(BAR_WIDTH * max(0, min(1, progress)))
    children = []
    if fill > 0:
        children.append(render.Box(width = fill, height = BAR_HEIGHT, color = color))
    if fill < BAR_WIDTH:
        children.append(render.Box(width = BAR_WIDTH - fill, height = BAR_HEIGHT, color = TRACK_COLOR))
    return render.Row(children = children)

def countdown(start, mins):
    if mins <= 0:
        return "now"
    if mins < 60:
        return "in %dm" % mins
    if mins < 10 * 60:
        return "%dh %sm" % (mins // 60, pad2(mins % 60))
    return start.format("Mon")

def clock(t):
    """Time as (text, font) runs: digits in tb-8, a smaller am/pm suffix."""
    return [(t.format("3:04"), "tb-8"), (t.format("pm"), SMALL_FONT)]

def pad2(n):
    return ("0" + str(n))[-2:]

def parse_hex(hex_color):
    h = hex_color.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)

def text_color(bg):
    r, g, b = parse_hex(bg)
    return "#000000" if 0.299 * r + 0.587 * g + 0.114 * b > 150 else "#ffffff"

def dim(hex_color, factor):
    digits = "0123456789abcdef"
    out = "#"
    for c in parse_hex(hex_color):
        v = int(c * factor)
        out += digits[v // 16] + digits[v % 16]
    return out

def message(text):
    return render.Root(
        child = render.WrappedText(text, font = "tb-8", color = STALE_COLOR),
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
