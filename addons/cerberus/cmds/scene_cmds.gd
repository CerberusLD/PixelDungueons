@tool
class_name CerberusSceneCmds
extends RefCounted
## Herramientas de escena. Métodos = nombres de tool del contrato.

var d: CerberusDispatcher


func _init(dispatcher: CerberusDispatcher) -> void:
	d = dispatcher


func _open(path: String) -> void:
	# Si la escena ya estaba abierta hay que recargarla: open_scene_from_path no refresca
	# una escena cuyo fichero se reescribió por fuera (caso típico al regenerar un proyecto).
	var already_open := false
	if EditorInterface.has_method("get_open_scenes"):
		for p in EditorInterface.call("get_open_scenes"):
			if String(p) == path:
				already_open = true
				break
	if already_open and EditorInterface.has_method("reload_scene_from_path"):
		EditorInterface.call("reload_scene_from_path", path)
	else:
		EditorInterface.open_scene_from_path(path)
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame


func scene_create(args: Dictionary, session: Dictionary) -> Dictionary:
	var path := CerberusUtil.to_res(String(args.path))
	if not path.ends_with(".tscn"):
		path += ".tscn"
	if FileAccess.file_exists(path):
		return CerberusUtil.fail("already_exists", "la escena ya existe: %s" % path)
	var root_type := String(args.get("root_type", "Node2D"))
	if not ClassDB.class_exists(root_type) or not ClassDB.is_parent_class(root_type, "Node"):
		return CerberusUtil.fail("invalid_type", "tipo de raíz no válido: %s" % root_type)

	var root: Node = ClassDB.instantiate(root_type)
	if root == null:
		return CerberusUtil.fail("invalid_type", "no se pudo instanciar %s (¿clase abstracta?)" % root_type)
	var root_name := String(args.get("root_name", ""))
	root.name = root_name if not root_name.is_empty() else _default_root_name(path)

	var ps := PackedScene.new()
	var pack_err := ps.pack(root)
	if pack_err != OK:
		root.free()
		return CerberusUtil.fail("pack_failed", "no se pudo empaquetar la escena", {"error": error_string(pack_err)})
	CerberusUtil.ensure_dir(path.get_base_dir())
	var tx := d.snapshot([path], "scene_create", d.current_agent(session))
	var save_err := ResourceSaver.save(ps, path)
	root.free()
	if save_err != OK:
		return CerberusUtil.fail("save_failed", "no se pudo guardar %s" % path, {"error": error_string(save_err)})
	EditorInterface.get_resource_filesystem().scan()
	await _open(path)
	var opened := d.edited_root()
	return CerberusUtil.ok({
		"path": path,
		"root_id": CerberusUtil.ensure_id(opened) if opened else "",
		"opened": opened != null,
		"transaction": tx,
	})


func scene_open(args: Dictionary, session: Dictionary) -> Dictionary:
	var path := CerberusUtil.to_res(String(args.path))
	if not FileAccess.file_exists(path):
		return CerberusUtil.fail("not_found", "no existe la escena: %s" % path)
	await _open(path)
	var root := d.edited_root()
	if root == null or root.scene_file_path != path:
		return CerberusUtil.fail("open_failed", "el editor no abrió la escena", {"path": path})
	return CerberusUtil.ok({
		"path": path,
		"root_id": CerberusUtil.ensure_id(root),
		"tree": CerberusUtil.subtree(root, root, 1),
	})


