#!/usr/bin/env python3
"""
Regenerates the TEAMS and LOGO_FIT tables in ../gameday.star from ESPN.

    pip install pillow      # and pixlet on PATH
    python3 tools/gen_teams.py

TEAMS feeds the settings dropdowns. College football is limited to FBS
(taken from the FBS standings, since the teams endpoint ignores its group
filter).

LOGO_FIT gives every team's logo the same visual size and center. Logo
artwork fills its square very differently from team to team (a full-height
shield vs. a short wide arrowhead), so one fixed size and offset can't work.
Every logo is rendered through pixlet (so the measurement is exactly what the
device draws) at each candidate size. For each logo cell, the largest size
whose artwork fits with a 1px margin above and below is chosen, preferring
one a size smaller if that makes the artwork width match the cell's parity
(exact centering, so stacked logos line up), with the offset that centers the
artwork. Requires pixlet on PATH.
"""

import functools
import http.server
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import threading
import urllib.error
import urllib.request

from PIL import Image

SITE = "https://site.api.espn.com/apis/site/v2/sports"
STANDINGS = "https://site.api.espn.com/apis/v2/sports"
CDN = "https://a.espncdn.com"

# (config id, display label used by gameday.star, ESPN path)
LEAGUES = [
    ("nfl", "NFL", "football/nfl"),
    ("mlb", "MLB", "baseball/mlb"),
    ("nhl", "NHL", "hockey/nhl"),
    ("cfb", "CFB", "football/college-football"),
    ("nwsl", "NWSL", "soccer/usa.nwsl"),
]

# Logo cells in gameday.star: (width, height, largest logo size). Must match
# the stacked row logo column and the live side-by-side logo cell.
CELLS = {
    "stacked": (14, 12, 14),
    "live": (17, 16, 16),
}
# Artwork keeps 1px clear above and below (so tall logos don't touch the row
# edges). No side margin: the cells already have space beside them.
MARGIN_Y = 1
MARGIN_X = 0
MIN_SIZE = 8

# A rendered pixel brighter than this (max channel) counts as artwork. Fainter
# anti-aliased edge pixels don't read as part of the logo on the LEDs.
VISIBLE = 40

# How much smaller than the largest fitting size a logo may get in exchange
# for exact horizontal centering (artwork width with the same parity as the
# cell), so logos line up over each other.
MAX_SHRINK_FOR_EXACT = 1

BEGIN = "# BEGIN GENERATED TEAMS (tools/gen_teams.py)"
END = "# END GENERATED TEAMS"


def get_json(url):
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)


def league_teams(path):
    data = get_json(f"{SITE}/{path}/teams?limit=1000")
    return [t["team"] for t in data["sports"][0]["leagues"][0]["teams"]]


def fbs_ids():
    data = get_json(f"{STANDINGS}/football/college-football/standings?group=80")
    ids = set()

    def walk(node):
        for child in node.get("children", []):
            walk(child)
        for entry in node.get("standings", {}).get("entries", []):
            ids.add(entry["team"]["id"])

    walk(data)
    return ids


def logo_path(team):
    """The dark-background logo if ESPN has one, else the default."""
    logos = team.get("logos", [])
    by_rel = {tuple(l.get("rel", [])): l["href"] for l in logos}
    href = by_rel.get(("full", "dark")) or (logos[0]["href"] if logos else "")
    return href[len(CDN):] if href.startswith(CDN) else ""


