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

# Finals and upcoming games use stacked team-color rows under a slimmer
# header. Row logos are a little taller than the rows and overlap the edges.
STACKED_HEADER_HEIGHT = 6
STACKED_ROW_HEIGHT = 13
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

    # Otherwise the team's next game.
    team = fetch("%s/%s/teams/%s" % (ESPN, path, team_id), {}, TEAM_CACHE_SECONDS)
    if not team:
        return None
    for ev in team.get("team", {}).get("nextEvent", []):
        g = parse_event(label, ev, tz)
        if g and g["state"] in ("live", "next"):
            # nextEvent has no records; take them from each team's page.
            for side in ("away", "home"):
                if not g[side]["record"]:
                    info = team if g[side]["id"] == team_id else fetch(
                        "%s/%s/teams/%s" % (ESPN, path, g[side]["id"]),
                        {},
                        TEAM_CACHE_SECONDS,
                    )
                    g[side]["record"] = team_record(info)
                if g[side]["bg"] == "#2a2a2a":
                    info = team if g[side]["id"] == team_id else fetch(
                        "%s/%s/teams/%s" % (ESPN, path, g[side]["id"]),
                        {},
                        TEAM_CACHE_SECONDS,
                    )
                    t = info.get("team", {}) if info else {}
                    g[side]["bg"] = row_color(t.get("color", ""), t.get("alternateColor", ""))
            g["last"] = last_result(path, team_id)
            return g
    return None

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

def logo_image(href, size = LOGO_SIZE):
    """Dark-background variant of a team logo at LOGO_SIZE, via ESPN's resizer."""
    if not href.startswith(ESPN_CDN):
        return None
    path = href[len(ESPN_CDN):]
    candidates = [path.replace("/500/", "/500-dark/"), path] if "/500/" in path else [path]
    for p in candidates:
        resp = http.get(
            ESPN_CDN + "/combiner/i",
            params = {"img": p, "w": str(size), "h": str(size)},
            ttl_seconds = LOGO_CACHE_SECONDS,
        )
        if resp.status_code == 200:
            return resp.body()
    return None

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
    """Header, then a team-color row per team with logos overlaid so they can
    be taller than the rows."""
    rows = render.Column(children = [top, team_row(g, "away"), team_row(g, "home")])
    overlays = [rows]
    for i, side in enumerate(("away", "home")):
        logo = logo_image(g[side]["logo"], ROW_LOGO_SIZE)
        if not logo:
            continue
        row_top = STACKED_HEADER_HEIGHT + i * STACKED_ROW_HEIGHT

        # ESPN's logo artwork sits about 1px low in its square, so lift it
        # to line up with the team name.
        y = row_top + (STACKED_ROW_HEIGHT - ROW_LOGO_SIZE) // 2 - 1
        overlays.append(render.Padding(
            pad = (1, max(0, y), 0, 0),
            child = render.Image(src = logo, width = ROW_LOGO_SIZE, height = ROW_LOGO_SIZE),
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

    logo = logo_image(t["logo"])
    logo_box = render.Box(width = LOGO_SIZE, height = LOGO_SIZE)
    if logo:
        logo_box = render.Image(src = logo, width = LOGO_SIZE, height = LOGO_SIZE)

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
            render.Box(width = SIDE_WIDTH, height = LOGO_SIZE, child = logo_box),
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
