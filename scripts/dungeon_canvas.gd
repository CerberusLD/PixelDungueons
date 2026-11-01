extends Node2D

# Renderizador Pixel Art 1:1 de pixeldungeons.xyz usando el tileset.png y characters.png originales
var main_scene: Node = null

const SCALE_FACTOR: float = 3.0
const TILE_PX: float = 16.0
const WORLD_TILE: float = 48.0 # 16 * 3.0
const TILESET_COLS: int = 23

var tex_tileset: Texture2D
var tex_characters: Texture2D
var tex_pixel: Texture2D
var tex_bomb: Texture2D
var tex_diamond: Texture2D
var tex_radial_light: ImageTexture

var char_frames: Array = []
var char_anims: Dictionary = {} # anim_name -> {from, to, total_duration_ms}
var _assets_loaded: bool = false


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_ensure_assets_loaded()


func _ensure_assets_loaded() -> void:
	if _assets_loaded:
		return
	_assets_loaded = true
	tex_tileset = load("res://assets/sprites/tileset.png")
	tex_characters = load("res://assets/sprites/characters.png")
	tex_pixel = load("res://assets/sprites/pixel.png")
	tex_bomb = load("res://assets/sprites/bomb.png")
	tex_diamond = load("res://assets/sprites/diamond.png")
	tex_radial_light = _create_radial_light_texture(128)
	_load_characters_aseprite_json()


func _create_radial_light_texture(sz: int) -> ImageTexture:
	var img: Image = Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var center := Vector2(sz * 0.5, sz * 0.5)
	var max_r: float = sz * 0.5
	for y in range(sz):
		for x in range(sz):
			var d: float = Vector2(x, y).distance_to(center) / max_r
			var a: float = clampf(1.0 - d * d, 0.0, 1.0)
			a = a * a
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


func _load_characters_aseprite_json() -> void:
	var path: String = "res://assets/sprites/characters.json"
	if not FileAccess.file_exists(path):
		return
	var txt: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var d: Dictionary = parsed
	if d.has("frames") and typeof(d["frames"]) == TYPE_ARRAY:
		char_frames = d["frames"]
	if d.has("meta") and typeof(d["meta"]) == TYPE_DICTIONARY:
		var meta: Dictionary = d["meta"]
		if meta.has("frameTags") and typeof(meta["frameTags"]) == TYPE_ARRAY:
			for tag in meta["frameTags"]:
				var tname: String = str(tag.get("name", ""))
				var from_idx: int = int(tag.get("from", 0))
				var to_idx: int = int(tag.get("to", 0))
				var total_ms: float = 0.0
				for idx in range(from_idx, to_idx + 1):
					if idx >= 0 and idx < char_frames.size():
						total_ms += float(char_frames[idx].get("duration", 100))
				char_anims[tname] = {
					"from": from_idx,
					"to": to_idx,
					"total_ms": maxf(total_ms, 40.0)
				}


func _get_tile_src_rect(tile_idx_zero: int) -> Rect2:
	if tile_idx_zero < 0:
		return Rect2(0, 0, 16, 16)
	var col: int = tile_idx_zero % TILESET_COLS
	var row: int = int(tile_idx_zero / TILESET_COLS)
	return Rect2(col * 16, row * 16, 16, 16)


func _draw_tile_at_grid(tile_idx_zero: int, gx: int, gy: int, modulate_col: Color = Color.WHITE) -> void:
	if tex_tileset == null or tile_idx_zero < 0:
		return
	var src: Rect2 = _get_tile_src_rect(tile_idx_zero)
	var dst := Rect2(gx * WORLD_TILE, gy * WORLD_TILE, WORLD_TILE, WORLD_TILE)
	draw_texture_rect_region(tex_tileset, dst, src, modulate_col)


func _draw_tile_at_world(tile_idx_zero: int, world_pos: Vector2, scale_mult: float = 1.0, modulate_col: Color = Color.WHITE) -> void:
	if tex_tileset == null or tile_idx_zero < 0:
		return
	var src: Rect2 = _get_tile_src_rect(tile_idx_zero)
	var sz: float = WORLD_TILE * scale_mult
	var dst := Rect2(world_pos.x - sz * 0.5, world_pos.y - sz * 0.5, sz, sz)
	draw_texture_rect_region(tex_tileset, dst, src, modulate_col)


