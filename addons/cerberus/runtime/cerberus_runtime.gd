extends Node
## Agente de runtime Cerberus.
##
## Se inyecta como autoload durante `project_run` y abre un canal TCP con el
## bridge. Permite inspeccionar el árbol vivo, capturar imágenes reales del
## render, ejecutar código, pausar y leer estado del motor.

const PROTO: String = "1.0"

var _sock := StreamPeerTCP.new()
var _buffer := ""
var _port := 0
var _connected := false
var _frames := 0
var _started_ms := 0
var _step_budget := 0
var _paused_by_agent := false
var _last_fps := 0.0
var _seq := 0
var _pending: Dictionary = {}
var _parent_pid: int = -1
var _parent_timer: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "CerberusRuntime"
	_started_ms = Time.get_ticks_msec()
	_port = int(OS.get_environment("CERBERUS_RUNTIME_PORT"))
	var parent := OS.get_environment("CERBERUS_PARENT_PID")
	if parent.is_valid_int():
		_parent_pid = parent.to_int()
	if _port <= 0:
		set_process(false)
		return
	_connect()


func _connect() -> void:
	if _port <= 0:
		return
	var err := _sock.connect_to_host("127.0.0.1", _port)
	if err != OK:
		print("[CerberusRT] no se pudo conectar al bridge: ", err)
		return
	_connected = true
	print("[CerberusRT] conectado al bridge en 127.0.0.1:%d" % _port)


func _process(delta: float) -> void:
	_frames += 1
	if _parent_pid > 0:
		_parent_timer += delta
		if _parent_timer >= 3.0:
			_parent_timer = 0.0
			var alive := OS.is_process_running(_parent_pid)
			if OS.get_name() == "Linux":
				alive = DirAccess.dir_exists_absolute("/proc/%d" % _parent_pid)
			if not alive:
				print("[CerberusRT] el bridge terminó; cerrando el juego")
				get_tree().quit()
				OS.kill(OS.get_process_id())
	_last_fps = Engine.get_frames_per_second()
	if _step_budget > 0:
		_step_budget -= 1
		if _step_budget == 0 and _paused_by_agent:
			get_tree().paused = true
	if not _connected:
		return
	_sock.poll()
	var status := _sock.get_status()
	if status != StreamPeerTCP.STATUS_CONNECTED:
		return
	var available := _sock.get_available_bytes()
	if available > 0:
		var chunk: Array = _sock.get_partial_data(available)
		if chunk[0] == OK:
			_buffer += (chunk[1] as PackedByteArray).get_string_from_utf8()
			_consume()


func _consume() -> void:
	while true:
		var idx := _buffer.find("\n")
		if idx < 0:
			break
		var line := _buffer.substr(0, idx)
		_buffer = _buffer.substr(idx + 1)
		if line.strip_edges().is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			_dispatch(parsed)


func _dispatch(req: Dictionary) -> void:
	var cmd := String(req.get("cmd", ""))
	var args: Dictionary = req.get("args", {}) if req.get("args") is Dictionary else {}
	var rid: Variant = req.get("id", 0)
	match cmd:
		"status":
			_reply(rid, _status())
		"screenshot":
			_screenshot(rid, args)
		"inspect":
			_reply(rid, _inspect(args))
		"eval":
			_reply(rid, _eval(String(args.get("code", ""))))
		"pause":
			_pause(rid)
		"resume":
			_resume(rid)
		"step":
			_step(rid, int(args.get("frames", 1)))
		"vars":
			_reply(rid, _vars(String(args.get("node_path", ""))))
		"profile":
			_reply(rid, _profile())
		"quit":
			_reply(rid, {"quitting": true})
			await get_tree().process_frame
			get_tree().quit()
		_:
			_error(rid, "unknown_command", "comando desconocido: %s" % cmd)


# ------------------------------------------------------------------ comandos

