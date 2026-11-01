@tool
class_name CerberusResourceCmds
extends RefCounted
## Recursos (.tres) gestionados por el editor con ResourceLoader/ResourceSaver.

var d: CerberusDispatcher


func _init(dispatcher: CerberusDispatcher) -> void:
	d = dispatcher


func resource_create(args: Dictionary, session: Dictionary) -> Dictionary:
	var path := CerberusUtil.to_res(String(args.path))
	var type := String(args.type)
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Resource"):
		return CerberusUtil.fail("invalid_type", "tipo de recurso no válido: %s" % type)
	if FileAccess.file_exists(path):
		return CerberusUtil.fail("already_exists", "ya existe: %s" % path)
	var res: Variant = ClassDB.instantiate(type)
	if res == null:
		return CerberusUtil.fail("invalid_type", "no se pudo instanciar %s" % type)
	var types := CerberusUtil.property_types(res)
	var applied: Array = []
	var unknown: Array = []
	var props: Dictionary = args.get("properties", {})
	for key in props.keys():
		var k := String(key)
		if not types.has(k):
			unknown.append(k)
			continue
		var v: Variant = CerberusUtil.convert_value(props[key], int(types[k]))
		res.set(k, v)
		applied.append({"property": k, "value": CerberusUtil.variant_to_json(v)})
	CerberusUtil.ensure_dir(path.get_base_dir())
	var tx := d.snapshot([path], "resource_create", d.current_agent(session))
	var err := ResourceSaver.save(res, path)
	if err != OK:
		return CerberusUtil.fail("save_failed", error_string(err))
	EditorInterface.get_resource_filesystem().scan()
	return CerberusUtil.ok({"path": path, "type": type, "applied": applied,
		"unknown_properties": unknown, "transaction": tx})


func resource_inspect(args: Dictionary, session: Dictionary) -> Dictionary:
	var path := CerberusUtil.to_res(String(args.path))
	if not FileAccess.file_exists(path):
		return CerberusUtil.fail("not_found", "no existe: %s" % path)
	var res: Variant = ResourceLoader.load(path)
	if res == null:
		return CerberusUtil.fail("load_failed", "ResourceLoader.load devolvió null")
	var props := {}
	if res is Resource:
		for k in CerberusUtil.property_types(res).keys():
			props[k] = CerberusUtil.variant_to_json(res.get(k))
	return CerberusUtil.ok({
		"path": path,
		"class": res.get_class(),
		"resource_name": str(res.get("resource_name")) if res is Resource else "",
		"properties": props,
		"dependencies": _dependencies(path),
		"size_bytes": CerberusUtil.file_size(path),
	})


func resource_modify(args: Dictionary, session: Dictionary) -> Dictionary:
	var path := CerberusUtil.to_res(String(args.path))
	if not FileAccess.file_exists(path):
		return CerberusUtil.fail("not_found", "no existe: %s" % path)
	var res: Variant = ResourceLoader.load(path)
	if res == null:
		return CerberusUtil.fail("load_failed", "no se pudo cargar el recurso")
	var types := CerberusUtil.property_types(res)
	var applied: Array = []
	var unknown: Array = []
	var props: Dictionary = args.properties
	for key in props.keys():
		var k := String(key)
		if not types.has(k):
			unknown.append(k)
			continue
		var old: Variant = res.get(k)
		var v: Variant = CerberusUtil.convert_value(props[key], int(types[k]))
		res.set(k, v)
		applied.append({"property": k, "old": CerberusUtil.variant_to_json(old), "new": CerberusUtil.variant_to_json(v)})
	if applied.is_empty():
		return CerberusUtil.fail("invalid_property", "ninguna propiedad existe en %s" % res.get_class(), {"unknown": unknown})
	var tx := d.snapshot([path], "resource_modify", d.current_agent(session))
	var err := ResourceSaver.save(res, path)
	if err != OK:
		return CerberusUtil.fail("save_failed", error_string(err))
	return CerberusUtil.ok({"path": path, "applied": applied, "unknown_properties": unknown, "transaction": tx})


func resource_validate(args: Dictionary, session: Dictionary) -> Dictionary:
	var path := CerberusUtil.to_res(String(args.path))
	if not FileAccess.file_exists(path):
		return CerberusUtil.fail("not_found", "no existe: %s" % path)
	var res: Variant = ResourceLoader.load(path)
	if res == null:
		return CerberusUtil.ok({"path": path, "valid": false, "problems": ["no carga"], "dependencies": []})
	var missing: Array = []
	var deps := _dependencies(path)
	for dep in deps:
		if not FileAccess.file_exists(String(dep)):
			missing.append(dep)
	return CerberusUtil.ok({
		"path": path,
		"class": res.get_class(),
		"valid": missing.is_empty(),
		"problems": missing,
		"dependencies": deps,
	})


func _dependencies(path: String) -> Array:
	var out: Array = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("[ext_resource") and line.contains("path=\""):
			var start := line.find("path=\"") + 6
			var end := line.find("\"", start)
			if end > start:
				out.append(line.substr(start, end - start))
	f.close()
	return out