func _get_animated_gid(gid: int, time_ms: float) -> int:
	if gid <= 0:
		return 0
	var zero_id: int = gid - 1
	# Animaciones exactas del Tiled JSON oficial (tileset.261f6448.png)
	if zero_id == 242 or zero_id == 243:
		var t: int = int(time_ms) % 2000
		if t < 1000:
			return 247 + 1
		var step: int = int((t - 1000) / 250)
		return clampi(243 + step, 243, 246) + 1
	elif zero_id == 265 or zero_id == 266:
		var t2: int = int(time_ms) % 3500
		if t2 < 2500:
			return 270 + 1
		var step2: int = int((t2 - 2500) / 250)
		return clampi(266 + step2, 266, 269) + 1
	elif zero_id == 272: # Torch flame animation: 289, 290, 291
		var step3: int = int(time_ms / 250.0) % 3
		return (289 + step3) + 1
	return gid


func _draw() -> void:
	_ensure_assets_loaded()
	if main_scene == null:
		return

	var map_w: float = float(main_scene.map_width)
	var map_h: float = float(main_scene.map_height)
	var time_ms: float = float(Time.get_ticks_msec())
	var time_sec: float = time_ms * 0.001

	# Fondo abismal exterior
	draw_rect(Rect2(-900, -900, map_w + 1800, map_h + 1800), Color("#0d0b14"), true)

	# Determinar rectángulo visible de cámara para culling rápido en mapas 100x100
	var cam_pos: Vector2 = main_scene.camera.position if main_scene.camera != null else Vector2(map_w * 0.5, map_h * 0.5)
	var half_view := Vector2(820, 520)
	var min_gx: int = maxi(0, int((cam_pos.x - half_view.x) / WORLD_TILE) - 1)
	var max_gx: int = mini(int(main_scene.grid_w) - 1, int((cam_pos.x + half_view.x) / WORLD_TILE) + 1)
	var min_gy: int = maxi(0, int((cam_pos.y - half_view.y) / WORLD_TILE) - 1)
	var max_gy: int = mini(int(main_scene.grid_h) - 1, int((cam_pos.y + half_view.y) / WORLD_TILE) + 1)

	var gw: int = int(main_scene.grid_w)
	var has_tiled_map: bool = main_scene.layer_ground.size() == gw * int(main_scene.grid_h) and gw > 0

	if has_tiled_map:
		# 1. Capas Tiled oficiales: ground -> interactive_objects -> walls -> decorative
		for gy in range(min_gy, max_gy + 1):
			var row_offset: int = gy * gw
			for gx in range(min_gx, max_gx + 1):
				var idx: int = row_offset + gx
				var g_gid: int = main_scene.layer_ground[idx]
				if g_gid > 0:
					_draw_tile_at_grid(g_gid - 1, gx, gy)

				var i_gid: int = main_scene.layer_interactive[idx]
				if i_gid > 0:
					_draw_tile_at_grid(i_gid - 1, gx, gy)

				var w_gid: int = main_scene.layer_walls[idx]
				if w_gid > 0:
					_draw_tile_at_grid(w_gid - 1, gx, gy)

				var d_gid: int = main_scene.layer_decorative[idx]
				if d_gid > 0:
					var anim_gid: int = _get_animated_gid(d_gid, time_ms + float((gx * 37 + gy * 13) * 40))
					_draw_tile_at_grid(anim_gid - 1, gx, gy)

	# 2. Dibujar vetas de mineral $PIXEL (frame 317 del tileset oficial)
	for ore in main_scene.ores:
		if not ore["alive"]:
			continue
		_draw_ore(ore, time_sec)

	# 3. Dibujar bolsas de botín / Backpacks (frame 239 del tileset oficial)
	for bag in main_scene.loot_bags:
		_draw_loot_bag(bag, time_sec)

	# 4. Dibujar bombas / Dinamitas plantadas (frame 293 del tileset oficial con parpadeo blanco y mecha)
	for tnt in main_scene.tnt_list:
		_draw_tnt(tnt, time_sec)

	# 5. Dibujar explosiones en cruz de 13 celdas (frames 166..172 de la capa fx oficial)
	for exp_fx in main_scene.explosions:
		_draw_explosion(exp_fx)

	# 6. Ordenar por Y y dibujar todos los personajes (Bots + Jugador + Goblins) con Aseprite oficial
	var entities: Array = []
	for gob in main_scene.goblins:
		if gob["alive"] or float(gob.get("death_timer", 0.0)) > 0.0:
			entities.append({"kind": "goblin", "data": gob, "y": gob["pos"].y})
	for b in main_scene.bots:
		if b["alive"] or float(b.get("death_timer", 0.0)) > 0.0:
			entities.append({"kind": "miner", "data": b, "y": b["pos"].y})
	if main_scene.player.get("alive", false) or float(main_scene.player.get("death_timer", 0.0)) > 0.0:
		entities.append({"kind": "miner", "data": main_scene.player, "y": main_scene.player["pos"].y})

	entities.sort_custom(func(a, b): return a["y"] < b["y"])

	for ent in entities:
		if ent["kind"] == "goblin":
			_draw_goblin(ent["data"], time_ms, time_sec)
		else:
			_draw_miner(ent["data"], time_ms, time_sec)

	# 7. Iluminación dinámica Light2D (Ambient #64748b + halos en antorchas, lava, minerales, bombas y mineros)
	if main_scene._state().lights_enabled and tex_radial_light != null:
		_draw_dynamic_lights(cam_pos, half_view, time_sec)

	# 8. Textos flotantes de recompensas (+ 0.45 [pixel logo], EPIC ORE!, etc.)
	if not main_scene._state().hide_rewards:
		var font: Font = ThemeDB.fallback_font
		for ft in main_scene.floating_texts:
			var fpos: Vector2 = ft["pos"]
			var fcol: Color = ft["color"]
			var alpha: float = clampf(float(ft["ttl"]) / float(ft["max_ttl"]), 0.0, 1.0)
			fcol.a = alpha
			var txt: String = str(ft["text"])
			var fsize: int = int(ft["size"])
			draw_string(font, fpos + Vector2(2, 2), txt, HORIZONTAL_ALIGNMENT_CENTER, 200, fsize, Color(0, 0, 0, alpha * 0.9))
			draw_string(font, fpos, txt, HORIZONTAL_ALIGNMENT_CENTER, 200, fsize, fcol)
			if bool(ft.get("show_pixel_icon", false)) and tex_pixel != null:
				var tw: float = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
				var icon_pos := Vector2(fpos.x + 100.0 + tw * 0.5 + 4.0, fpos.y - fsize + 2.0)
				draw_texture_rect(tex_pixel, Rect2(icon_pos.x, icon_pos.y, 18, 16), false, Color(1, 1, 1, alpha))


