class_name GSLeaderboardStoreBackbone
extends GSLeaderboardStore

## Boards that live on the TMC backbone, read and written through its
## `/api/integration/v1/leaderboard/*` endpoints.

const CHANNEL := "leaderboard.backbone"

const DEFINE_PATH := "leaderboard/define"
const SUBMIT_PATH := "leaderboard/submit"
const BOARD_PATH := "leaderboard/board"

## Needs `LEADERBOARD_READ` on top of the write scope the reporter uses.
const SCOPE_READ := "LEADERBOARD_READ"

## The backbone's cap on one page.
const MAX_PAGE := 100

## Anything with `post_integration(path, body)` and `get_integration(path, query)`:
## GameSpice Auth's `GSBackboneClient`. Assigned, never named, so GameSpice Auth stays optional.
var client: Object = null

## Boards already declared this run, so a submit does not define first every time.
var _declared: Dictionary = {}


static func with_client(p_client: Object) -> GSLeaderboardStoreBackbone:
	var store := GSLeaderboardStoreBackbone.new()
	store.client = p_client
	return store


func is_available() -> bool:
	return client != null and client.has_method("post_integration") and client.has_method("get_integration")


## Remote, so the plain `submit`/`page`/`entry_for` refuse it and the `_async` forms work.
func is_synchronous() -> bool:
	return false


## True for a store that is itself the site's copy; the manager then skips its reporter.
func is_remote() -> bool:
	return true


## Declares a board once; the site refuses entries for a board it has not been told about.
func declare(board: GSLeaderboardDef) -> GSResult:
	var key := board.key()
	if _declared.has(key):
		return GSResult.success(false)

	var unavailable := _need_client()
	if unavailable != null:
		return unavailable

	var res: Variant = await client.call(
		"post_integration", DEFINE_PATH, {"boards": [GSLeaderboardReporter.wire_definition(board)]}
	)
	var checked := _checked(res)
	if checked.ok:
		_declared[key] = true
	return checked


## Files an entry, overwriting: the manager already judged that it beats the held one.
func put(entry: GSLeaderboardEntry) -> GSResult:
	if entry == null or entry.board_key == "":
		return GSResult.fail(GSError.CODE_INVALID, "An entry needs a board key.")

	var unavailable := _need_client()
	if unavailable != null:
		return unavailable

	var address := split_key(entry.board_key)
	var wire := {
		"board": address["board"],
		"scope": address["scope"],
		"player": String(entry.player_id),
		"name": entry.player_name,
		"value": entry.value,
		"meta": entry.meta,
	}
	if entry.set_at > 0:
		wire["setAt"] = entry.set_at

	var res: Variant = await client.call(
		"post_integration", SUBMIT_PATH, {"entries": [wire], "overwrite": true}
	)
	var checked := _checked(res)
	if not checked.ok:
		return checked

	var refused: Variant = (checked.value as Dictionary).get("refused", [])
	if refused is Array and not (refused as Array).is_empty():
		return GSResult.fail(
			GSError.CODE_INVALID, "The backbone refused the entry.", str((refused as Array)[0])
		)

	# The previous entry is the manager's own read; the site does not return one.
	return GSResult.success(null)


## A page of a board, best first, as `Array[GSLeaderboardEntry]` with ranks set.
func page(board: GSLeaderboardDef, offset: int = 0, limit: int = 25) -> GSResult:
	var read := await _read(board, offset, limit, &"")
	if not read.ok:
		return read

	var out: Array[GSLeaderboardEntry] = []
	for row in (read.value as Dictionary).get("rows", []):
		out.append(_entry(board, row))
	return GSResult.success(out)


## The best [param count] entries.
func top(board: GSLeaderboardDef, count: int = 10) -> GSResult:
	return await page(board, 0, count)


## One player's entry with its rank, or a success carrying null.
func entry_for(board: GSLeaderboardDef, player_id: StringName) -> GSResult:
	var read := await _read(board, 0, 1, player_id)
	if not read.ok:
		if read.error.http_status == 404:
			return GSResult.success(null)
		return read

	var mine: Variant = (read.value as Dictionary).get("self")
	return GSResult.success(_entry(board, mine) if mine is Dictionary else null)


