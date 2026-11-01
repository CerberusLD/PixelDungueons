@tool
class_name CerberusProjectCmds
extends RefCounted
## Ajustes de proyecto, input map, autoloads y señales — siempre a través del editor.

var d: CerberusDispatcher


func _init(dispatcher: CerberusDispatcher) -> void:
	d = dispatcher


# ------------------------------------------------------------------ settings

func project_settings_get(args: Dictionary, session: Dictionary) -> Dictionary:
	var key := String(args.get("key", ""))
	var section := String(args.get("section", ""))
	if not key.is_empty():
		if not ProjectSettings.has_setting(key):
			return CerberusUtil.fail("not_found", "el ajuste '%s' no existe" % key)
		var info := {}
		for p in ProjectSettings.get_property_list():
			if String(p.get("name", "")) == key:
				info = p
				break
		return CerberusUtil.ok({
			"key": key,
			"value": CerberusUtil.variant_to_json(ProjectSettings.get_setting(key)),
			"type": int(info.get("type", TYPE_NIL)),
		})
	if section.is_empty():
		return CerberusUtil.fail("invalid_args", "pasa 'key' o 'section'")
	var out := {}
	for p in ProjectSettings.get_property_list():
		var n := String(p.get("name", ""))
		if n.begins_with(section + "/") and int(p.get("usage", 0)) & PROPERTY_USAGE_STORAGE:
			out[n] = CerberusUtil.variant_to_json(ProjectSettings.get_setting(n))
	return CerberusUtil.ok({"section": section, "settings": out, "count": out.size()})


func project_settings_set(args: Dictionary, session: Dictionary) -> Dictionary:
	var key := String(args.key)
	var value: Variant = args.value
	var existing_type := TYPE_NIL
	var existed := ProjectSettings.has_setting(key)
	if existed:
		existing_type = typeof(ProjectSettings.get_setting(key))
		value = CerberusUtil.convert_value(value, existing_type)
	elif value is Dictionary and value.has("type") and value.has("value"):
		value = CerberusUtil.convert_value(value.value, int(value.type))
	var tx := d.snapshot(["res://project.godot"], "project_settings_set", d.current_agent(session))
	ProjectSettings.set_setting(key, value)
	var err := ProjectSettings.save()
	if err != OK:
		return CerberusUtil.fail("save_failed", error_string(err))
	return CerberusUtil.ok({
		"key": key,
		"value": CerberusUtil.variant_to_json(ProjectSettings.get_setting(key)),
		"existed": existed,
		"transaction": tx,
	})


# ------------------------------------------------------------------ input map

func input_map_get(args: Dictionary, session: Dictionary) -> Dictionary:
	var action := String(args.get("action", ""))
	var names: Array = []
	if action.is_empty():
		names = InputMap.get_actions()
		var filtered: Array = []
		for n in names:
			if not String(n).begins_with("ui_"):
				filtered.append(String(n))
		return CerberusUtil.ok({"actions": filtered, "count": filtered.size()})
	if not InputMap.has_action(action):
		return CerberusUtil.fail("not_found", "no existe la acción '%s'" % action)
	var events: Array = []
	for e in InputMap.action_get_events(action):
		events.append(_event_to_json(e))
	return CerberusUtil.ok({"action": action, "deadzone": InputMap.action_get_deadzone(action), "events": events})


func input_map_set(args: Dictionary, session: Dictionary) -> Dictionary:
	var action := String(args.action)
	var events_raw: Variant = args.events
	var events: Array = []
	if events_raw is Dictionary:
		events = [events_raw]
	elif events_raw is Array:
		events = events_raw
	else:
		return CerberusUtil.fail("invalid_args", "events debe ser objeto o array de objetos")
	var tx := d.snapshot(["res://project.godot"], "input_map_set", d.current_agent(session))
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	InputMap.action_erase_events(action)
	var parsed: Array = []
	for raw in events:
		var ev: Variant = _json_to_event(raw)
		if ev == null:
			continue
		InputMap.action_add_event(action, ev)
		parsed.append(_event_to_json(ev))
	if args.has("deadzone"):
		InputMap.action_set_deadzone(action, float(args.deadzone))
	ProjectSettings.save()
	return CerberusUtil.ok({"action": action, "events": parsed, "transaction": tx})


func _event_to_json(e: InputEvent) -> Dictionary:
	if e is InputEventKey:
		return {"type": "key", "keycode": OS.get_keycode_string(e.keycode), "physical": OS.get_keycode_string(e.physical_keycode)}
	if e is InputEventMouseButton:
		return {"type": "mouse_button", "button": e.button_index}
	if e is InputEventJoypadButton:
		return {"type": "joypad_button", "button": e.button_index}
	if e is InputEventJoypadMotion:
		return {"type": "joypad_motion", "axis": e.axis, "axis_value": e.axis_value}
	if e is InputEventAction:
		return {"type": "action", "action": e.action}
	return {"type": e.get_class()}