func _draw_ore(ore: Dictionary, time_sec: float) -> void:
	var pos: Vector2 = ore["pos"]
	var is_epic: bool = bool(ore["is_epic"])
	var shake_off := Vector2.ZERO
	if float(ore.get("shake_ttl", 0.0)) > 0.0:
		shake_off = Vector2(sin(time_sec * 65.0) * 3.5, cos(time_sec * 50.0) * 1.5)

	# Sombra sutil bajo el cristal
	draw_circle(pos + Vector2(0, 14), 16.0, Color(0, 0, 0, 0.35))

	# En el juego oficial, los diamantes/ores usan el frame 317 de tileset.png
	# Si es EPIC ORE, emite un destello dorado/esmeralda brillante y partículas de brillo (frames 212..220)
	if is_epic:
		var pulse: float = 0.55 + 0.25 * sin(time_sec * 6.0 + pos.x)
		if tex_radial_light != null:
			var rsz: float = 110.0
			draw_texture_rect(tex_radial_light, Rect2(pos.x - rsz * 0.5, pos.y - rsz * 0.5, rsz, rsz), false, Color(0.53, 0.93, 0.0, pulse * 0.45))

	_draw_tile_at_world(317, pos + shake_off, 1.0, Color(1.15, 1.15, 1.15, 1.0) if is_epic else Color.WHITE)

	# Partícula de brillo (diamond-shine frames 212..220 del tileset oficial)
	var shine_cycle: float = fmod(time_sec * 1.8 + (pos.x + pos.y) * 0.01, 3.0)
	if shine_cycle < 0.45:
		var shine_frame: int = 212 + clampi(int((shine_cycle / 0.45) * 8.0), 0, 8)
		var sp_off := Vector2(sin(pos.x) * 10.0, -8.0 - (shine_cycle / 0.45) * 18.0)
		_draw_tile_at_world(shine_frame, pos + sp_off, 0.55, Color(1, 1, 1, 0.9))

	# Barra de progreso de picado cuando está recibiendo golpes
	var hp: float = float(ore["hp"])
	var max_hp: float = float(ore["max_hp"])
	if hp < max_hp:
		var bw: float = 36.0
		var ratio: float = clampf(hp / max_hp, 0.0, 1.0)
		draw_rect(Rect2(pos.x - bw * 0.5, pos.y - 28, bw, 6), Color(0, 0, 0, 0.8), true)
		var bar_col: Color = Color("#87ED00") if not is_epic else Color("#ffd43b")
		draw_rect(Rect2(pos.x - bw * 0.5 + 1, pos.y - 27, (bw - 2) * ratio, 4), bar_col, true)