## The player's rank, for the manager to stamp on a fresh entry.
func rank_entry(board: GSLeaderboardDef, player_id: StringName) -> GSResult:
	var found := await entry_for(board, player_id)
	if not found.ok:
		return found
	return GSResult.success(found.value.rank if found.value != null else 0)


## The player's row with [param radius] entries each side. Two requests: the site gives the
## rank only with the player's own row, and a page is addressed by offset. No entry: top of board.
func around(board: GSLeaderboardDef, player_id: StringName, radius: int = 3) -> GSResult:
	var found := await entry_for(board, player_id)
	if not found.ok:
		return found

	if found.value == null:
		return await page(board, 0, radius * 2 + 1)

	var rank: int = (found.value as GSLeaderboardEntry).rank
	var start := maxi(0, rank - 1 - radius)
	return await page(board, start, radius * 2 + 1)


func count_on(board: GSLeaderboardDef) -> GSResult:
	var read := await _read(board, 0, 1, &"")
	if not read.ok:
		return read
	return GSResult.success(int(((read.value as Dictionary).get("board", {}) as Dictionary).get("entries", 0)))


func stats_for(_player_id: StringName) -> GSResult:
	return GSResult.fail(GSError.CODE_UNSUPPORTED, "The backbone store holds boards, not statistics.")


func add_stats(_player_id: StringName, _stats: GSStatSet) -> GSResult:
	return GSResult.fail(GSError.CODE_UNSUPPORTED, "The backbone store holds boards, not statistics.")


## `"id|k=v;k=v"` back to a board id and a scope map: the inverse of [method GSLeaderboardDef.key].
static func split_key(key: String) -> Dictionary:
	var parts := key.split("|", true, 1)
	var scope := {}
	if parts.size() > 1:
		for pair in parts[1].split(";", false):
			var kv := pair.split("=", true, 1)
			if kv.size() == 2:
				scope[kv[0]] = kv[1]
	return {"board": parts[0], "scope": scope}


func _read(board: GSLeaderboardDef, offset: int, limit: int, player_id: StringName) -> GSResult:
	var unavailable := _need_client()
	if unavailable != null:
		return unavailable

	var query := {
		"board": String(board.id),
		"scope": board.scope_key(),
		"offset": maxi(offset, 0),
		"limit": clampi(limit, 1, MAX_PAGE),
	}
	if player_id != &"":
		query["player"] = String(player_id)

	var res: Variant = await client.call("get_integration", BOARD_PATH, query)
	var checked := _checked(res)
	if not checked.ok and checked.error.http_status == 403:
		GSLog.warn(CHANNEL, "the backbone refused the read; the integration may lack a scope", {"need": SCOPE_READ})
	return checked


func _entry(board: GSLeaderboardDef, row: Variant) -> GSLeaderboardEntry:
	var data: Dictionary = row if row is Dictionary else {}
	var entry := GSLeaderboardEntry.make(
		board.key(), StringName(str(data.get("player", ""))), str(data.get("name", "")),
		float(data.get("value", 0.0)), data.get("meta") if data.get("meta") is Dictionary else {}
	)
	entry.rank = int(data.get("rank", 0))
	entry.set_at = int(data.get("setAt", 0))
	return entry


func _need_client() -> GSResult:
	if is_available():
		return null
	return GSResult.fail(
		GSError.CODE_STATE, "No backbone client; the leaderboard store is off.",
		"assign GSLeaderboardStoreBackbone.client from dot-auth's GSBackboneClient"
	)


## A client answer as a GSResult holding the response dictionary.
func _checked(res: Variant) -> GSResult:
	if not (res is GSResult):
		return GSResult.fail(GSError.CODE_INTERNAL, "The backbone client returned something unexpected.", str(res))
	var typed: GSResult = res
	if typed.ok and not (typed.value is Dictionary):
		return GSResult.fail(GSError.CODE_PARSE, "The backbone answered with something other than an object.")
	return typed
