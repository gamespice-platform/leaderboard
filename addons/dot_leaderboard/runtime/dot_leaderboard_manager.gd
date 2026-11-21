@tool
class_name GSLeaderboardManager
extends Node

## The node a game adds: its boards, its store, its statistics, and the reporter.
##
## [codeblock]
## var boards := GSLeaderboardManager.new()
## boards.store = GSLeaderboardStoreMemory.new()
## add_child(boards)
##
## boards.define(GSLeaderboardDef.make(&"fastest", GSLeaderboardDef.Kind.TIME,
##     {"map": "surf_beginner", "track": "0", "style": "normal"}))
##
## await boards.submit(&"fastest", {"map": "surf_beginner", "track": "0",
##     "style": "normal"}, player_id, player_name, run.time())
## [/codeblock]
##
## With a store that reaches a database ([GSLeaderboardStoreSql]), open it first and use
## the awaited forms — [method submit_async], [method page_async], [method entry_for_async] —
## which work with every store; the plain forms are synchronous and refuse such a store in
## words. Why there are two is written above [method submit].
##
## [b]Boards are defined once and addressed by id plus scope.[/b] A timer has one
## board — "fastest time" — instantiated per map, track and style, and defining
## fourteen thousand of them up front would be absurd. So a definition is a template
## and [method board_for] produces the scoped instance on demand, caching it because
## the key is a string build and this is on the path of every submission.

const CHANNEL := "leaderboard"

## An entry was filed. [param previous] is what the player had before, or null.
signal entry_accepted(
	board: GSLeaderboardDef,
	entry: GSLeaderboardEntry,
	previous: GSLeaderboardEntry
)

## An entry was not filed, and why.
signal entry_refused(board_id: StringName, player_id: StringName, reason: String)

## A player's statistics changed.
signal stats_changed(player_id: StringName, totals: GSStatSet)

@export_group("Reporting")

## Whether accepted entries are queued for the backbone.
##
## Per-board [member GSLeaderboardDef.publish] still decides individually; this is
## the master switch, so a server can be taken off the site's leaderboards without
## editing every board.
@export var report_to_backbone: bool = false

## Seconds between flushes of the report queue. 0 disables the timer.
@export_range(0.0, 600.0, 1.0) var report_interval: float = 30.0

@export_group("Backend")

## Where boards live when [member store] is not assigned: this process (default) or the TMC
## backbone through [member backbone_client] or the registered GameSpice Auth client.
@export_enum("memory", "backbone") var backend: String = "memory"

## The client for the "backbone" backend: anything with `post_integration` and
## `get_integration`. Falls back to the `dot_backbone_client` registry service.
var backbone_client: Object = null

## Where entries live. A store that suspends must be opened before it is used here.
var store: GSLeaderboardStore = null

## Sends published entries to the backbone. Assign its client from GameSpice Auth.
var reporter := GSLeaderboardReporter.new()

## Board templates by id.
var _definitions: Dictionary = {}

## Scoped boards by their full key, so the key is built once per scope.
var _scoped: Dictionary = {}

var _report_timer: Timer = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if store == null:
		store = _make_store()

	if report_interval > 0.0:
		_report_timer = Timer.new()
		_report_timer.wait_time = report_interval
		_report_timer.autostart = true
		_report_timer.timeout.connect(_on_report_due)
		add_child(_report_timer)


func _make_store() -> GSLeaderboardStore:
	if backend != "backbone":
		return GSLeaderboardStoreMemory.new()

	var client: Object = backbone_client
	if client == null:
		client = GSRegistry.get_service(&"dot_backbone_client")
	if client == null:
		GSLog.warn(CHANNEL, "backend is backbone but no client is available; using memory")
		return GSLeaderboardStoreMemory.new()

	return GSLeaderboardStoreBackbone.with_client(client)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return

	# One last flush on the way out. A server shutting down cleanly holds up to a
	# whole interval of results, and losing the last round of a map because the
	# operator restarted is exactly the case a queue exists to survive.
	if report_to_backbone and reporter.queued() > 0 and reporter.is_available():
		reporter.flush_all()


# --- Boards ----------------------------------------------------------------

## Registers a board template.
func define(board: GSLeaderboardDef) -> GSResult:
	if board == null:
		return GSResult.fail(GSError.CODE_INVALID, "No board to define.")

	var valid := board.validate()

	if not valid.ok:
		return valid

	_definitions[board.id] = board

	return GSResult.success(board)


