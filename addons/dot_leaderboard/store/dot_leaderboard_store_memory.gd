class_name GSLeaderboardStoreMemory
extends GSLeaderboardStore

## Entries and statistics in dictionaries. For tests, a scratch server, and as the
## reference implementation.
##
## [b]Boards are kept sorted on write and ranks are materialised there too.[/b] A
## board is read far more often than it is written — a HUD asks for the top ten
## whenever anybody finishes, a scoreboard asks on every open, and "am I first" is
## asked constantly — so paying the sort on the write is the right side of the trade,
## and it turns a rank lookup into an array read.

## board key -> player id -> entry.
var _rows: Dictionary = {}

## board key -> sorted array of entries.
var _boards: Dictionary = {}

## player id -> GSStatSet.
var _stats: Dictionary = {}


func put(entry: GSLeaderboardEntry) -> GSResult:
	if entry == null or entry.board_key == "":
		return GSResult.fail(
			GSError.CODE_INVALID, "An entry needs a board key."
		)

	if not _rows.has(entry.board_key):
		_rows[entry.board_key] = {}
		_boards[entry.board_key] = []

	var by_player: Dictionary = _rows[entry.board_key]
	var previous_value: Variant = by_player.get(entry.player_id)
	var previous: GSLeaderboardEntry = (
		previous_value if previous_value is GSLeaderboardEntry else null
	)

	by_player[entry.player_id] = entry

	var rows: Array = _boards[entry.board_key]

	if previous != null:
		rows.erase(previous)

	rows.append(entry)

	return GSResult.success(previous)


## Sorts a board and rewrites every rank on it.
##
## [b]Called by the manager, not by [method put], and that is a real decision.[/b] The
## manager knows the board's ordering; the store only has entries, and an entry does
## not carry whether lower is better. Storing the ordering on the entry would put it
## on every row of every board; passing the definition to put() would make the
## interface awkward for a database implementation that keys on the board id alone.
## So the manager sorts, and a store used directly is a store with unranked rows —
## which [method page] still returns in insertion order rather than pretending.
func sort_board(board: GSLeaderboardDef) -> void:
	var key := board.key()
	var rows_value: Variant = _boards.get(key)

	if not (rows_value is Array):
		return

	var rows: Array = rows_value
	var lower := board.lower_is_better()

	# A tie is broken by player id only so that the order is stable between two reads —
	# `sort_custom` is not a stable sort, and a page boundary that moves between two
	# requests shows one player twice and another not at all. It is not a ranking rule:
	# see below. The SQL store orders the same way, so the two agree page for page.
	rows.sort_custom(func(a: GSLeaderboardEntry, b: GSLeaderboardEntry) -> bool:
		if a.value == b.value:
			return String(a.player_id) < String(b.player_id)
		return a.value < b.value if lower else a.value > b.value
	)

	# Competition ranking: a tie shares a rank, and the next distinct value is ranked by
	# how many are ahead of it (1, 2, 2, 4). Until 2026-10-08 the rank was the array index,
	# so two identical times were 2nd and 3rd in whichever order the sort left them —
	# awarding one of them a place over the other by a rule nobody agreed to (see
	# GSLeaderboardEntry.set_at), and disagreeing with the SQL store, which counts.
	for i in range(rows.size()):
		var entry := rows[i] as GSLeaderboardEntry
		if i > 0 and entry.value == (rows[i - 1] as GSLeaderboardEntry).value:
			entry.rank = (rows[i - 1] as GSLeaderboardEntry).rank
		else:
			entry.rank = i + 1


func page(
	board: GSLeaderboardDef, offset: int = 0, limit: int = 25
) -> GSResult:
	var rows_value: Variant = _boards.get(board.key(), [])
	var rows: Array = rows_value if rows_value is Array else []

	var out: Array[GSLeaderboardEntry] = []
	var start := maxi(offset, 0)

	for i in range(start, mini(start + maxi(limit, 0), rows.size())):
		out.append(rows[i])

	return GSResult.success(out)


func entry_for(
	board: GSLeaderboardDef, player_id: StringName
) -> GSResult:
	var by_player_value: Variant = _rows.get(board.key(), {})
	var by_player: Dictionary = (
		by_player_value if by_player_value is Dictionary else {}
	)

	var found: Variant = by_player.get(player_id)

	return GSResult.success(
		found if found is GSLeaderboardEntry else null
	)


func count_on(board: GSLeaderboardDef) -> GSResult:
	var rows_value: Variant = _boards.get(board.key(), [])
	return GSResult.success((rows_value as Array).size() if rows_value is Array else 0)


func remove(board: GSLeaderboardDef, player_id: StringName) -> GSResult:
	var key := board.key()
	var by_player_value: Variant = _rows.get(key, {})
	var by_player: Dictionary = (
		by_player_value if by_player_value is Dictionary else {}
	)

	var found: Variant = by_player.get(player_id)

	if not (found is GSLeaderboardEntry):
		return GSResult.success(false)

	by_player.erase(player_id)

	var rows_value: Variant = _boards.get(key, [])
	if rows_value is Array:
		(rows_value as Array).erase(found)

	sort_board(board)

	return GSResult.success(true)


func add_stats(player_id: StringName, stats: GSStatSet) -> GSResult:
	if stats == null:
		return GSResult.fail(GSError.CODE_INVALID, "No stats to add.")

	if not _stats.has(player_id):
		_stats[player_id] = GSStatSet.new()

	(_stats[player_id] as GSStatSet).add_from(stats)

	return GSResult.success(_stats[player_id])


func stats_for(player_id: StringName) -> GSResult:
	var found: Variant = _stats.get(player_id)

	# An empty set rather than null, so a caller reading a counter does not have to
	# check twice. A player with no statistics has zero of everything, which is what
	# an empty set says.
	return GSResult.success(
		found if found is GSStatSet else GSStatSet.new()
	)


## Every board key that has entries. For an export or a re-rank.
func board_keys() -> PackedStringArray:
	var out := PackedStringArray()

	for key in _boards:
		out.append(key)

	return out


func clear() -> void:
	_rows.clear()
	_boards.clear()
	_stats.clear()


func describe() -> Dictionary:
	var out := super.describe()
	out["boards"] = _boards.size()
	out["players_with_stats"] = _stats.size()

	var total := 0
	for key in _boards:
		total += (_boards[key] as Array).size()

	out["entries"] = total
	return out
