@tool
class_name CerberusScriptCmds
extends RefCounted
## Herramientas de script que necesitan el contexto del editor.

var d: CerberusDispatcher


func _init(dispatcher: CerberusDispatcher) -> void:
	d = dispatcher


func script_execute(args: Dictionary, session: Dictionary) -> Dictionary:
	var path := CerberusUtil.to_res(String(args.path))
	if not FileAccess.file_exists(path):
		return CerberusUtil.fail("not_found", "no existe el script: %s" % path)
	var exe := OS.get_executable_path()
	var cmd_args: Array = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", path]
	for a in args.get("args", []):
		cmd_args.append("--")
		cmd_args.append(str(a))
	var output: Array = []
	var timeout_ms := int(args.get("timeout_ms", 30000))
	var started := Time.get_ticks_msec()
	var code := OS.execute(exe, cmd_args, output, true, false)
	var elapsed := Time.get_ticks_msec() - started
	var text := ""
	for chunk in output:
		text += str(chunk)
	return CerberusUtil.ok({
		"path": path,
		"exit_code": code,
		"duration_ms": elapsed,
		"output": text,
		"timeout_ms": timeout_ms,
		"timed_out": elapsed >= timeout_ms,
	})
