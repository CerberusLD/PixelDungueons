@tool
class_name CerberusUtil
extends RefCounted
## Utilidades compartidas: ids estables, serialización de Variant <-> JSON y árboles de nodos.

const ID_META := "cerberus_id"


# ----------------------------------------------------------------------- ids

static func new_id(prefix: String = "n") -> String:
	return "%s_%08x%04x" % [prefix, randi(), randi() & 0xffff]


static func ensure_id(node: Node) -> String:
	var existing := str(node.get_meta(ID_META, ""))
	if not existing.is_empty():
		return existing
	var fresh := new_id()
	node.set_meta(ID_META, fresh)
	return fresh


static func build_index(root: Node) -> Dictionary:
	var out: Dictionary = {}
	if root == null:
		return out
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out[ensure_id(n)] = n
		for c in n.get_children():
			stack.push_back(c)
	return out


static func find_node(root: Node, id_or_path: String) -> Node:
	if root == null:
		return null
	if id_or_path.is_empty():
		return root
	var idx := build_index(root)
	if idx.has(id_or_path):
		return idx[id_or_path]
	# Aceptar rutas absolutas, relativas a la raíz y nombres con "/".
	var direct := root.get_node_or_null(NodePath(id_or_path))
	if direct:
		return direct
	if root.find_child(id_or_path, true, false):
		return root.find_child(id_or_path, true, false)
	return null


# ------------------------------------------------------------------- variantes

static func variant_to_json(v: Variant) -> Variant:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_STRING_NAME:
			return String(v)
		TYPE_VECTOR2:
			return {"x": v.x, "y": v.y}
		TYPE_VECTOR2I:
			return {"x": v.x, "y": v.y}
		TYPE_VECTOR3:
			return {"x": v.x, "y": v.y, "z": v.z}
		TYPE_VECTOR3I:
			return {"x": v.x, "y": v.y, "z": v.z}
		TYPE_VECTOR4:
			return {"x": v.x, "y": v.y, "z": v.z, "w": v.w}
		TYPE_COLOR:
			return {"r": v.r, "g": v.g, "b": v.b, "a": v.a, "hex": v.to_html()}
		TYPE_RECT2:
			return {"position": variant_to_json(v.position), "size": variant_to_json(v.size)}
		TYPE_TRANSFORM2D:
			return {"origin": variant_to_json(v.origin), "x": variant_to_json(v.x), "y": variant_to_json(v.y)}
		TYPE_TRANSFORM3D:
			return {"origin": variant_to_json(v.origin)}
		TYPE_QUATERNION:
			return {"x": v.x, "y": v.y, "z": v.z, "w": v.w}
		TYPE_NODE_PATH:
			return String(v)
		TYPE_ARRAY:
			var arr: Array = []
			for e in v:
				arr.append(variant_to_json(e))
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k in v:
				d[str(k)] = variant_to_json(v[k])
			return d
		TYPE_OBJECT:
			if v == null:
				return null
			if v is Resource:
				if v.resource_path:
					return v.resource_path
				return {"class": v.get_class()}
			if v is Node:
				return {"node": ensure_id(v), "path": str(v.get_path())}
			return {"class": v.get_class()}
		TYPE_PACKED_STRING_ARRAY:
			var a1: Array = []
			for e in v:
				a1.append(String(e))
			return a1
		_:
			return str(v)


static func property_types(node: Object) -> Dictionary:
	var types := {}
	for p in node.get_property_list():
		var usage: int = p.get("usage", 0)
		if usage & PROPERTY_USAGE_STORAGE:
			types[str(p.get("name"))] = int(p.get("type", TYPE_NIL))
	return types


