extends CerberusTest

var main_scene_packed: PackedScene = preload("res://scenes/main.tscn")
const GeneratorScript = preload("res://scripts/dungeon_generator.gd")

func _suite_name() -> String:
	return "PixelDungeonsGameplayTest"

func _make_game() -> Node2D:
	var game: Node2D = main_scene_packed.instantiate()
	game._load_icons_and_audio()
	game._setup_hud_ui()
	game.start_dungeon_run(0)
	return game


# Mapa de pruebas hecho a mano (todo suelo) con los muros que se indiquen
func _make_grid_game(width: int, height: int, walls: Array) -> Node2D:
	var game: Node2D = main_scene_packed.instantiate()
	game._load_icons_and_audio()
	game.grid_w = width
	game.grid_h = height
	game.map_width = float(width) * 48.0
	game.map_height = float(height) * 48.0
	var total: int = width * height
	game.layer_ground.resize(total)
	game.layer_ground.fill(130)
	game.layer_interactive.resize(total)
	game.layer_interactive.fill(0)
	game.layer_walls.resize(total)
	game.layer_walls.fill(0)
	game.layer_decorative.resize(total)
	game.layer_decorative.fill(0)
	for w in walls:
		var cell: Vector2i = w
		game.layer_walls[cell.y * width + cell.x] = 226
	game.collide_gids = {226: true, 227: true, 228: true, 229: true}
	game.fire_gids = {}
	game.torch_gids = {}
	game.walkable_cells.clear()
	for y in range(height):
		for x in range(width):
			if game.layer_walls[y * width + x] == 0:
				game.walkable_cells.append(Vector2i(x, y))
	game.lava_pools.clear()
	game.ores.clear()
	game.goblins.clear()
	game.bots.clear()
	game.loot_bags.clear()
	game.tnt_list.clear()
	game.player = {
		"name": "You",
		"pos": Vector2.ZERO,
		"vel": Vector2.ZERO,
		"pixels": 0,
		"dynamites": 1,
		"alive": true,
		"is_player": true,
		"skin": 1,
		"membership": "gold",
		"facing_x": 1.0,
		"mining": false,
		"mine_anim_timer": 0.0,
		"invulnerable_timer": 0.0,
		"death_timer": 0.0,
		"death_reason": "",
		"path": [],
		"path_i": 0,
		"repath_timer": 0.0
	}
	game._build_nav_grid()
	return game


func _make_goblin(pos: Vector2) -> Dictionary:
	return {
		"pos": pos,
		"home_pos": pos,
		"vel": Vector2.ZERO,
		"facing_x": -1.0,
		"awake": false,
		"alive": true,
		"attack_timer": 0.0,
		"death_timer": 0.0,
		"sight_radius": 330.0,
		"lose_timer": 0.0,
		"last_seen": Vector2.ZERO,
		"path": [],
		"path_i": 0,
		"path_fail": 0,
		"repath_timer": 0.0,
		"goal": Vector2.ZERO,
		"loot": 10
	}

func _make_bot(pos: Vector2) -> Dictionary:
	return {
		"name": "TestBot",
		"pos": pos,
		"vel": Vector2.ZERO,
		"pixels": 0,
		"dynamites": 0,
		"alive": true,
		"is_player": false,
		"skin": 2,
		"membership": "gold",
		"tint": Color.WHITE,
		"facing_x": 1.0,
		"mining": false,
		"mine_anim_timer": 0.0,
		"invulnerable_timer": 0.0,
		"death_timer": 0.0,
		"death_reason": "",
		"ai_timer": 0.0,
		"target_pos": pos,
		"skill": 1.0,
		"greed": 0.9,
		"courage": 0.5,
		"state": "idle",
		"goal": Vector2.ZERO,
		"path": [],
		"path_i": 0,
		"path_fail": 0,
		"repath_timer": 0.0
	}


