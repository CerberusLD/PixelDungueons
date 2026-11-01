@tool
class_name CerberusChangelog
extends RefCounted
## Registro transaccional: snapshots de ficheros antes de escribir + rollback.

const DIR := "res://.cerberus"
const BACKUPS := DIR + "/backups"
const JOURNAL := DIR + "/changelog.json"

var entries: Array = []


func _init() -> void:
	_load()


func _load() -> void:
	if FileAccess.file_exists(JOURNAL):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(JOURNAL))
		if parsed is Array:
			entries = parsed


func _save() -> void:
	_ensure_dir()
	var f := FileAccess.open(JOURNAL, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(entries, "  "))
		f.close()


func _ensure_dir() -> void:
	var d := DirAccess.open("res://")
	if d == null:
		return
	if not d.dir_exists(".cerberus"):
		d.make_dir(".cerberus")
	if not d.dir_exists(".cerberus/backups"):
		d.make_dir_recursive(".cerberus/backups")


## Guarda copia de los ficheros indicados antes de modificarlos.
func snapshot(paths: Array, tool: String, agent_id: String) -> String:
	_ensure_dir()
	var tx := "tx_%d_%04x" % [Time.get_unix_time_from_system(), randi() & 0xffff]
	var tx_dir := BACKUPS + "/" + tx
	var d := DirAccess.open("res://")
	if d and not d.dir_exists(".cerberus/backups/" + tx):
		d.make_dir_recursive(".cerberus/backups/" + tx)
	var files: Array = []
	var i := 0
	for p in paths:
		var path := str(p)
		if path.is_empty():
			continue
		if not path.begins_with("res://"):
			path = CerberusUtil.to_res(path)
		var existed := FileAccess.file_exists(path)
		var backup_path := ""
		var size := 0
		if existed:
			var src := FileAccess.open(path, FileAccess.READ)
			if src:
				var bytes := src.get_buffer(src.get_length())
				size = bytes.size()
				src.close()
				backup_path = "%s/%d.dat" % [tx_dir, i]
				var dst := FileAccess.open(backup_path, FileAccess.WRITE)
				if dst:
					dst.store_buffer(bytes)
					dst.close()
		files.append({"path": path, "existed": existed, "backup": backup_path, "size": size})
		i += 1
	var entry := {
		"id": tx,
		"time": Time.get_datetime_string_from_system(true),
		"unix": Time.get_unix_time_from_system(),
		"agent": agent_id,
		"tool": tool,
		"files": files,
	}
	entries.append(entry)
	if entries.size() > 200:
		entries = entries.slice(entries.size() - 200)
	_save()
	return tx


func list(limit: int = 20) -> Array:
	var out: Array = []
	var start := max(0, entries.size() - limit)
	for i in range(entries.size() - 1, start - 1, -1):
		out.append(entries[i])
	return out


func get_entry(tx: String) -> Variant:
	for e in entries:
		if e.id == tx:
			return e
	return null


func rollback(tx: String) -> Dictionary:
	var entry: Variant = get_entry(tx)
	if entry == null:
		return {"ok": false, "reason": "unknown_transaction"}
	var restored: Array = []
	var removed: Array = []
	for f in entry.files:
		var path: String = f.path
		if bool(f.existed) and not String(f.backup).is_empty():
			var src := FileAccess.open(String(f.backup), FileAccess.READ)
			if src == null:
				continue
			var bytes := src.get_buffer(src.get_length())
			src.close()
			var dst := FileAccess.open(path, FileAccess.WRITE)
			if dst:
				dst.store_buffer(bytes)
				dst.close()
				restored.append(path)
		elif not bool(f.existed):
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
				removed.append(path)
	entry["rolled_back"] = true
	_save()
	EditorInterface.get_resource_filesystem().scan()
	return {"ok": true, "restored": restored, "removed": removed}
