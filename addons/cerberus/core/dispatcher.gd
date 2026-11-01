@tool
class_name CerberusDispatcher
extends RefCounted
## Enruta tool_name -> handler, aplica permisos, locks y auditoría.

const MAX_HISTORY := 300

var plugin: EditorPlugin
var locks: CerberusLocks
var changelog: CerberusChangelog
var agents: Dictionary = {}     # agent_id -> {name, permission, task, status, last_seen, calls}
var history: Array = []         # ejecuciones recientes

var _cmds: Array = []


func _init(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	locks = CerberusLocks.new()
	changelog = CerberusChangelog.new()
	_cmds = [
		CerberusSceneCmds.new(self),
		CerberusNodeCmds.new(self),
		CerberusScriptCmds.new(self),
		CerberusResourceCmds.new(self),
		CerberusWorkspaceCmds.new(self),
		CerberusProjectCmds.new(self),
	]


# ------------------------------------------------------------------ registro

func tool_names() -> Array:
	var declared: Dictionary = plugin.specs.get("tools", {})
	var names: Array = []
	for cmd in _cmds:
		for m in cmd.get_method_list():
			var n := String(m.name)
			if not declared.has(n) or names.has(n):
				continue
			names.append(n)
	return names


func register_agent(agent_id: String, name: String, permission: String, task: String) -> Dictionary:
	var rank: int = plugin.permission_rank(permission)
	if rank < 0:
		return CerberusUtil.fail("invalid_permission", "permiso desconocido: %s" % permission,
			{"allowed": plugin.specs.get("permissions", [])})
	agents[agent_id] = {
		"agent_id": agent_id,
		"name": name if not name.is_empty() else agent_id,
		"permission": permission,
		"rank": rank,
		"task": task,
		"status": "idle",
		"last_seen": Time.get_datetime_string_from_system(true),
		"calls": 0,
	}
	return CerberusUtil.ok({"agent": agents[agent_id]})


func touch_agent(agent_id: String) -> void:
	if agents.has(agent_id):
		agents[agent_id]["last_seen"] = Time.get_datetime_string_from_system(true)
		agents[agent_id]["calls"] = int(agents[agent_id].get("calls", 0)) + 1


# ------------------------------------------------------------------ despacho

func dispatch(tool: String, args: Dictionary, session: Dictionary) -> Dictionary:
	var start := CerberusUtil.now_ms()
	var agent_id: String = session.get("agent_id", "anonymous")
	var permission: String = session.get("permission", "read")

	var spec: Dictionary = plugin.tool_spec(tool)
	if spec.is_empty():
		return _finish(tool, agent_id, start, CerberusUtil.fail("unknown_tool", "herramienta desconocida: %s" % tool))

	if String(spec.get("permission", "read")) != "":
		var need: int = plugin.permission_rank(String(spec.get("permission", "read")))
		var have: int = plugin.permission_rank(permission)
		if have < need:
			return _finish(tool, agent_id, start, CerberusUtil.fail(
				"permission_denied",
				"el agente '%s' tiene '%s' y la herramienta exige '%s'" % [agent_id, permission, spec.get("permission")],
				{"required": spec.get("permission"), "current": permission}))

	var invalid := _validate(args, spec.get("input", {}))
	if not invalid.is_empty():
		return _finish(tool, agent_id, start, CerberusUtil.fail("invalid_args", invalid))

	var locked := _locked_by(tool, args, agent_id, bool(spec.get("mutating", false)))
	if not locked.is_empty():
		return _finish(tool, agent_id, start, CerberusUtil.fail(
			"locked", "recurso bloqueado por otro agente", locked))

	var cmd := _find_cmd(tool)
	if cmd == null:
		return _finish(tool, agent_id, start, CerberusUtil.fail(
			"not_implemented", "no hay handler para '%s'" % tool))

	touch_agent(agent_id)
	if agents.has(agent_id):
		agents[agent_id]["status"] = "working"
	var result: Variant = await cmd.call(tool, args, {"agent_id": agent_id, "permission": permission})
	if agents.has(agent_id):
		agents[agent_id]["status"] = "idle"
	if not (result is Dictionary):
		result = CerberusUtil.ok(result)
	return _finish(tool, agent_id, start, result)


func _finish(tool: String, agent_id: String, start: int, result: Dictionary) -> Dictionary:
	var duration := CerberusUtil.now_ms() - start
	var entry := {
		"time": Time.get_time_string_from_system(),
		"agent": agent_id,
		"tool": tool,
		"ok": bool(result.get("ok", false)),
		"duration_ms": duration,
		"error": String(result.get("error", {}).get("code", "")) if not bool(result.get("ok", false)) else "",
	}
	history.append(entry)
	if history.size() > MAX_HISTORY:
		history = history.slice(history.size() - MAX_HISTORY)
	result["meta"] = {"tool": tool, "agent_id": agent_id, "duration_ms": duration}
	return result


func _find_cmd(tool: String) -> Variant:
	for cmd in _cmds:
		if cmd.has_method(tool):
			return cmd
	return null


func _validate(args: Dictionary, schema: Dictionary) -> String:
	var props: Dictionary = schema.get("properties", {})
	for req in schema.get("required", []):
		if not args.has(req):
			return "falta el argumento obligatorio '%s'" % req
	if bool(schema.get("additionalProperties", true)) == false:
		for k in args.keys():
			if not props.has(k):
				return "argumento no permitido '%s'" % k
	for k in args.keys():
		var spec: Dictionary = props.get(k, {})
		var expected: String = String(spec.get("type", ""))
		if expected.is_empty():
			continue
		var v: Variant = args[k]
		var good := true
		match expected:
			"string": good = v is String or v is StringName
			"integer": good = v is int or (v is float and float(v) == floor(float(v)))
			"number": good = v is int or v is float
			"boolean": good = v is bool
			"array": good = v is Array
			"object": good = v is Dictionary
		if not good:
			return "el argumento '%s' debe ser de tipo %s" % [k, expected]
	return ""


# ------------------------------------------------------------------ locks

func _locked_by(tool: String, args: Dictionary, agent_id: String, mutating: bool) -> Dictionary:
	if not mutating:
		return {}
	var targets: Array = []
	for key in ["path", "scene_path", "script_path", "target_path", "new_path", "output_path"]:
		if args.has(key) and args[key] is String:
			targets.append(str(args[key]))
	# cualquier operación sobre nodos/señales toca la escena editada
	if tool.begins_with("node_") or tool.begins_with("signal_"):
		var root := edited_root()
		if root and root.scene_file_path:
			targets.append(root.scene_file_path)
	for t in targets:
		var holder := locks.holder(t)
		if not holder.is_empty() and holder != agent_id:
			return {"resource": t, "holder": holder}
	return {}


# ------------------------------------------------------------------ helpers

func edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func require_scene() -> Node:
	return edited_root()


func resolve_node(id_or_path: String) -> Node:
	var root := edited_root()
	if root == null:
		return null
	return CerberusUtil.find_node(root, id_or_path)


func snapshot(paths: Array, tool: String, agent_id: String) -> String:
	return changelog.snapshot(paths, tool, agent_id)


func current_agent(session: Dictionary) -> String:
	return session.get("agent_id", "anonymous")


## Rompe las referencias cruzadas cmds <-> dispatcher (RefCounted no libera ciclos).
func clear() -> void:
	for cmd in _cmds:
		cmd.set("d", null)
	_cmds.clear()
	agents.clear()
	history.clear()
