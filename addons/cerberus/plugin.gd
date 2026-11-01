@tool
extends EditorPlugin
## Cerberus AI Bridge — punto de entrada del plugin del editor.
##
## Arranca un servidor TCP local que expone las herramientas de Cerberus,
## mantiene el workspace de agentes, los locks y el registro de cambios.
## Todo el estado vive en el editor: los agentes externos sólo hablan JSON.

const PROTOCOL_VERSION := "1.0"
const ENGINE_NAME := "Cerberus Engine"

var specs: Dictionary = {}
var token: String = ""
var protocol_version := PROTOCOL_VERSION
var engine_name := ENGINE_NAME
var started_unix := Time.get_unix_time_from_system()
var _parent_pid := -1
var _parent_watch: Timer
var dispatcher: CerberusDispatcher
var server: CerberusServer
var dock: CerberusWorkspaceDock


func _enter_tree() -> void:
	_load_specs()
	token = _resolve_token()
	dispatcher = CerberusDispatcher.new(self)
	server = CerberusServer.new(self)
	server.name = "CerberusServer"
	add_child(server)
	_start_parent_watch()
	if not server.start(_port()):
		# ocurre al abrir un segundo editor (p. ej. `--export-release`): se desactiva sin romper nada
		push_warning("[Cerberus] puerto %d ocupado; esta instancia funciona sin bridge" % _port())
	_build_dock()


func _exit_tree() -> void:
	if server:
		server.stop()
		server.queue_free()
		server = null
	if dispatcher:
		dispatcher.clear()
		dispatcher = null
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null


## Si el bridge que nos lanzó desaparece, el editor no debe quedar huérfano.
func _start_parent_watch() -> void:
	var env := OS.get_environment("CERBERUS_PARENT_PID")
	if not env.is_valid_int():
		return
	_parent_pid = env.to_int()
	if _parent_pid <= 0:
		return
	_parent_watch = Timer.new()
	_parent_watch.name = "CerberusParentWatch"
	_parent_watch.wait_time = 2.0
	_parent_watch.autostart = true
	_parent_watch.timeout.connect(_check_parent)
	add_child(_parent_watch)


func _check_parent() -> void:
	if _parent_pid <= 0:
		return
	# OS.is_process_running() sólo ve hijos directos; /proc sí ve cualquier PID
	if OS.get_name() == "Linux":
		if DirAccess.dir_exists_absolute("/proc/%d" % _parent_pid):
			return
	elif OS.is_process_running(_parent_pid):
		return
	push_warning("[Cerberus] el bridge (pid %d) terminó; cerrando el editor" % _parent_pid)
	_parent_pid = -1
	var root := EditorInterface.get_edited_scene_root()
	if root and not root.scene_file_path.is_empty():
		EditorInterface.save_scene()
	OS.kill(OS.get_process_id())


# --------------------------------------------------------------------- helpers

func _load_specs() -> void:
	var path := "res://addons/cerberus/tool_specs.json"
	if not FileAccess.file_exists(path):
		push_error("[Cerberus] falta %s (ejecuta scripts/gen_tool_specs.py)" % path)
		specs = {"tools": {}, "permissions": []}
		return
	var txt := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary:
		specs = parsed
	else:
		push_error("[Cerberus] tool_specs.json inválido")


func _port() -> int:
	var env := OS.get_environment("CERBERUS_PORT")
	if env.is_valid_int():
		return env.to_int()
	return int(ProjectSettings.get_setting("cerberus/server/port", 7777))


func _resolve_token() -> String:
	var env := OS.get_environment("CERBERUS_TOKEN")
	if not env.is_empty():
		return env
	var user_path := "user://cerberus_token"
	if FileAccess.file_exists(user_path):
		var stored := FileAccess.get_file_as_string(user_path).strip_edges()
		if not stored.is_empty():
			return stored
	var generated := _random_hex(24)
	var f := FileAccess.open(user_path, FileAccess.WRITE)
	if f:
		f.store_string(generated)
		f.close()
	return generated


func _random_hex(n_chars: int) -> String:
	var out := ""
	while out.length() < n_chars:
		out += "%02x" % randi_range(0, 255)
	return out.substr(0, n_chars)


func _build_dock() -> void:
	if DisplayServer.get_name() == "headless":
		return  # CI: sin UI
	dock = CerberusWorkspaceDock.new()
	dock.name = "Cerberus"
	dock.plugin = self
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	if bool(ProjectSettings.get_setting("cerberus/workspace/auto_open_dock", false)):
		dock.make_visible()


func tool_spec(tool_name: String) -> Dictionary:
	var tools: Dictionary = specs.get("tools", {})
	return tools.get(tool_name, {})


func permission_rank(permission: String) -> int:
	var levels: Array = specs.get("permissions", [])
	return levels.find(permission)


func engine_status() -> Dictionary:
	return {
		"engine": ENGINE_NAME,
		"protocol": PROTOCOL_VERSION,
		"godot_version": Engine.get_version_info().get("string", ""),
		"headless": DisplayServer.get_name() == "headless",
		"platform": OS.get_name(),
		"port": server.port if server else 0,
		"tools": specs.get("tools", {}).size(),
		"edited_scene": _edited_scene_path(),
		"project": ProjectSettings.get_setting("application/config/name", ""),
	}


func _edited_scene_path() -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root and root.scene_file_path:
		return root.scene_file_path
	return ""