func test_official_assets_and_tiled_maps_loaded() -> void:
	var game: Node2D = _make_game()
	assert_eq(game._state().DUNGEON_CONFIGS.size(), 10, "deben existir los 10 mapas oficiales de pixeldungeons.xyz")
	assert_true(game.grid_w > 0 and game.grid_h > 0, "el mapa Tiled oficial debe haberse cargado con dimensiones válidas")
	assert_eq(game.layer_ground.size(), game.grid_w * game.grid_h, "la capa ground del Tiled JSON debe estar cargada")
	assert_true(game.walkable_cells.size() > 50, "debe haber celdas caminables extraídas del mapa oficial")

	var canvas: Node2D = game.get_node("WorldCanvas")
	canvas._ensure_assets_loaded()
	assert_not_null(canvas.tex_tileset, "tileset.png oficial debe cargarse")
	assert_not_null(canvas.tex_characters, "characters.png oficial debe cargarse")
	assert_eq(canvas.char_frames.size(), 1262, "el JSON Aseprite oficial debe tener los 1262 frames de personajes")
	assert_true(canvas.char_anims.has("player-idle-right-1"), "debe existir la animación oficial player-idle-right-1")
	assert_true(canvas.char_anims.has("goblin-sleep-left"), "debe existir la animación oficial goblin-sleep-left")
	game.free()

func test_bag_weight_slows_miner() -> void:
	var st := PixelDungeonsState.new()
	var speed_empty: float = st.compute_speed_multiplier(0, 100)
	var speed_half: float = st.compute_speed_multiplier(50, 100)
	var speed_full: float = st.compute_speed_multiplier(100, 100)
	assert_almost_eq(speed_empty, 1.0, 0.001, "sin $PIXEL la velocidad debe ser 100%")
	assert_true(speed_half < speed_empty, "con 50 $PIXEL debe moverse más lento que vacío")
	assert_true(speed_full < speed_half, "con 100 $PIXEL debe moverse aún más lento")
	assert_eq(st.compute_bag_weight_percent(55, 100), 55, "el porcentaje de peso de la bolsa debe coincidir")

func test_mining_ore_and_epic_ore_yields_pixels() -> void:
	var game: Node2D = _make_game()
	var normal_ore: Dictionary = {
		"pos": Vector2(200, 200),
		"hp": 30.0,
		"max_hp": 30.0,
		"value": 8,
		"is_epic": false,
		"alive": true
	}
	var epic_ore: Dictionary = {
		"pos": Vector2(240, 200),
		"hp": 100.0,
		"max_hp": 100.0,
		"value": 45,
		"is_epic": true,
		"alive": true
	}
	game.player["pixels"] = 0
	game._damage_ore(normal_ore, game.player, 35.0)
	assert_false(normal_ore["alive"], "la veta normal debe romperse al llegar a 0 HP")
	assert_eq(game.player["pixels"], 8, "el minero debe recibir los $PIXEL de la veta")

	game._damage_ore(epic_ore, game.player, 110.0)
	assert_false(epic_ore["alive"], "el EPIC $PIXEL ORE debe romperse")
	assert_eq(game.player["pixels"], 53, "el minero debe acumular el gran premio del EPIC ORE")
	game.free()

func test_tnt_kills_goblins_and_drops_loot_bag() -> void:
	var game: Node2D = _make_game()
	game.goblins.clear()
	game.bots.clear()
	game.loot_bags.clear()
	game.tnt_list.clear()
	# Sin vetas ni bots cerca: la explosión no debe generar bolsas extra
	for ore in game.ores:
		ore["alive"] = false
		if ore.has("cell"):
			game._set_ore_block(ore["cell"], false)
	game.ores.clear()

	# Alejar al jugador para que no muera con su propio TNT
	game.player["pos"] = Vector2(500, 500)
	game.player["dynamites"] = 3
	var planted: bool = game.try_place_tnt(game.player)
	assert_true(planted, "debe poder plantar TNT con clic derecho / tecla E")
	assert_eq(game.player["dynamites"], 2, "debe descontar 1 dinamita")

	# Colocar un goblin sobre el TNT y alejar al jugador
	var tnt_pos: Vector2 = game.tnt_list[0]["pos"]
	game.goblins.append({
		"pos": tnt_pos + Vector2(15, 0),
		"vel": Vector2.ZERO,
		"awake": false,
		"alive": true,
		"loot": 25
	})
	game.player["pos"] = tnt_pos + Vector2(300, 0)

	game._update_tnt(2.5)
	assert_false(game.goblins[0]["alive"], "el Goblin dentro del radio de explosión debe morir")
	assert_eq(game.loot_bags.size(), 1, "el Goblin eliminado debe soltar 1 bolsa de botín $PIXEL")
	assert_eq(game.loot_bags[0]["amount"], 25, "la bolsa debe contener los $PIXEL del Goblin")
	game.free()

