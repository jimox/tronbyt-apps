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

# The countdown bar drains over this window before a meeting starts.
COUNTDOWN_BAR_MINUTES = 60

WIDTH = 64
HEADER_HEIGHT = 9
BODY_HEIGHT = 16
BAR_HEIGHT = 2

# Fanatics flag, sampled from the logo at 13x11 and shown left of the title.
# X = full brightness, o = dim (smooths the curves), . = off.
FLAG = [
    "......oXXXXX.",
    "oXXXXXXXXXXXX",
    ".XXXXXXXXXXX.",
    ".oXXXXo......",
    ".......oXXo..",
    "...oXXXXXXo..",
    "...oXXXXXX...",
    "....XXo......",
    ".....X.......",
    ".....oo......",
    "......o......",
]
FLAG_COLOR = "#E63E30"
FLAG_DIM = "#5C1913"
FLAG_GAP = 2

CONTENT_WIDTH = 60
BAR_WIDTH = CONTENT_WIDTH
TITLE_WIDTH = CONTENT_WIDTH - len(FLAG[0]) - FLAG_GAP

# Rough tb-8 capacity of the two-line title area; longer titles scroll.
TITLE_FIT_CHARS = 16

# The header pulses from PULSE_BEFORE_MINUTES before a meeting starts until
# PULSE_AFTER_MINUTES after.
PULSE_BEFORE_MINUTES = 5
PULSE_AFTER_MINUTES = 1

# Milliseconds per frame. Long titles scroll 1px per frame, so this sets the
# scroll speed (100ms = 10px/s).
FRAME_MS = 100

# Frames per half-cycle of the pulse (~600ms at FRAME_MS).
PULSE_FRAMES = 6

# Used for the am/pm suffix and "til" so the header fits in 64px.
SMALL_FONT = "tom-thumb"

# Pseudo-font for header runs: one blank pixel per character.
GAP = "gap"

TRACK_COLOR = "#222222"
STALE_COLOR = "#ff8800"

def main(config):
    url = config.str("feed_url", "") or DEFAULT_FEED_URL
    tz = config.get("$tz", DEFAULT_TZ)

    # Starting-only mode renders only inside the pulse window and nothing
    # otherwise, so Tronbyt's Auto Pin pins the app for exactly that window.
    # It never renders error messages, which would also get pinned.
    starting_only = config.bool("starting_only", False)

    resp = http.get(url, ttl_seconds = CACHE_SECONDS)
    if resp.status_code != 200:
        if starting_only:
            return []
        if resp.status_code == 404:
            return message("No data from Apps Script yet")
        return message("pi-api: HTTP %d" % resp.status_code)

    body = resp.json()
    now = time.now().in_location(tz)
    received = time.parse_time(body["received_at"])
    stale = now - received > time.parse_duration("%dm" % STALE_MINUTES)
    events = body["data"].get("events", [])

    if starting_only:
        event = starting_event(events, now)
        return render_event(event, now, tz, stale) if event else []

    event = next_event(events, now)
    if not event:
        # If pushes stopped, the list drains to empty; say so instead of
        # silently hiding.
        return message("Feed stale") if stale else []

    return render_event(event, now, tz, stale)

def next_event(events, now):
    """The meeting in progress (latest start if several overlap), else the
    next one to start."""
    active = None
    upcoming = None
    for ev in events:
        start = time.parse_time(ev["start"])
        end = time.parse_time(ev["end"])
        if end <= now:
            continue
        if start <= now:
            if not active or start > active["start"]:
                active = to_event(ev, start, end)
        elif not upcoming or start < upcoming["start"]:
            upcoming = to_event(ev, start, end)
    return active or upcoming

def starting_event(events, now):
    """The meeting whose pulse window contains now (soonest start if several),
    even if another meeting is still in progress."""
    found = None
    for ev in events:
        start = time.parse_time(ev["start"])
        end = time.parse_time(ev["end"])
        if in_pulse_window(start, now) and end > now and (not found or start < found["start"]):
            found = to_event(ev, start, end)
    return found

def in_pulse_window(start, now):
    return (start - now <= time.parse_duration("%dm" % PULSE_BEFORE_MINUTES) and
            now - start < time.parse_duration("%dm" % PULSE_AFTER_MINUTES))

def to_event(ev, start, end):
    return {
        "title": ev.get("title") or "(no title)",
        "start": start,
        "end": end,
        "color": ev.get("color") or "#D50000",
    }

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

    if in_pulse_window(start, now):
        frames = [header(left, right, color)] * PULSE_FRAMES
        frames += [header(left, right, dim(color, 0.55))] * PULSE_FRAMES
        top = render.Animation(children = frames)
    else:
        top = header(left, right, color)

    screen = render.Column(
        children = [
            top,
            render.Padding(pad = (2, 1, 0, 0), child = render.Row(
                cross_align = "center",
                children = [
                    render.Box(width = len(FLAG[0]), height = BODY_HEIGHT, child = flag()),
                    render.Box(width = FLAG_GAP, height = 1),
                    title(ev["title"]),
                ],
            )),
            render.Padding(pad = (2, 3, 0, 0), child = bar(progress, bar_color)),
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

    return render.Root(delay = FRAME_MS, child = screen)

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
    wrapped = render.WrappedText(text, width = TITLE_WIDTH, font = "tb-8", color = "#ffffff")
    if len(text) <= TITLE_FIT_CHARS:
        return render.Box(width = TITLE_WIDTH, height = BODY_HEIGHT, child = wrapped)
    return render.Marquee(
        width = TITLE_WIDTH,
        height = BODY_HEIGHT,
        scroll_direction = "vertical",
        offset_start = 0,
        child = wrapped,
    )

def flag():
    rows = []
    for line in FLAG:
        cells = []
        for ch in line.elems():
            if ch == "X":
                cells.append(render.Box(width = 1, height = 1, color = FLAG_COLOR))
            elif ch == "o":
                cells.append(render.Box(width = 1, height = 1, color = FLAG_DIM))
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
            schema.Toggle(
                id = "starting_only",
                name = "Only when starting",
                desc = "Show only from 5 min before a meeting starts until 1 min after. Pair with Tronbyt's Auto Pin.",
                icon = "thumbtack",
                default = False,
            ),
        ],
    )