func _status() -> Dictionary:
	var root := get_tree().root
	return {
		"fps": _last_fps,
		"frames": _frames,
		"uptime_s": (Time.get_ticks_msec() - _started_ms) / 1000.0,
		"paused": get_tree().paused,
		"paused_by_agent": _paused_by_agent,
		"scene": get_tree().current_scene.scene_file_path if get_tree().current_scene else "",
		"current_scene": str(get_tree().current_scene.name) if get_tree().current_scene else "",
		"node_count": _count_nodes(root),
		"viewport": {"w": root.size.x, "h": root.size.y},
		"renderer": RenderingServer.get_video_adapter_name(),
		"display": DisplayServer.get_name(),
		"version": Engine.get_version_info().get("string", ""),
		"headless": DisplayServer.get_name() == "headless",
	}


func _screenshot(rid: Variant, args: Dictionary) -> void:
	await RenderingServer.frame_post_draw
	var vp := get_viewport()
	if vp == null:
		_error(rid, "no_viewport", "sin viewport")
		return
	var tex := vp.get_texture()
	if tex == null:
		_error(rid, "no_texture", "sin textura de viewport")
		return
	var img: Image = tex.get_image()
	if img == null:
		_error(rid, "no_image", "no se pudo leer la imagen del viewport")
		return
	var w := int(args.get("width", 0))
	var h := int(args.get("height", 0))
	if w > 0 and h > 0:
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)
	var path := String(args.get("path", ""))
	if path.is_empty():
		var dir := "user://cerberus_screenshots"
		DirAccess.make_dir_recursive_absolute(dir)
		path = "%s/shot_%d.png" % [dir, Time.get_ticks_msec()]
	var err := img.save_png(path)
	if err != OK:
		_error(rid, "save_failed", "no se pudo guardar PNG: %s" % error_string(err))
		return
	_reply(rid, {
		"path": ProjectSettings.globalize_path(path),
		"res_path": path,
		"width": img.get_width(),
		"height": img.get_height(),
		"bytes": _file_size(path),
		"headless": DisplayServer.get_name() == "headless",
		"warning": "" if DisplayServer.get_name() != "headless" else
			"el juego corre con --headless (driver dummy): la imagen no contiene el render real",
	})


func _inspect(args: Dictionary) -> Dictionary:
	var root := get_tree().root
	var depth := int(args.get("depth", -1))
	var start := root
	var node_path := String(args.get("node_path", ""))
	if not node_path.is_empty():
		var found := root.get_node_or_null(NodePath(node_path))
		if found == null:
			return {"error": "node no encontrado: %s" % node_path}
		start = found
	return {"tree": _describe(start, depth), "node_count": _count_nodes(root)}


func _vars(node_path: String) -> Dictionary:
	var root := get_tree().root
	var node: Node = root
	if not node_path.is_empty():
		node = root.get_node_or_null(NodePath(node_path))
		if node == null:
			return {"error": "node no encontrado: %s" % node_path}
	var props := {}
	for p in node.get_property_list():
		var usage: int = int(p.get("usage", 0))
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE or usage & PROPERTY_USAGE_STORAGE:
			var n := String(p.get("name", ""))
			props[n] = _to_json(node.get(n))
	return {
		"node": str(node.get_path()),
		"type": node.get_class(),
		"script": node.get_script().resource_path if node.get_script() else "",
		"properties": props,
	}


## Monitorización de rendimiento del juego en ejecución.
func _profile() -> Dictionary:
	var mem_static := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	return {
		"fps": Engine.get_frames_per_second(),
		"frame_time_ms": float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0,
		"physics_time_ms": float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0,
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"memory_static_mb": mem_static,
		"video_mem_mb": float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0,
		"texture_mem_mb": float(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)) / 1048576.0,
		"nodes_in_tree": get_tree().get_node_count(),
		"uptime_s": (Time.get_ticks_msec() - _started_ms) / 1000.0,
		"viewport": {"w": get_tree().root.size.x, "h": get_tree().root.size.y},
	}


func _pause(rid: Variant) -> void:
	_paused_by_agent = true
	get_tree().paused = true
	_reply(rid, {"paused": true})