func _draw_loot_bag(bag: Dictionary, time_sec: float) -> void:
	var pos: Vector2 = bag["pos"]
	var bob: float = sin(time_sec * 4.5 + pos.x) * 2.0
	draw_circle(pos + Vector2(0, 14), 14.0, Color(0, 0, 0, 0.4))
	# Mochila oficial: frame 239 del tileset.png
	_draw_tile_at_world(239, pos + Vector2(0, bob), 1.0)
	var font: Font = ThemeDB.fallback_font
	var txt: String = "+" + str(bag["amount"])
	draw_string(font, pos + Vector2(-39, bob - 21), txt, HORIZONTAL_ALIGNMENT_CENTER, 80, 12, Color(0, 0, 0, 0.9))
	draw_string(font, pos + Vector2(-40, bob - 22), txt, HORIZONTAL_ALIGNMENT_CENTER, 80, 12, Color("#87ED00"))


func _draw_tnt(tnt: Dictionary, time_sec: float) -> void:
	var pos: Vector2 = tnt["pos"]
	var timer: float = float(tnt["timer"])
	# En el juego oficial la bomba parpadea en blanco puro acelerando antes de explotar (1.5s)
	var freq: float = 18.0 if timer < 0.5 else (10.0 if timer < 1.0 else 5.0)
	var flash_white: bool = sin(time_sec * freq * PI) > 0.15

	# Indicador sutil de las 13 celdas de explosión en cruz (radio de peligro)
	var danger_alpha: float = 0.22 if flash_white else 0.10
	draw_circle(pos, float(tnt["radius"]), Color(1.0, 0.2, 0.1, danger_alpha))
	draw_arc(pos, float(tnt["radius"]), 0.0, TAU, 36, Color(1.0, 0.35, 0.2, danger_alpha * 2.4), 1.5)

	if tex_radial_light != null and flash_white:
		draw_texture_rect(tex_radial_light, Rect2(pos.x - 64, pos.y - 64, 128, 128), false, Color(1, 1, 1, 0.55))

	# Bomba oficial: frame 293 del tileset.png
	var mod_col: Color = Color(10.0, 10.0, 10.0, 1.0) if flash_white else Color.WHITE
	_draw_tile_at_world(293, pos, 1.0, mod_col)


func _draw_explosion(exp_fx: Dictionary) -> void:
	var pos: Vector2 = exp_fx["pos"]
	var elapsed: float = float(exp_fx["max_ttl"]) - float(exp_fx["ttl"])
	var total_d: float = float(exp_fx["max_ttl"])
	var progress: float = clampf(elapsed / maxf(0.01, total_d), 0.0, 0.999)
	# En el código oficial: firstgid 166 (0-indexed 165) con 7 frames de animación (tileid 0..6 -> 165..171)
	var frame_offset: int = clampi(int(progress * 7.0), 0, 6)
	var tile_zero: int = 165 + frame_offset

	var cells: Array = exp_fx.get("cells", [])
	if cells.size() > 0:
		for c in cells:
			var cpos: Vector2 = c
			_draw_tile_at_world(tile_zero, cpos, 1.0)
	else:
		# Patrón de 13 celdas exacto del código oficial (3x3 central + 4 extremos a 2 celdas)
		var offsets: Array[Vector2] = [
			Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1),
			Vector2(-1, 0),  Vector2(0, 0),  Vector2(1, 0),
			Vector2(-1, 1),  Vector2(0, 1),  Vector2(1, 1),
			Vector2(-2, 0),  Vector2(2, 0),  Vector2(0, -2), Vector2(0, 2)
		]
		for off in offsets:
			_draw_tile_at_world(tile_zero, pos + off * WORLD_TILE, 1.0)


