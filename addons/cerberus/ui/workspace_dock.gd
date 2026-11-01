@tool
class_name CerberusWorkspaceDock
extends VBoxContainer
## Panel "Cerberus" en el editor: agentes, locks, ejecuciones y control del bridge.

var plugin: EditorPlugin

var _status: Label
var _agents: Tree
var _locks: Tree
var _activity: ItemList
var _token_label: LineEdit


func _ready() -> void:
	name = "Cerberus"
	add_theme_constant_override("separation", 6)
	_build()
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)
	_refresh()


func _build() -> void:
	var title := Label.new()
	title.text = "CERBERUS AI WORKSPACE"
	title.add_theme_font_size_override("font_size", 14)
	add_child(title)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	var token_row := HBoxContainer.new()
	var token_caption := Label.new()
	token_caption.text = "Token:"
	token_row.add_child(token_caption)
	_token_label = LineEdit.new()
	_token_label.editable = false
	_token_label.secret = true
	_token_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	token_row.add_child(_token_label)
	var copy_btn := Button.new()
	copy_btn.text = "Copiar"
	copy_btn.pressed.connect(_copy_token)
	token_row.add_child(copy_btn)
	add_child(token_row)

	var agents_label := Label.new()
	agents_label.text = "Agentes"
	add_child(agents_label)
	_agents = Tree.new()
	_agents.columns = 4
	_agents.set_column_title(0, "Agente")
	_agents.set_column_title(1, "Permiso")
	_agents.set_column_title(2, "Estado")
	_agents.set_column_title(3, "Tarea")
	_agents.column_titles_visible = true
	_agents.custom_minimum_size = Vector2(0, 120)
	_agents.hide_root = true
	add_child(_agents)

	var locks_label := Label.new()
	locks_label.text = "Locks"
	add_child(locks_label)
	_locks = Tree.new()
	_locks.columns = 3
	_locks.set_column_title(0, "Recurso")
	_locks.set_column_title(1, "Dueño")
	_locks.set_column_title(2, "TTL")
	_locks.column_titles_visible = true
	_locks.custom_minimum_size = Vector2(0, 80)
	_locks.hide_root = true
	add_child(_locks)

	var activity_label := Label.new()
	activity_label.text = "Actividad"
	add_child(activity_label)
	_activity = ItemList.new()
	_activity.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_activity.custom_minimum_size = Vector2(0, 140)
	add_child(_activity)

	var buttons := HBoxContainer.new()
	var rescan := Button.new()
	rescan.text = "Rescan"
	rescan.pressed.connect(func(): EditorInterface.get_resource_filesystem().scan())
	buttons.add_child(rescan)
	var clear := Button.new()
	clear.text = "Limpiar log"
	clear.pressed.connect(func(): plugin.dispatcher.history.clear(); _refresh())
	buttons.add_child(clear)
	add_child(buttons)


func _copy_token() -> void:
	DisplayServer.clipboard_set(plugin.token)
	_token_label.text = plugin.token
	_status.text = "Token copiado al portapapeles."


func _refresh() -> void:
	if plugin == null or plugin.server == null:
		return
	var st: Dictionary = plugin.engine_status()
	_status.text = "%s · Godot %s · puerto %d · %d tools · %d clientes" % [
		st.engine, st.godot_version, st.port, st.tools, plugin.server.client_count()]
	_token_label.text = plugin.token

	_agents.clear()
	var root := _agents.create_item()
	for a in plugin.dispatcher.agents.values():
		var it := _agents.create_item(root)
		it.set_text(0, String(a.name))
		it.set_text(1, String(a.permission))
		it.set_text(2, String(a.status))
		it.set_text(3, String(a.task))

	_locks.clear()
	var lroot := _locks.create_item()
	for l in plugin.dispatcher.locks.list():
		var it := _locks.create_item(lroot)
		it.set_text(0, String(l.resource))
		it.set_text(1, String(l.owner))
		it.set_text(2, "%ds" % (int(l.ttl_remaining_ms) / 1000))

	_activity.clear()
	var hist: Array = plugin.dispatcher.history
	for i in range(hist.size() - 1, max(-1, hist.size() - 40), -1):
		var h: Dictionary = hist[i]
		var mark := "OK " if bool(h.ok) else "ERR"
		_activity.add_item("%s %s %s (%dms)%s" % [
			mark, h.time, String(h.tool), int(h.duration_ms),
			"" if bool(h.ok) else " " + String(h.get("error", ""))])