func _resume(rid: Variant) -> void:
	_paused_by_agent = false
	_step_budget = 0
	get_tree().paused = false
	_reply(rid, {"paused": false})


func _step(rid: Variant, frames: int) -> void:
	if frames <= 0:
		frames = 1
	_paused_by_agent = true
	get_tree().paused = false
	_step_budget = frames
	_reply(rid, {"stepping_frames": frames})


func _eval(code: String) -> Dictionary:
	if code.strip_edges().is_empty():
		return {"error": "code vacío"}
	var gd := GDScript.new()
	var indented := ""
	var lines := code.split("\n")
	if lines.size() == 1:
		# expresión simple: se devuelve automáticamente
		indented = "	return " + lines[0] + "\n"
	else:
		for line in lines:
			indented += "	" + line + "\n"
	gd.source_code = "extends RefCounted\nvar rt\nfunc __run():\n" + indented
	var err := gd.reload()
	if err != OK:
		return {"error": "no compila", "code": err}
	var inst: Variant = gd.new()
	if inst == null:
		return {"error": "no se pudo instanciar"}
	inst.rt = self
	var result: Variant = inst.__run()
	return {"result": _to_json(result), "type": type_string(typeof(result))}


# ------------------------------------------------------------------ árbol vivo

func _describe(node: Node, depth: int) -> Dictionary:
	var d := {
		"name": String(node.name),
		"path": str(node.get_path()),
		"type": node.get_class(),
		"children": node.get_child_count(),
	}
	if node is CanvasItem:
		d["visible"] = node.visible
	if node is Node2D:
		d["position"] = {"x": node.global_position.x, "y": node.global_position.y}
		d["rotation"] = node.global_rotation
		d["scale"] = {"x": node.global_scale.x, "y": node.global_scale.y}
	if node is Node3D:
		d["position"] = {"x": node.global_position.x, "y": node.global_position.y, "z": node.global_position.z}
	if node is Control:
		d["rect"] = {"x": node.global_position.x, "y": node.global_position.y, "w": node.size.x, "h": node.size.y}
		if node is Label or node is Button or node is LineEdit:
			d["text"] = node.text
	var scr := node.get_script()
	if scr is Script:
		d["script"] = scr.resource_path
	if not node.get_groups().is_empty():
		d["groups"] = node.get_groups()
	if depth == 0:
		return d
	var kids: Array = []
	for c in node.get_children():
		kids.append(_describe(c, depth - 1 if depth > 0 else -1))
	if not kids.is_empty():
		d["nodes"] = kids
	return d


func _count_nodes(node: Node) -> int:
	var n := 1
	for c in node.get_children():
		n += _count_nodes(c)
	return n


func _to_json(v: Variant) -> Variant:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_VECTOR2:
			return {"x": v.x, "y": v.y}
		TYPE_VECTOR3:
			return {"x": v.x, "y": v.y, "z": v.z}
		TYPE_COLOR:
			return {"r": v.r, "g": v.g, "b": v.b, "a": v.a, "hex": v.to_html()}
		TYPE_ARRAY:
			var a: Array = []
			for e in v:
				a.append(_to_json(e))
			return a
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k in v:
				d[str(k)] = _to_json(v[k])
			return d
		TYPE_OBJECT:
			if v == null:
				return null
			if v is Node:
				return {"node": str(v.get_path()), "type": v.get_class()}
			if v is Resource:
				return v.resource_path if v.resource_path else {"class": v.get_class()}
			return {"class": v.get_class()}
		_:
			return str(v)


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return size


# ------------------------------------------------------------------ protocolo

func _reply(rid: Variant, data: Variant) -> void:
	_send({"id": rid, "ok": true, "data": data})


func _error(rid: Variant, code: String, message: String, details: Dictionary = {}) -> void:
	_send({"id": rid, "ok": false, "error": {"code": code, "message": message, "details": details}})


func _send(payload: Dictionary) -> void:
	if not _connected:
		return
	payload["rt"] = PROTO
	_sock.put_data((JSON.stringify(payload) + "\n").to_utf8_buffer())