func test_lava_is_instant_death_and_drops_bag() -> void:
	var game: Node2D = _make_game()
	game.loot_bags.clear()
	var lava_pos: Vector2 = game.lava_pools[0]["pos"]
	game.player["pos"] = lava_pos
	game.player["pixels"] = 33
	assert_true(game._is_touching_lava(game.player["pos"]), "debe detectar colisión con el pozo de lava")
	game._kill_miner(game.player, "fire")
	assert_false(game.player["alive"], "la lava debe causar muerte instantánea")
	assert_eq(game.player["pixels"], 0, "el jugador pierde los $PIXEL que llevaba encima")
	assert_eq(game.loot_bags.size(), 1, "al morir suelta su bolsa de botín en el suelo")
	assert_eq(game.loot_bags[0]["amount"], 33, "la bolsa caída guarda los 33 $PIXEL para quien la robe")
	game.free()

func test_survival_2_minutes_transfers_pixels_to_wallet() -> void:
	var game: Node2D = _make_game()
	var initial_wallet: int = game._state().wallet_pixels
	game.player["pixels"] = 64
	game.time_left = 0.05
	game._update_round(0.1)
	assert_false(game.round_active, "la ronda termina al llegar el reloj a 00:00")
	assert_eq(game._state().wallet_pixels, initial_wallet + 64, "sobrevivir transfiere todo el $PIXEL recolectado a la Wallet")
	game.free()


# ------------------------------------------------------------------ procedural


func _count_reachable(res: Dictionary) -> int:
	var w: int = int(res["width"])
	var h: int = int(res["height"])
	var ground: PackedInt32Array = res["layer_ground"]
	var walls: PackedInt32Array = res["layer_walls"]
	var inter: PackedInt32Array = res["layer_interactive"]
	var floor_cells: Dictionary = {}
	for y in range(h):
		for x in range(w):
			var i: int = y * w + x
			if walls[i] == 0 and ground[i] > 0 and inter[i] == 0:
				floor_cells[Vector2i(x, y)] = true
	var spawn: Vector2i = res["spawn_cell"]
	if not floor_cells.has(spawn):
		return 0
	var seen: Dictionary = {spawn: true}
	var queue: Array = [spawn]
	while queue.size() > 0:
		var cur: Vector2i = queue.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if floor_cells.has(n) and not seen.has(n):
				seen[n] = true
				queue.append(n)
	return seen.size()


func test_dungeons_offer_small_med_and_big_styles() -> void:
	var game: Node2D = _make_game()
	var styles: Dictionary = {}
	var layouts: Dictionary = {}
	for cfg in game._state().DUNGEON_CONFIGS:
		styles[str(cfg.get("style", ""))] = true
		layouts[str(cfg.get("layout", ""))] = true
		assert_true(bool(cfg.has("ore_density")) and bool(cfg.has("goblin_density")), "cada mazmorra debe escalar minerales y goblins por densidad")
	assert_true(styles.has("small") and styles.has("med") and styles.has("big"), "deben existir estilos small, med y big")
	assert_true(layouts.size() >= 3, "debe haber variedad de familias de layout")
	game.free()


func test_procedural_generator_is_deterministic_and_connected() -> void:
	for style in ["small", "med", "big"]:
		for layout in ["chambers", "corridors", "caverns", "labyrinth", "rings"]:
			var gen: RefCounted = GeneratorScript.new(style, layout)
			var a: Dictionary = gen.generate(987654)
			var b: Dictionary = gen.generate(987654)
			assert_eq(a["layer_walls"], b["layer_walls"], "misma semilla + layout (%s/%s) = mismo mapa" % [style, layout])
			assert_true(int(a["floor_count"]) > 60, "el layout %s/%s debe generar suelo suficiente" % [style, layout])
			assert_eq(_count_reachable(a), int(a["floor_count"]), "todas las celdas de %s/%s deben ser alcanzables desde el spawn" % [style, layout])


