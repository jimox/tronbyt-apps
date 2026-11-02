# Gameday

Pick a favorite NFL, MLB, NHL, college football (FBS) and NWSL team. The app
shows one game, in this order of priority:

1. A live game, with score and clock (red). If several of your teams are live,
   it rotates between them every 5 seconds.
2. A game that finished today, with the final score. The loser is dimmed.
3. The soonest upcoming game across your teams, with both records.

It hides itself if none of your teams has anything scheduled.

## Display

Live games use a side-by-side layout with 16px logos:

```
NFL       4:12 - 3rd     league · clock (red); alternates with down & distance
[LOGO]   17   21  [LOGO]
 [KC]           •[DEN]   team-color name tags; • = possession
```

Finals and upcoming games use stacked team-color rows with 14px logos:

```
NFL            FINAL     league · FINAL, or start time / last result
[logo] KC          20    loser dimmed
[logo] DEN         24    (upcoming games show records instead of scores)
```

- Team colors are the primary color (alternate if the primary is black or
  grey), normalized in brightness so white text reads on every team.
- Live baseball shows the inning, a bases diamond and outs in the header.
- Text is positioned from each font's glyph metrics (`FONT_METRICS`) so it
  is centered in its tag or row. Logos are sized and centered by their
  artwork using `LOGO_FIT`, and clipped to their cells.

## Data

Uses ESPN's public site API (no key). It's unofficial and could change
without notice.

- League scoreboard for today: live scores and today's finals, cached 60s.
- Team page: next game, records and colors, cached 30 min.
- Team schedule: last result for upcoming games, cached 30 min.
- Logos: ESPN's dark-background variants where available, cached a day.

Set the app's render interval in Tronbyt to 1 minute so live scores stay
current.

## Team lists and logo fit

The settings dropdowns (`TEAMS`) and per-team logo placement (`LOGO_FIT`)
are generated tables in `gameday.star`. To refresh them (e.g. for expansion
teams or new logos):

```
pip install pillow
python3 tools/gen_teams.py
```

Logo artwork fills its square very differently from team to team, so the
generator measures each logo at the sizes the app uses and records the
largest size whose artwork fits the cell with 1px clear above and below, plus
the offset that centers the artwork. Teams without an entry (e.g. FCS
opponents) fall back to a default size and position.

## Local render

```
pixlet render gameday.star nfl=7 '$tz=America/Denver'
```
