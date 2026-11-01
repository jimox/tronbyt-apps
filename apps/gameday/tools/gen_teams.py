#!/usr/bin/env python3
"""
Regenerates the TEAMS table in ../gameday.star from ESPN.

    python3 tools/gen_teams.py

College football is limited to FBS (taken from the FBS standings, since the
teams endpoint ignores its group filter).
"""

import json
import pathlib
import re
import urllib.request

SITE = "https://site.api.espn.com/apis/site/v2/sports"
STANDINGS = "https://site.api.espn.com/apis/v2/sports"

LEAGUES = [
    ("nfl", "football/nfl"),
    ("mlb", "baseball/mlb"),
    ("nhl", "hockey/nhl"),
    ("cfb", "football/college-football"),
    ("nwsl", "soccer/usa.nwsl"),
]

BEGIN = "# BEGIN GENERATED TEAMS (tools/gen_teams.py)"
END = "# END GENERATED TEAMS"


def get(url):
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)


def league_teams(path):
    data = get(f"{SITE}/{path}/teams?limit=1000")
    teams = data["sports"][0]["leagues"][0]["teams"]
    return [(t["team"]["id"], t["team"]["displayName"]) for t in teams]


def fbs_teams():
    data = get(f"{STANDINGS}/football/college-football/standings?group=80")
    teams = {}

    def walk(node):
        for child in node.get("children", []):
            walk(child)
        for entry in node.get("standings", {}).get("entries", []):
            teams[entry["team"]["id"]] = entry["team"]["displayName"]

    walk(data)
    return list(teams.items())


def main():
    lines = [BEGIN, "TEAMS = {"]
    for key, path in LEAGUES:
        teams = fbs_teams() if key == "cfb" else league_teams(path)
        teams.sort(key=lambda t: t[1])
        lines.append(f'    "{key}": [')
        lines.extend(f"        ({json.dumps(i)}, {json.dumps(n)})," for i, n in teams)
        lines.append("    ],")
        print(f"{key}: {len(teams)} teams")
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