func test_procedural_map_changes_on_every_run() -> void:
	var game: Node2D = _make_game()
	game.start_dungeon_run(0)
	var seed_a: int = game.map_seed
	var walls_a: PackedInt32Array = game.layer_walls.duplicate()
	assert_eq(str(game.map_style), "small", "la mazmorra 0 es de estilo small")
	game.start_dungeon_run(0)
	assert_ne(seed_a, game.map_seed, "cada partida nueva debe usar otra semilla procedural")
	assert_ne(walls_a, game.layer_walls, "el layout de la mazmorra debe cambiar al reabrirla")
	assert_eq(game.layer_ground.size(), game.grid_w * game.grid_h, "las capas deben cubrir toda la rejilla")
	assert_true(game.walkable_cells.size() > 40, "el mapa procedural debe tener zonas transitables")
	assert_true(game.astar != null, "debe existir la rejilla A* de navegación")
	game.free()


# ------------------------------------------------------------------ navegación y visión


func test_pathfinding_routes_around_walls() -> void:
	var walls: Array = []
	for y in range(0, 10):
		walls.append(Vector2i(6, y))
	var game: Node2D = _make_grid_game(12, 12, walls)
	var from_pos: Vector2 = game._cell_to_world(Vector2i(2, 5))
	var to_pos: Vector2 = game._cell_to_world(Vector2i(10, 5))
	assert_false(game._has_line_of_sight(from_pos, to_pos), "el muro debe cortar la línea de visión")
	var path: Array = game._nav_path(from_pos, to_pos)
	assert_true(path.size() > 0, "A* debe encontrar una ruta rodeando el muro")
	var prev: Vector2 = from_pos
	var contiguous: bool = true
	for p in path:
		var cell: Vector2i = game._world_to_cell(p)
		if not game._is_cell_walkable(cell):
			contiguous = false
		if prev.distance_to(p) > 48.0 * 1.6:
			contiguous = false
		prev = p
	assert_true(contiguous, "cada paso de la ruta debe ser transitable y contiguo")
	assert_true(prev.distance_to(to_pos) < 1.0, "la ruta debe terminar en el destino")
	game.free()


func test_goblin_cannot_chase_without_line_of_sight() -> void:
	var walls: Array = []
	for y in range(0, 10):
		walls.append(Vector2i(6, y))
	var game: Node2D = _make_grid_game(12, 12, walls)
	game.goblins.append(_make_goblin(game._cell_to_world(Vector2i(4, 5))))
	game.player["pos"] = game._cell_to_world(Vector2i(10, 5))
	var start_dist: float = game.goblins[0]["pos"].distance_to(game.player["pos"])
	for _i in range(40):
		game._update_goblins(1.0 / 60.0)
	assert_false(bool(game.goblins[0]["awake"]), "sin línea de visión el goblin no debe despertar")
	assert_almost_eq(game.goblins[0]["pos"].distance_to(game.player["pos"]), start_dist, 1.0, "el goblin no debe avanzar hacia un objetivo que no ve")

	# Con visión directa sí persigue
	var game2: Node2D = _make_grid_game(12, 12, [])
	game2.goblins.append(_make_goblin(game2._cell_to_world(Vector2i(2, 5))))
	game2.player["pos"] = game2._cell_to_world(Vector2i(6, 5))
	for _j in range(12):
		game2._update_goblins(1.0 / 60.0)
	assert_true(bool(game2.goblins[0]["awake"]), "con visión directa el goblin debe despertar y perseguir")
	game.free()
	game2.free()


func test_goblins_are_slower_than_player() -> void:
	var game: Node2D = _make_game()
	var consts: Dictionary = game.get_script().get_script_constant_map()
	var gob_speed: float = float(consts["GOBLIN_SPEED"])
	var gob_chase: float = float(consts["GOBLIN_CHASE_SPEED"])
	var player_speed: float = float(consts["BASE_PLAYER_SPEED"])
	assert_true(gob_speed < player_speed * 0.6, "los goblins deben caminar bastante más lentos que el jugador")
	assert_true(gob_chase < player_speed, "incluso persiguiendo deben ser más lentos que el jugador sin carga")
	game.free()


