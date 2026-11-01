@tool
class_name CerberusWorkspaceCmds
extends RefCounted
## Workspace de agentes: registro, estado, locks, auditoría y control del editor.

var d: CerberusDispatcher


func _init(dispatcher: CerberusDispatcher) -> void:
	d = dispatcher


func agent_register(args: Dictionary, session: Dictionary) -> Dictionary:
	var requester := String(session.get("permission", "read"))
	var wanted := String(args.get("permission", requester))
	if Engine.get_main_loop() == null:
		return CerberusUtil.fail("internal", "sin main loop")
	if d.plugin.permission_rank(wanted) > d.plugin.permission_rank(requester) and requester != "admin":
		return CerberusUtil.fail("permission_denied",
			"un agente '%s' no puede crear agentes con '%s'" % [requester, wanted])
	var res := d.register_agent(
		String(args.agent_id),
		String(args.get("name", "")),
		wanted,
		String(args.get("task", "")))
	return res


func agent_list(args: Dictionary, session: Dictionary) -> Dictionary:
	var out: Array = []
	for k in d.agents.keys():
		out.append(d.agents[k])
	return CerberusUtil.ok({"agents": out, "count": out.size()})


func agent_update(args: Dictionary, session: Dictionary) -> Dictionary:
	var agent_id := String(args.get("agent_id", session.get("agent_id", "")))
	if not d.agents.has(agent_id):
		return CerberusUtil.fail("not_found", "agente desconocido: %s" % agent_id)
	if args.has("task"):
		d.agents[agent_id]["task"] = String(args.task)
	if args.has("status"):
		d.agents[agent_id]["status"] = String(args.status)
	d.agents[agent_id]["last_seen"] = Time.get_datetime_string_from_system(true)
	return CerberusUtil.ok({"agent": d.agents[agent_id]})


func workspace_status(args: Dictionary, session: Dictionary) -> Dictionary:
	var root := d.edited_root()
	return CerberusUtil.ok({
		"engine": d.plugin.engine_status(),
		"agents": d.agents.values(),
		"locks": d.locks.list(),
		"recent": d.history.slice(max(0, d.history.size() - 20)),
		"clients": d.plugin.server.client_count() if d.plugin.server else 0,
		"edited_scene": root.scene_file_path if root and root.scene_file_path else "",
		"pending_executions": 0,
	})


func lock_acquire(args: Dictionary, session: Dictionary) -> Dictionary:
	var res := d.locks.acquire(String(args.resource), d.current_agent(session),
		int(args.get("ttl_ms", 120000)), String(args.get("reason", "")))
	if not bool(res.get("acquired", false)):
		return CerberusUtil.fail("locked", "el recurso ya está bloqueado", res)
	return CerberusUtil.ok(res)


func lock_release(args: Dictionary, session: Dictionary) -> Dictionary:
	var released := d.locks.release(String(args.resource), d.current_agent(session))
	if not released:
		return CerberusUtil.fail("not_locked", "no tienes lock sobre '%s'" % args.resource)
	return CerberusUtil.ok({"released": String(args.resource)})


func lock_list(args: Dictionary, session: Dictionary) -> Dictionary:
	var locks := d.locks.list()
	return CerberusUtil.ok({"locks": locks, "count": locks.size()})


func changelog_list(args: Dictionary, session: Dictionary) -> Dictionary:
	var limit := int(args.get("limit", 20))
	var entries := d.changelog.list(limit)
	var agent := String(args.get("agent_id", ""))
	if not agent.is_empty():
		var filtered: Array = []
		for e in entries:
			if e.agent == agent:
				filtered.append(e)
		entries = filtered
	return CerberusUtil.ok({"transactions": entries, "count": entries.size()})


func changelog_rollback(args: Dictionary, session: Dictionary) -> Dictionary:
	var tx := String(args.transaction_id)
	var result := d.changelog.rollback(tx)
	if not bool(result.get("ok", false)):
		return CerberusUtil.fail("rollback_failed", "no se pudo revertir", result)
	return CerberusUtil.ok(result)


func editor_ping(args: Dictionary, session: Dictionary) -> Dictionary:
	var implemented: Array = d.tool_names()
	implemented.sort()
	return CerberusUtil.ok({
		"pong": true,
		"engine": d.plugin.engine_status(),
		"agent": d.agents.get(session.get("agent_id", ""), {}),
		"implemented_tools": implemented,
		"implemented_count": implemented.size(),
		"uptime_s": int(Time.get_unix_time_from_system() - d.plugin.started_unix),
	})


func editor_godot(args: Dictionary, session: Dictionary) -> Dictionary:
	var info := Engine.get_version_info()
	return CerberusUtil.ok({
		"version": info.get("string", ""),
		"major": info.get("major", 0),
		"minor": info.get("minor", 0),
		"patch": info.get("patch", 0),
		"string": info.get("string", ""),
		"build": info.get("build", ""),
		"platform": OS.get_name(),
		"display": DisplayServer.get_name(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"rendering_method": ProjectSettings.get_setting("rendering/renderer/rendering_method", ""),
		"locale": OS.get_locale(),
	})


func editor_rescan(args: Dictionary, session: Dictionary) -> Dictionary:
	EditorInterface.get_resource_filesystem().scan()
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame
	return CerberusUtil.ok({"rescanned": true})


func editor_quit(args: Dictionary, session: Dictionary) -> Dictionary:
	if bool(args.get("save", true)):
		var root := d.edited_root()
		if root and not root.scene_file_path.is_empty():
			EditorInterface.save_scene()
	# La respuesta debe salir antes de cerrar: se programa el cierre y se devuelve ya.
	var tree := d.plugin.get_tree()
	var timer := tree.create_timer(0.3)
	timer.timeout.connect(func(): tree.quit())
	return CerberusUtil.ok({
		"quitting": true,
		"note": "el editor se cierra en ~0,3 s; en headless el bridge completa con SIGTERM si no termina",
	})