func _get_aseprite_frame_index(anim_key: String, time_ms: float, loop: bool = true, custom_progress: float = -1.0) -> int:
	if not char_anims.has(anim_key):
		# Fallback a skin 1 o goblin
		if anim_key.begins_with("player-"):
			anim_key = "player-idle-right-1"
		else:
			anim_key = "goblin-sleep-left"
		if not char_anims.has(anim_key):
			return 16

	var tag: Dictionary = char_anims[anim_key]
	var from_idx: int = int(tag["from"])
	var to_idx: int = int(tag["to"])
	var total_ms: float = float(tag["total_ms"])

	var t: float = 0.0
	if custom_progress >= 0.0:
		t = clampf(custom_progress, 0.0, 0.999) * total_ms
	elif loop:
		t = fmod(time_ms, total_ms)
	else:
		t = minf(time_ms, total_ms - 1.0)

	var acc: float = 0.0
	for idx in range(from_idx, to_idx + 1):
		var dur: float = float(char_frames[idx].get("duration", 100))
		acc += dur
		if t <= acc:
			return idx
	return to_idx


func _draw_aseprite_frame(frame_idx: int, world_pos: Vector2, modulate_col: Color = Color.WHITE) -> void:
	if tex_characters == null or frame_idx < 0 or frame_idx >= char_frames.size():
		return
	var fr_data: Dictionary = char_frames[frame_idx]
	var f_rect: Dictionary = fr_data["frame"]
	var s_rect: Dictionary = fr_data["spriteSourceSize"]
	var src := Rect2(float(f_rect["x"]), float(f_rect["y"]), float(f_rect["w"]), float(f_rect["h"]))

	# El lienzo original Aseprite de cada personaje es 32x32, con los pies cerca de y=30
	var top_left: Vector2 = world_pos - Vector2(16.0 * SCALE_FACTOR, 22.0 * SCALE_FACTOR)
	var dst := Rect2(
		top_left.x + float(s_rect["x"]) * SCALE_FACTOR,
		top_left.y + float(s_rect["y"]) * SCALE_FACTOR,
		float(f_rect["w"]) * SCALE_FACTOR,
		float(f_rect["h"]) * SCALE_FACTOR
	)
	draw_texture_rect_region(tex_characters, dst, src, modulate_col)


func _draw_goblin(gob: Dictionary, time_ms: float, time_sec: float) -> void:
	var pos: Vector2 = gob["pos"]
	var orient: String = "right" if float(gob.get("facing_x", -1.0)) >= 0.0 else "left"
	var anim_key: String = "goblin-sleep-" + orient
	var custom_prog: float = -1.0

	if not bool(gob["alive"]):
		anim_key = "goblin-death-fire-" + orient
		var dt: float = float(gob.get("death_timer", 0.0))
		custom_prog = clampf(1.0 - (dt / 1.2), 0.0, 1.0)
	elif float(gob.get("attack_timer", 0.0)) > 0.0:
		anim_key = "goblin-attack-" + orient
	elif bool(gob["awake"]) or bool(gob.get("returning", false)):
		if gob["vel"].length() > 5.0:
			anim_key = "goblin-chase-" + orient if bool(gob["awake"]) else "goblin-walk-" + orient
		else:
			anim_key = "goblin-walk-" + orient

	draw_circle(pos + Vector2(0, 16), 14.0, Color(0, 0, 0, 0.4))
	var frame_idx: int = _get_aseprite_frame_index(anim_key, time_ms + pos.x * 13.0, true, custom_prog)
	_draw_aseprite_frame(frame_idx, pos)

	# Indicador Zzz cuando duerme o ! cuando persigue
	var font: Font = ThemeDB.fallback_font
	if bool(gob["alive"]):
		if not bool(gob["awake"]) and not bool(gob.get("returning", false)):
			var z_bob: float = sin(time_sec * 3.5 + pos.x) * 2.5
			draw_string(font, pos + Vector2(8, -22 + z_bob), "Z z", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.85))
		elif bool(gob["awake"]):
			draw_string(font, pos + Vector2(-4, -26), "!", HORIZONTAL_ALIGNMENT_CENTER, 12, 15, Color("#ff3b3b"))