func test_bots_path_towards_ore_and_start_mining() -> void:
	var walls: Array = []
	for y in range(0, 8):
		walls.append(Vector2i(6, y))
	var game: Node2D = _make_grid_game(14, 12, walls)
	game.bots.clear()
	game.bots.append(_make_bot(game._cell_to_world(Vector2i(2, 2))))
	var ore_cell := Vector2i(10, 10)
	game.ores.append({
		"pos": game._cell_to_world(ore_cell),
		"cell": ore_cell,
		"hp": 60.0,
		"max_hp": 60.0,
		"value": 20,
		"is_epic": false,
		"alive": true,
		"shake_ttl": 0.0
	})
	game._set_ore_block(ore_cell, true)
	var start: Vector2 = game.bots[0]["pos"]
	for _i in range(180):
		game._update_bots(1.0 / 60.0)
	assert_true(game.bots[0]["pos"].distance_to(start) > 30.0, "el bot debe desplazarse hacia la veta por la ruta A*")
	assert_eq(str(game.bots[0]["state"]), "mine", "el bot debe acabar en estado minar")
	game.free()


# ------------------------------------------------------------------ minerales


func test_ore_veins_block_movement_and_take_longer_to_mine() -> void:
	var game: Node2D = _make_game()
	var ore: Dictionary = game.ores[0]
	var cell: Vector2i = ore["cell"]
	assert_false(game._is_cell_walkable(cell), "las vetas de mineral no deben ser atravesables")
	assert_true(game.astar.is_point_solid(cell), "A* debe tratar la veta como obstáculo")

	var consts: Dictionary = game.get_script().get_script_constant_map()
	var dps: float = float(consts["PLAYER_MINE_DPS"])
	var seconds: float = float(ore["max_hp"]) / maxf(0.01, dps)
	assert_true(seconds >= 3.0, "picar una veta normal debe llevar al menos 3 segundos (actual: %.1fs)" % seconds)

	game.player["pixels"] = 0
	game._damage_ore(ore, game.player, float(ore["max_hp"]) + 1.0)
	assert_false(ore["alive"], "la veta se rompe al agotar su HP")
	assert_true(game._is_cell_walkable(cell), "al romperse la veta la celda vuelve a ser transitable")
	assert_true(int(game.player["pixels"]) > 0, "el minero recibe el $PIXEL de la veta")
	game.free()


func test_rock_collision_prevents_tunneling_and_lava_rim_is_safe() -> void:
	# Muro en (5,5): empujar con un vector grande no debe atravesar la roca
	var game: Node2D = _make_grid_game(12, 12, [Vector2i(5, 5)])
	var start_pos: Vector2 = game._cell_to_world(Vector2i(4, 5))
	var moved: Vector2 = game._move_with_obstacles(start_pos, Vector2(96.0, 0.0), false)
	var wall_left_x: float = 5.0 * 48.0
	assert_true(moved.x <= wall_left_x - 13.5, "el colisionador circular con sub-stepping no debe atravesar la roca")

	# Celda de borde inferior de lava (GID 183: magma sólo en el 25% superior, piedra en el 75% inferior)
	var lava_cell := Vector2i(6, 8)
	game.fire_gids[183] = true
	game.layer_interactive[lava_cell.y * game.grid_w + lava_cell.x] = 183
	var stone_rim_pos := Vector2((float(lava_cell.x) + 0.5) * 48.0, (float(lava_cell.y) + 0.80) * 48.0)
	var magma_core_pos := Vector2((float(lava_cell.x) + 0.5) * 48.0, (float(lava_cell.y) + 0.10) * 48.0)
	assert_false(game._is_touching_lava(stone_rim_pos), "pisar el reborde de piedra del tile de costa NO debe matar por lava")
	assert_true(game._is_touching_lava(magma_core_pos), "pisar la parte naranja de magma SÍ debe detectar lava")
	game.free()


