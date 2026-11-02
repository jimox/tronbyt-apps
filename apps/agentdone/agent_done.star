"""
Applet: Agent Done
Summary: Coding agent finished
Description: Shows when Claude Code (or another agent) finishes working or needs your input. Hidden unless there's a recent message.
Author: Jim Oxenhandler
"""

load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

# Messages are pushed by tools/hooks (see hooks/claude_notify.py) through
# pi-api's relay; this app only shows the latest one while it's recent.
DEFAULT_FEED_URL = "http://pi-api:8081/relay/feeds/agents"
DEFAULT_DURATION = "10"
CACHE_SECONDS = 30

WIDTH = 64
HEADER_HEIGHT = 9
FRAME_MS = 100

# Header bar brightness relative to the event color, as in Next Up.
HEADER_BRIGHTNESS = 0.5

EVENTS = {
    "done": ("DONE", "#33B679"),
    "input": ("INPUT", "#F6BF26"),
}

# Body layout under the header (rows 9-31): margin, project line (icon
# height), gap, then two lines of summary that scroll upward if longer.
TOP_MARGIN = 1
PROJECT_HEIGHT = 9
GAP_HEIGHT = 1
SUMMARY_LINE_HEIGHT = 6
SUMMARY_HEIGHT = 2 * SUMMARY_LINE_HEIGHT
CONTENT_WIDTH = WIDTH - 2

# Claude spark, 9x9 pixel art in Claude orange.
SPARK = [
    "....X....",
    ".X..X..X.",
    "..X.X.X..",
    "...XXX...",
    "XXXXXXXXX",
    "...XXX...",
    "..X.X.X..",
    ".X..X..X.",
    "....X....",
]
SPARK_COLOR = "#D97757"
ICON_GAP = 3

SUMMARY_COLOR = "#bbbbbb"

# Where the letters actually sit in each font's text box: (first lit row,
# lit height). Every font also leaves 1 blank column after the last character.
FONT_METRICS = {
    "tom-thumb": (0, 5),
    "tb-8": (1, 6),
}

def main(config):
    url = config.str("feed_url", "") or DEFAULT_FEED_URL
    minutes = int(config.str("duration", DEFAULT_DURATION) or DEFAULT_DURATION)
    tz = config.get("$tz", "America/New_York")

    # Hidden unless there's a recent message; errors hide it too, so nothing
    # broken ever shows up in rotation.
    resp = http.get(url, ttl_seconds = CACHE_SECONDS)
    if resp.status_code != 200:
        return []
    body = resp.json()
    now = time.now().in_location(tz)
    age = now - time.parse_time(body["received_at"])
    if age >= time.parse_duration("%dm" % minutes):
        return []

    msg = body.get("data", {})
    return render.Root(delay = FRAME_MS, child = render_message(msg, age))

def render_message(msg, age):
    label, color = EVENTS.get(msg.get("event", ""), EVENTS["done"])
    mins = int(age.minutes)
    ago = "now" if mins < 1 else "%dm ago" % mins

    return render.Column(
        children = [
            header(label, ago, dim(color, HEADER_BRIGHTNESS)),
            render.Box(width = WIDTH, height = TOP_MARGIN),
            render.Padding(pad = (1, 0, 1, 0), child = project_line(msg)),
            render.Box(width = WIDTH, height = GAP_HEIGHT),
            render.Padding(pad = (1, 0, 1, 0), child = summary_line(msg.get("summary", ""))),
        ],
    )

def header(left, right, color):
    """Dark top pixel row, then the colored bar with the event and its age."""
    bar = render.Box(
        width = WIDTH,
        height = HEADER_HEIGHT - 1,
        color = color,
        child = render.Padding(
            pad = (1, 0, 1, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                cross_align = "end",
                children = [
                    render.Text(left, font = "tb-8", color = "#ffffff"),
                    render.Text(right, font = "tom-thumb", color = "#ffffff"),
                ],
            ),
        ),
    )
    return render.Column(children = [render.Box(width = WIDTH, height = 1), bar])

def project_line(msg):
    agent = msg.get("agent", "")
    if agent == "claude":
        icon = render.Box(width = len(SPARK[0]), height = PROJECT_HEIGHT, child = pixel_art(SPARK, SPARK_COLOR))
    else:
        # Future agents: their initial until they get an icon.
        initial = (agent[:1] or "?").upper()
        icon = centered(initial, "tb-8", SPARK_COLOR, len(SPARK[0]), PROJECT_HEIGHT)

    name = msg.get("project", "") or "(unknown)"
    width = CONTENT_WIDTH - len(SPARK[0]) - ICON_GAP
    if text_width(name, "tb-8") > width:
        text = render.Marquee(
            width = width,
            child = centered(name, "tb-8", "#ffffff", text_width(name, "tb-8"), PROJECT_HEIGHT),
        )
    else:
        text = centered(name, "tb-8", "#ffffff", text_width(name, "tb-8"), PROJECT_HEIGHT)

    return render.Row(children = [icon, render.Box(width = ICON_GAP, height = 1), text])

def summary_line(summary):
    """Wrapped to the screen width; scrolls upward (and loops) when it's
    longer than SUMMARY_HEIGHT allows. Marquee only scrolls if it has to."""
    if not summary:
        return render.Box(width = CONTENT_WIDTH, height = SUMMARY_HEIGHT)
    text = render.WrappedText(summary, width = CONTENT_WIDTH, font = "tom-thumb", color = SUMMARY_COLOR)
    return render.Marquee(
        width = CONTENT_WIDTH,
        height = SUMMARY_HEIGHT,
        scroll_direction = "vertical",
        offset_start = 0,
        child = text,
    )

def pixel_art(rows, color):
    lines = []
    for line in rows:
        cells = []
        for ch in line.elems():
            cells.append(render.Box(width = 1, height = 1, color = color) if ch == "X" else render.Box(width = 1, height = 1))
        lines.append(render.Row(children = cells))
    return render.Column(children = lines)

def centered(text, font, color, width, height):
    """Text whose visible glyphs are centered in a width x height box."""
    t = render.Text(text, font = font, color = color)
    tw, _ = t.size()
    top, glyph_h = FONT_METRICS[font]
    left = max(0, (width - (tw - 1)) // 2)
    down = max(0, (height - glyph_h) // 2 - top)
    return render.Stack(
        children = [
            render.Box(width = width, height = height),
            render.Padding(pad = (left, down, 0, 0), child = t),
        ],
    )

def text_width(text, font):
    w, _ = render.Text(text, font = font).size()
    return w - 1

def dim(hex_color, factor):
    h = hex_color.lstrip("#")
    digits = "0123456789abcdef"
    out = "#"
    for k in (0, 2, 4):
        v = int(int(h[k:k + 2], 16) * factor)
        out += digits[v // 16] + digits[v % 16]
    return out

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "duration",
                name = "Show for",
                desc = "How long to show a message after it arrives.",
                icon = "clock",
                default = DEFAULT_DURATION,
                options = [
                    schema.Option(display = "%s minutes" % m, value = m)
                    for m in ["5", "10", "15", "30", "60"]
                ],
            ),
            schema.Text(
                id = "feed_url",
                name = "Feed URL",
                desc = "pi-api feed URL.",
                icon = "link",
                default = DEFAULT_FEED_URL,
            ),
        ],
    )