func _draw_miner(m: Dictionary, time_ms: float, time_sec: float) -> void:
	var pos: Vector2 = m["pos"]
	var skin: int = clampi(int(m.get("skin", 1)), 1, 13)
	var orient: String = "right" if float(m.get("facing_x", 1.0)) >= 0.0 else "left"
	var action: String = "idle"
	var custom_prog: float = -1.0

	if not bool(m.get("alive", true)):
		var reason: String = str(m.get("death_reason", "goblin"))
		action = "death-fire" if (reason == "fire" or reason == "bomb") else "death"
		var dt: float = float(m.get("death_timer", 0.0))
		custom_prog = clampf(1.0 - (dt / 1.2), 0.0, 1.0)
	elif bool(m.get("escaping", false)):
		action = "escape"
	elif bool(m.get("mining", false)) or float(m.get("mine_anim_timer", 0.0)) > 0.0:
		action = "mine"
	elif m["vel"].length() > 8.0:
		action = "walk"

	var anim_key: String = "player-" + action + "-" + orient + "-" + str(skin)
	draw_circle(pos + Vector2(0, 16), 14.0, Color(0, 0, 0, 0.42))

	# Parpadeo de invulnerabilidad inicial (como el tween de alpha 0.5..1.0 en Phaser)
	var mod_col := Color.WHITE
	if float(m.get("invulnerable_timer", 0.0)) > 0.0:
		mod_col.a = 0.55 + 0.45 * abs(sin(time_sec * 8.0))

	var frame_idx: int = _get_aseprite_frame_index(anim_key, time_ms, true, custom_prog)
	_draw_aseprite_frame(frame_idx, pos, mod_col)

	# Nombre del jugador e insignia de membresía (Gold / Diamond) sobre el personaje
	if bool(m.get("alive", true)) and not main_scene._state().hide_names:
		var font: Font = ThemeDB.fallback_font
		var uname: String = str(m.get("name", "Miner"))
		var badge_tier: String = str(m.get("membership", "gold"))
		var text_w: float = font.get_string_size(uname, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var total_w: float = text_w + (18.0 if badge_tier != "none" else 0.0)
		var start_x: float = pos.x - total_w * 0.5
		var name_y: float = pos.y - 30.0

		if badge_tier == "diamond":
			draw_rect(Rect2(start_x, name_y - 11, 14, 14), Color("#0284c7"), true)
			draw_circle(Vector2(start_x + 7, name_y - 4), 4.0, Color("#7dd3fc"))
			start_x += 18.0
		elif badge_tier == "gold":
			draw_rect(Rect2(start_x, name_y - 11, 14, 14), Color("#ca8a04"), true)
			draw_circle(Vector2(start_x + 7, name_y - 4), 4.0, Color("#fde047"))
			start_x += 18.0

		draw_string(font, Vector2(start_x + 1, name_y + 1), uname, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0, 0, 0, 0.9))
		draw_string(font, Vector2(start_x, name_y), uname, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.92))


func _draw_dynamic_lights(cam_pos: Vector2, half_view: Vector2, time_sec: float) -> void:
	# Simulación fiel del pipeline Light2D de Phaser (ambient #64748b + luces aditivas suaves)
	# Halo cálido en antorchas visibles
	for tpos in main_scene.torch_positions:
		var p: Vector2 = tpos
		if abs(p.x - cam_pos.x) < half_view.x + 120.0 and abs(p.y - cam_pos.y) < half_view.y + 120.0:
			var flick: float = 150.0 + sin(time_sec * 10.0 + p.x) * 10.0
			draw_texture_rect(tex_radial_light, Rect2(p.x - flick, p.y - flick, flick * 2.0, flick * 2.0), false, Color(1.0, 0.85, 0.2, 0.22))

	# Halo en el jugador y mineros (#e0f2fe)
	if main_scene.player.get("alive", false):
		var ppos: Vector2 = main_scene.player["pos"]
		var r: float = 220.0
		draw_texture_rect(tex_radial_light, Rect2(ppos.x - r, ppos.y - r, r * 2.0, r * 2.0), false, Color(0.88, 0.95, 1.0, 0.14))
