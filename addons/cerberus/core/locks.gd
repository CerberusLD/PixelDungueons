@tool
class_name CerberusLocks
extends RefCounted
## Locks cooperativos sobre rutas del proyecto para escrituras concurrentes.

var _locks: Dictionary = {}  # resource -> {owner, expires, reason, acquired_ms}


func acquire(resource: String, owner: String, ttl_ms: int = 120000, reason: String = "") -> Dictionary:
	_purge()
	var key := resource.simplify_path()
	var current: Variant = _locks.get(key)
	if current != null and current.owner != owner:
		return {
			"acquired": false,
			"holder": current.owner,
			"ttl_remaining_ms": max(0, int(current.expires) - Time.get_ticks_msec()),
		}
	_locks[key] = {
		"owner": owner,
		"expires": Time.get_ticks_msec() + max(1000, ttl_ms),
		"reason": reason,
		"acquired_ms": Time.get_ticks_msec(),
	}
	return {"acquired": true, "resource": key}


func release(resource: String, owner: String) -> bool:
	var key := resource.simplify_path()
	var current: Variant = _locks.get(key)
	if current == null:
		return false
	if current.owner != owner:
		return false
	_locks.erase(key)
	return true


func release_all(owner: String) -> int:
	var n := 0
	for key in _locks.keys():
		if _locks[key].owner == owner:
			_locks.erase(key)
			n += 1
	return n


func holder(resource: String) -> String:
	_purge()
	var current: Variant = _locks.get(resource.simplify_path())
	return "" if current == null else String(current.owner)


func list() -> Array:
	_purge()
	var out: Array = []
	for key in _locks.keys():
		var l: Dictionary = _locks[key]
		out.append({
			"resource": key,
			"owner": l.owner,
			"reason": l.reason,
			"ttl_remaining_ms": max(0, int(l.expires) - Time.get_ticks_msec()),
		})
	return out


func _purge() -> void:
	var now := Time.get_ticks_msec()
	for key in _locks.keys():
		if int(_locks[key].expires) <= now:
			_locks.erase(key)
