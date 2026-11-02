#!/usr/bin/env python3
"""
Regenerates the TEAMS and LOGO_FIT tables in ../gameday.star from ESPN.

    pip install pillow
    python3 tools/gen_teams.py

TEAMS feeds the settings dropdowns. College football is limited to FBS
(taken from the FBS standings, since the teams endpoint ignores its group
filter).

LOGO_FIT gives every team's logo the same visual size and center. Logo
artwork fills its square very differently from team to team (a full-height
shield vs. a short wide arrowhead), so one fixed size and offset can't work.
For each logo cell the app uses, this picks the largest size whose artwork
fits inside the cell with a 1px margin above and below, and the offset that centers the
artwork (not the image) in the cell. The app fetches each original logo and
lets pixlet scale it; artwork bounds are measured on the original scaled the
same way.
"""

import io
import json
import pathlib
import re
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

# Alpha at or above this counts as visible artwork on the LEDs.
ALPHA_VISIBLE = 64

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


_originals = {}


def artwork(path, size):
    """Bounding box (x0, y0, x1, y1 inclusive) of visible artwork at size.

    The app fetches the original logo and lets pixlet scale it, so measure
    the original scaled the same way (Lanczos is a close match). ESPN's
    resizer is not used: it crops/shifts small logos by a pixel or so.
    """
    if path not in _originals:
        with urllib.request.urlopen(CDN + path, timeout=30) as resp:
            _originals[path] = Image.open(io.BytesIO(resp.read())).convert("RGBA")
    im = _originals[path].resize((size, size), Image.LANCZOS)
    box = im.split()[3].point(lambda v: 255 if v >= ALPHA_VISIBLE else 0).getbbox()
    return (box[0], box[1], box[2] - 1, box[3] - 1) if box else None


def round_half_up(x):
    return int(x + 0.5) if x >= 0 else -int(-x + 0.5)


def fit(path, cell):
    """(size, x, y): logo size and top-left position in the cell."""
    w, h, largest = cell
    for size in range(largest, MIN_SIZE - 1, -1):
        box = artwork(path, size)
        if not box:
            return None
        x0, y0, x1, y1 = box
        if x1 - x0 + 1 <= w - 2 * MARGIN_X and y1 - y0 + 1 <= h - 2 * MARGIN_Y:
            x = round_half_up((w - 1) / 2 - (x0 + x1) / 2)
            y = round_half_up((h - 1) / 2 - (y0 + y1) / 2)
            return (size, x, y)
    return None


def main():
    teams_out, fit_out = {}, {}
    for key, label, path in LEAGUES:
        teams = league_teams(path)
        if key == "cfb":
            fbs = fbs_ids()
            teams = [t for t in teams if t["id"] in fbs]
        teams.sort(key=lambda t: t["displayName"])
        teams_out[key] = [(t["id"], t["displayName"]) for t in teams]

        fits = {}
        for t in teams:
            p = logo_path(t)
            if not p:
                continue
            try:
                stacked, live = fit(p, CELLS["stacked"]), fit(p, CELLS["live"])
            except urllib.error.URLError as err:
                print(f"  skip {t['abbreviation']}: {err}")
                continue
            if stacked and live:
                fits[t["id"]] = (p,) + stacked + live
        fit_out[label] = fits
        print(f"{key}: {len(teams)} teams, {len(fits)} logos fitted")

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