func scene_save(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var target := String(args.get("path", ""))
	if not target.is_empty():
		target = CerberusUtil.to_res(target)
		if target != root.scene_file_path:
			d.snapshot([target], "scene_save_as", d.current_agent(session))
			EditorInterface.save_scene_as(target, false)
		else:
			EditorInterface.save_scene()
	else:
		if root.scene_file_path.is_empty():
			return CerberusUtil.fail("no_path", "la escena nunca se guardó; pasa 'path'")
		d.snapshot([root.scene_file_path], "scene_save", d.current_agent(session))
		EditorInterface.save_scene()
	await Engine.get_main_loop().process_frame
	var saved := d.edited_root()
	return CerberusUtil.ok({
		"path": saved.scene_file_path if saved else "",
	})


func scene_close(args: Dictionary, session: Dictionary) -> Dictionary:
	var path := CerberusUtil.to_res(String(args.path))
	var candidates := ["close_scene_from_path", "close_scene"]
	for m in candidates:
		if EditorInterface.has_method(m):
			if m == "close_scene_from_path":
				EditorInterface.call(m, path)
			else:
				EditorInterface.call(m)
			await Engine.get_main_loop().process_frame
			return CerberusUtil.ok({"closed": path})
	return CerberusUtil.fail("not_supported", "esta versión de Godot no expone close_scene")


func scene_inspect(args: Dictionary, session: Dictionary) -> Dictionary:
	var path := CerberusUtil.to_res(String(args.get("path", "")))
	var root := d.edited_root()
	if not path.is_empty() and (root == null or root.scene_file_path != path):
		if not FileAccess.file_exists(path):
			return CerberusUtil.fail("not_found", "no existe: %s" % path)
		return CerberusUtil.ok({"path": path, "open": false, "size_bytes": CerberusUtil.file_size(path)})
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var scripts: Array = []
	var nodes := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		nodes += 1
		var s := n.get_script()
		if s is Script and s.resource_path and not scripts.has(s.resource_path):
			scripts.append(s.resource_path)
		for c in n.get_children():
			stack.push_back(c)
	return CerberusUtil.ok({
		"path": root.scene_file_path,
		"open": true,
		"root": CerberusUtil.describe_node(root, root),
		"node_count": nodes,
		"scripts": scripts,
		"size_bytes": CerberusUtil.file_size(root.scene_file_path) if root.scene_file_path else 0,
	})


func scene_tree(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	if root == null:
		return CerberusUtil.fail("no_scene", "no hay escena editada")
	var depth := int(args.get("depth", -1))
	var props := bool(args.get("include_properties", false))
	var idx := CerberusUtil.build_index(root)
	return CerberusUtil.ok({
		"path": root.scene_file_path,
		"node_count": idx.size(),
		"tree": CerberusUtil.subtree(root, root, depth, props),
	})


func scene_duplicate(args: Dictionary, session: Dictionary) -> Dictionary:
	var src := CerberusUtil.to_res(String(args.path))
	var dst := CerberusUtil.to_res(String(args.new_path))
	if not FileAccess.file_exists(src):
		return CerberusUtil.fail("not_found", "no existe: %s" % src)
	if FileAccess.file_exists(dst):
		return CerberusUtil.fail("already_exists", "ya existe: %s" % dst)
	var res: Variant = ResourceLoader.load(src)
	if not (res is PackedScene):
		return CerberusUtil.fail("invalid_scene", "no se pudo cargar la escena origen")
	d.snapshot([dst], "scene_duplicate", d.current_agent(session))
	CerberusUtil.ensure_dir(dst.get_base_dir())
	var err := ResourceSaver.save(res, dst)
	if err != OK:
		return CerberusUtil.fail("save_failed", error_string(err))
	EditorInterface.get_resource_filesystem().scan()
	return CerberusUtil.ok({"source": src, "path": dst})


func scene_validate(args: Dictionary, session: Dictionary) -> Dictionary:
	var path := CerberusUtil.to_res(String(args.path))
	if not FileAccess.file_exists(path):
		return CerberusUtil.fail("not_found", "no existe: %s" % path)
	var res: Variant = ResourceLoader.load(path)
	if not (res is PackedScene):
		return CerberusUtil.fail("invalid_scene", "no carga como PackedScene")
	var problems: Array = []
	var warnings: Array = []
	var root: Node = res.instantiate()
	if root == null:
		return CerberusUtil.fail("instantiate_failed", "instantiate() devolvió null")
	var stack: Array[Node] = [root]
	var count := 0
	var notes: Array = []
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		count += 1
		var s := n.get_script()
		if s is Script:
			if s.resource_path.is_empty():
				warnings.append({"node": str(n.get_path()), "issue": "script embebido sin ruta"})
			elif not FileAccess.file_exists(s.resource_path):
				problems.append({"node": str(n.get_path()), "issue": "script inexistente", "path": s.resource_path})
			elif s.reload() != OK:
				problems.append({"node": str(n.get_path()), "issue": "script no compila", "path": s.resource_path})
		for c in n.get_children():
			stack.push_back(c)
	notes.append("nodos=%d" % count)
	root.free()
	return CerberusUtil.ok({
		"path": path,
		"valid": problems.is_empty(),
		"node_count": count,
		"problems": problems,
		"warnings": warnings,
		"notes": notes,
	})


# ------------------------------------------------------------------ helpers

func _default_root_name(path: String) -> String:
	var base := path.get_file().get_basename()
	var parts := base.replace("-", "_").split("_")
	var out := ""
	for p in parts:
		if p.is_empty():
			continue
		out += p.substr(0, 1).to_upper() + p.substr(1)
	return out if not out.is_empty() else "Root"
