@tool
class_name CerberusServer
extends Node
## Servidor TCP JSON-lines para agentes. Un request por línea, una respuesta por línea.

const MAX_LINE_BYTES := 8 * 1024 * 1024

var plugin: EditorPlugin
var tcp := TCPServer.new()
var port: int = 0
var bind_address: String = "127.0.0.1"
var running := false
var connections_total := 0

var _clients: Array = []
var _queue: Array = []
var _busy := false


func _init(p_plugin: EditorPlugin = null) -> void:
	plugin = p_plugin
	set_process(true)


func start(p_port: int) -> bool:
	if running:
		return true
	bind_address = str(ProjectSettings.get_setting("cerberus/server/bind", "127.0.0.1"))
	var err := tcp.listen(p_port, bind_address)
	if err != OK:
		push_error("[Cerberus] listen(%d) falló: %s" % [p_port, error_string(err)])
		return false
	port = p_port
	running = true
	print("[Cerberus] editor bridge listening on %s:%d (%d tools)" % [bind_address, port, plugin.specs.get("tools", {}).size()])
	return true


func stop() -> void:
	running = false
	for c in _clients:
		c.peer.disconnect_from_host()
	_clients.clear()
	_queue.clear()
	tcp.stop()
	print("[Cerberus] editor bridge stopped")


func _exit_tree() -> void:
	stop()


# ------------------------------------------------------------------- loop

func _process(_delta: float) -> void:
	if not running:
		return
	_accept()
	_poll()
	_drain()


func _accept() -> void:
	while tcp.is_connection_available():
		var peer := tcp.take_connection()
		if peer == null:
			return
		_clients.append({
			"peer": peer,
			"buffer": PackedByteArray(),
			"session": {},
			"authed": false,
			"connected_at": Time.get_unix_time_from_system(),
			"remote": "%s:%d" % [peer.get_connected_host(), peer.get_connected_port()],
		})
		connections_total += 1


func _poll() -> void:
	var dead: Array = []
	for c in _clients:
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		var status := peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			dead.append(c)
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			var chunk: Array = peer.get_partial_data(available)
			if chunk[0] != OK:
				dead.append(c)
				continue
			c.buffer.append_array(chunk[1])
			_extract_lines(c)
			if c.buffer.size() > MAX_LINE_BYTES:
				_send(c, {"ok": false, "error": {"code": "payload_too_large", "message": "línea > 8MB"}})
				dead.append(c)
	for c in dead:
		_close(c)


func _extract_lines(c: Dictionary) -> void:
	var buf: PackedByteArray = c.buffer
	var newline := buf.find(10)
	while newline >= 0:
		var line := buf.slice(0, newline)
		buf = buf.slice(newline + 1)
		if line.size() > 0:
			_on_line(c, line.get_string_from_utf8())
		newline = buf.find(10)
	c.buffer = buf


func _on_line(c: Dictionary, line: String) -> void:
	var parsed: Variant = JSON.parse_string(line)
	if not (parsed is Dictionary):
		_send(c, {"ok": false, "error": {"code": "bad_request", "message": "JSON inválido"}})
		return
	var req: Dictionary = parsed
	var kind := String(req.get("type", "tool"))
	if not bool(c.authed):
		if kind != "hello":
			_send(c, {"id": req.get("id"), "ok": false, "error": {"code": "unauthorized", "message": "envía hello con token"}})
			_close(c)
			return
		_handshake(c, req)
		return
	if kind == "ping":
		_send(c, {"id": req.get("id"), "ok": true, "data": {"pong": true, "ts": Time.get_unix_time_from_system()}})
		return
	if kind == "cancel":
		_cancel(str(req.get("target", "")))
		return
	_queue.append({"client": c, "req": req})


func _handshake(c: Dictionary, req: Dictionary) -> void:
	var given := String(req.get("token", ""))
	if given != plugin.token:
		_send(c, {"id": req.get("id"), "ok": false, "error": {"code": "unauthorized", "message": "token inválido"}})
		_close(c)
		return
	var agent: Variant = req.get("agent", {})
	if not (agent is Dictionary):
		agent = {}
	var agent_id := String(agent.get("id", ""))
	if agent_id.is_empty():
		agent_id = "agent_%04x" % (randi() & 0xffff)
	var permission := String(agent.get("permission", "read"))
	if plugin.permission_rank(permission) < 0:
		permission = "read"
	var reg: Dictionary = plugin.dispatcher.register_agent(
		agent_id, String(agent.get("name", agent_id)), permission, String(agent.get("task", "")))
	if not bool(reg.get("ok", false)):
		_send(c, {"id": req.get("id"), "ok": false, "error": reg.get("error")})
		_close(c)
		return
	c.authed = true
	c.session = {"agent_id": agent_id, "permission": permission}
	_send(c, {
		"id": req.get("id"),
		"ok": true,
		"data": {
			"protocol": plugin.protocol_version,
			"engine": plugin.engine_name,
			"godot_version": Engine.get_version_info().get("string", ""),
			"agent_id": agent_id,
			"permission": permission,
			"tools": plugin.specs.get("tools", {}).size(),
		},
	})


func _drain() -> void:
	if _busy or _queue.is_empty():
		return
	_busy = true
	var job: Dictionary = _queue.pop_front()
	await _execute(job)
	_busy = false


func _execute(job: Dictionary) -> void:
	var c: Dictionary = job.client
	var req: Dictionary = job.req
	if not _clients.has(c):
		return
	var tool := String(req.get("tool", ""))
	var args: Variant = req.get("args", {})
	if not (args is Dictionary):
		args = {}
	var response: Dictionary
	if tool.is_empty():
		response = {"ok": false, "error": {"code": "bad_request", "message": "falta 'tool'"}}
	else:
		response = await plugin.dispatcher.dispatch(tool, args, c.session)
	response["id"] = req.get("id")
	response["engine"] = plugin.engine_name
	response["protocol"] = plugin.protocol_version
	_send(c, response)


func _send(c: Dictionary, payload: Dictionary) -> void:
	if not _clients.has(c):
		return
	var peer: StreamPeerTCP = c.peer
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var line := JSON.stringify(payload) + "\n"
	peer.put_data(line.to_utf8_buffer())


func _cancel(target_id: String) -> void:
	for i in range(_queue.size() - 1, -1, -1):
		if str(_queue[i].req.get("id", "")) == target_id:
			_queue.remove_at(i)


func _close(c: Dictionary) -> void:
	c.peer.disconnect_from_host()
	_clients.erase(c)
	if c.session.has("agent_id"):
		if plugin.dispatcher.agents.has(c.session.agent_id):
			plugin.dispatcher.agents[c.session.agent_id]["status"] = "disconnected"
		plugin.dispatcher.locks.release_all(c.session.agent_id)


func client_count() -> int:
	return _clients.size()