class PixletMeasurer:
    """Measures logo artwork exactly as pixlet draws it.

    Originals are downloaded once and served locally; each batch of logos is
    rendered by pixlet at a given size in a grid of tiles, and the lit pixels
    of each tile give the artwork's bounding box.
    """

    TILE, COLS, ROWS = 16, 4, 2

    def __init__(self):
        self.pixlet = shutil.which("pixlet")
        if not self.pixlet:
            raise SystemExit("pixlet not found on PATH")
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix="gameday-logos-"))
        self.names = {}

        class Quiet(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

        handler = functools.partial(Quiet, directory=str(self.dir))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_port}/"

    def add(self, path):
        if path in self.names:
            return True
        try:
            with urllib.request.urlopen(CDN + path, timeout=30) as resp:
                data = resp.read()
        except urllib.error.URLError as err:
            print(f"  skip {path}: {err}")
            return False
        name = f"{len(self.names)}.png"
        (self.dir / name).write_bytes(data)
        self.names[path] = name
        return True

    def measure(self, paths, size):
        """{path: (x0, y0, x1, y1) inclusive, or None} at size x size."""
        out = {}
        per = self.COLS * self.ROWS
        for start in range(0, len(paths), per):
            batch = paths[start:start + per]
            urls = [self.base + self.names[p] for p in batch]
            app = self.dir / f"m{start}" / "measure.star"
            app.parent.mkdir(exist_ok=True)
            app.write_text(
                'load("http.star", "http")\n'
                'load("render.star", "render")\n'
                f"URLS = {json.dumps(urls)}\n"
                "def main():\n"
                "    tiles = [render.Box(width = 64, height = 32)]\n"
                "    for i, u in enumerate(URLS):\n"
                f"        img = render.Image(src = http.get(u).body(), width = {size}, height = {size})\n"
                f"        tiles.append(render.Padding(pad = ((i % {self.COLS}) * {self.TILE}, (i // {self.COLS}) * {self.TILE}, 0, 0), child = img))\n"
                "    return render.Root(child = render.Stack(children = tiles))\n"
            )
            gif = app.with_suffix(".gif")
            subprocess.run([self.pixlet, "render", str(app), "--gif", "-o", str(gif)], check=True, capture_output=True)
            im = Image.open(gif).convert("RGB")
            for k, p in enumerate(batch):
                ox, oy = (k % self.COLS) * self.TILE, (k // self.COLS) * self.TILE
                lit = [(x, y) for y in range(size) for x in range(size) if max(im.getpixel((ox + x, oy + y))) > VISIBLE]
                out[p] = (min(x for x, _ in lit), min(y for _, y in lit), max(x for x, _ in lit), max(y for _, y in lit)) if lit else None
        return out


def fit(boxes, cell):
    """(size, x, y): logo size and top-left position in the cell.

    boxes maps size -> artwork box. Takes the largest size whose artwork fits
    the cell's margins, but prefers one up to MAX_SHRINK_FOR_EXACT smaller
    whose artwork width has the cell's parity, so it sits exactly on the
    cell's vertical center line and stacked logos line up. Exact vertical
    centering is taken too when it comes at the same size.
    """
    w, h, largest = cell
    fitting = []  # (size, box, exact horizontally, exact vertically), largest first
    for size in range(largest, MIN_SIZE - 1, -1):
        box = boxes.get(size)
        if not box:
            continue
        x0, y0, x1, y1 = box
        aw, ah = x1 - x0 + 1, y1 - y0 + 1
        if aw <= w - 2 * MARGIN_X and ah <= h - 2 * MARGIN_Y:
            fitting.append((size, box, (w - aw) % 2 == 0, (h - ah) % 2 == 0))
    if not fitting:
        return None
    best = fitting[0][0]
    near = [f for f in fitting if f[0] >= best - MAX_SHRINK_FOR_EXACT]
    exact_x = [f for f in near if f[2]]
    if exact_x:
        top = exact_x[0][0]
        size, box, _, _ = next((f for f in exact_x if f[0] == top and f[3]), exact_x[0])
    else:
        size, box, _, _ = fitting[0]
    x0, y0, x1, y1 = box
    # Floor consistently, so any leftover half pixel always goes the same way.
    x = (w - (x1 - x0 + 1)) // 2 - x0
    y = (h - (y1 - y0 + 1)) // 2 - y0
    return (size, x, y)


def main():
    teams_out, fit_out = {}, {}
    for key, label, path in LEAGUES:
        teams = league_teams(path)
        if key == "cfb":
            fbs = fbs_ids()
            teams = [t for t in teams if t["id"] in fbs]
        teams.sort(key=lambda t: t["displayName"])
        teams_out[key] = [(t["id"], t["displayName"]) for t in teams]

        fit_out[label] = [(t["id"], logo_path(t)) for t in teams if logo_path(t)]

    # Measure every logo at every candidate size through pixlet.
    measurer = PixletMeasurer()
    paths = sorted({p for logos in fit_out.values() for _, p in logos if measurer.add(p)})
    sizes = range(MIN_SIZE, max(c[2] for c in CELLS.values()) + 1)
    boxes = {}
    for size in sizes:
        for p, box in measurer.measure(paths, size).items():
            boxes.setdefault(p, {})[size] = box
        print(f"measured {len(paths)} logos at {size}px")

    for label, logos in list(fit_out.items()):
        fits = {}
        for tid, p in logos:
            if p not in boxes:
                continue
            stacked, live = fit(boxes[p], CELLS["stacked"]), fit(boxes[p], CELLS["live"])
            if stacked and live:
                fits[tid] = (p,) + stacked + live
        fit_out[label] = fits
        print(f"{label}: {len(logos)} logos, {len(fits)} fitted")

    lines = [BEGIN, "TEAMS = {"]
    for key, teams in teams_out.items():
        lines.append(f'    "{key}": [')
        lines.extend(f"        ({json.dumps(i)}, {json.dumps(n)})," for i, n in teams)
        lines.append("    ],")
    lines += [
        "}",
        "",
        "# Per-team logo fit, keyed by league label and team id:",
        "# (path, stacked size, x, y, live size, x, y).",
        "LOGO_FIT = {",
    ]
    for label, fits in fit_out.items():
        lines.append(f'    "{label}": {{')
        for tid, (p, ss, sx, sy, ls, lx, ly) in sorted(fits.items(), key=lambda kv: int(kv[0])):
            lines.append(f"        {json.dumps(tid)}: ({json.dumps(p)}, {ss}, {sx}, {sy}, {ls}, {lx}, {ly}),")
        lines.append("    },")
    lines += ["}", END]

    star = pathlib.Path(__file__).resolve().parent.parent / "gameday.star"
    src = star.read_text()
    pattern = re.compile(re.escape(BEGIN) + ".*?" + re.escape(END), re.S)
    if not pattern.search(src):
        raise SystemExit(f"markers not found in {star}")
    star.write_text(pattern.sub(lambda _: "\n".join(lines), src))
    print(f"updated {star}")


if __name__ == "__main__":
    main()