func _json_to_event(raw: Variant) -> Variant:
	if not (raw is Dictionary):
		return null
	var kind := String(raw.get("type", "key"))
	match kind:
		"key":
			var ev := InputEventKey.new()
			ev.keycode = OS.find_keycode_from_string(String(raw.get("keycode", "")))
			ev.physical_keycode = OS.find_keycode_from_string(String(raw.get("physical", raw.get("keycode", ""))))
			return ev
		"mouse_button":
			var ev := InputEventMouseButton.new()
			ev.button_index = int(raw.get("button", 1))
			return ev
		"joypad_button":
			var ev := InputEventJoypadButton.new()
			ev.button_index = int(raw.get("button", 0))
			return ev
		"joypad_motion":
			var ev := InputEventJoypadMotion.new()
			ev.axis = int(raw.get("axis", 0))
			ev.axis_value = float(raw.get("axis_value", 1.0))
			return ev
		"action":
			var ev := InputEventAction.new()
			ev.action = String(raw.get("action", ""))
			return ev
	return null


# ------------------------------------------------------------------ autoloads

func autoload_list(args: Dictionary, session: Dictionary) -> Dictionary:
	var out: Array = []
	for p in ProjectSettings.get_property_list():
		var n := String(p.get("name", ""))
		if n.begins_with("autoload/") and int(p.get("usage", 0)) & PROPERTY_USAGE_STORAGE:
			var value := String(ProjectSettings.get_setting(n))
			out.append({
				"name": n.trim_prefix("autoload/"),
				"path": value.trim_prefix("*"),
				"singleton": value.begins_with("*"),
				"key": n,
			})
	return CerberusUtil.ok({"autoloads": out, "count": out.size()})


func autoload_set(args: Dictionary, session: Dictionary) -> Dictionary:
	var name := String(args.name)
	var key := "autoload/" + name
	var tx := d.snapshot(["res://project.godot"], "autoload_set", d.current_agent(session))
	if bool(args.get("remove", false)):
		ProjectSettings.set_setting(key, null)
		ProjectSettings.save()
		return CerberusUtil.ok({"removed": name, "transaction": tx})
	var path := CerberusUtil.to_res(String(args.get("path", "")))
	if path.is_empty() or not FileAccess.file_exists(path):
		return CerberusUtil.fail("not_found", "el script del autoload no existe: %s" % path)
	var singleton := bool(args.get("singleton", true))
	ProjectSettings.set_setting(key, ("*" if singleton else "") + path)
	var err := ProjectSettings.save()
	if err != OK:
		return CerberusUtil.fail("save_failed", error_string(err))
	return CerberusUtil.ok({"name": name, "path": path, "singleton": singleton, "transaction": tx})


# ------------------------------------------------------------------ señales

func signal_list(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var out: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var declared: Array = []
		for s in n.get_signal_list():
			declared.append(String(s.name))
		var connections: Array = []
		for s in declared:
			for c in n.get_signal_connection_list(s):
				var callable: Callable = c.callable
				connections.append({
					"signal": s,
					"target": callable.get_object().get_path() if callable.get_object() else "",
					"target_id": CerberusUtil.ensure_id(callable.get_object()) if callable.get_object() is Node else "",
					"method": callable.get_method(),
					"flags": c.flags,
				})
		out.append({
			"node_id": CerberusUtil.ensure_id(n),
			"path": str(root.get_path_to(n)) if n != root else ".",
			"signals": declared,
			"connections": connections,
		})
		for c in n.get_children():
			stack.push_back(c)
	return CerberusUtil.ok({"nodes": out})


func signal_connect(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var from: Node = d.resolve_node(String(args.from_id))
	var to: Node = d.resolve_node(String(args.to_id))
	if from == null or to == null:
		return CerberusUtil.fail("node_not_found", "origen o destino no existe")
	var sig := String(args.signal)
	var method := String(args.method)
	var exists := false
	for s in from.get_signal_list():
		if String(s.name) == sig:
			exists = true
			break
	if not exists:
		return CerberusUtil.fail("unknown_signal", "%s no declara la señal '%s'" % [from.get_class(), sig])
	if not to.has_method(method):
		return CerberusUtil.fail("unknown_method", "%s no tiene el método '%s'" % [to.get_class(), method])
	var flags := int(args.get("flags", CONNECT_PERSIST))
	var callable := Callable(to, method)
	if from.is_connected(sig, callable):
		return CerberusUtil.ok({"connected": true, "already": true})
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Cerberus: conectar %s" % sig)
	ur.add_do_method(from, "connect", sig, callable, flags)
	ur.add_undo_method(from, "disconnect", sig, callable)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return CerberusUtil.ok({"connected": true, "signal": sig, "method": method})
