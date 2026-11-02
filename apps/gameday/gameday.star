"""
Applet: Gameday
Summary: Favorite teams' scores
Description: Live score, today's final, or next game for your favorite NFL, MLB, NHL, college football and NWSL teams.
Author: Jim Oxenhandler
"""

load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

ESPN = "https://site.api.espn.com/apis/site/v2/sports"
ESPN_CDN = "https://a.espncdn.com"

# (config id, display label, ESPN path, extra scoreboard params)
LEAGUES = [
    ("nfl", "NFL", "football/nfl", {}),
    ("mlb", "MLB", "baseball/mlb", {}),
    ("nhl", "NHL", "hockey/nhl", {}),
    ("cfb", "CFB", "football/college-football", {"groups": "80"}),
    ("nwsl", "NWSL", "soccer/usa.nwsl", {}),
]

DEFAULT_TZ = "America/New_York"

SCOREBOARD_CACHE_SECONDS = 60
TEAM_CACHE_SECONDS = 1800
LOGO_CACHE_SECONDS = 86400

WIDTH = 64
HEADER_HEIGHT = 7

# Live games use a side-by-side layout: away logo | scores | home logo, with a
# team-color name tag under each logo.
SIDE_WIDTH = 17
CENTER_WIDTH = 64 - 2 * SIDE_WIDTH
TAG_HEIGHT = 7

# Logos fill the team row. ESPN's resizer produces them at exactly this size,
# which is much crisper than letting pixlet shrink a larger image.
LOGO_SIZE = 16

# Finals and upcoming games use stacked team-color rows: header (7), top row
# (12), a dark 1px gap, bottom row (12). Row logos are a little taller than
# the rows and overlap the edges.
STACKED_HEADER_HEIGHT = 7
STACKED_ROW_HEIGHT = 12
STACKED_GAP = 1
ROW_LOGO_SIZE = 14

FRAME_MS = 100

# When several games are live (or final today), each gets this many frames.
FRAMES_PER_GAME = 50

LIVE_COLOR = "#ff3b30"
DIM_COLOR = "#777777"
LABEL_COLOR = "#999999"
BASE_ON = "#ffd60a"
BASE_OFF = "#3a3a3a"

# Team rows are filled with the team color, scaled so its brightest channel
# is ROW_BRIGHTNESS (keeps white text readable on any team color).
ROW_BRIGHTNESS = 110

# Live football and upcoming games alternate two header texts this often.
HEADER_SWAP_FRAMES = 25

def main(config):
    tz = config.get("$tz", DEFAULT_TZ)
    now = time.now().in_location(tz)

    games = []
    picked = 0
    for key, label, path, params in LEAGUES:
        team_id = config.str(key, "none")
        if team_id in ("", "none"):
            continue
        picked += 1
        game = team_game(label, path, params, team_id, now, tz)
        if game:
            games.append(game)

    if picked == 0:
        return message("Pick your teams in the app settings")

    screens = pick(games)
    if not screens:
        return []

    if len(screens) == 1:
        child = render_game(screens[0], now)
    else:
        frames = []
        for g in screens:
            frames += [render_game(g, now)] * FRAMES_PER_GAME
        child = render.Animation(children = frames)
    return render.Root(delay = FRAME_MS, child = child)

def pick(games):
    """Live games first, then today's finals, then the soonest next game."""
    live = [g for g in games if g["state"] == "live"]
    if live:
        return live
    final = [g for g in games if g["state"] == "final"]
    if final:
        return final
    upcoming = sorted([g for g in games if g["state"] == "next"], key = lambda g: g["start"].unix)
    return upcoming[:1]

# Data

def fetch(url, params, ttl):
    resp = http.get(url, params = params, ttl_seconds = ttl)
    if resp.status_code != 200:
        return None
    return resp.json()

def team_game(label, path, params, team_id, now, tz):
    today = now.format("2006-01-02")

    # Today's scoreboard has live scores and today's finals.
    board_params = dict(params)
    board_params["dates"] = now.format("20060102")
    board = fetch("%s/%s/scoreboard" % (ESPN, path), board_params, SCOREBOARD_CACHE_SECONDS)
    if board:
        for ev in board.get("events", []):
            g = parse_event(label, ev, tz)
            if not g or team_id not in g["team_ids"]:
                continue
            if g["state"] == "live":
                return g
            if g["state"] == "final" and g["start"].format("2006-01-02") == today:
                return g

    # Otherwise the team's next game. ESPN's nextEvent can lag (it keeps
    # pointing at a finished game for a while), so fall back to the first
    # upcoming game on the team's schedule.
    team = fetch("%s/%s/teams/%s" % (ESPN, path, team_id), {}, TEAM_CACHE_SECONDS)
    if not team:
        return None
    g = None
    for ev in team.get("team", {}).get("nextEvent", []):
        candidate = parse_event(label, ev, tz)
        if candidate and candidate["state"] in ("live", "next"):
            g = candidate
            break
    if not g:
        g = next_scheduled(label, path, team_id, now, tz)
    if not g:
        return None

    # nextEvent and schedule entries lack records and team colors; take them
    # from each team's page.
    for side in ("away", "home"):
        if g[side]["record"] and g[side]["bg"] != "#2a2a2a":
            continue
        info = team if g[side]["id"] == team_id else fetch(
            "%s/%s/teams/%s" % (ESPN, path, g[side]["id"]),
            {},
            TEAM_CACHE_SECONDS,
        )
        if not g[side]["record"]:
            g[side]["record"] = team_record(info)
        if g[side]["bg"] == "#2a2a2a":
            t = info.get("team", {}) if info else {}
            g[side]["bg"] = row_color(t.get("color", ""), t.get("alternateColor", ""))
    g["last"] = last_result(path, team_id)
    return g

def next_scheduled(label, path, team_id, now, tz):
    """Soonest upcoming game on the team's schedule."""
    sched = fetch("%s/%s/teams/%s/schedule" % (ESPN, path, team_id), {}, TEAM_CACHE_SECONDS)
    if not sched:
        return None
    best = None
    for ev in sched.get("events", []):
        g = parse_event(label, ev, tz)
        if g and g["state"] == "next" and g["start"] > now and (not best or g["start"] < best["start"]):
            best = g
    return best

def last_result(path, team_id):
    """'W 24-17' for the team's most recent completed game, from its side."""
    sched = fetch("%s/%s/teams/%s/schedule" % (ESPN, path, team_id), {}, TEAM_CACHE_SECONDS)
    if not sched:
        return ""
    result = ""
    for ev in sched.get("events", []):
        comp = ev.get("competitions", [{}])[0]
        if comp.get("status", {}).get("type", {}).get("state") != "post":
            continue
        mine, theirs = None, None
        for c in comp.get("competitors", []):
            if c.get("team", {}).get("id") == team_id:
                mine = c
            else:
                theirs = c
        if not mine or not theirs:
            continue
        a, b = score_text(mine.get("score")), score_text(theirs.get("score"))
        outcome = "W" if mine.get("winner") else ("L" if theirs.get("winner") else "T")
        result = "%s %s-%s" % (outcome, a, b)
    return result

