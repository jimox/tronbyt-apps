# Gameday

Pick a favorite NFL, MLB, NHL, college football (FBS) and NWSL team. The app
shows one game, in this order of priority:

1. A live game, with score and clock (red). If several of your teams are live,
   it rotates between them every 5 seconds.
2. A game that finished today, with the final score. The loser is dimmed.
3. The soonest upcoming game across your teams, with both records.

It hides itself if none of your teams has anything scheduled.

## Display

```
NFL      4:12 - 3rd      league · status (live in red, FINAL, or start time)
[logo] KC          17    away team, row in the team's color
[logo] DEN       • 21    home team; • = possession
```

- Each team row is filled with the team's color (brightness-normalized so
  white text stays readable); the losing team in a final is dimmed.
- Live football alternates the clock with down and distance
  ("2nd & 7 DEN 35"). Live baseball shows the inning, a bases diamond and
  outs.
- Upcoming games alternate the start time with the team's last result
  ("W 27-24").

## Data

Uses ESPN's public site API (no key). It's unofficial and could change
without notice.

- League scoreboard for today: live scores and today's finals, cached 60s.
- Team page: next game, records and colors, cached 30 min.
- Team schedule: last result for upcoming games, cached 30 min.
- Logos: ESPN's dark-background variants where available, cached a day.

Set the app's render interval in Tronbyt to 1 minute so live scores stay
current.

## Team lists

The settings dropdowns come from a generated `TEAMS` table in `gameday.star`.
To refresh it (e.g. for expansion teams):

```
python3 tools/gen_teams.py
```

## Local render

```
pixlet render gameday.star nfl=7 '$tz=America/Denver'
```