func definition(id: StringName) -> GSLeaderboardDef:
	var found: Variant = _definitions.get(id)
	return found if found is GSLeaderboardDef else null


## The board for an id and a scope, creating the scoped instance if needed.
##
## Cached by key. The key is a sorted string build, and this is called for every
## submission and every page render.
func board_for(id: StringName, scope: Dictionary = {}) -> GSLeaderboardDef:
	var template := definition(id)

	if template == null:
		return null

	if scope.is_empty():
		return template

	var scoped := template.scoped(scope)
	var key := scoped.key()

	if _scoped.has(key):
		return _scoped[key]

	_scoped[key] = scoped

	return scoped


func definitions() -> Array[GSLeaderboardDef]:
	var out: Array[GSLeaderboardDef] = []

	for id in _definitions:
		out.append(_definitions[id])

	out.sort_custom(func(a: GSLeaderboardDef, b: GSLeaderboardDef) -> bool:
		return String(a.id) < String(b.id)
	)

	return out


# --- Submitting ------------------------------------------------------------
#
# [b]Two forms of the three calls a game makes, and the reason is a parse error.[/b] A store
# is "a coroutine in shape" (GSLeaderboardStore), but `submit`, `page` and `entry_for`
# were written against the memory store and called it without `await`. Against a store that
# really suspends — GSLeaderboardStoreSql — that aborts the call with "Trying to call an
# async function without await" and hands the caller null. Adding the `await` here is the
# fix, and it makes each of them a coroutine, which is a PARSE error at every caller that
# does not await it: game-fatal-contact (`_cmd_boards`, headless_match) and game-hungario (`_submit`,
# `page`) call them synchronously today, and an addon edit that stops two games parsing is
# not a fix. So the `_async` forms are the real ones and work with every store; the plain
# forms stay synchronous, keep working with the memory store, and refuse an asynchronous
# store in words (GSLeaderboardStore.is_synchronous). When those games await, the plain
# forms can become the awaited ones and the `_async` names can go.

## Files a value on a board. Synchronous; see the note above, and [method submit_async].
##
## [b]Only an improvement is written.[/b] The comparison uses the board's own
## ordering, which is why this goes through the manager rather than the store — a
## store has entries and an entry does not carry whether lower is better.
func submit(
	board_id: StringName,
	scope: Dictionary,
	player_id: StringName,
	player_name: String,
	value: float,
	meta: Dictionary = {}
) -> GSResult:
	var ready := _prepare(board_id, scope, player_id, value)
	if not ready.ok:
		return ready
	var synchronous := _synchronous_store("submit")
	if not synchronous.ok:
		return synchronous

	var board: GSLeaderboardDef = ready.value
	var existing := store.entry_for(board, player_id)
	if not existing.ok:
		return existing

	var previous: GSLeaderboardEntry = (
		existing.value if existing.value is GSLeaderboardEntry else null
	)
	if previous != null and not board.beats(value, previous.value):
		# Not an error. Most results are worse than the player's own best, and
		# treating that as a failure means every caller has to tell the two apart.
		return GSResult.success(previous)

	var entry := GSLeaderboardEntry.make(board.key(), player_id, player_name, value, meta)
	var wrote := store.put(entry)
	if not wrote.ok:
		entry_refused.emit(board_id, player_id, wrote.error.message)
		return wrote

	# The store holds entries and does not know the ordering, so the manager — which
	# does — asks it to re-sort and re-rank. A store that does its own ordering
	# overrides this by ignoring the call.
	if store.has_method("sort_board"):
		store.call("sort_board", board)

	return _accepted(board, entry, previous)


## [method submit], awaited, for any store — including one that reaches a database.
func submit_async(
	board_id: StringName,
	scope: Dictionary,
	player_id: StringName,
	player_name: String,
	value: float,
	meta: Dictionary = {}
) -> GSResult:
	var ready := _prepare(board_id, scope, player_id, value)
	if not ready.ok:
		return ready

	var board: GSLeaderboardDef = ready.value
	var declared := await _declare(board)
	if not declared.ok:
		return declared

	var existing: GSResult = await store.entry_for(board, player_id)
	if not existing.ok:
		return existing

	var previous: GSLeaderboardEntry = (
		existing.value if existing.value is GSLeaderboardEntry else null
	)
	if previous != null and not board.beats(value, previous.value):
		return GSResult.success(previous)

	var entry := GSLeaderboardEntry.make(board.key(), player_id, player_name, value, meta)
	var wrote: GSResult = await store.put(entry)
	if not wrote.ok:
		entry_refused.emit(board_id, player_id, wrote.error.message)
		return wrote

	await _rank_written(board, entry)

	return _accepted(board, entry, previous)


