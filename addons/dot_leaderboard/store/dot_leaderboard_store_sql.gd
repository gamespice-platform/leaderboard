@tool
class_name GSLeaderboardStoreSql
extends GSLeaderboardStore

## Boards and statistics in real tables, in whichever SQL a GameSpice SQL driver speaks.
##
## [codeblock]
## var store := GSLeaderboardStoreSql.new(GSSqlDriverSqlite.new("user://boards.db"))
## var opened := await store.open()      # creates or migrates the tables
## boards.store = store
## await boards.submit_async(&"fastest", scope, player_id, player_name, time)
## [/codeblock]
##
## [b]The driver is duck-typed[/b] — held untyped and asked for `query`, `execute`,
## `batch`, `upsert_sql`, `dialect` and `migrate` — so GameSpice Leaderboard does not depend on
## GameSpice SQL and parses in a project without it. The tables are
## [GSLeaderboardSqlSchema]'s specs, rendered by the driver for its own dialect.
##
## [b]Every method suspends[/b], because every one is a round trip. So this store reports
## [method is_synchronous] false, and [GSLeaderboardManager]'s synchronous
## [code]submit[/code], [code]page[/code] and [code]entry_for[/code] refuse it in words
## rather than failing half-way with "Trying to call an async function without await";
## the [code]_async[/code] forms are the ones that work with it.
##
## [b]Ranks are computed on read, not materialised.[/b] See
## [method GSLeaderboardSqlSchema.select_page]: a stored rank is a write per player on the
## board for every submission. Ties share a rank.
##
## [b]Statements are parameterised, always.[/b] A player name is the string most likely to
## contain a quote and the one an attacker chooses.

const CHANNEL := "leaderboard"

## Where statements go: a GameSpice SQL driver, or anything shaped like one.
var driver = null

## Table names, in case an operator already owns these or runs two games in one database.
var entries_table: String = GSLeaderboardSqlSchema.DEFAULT_ENTRIES_TABLE
var stats_table: String = GSLeaderboardSqlSchema.DEFAULT_STATS_TABLE

## Create or migrate the tables on [method open]. Off for a deployment whose schema is
## managed elsewhere and which would rather this touched nothing.
var create_schema: bool = true

## Diagnostics.
var reads: int = 0
var writes: int = 0

## board key -> the entry [method put] just wrote, for [method sort_board] to rank.


func _init(p_driver = null) -> void:
	driver = p_driver


func is_synchronous() -> bool:
	return false


func store_name() -> String:
	return "sql/%s" % (driver.driver_name() if driver != null else "none")


func is_writable() -> bool:
	return driver != null and driver.is_open()


## Opens the driver and, unless told not to, creates or migrates the tables.
func open() -> GSResult:
	if driver == null:
		return GSResult.fail(GSError.CODE_STATE, "No SQL driver.")

	var available: GSResult = driver.is_available()
	if not available.ok:
		return available

	var opened: GSResult = await driver.open()
	if not opened.ok:
		return opened

	if not create_schema:
		return GSResult.success(true)

	# Versioned rather than "create if missing": a database from an older build is brought
	# forward, and one from a NEWER build is refused rather than read with columns that
	# have changed meaning underneath it.
	var migrated: GSResult = await driver.migrate(
		"%s:%s" % [GSLeaderboardSqlSchema.MIGRATION_COMPONENT, entries_table],
		GSLeaderboardSqlSchema.migration_steps(entries_table, stats_table)
	)

	if not migrated.ok:
		return migrated.wrap("Could not prepare the leaderboard tables.")

	GSLog.info(CHANNEL, "leaderboard tables ready", {
		"dialect": GSLeaderboardSqlSchema.dialect_name(int(driver.dialect())),
		"entries": entries_table,
		"stats": stats_table,
	})

	return GSResult.success(true)


func close() -> void:
	if driver != null:
		driver.close()


func put(entry: GSLeaderboardEntry) -> GSResult:
	if entry == null or entry.board_key == "" or entry.player_id == &"":
		return GSResult.fail(GSError.CODE_INVALID, "An entry needs a board key and a player.")

	# JSON has no NaN and MySQL refuses one, so it would fail on two backends of three and
	# poison the board on the third. The manager refuses it first; a store used directly
	# refuses it here.
	if not is_finite(entry.value):
		return GSResult.fail(GSError.CODE_INVALID, "An entry's value must be finite.", str(entry.value))

	if not is_writable():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	var before: GSResult = await driver.query(
		GSLeaderboardSqlSchema.select_entry(entries_table),
		[entry.board_key, String(entry.player_id)]
	)
	if not before.ok:
		return before.wrap("Could not read the previous entry.")

	var rows: Array = before.value
	var previous: GSLeaderboardEntry = (
		GSLeaderboardSqlSchema.entry_from_row(rows[0]) if not rows.is_empty() else null
	)

	# An upsert, so a retry after a timeout cannot file a player twice on one board.
	# Unconditional: whether the value is an improvement is the manager's call, because the
	# store has no ordering to judge it by (see GSLeaderboardStore).
	var wrote: GSResult = await driver.execute(
		driver.upsert_sql(
			entries_table,
			PackedStringArray(GSLeaderboardSqlSchema.ENTRY_COLUMNS),
			PackedStringArray(["board_key", "player_id"])
		),
		GSLeaderboardSqlSchema.entry_to_row(entry)
	)
	if not wrote.ok:
		return wrote.wrap("Could not write the entry.")

	writes += 1
	return GSResult.success(previous)