def row_color(primary, alternate):
    """The team's primary color (or its alternate if the primary is black or
    grey), normalized in brightness."""
    for c in (primary, alternate):
        if len(c) != 6:
            continue
        rgb = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
        if max(rgb) - min(rgb) < 40:
            continue
        scale = ROW_BRIGHTNESS / max(rgb)
        digits = "0123456789abcdef"
        out = "#"
        for v in rgb:
            v = min(255, int(v * scale))
            out += digits[v // 16] + digits[v % 16]
        return out
    return "#2a2a2a"

def team_record(info):
    if not info:
        return ""
    items = info.get("team", {}).get("record", {}).get("items", [])
    return items[0].get("summary", "") if items else ""

STATES = {"pre": "next", "in": "live", "post": "final"}

def parse_event(label, ev, tz):
    comps = ev.get("competitions", [])
    if not comps:
        return None
    comp = comps[0]
    status = comp.get("status", {}).get("type", {})
    state = STATES.get(status.get("state", ""))
    if not state:
        return None

    teams = {}
    for c in comp.get("competitors", []):
        t = c.get("team", {})
        teams[c.get("homeAway", "")] = {
            "id": t.get("id", ""),
            "abbr": t.get("abbreviation", "?"),
            "logo": logo_url(t),
            "fit": LOGO_FIT.get(label, {}).get(t.get("id", "")),
            "score": score_text(c.get("score")),
            "record": record_text(c),
            "winner": c.get("winner", False),
            "bg": row_color(t.get("color", ""), t.get("alternateColor", "")),
        }
    if "home" not in teams or "away" not in teams:
        return None

    return {
        "league": label,
        "state": state,
        "start": parse_espn_time(ev["date"]).in_location(tz),
        "time_valid": ev.get("timeValid", True),
        "detail": status.get("shortDetail", ""),
        "away": teams["away"],
        "home": teams["home"],
        "team_ids": [teams["away"]["id"], teams["home"]["id"]],
        "situation": comp.get("situation", {}),
        "last": "",
    }

def parse_espn_time(s):
    # ESPN mostly omits seconds ("2026-11-01T18:00Z") but not always.
    if len(s) == len("2006-01-02T15:04Z"):
        return time.parse_time(s, format = "2006-01-02T15:04Z")
    return time.parse_time(s)

def score_text(score):
    # Scoreboard scores are strings; nextEvent scores are {value, displayValue}.
    if type(score) == "dict":
        return score.get("displayValue", "")
    return str(score) if score != None else ""

def record_text(c):
    # "records" is a list of {summary}; "record" is a list of {displayValue}
    # in some feeds and a plain string (e.g. MLB scoreboards) in others.
    for key in ("records", "record"):
        value = c.get(key)
        if type(value) == "string" and value:
            return value
        if type(value) == "list":
            for r in value:
                text = r.get("summary") or r.get("displayValue")
                if text:
                    return text
    return ""

def logo_url(team):
    href = team.get("logo", "")
    if not href:
        logos = team.get("logos", [])
        href = logos[0].get("href", "") if logos else ""
    return href

def fetch_logo(path):
    """A team logo's original (500px) image. pixlet scales it down when
    rendering; ESPN's own resizer crops and shifts small logos by a pixel or
    so, which threw off the placement."""
    resp = http.get(ESPN_CDN + path, ttl_seconds = LOGO_CACHE_SECONDS)
    return resp.body() if resp.status_code == 200 else None

def logo_image(href):
    """Dark-background variant of a team logo, for teams without a LOGO_FIT."""
    if not href.startswith(ESPN_CDN):
        return None
    path = href[len(ESPN_CDN):]
    candidates = [path.replace("/500/", "/500-dark/"), path] if "/500/" in path else [path]
    for p in candidates:
        src = fetch_logo(p)
        if src:
            return src
    return None

def fitted_logo(t, mode, cell_w, cell_h, default_size, default_lift):
    """A team logo placed in a cell_w x cell_h cell (clipped to it).

    With a LOGO_FIT entry, the logo is sized so its artwork fits the cell
    with a margin and positioned so the artwork (not the image square) is
    centered. Otherwise it's default_size, centered and lifted default_lift.
    """
    fit = t["fit"]
    if fit:
        size, x, y = (fit[1], fit[2], fit[3]) if mode == "stacked" else (fit[4], fit[5], fit[6])
        src = fetch_logo(fit[0])
    else:
        size = default_size
        x, y = (cell_w - size) // 2, (cell_h - size) // 2 - default_lift
        src = logo_image(t["logo"])
    if not src:
        return render.Box(width = cell_w, height = cell_h)
    return place(render.Image(src = src, width = size, height = size), size, cell_w, cell_h, x, y)

def place(child, size, w, h, x, y):
    """child (size x size) with its top-left at (x, y) in a w x h box, which
    clips it. Box centers its child, so padding steers the position; the
    padding keeps the leftover space even so centering is exact."""
    dx = 2 * x - (w - size)
    dy = 2 * y - (h - size)
    pad = (max(0, dx), max(0, dy), max(0, -dx), max(0, -dy))
    return render.Box(width = w, height = h, child = render.Padding(pad = pad, child = child))

# Rendering

def render_game(g, now):
    league = render.Text(g["league"], font = "tom-thumb", color = LABEL_COLOR)
    sit = g["situation"]

    if g["state"] == "live" and "outs" in sit:
        # Baseball: inning, bases diamond, outs.
        status = render.Row(
            cross_align = "center",
            children = [
                render.Text(g["detail"], font = "tom-thumb", color = LIVE_COLOR),
                render.Box(width = 2, height = 1),
                bases(sit),
                render.Box(width = 2, height = 1),
                outs(sit.get("outs", 0)),
            ],
        )
        top = header(league, status)
    elif g["state"] == "live":
        clock = live_text(g["detail"])
        down = sit.get("shortDownDistanceText", "")
        if down:
            spot = sit.get("possessionText", "")
            down_text = live_text(down + (" " + spot if spot else ""), dot = False)
            top = render.Animation(
                children = [header(league, clock)] * HEADER_SWAP_FRAMES +
                           [header(render.Box(width = 1, height = 1), down_text)] * HEADER_SWAP_FRAMES,
            )
        else:
            top = header(league, clock)
    elif g["state"] == "final":
        top = header(league, render.Text(g["detail"].upper(), font = "tom-thumb", color = "#ffffff"), STACKED_HEADER_HEIGHT)
    else:
        start = render.Text(when(g, now, len(g["league"])), font = "tom-thumb", color = "#ffffff")
        if g["last"]:
            room = HEADER_CHARS - len(g["league"]) - 1
            last = "Last " + g["last"] if len("Last " + g["last"]) <= room else g["last"]
            top = render.Animation(
                children = [header(league, start, STACKED_HEADER_HEIGHT)] * HEADER_SWAP_FRAMES +
                           [header(league, render.Text(last, font = "tom-thumb", color = LABEL_COLOR), STACKED_HEADER_HEIGHT)] * HEADER_SWAP_FRAMES,
            )
        else:
            top = header(league, start, STACKED_HEADER_HEIGHT)

    if g["state"] != "live":
        return stacked(g, top)

    return render.Column(
        children = [
            top,
            render.Box(width = WIDTH, height = 1),
            render.Row(
                children = [team_side(g, "away"), center(g), team_side(g, "home")],
            ),
        ],
    )

def stacked(g, top):
    """Header, then a team-color row per team with logos overlaid (clipped to
    their rows)."""
    rows = render.Column(
        children = [top, team_row(g, "away"), render.Box(width = WIDTH, height = STACKED_GAP), team_row(g, "home")],
    )
    overlays = [rows]
    for i, side in enumerate(("away", "home")):
        row_top = STACKED_HEADER_HEIGHT + i * (STACKED_ROW_HEIGHT + STACKED_GAP)

        # The cell is exactly as tall as the row, so nothing bleeds into the
        # gap or the header. Without a fit, ESPN artwork sits about 1px low
        # in its square, so the default lifts it 1px.
        overlays.append(render.Padding(
            pad = (1, row_top, 0, 0),
            child = fitted_logo(g[side], "stacked", ROW_LOGO_SIZE, STACKED_ROW_HEIGHT, ROW_LOGO_SIZE, 1),
        ))
    return render.Stack(children = overlays)

def team_row(g, side):
    t = g[side]
    bg = dim(t["bg"], 0.5) if lost(g, side) else t["bg"]
    text_color = "#bbbbbb" if lost(g, side) else "#ffffff"
    if g["state"] == "next":
        value, font, color = t["record"], "tom-thumb", "#dddddd"
    else:
        value, font = t["score"], "6x10"
        color = DIM_COLOR if lost(g, side) else "#ffffff"
    h = STACKED_ROW_HEIGHT
    return render.Box(
        width = WIDTH,
        height = h,
        color = bg,
        child = render.Padding(
            pad = (1 + ROW_LOGO_SIZE + 3, 0, 2, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                children = [
                    centered(t["abbr"], "tb-8", text_color, text_width(t["abbr"], "tb-8"), h),
                    centered(value, font, color, text_width(value, font), h),
                ],
            ),
        ),
    )

def header(left, right, height = HEADER_HEIGHT):
    return render.Box(
        width = WIDTH,
        height = height,
        child = render.Padding(
            pad = (1, height - 6, 1, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                cross_align = "center",
                children = [left, right],
            ),
        ),
    )

def live_text(text, dot = True):
    children = []
    if dot:
        children += [render.Box(width = 2, height = 2, color = LIVE_COLOR), render.Box(width = 1, height = 1)]
    children.append(render.Text(text, font = "tom-thumb", color = LIVE_COLOR))
    return render.Row(cross_align = "center", children = children)

def bases(sit):
    """2nd on top, 3rd left, 1st right; lit when occupied."""

    def base(on):
        return render.Box(width = 2, height = 2, color = BASE_ON if on else BASE_OFF)

    return render.Stack(
        children = [
            render.Box(width = 6, height = 5),
            render.Padding(pad = (2, 0, 0, 0), child = base(sit.get("onSecond"))),
            render.Padding(pad = (0, 2, 0, 0), child = base(sit.get("onThird"))),
            render.Padding(pad = (4, 2, 0, 0), child = base(sit.get("onFirst"))),
        ],
    )

def outs(n):
    dots = []
    for i in range(3):
        if i:
            dots.append(render.Box(width = 1, height = 1))
        dots.append(render.Box(width = 1, height = 1, color = LIVE_COLOR if i < n else BASE_OFF))
    return render.Row(children = dots)

# Where the letters/digits actually sit in each font's text box:
# (first lit row, lit height). Every font also leaves 1 blank column after
# the last character.
FONT_METRICS = {
    "tom-thumb": (0, 5),
    "tb-8": (1, 6),
    "6x10": (1, 7),
}

def centered(text, font, color, width, height):
    """Text whose visible glyphs are centered in a width x height box (the
    widgets' own centering is off by the fonts' blank rows and column)."""
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
    """Visible width of text (without the trailing blank column)."""
    w, _ = render.Text(text, font = font).size()
    return w - 1

def lost(g, side):
    other = g["home" if side == "away" else "away"]
    return g["state"] == "final" and other["winner"]

def team_side(g, side):
    """Logo with a team-color name tag under it."""
    t = g[side]
    bg = dim(t["bg"], 0.5) if lost(g, side) else t["bg"]
    text_color = "#bbbbbb" if lost(g, side) else "#ffffff"

    has_ball = g["state"] == "live" and g["situation"].get("possession", "") == t["id"]
    tag = render.Box(
        width = SIDE_WIDTH,
        height = TAG_HEIGHT,
        color = bg,
        child = centered(t["abbr"], "tom-thumb", text_color, SIDE_WIDTH, TAG_HEIGHT),
    )
    if has_ball:
        # Possession: yellow dot in the tag's top corner nearest the scores.
        corner = SIDE_WIDTH - 2 if side == "away" else 0
        tag = render.Stack(
            children = [
                tag,
                render.Padding(pad = (corner, 0, 0, 0), child = render.Box(width = 2, height = 2, color = BASE_ON)),
            ],
        )

    return render.Column(
        cross_align = "center",
        children = [
            fitted_logo(t, "live", SIDE_WIDTH, LOGO_SIZE, LOGO_SIZE, 0),
            render.Box(width = SIDE_WIDTH, height = 1),
            tag,
        ],
    )

def center(g):
    """Live scores, each centered in its half of the middle column and level
    with the logos."""
    half = CENTER_WIDTH // 2
    scores = []
    for side in ("away", "home"):
        color = DIM_COLOR if lost(g, side) else "#ffffff"
        scores.append(centered(g[side]["score"], "6x10", color, half, LOGO_SIZE))
    return render.Row(children = scores)

def dim(hex_color, factor):
    h = hex_color.lstrip("#")
    digits = "0123456789abcdef"
    out = "#"
    for k in (0, 2, 4):
        v = int(int(h[k:k + 2], 16) * factor)
        out += digits[v // 16] + digits[v % 16]
    return out

# tom-thumb is 4px per character; the header has 62px for the league label,
# a 1-character gap and the status.
HEADER_CHARS = 15

def when(g, now, league_chars):
    """Start day and time, dropping detail until it fits beside the label."""
    start = g["start"]
    day = start.format("2006-01-02")
    clock = start.format("3pm" if start.minute == 0 else "3:04pm")

    if day == now.format("2006-01-02"):
        options = ["Today " + clock, clock]
    elif start - now < time.parse_duration("144h"):
        options = [start.format("Mon") + " " + clock, start.format("Mon")]
    else:
        options = [start.format("1/2") + " " + clock, start.format("1/2")]
    if not g["time_valid"]:
        options = options[1:]

    room = HEADER_CHARS - league_chars - 1
    for text in options:
        if len(text) <= room:
            return text
    return options[-1]

def message(text):
    return render.Root(
        child = render.WrappedText(text, font = "tb-8", color = "#ff8800"),
    )

# Settings

# BEGIN GENERATED TEAMS (tools/gen_teams.py)
TEAMS = {
    "nfl": [
        ("22", "Arizona Cardinals"),
        ("1", "Atlanta Falcons"),
        ("33", "Baltimore Ravens"),
        ("2", "Buffalo Bills"),
        ("29", "Carolina Panthers"),
        ("3", "Chicago Bears"),
        ("4", "Cincinnati Bengals"),
        ("5", "Cleveland Browns"),
        ("6", "Dallas Cowboys"),
        ("7", "Denver Broncos"),
        ("8", "Detroit Lions"),
        ("9", "Green Bay Packers"),
        ("34", "Houston Texans"),
        ("11", "Indianapolis Colts"),
        ("30", "Jacksonville Jaguars"),
        ("12", "Kansas City Chiefs"),
        ("13", "Las Vegas Raiders"),
        ("24", "Los Angeles Chargers"),
        ("14", "Los Angeles Rams"),
        ("15", "Miami Dolphins"),
        ("16", "Minnesota Vikings"),
        ("17", "New England Patriots"),
        ("18", "New Orleans Saints"),
        ("19", "New York Giants"),
        ("20", "New York Jets"),
        ("21", "Philadelphia Eagles"),
        ("23", "Pittsburgh Steelers"),
        ("25", "San Francisco 49ers"),
        ("26", "Seattle Seahawks"),
        ("27", "Tampa Bay Buccaneers"),
        ("10", "Tennessee Titans"),
        ("28", "Washington Commanders"),
    ],
    "mlb": [
        ("29", "Arizona Diamondbacks"),
        ("11", "Athletics"),
        ("15", "Atlanta Braves"),
        ("1", "Baltimore Orioles"),
        ("2", "Boston Red Sox"),
        ("16", "Chicago Cubs"),
        ("4", "Chicago White Sox"),
        ("17", "Cincinnati Reds"),
        ("5", "Cleveland Guardians"),
        ("27", "Colorado Rockies"),
        ("6", "Detroit Tigers"),
        ("18", "Houston Astros"),
        ("7", "Kansas City Royals"),
        ("3", "Los Angeles Angels"),
        ("19", "Los Angeles Dodgers"),
        ("28", "Miami Marlins"),
        ("8", "Milwaukee Brewers"),
        ("9", "Minnesota Twins"),
        ("21", "New York Mets"),
        ("10", "New York Yankees"),
        ("22", "Philadelphia Phillies"),
        ("23", "Pittsburgh Pirates"),
        ("25", "San Diego Padres"),
        ("26", "San Francisco Giants"),
        ("12", "Seattle Mariners"),
        ("24", "St. Louis Cardinals"),
        ("30", "Tampa Bay Rays"),
        ("13", "Texas Rangers"),
        ("14", "Toronto Blue Jays"),
        ("20", "Washington Nationals"),
    ],
    "nhl": [
        ("25", "Anaheim Ducks"),
        ("1", "Boston Bruins"),
        ("2", "Buffalo Sabres"),
        ("3", "Calgary Flames"),
        ("7", "Carolina Hurricanes"),
        ("4", "Chicago Blackhawks"),
        ("17", "Colorado Avalanche"),
        ("29", "Columbus Blue Jackets"),
        ("9", "Dallas Stars"),
        ("5", "Detroit Red Wings"),
        ("6", "Edmonton Oilers"),
        ("26", "Florida Panthers"),
        ("8", "Los Angeles Kings"),
        ("30", "Minnesota Wild"),
        ("10", "Montreal Canadiens"),
        ("27", "Nashville Predators"),
        ("11", "New Jersey Devils"),
        ("12", "New York Islanders"),
        ("13", "New York Rangers"),
        ("14", "Ottawa Senators"),
        ("15", "Philadelphia Flyers"),
        ("16", "Pittsburgh Penguins"),
        ("18", "San Jose Sharks"),
        ("124292", "Seattle Kraken"),
        ("19", "St. Louis Blues"),
        ("20", "Tampa Bay Lightning"),
        ("21", "Toronto Maple Leafs"),
        ("129764", "Utah Mammoth"),
        ("22", "Vancouver Canucks"),
        ("37", "Vegas Golden Knights"),
        ("23", "Washington Capitals"),
        ("28", "Winnipeg Jets"),
    ],
    "cfb": [
        ("2005", "Air Force Falcons"),
        ("2006", "Akron Zips"),
        ("333", "Alabama Crimson Tide"),
        ("2026", "App State Mountaineers"),
        ("9", "Arizona State Sun Devils"),
        ("12", "Arizona Wildcats"),
        ("8", "Arkansas Razorbacks"),
        ("2032", "Arkansas State Red Wolves"),
        ("349", "Army Black Knights"),
        ("2", "Auburn Tigers"),
        ("252", "BYU Cougars"),
        ("2050", "Ball State Cardinals"),
        ("239", "Baylor Bears"),
        ("68", "Boise State Broncos"),
        ("103", "Boston College Eagles"),
        ("189", "Bowling Green Falcons"),
        ("2084", "Buffalo Bulls"),
        ("25", "California Golden Bears"),
        ("2117", "Central Michigan Chippewas"),
        ("2429", "Charlotte 49ers"),
        ("2132", "Cincinnati Bearcats"),
        ("228", "Clemson Tigers"),
        ("324", "Coastal Carolina Chanticleers"),
        ("38", "Colorado Buffaloes"),
        ("36", "Colorado State Rams"),
        ("48", "Delaware Blue Hens"),
        ("150", "Duke Blue Devils"),
        ("151", "East Carolina Pirates"),
        ("2199", "Eastern Michigan Eagles"),
        ("2226", "Florida Atlantic Owls"),
        ("57", "Florida Gators"),
        ("2229", "Florida International Panthers"),
        ("52", "Florida State Seminoles"),
        ("278", "Fresno State Bulldogs"),
        ("61", "Georgia Bulldogs"),
        ("290", "Georgia Southern Eagles"),
        ("2247", "Georgia State Panthers"),
        ("59", "Georgia Tech Yellow Jackets"),
        ("62", "Hawai'i Rainbow Warriors"),
        ("248", "Houston Cougars"),
        ("356", "Illinois Fighting Illini"),
        ("84", "Indiana Hoosiers"),
        ("2294", "Iowa Hawkeyes"),
        ("66", "Iowa State Cyclones"),
        ("55", "Jacksonville State Gamecocks"),
        ("256", "James Madison Dukes"),
        ("2305", "Kansas Jayhawks"),
        ("2306", "Kansas State Wildcats"),
        ("338", "Kennesaw State Owls"),
        ("2309", "Kent State Golden Flashes"),
        ("96", "Kentucky Wildcats"),
        ("99", "LSU Tigers"),
        ("2335", "Liberty Flames"),
        ("309", "Louisiana Ragin' Cajuns"),
        ("2348", "Louisiana Tech Bulldogs"),
        ("97", "Louisville Cardinals"),
        ("276", "Marshall Thundering Herd"),
        ("120", "Maryland Terrapins"),
        ("113", "Massachusetts Minutemen"),
        ("235", "Memphis Tigers"),
        ("193", "Miami (OH) RedHawks"),
        ("2390", "Miami Hurricanes"),
        ("127", "Michigan State Spartans"),
        ("130", "Michigan Wolverines"),
        ("2393", "Middle Tennessee Blue Raiders"),
        ("135", "Minnesota Golden Gophers"),
        ("344", "Mississippi State Bulldogs"),
        ("2623", "Missouri State Bears"),
        ("142", "Missouri Tigers"),
        ("152", "NC State Wolfpack"),
        ("2426", "Navy Midshipmen"),
        ("158", "Nebraska Cornhuskers"),
        ("2440", "Nevada Wolf Pack"),
        ("167", "New Mexico Lobos"),
        ("166", "New Mexico State Aggies"),
        ("153", "North Carolina Tar Heels"),
        ("2449", "North Dakota State Bison"),
        ("249", "North Texas Mean Green"),
        ("2459", "Northern Illinois Huskies"),
        ("77", "Northwestern Wildcats"),
        ("87", "Notre Dame Fighting Irish"),
        ("195", "Ohio Bobcats"),
        ("194", "Ohio State Buckeyes"),
        ("201", "Oklahoma Sooners"),
        ("197", "Oklahoma State Cowboys"),
        ("295", "Old Dominion Monarchs"),
        ("145", "Ole Miss Rebels"),
        ("2483", "Oregon Ducks"),
        ("204", "Oregon State Beavers"),
        ("213", "Penn State Nittany Lions"),
        ("221", "Pittsburgh Panthers"),
        ("2509", "Purdue Boilermakers"),
        ("242", "Rice Owls"),
        ("164", "Rutgers Scarlet Knights"),
        ("2567", "SMU Mustangs"),
        ("16", "Sacramento State Hornets"),
        ("2534", "Sam Houston Bearkats"),
        ("21", "San Diego State Aztecs"),
        ("23", "San Jos\u00e9 State Spartans"),
        ("6", "South Alabama Jaguars"),
        ("2579", "South Carolina Gamecocks"),
        ("58", "South Florida Bulls"),
        ("2572", "Southern Miss Golden Eagles"),
        ("24", "Stanford Cardinal"),
        ("183", "Syracuse Orange"),
        ("2628", "TCU Horned Frogs"),
        ("218", "Temple Owls"),
        ("2633", "Tennessee Volunteers"),
        ("245", "Texas A&M Aggies"),
        ("251", "Texas Longhorns"),
        ("326", "Texas State Bobcats"),
        ("2641", "Texas Tech Red Raiders"),
        ("2649", "Toledo Rockets"),
        ("2653", "Troy Trojans"),
        ("2655", "Tulane Green Wave"),
        ("202", "Tulsa Golden Hurricane"),
        ("5", "UAB Blazers"),
        ("2116", "UCF Knights"),
        ("26", "UCLA Bruins"),
        ("41", "UConn Huskies"),
        ("2433", "UL Monroe Warhawks"),
        ("2439", "UNLV Rebels"),
        ("30", "USC Trojans"),
        ("2638", "UTEP Miners"),
        ("2636", "UTSA Roadrunners"),
        ("328", "Utah State Aggies"),
        ("254", "Utah Utes"),
        ("238", "Vanderbilt Commodores"),
        ("258", "Virginia Cavaliers"),
        ("259", "Virginia Tech Hokies"),
        ("154", "Wake Forest Demon Deacons"),
        ("264", "Washington Huskies"),
        ("265", "Washington State Cougars"),
        ("277", "West Virginia Mountaineers"),
        ("98", "Western Kentucky Hilltoppers"),
        ("2711", "Western Michigan Broncos"),
        ("275", "Wisconsin Badgers"),
        ("2751", "Wyoming Cowboys"),
    ],
    "nwsl": [
        ("21422", "Angel City FC"),
        ("22187", "Bay FC"),
        ("131562", "Boston Legacy FC"),
        ("15360", "Chicago Stars FC"),
        ("131563", "Denver Summit FC"),
        ("15364", "Gotham FC"),
        ("17346", "Houston Dash"),
        ("20907", "Kansas City Current"),
        ("15366", "North Carolina Courage"),
        ("18206", "Orlando Pride"),
        ("15362", "Portland Thorns FC"),
        ("20905", "Racing Louisville FC"),
        ("21423", "San Diego Wave FC"),
        ("15363", "Seattle Reign FC"),
        ("19141", "Utah Royals"),
        ("15365", "Washington Spirit"),
    ],
}

# Per-team logo fit, keyed by league label and team id:
# (path, stacked size, x, y, live size, x, y).
LOGO_FIT = {
    "NFL": {
        "1": ("/i/teamlogos/nfl/500-dark/atl.png", 12, 1, 0, 16, 0, 0),
        "2": ("/i/teamlogos/nfl/500-dark/buf.png", 14, -1, -1, 16, 0, 0),
        "3": ("/i/teamlogos/nfl/500-dark/chi.png", 10, 2, 1, 16, 1, 0),
        "4": ("/i/teamlogos/nfl/500-dark/cin.png", 14, -1, -1, 16, 0, 0),
        "5": ("/i/teamlogos/nfl/500-dark/cle.png", 14, 0, -1, 16, 1, 0),
        "6": ("/i/teamlogos/nfl/500-dark/dal.png", 12, 1, 0, 16, 1, -1),
        "7": ("/i/teamlogos/nfl/500-dark/den.png", 14, -1, -1, 16, 1, 1),
        "8": ("/i/teamlogos/nfl/500-dark/det.png", 14, -1, -1, 16, 0, 0),
        "9": ("/i/teamlogos/nfl/500-dark/gb.png", 14, 0, -1, 16, 1, 0),
        "10": ("/i/teamlogos/nfl/500-dark/ten.png", 10, 2, 1, 14, 2, 1),
        "11": ("/i/teamlogos/nfl/500-dark/ind.png", 10, 2, 1, 14, 2, 1),
        "12": ("/i/teamlogos/nfl/500-dark/kc.png", 14, 1, -1, 16, 1, 0),
        "13": ("/i/teamlogos/nfl/500-dark/lv.png", 10, 2, 1, 15, 1, 0),
        "14": ("/i/teamlogos/nfl/500-dark/lar.png", 14, -1, -1, 16, 0, 0),
        "15": ("/i/teamlogos/nfl/500-dark/mia.png", 14, -1, -1, 16, 1, 0),
        "16": ("/i/teamlogos/nfl/500-dark/min.png", 11, 2, 0, 16, 1, 0),
        "17": ("/i/teamlogos/nfl/500-dark/ne.png", 14, -1, -1, 16, 1, 0),
        "18": ("/i/teamlogos/nfl/500-dark/no.png", 12, 1, 0, 16, 1, 0),
        "19": ("/i/teamlogos/nfl/500-dark/nyg.png", 14, 0, -1, 16, 1, 0),
        "20": ("/i/teamlogos/nfl/500-dark/nyj.png", 14, 0, -1, 16, 1, -1),
        "21": ("/i/teamlogos/nfl/500-dark/phi.png", 14, 1, -1, 16, 1, 0),
        "22": ("/i/teamlogos/nfl/500-dark/ari.png", 12, 1, 0, 16, 1, 0),
        "23": ("/i/teamlogos/nfl/500-dark/pit.png", 10, 2, 1, 14, 2, 1),
        "24": ("/i/teamlogos/nfl/500-dark/lac.png", 14, 0, -1, 16, 1, 0),
        "25": ("/i/teamlogos/nfl/500-dark/sf.png", 14, 0, -1, 16, 1, 0),
        "26": ("/i/teamlogos/nfl/500-dark/sea.png", 14, 0, -1, 16, 1, 0),
        "27": ("/i/teamlogos/nfl/500-dark/tb.png", 13, 1, -1, 16, 1, -1),
        "28": ("/i/teamlogos/nfl/500-dark/wsh.png", 14, 0, -1, 16, 1, 0),
        "29": ("/i/teamlogos/nfl/500-dark/car.png", 14, 0, -1, 16, 1, 0),
        "30": ("/i/teamlogos/nfl/500-dark/jax.png", 14, 0, -1, 16, 1, 0),
        "33": ("/i/teamlogos/nfl/500-dark/bal.png", 14, -1, -1, 16, 0, 1),
        "34": ("/i/teamlogos/nfl/500-dark/hou.png", 12, 1, 0, 16, 1, 0),
    },
    "MLB": {
        "1": ("/i/teamlogos/mlb/500-dark/bal.png", 12, 1, 0, 16, 1, 0),
        "2": ("/i/teamlogos/mlb/500-dark/bos.png", 10, 2, 1, 14, 2, 1),
        "3": ("/i/teamlogos/mlb/500-dark/laa.png", 10, 2, 1, 14, 2, 1),
        "4": ("/i/teamlogos/mlb/500-dark/chw.png", 10, 2, 1, 14, 2, 1),
        "5": ("/i/teamlogos/mlb/500-dark/cle.png", 10, 2, 1, 14, 2, 1),
        "6": ("/i/teamlogos/mlb/500-dark/det.png", 12, 1, 0, 16, 1, 0),
        "7": ("/i/teamlogos/mlb/500-dark/kc.png", 10, 2, 1, 14, 1, 1),
        "8": ("/i/teamlogos/mlb/500-dark/mil.png", 10, 2, 1, 14, 2, 1),
        "9": ("/i/teamlogos/mlb/500-dark/min.png", 10, 2, 1, 14, 2, 1),
        "10": ("/i/teamlogos/mlb/500-dark/nyy.png", 12, 1, 0, 16, 1, 0),
        "11": ("/i/teamlogos/mlb/500-dark/ath.png", 14, -1, -1, 16, 0, 0),
        "12": ("/i/teamlogos/mlb/500-dark/sea.png", 10, 2, 1, 14, 2, 1),
        "13": ("/i/teamlogos/mlb/500-dark/tex.png", 10, 2, 1, 14, 2, 1),
        "14": ("/i/teamlogos/mlb/500-dark/tor.png", 14, 0, -1, 16, 1, 0),
        "15": ("/i/teamlogos/mlb/500-dark/atl.png", 12, 1, 0, 16, 1, 0),
        "16": ("/i/teamlogos/mlb/500-dark/chc.png", 10, 2, 1, 14, 2, 1),
        "17": ("/i/teamlogos/mlb/500-dark/cin.png", 14, 0, -1, 16, 1, 0),
        "18": ("/i/teamlogos/mlb/500-dark/hou.png", 10, 2, 1, 14, 2, 1),
        "19": ("/i/teamlogos/mlb/500-dark/lad.png", 10, 2, 1, 14, 2, 1),
        "20": ("/i/teamlogos/mlb/500-dark/wsh.png", 10, 2, 1, 14, 2, 1),
        "21": ("/i/teamlogos/mlb/500-dark/nym.png", 10, 2, 1, 14, 2, 1),
        "22": ("/i/teamlogos/mlb/500-dark/phi.png", 10, 2, 1, 14, 2, 1),
        "23": ("/i/teamlogos/mlb/500-dark/pit.png", 11, 2, 0, 15, 1, 0),
        "24": ("/i/teamlogos/mlb/500-dark/stl.png", 10, 2, 1, 14, 2, 1),
        "25": ("/i/teamlogos/mlb/500-dark/sd.png", 10, 2, 1, 14, 2, 1),
        "26": ("/i/teamlogos/mlb/500-dark/sf.png", 10, 3, 1, 14, 2, 1),
        "27": ("/i/teamlogos/mlb/500-dark/col.png", 10, 2, 1, 14, 2, 1),
        "28": ("/i/teamlogos/mlb/500-dark/mia.png", 12, 1, 0, 16, 1, 0),
        "29": ("/i/teamlogos/mlb/500-dark/ari.png", 12, 1, 0, 16, 1, 0),
        "30": ("/i/teamlogos/mlb/500-dark/tb.png", 12, 2, 0, 16, 1, 0),
    },
    "NHL": {
        "1": ("/i/teamlogos/nhl/500-dark/bos.png", 10, 2, 1, 14, 2, 1),
        "2": ("/i/teamlogos/nhl/500-dark/buf.png", 10, 2, 1, 14, 2, 1),
        "3": ("/i/teamlogos/nhl/500-dark/cgy.png", 12, 1, 0, 16, 0, 1),
        "4": ("/i/teamlogos/nhl/500-dark/chi.png", 12, 1, 0, 16, 1, 0),
        "5": ("/i/teamlogos/nhl/500-dark/det.png", 14, 0, -1, 16, 1, 0),
        "6": ("/i/teamlogos/nhl/500-dark/edm.png", 10, 2, 1, 14, 2, 1),
        "7": ("/i/teamlogos/nhl/500-dark/car.png", 14, 0, -1, 16, 1, 0),
        "8": ("/i/teamlogos/nhl/500-dark/la.png", 14, -1, -1, 16, 1, 0),
        "9": ("/i/teamlogos/nhl/500-dark/dal.png", 14, 0, -1, 16, 1, 0),
        "10": ("/i/teamlogos/nhl/500-dark/mtl.png", 14, 1, -1, 16, 1, 0),
        "11": ("/i/teamlogos/nhl/500-dark/nj.png", 11, 2, 1, 15, 1, 1),
        "12": ("/i/teamlogos/nhl/500-dark/nyi.png", 10, 2, 1, 16, 1, 0),
        "13": ("/i/teamlogos/nhl/500-dark/nyr.png", 11, 2, 1, 16, 1, 0),
        "14": ("/i/teamlogos/nhl/500-dark/ott.png", 14, -1, -1, 16, 0, 0),
        "15": ("/i/teamlogos/nhl/500-dark/phi.png", 14, 0, -1, 16, 1, 0),
        "16": ("/i/teamlogos/nhl/500-dark/pit.png", 12, 1, 0, 16, 1, 0),
        "17": ("/i/teamlogos/nhl/500-dark/col.png", 13, 0, -1, 16, 0, 0),
        "18": ("/i/teamlogos/nhl/500-dark/sj.png", 13, 0, -1, 16, 0, 0),
        "19": ("/i/teamlogos/nhl/500-dark/stl.png", 14, 0, -1, 16, 1, 0),
        "20": ("/i/teamlogos/nhl/500-dark/tb.png", 13, 1, 0, 16, 1, 1),
        "21": ("/i/teamlogos/nhl/500-dark/tor.png", 12, 1, 0, 16, 1, 0),
        "22": ("/i/teamlogos/nhl/500-dark/van.png", 10, 2, 1, 16, 1, 0),
        "23": ("/i/teamlogos/nhl/500-dark/wsh.png", 14, 1, -1, 16, 1, 0),
        "25": ("/i/teamlogos/nhl/500-dark/ana.png", 12, 1, 0, 16, 1, 1),
        "26": ("/i/teamlogos/nhl/500-dark/fla.png", 10, 2, 1, 14, 2, 2),
        "27": ("/i/teamlogos/nhl/500-dark/nsh.png", 14, -1, -1, 16, 1, 0),
        "28": ("/i/teamlogos/nhl/500-dark/wpg.png", 10, 2, 1, 14, 2, 1),
        "29": ("/i/teamlogos/nhl/500-dark/cbj.png", 14, 1, -1, 16, 1, 0),
        "30": ("/i/teamlogos/nhl/500-dark/min.png", 14, 1, -1, 16, 1, 0),
        "37": ("/i/teamlogos/nhl/500-dark/vgk.png", 10, 2, 1, 16, 1, 0),
        "124292": ("/i/teamlogos/nhl/500-dark/sea.png", 10, 2, 1, 16, 1, 0),
        "129764": ("/i/teamlogos/nhl/500-dark/utah.png", 14, -1, -1, 16, 0, 0),
    },
    "CFB": {
        "2": ("/i/teamlogos/ncaa/500-dark/2.png", 12, 1, 0, 16, 1, 0),
        "5": ("/i/teamlogos/ncaa/500-dark/5.png", 13, 1, 0, 16, 1, 0),
        "6": ("/i/teamlogos/ncaa/500-dark/6.png", 14, 0, -1, 16, 1, 1),
        "8": ("/i/teamlogos/ncaa/500-dark/8.png", 14, 0, -1, 16, 1, 0),
        "9": ("/i/teamlogos/ncaa/500-dark/9.png", 12, 1, 1, 16, 1, 1),
        "12": ("/i/teamlogos/ncaa/500-dark/12.png", 12, 1, 0, 16, 1, 0),
        "16": ("/i/teamlogos/ncaa/500-dark/16.png", 11, 2, 1, 15, 1, 1),
        "21": ("/i/teamlogos/ncaa/500-dark/21.png", 14, 1, -1, 16, 1, 0),
        "23": ("/i/teamlogos/ncaa/500-dark/23.png", 10, 2, 1, 15, 1, 1),
        "24": ("/i/teamlogos/ncaa/500-dark/24.png", 10, 2, 1, 14, 2, 1),
        "25": ("/i/teamlogos/ncaa/500-dark/25.png", 14, -1, -1, 16, 0, 0),
        "26": ("/i/teamlogos/ncaa/500-dark/26.png", 14, 1, -1, 16, 1, 0),
        "30": ("/i/teamlogos/ncaa/500-dark/30.png", 10, 2, 1, 14, 2, 1),
        "36": ("/i/teamlogos/ncaa/500-dark/36.png", 10, 2, 1, 14, 2, 1),
        "38": ("/i/teamlogos/ncaa/500-dark/38.png", 14, 0, -1, 16, 1, 1),
        "41": ("/i/teamlogos/ncaa/500-dark/41.png", 10, 2, 1, 15, 1, 0),
        "48": ("/i/teamlogos/ncaa/500-dark/48.png", 14, 0, -1, 16, 1, 0),
        "52": ("/i/teamlogos/ncaa/500-dark/52.png", 10, 2, 1, 14, 2, 1),
        "55": ("/i/teamlogos/ncaa/500-dark/55.png", 14, 0, -1, 16, 1, 0),
        "57": ("/i/teamlogos/ncaa/500-dark/57.png", 14, 0, -1, 16, 1, 0),
        "58": ("/i/teamlogos/ncaa/500-dark/58.png", 14, 0, -1, 16, 1, 0),
        "59": ("/i/teamlogos/ncaa/500-dark/59.png", 14, 0, -1, 16, 1, 0),
        "61": ("/i/teamlogos/ncaa/500-dark/61.png", 14, 0, -1, 16, 1, 0),
        "62": ("/i/teamlogos/ncaa/500-dark/62.png", 14, 0, -1, 16, 1, 0),
        "66": ("/i/teamlogos/ncaa/500-dark/66.png", 14, 0, -1, 16, 1, 0),
        "68": ("/i/teamlogos/ncaa/500-dark/68.png", 12, 1, 0, 16, 0, 0),
        "77": ("/i/teamlogos/ncaa/500-dark/77.png", 10, 2, 1, 14, 2, 1),
        "84": ("/i/teamlogos/ncaa/500-dark/84.png", 10, 2, 1, 14, 2, 1),
        "87": ("/i/teamlogos/ncaa/500-dark/87.png", 12, 1, 0, 16, 1, 0),
        "96": ("/i/teamlogos/ncaa/500-dark/96.png", 12, 1, 0, 16, 1, 0),
        "97": ("/i/teamlogos/ncaa/500-dark/97.png", 12, 1, 0, 16, 1, 0),
        "98": ("/i/teamlogos/ncaa/500-dark/98.png", 14, 1, -1, 16, 1, 0),
        "99": ("/i/teamlogos/ncaa/500-dark/99.png", 14, 0, -1, 16, 1, 0),
        "103": ("/i/teamlogos/ncaa/500-dark/103.png", 12, 1, 0, 16, 1, 0),
        "113": ("/i/teamlogos/ncaa/500-dark/113.png", 12, 1, 0, 16, 1, 0),
        "120": ("/i/teamlogos/ncaa/500-dark/120.png", 10, 2, 1, 14, 2, 1),
        "127": ("/i/teamlogos/ncaa/500-dark/127.png", 10, 2, 1, 15, 2, 1),
        "130": ("/i/teamlogos/ncaa/500-dark/130.png", 14, 0, -1, 16, 1, 0),
        "135": ("/i/teamlogos/ncaa/500-dark/135.png", 14, 0, -1, 16, 1, 0),
        "142": ("/i/teamlogos/ncaa/500-dark/142.png", 14, 0, -1, 16, 1, 0),
        "145": ("/i/teamlogos/ncaa/500-dark/145.png", 12, 1, 0, 16, 1, 0),
        "150": ("/i/teamlogos/ncaa/500-dark/150.png", 12, 1, 0, 16, 0, 0),
        "151": ("/i/teamlogos/ncaa/500-dark/151.png", 10, 2, 1, 14, 2, 1),
        "152": ("/i/teamlogos/ncaa/500-dark/152.png", 10, 2, 1, 16, 1, 0),
        "153": ("/i/teamlogos/ncaa/500-dark/153.png", 14, 1, -1, 16, 1, 0),
        "154": ("/i/teamlogos/ncaa/500-dark/154.png", 14, -1, -1, 16, 0, 0),
        "158": ("/i/teamlogos/ncaa/500-dark/158.png", 10, 2, 1, 14, 2, 1),
        "164": ("/i/teamlogos/ncaa/500-dark/164.png", 12, 1, 0, 16, 1, 0),
        "166": ("/i/teamlogos/ncaa/500-dark/166.png", 14, 0, -1, 16, 0, 0),
        "167": ("/i/teamlogos/ncaa/500-dark/167.png", 10, 2, 2, 15, 1, 1),
        "183": ("/i/teamlogos/ncaa/500-dark/183.png", 10, 2, 1, 14, 2, 1),
        "189": ("/i/teamlogos/ncaa/500-dark/189.png", 12, 1, 0, 16, 0, 0),
        "193": ("/i/teamlogos/ncaa/500-dark/193.png", 14, 0, -1, 16, 1, 0),
        "194": ("/i/teamlogos/ncaa/500-dark/194.png", 10, 2, 1, 15, 1, 1),
        "195": ("/i/teamlogos/ncaa/500-dark/195.png", 14, 0, -1, 16, 1, 0),
        "197": ("/i/teamlogos/ncaa/500-dark/197.png", 14, 0, -1, 16, 1, 0),
        "201": ("/i/teamlogos/ncaa/500-dark/201.png", 10, 2, 1, 14, 2, 1),
        "202": ("/i/teamlogos/ncaa/500-dark/202.png", 14, 0, -1, 16, 1, 0),
        "204": ("/i/teamlogos/ncaa/500-dark/204.png", 14, -1, -1, 16, 1, 0),
        "213": ("/i/teamlogos/ncaa/500-dark/213.png", 14, 0, -1, 16, 1, 0),
        "218": ("/i/teamlogos/ncaa/500-dark/218.png", 10, 2, 1, 14, 2, 1),
        "221": ("/i/teamlogos/ncaa/500-dark/221.png", 14, 0, -1, 16, 1, 0),
        "228": ("/i/teamlogos/ncaa/500-dark/228.png", 12, 1, 0, 16, 1, 0),
        "235": ("/i/teamlogos/ncaa/500-dark/235.png", 12, 1, 0, 16, 1, 0),
        "238": ("/i/teamlogos/ncaa/500-dark/238.png", 14, 0, -1, 16, 1, 0),
        "239": ("/i/teamlogos/ncaa/500-dark/239.png", 10, 2, 1, 14, 2, 1),
        "242": ("/i/teamlogos/ncaa/500-dark/242.png", 10, 2, 1, 16, 1, 0),
        "245": ("/i/teamlogos/ncaa/500-dark/245.png", 12, 1, 0, 16, 1, 0),
        "248": ("/i/teamlogos/ncaa/500-dark/248.png", 10, 2, 1, 16, 1, 0),
        "249": ("/i/teamlogos/ncaa/500-dark/249.png", 10, 2, 1, 14, 2, 1),
        "251": ("/i/teamlogos/ncaa/500-dark/251.png", 14, 0, -1, 16, 1, 0),
        "252": ("/i/teamlogos/ncaa/500-dark/252.png", 14, 0, -1, 16, 1, 0),
        "254": ("/i/teamlogos/ncaa/500-dark/254.png", 12, 1, 0, 16, 1, 0),
        "256": ("/i/teamlogos/ncaa/500-dark/256.png", 14, 0, -1, 16, 1, 0),
        "258": ("/i/teamlogos/ncaa/500-dark/258.png", 14, 0, -1, 16, 1, 0),
        "259": ("/i/teamlogos/ncaa/500-dark/259.png", 14, 0, -1, 16, 1, 0),
        "264": ("/i/teamlogos/ncaa/500-dark/264.png", 14, 0, -1, 16, 1, 0),
        "265": ("/i/teamlogos/ncaa/500-dark/265.png", 10, 2, 1, 16, 0, 0),
        "275": ("/i/teamlogos/ncaa/500-dark/275.png", 11, 2, 1, 15, 1, 1),
        "276": ("/i/teamlogos/ncaa/500-dark/276.png", 14, 0, -1, 16, 1, 0),
        "277": ("/i/teamlogos/ncaa/500-dark/277.png", 12, 1, 0, 16, 1, 0),
        "278": ("/i/teamlogos/ncaa/500-dark/278.png", 14, 0, -1, 16, 1, 0),
        "290": ("/i/teamlogos/ncaa/500-dark/290.png", 14, 0, -1, 16, 1, 1),
        "295": ("/i/teamlogos/ncaa/500-dark/295.png", 12, 1, 0, 16, 1, 0),
        "309": ("/i/teamlogos/ncaa/500-dark/309.png", 14, 1, -2, 16, 1, 0),
        "324": ("/i/teamlogos/ncaa/500-dark/324.png", 10, 2, 1, 14, 2, 1),
        "326": ("/i/teamlogos/ncaa/500-dark/326.png", 11, 2, 0, 15, 1, 0),
        "328": ("/i/teamlogos/ncaa/500-dark/328.png", 14, 1, -1, 16, 1, 0),
        "333": ("/i/teamlogos/ncaa/500-dark/333.png", 10, 2, 1, 14, 2, 1),
        "338": ("/i/teamlogos/ncaa/500-dark/338.png", 10, 3, 1, 16, 1, 0),
        "344": ("/i/teamlogos/ncaa/500-dark/344.png", 14, -1, -1, 16, 0, 0),
        "349": ("/i/teamlogos/ncaa/500-dark/349.png", 10, 2, 1, 14, 2, 1),
        "356": ("/i/teamlogos/ncaa/500-dark/356.png", 10, 2, 1, 14, 2, 1),
        "2005": ("/i/teamlogos/ncaa/500-dark/2005.png", 10, 2, 1, 14, 2, 1),
        "2006": ("/i/teamlogos/ncaa/500-dark/2006.png", 14, 0, -1, 16, 1, 0),
        "2026": ("/i/teamlogos/ncaa/500-dark/2026.png", 10, 2, 1, 14, 2, 1),
        "2032": ("/i/teamlogos/ncaa/500-dark/2032.png", 10, 2, 1, 15, 1, 0),
        "2050": ("/i/teamlogos/ncaa/500-dark/2050.png", 11, 2, 0, 16, 1, 0),
        "2084": ("/i/teamlogos/ncaa/500-dark/2084.png", 11, 2, 0, 16, 1, 0),
        "2116": ("/i/teamlogos/ncaa/500-dark/2116.png", 14, -1, -1, 16, 1, 0),
        "2117": ("/i/teamlogos/ncaa/500-dark/2117.png", 14, 0, -1, 16, 1, 1),
        "2132": ("/i/teamlogos/ncaa/500-dark/2132.png", 11, 2, 0, 15, 2, 0),
        "2199": ("/i/teamlogos/ncaa/500-dark/2199.png", 10, 2, 1, 14, 2, 1),
        "2226": ("/i/teamlogos/ncaa/500-dark/2226.png", 14, 0, -1, 16, 1, 0),
        "2229": ("/i/teamlogos/ncaa/500-dark/2229.png", 10, 2, 1, 14, 2, 1),
        "2247": ("/i/teamlogos/ncaa/500-dark/2247.png", 14, 0, -1, 16, 1, 0),
        "2294": ("/i/teamlogos/ncaa/500-dark/2294.png", 14, 0, -1, 16, 0, 0),
        "2305": ("/i/teamlogos/ncaa/500-dark/2305.png", 12, 1, 0, 16, 0, 0),
        "2306": ("/i/teamlogos/ncaa/500-dark/2306.png", 14, 0, -1, 16, 1, 0),
        "2309": ("/i/teamlogos/ncaa/500-dark/2309.png", 14, 0, -1, 16, 1, 1),
        "2335": ("/i/teamlogos/ncaa/500-dark/2335.png", 12, 1, 0, 16, 0, 0),
        "2348": ("/i/teamlogos/ncaa/500-dark/2348.png", 12, 2, 0, 16, 1, 0),
        "2390": ("/i/teamlogos/ncaa/500-dark/2390.png", 14, 0, -1, 16, 1, 0),
        "2393": ("/i/teamlogos/ncaa/500-dark/2393.png", 14, 1, -1, 16, 1, 1),
        "2426": ("/i/teamlogos/ncaa/500-dark/2426.png", 11, 2, 0, 15, 1, 0),
        "2429": ("/i/teamlogos/ncaa/500-dark/2429.png", 10, 2, 1, 14, 2, 1),
        "2433": ("/i/teamlogos/ncaa/500-dark/2433.png", 14, 0, -2, 16, 1, 0),
        "2439": ("/i/teamlogos/ncaa/500-dark/2439.png", 14, 0, -1, 16, 1, 0),
        "2440": ("/i/teamlogos/ncaa/500-dark/2440.png", 14, 0, -1, 16, 1, 1),
        "2449": ("/i/teamlogos/ncaa/500-dark/2449.png", 14, -1, -1, 16, 0, 0),
        "2459": ("/i/teamlogos/ncaa/500-dark/2459.png", 11, 2, 0, 16, 0, 0),
        "2483": ("/i/teamlogos/ncaa/500-dark/2483.png", 12, 1, 0, 16, 1, 0),
        "2509": ("/i/teamlogos/ncaa/500-dark/2509.png", 14, -1, -1, 16, 0, 0),
        "2534": ("/i/teamlogos/ncaa/500-dark/2534.png", 12, 1, 0, 16, 1, 0),
        "2567": ("/i/teamlogos/ncaa/500-dark/2567.png", 14, 0, -1, 16, 1, 0),
        "2572": ("/i/teamlogos/ncaa/500-dark/2572.png", 14, -1, -1, 16, 0, 0),
        "2579": ("/i/teamlogos/ncaa/500-dark/2579.png", 10, 2, 1, 14, 2, 1),
        "2623": ("/i/teamlogos/ncaa/500-dark/2623.png", 12, 1, 0, 16, 1, 1),
        "2628": ("/i/teamlogos/ncaa/500-dark/2628.png", 14, 0, -1, 16, 1, 1),
        "2633": ("/i/teamlogos/ncaa/500-dark/2633.png", 10, 2, 1, 14, 2, 1),
        "2636": ("/i/teamlogos/ncaa/500-dark/2636.png", 14, 0, -1, 16, 1, 1),
        "2638": ("/i/teamlogos/ncaa/500-dark/2638.png", 14, 0, -1, 16, 1, 1),
        "2641": ("/i/teamlogos/ncaa/500-dark/2641.png", 10, 2, 1, 14, 2, 1),
        "2649": ("/i/teamlogos/ncaa/500-dark/2649.png", 14, -1, -1, 16, 0, 1),
        "2653": ("/i/teamlogos/ncaa/500-dark/2653.png", 10, 2, 2, 15, 1, 1),
        "2655": ("/i/teamlogos/ncaa/500-dark/2655.png", 14, 0, -1, 16, 1, 1),
        "2711": ("/i/teamlogos/ncaa/500-dark/2711.png", 14, -1, -1, 16, 0, 0),
        "2751": ("/i/teamlogos/ncaa/500-dark/2751.png", 11, 2, 1, 15, 1, 1),
    },
    "NWSL": {
        "15360": ("/i/teamlogos/soccer/500-dark/15360.png", 10, 2, 1, 14, 2, 1),
        "15362": ("/i/teamlogos/soccer/500-dark/15362.png", 10, 2, 1, 14, 2, 1),
        "15363": ("/i/teamlogos/soccer/500-dark/15363.png", 11, 2, 0, 16, 1, 0),
        "15364": ("/i/teamlogos/soccer/500-dark/15364.png", 12, 1, -1, 16, 1, 0),
        "15365": ("/i/teamlogos/soccer/500-dark/15365.png", 12, 1, 0, 16, 1, 0),
        "15366": ("/i/teamlogos/soccer/500-dark/15366.png", 10, 2, 1, 16, 1, 0),
        "17346": ("/i/teamlogos/soccer/500-dark/17346.png", 10, 2, 1, 16, 1, 0),
        "18206": ("/i/teamlogos/soccer/500-dark/18206.png", 10, 2, 1, 14, 2, 1),
        "19141": ("/i/teamlogos/soccer/500-dark/19141.png", 10, 2, 1, 15, 1, 0),
        "20905": ("/i/teamlogos/soccer/500-dark/20905.png", 10, 2, 1, 14, 2, 1),
        "20907": ("/i/teamlogos/soccer/500-dark/20907.png", 10, 2, 1, 14, 2, 1),
        "21422": ("/i/teamlogos/soccer/500-dark/21422.png", 10, 2, 1, 16, 1, 0),
        "21423": ("/i/teamlogos/soccer/500-dark/21423.png", 10, 2, 1, 14, 2, 2),
        "22187": ("/i/teamlogos/soccer/500-dark/22187.png", 10, 2, 1, 14, 2, 1),
        "131562": ("/i/teamlogos/soccer/500-dark/131562.png", 10, 2, 1, 15, 1, 1),
        "131563": ("/i/teamlogos/soccer/500-dark/131563.png", 10, 2, 1, 14, 2, 2),
    },
}
# END GENERATED TEAMS

def team_options(key):
    return [schema.Option(display = "None", value = "none")] + [
        schema.Option(display = name, value = team_id)
        for team_id, name in TEAMS.get(key, [])
    ]

def get_schema():
    fields = []
    for key, label, _, _ in LEAGUES:
        fields.append(
            schema.Dropdown(
                id = key,
                name = label,
                desc = "Favorite %s team." % label,
                icon = "trophy",
                default = "none",
                options = team_options(key),
            ),
        )
    return schema.Schema(version = "1", fields = fields)