## Writes [param value] whether or not it beats the held one: a board whose newest value
## is the right one ([member GSLeaderboardDef.running_total]). Awaited, for any store.
func replace_async(
	board_id: StringName,
	scope: Dictionary,
	player_id: StringName,
	player_name: String,
	value: float,
	meta: Dictionary = {}
) -> GSResult:
	var ready := _prepare(board_id, scope, player_id, value)
	if not ready.ok:
		return ready

	var board: GSLeaderboardDef = ready.value
	var declared := await _declare(board)
	if not declared.ok:
		return declared

	var existing: GSResult = await store.entry_for(board, player_id)
	var previous: GSLeaderboardEntry = (
		existing.value if existing.ok and existing.value is GSLeaderboardEntry else null
	)
	if previous != null and is_equal_approx(previous.value, value) and previous.player_name == player_name:
		return GSResult.success(previous)

	var entry := GSLeaderboardEntry.make(board.key(), player_id, player_name, value, meta)
	var wrote: GSResult = await store.put(entry)
	if not wrote.ok:
		entry_refused.emit(board_id, player_id, wrote.error.message)
		return wrote

	await _rank_written(board, entry)

	return _accepted(board, entry, previous)


## Ranks the entry just written. Awaited: the SQL store ranks THAT entry with a query
## ([code]rank_entry[/code]) — a per-board "last written" slot was overwritten by a second
## submission to the same board before the first was ranked, and the first went back
## unranked. A rank that could not be read is not a refusal; the entry IS on the board.
func _rank_written(board: GSLeaderboardDef, entry: GSLeaderboardEntry) -> void:
	var ranked: Variant = null
	if store.has_method("rank_entry"):
		ranked = await store.call("rank_entry", board, entry.player_id)
		if ranked is GSResult and (ranked as GSResult).ok:
			entry.rank = int((ranked as GSResult).value)
	elif store.has_method("sort_board"):
		ranked = await store.call("sort_board", board)
	if ranked is GSResult and not (ranked as GSResult).ok:
		GSLog.debug(CHANNEL, "an accepted entry could not be ranked", {
			"board": board.key(), "why": (ranked as GSResult).error.message,
		})


## The refusals both forms share: an unknown board, a non-finite value.
func _prepare(
	board_id: StringName, scope: Dictionary, player_id: StringName, value: float
) -> GSResult:
	var board := board_for(board_id, scope)

	if board == null:
		var reason := "No such board."
		entry_refused.emit(board_id, player_id, reason)
		return GSResult.fail(GSError.CODE_IO, reason, String(board_id))

	if not is_finite(value):
		# A NaN sorts unpredictably and, once on a board, cannot be compared out of
		# first place — every `beats` test against it is false, so nothing ever
		# replaces it. Cheap to refuse here; effectively unfixable afterwards.
		var reason := "That value is not a finite number."
		entry_refused.emit(board_id, player_id, reason)
		return GSResult.fail(GSError.CODE_INVALID, reason, str(value))

	if store == null:
		return GSResult.fail(GSError.CODE_STATE, "The board manager has no store.")

	return GSResult.success(board)


## Tells a store that keeps boards elsewhere about this one, once.
func _declare(board: GSLeaderboardDef) -> GSResult:
	if store != null and store.has_method("declare"):
		return await store.call("declare", board)
	return GSResult.success(true)


func _accepted(
	board: GSLeaderboardDef, entry: GSLeaderboardEntry, previous: GSLeaderboardEntry
) -> GSResult:
	# A backbone store already wrote it; queueing it too would submit twice.
	if report_to_backbone and not (store != null and store.has_method("is_remote")):
		reporter.queue_entry(board, entry)

	entry_accepted.emit(board, entry, previous)

	return GSResult.success(entry)


## Refuses a store that suspends, from a synchronous call that cannot wait for it.
func _synchronous_store(method: String) -> GSResult:
	if store == null:
		return GSResult.fail(GSError.CODE_STATE, "The board manager has no store.")
	if store.is_synchronous():
		return GSResult.success(true)
	return GSResult.fail(
		GSError.CODE_UNSUPPORTED,
		"This store answers asynchronously; await %s_async() instead." % method,
		str(store.describe().get("implementation", ""))
	)


