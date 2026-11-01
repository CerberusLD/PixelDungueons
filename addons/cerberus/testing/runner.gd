@tool
extends SceneTree
## Runner de tests de Cerberus Engine.
##
## Ejecuta: godot --headless --path <proyecto> --script res://addons/cerberus/testing/runner.gd
## Salida: línea "CERBERUS_TEST_RESULTS:{json}" y exit code 0/1.

const RESULTS_PREFIX := "CERBERUS_TEST_RESULTS:"

var _results := {"passed": 0, "failed": 0, "suites": [], "total_assertions": 0}


func _initialize() -> void:
	var dir := "res://tests"
	var pattern := "*_test.gd"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("dir="):
			dir = arg.substr(4)
		elif arg.begins_with("pattern="):
			pattern = arg.substr(8)
	var files: Array[String] = []
	_collect(dir, pattern, files)
	files.sort()
	print("[CerberusTest] %d ficheros de test en %s" % [files.size(), dir])
	for f in files:
		_run_file(f)
	_results["files"] = files.size()
	_results["ok"] = _results.failed == 0
	print(RESULTS_PREFIX + JSON.stringify(_results))
	quit(0 if _results.failed == 0 else 1)


func _collect(dir: String, pattern: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		var full := dir.path_join(name)
		if d.current_is_dir():
			_collect(full, pattern, out)
		elif name.match(pattern):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()


func _run_file(path: String) -> void:
	var suite := {"file": path, "name": path.get_file().get_basename(), "tests": [],
		"passed": 0, "failed": 0, "errors": []}
	var script: Variant = load(path)
	if not (script is Script):
		suite["errors"].append("no carga como Script")
		suite["failed"] += 1
		_results.failed += 1
		_results.suites.append(suite)
		return
	var base: Array = []
	var cursor: Script = script.get_base_script()
	while cursor != null:
		base.append(cursor.resource_path)
		cursor = cursor.get_base_script()
	if not _extends_cerberus_test(script):
		suite["errors"].append("no extiende CerberusTest (base: %s)" % str(base))
		suite["failed"] += 1
		_results.failed += 1
		_results.suites.append(suite)
		return
	var methods: Array[String] = []
	for m in script.get_script_method_list():
		var mname := String(m.name)
		if mname.begins_with("test_"):
			methods.append(mname)
	methods.sort()
	for mname in methods:
		var inst: Variant = script.new()
		if inst == null:
			suite["tests"].append({"name": mname, "ok": false, "message": "no se pudo instanciar"})
			suite["failed"] += 1
			_results.failed += 1
			continue
		inst.before_each()
		inst.call(mname)
		inst.after_each()
		var failures: Array = inst.failures
		_results.total_assertions += int(inst.assertions)
		var ok := failures.is_empty()
		suite["tests"].append({
			"name": mname,
			"ok": ok,
			"assertions": int(inst.assertions),
			"failures": failures,
		})
		if ok:
			suite["passed"] += 1
			_results.passed += 1
		else:
			suite["failed"] += 1
			_results.failed += 1
	_results.suites.append(suite)


func _extends_cerberus_test(script: Script) -> bool:
	var cursor: Script = script
	while cursor != null:
		if cursor.resource_path.ends_with("cerberus_test.gd"):
			return true
		cursor = cursor.get_base_script()
	return false