## The rank of [param player_id] on [param board], for the manager to stamp on the entry
## it just wrote. 0 when they have none.
##
## [b]By player, never "the last entry written".[/b] A per-board slot holding the last
## write was overwritten by a second submission to the same board before the first was
## ranked, and the first went back with rank 0.
func rank_entry(board: GSLeaderboardDef, player_id: StringName) -> GSResult:
	var ranked: GSResult = await _ranked_entry(board, player_id)
	if not ranked.ok:
		return ranked
	return GSResult.success((ranked.value as GSLeaderboardEntry).rank if ranked.value is GSLeaderboardEntry else 0)


## Nothing to re-sort: the index is the order. Kept for the interface the memory store
## answers; the manager ranks a written entry through [method rank_entry].
func sort_board(_board: GSLeaderboardDef) -> GSResult:
	return GSResult.success(0)


func page(board: GSLeaderboardDef, offset: int = 0, limit: int = 25) -> GSResult:
	if not is_writable():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	var got: GSResult = await driver.query(
		GSLeaderboardSqlSchema.select_page(entries_table, board.lower_is_better()),
		[board.key(), maxi(limit, 0), maxi(offset, 0)]
	)
	if not got.ok:
		return got.wrap("Could not read a board.")

	reads += 1
	var out: Array[GSLeaderboardEntry] = []
	for row in (got.value as Array):
		var entry := GSLeaderboardSqlSchema.entry_from_row(row)
		if entry != null:
			out.append(entry)

	return GSResult.success(out)


func entry_for(board: GSLeaderboardDef, player_id: StringName) -> GSResult:
	if not is_writable():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	return await _ranked_entry(board, player_id)


func count_on(board: GSLeaderboardDef) -> GSResult:
	if not is_writable():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	var got: GSResult = await driver.query_value(
		GSLeaderboardSqlSchema.count_board(entries_table), [board.key()], 0
	)
	if not got.ok:
		return got.wrap("Could not count a board.")

	return GSResult.success(int(got.value))


func remove(board: GSLeaderboardDef, player_id: StringName) -> GSResult:
	if not is_writable():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	var gone: GSResult = await driver.execute(
		GSLeaderboardSqlSchema.delete_entry(entries_table), [board.key(), String(player_id)]
	)
	if not gone.ok:
		return gone.wrap("Could not remove an entry.")

	writes += 1
	# The affected-row count, where the driver reports one, says whether anything was
	# there; the memory store answers the same question with true or false.
	return GSResult.success(int(gone.value) > 0 if gone.value is int or gone.value is float else true)


## Adds counters into a player's totals and returns the totals.
##
## One additive statement per counter (see [method GSLeaderboardSqlSchema.add_stat]), sent
## as one batch, so a driver with transactions applies a round's figures all or not at all.
func add_stats(player_id: StringName, stats: GSStatSet) -> GSResult:
	if stats == null:
		return GSResult.fail(GSError.CODE_INVALID, "No stats to add.")

	if not is_writable():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	var statement := GSLeaderboardSqlSchema.add_stat(stats_table, int(driver.dialect()))
	var batch: Array = []

	for id in stats.values:
		var amount := float(stats.values[id])
		if not is_finite(amount):
			return GSResult.fail(GSError.CODE_INVALID, "A counter must be finite.", String(id))
		batch.append([statement, [String(player_id), String(id), amount]])

	if not batch.is_empty():
		var added: GSResult = await driver.batch(batch)
		if not added.ok:
			return added.wrap("Could not add a player's statistics.")
		writes += 1

	return await stats_for(player_id)


func stats_for(player_id: StringName) -> GSResult:
	if not is_writable():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	var got: GSResult = await driver.query(
		GSLeaderboardSqlSchema.select_stats(stats_table), [String(player_id)]
	)
	if not got.ok:
		return got.wrap("Could not read a player's statistics.")

	reads += 1
	var out := GSStatSet.new()
	for row in (got.value as Array):
		if row is Dictionary:
			out.values[StringName(str(row.get("stat_id", "")))] = GSLeaderboardSqlSchema._number(row.get("amount", 0.0))

	return GSResult.success(out)


func _ranked_entry(board: GSLeaderboardDef, player_id: StringName) -> GSResult:
	var got: GSResult = await driver.query(
		GSLeaderboardSqlSchema.select_ranked_entry(entries_table, board.lower_is_better()),
		[board.key(), String(player_id)]
	)
	if not got.ok:
		return got.wrap("Could not read an entry.")

	reads += 1
	var rows: Array = got.value
	# Absent is not an error: a player who has never played is the normal case.
	return GSResult.success(GSLeaderboardSqlSchema.entry_from_row(rows[0]) if not rows.is_empty() else null)


func describe() -> Dictionary:
	var out := super.describe()
	out["store"] = store_name()
	out["writable"] = is_writable()
	out["entries_table"] = entries_table
	out["stats_table"] = stats_table
	out["dialect"] = GSLeaderboardSqlSchema.dialect_name(int(driver.dialect()) if driver != null else -1)
	out["reads"] = reads
	out["writes"] = writes
	return out
