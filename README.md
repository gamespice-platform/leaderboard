# dot-leaderboard

Leaderboards and player statistics for any Godot game, plus the path from a game server to the TMC website's leaderboards.

Part of TMC's **Dot** collection: modular, MIT-licensed building blocks for games on the TMC platform (only the TMC website back end is closed). It was built with Claude Code and its headless suite passes, but little of it has met real players yet, so expect rough edges and please report what you find.

## What you get

A board orders one number per player within a scope you choose, such as map, track and style. "Fastest time on surf_beginner", "most kills this week" and "highest score" are one thing with different settings.

- **Boards** with four orderings (`TIME`, `SCORE`, `POINTS`, `PENALTY`) and display that knows a time from a score.
- **Ranks.** Ties share a rank (1, 2, 2, 4) in every store.
- **Player statistics:** counters, bests and lowests, and any counter can become a board.
- **Stores:** in memory, or `DotLeaderboardStoreSql` for SQLite, Postgres and MySQL/MariaDB through [dot-sql](https://github.com/modcommunity/dot-sql).
- **A reporter** that batches submissions to the TMC backbone and keeps its queue through an outage.

## Install

Copy `addons/dot_leaderboard/` and [dot-core](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable dot-leaderboard in **Project > Project Settings > Plugins**. dot-auth, dot-timer, dot-server and dot-sql are optional and never named in the source.

## Use

```gdscript
var boards := DotLeaderboardManager.new()
boards.store = DotLeaderboardStoreMemory.new()
add_child(boards)

var fastest := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME)
fastest.display_name = "Fastest time"
fastest.publish = true                # opt in to the site leaderboard
boards.define(fastest)

# one definition, one board per (map, track, style)
await boards.submit(
    &"fastest",
    {"map": "surf_beginner", "track": "0", "style": "normal"},
    player_id, player_name, run.time()
)

var page := await boards.page(&"fastest", {"map": "surf_beginner", "track": "0", "style": "normal"})
for entry in page.value:
    print("%d. %s %s" % [entry.rank, entry.player_name, fastest.format_value(entry.value)])
```

### Statistics

```gdscript
var session := DotStatSet.new()
session.add(&"jumps", stats.jumps)
session.set_best(&"top_speed", stats.max_speed)
await boards.add_stats(player_id, session)

# any counter can become a board
await boards.publish_stat(&"most_jumps", {}, player_id, player_name, &"jumps")
```

### A database

```gdscript
var store := DotLeaderboardStoreSql.new(driver)   # any dot-sql driver
await store.open()                                # creates or migrates its two tables
boards.store = store

await boards.submit_async(&"fastest", scope, player_id, player_name, run.time())
var page := await boards.page_async(&"fastest", scope)
```

Use the `_async` forms (`submit_async`, `page_async`, `entry_for_async`) with a database store. The plain forms refuse a store that has to wait. `add_stats`, `stats_for` and `publish_stat` are always awaited. Table names are the `entries_table` and `stats_table` settings (defaults `dot_leaderboard_entries` and `dot_leaderboard_stats`). Counters are added inside the database, so two servers sharing it do not lose each other's updates.

### Reporting to the website

```gdscript
boards.report_to_backbone = true
boards.reporter.client = backbone_client   # dot-auth's DotBackboneClient
```

This needs the `LEADERBOARD_WRITE` scope on a server or app integration. Entries are queued and sent in batches, and the queue survives an outage.

## Board definitions file

`tools/export_site_defs.gd` writes your boards as the website's `dot-leaderboard-defs` JSON, for the dashboard import or a deploy. Run it from the game project.

| Option | Meaning |
| --- | --- |
| `--source` | Script with the static method that returns an array of `DotLeaderboardDef`. |
| `--method` | The method name. |
| `--out` | Output file (default `deployment/leaderboard-defs.json`). |
| `--game` | Pin the site app id (unset by default). |
| `--check` | Exit 1 if the file is stale. |

A board is identified by `key` plus `scope`. Importing merges, and boards the file does not mention are kept with their entries.

## More

[docs/](docs/README.md) explains the design choices.

## Test

```bash
godot --headless --path . --import
godot --headless --path . res://examples/leaderboard_selftest.tscn

# the SQL store against real SQLite, Postgres and MariaDB (dot-sql linked in addons/)
../dot-sql/tools/test_live.sh . res://examples/leaderboard_sql_live.tscn
```

## Licence

MIT. See [LICENSE](LICENSE).
