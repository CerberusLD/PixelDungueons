@tool
class_name CerberusNodeCmds
extends RefCounted
## Herramientas de nodo con soporte de undo/redo del editor.

var d: CerberusDispatcher


func _init(dispatcher: CerberusDispatcher) -> void:
	d = dispatcher


# ------------------------------------------------------------------ creación

func node_create(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada; usa scene_open/scene_create")
	var type := String(args.type)
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Node"):
		return CerberusUtil.fail("invalid_type", "tipo de nodo desconocido: %s" % type)
	var parent: Node = d.resolve_node(String(args.get("parent_id", ""))) if args.has("parent_id") else root
	if parent == null:
		return CerberusUtil.fail("parent_not_found", "no existe el padre '%s'" % args.get("parent_id", ""))
	if parent.is_inside_tree() == false:
		return CerberusUtil.fail("parent_detached", "el padre no está en el árbol")
	var node: Node = ClassDB.instantiate(type)
	if node == null:
		return CerberusUtil.fail("invalid_type", "no se pudo instanciar %s (¿clase abstracta?)" % type)
	var name := String(args.get("name", ""))
	node.name = name if not name.is_empty() else type
	CerberusUtil.ensure_id(node)

	var applied: Array = []
	var unknown: Array = []
	var props: Dictionary = args.get("properties", {})
	for key in props.keys():
		var ok := _apply_property(node, String(key), props[key], applied, unknown)
		if not ok:
			node.free()
			return CerberusUtil.fail("invalid_property", "propiedad inválida: %s" % key)

	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Cerberus: crear %s" % type)
	ur.add_do_method(parent, "add_child", node, true)
	ur.add_do_method(node, "set_owner", root)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return CerberusUtil.ok({
		"node": CerberusUtil.describe_node(node, root),
		"applied": applied,
		"unknown_properties": unknown,
	})


func node_duplicate(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var src: Node = d.resolve_node(String(args.node_id))
	if src == null:
		return CerberusUtil.fail("node_not_found", "no existe el nodo '%s'" % args.node_id)
	if src == root:
		return CerberusUtil.fail("invalid_target", "no se puede duplicar la raíz de la escena")
	var copy: Node = src.duplicate()
	if args.has("name"):
		copy.name = String(args.name)
	_regenerate_ids(copy)
	var parent := src.get_parent()
	var idx := src.get_index()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Cerberus: duplicar nodo")
	ur.add_do_method(parent, "add_child", copy, true)
	ur.add_do_method(parent, "move_child", copy, idx + 1)
	ur.add_do_method(copy, "set_owner", root)
	ur.add_do_reference(copy)
	ur.add_undo_method(parent, "remove_child", copy)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return CerberusUtil.ok({"node": CerberusUtil.describe_node(copy, root)})


func node_delete(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var node: Node = d.resolve_node(String(args.node_id))
	if node == null:
		return CerberusUtil.fail("node_not_found", "no existe el nodo '%s'" % args.node_id)
	if node == root:
		return CerberusUtil.fail("invalid_target", "no se puede eliminar la raíz; cierra la escena")
	var parent := node.get_parent()
	var idx := node.get_index()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Cerberus: eliminar nodo")
	ur.add_do_method(parent, "remove_child", node)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "add_child", node, true)
	ur.add_undo_method(parent, "move_child", node, idx)
	ur.add_undo_reference(node)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return CerberusUtil.ok({"deleted": true, "node_id": String(node.get_meta(CerberusUtil.ID_META, ""))})


func node_reparent(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var node: Node = d.resolve_node(String(args.node_id))
	var new_parent: Node = d.resolve_node(String(args.new_parent_id))
	if node == null:
		return CerberusUtil.fail("node_not_found", "no existe el nodo '%s'" % args.node_id)
	if new_parent == null:
		return CerberusUtil.fail("parent_not_found", "no existe el padre '%s'" % args.new_parent_id)
	if node == root:
		return CerberusUtil.fail("invalid_target", "no se puede mover la raíz")
	if node.is_ancestor_of(new_parent):
		return CerberusUtil.fail("invalid_target", "no se puede mover un nodo dentro de sí mismo")
	var old_parent := node.get_parent()
	var old_idx := node.get_index()
	var keep := bool(args.get("keep_global_transform", true))
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Cerberus: reparentar nodo")
	ur.add_do_method(node, "reparent", new_parent, keep)
	ur.add_do_method(node, "set_owner", root)
	ur.add_undo_method(node, "reparent", old_parent, keep)
	ur.add_undo_method(old_parent, "move_child", node, old_idx)
	ur.add_undo_method(node, "set_owner", root)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return CerberusUtil.ok({"node": CerberusUtil.describe_node(node, root)})


# ------------------------------------------------------------------ propiedades

func node_set_property(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var node: Node = d.resolve_node(String(args.node_id))
	if node == null:
		return CerberusUtil.fail("node_not_found", "no existe el nodo '%s'" % args.node_id)
	var props: Dictionary = args.properties
	if props.is_empty():
		return CerberusUtil.fail("invalid_args", "properties vacío")
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Cerberus: propiedades de %s" % node.name)
	var applied: Array = []
	var unknown: Array = []
	var types := CerberusUtil.property_types(node)
	for key in props.keys():
		var k := String(key)
		if not types.has(k):
			unknown.append(k)
			continue
		var old_value: Variant = node.get(k)
		var new_value: Variant = CerberusUtil.convert_value(props[key], int(types[k]))
		ur.add_do_method(node, "set", k, new_value)
		ur.add_undo_method(node, "set", k, old_value)
		applied.append({"property": k, "old": CerberusUtil.variant_to_json(old_value), "new": CerberusUtil.variant_to_json(new_value)})
	if applied.is_empty():
		return CerberusUtil.fail("invalid_property", "ninguna propiedad existe en %s" % node.get_class(), {"unknown": unknown})
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return CerberusUtil.ok({"node_id": CerberusUtil.ensure_id(node), "applied": applied, "unknown_properties": unknown})


func node_get_property(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var node: Node = d.resolve_node(String(args.node_id))
	if node == null:
		return CerberusUtil.fail("node_not_found", "no existe el nodo '%s'" % args.node_id)
	var prop := String(args.get("property", ""))
	if not prop.is_empty():
		var types := CerberusUtil.property_types(node)
		if not types.has(prop):
			return CerberusUtil.fail("invalid_property", "no existe la propiedad '%s'" % prop, {"available": types.keys()})
		return CerberusUtil.ok({"node_id": CerberusUtil.ensure_id(node), "property": prop, "value": CerberusUtil.variant_to_json(node.get(prop))})
	var all := {}
	for k in CerberusUtil.property_types(node).keys():
		all[k] = CerberusUtil.variant_to_json(node.get(k))
	return CerberusUtil.ok({"node_id": CerberusUtil.ensure_id(node), "properties": all})


func node_get_children(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var node: Node = d.resolve_node(String(args.node_id))
	if node == null:
		return CerberusUtil.fail("node_not_found", "no existe el nodo '%s'" % args.node_id)
	var kids: Array = []
	for c in node.get_children():
		kids.append(CerberusUtil.describe_node(c, root))
	return CerberusUtil.ok({"node_id": CerberusUtil.ensure_id(node), "children": kids})


func node_attach_script(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var node: Node = d.resolve_node(String(args.node_id))
	if node == null:
		return CerberusUtil.fail("node_not_found", "no existe el nodo '%s'" % args.node_id)
	var path := ""
	var raw_script: Variant = args.get("script_path")
	if raw_script is String:
		path = String(raw_script)
	var script: Script = null
	if not path.is_empty():
		path = CerberusUtil.to_res(path)
		if not FileAccess.file_exists(path):
			return CerberusUtil.fail("not_found", "no existe el script: %s" % path)
		var res: Variant = load(path)
		if not (res is Script):
			return CerberusUtil.fail("invalid_script", "no carga como Script: %s" % path)
		script = res
	var old: Variant = node.get_script()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Cerberus: script de %s" % node.name)
	ur.add_do_method(node, "set_script", script)
	ur.add_undo_method(node, "set_script", old)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return CerberusUtil.ok({
		"node_id": CerberusUtil.ensure_id(node),
		"script": script.resource_path if script else null,
	})


func node_set_transform(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var node: Node = d.resolve_node(String(args.node_id))
	if node == null:
		return CerberusUtil.fail("node_not_found", "no existe el nodo '%s'" % args.node_id)
	if not (node is Node2D or node is Node3D or node is Control):
		return CerberusUtil.fail("invalid_target", "%s no tiene transform" % node.get_class())
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Cerberus: transform de %s" % node.name)
	var changed: Array = []
	if args.has("position"):
		var p: Variant = args.position
		if node is Node2D or node is Control:
			var v: Variant = CerberusUtil.convert_value(p, TYPE_VECTOR2)
			ur.add_do_method(node, "set", "position", v)
			ur.add_undo_method(node, "set", "position", node.position)
		else:
			var v3: Variant = CerberusUtil.convert_value(p, TYPE_VECTOR3)
			ur.add_do_method(node, "set", "position", v3)
			ur.add_undo_method(node, "set", "position", node.position)
		changed.append("position")
	if args.has("rotation"):
		var r := float(args.rotation)
		ur.add_do_method(node, "set", "rotation", r)
		ur.add_undo_method(node, "set", "rotation", node.rotation)
		changed.append("rotation")
	if args.has("scale"):
		var s: Variant = CerberusUtil.convert_value(args.scale, TYPE_VECTOR2)
		if node is Node3D:
			s = CerberusUtil.convert_value(args.scale, TYPE_VECTOR3)
		ur.add_do_method(node, "set", "scale", s)
		ur.add_undo_method(node, "set", "scale", node.scale)
		changed.append("scale")
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return CerberusUtil.ok({"node_id": CerberusUtil.ensure_id(node), "changed": changed,
		"node": CerberusUtil.describe_node(node, root)})


func node_add_to_group(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var node: Node = d.resolve_node(String(args.node_id))
	if node == null:
		return CerberusUtil.fail("node_not_found", "no existe el nodo '%s'" % args.node_id)
	var group := String(args.group)
	var add := bool(args.get("add", true))
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Cerberus: grupo %s" % group)
	if add:
		ur.add_do_method(node, "add_to_group", group, true)
		ur.add_undo_method(node, "remove_from_group", group)
	else:
		ur.add_do_method(node, "remove_from_group", group)
		ur.add_undo_method(node, "add_to_group", group, true)
	ur.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	return CerberusUtil.ok({"node_id": CerberusUtil.ensure_id(node), "groups": node.get_groups()})


func node_find(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var pattern := String(args.get("name_pattern", ""))
	var type_filter := String(args.get("type", ""))
	var group := String(args.get("group", ""))
	var wants_script := bool(args.get("has_script", false))
	var limit := int(args.get("limit", 100))
	var out: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var is_match := true
		if not pattern.is_empty() and not String(n.name).match(pattern):
			is_match = false
		if is_match and not type_filter.is_empty() and not n.is_class(type_filter) and n.get_class() != type_filter:
			is_match = false
		if is_match and not group.is_empty() and not n.is_in_group(group):
			is_match = false
		if is_match and wants_script and n.get_script() == null:
			is_match = false
		if is_match:
			out.append(CerberusUtil.describe_node(n, root))
			if out.size() >= limit:
				break
		for c in n.get_children():
			stack.push_back(c)
	return CerberusUtil.ok({"matches": out, "count": out.size()})


# ------------------------------------------------------------------ helpers

func _apply_property(node: Node, key: String, raw: Variant, applied: Array, unknown: Array) -> bool:
	var types := CerberusUtil.property_types(node)
	if not types.has(key):
		# permitir alias habituales
		var alias := {"pos": "position", "rot": "rotation", "scl": "scale", "txt": "text"}
		if alias.has(key) and types.has(alias[key]):
			key = alias[key]
		else:
			unknown.append(key)
			return true
	var old_value: Variant = node.get(key)
	var new_value: Variant = CerberusUtil.convert_value(raw, int(types[key]))
	node.set(key, new_value)
	applied.append({"property": key, "old": CerberusUtil.variant_to_json(old_value), "new": CerberusUtil.variant_to_json(new_value)})
	return true


func _regenerate_ids(node: Node) -> void:
	node.set_meta(CerberusUtil.ID_META, CerberusUtil.new_id())
	for c in node.get_children():
		_regenerate_ids(c)