static func convert_value(raw: Variant, declared_type: int) -> Variant:
	match declared_type:
		TYPE_VECTOR2:
			if raw is Dictionary:
				return Vector2(float(raw.get("x", 0.0)), float(raw.get("y", 0.0)))
			if raw is Array and raw.size() >= 2:
				return Vector2(float(raw[0]), float(raw[1]))
		TYPE_VECTOR2I:
			if raw is Dictionary:
				return Vector2i(int(raw.get("x", 0)), int(raw.get("y", 0)))
			if raw is Array and raw.size() >= 2:
				return Vector2i(int(raw[0]), int(raw[1]))
		TYPE_VECTOR3:
			if raw is Dictionary:
				return Vector3(float(raw.get("x", 0.0)), float(raw.get("y", 0.0)), float(raw.get("z", 0.0)))
		TYPE_VECTOR3I:
			if raw is Dictionary:
				return Vector3i(int(raw.get("x", 0)), int(raw.get("y", 0)), int(raw.get("z", 0)))
		TYPE_COLOR:
			if raw is String:
				return Color.from_string(raw, Color.WHITE)
			if raw is Dictionary:
				return Color(float(raw.get("r", 0.0)), float(raw.get("g", 0.0)), float(raw.get("b", 0.0)), float(raw.get("a", 1.0)))
			if raw is Array:
				var c := Color(0, 0, 0, 1)
				if raw.size() > 0: c.r = float(raw[0])
				if raw.size() > 1: c.g = float(raw[1])
				if raw.size() > 2: c.b = float(raw[2])
				if raw.size() > 3: c.a = float(raw[3])
				return c
		TYPE_RECT2:
			if raw is Dictionary and raw.has("position") and raw.has("size"):
				return Rect2(Vector2(float(raw.position.get("x", 0)), float(raw.position.get("y", 0))),
					Vector2(float(raw.size.get("x", 0)), float(raw.size.get("y", 0))))
		TYPE_NODE_PATH:
			if raw is String:
				return NodePath(raw)
		TYPE_STRING:
			return str(raw)
		TYPE_STRING_NAME:
			return StringName(str(raw))
		TYPE_INT:
			if raw is bool:
				return 1 if raw else 0
			if raw is float or raw is int or (raw is String and String(raw).is_valid_int()):
				return int(raw)
		TYPE_FLOAT:
			if raw is int or raw is float or (raw is String and String(raw).is_valid_float()):
				return float(raw)
		TYPE_BOOL:
			if raw is String:
				return String(raw).to_lower() in ["true", "1", "yes", "on"]
			return bool(raw)
		TYPE_ARRAY:
			if raw is Array:
				return raw.duplicate(true)
		TYPE_DICTIONARY:
			if raw is Dictionary:
				return raw.duplicate(true)
		TYPE_OBJECT:
			if raw == null:
				return null
			if raw is String:
				return load(raw)
			if raw is Dictionary and raw.has("class"):
				var made: Variant = ClassDB.instantiate(str(raw["class"]))
				return made
	return raw


static func describe_node(node: Node, root: Node) -> Dictionary:
	var d := {
		"id": ensure_id(node),
		"name": String(node.name),
		"type": node.get_class(),
		"path": str(root.get_path_to(node)) if root and node != root else ".",
		"children": node.get_child_count(),
	}
	var scr := node.get_script()
	if scr is Script and scr.resource_path:
		d["script"] = scr.resource_path
	if node is CanvasItem:
		d["visible"] = node.visible
	if node is Node2D:
		d["position"] = {"x": node.position.x, "y": node.position.y}
		d["rotation"] = node.rotation
		d["scale"] = {"x": node.scale.x, "y": node.scale.y}
	if node is Node3D:
		d["position"] = {"x": node.position.x, "y": node.position.y, "z": node.position.z}
	if node is Control:
		d["rect"] = {"x": node.position.x, "y": node.position.y, "w": node.size.x, "h": node.size.y}
		if node is Label or node is Button:
			d["text"] = node.text
	if not node.get_groups().is_empty():
		d["groups"] = node.get_groups()
	return d


static func subtree(node: Node, root: Node, depth: int = -1, include_properties: bool = false) -> Dictionary:
	var d := describe_node(node, root)
	if include_properties:
		var props := {}
		var types := property_types(node)
		for name in types.keys():
			if name in ["script", "owner", "position", "rotation", "scale", "visible"]:
				continue
			props[name] = variant_to_json(node.get(name))
		d["properties"] = props
	if depth == 0:
		return d
	var kids: Array = []
	for c in node.get_children():
		kids.append(subtree(c, root, depth - 1 if depth > 0 else -1, include_properties))
	if not kids.is_empty():
		d["children_nodes"] = kids
	return d


# ----------------------------------------------------------------------- rutas

static func to_abs(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path


static func to_res(path: String) -> String:
	if path.begins_with("res://"):
		return path
	var root := ProjectSettings.globalize_path("res://").simplify_path()
	var abs := path.simplify_path()
	if abs.begins_with(root):
		return "res://" + abs.substr(root.length()).trim_prefix("/")
	return path


static func file_size(path: String) -> int:
	var f := FileAccess.open(to_abs(path) if not path.begins_with("res://") else path, FileAccess.READ)
	if f == null:
		return -1
	var size := f.get_length()
	f.close()
	return size


static func ensure_dir(res_dir: String) -> void:
	var dir := DirAccess.open("res://")
	if dir and not dir.dir_exists(res_dir.trim_prefix("res://")):
		dir.make_dir_recursive(res_dir.trim_prefix("res://"))


static func now_ms() -> int:
	return Time.get_ticks_msec()


# ------------------------------------------------------------------ respuestas

static func ok(data: Variant = {}) -> Dictionary:
	return {"ok": true, "data": data}


static func fail(code: String, message: String, details: Dictionary = {}) -> Dictionary:
	return {"ok": false, "error": {"code": code, "message": message, "details": details}}