## A page of a board. Synchronous; see [method page_async].
func page(
	board_id: StringName,
	scope: Dictionary = {},
	offset: int = 0,
	limit: int = 0
) -> GSResult:
	var board := board_for(board_id, scope)

	if board == null:
		return GSResult.fail(
			GSError.CODE_IO, "No such board.", String(board_id)
		)

	var synchronous := _synchronous_store("page")
	if not synchronous.ok:
		return synchronous

	return store.page(
		board, offset, limit if limit > 0 else board.page_size
	)


## [method page], awaited, for any store.
func page_async(
	board_id: StringName,
	scope: Dictionary = {},
	offset: int = 0,
	limit: int = 0
) -> GSResult:
	var board := board_for(board_id, scope)

	if board == null:
		return GSResult.fail(
			GSError.CODE_IO, "No such board.", String(board_id)
		)

	if store == null:
		return GSResult.fail(GSError.CODE_STATE, "The board manager has no store.")

	return await store.page(
		board, offset, limit if limit > 0 else board.page_size
	)


## A player's entry on a board, or a success carrying null. Synchronous; see
## [method entry_for_async].
func entry_for(
	board_id: StringName, scope: Dictionary, player_id: StringName
) -> GSResult:
	var board := board_for(board_id, scope)

	if board == null:
		return GSResult.fail(
			GSError.CODE_IO, "No such board.", String(board_id)
		)

	var synchronous := _synchronous_store("entry_for")
	if not synchronous.ok:
		return synchronous

	return store.entry_for(board, player_id)


## [method entry_for], awaited, for any store.
func entry_for_async(
	board_id: StringName, scope: Dictionary, player_id: StringName
) -> GSResult:
	var board := board_for(board_id, scope)

	if board == null:
		return GSResult.fail(
			GSError.CODE_IO, "No such board.", String(board_id)
		)

	if store == null:
		return GSResult.fail(GSError.CODE_STATE, "The board manager has no store.")

	return await store.entry_for(board, player_id)


# --- Statistics ------------------------------------------------------------
#
# Awaited in place. Unlike the three above, every caller in the family already awaits these,
# so making them coroutines broke nothing.

## Adds counters to a player's totals.
func add_stats(player_id: StringName, stats: GSStatSet) -> GSResult:
	var added: GSResult = await store.add_stats(player_id, stats)

	if added.ok and added.value is GSStatSet:
		stats_changed.emit(player_id, added.value)

	return added


func stats_for(player_id: StringName) -> GSResult:
	return await store.stats_for(player_id)


## Files a player's counter onto a board — "most kills", "furthest travelled".
##
## The bridge between the two halves: a stat set is many numbers accumulated, a board
## is one number ordered, and this is how one becomes the other. Reads the total from
## the store rather than taking a value, so a board built this way always agrees with
## the counter it is derived from.
func publish_stat(
	board_id: StringName,
	scope: Dictionary,
	player_id: StringName,
	player_name: String,
	stat_id: StringName
) -> GSResult:
	var totals: GSResult = await store.stats_for(player_id)

	if not totals.ok:
		return totals

	var set: GSStatSet = totals.value

	if not set.has(stat_id):
		return GSResult.success(null)

	return await submit_async(
		board_id, scope, player_id, player_name, set.get_value(stat_id)
	)


# --- Reporting -------------------------------------------------------------

func _on_report_due() -> void:
	if not report_to_backbone or reporter.queued() == 0:
		return

	if not reporter.is_available():
		return

	var flushed := await reporter.flush()

	if not flushed.ok:
		GSLog.debug(CHANNEL, "a leaderboard report failed", {
			"why": flushed.error.message, "queued": reporter.queued()
		})


func describe() -> Dictionary:
	return {
		"boards": _definitions.size(),
		"scoped": _scoped.size(),
		"store": store.describe() if store != null else "none",
		"reporting": report_to_backbone,
		"reporter": reporter.describe(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("boards       %d defined, %d scoped" % [
		_definitions.size(), _scoped.size()
	])
	out.append("reporting    %s" % report_to_backbone)
	out.append("queued       %d" % reporter.queued())

	for board in definitions():
		out.append("  %-20s %s" % [
			String(board.id), GSLeaderboardDef.Kind.keys()[board.kind]
		])

	return out
