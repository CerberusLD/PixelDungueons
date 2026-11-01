extends Node2D

# Constantes de mundo y jugabilidad compatibles con tests y con pixeldungeons.xyz
const WORLD_TILE: float = 48.0 # 16px tile * 3.0 scale
const MAP_WIDTH: float = 1920.0
const MAP_HEIGHT: float = 1920.0
const ROUND_DURATION: float = 120.0
const BASE_PLAYER_SPEED: float = 215.0
# Goblins: lentos al caminar, algo más rápidos al cazar, pero muy por debajo del jugador
const GOBLIN_WAKE_RADIUS: float = 170.0
const GOBLIN_SIGHT_RADIUS: float = 330.0
const GOBLIN_SPEED: float = 108.0
const GOBLIN_CHASE_SPEED: float = 124.0
const GOBLIN_LEASH_RADIUS: float = 430.0
const GOBLIN_LOSE_SIGHT_TIME: float = 2.4
const GOBLIN_ATTACK_RANGE: float = 26.0
const ENTITY_COLLIDER_RADIUS: float = 14.0
const LAVA_PROBE_RADIUS: float = 8.0
const TNT_FUSE_TIME: float = 1.5
const TNT_BLAST_RADIUS: float = 105.0
const MINE_RANGE: float = 88.0
const PLAYER_MINE_DPS: float = 31.2
const BOT_MINE_DPS: float = 17.55
const MAX_BAG_CAPACITY: int = 100
const ORE_HP_NORMAL: float = 62.0
const ORE_HP_EPIC: float = 165.0

const DungeonGenerator = preload("res://scripts/dungeon_generator.gd")

var grid_w: int = 40
var grid_h: int = 40
var map_width: float = 1920.0
var map_height: float = 1920.0

var layer_ground: PackedInt32Array = PackedInt32Array()
var layer_interactive: PackedInt32Array = PackedInt32Array()
var layer_walls: PackedInt32Array = PackedInt32Array()
var layer_decorative: PackedInt32Array = PackedInt32Array()

var collide_gids: Dictionary = {}
var fire_gids: Dictionary = {}
var torch_gids: Dictionary = {}
var walkable_cells: Array[Vector2i] = []
var spawn_cells: Array[Vector2i] = []
var ore_spots: Array[Vector2i] = []
var torch_positions: Array[Vector2] = []

# --- Navegación (A*) y bloqueos dinámicos por vetas de mineral ---
var astar: AStarGrid2D = null
var ore_cells: Dictionary = {}       # Vector2i -> Dictionary (veta)
var map_style: String = "small"
var map_layout: String = "chambers"
var map_seed: int = 0
var map_floor_count: int = 0
var spawn_hint: Vector2i = Vector2i(1, 1)
# Semilla pendiente por mazmorra: cambia cada vez que la partida se cierra
var dungeon_seeds: Dictionary = {}
var cards_grid: GridContainer = null


var round_active: bool = false
var time_left: float = ROUND_DURATION
var simulated_ping_ms: int = 42
var ping_timer: float = 0.0
var footstep_timer: float = 0.0
var shot_path: String = ""
var shot_mode: String = "gameplay" # "gameplay" o "dashboard"
var shot_taken: bool = false
var shot_elapsed: float = 0.0

var player: Dictionary = {}
var bots: Array[Dictionary] = []
var goblins: Array[Dictionary] = []
var ores: Array[Dictionary] = []
var lava_pools: Array[Dictionary] = []
var rock_pillars: Array[Dictionary] = []
var loot_bags: Array[Dictionary] = []
var tnt_list: Array[Dictionary] = []
var explosions: Array[Dictionary] = []
var floating_texts: Array[Dictionary] = []
var feed_entries: Array[Dictionary] = []

@onready var world_canvas: Node2D = $WorldCanvas
@onready var camera: Camera2D = $Camera2D
@onready var hud_layer: CanvasLayer = $HUD

# Referencias UI (compatibles con escena original + HUD pixel art oficial)
var lbl_timer: Label
var lbl_pixels: Label
var lbl_dynamite: Label
var lbl_weight: Label
var lbl_ping_fps: Label
var lbl_feed: Label
var lbl_hint: Label
var overlay_panel: Panel
var lbl_overlay_title: Label
var lbl_overlay_stats: Label
var btn_free_dungeon: Button
var btn_vip_dungeon: Button

# Nuevos nodos del HUD y Dashboard 1:1 de pixeldungeons.xyz
var official_hud_root: Control
var lbl_hud_time: Label
var lbl_hud_pixels: Label
var lbl_hud_bombs: Label
var lbl_hud_weight: Label
var lbl_hud_ping: Label
var lbl_hud_fps: Label
var toast_vbox: VBoxContainer
var enter_modal: PanelContainer
var lbl_enter_title: Label
var lbl_enter_bounty: Label
var lbl_enter_rules: Label
var btn_enter_start: Button
var btn_open_dashboard: Button
var dashboard_overlay: Control
var settings_modal: PanelContainer
var skin_button_label: Label
var lbl_sidebar_pixels: Label
var lbl_sidebar_pickaxes: Label

var sfx_players: Dictionary = {}
var icon_textures: Dictionary = {}
var _local_state: Node = null
var _ui_built: bool = false

const BOT_NAMES: Array[String] = [
	"Nelliel", "Breadcrumb2044", "Franvill", "CryptoMiner",
	"RoninWhale", "GigaPickaxe", "TaikoRunner", "PixelHunter"
]
const BOT_TINTS: Array[Color] = [
	Color("#ffd43b"), Color("#d99b26"), Color("#69db7c"), Color("#4dabf7"),
	Color("#da77f2"), Color("#ff8787"), Color("#3bc9db"), Color("#ffa94d")
]


func _state() -> Node:
	if is_inside_tree():
		var st: Node = get_node_or_null("/root/GameState")
		if st != null:
			return st
	if _local_state == null:
		var scr: Script = load("res://scripts/game_state.gd")
		_local_state = scr.new()
	return _local_state


func _ready() -> void:
	world_canvas = get_node_or_null("WorldCanvas")
	camera = get_node_or_null("Camera2D")
	hud_layer = get_node_or_null("HUD")
	if world_canvas != null:
		world_canvas.set("main_scene", self)
	_load_icons_and_audio()
	_setup_hud_ui()
	_check_cmdline_args()
	if shot_path != "":
		start_dungeon_run(_state().selected_dungeon)
		_seed_showcase_action()
		if shot_mode == "dashboard" and dashboard_overlay != null:
			dashboard_overlay.visible = true
			if enter_modal != null:
				enter_modal.visible = false
	else:
		start_dungeon_run(_state().selected_dungeon)


func _check_cmdline_args() -> void:
	var all_args: PackedStringArray = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for arg in all_args:
		if arg.begins_with("--shot="):
			shot_path = arg.substr("--shot=".length())
		elif arg.begins_with("--shot-dashboard="):
			shot_path = arg.substr("--shot-dashboard=".length())
			shot_mode = "dashboard"
		elif arg.begins_with("--dungeon="):
			_state().selected_dungeon = int(arg.substr("--dungeon=".length()))


func _load_icons_and_audio() -> void:
	var icon_files: Dictionary = {
		"clock": "res://assets/sprites/clock.png",
		"pixel": "res://assets/sprites/pixel.png",
		"bomb": "res://assets/sprites/bomb.png",
		"weight": "res://assets/sprites/weight.png",
		"pickaxe": "res://assets/sprites/pickaxe.png",
		"diamond": "res://assets/sprites/diamond.png",
		"ore": "res://assets/sprites/ore.png",
		"goblin": "res://assets/sprites/goblin_head.png",
		"player": "res://assets/sprites/player_head.png",
		"lava": "res://assets/sprites/player_lava_death.png",
		"logo": "res://assets/sprites/pixel_dungeons_logo.png",
		"gold": "res://assets/sprites/gold_membership.png",
		"diamond_mem": "res://assets/sprites/diamond_membership.png"
	}
	for k in icon_files.keys():
		var p: String = icon_files[k]
		if ResourceLoader.exists(p):
			icon_textures[k] = load(p)

	var audio_files: Dictionary = {
		"backpack-pickup": "res://assets/audio/sfx_backpack_pickup.ogg",
		"bomb-explosion": "res://assets/audio/sfx_bomb_explosion.ogg",
		"collect": "res://assets/audio/sfx_collect.ogg",
		"epic-ore-found": "res://assets/audio/sfx_epic_ore_found.ogg",
		"footsteps": "res://assets/audio/sfx_footsteps.ogg",
		"goblin-attack": "res://assets/audio/sfx_goblin_attack.ogg",
		"goblin-rage": "res://assets/audio/sfx_goblin_rage.ogg",
		"lava-death": "res://assets/audio/sfx_lava_death.ogg",
		"mine-epic": "res://assets/audio/sfx_mine_epic.ogg",
		"mining": "res://assets/audio/sfx_mining.ogg"
	}
	for sname in audio_files.keys():
		var apath: String = audio_files[sname]
		if ResourceLoader.exists(apath):
			var asp := AudioStreamPlayer.new()
			asp.stream = load(apath)
			asp.volume_db = -6.0
			add_child(asp)
			sfx_players[sname] = asp


func _play_sfx(sfx_name: String, vol_db: float = -6.0) -> void:
	if not is_inside_tree():
		return
	if sfx_players.has(sfx_name):
		var asp: AudioStreamPlayer = sfx_players[sfx_name]
		asp.volume_db = vol_db
		asp.play()


func _setup_hud_ui() -> void:
	world_canvas = get_node_or_null("WorldCanvas")
	camera = get_node_or_null("Camera2D")
	hud_layer = get_node_or_null("HUD")
	if hud_layer == null:
		return

	lbl_timer = get_node_or_null("HUD/TopLeftPanel/TimerValue")
	lbl_pixels = get_node_or_null("HUD/TopLeftPanel/PixelValue")
	lbl_dynamite = get_node_or_null("HUD/TopLeftPanel/DynamiteValue")
	lbl_weight = get_node_or_null("HUD/TopLeftPanel/WeightValue")
	lbl_ping_fps = get_node_or_null("HUD/TopRightPanel/PingFpsLabel")
	lbl_feed = get_node_or_null("HUD/TopRightPanel/FeedLabel")
	lbl_hint = get_node_or_null("HUD/BottomBar/HintLabel")
	overlay_panel = get_node_or_null("HUD/LobbyOverlay")
	lbl_overlay_title = get_node_or_null("HUD/LobbyOverlay/OverlayTitle")
	lbl_overlay_stats = get_node_or_null("HUD/LobbyOverlay/OverlayStats")
	btn_free_dungeon = get_node_or_null("HUD/LobbyOverlay/BtnFreeDungeon")
	btn_vip_dungeon = get_node_or_null("HUD/LobbyOverlay/BtnVipDungeon")

	# Ocultar los paneles antiguos de prototipo para mostrar el HUD flotante 1:1 de pixeldungeons.xyz
	var old_tl: Control = get_node_or_null("HUD/TopLeftPanel")
	var old_tr: Control = get_node_or_null("HUD/TopRightPanel")
	var old_bb: Control = get_node_or_null("HUD/BottomBar")
	if old_tl != null:
		old_tl.visible = false
	if old_tr != null:
		old_tr.visible = false
	if old_bb != null:
		old_bb.visible = false
	if overlay_panel != null:
		overlay_panel.visible = false

	if not _ui_built:
		_ui_built = true
		if btn_free_dungeon != null:
			btn_free_dungeon.pressed.connect(func(): _on_select_dungeon(0))
		if btn_vip_dungeon != null:
			btn_vip_dungeon.pressed.connect(func(): _on_select_dungeon(1))
		_build_official_pixeldungeons_ui()


func _make_stylebox(bg: Color, border: Color, radius: int = 8, border_w: int = 1, pad: int = 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	return sb


func _make_icon_rect(tex_key: String, sz: Vector2) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if icon_textures.has(tex_key):
		tr.texture = icon_textures[tex_key]
	tr.custom_minimum_size = sz
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return tr


func _add_shadow_label(parent: Node, txt: String, fsize: int, col: Color = Color.WHITE) -> Label:
	var lbl := Label.new()
	lbl.text = txt
	lbl.add_theme_font_size_override("font_size", fsize)
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	parent.add_child(lbl)
	return lbl


func _build_official_pixeldungeons_ui() -> void:
	official_hud_root = Control.new()
	official_hud_root.name = "OfficialHUD"
	official_hud_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	official_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(official_hud_root)

	# 1. ESQUINA SUPERIOR IZQUIERDA (Idéntico a q() en playchunk2_8780: Time Left + Reloj + Lista vertical de $PIXEL, Bombas y Peso)
	var tl_vbox := VBoxContainer.new()
	tl_vbox.position = Vector2(28, 22)
	tl_vbox.add_theme_constant_override("separation", 6)
	tl_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	official_hud_root.add_child(tl_vbox)

	_add_shadow_label(tl_vbox, "Time Left", 18, Color("#f1f5f9"))

	var timer_row := HBoxContainer.new()
	timer_row.add_theme_constant_override("separation", 10)
	tl_vbox.add_child(timer_row)
	timer_row.add_child(_make_icon_rect("clock", Vector2(40, 40)))
	lbl_hud_time = _add_shadow_label(timer_row, "01:00", 36, Color.WHITE)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 18)
	tl_vbox.add_child(spacer)

	# Fila 1: $PIXEL recolectados
	var row_px := HBoxContainer.new()
	row_px.add_theme_constant_override("separation", 10)
	tl_vbox.add_child(row_px)
	row_px.add_child(_make_icon_rect("pixel", Vector2(34, 31)))
	lbl_hud_pixels = _add_shadow_label(row_px, "0", 28, Color.WHITE)

	# Fila 2: Bombas restantes
	var row_bm := HBoxContainer.new()
	row_bm.add_theme_constant_override("separation", 10)
	tl_vbox.add_child(row_bm)
	row_bm.add_child(_make_icon_rect("bomb", Vector2(34, 34)))
	lbl_hud_bombs = _add_shadow_label(row_bm, "3", 28, Color.WHITE)

	# Fila 3: Peso de la mochila (%)
	var row_wt := HBoxContainer.new()
	row_wt.add_theme_constant_override("separation", 10)
	tl_vbox.add_child(row_wt)
	row_wt.add_child(_make_icon_rect("weight", Vector2(34, 34)))
	lbl_hud_weight = _add_shadow_label(row_wt, "0%", 28, Color.WHITE)

	# 2. ESQUINA SUPERIOR DERECHA: Ping ms + FPS + Botones Dungeons / Pantalla Completa / Ajustes + Toasts Oscuros
	var tr_vbox := VBoxContainer.new()
	tr_vbox.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	tr_vbox.offset_left = -440
	tr_vbox.offset_top = 22
	tr_vbox.offset_right = -24
	tr_vbox.offset_bottom = 360
	tr_vbox.add_theme_constant_override("separation", 10)
	tr_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	official_hud_root.add_child(tr_vbox)

	var top_bar_right := HBoxContainer.new()
	top_bar_right.alignment = BoxContainer.ALIGNMENT_END
	top_bar_right.add_theme_constant_override("separation", 14)
	tr_vbox.add_child(top_bar_right)

	lbl_hud_ping = _add_shadow_label(top_bar_right, "42 ms", 15, Color("#4ade80"))
	lbl_hud_fps = _add_shadow_label(top_bar_right, "60 fps", 15, Color("#f8fafc"))

	btn_open_dashboard = Button.new()
	btn_open_dashboard.text = "Dungeons"
	btn_open_dashboard.add_theme_stylebox_override("normal", _make_stylebox(Color("#1f2937"), Color("#4b5563"), 6, 1, 6))
	btn_open_dashboard.add_theme_stylebox_override("hover", _make_stylebox(Color("#374151"), Color("#87ED00"), 6, 1, 6))
	btn_open_dashboard.pressed.connect(func():
		dashboard_overlay.visible = not dashboard_overlay.visible
		if dashboard_overlay.visible:
			_refresh_dashboard_cards()
	)

	top_bar_right.add_child(btn_open_dashboard)

	var btn_skin := Button.new()
	btn_skin.text = "Skin #" + str(_state().selected_skin)
	btn_skin.add_theme_stylebox_override("normal", _make_stylebox(Color("#1f2937"), Color("#4b5563"), 6, 1, 6))
	btn_skin.pressed.connect(func():
		_state().selected_skin = (_state().selected_skin % 13) + 1
		player["skin"] = _state().selected_skin
		btn_skin.text = "Skin #" + str(_state().selected_skin)
		if skin_button_label != null:
			skin_button_label.text = str(_state().SKIN_NAMES.get(_state().selected_skin, "Miner"))
		_state().save_state()
	)
	top_bar_right.add_child(btn_skin)

	var btn_lights := Button.new()
	btn_lights.text = "⚙"
	btn_lights.tooltip_text = "Settings (Ctrl+,)"
	btn_lights.add_theme_stylebox_override("normal", _make_stylebox(Color("#1f2937"), Color("#4b5563"), 6, 1, 6))
	btn_lights.pressed.connect(func():
		settings_modal.visible = not settings_modal.visible
	)
	top_bar_right.add_child(btn_lights)

	toast_vbox = VBoxContainer.new()
	toast_vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	toast_vbox.add_theme_constant_override("separation", 8)
	toast_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr_vbox.add_child(toast_vbox)

	# 3. MODAL DE FIN DE PARTIDA / ENTRAR A LA MAZMORRA (Idéntico a eS / ej en playchunk2_8780)
	enter_modal = PanelContainer.new()
	enter_modal.visible = false
	enter_modal.set_anchors_preset(Control.PRESET_CENTER)
	enter_modal.offset_left = -250
	enter_modal.offset_top = -195
	enter_modal.offset_right = 250
	enter_modal.offset_bottom = 195
	enter_modal.add_theme_stylebox_override("panel", _make_stylebox(Color("#111827"), Color("#374151"), 14, 1, 24))
	official_hud_root.add_child(enter_modal)

	var m_vbox := VBoxContainer.new()
	m_vbox.add_theme_constant_override("separation", 12)
	enter_modal.add_child(m_vbox)

	lbl_enter_title = Label.new()
	lbl_enter_title.text = "Enter the dungeon"
	lbl_enter_title.add_theme_font_size_override("font_size", 22)
	lbl_enter_title.add_theme_color_override("font_color", Color.WHITE)
	m_vbox.add_child(lbl_enter_title)

	lbl_enter_bounty = Label.new()
	lbl_enter_bounty.text = "1515.00 $PIXEL await you inside"
	lbl_enter_bounty.add_theme_font_size_override("font_size", 16)
	lbl_enter_bounty.add_theme_color_override("font_color", Color("#9ca3af"))
	m_vbox.add_child(lbl_enter_bounty)

	lbl_enter_rules = Label.new()
	lbl_enter_rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl_enter_rules.text = (
		"1. You have 2 minutes to collect $PIXEL. If you survive, the collected amount will be sent to your wallet.\n" +
		"2. Move using WASD. Left-click / Space to mine diamonds and Right-click / E to place bombs.\n" +
		"3. If you die, your items will spawn on the ground. Beware of lava, goblins, and bombs."
	)
	lbl_enter_rules.add_theme_font_size_override("font_size", 14)
	lbl_enter_rules.add_theme_color_override("font_color", Color("#d1d5db"))
	m_vbox.add_child(lbl_enter_rules)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	m_vbox.add_child(btn_row)

	btn_enter_start = Button.new()
	btn_enter_start.text = "Play Again"
	btn_enter_start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_enter_start.custom_minimum_size = Vector2(0, 44)
	btn_enter_start.add_theme_stylebox_override("normal", _make_stylebox(Color("#6366f1"), Color("#818cf8"), 8, 1, 10))
	btn_enter_start.add_theme_stylebox_override("hover", _make_stylebox(Color("#4f46e5"), Color("#a5b4fc"), 8, 1, 10))
	btn_enter_start.pressed.connect(func():
		enter_modal.visible = false
		_on_select_dungeon(_state().selected_dungeon)
	)
	btn_row.add_child(btn_enter_start)

	var btn_view_dungeons := Button.new()
	btn_view_dungeons.text = "All Dungeons (10 Procedural)"
	btn_view_dungeons.custom_minimum_size = Vector2(180, 44)
	btn_view_dungeons.add_theme_stylebox_override("normal", _make_stylebox(Color("#1f2937"), Color("#374151"), 8, 1, 10))
	btn_view_dungeons.pressed.connect(func():
		enter_modal.visible = false
		dashboard_overlay.visible = true
		_refresh_dashboard_cards()
	)
	btn_row.add_child(btn_view_dungeons)

	# 4. MODAL DE SETTINGS OFICIAL (Enable Lights, Hide HUD, Hide Names, Hide Rewards)
	_build_settings_modal()

	# 5. DASHBOARD DE DUNGEONS OFICIAL (Sidebar + 10 Tarjetas con previews reales de pixeldungeons.xyz)
	_build_dashboard_overlay()


func _build_settings_modal() -> void:
	settings_modal = PanelContainer.new()
	settings_modal.visible = false
	settings_modal.set_anchors_preset(Control.PRESET_CENTER)
	settings_modal.offset_left = -210
	settings_modal.offset_top = -170
	settings_modal.offset_right = 210
	settings_modal.offset_bottom = 170
	settings_modal.add_theme_stylebox_override("panel", _make_stylebox(Color("#111827"), Color("#374151"), 12, 1, 20))
	official_hud_root.add_child(settings_modal)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	settings_modal.add_child(vb)

	var title := Label.new()
	title.text = "Settings (pixeldungeons.xyz)"
	title.add_theme_font_size_override("font_size", 19)
	vb.add_child(title)

	var chk_lights := CheckBox.new()
	chk_lights.text = "Enable Lights (Light2D)"
	chk_lights.button_pressed = _state().lights_enabled
	chk_lights.toggled.connect(func(v: bool):
		_state().lights_enabled = v
		_state().save_state()
	)
	vb.add_child(chk_lights)

	var chk_names := CheckBox.new()
	chk_names.text = "Hide Names above characters"
	chk_names.button_pressed = _state().hide_names
	chk_names.toggled.connect(func(v: bool):
		_state().hide_names = v
		_state().save_state()
	)
	vb.add_child(chk_names)

	var chk_rewards := CheckBox.new()
	chk_rewards.text = "Hide Reward floating numbers"
	chk_rewards.button_pressed = _state().hide_rewards
	chk_rewards.toggled.connect(func(v: bool):
		_state().hide_rewards = v
		_state().save_state()
	)
	vb.add_child(chk_rewards)

	var close_btn := Button.new()
	close_btn.text = "Save Settings"
	close_btn.custom_minimum_size = Vector2(0, 38)
	close_btn.add_theme_stylebox_override("normal", _make_stylebox(Color("#6366f1"), Color("#818cf8"), 8, 1, 8))
	close_btn.pressed.connect(func(): settings_modal.visible = false)
	vb.add_child(close_btn)


func _build_dashboard_overlay() -> void:
	dashboard_overlay = Control.new()
	dashboard_overlay.visible = false
	dashboard_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	official_hud_root.add_child(dashboard_overlay)

	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09, 0.96)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	dashboard_overlay.add_child(bg)

	var main_hbox := HBoxContainer.new()
	main_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_hbox.add_theme_constant_override("separation", 0)
	dashboard_overlay.add_child(main_hbox)

	# SIDEBAR IZQUIERDA (Idéntica a DashboardSidebar en route_8536)
	var sidebar := PanelContainer.new()
	sidebar.custom_minimum_size = Vector2(230, 0)
	sidebar.add_theme_stylebox_override("panel", _make_stylebox(Color("#111827"), Color("#374151"), 0, 1, 16))
	main_hbox.add_child(sidebar)

	var sb_vbox := VBoxContainer.new()
	sb_vbox.add_theme_constant_override("separation", 12)
	sidebar.add_child(sb_vbox)

	# Logo oficial Pixel Dungeons
	var logo_rect := _make_icon_rect("logo", Vector2(190, 56))
	sb_vbox.add_child(logo_rect)

	# Tarjeta de perfil / Wallet / Pickaxes / Skin selector
	var user_card := PanelContainer.new()
	user_card.add_theme_stylebox_override("panel", _make_stylebox(Color("#1f2937"), Color("#4b5563"), 8, 1, 10))
	sb_vbox.add_child(user_card)

	var uc_vbox := VBoxContainer.new()
	uc_vbox.add_theme_constant_override("separation", 6)
	user_card.add_child(uc_vbox)

	var u_row := HBoxContainer.new()
	u_row.add_theme_constant_override("separation", 8)
	uc_vbox.add_child(u_row)
	u_row.add_child(_make_icon_rect("player", Vector2(24, 24)))
	skin_button_label = Label.new()
	skin_button_label.text = str(_state().SKIN_NAMES.get(_state().selected_skin, "Classic Miner"))
	skin_button_label.add_theme_font_size_override("font_size", 14)
	u_row.add_child(skin_button_label)

	var bal_row := HBoxContainer.new()
	bal_row.add_theme_constant_override("separation", 10)
	uc_vbox.add_child(bal_row)

	var px_box := HBoxContainer.new()
	px_box.add_child(_make_icon_rect("pixel", Vector2(18, 16)))
	lbl_sidebar_pixels = Label.new()
	lbl_sidebar_pixels.text = " " + str(_state().wallet_pixels)
	px_box.add_child(lbl_sidebar_pixels)
	bal_row.add_child(px_box)

	var pk_box := HBoxContainer.new()
	pk_box.add_child(_make_icon_rect("pickaxe", Vector2(18, 18)))
	lbl_sidebar_pickaxes = Label.new()
	lbl_sidebar_pickaxes.text = " " + str(_state().pickaxes_balance)
	pk_box.add_child(lbl_sidebar_pickaxes)
	bal_row.add_child(pk_box)

	for nav_item in ["Dungeons (10 Maps)", "Change Character Skin", "Resume Current Run"]:
		var nb := Button.new()
		nb.text = nav_item
		nb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		nb.custom_minimum_size = Vector2(0, 38)
		nb.add_theme_stylebox_override("normal", _make_stylebox(Color("#1f2937"), Color("#374151"), 6, 1, 8))
		if nav_item.begins_with("Change"):
			nb.pressed.connect(func():
				_state().selected_skin = (_state().selected_skin % 13) + 1
				player["skin"] = _state().selected_skin
				skin_button_label.text = str(_state().SKIN_NAMES.get(_state().selected_skin, "Miner"))
				_state().save_state()
			)
		elif nav_item.begins_with("Resume"):
			nb.pressed.connect(func(): dashboard_overlay.visible = false)
		sb_vbox.add_child(nb)

	# CONTENIDO DERECHO: Encabezado "Dungeons - Open daily with fresh rewards" + Grid de los 10 mapas
	var content_margin := MarginContainer.new()
	content_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_margin.add_theme_constant_override("margin_left", 24)
	content_margin.add_theme_constant_override("margin_right", 24)
	content_margin.add_theme_constant_override("margin_top", 18)
	content_margin.add_theme_constant_override("margin_bottom", 18)
	main_hbox.add_child(content_margin)

	var right_vbox := VBoxContainer.new()
	right_vbox.add_theme_constant_override("separation", 12)
	content_margin.add_child(right_vbox)

	var header_row := HBoxContainer.new()
	right_vbox.add_child(header_row)

	var h_titles := VBoxContainer.new()
	h_titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(h_titles)

	var d_title := Label.new()
	d_title.text = "Dungeons"
	d_title.add_theme_font_size_override("font_size", 28)
	d_title.add_theme_color_override("font_color", Color("#87ED00"))
	h_titles.add_child(d_title)

	var d_sub := Label.new()
	d_sub.text = "Mazmorras procedurales · cambian cada vez que cierras una partida · estilos SMALL / MED / BIG"
	d_sub.add_theme_font_size_override("font_size", 15)
	d_sub.add_theme_color_override("font_color", Color("#d1d5db"))
	h_titles.add_child(d_sub)

	var btn_close_dash := Button.new()
	btn_close_dash.text = "✕ Back to Game"
	btn_close_dash.custom_minimum_size = Vector2(140, 38)
	btn_close_dash.add_theme_stylebox_override("normal", _make_stylebox(Color("#374151"), Color("#6b7280"), 8, 1, 8))
	btn_close_dash.pressed.connect(func(): dashboard_overlay.visible = false)
	header_row.add_child(btn_close_dash)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(scroll)

	cards_grid = GridContainer.new()
	cards_grid.columns = 3
	cards_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards_grid.add_theme_constant_override("h_separation", 14)
	cards_grid.add_theme_constant_override("v_separation", 14)
	scroll.add_child(cards_grid)

	_refresh_dashboard_cards()


func _refresh_dashboard_cards() -> void:
	if cards_grid == null:
		return
	for child in cards_grid.get_children():
		child.queue_free()
	var configs: Array = _state().DUNGEON_CONFIGS
	for i in range(configs.size()):
		var cfg: Dictionary = configs[i]
		cards_grid.add_child(_create_dungeon_card(cfg, i))


# Miniatura real del layout procedural pendiente de cada mazmorra
func _make_map_preview_texture(style: String, layout: String, seed_value: int) -> Texture2D:
	var gen: RefCounted = DungeonGenerator.new(style, layout)
	var res: Dictionary = gen.generate(seed_value)
	var w: int = int(res["width"])
	var h: int = int(res["height"])
	var l_ground: PackedInt32Array = res["layer_ground"]
	var l_inter: PackedInt32Array = res["layer_interactive"]
	var l_walls: PackedInt32Array = res["layer_walls"]
	var l_decor: PackedInt32Array = res["layer_decorative"]

	var img: Image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	var floor_col := Color("#3b3242")
	var floor_alt := Color("#463b50")
	var rock_col := Color("#17131f")
	var lava_col := Color("#d2452f")
	var torch_col := Color("#ffb703")
	for y in range(h):
		for x in range(w):
			var i: int = y * w + x
			var col: Color = floor_col if (l_ground[i] % 2 == 0) else floor_alt
			if l_walls[i] > 0:
				col = rock_col
			elif l_inter[i] > 0:
				col = lava_col
			elif l_decor[i] > 0:
				col = torch_col
			img.set_pixel(x, y, col)
	var scale: int = maxi(1, int(240.0 / float(maxi(1, w))))
	img.resize(w * scale, h * scale, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(img)


func _create_dungeon_card(cfg: Dictionary, idx: int) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(270, 240)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _make_stylebox(Color("#111827"), Color("#374151"), 8, 1, 10))

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	card.add_child(vb)

	# Miniatura procedural generada con la semilla que se jugará al entrar
	var style_name: String = str(cfg.get("style", "med"))
	var layout_name: String = str(cfg.get("layout", "chambers"))
	var seed_value: int = _peek_dungeon_seed(idx)
	var prev_rect := TextureRect.new()
	prev_rect.texture = _make_map_preview_texture(style_name, layout_name, seed_value)
	prev_rect.custom_minimum_size = Vector2(250, 92)
	prev_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	prev_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	prev_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	vb.add_child(prev_rect)

	var top_line := HBoxContainer.new()
	vb.add_child(top_line)

	var name_lbl := Label.new()
	name_lbl.text = str(cfg["name"])
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 15)
	name_lbl.add_theme_color_override("font_color", Color.WHITE)
	top_line.add_child(name_lbl)

	var cost_lbl := Label.new()
	var fee: int = int(cfg["entry_fee"])
	cost_lbl.text = "FREE" if fee == 0 else (str(fee) + " $PIXEL")
	cost_lbl.add_theme_font_size_override("font_size", 14)
	cost_lbl.add_theme_color_override("font_color", Color("#87ED00") if fee == 0 else Color("#facc15"))
	top_line.add_child(cost_lbl)

	var tag_row := HBoxContainer.new()
	tag_row.add_theme_constant_override("separation", 6)
	vb.add_child(tag_row)

	var style_col: Color = Color("#69db7c") if style_name == "small" else (Color("#4dabf7") if style_name == "med" else Color("#da77f2"))
	var style_lbl := Label.new()
	style_lbl.text = style_name.to_upper()
	style_lbl.add_theme_font_size_override("font_size", 12)
	style_lbl.add_theme_color_override("font_color", style_col)
	tag_row.add_child(style_lbl)

	var layout_lbl := Label.new()
	layout_lbl.text = "· " + layout_name
	layout_lbl.add_theme_font_size_override("font_size", 12)
	layout_lbl.add_theme_color_override("font_color", Color("#9ca3af"))
	tag_row.add_child(layout_lbl)

	var seed_lbl := Label.new()
	seed_lbl.text = "· seed " + str(seed_value % 100000)
	seed_lbl.add_theme_font_size_override("font_size", 12)
	seed_lbl.add_theme_color_override("font_color", Color("#6b7280"))
	tag_row.add_child(seed_lbl)

	var bounty_row := HBoxContainer.new()
	bounty_row.add_theme_constant_override("separation", 6)
	vb.add_child(bounty_row)

	var b_val := Label.new()
	b_val.text = "%.2f" % float(cfg.get("bounty_pool", 150.0))
	b_val.add_theme_font_size_override("font_size", 22)
	b_val.add_theme_color_override("font_color", Color.WHITE)
	bounty_row.add_child(b_val)
	bounty_row.add_child(_make_icon_rect("pixel", Vector2(22, 20)))

	var b_txt := Label.new()
	b_txt.text = "in the dungeon"
	b_txt.add_theme_font_size_override("font_size", 13)
	b_txt.add_theme_color_override("font_color", Color("#9ca3af"))
	bounty_row.add_child(b_txt)

	var play_btn := Button.new()
	play_btn.text = "Play now (" + str(cfg.get("region_name", "Asia")) + ")"
	play_btn.custom_minimum_size = Vector2(0, 34)
	play_btn.add_theme_stylebox_override("normal", _make_stylebox(Color("#6366f1"), Color("#818cf8"), 6, 1, 6))
	play_btn.add_theme_stylebox_override("hover", _make_stylebox(Color("#4f46e5"), Color("#a5b4fc"), 6, 1, 6))
	play_btn.pressed.connect(func():
		dashboard_overlay.visible = false
		_on_select_dungeon(idx)
	)
	vb.add_child(play_btn)

	return card


func _load_tiled_map_json(map_name: String) -> void:
	var path: String = "res://assets/maps/" + map_name + ".json"
	if not FileAccess.file_exists(path):
		path = "res://assets/maps/the_clock.json"
	if not FileAccess.file_exists(path):
		return

	var raw: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var d: Dictionary = parsed

	grid_w = int(d.get("width", 40))
	grid_h = int(d.get("height", 40))
	map_width = float(grid_w) * WORLD_TILE
	map_height = float(grid_h) * WORLD_TILE

	var min_x_init: int = int(d.get("minXInitialPosition", grid_w / 2 - 2))
	var max_x_init: int = int(d.get("maxXInitialPosition", grid_w / 2 + 2))
	var min_y_init: int = int(d.get("minYInitialPosition", grid_h / 2 - 2))
	var max_y_init: int = int(d.get("maxYInitialPosition", grid_h / 2 + 2))

	collide_gids.clear()
	fire_gids.clear()
	torch_gids.clear()

	if d.has("tilesets") and typeof(d["tilesets"]) == TYPE_ARRAY and d["tilesets"].size() > 0:
		var ts: Dictionary = d["tilesets"][0]
		var firstgid: int = int(ts.get("firstgid", 1))
		for t in ts.get("tiles", []):
			var gid: int = int(t.get("id", 0)) + firstgid
			for prop in t.get("properties", []):
				var pname: String = str(prop.get("name", ""))
				var pval: bool = bool(prop.get("value", false))
				if pname == "ge_collide" and pval:
					collide_gids[gid] = true
				elif pname == "interaction_fire" and pval:
					fire_gids[gid] = true
				elif pname == "torch" and pval:
					torch_gids[gid] = true

	var total_cells: int = grid_w * grid_h
	layer_ground.resize(total_cells)
	layer_interactive.resize(total_cells)
	layer_walls.resize(total_cells)
	layer_decorative.resize(total_cells)
	layer_ground.fill(0)
	layer_interactive.fill(0)
	layer_walls.fill(0)
	layer_decorative.fill(0)

	for l in d.get("layers", []):
		var lname: String = str(l.get("name", ""))
		var ldata: Array = l.get("data", [])
		if ldata.size() != total_cells:
			continue
		if lname == "ground":
			for i in range(total_cells):
				layer_ground[i] = int(ldata[i])
		elif lname == "interactive_objects":
			for i in range(total_cells):
				layer_interactive[i] = int(ldata[i])
		elif lname == "walls":
			for i in range(total_cells):
				layer_walls[i] = int(ldata[i])
		elif lname == "decorative":
			for i in range(total_cells):
				layer_decorative[i] = int(ldata[i])

	walkable_cells.clear()
	spawn_cells.clear()
	torch_positions.clear()
	lava_pools.clear()
	rock_pillars.clear()

	for gy in range(grid_h):
		for gx in range(grid_w):
			var idx: int = gy * grid_w + gx
			var g_gid: int = layer_ground[idx]
			var i_gid: int = layer_interactive[idx]
			var w_gid: int = layer_walls[idx]
			var d_gid: int = layer_decorative[idx]
			var cell_center := Vector2((float(gx) + 0.5) * WORLD_TILE, (float(gy) + 0.5) * WORLD_TILE)

			if torch_gids.has(d_gid):
				torch_positions.append(cell_center)

			if fire_gids.has(i_gid) or fire_gids.has(g_gid):
				lava_pools.append({
					"pos": cell_center,
					"radius": 20.0,
					"cell": Vector2i(gx, gy)
				})
			elif w_gid > 0 or collide_gids.has(g_gid) or collide_gids.has(i_gid):
				if w_gid > 0:
					rock_pillars.append({
						"pos": cell_center,
						"radius": 18.0,
						"cell": Vector2i(gx, gy)
					})
			elif g_gid > 0:
				var cell_v := Vector2i(gx, gy)
				walkable_cells.append(cell_v)
				if gx >= min_x_init and gx <= max_x_init and gy >= min_y_init and gy <= max_y_init:
					spawn_cells.append(cell_v)


func _cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2((float(cell.x) + 0.5) * WORLD_TILE, (float(cell.y) + 0.5) * WORLD_TILE)


func _world_to_cell(pos: Vector2) -> Vector2i:
	return Vector2i(
		clampi(int(pos.x / WORLD_TILE), 0, maxi(0, grid_w - 1)),
		clampi(int(pos.y / WORLD_TILE), 0, maxi(0, grid_h - 1))
	)


func _is_cell_walkable(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.x >= grid_w or cell.y < 0 or cell.y >= grid_h:
		return false
	var idx: int = cell.y * grid_w + cell.x
	if idx < 0 or idx >= layer_ground.size():
		return true
	var g_gid: int = layer_ground[idx]
	var w_gid: int = layer_walls[idx]
	var i_gid: int = layer_interactive[idx]
	if g_gid <= 0 or w_gid > 0:
		return false
	if collide_gids.has(g_gid) or collide_gids.has(i_gid):
		return false
	# Las vetas de mineral son sólidas: hay que caminar alrededor y picarlas
	if ore_cells.has(cell):
		return false
	return true


# ------------------------------------------------------------------ procedural


func _peek_dungeon_seed(dungeon_id: int) -> int:
	if not dungeon_seeds.has(dungeon_id):
		dungeon_seeds[dungeon_id] = randi()
	return int(dungeon_seeds[dungeon_id])


func _roll_next_dungeon_seed(dungeon_id: int) -> void:
	# La siguiente visita a esta mazmorra tendrá otro layout
	dungeon_seeds[dungeon_id] = randi()


func _load_procedural_map(cfg: Dictionary) -> void:
	var style_name: String = str(cfg.get("style", "small"))
	var layout_name: String = str(cfg.get("layout", "chambers"))
	var dungeon_id: int = int(cfg.get("id", 0))
	map_style = style_name
	map_layout = layout_name
	map_seed = _peek_dungeon_seed(dungeon_id)

	var gen: RefCounted = DungeonGenerator.new(style_name, layout_name)
	var res: Dictionary = gen.generate(map_seed)

	grid_w = int(res["width"])
	grid_h = int(res["height"])
	map_width = float(grid_w) * WORLD_TILE
	map_height = float(grid_h) * WORLD_TILE

	layer_ground = res["layer_ground"]
	layer_interactive = res["layer_interactive"]
	layer_walls = res["layer_walls"]
	layer_decorative = res["layer_decorative"]

	walkable_cells.clear()
	spawn_cells.clear()
	torch_positions.clear()
	lava_pools.clear()
	rock_pillars.clear()
	ore_spots.clear()
	ore_cells.clear()

	var walk_list: Array = res["walkable"]
	for c in walk_list:
		walkable_cells.append(c)
	var spot_list: Array = res["ore_spots"]
	for c in spot_list:
		ore_spots.append(c)
	var torch_list: Array = res["torches"]
	for c in torch_list:
		var tp: Vector2i = c
		torch_positions.append(_cell_to_world(tp))
	var fire_list: Array = res["fires"]
	for c in fire_list:
		var fc: Vector2i = c
		var fgid: int = layer_interactive[fc.y * grid_w + fc.x]
		lava_pools.append({
			"pos": _cell_to_world(fc),
			"radius": 18.0 if fgid == 160 else 10.0,
			"cell": fc,
			"gid": fgid
		})

	for y in range(grid_h):
		for x in range(grid_w):
			var w_gid: int = layer_walls[y * grid_w + x]
			if w_gid > 0:
				var rc := Vector2i(x, y)
				rock_pillars.append({
					"pos": _cell_to_world(rc),
					"radius": 20.0,
					"cell": rc
				})

	map_floor_count = walkable_cells.size()
	spawn_hint = res["spawn_cell"]
	spawn_cells.append(spawn_hint)

	# GIDs del tileset oficial que el generador usa (mantiene el renderizado actual)
	collide_gids.clear()
	fire_gids.clear()
	torch_gids.clear()
	for gid in DungeonGenerator.GID_WALL:
		collide_gids[gid] = true
	for gid in DungeonGenerator.GID_LAVA:
		fire_gids[gid] = true
	torch_gids[DungeonGenerator.GID_TORCH] = true

	# El layout recién generado se juega ahora: la próxima entrada será distinta
	_roll_next_dungeon_seed(dungeon_id)
	_build_nav_grid()


# ------------------------------------------------------------------ navegación


func _build_nav_grid() -> void:
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, grid_w, grid_h)
	astar.cell_size = Vector2(WORLD_TILE, WORLD_TILE)
	astar.offset = Vector2(WORLD_TILE * 0.5, WORLD_TILE * 0.5)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	for y in range(grid_h):
		for x in range(grid_w):
			var cell := Vector2i(x, y)
			var solid_cell: bool = (not _is_cell_walkable(cell)) or _is_cell_fire(cell)
			astar.set_point_solid(cell, solid_cell)


func _set_ore_block(cell: Vector2i, blocked: bool) -> void:
	if blocked:
		ore_cells[cell] = true
	else:
		ore_cells.erase(cell)
	if astar != null and cell.x >= 0 and cell.y >= 0 and cell.x < grid_w and cell.y < grid_h:
		var solid_cell: bool = blocked or (not _is_cell_raw_walkable(cell)) or _is_cell_fire(cell)
		astar.set_point_solid(cell, solid_cell)


func _is_cell_raw_walkable(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.x >= grid_w or cell.y < 0 or cell.y >= grid_h:
		return false
	var idx: int = cell.y * grid_w + cell.x
	if idx < 0 or idx >= layer_ground.size():
		return true
	var g_gid: int = layer_ground[idx]
	var w_gid: int = layer_walls[idx]
	var i_gid: int = layer_interactive[idx]
	if g_gid <= 0 or w_gid > 0:
		return false
	if collide_gids.has(g_gid) or collide_gids.has(i_gid):
		return false
	return true


# Celda libre más cercana (para objetivos dentro de roca o sobre una veta)
func _nearest_free_cell(cell: Vector2i, max_radius: int = 7) -> Vector2i:
	if astar == null:
		return cell
	var c: Vector2i = Vector2i(clampi(cell.x, 0, grid_w - 1), clampi(cell.y, 0, grid_h - 1))
	if not astar.is_point_solid(c):
		return c
	for r in range(1, max_radius + 1):
		for oy in range(-r, r + 1):
			for ox in range(-r, r + 1):
				if maxi(absi(ox), absi(oy)) != r:
					continue
				var cand := Vector2i(c.x + ox, c.y + oy)
				if cand.x < 0 or cand.y < 0 or cand.x >= grid_w or cand.y >= grid_h:
					continue
				if not astar.is_point_solid(cand):
					return cand
	return c


# Ruta A* en coordenadas de mundo (sin incluir la celda actual)
func _nav_path(from_world: Vector2, to_world: Vector2) -> Array:
	if astar == null:
		return []
	var from_cell: Vector2i = _nearest_free_cell(_world_to_cell(from_world))
	var to_cell: Vector2i = _nearest_free_cell(_world_to_cell(to_world))
	if from_cell == to_cell:
		return []
	var ids: Array[Vector2i] = astar.get_id_path(from_cell, to_cell)
	var pts: Array = []
	for i in range(1, ids.size()):
		pts.append(_cell_to_world(ids[i]))
	return pts


# Avanza siguiendo una ruta cacheada. Devuelve true si sigue teniendo camino.
func _follow_path(ent: Dictionary, speed: float, delta: float) -> bool:
	var failed: int = int(ent.get("path_fail", 0))
	while true:
		var path: Array = ent.get("path", [])
		var i: int = int(ent.get("path_i", 0))
		if i >= path.size():
			ent["vel"] = Vector2.ZERO
			return false
		var target: Vector2 = path[i]
		var pos: Vector2 = ent["pos"]
		if pos.distance_to(target) <= 14.0:
			ent["path_i"] = i + 1
			continue
		var dir: Vector2 = (target - pos).normalized()
		ent["vel"] = dir * speed
		if abs(dir.x) > 0.05:
			ent["facing_x"] = sign(dir.x)
		ent["pos"] = _move_with_obstacles(pos, dir * speed * delta, true)
		# Si el movimiento se bloquea por completo, no insistir eternamente
		if ent["pos"].distance_to(pos) < speed * delta * 0.25:
			failed += 1
			ent["path_fail"] = failed
			if failed > 6:
				ent["path"] = []
				ent["path_i"] = 0
				ent["path_fail"] = 0
				ent["vel"] = Vector2.ZERO
				return false
		else:
			ent["path_fail"] = 0
		return true
	ent["vel"] = Vector2.ZERO
	return false


# Mueve la entidad hacia un objetivo con repath periódico.
func _entity_goto(ent: Dictionary, goal: Vector2, speed: float, delta: float, repath: float = 0.5) -> bool:
	ent["repath_timer"] = float(ent.get("repath_timer", 0.0)) - delta
	var path: Array = ent.get("path", [])
	if path.is_empty() or float(ent["repath_timer"]) <= 0.0 or not ent.has("goal") or Vector2(ent["goal"]).distance_to(goal) > WORLD_TILE * 0.75:
		ent["repath_timer"] = repath * randf_range(0.85, 1.2)
		ent["goal"] = goal
		ent["path"] = _nav_path(ent["pos"], goal)
		ent["path_i"] = 0
		ent["path_fail"] = 0
	return _follow_path(ent, speed, delta)


# Línea de visión sobre la rejilla (Bresenham). La roca, las vetas y el foso de lava la bloquean.
func _has_line_of_sight(from_world: Vector2, to_world: Vector2) -> bool:
	var c0: Vector2i = _world_to_cell(from_world)
	var c1: Vector2i = _world_to_cell(to_world)
	var dx: int = absi(c1.x - c0.x)
	var dy: int = absi(c1.y - c0.y)
	var sx: int = 1 if c0.x < c1.x else -1
	var sy: int = 1 if c0.y < c1.y else -1
	var err: int = dx - dy
	var cx: int = c0.x
	var cy: int = c0.y
	var guard: int = 0
	while guard < 512:
		guard += 1
		if cx == c1.x and cy == c1.y:
			return true
		if not (cx == c0.x and cy == c0.y):
			var cell := Vector2i(cx, cy)
			if cell.x < 0 or cell.y < 0 or cell.x >= grid_w or cell.y >= grid_h:
				return false
			if not _is_cell_raw_walkable(cell) or _is_cell_fire(cell) or ore_cells.has(cell):
				return false
		var e2: int = 2 * err
		if e2 > -dy:
			err -= dy
			cx += sx
		if e2 < dx:
			err += dx
			cy += sy
	return true




func _is_cell_fire(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.x >= grid_w or cell.y < 0 or cell.y >= grid_h:
		return false
	var idx: int = cell.y * grid_w + cell.x
	if idx < 0 or idx >= layer_interactive.size():
		return false
	return fire_gids.has(layer_interactive[idx]) or fire_gids.has(layer_ground[idx])


func _on_select_dungeon(dungeon_id: int) -> void:
	if not _state().can_enter_dungeon(dungeon_id):
		_push_feed("Not enough $PIXEL in Wallet for this dungeon", "bomb")
		_refresh_lobby_text("NOT ENOUGH $PIXEL FOR ENTRY")
		return
	_state().pay_entry_fee(dungeon_id)
	start_dungeon_run(dungeon_id)


func start_dungeon_run(dungeon_id: int) -> void:
	_state().selected_dungeon = dungeon_id
	var cfg: Dictionary = _state().get_current_config()
	_load_procedural_map(cfg)

	round_active = true
	time_left = float(cfg.get("duration", ROUND_DURATION))
	if overlay_panel != null:
		overlay_panel.visible = false
	if enter_modal != null:
		enter_modal.visible = false

	ores.clear()
	goblins.clear()
	bots.clear()
	loot_bags.clear()
	tnt_list.clear()
	explosions.clear()
	floating_texts.clear()
	feed_entries.clear()

	# Punto de aparición: la cámara despejada que eligió el generador
	var spawn_cell: Vector2i = spawn_hint
	if not _is_cell_raw_walkable(spawn_cell) and walkable_cells.size() > 0:
		spawn_cell = walkable_cells[randi() % walkable_cells.size()]

	var start_pos: Vector2 = _cell_to_world(spawn_cell)
	var init_bombs: int = int(cfg.get("initial_bombs", 3))

	player = {
		"name": "You",
		"pos": start_pos,
		"vel": Vector2.ZERO,
		"pixels": 0,
		"dynamites": init_bombs,
		"alive": true,
		"is_player": true,
		"skin": _state().selected_skin,
		"membership": _state().membership_tier,
		"tint": Color("#ffd43b"),
		"facing_x": 1.0,
		"mining": false,
		"mine_anim_timer": 0.0,
		"invulnerable_timer": 2.0,
		"death_timer": 0.0,
		"death_reason": "",
		"path": [],
		"path_i": 0,
		"repath_timer": 0.0
	}
	if camera != null:
		camera.position = start_pos

	# Asegurar al menos un pozo de lava para tests unitarios si el mapa no tuviera
	if lava_pools.is_empty():
		lava_pools.append({"pos": start_pos + Vector2(300, 300), "radius": 38.0})

	var occupied: Dictionary = {spawn_cell: true}
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		occupied[spawn_cell + d] = true

	var floor_count: int = maxi(40, map_floor_count)
	var reward_mult: float = float(cfg["reward_mult"])
	var epic_chance: float = float(cfg["epic_chance"])

	# --- Vetas de mineral: bloquean el paso, así que sólo se colocan en zonas abiertas ---
	var ore_total: int = clampi(int(round(float(floor_count) * float(cfg.get("ore_density", 0.06)))), 14, 90)
	var candidates: Array[Vector2i] = []
	for c in ore_spots:
		if occupied.has(c):
			continue
		if maxi(absi(c.x - spawn_cell.x), absi(c.y - spawn_cell.y)) < 3:
			continue
		if not _is_open_floor_cell(c):
			continue
		candidates.append(c)
	candidates.shuffle()
	for i in range(ore_total):
		var c: Vector2i
		if candidates.size() > 0:
			c = candidates.pop_back()
		else:
			c = _pick_walkable_cell(spawn_cell, 2, occupied)
			if not _is_cell_raw_walkable(c):
				continue
		occupied[c] = true
		var is_epic: bool = (i == 0) or (randf() < epic_chance)
		var base_val: int = randi_range(28, 45) if is_epic else randi_range(4, 12)
		var final_val: int = int(round(float(base_val) * reward_mult))
		var ore_hp: float = ORE_HP_EPIC if is_epic else ORE_HP_NORMAL * randf_range(0.9, 1.15)
		var ore: Dictionary = {
			"pos": _cell_to_world(c),
			"cell": c,
			"hp": ore_hp,
			"max_hp": ore_hp,
			"value": final_val,
			"is_epic": is_epic,
			"alive": true,
			"shake_ttl": 0.0
		}
		ores.append(ore)
		_set_ore_block(c, true)

	# --- Goblins: patrullan su zona, sólo cazan lo que ven ---
	var gob_total: int = clampi(int(round(float(floor_count) * float(cfg.get("goblin_density", 0.009)))), 3, 18)
	for i in range(gob_total):
		var gc: Vector2i = _pick_walkable_cell(spawn_cell, 6, occupied)
		occupied[gc] = true
		goblins.append({
			"pos": _cell_to_world(gc),
			"home_pos": _cell_to_world(gc),
			"vel": Vector2.ZERO,
			"facing_x": -1.0 if (i % 2 == 0) else 1.0,
			"awake": false,
			"returning": false,
			"alive": true,
			"attack_timer": 0.0,
			"death_timer": 0.0,
			"sight_radius": GOBLIN_SIGHT_RADIUS * randf_range(0.85, 1.1),
			"lose_timer": 0.0,
			"last_seen": Vector2.ZERO,
			"path": [],
			"path_i": 0,
			"path_fail": 0,
			"repath_timer": 0.0,
			"goal": Vector2.ZERO,
			"loot": int(round(randf_range(12.0, 22.0) * reward_mult))
		})

	# --- Bots rivales con personalidad y rutas propias ---
	var bot_total: int = int(cfg.get("bot_count", 6))
	for i in range(bot_total):
		var bc: Vector2i = _pick_walkable_cell(spawn_cell, 3, occupied)
		occupied[bc] = true
		bots.append({
			"name": BOT_NAMES[i % BOT_NAMES.size()],
			"pos": _cell_to_world(bc),
			"vel": Vector2.ZERO,
			"pixels": randi_range(3, 14),
			"dynamites": init_bombs,
			"alive": true,
			"is_player": false,
			"skin": ((i + 1) % 13) + 1,
			"membership": "diamond" if (i % 3 == 0) else ("gold" if (i % 2 == 0) else "none"),
			"tint": BOT_TINTS[(i + 1) % BOT_TINTS.size()],
			"facing_x": 1.0,
			"mining": false,
			"mine_anim_timer": 0.0,
			"invulnerable_timer": 1.5,
			"death_timer": 0.0,
			"death_reason": "",
			"ai_timer": randf_range(0.4, 1.6),
			"target_pos": _cell_to_world(bc),
			"skill": randf_range(0.62, 1.0),
			"greed": randf_range(0.35, 1.0),
			"courage": randf_range(0.3, 1.0),
			"state": "idle",
			"goal": Vector2.ZERO,
			"path": [],
			"path_i": 0,
			"path_fail": 0,
			"repath_timer": randf_range(0.0, 0.45)
		})

	_update_hud()
	if world_canvas != null:
		world_canvas.queue_redraw()


# ¿Celda despejada lo bastante ancha como para bloquearla con una veta?
func _is_open_floor_cell(cell: Vector2i) -> bool:
	if not _is_cell_raw_walkable(cell) or _is_cell_fire(cell):
		return false
	var open: int = 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = cell + d
		if _is_cell_raw_walkable(n) and not _is_cell_fire(n) and not ore_cells.has(n):
			open += 1
	return open >= 3


func _pick_walkable_cell(avoid_cell: Vector2i, min_chebyshev: int, occupied: Dictionary) -> Vector2i:
	if walkable_cells.is_empty():
		return avoid_cell + Vector2i(3, 0)
	for _i in range(160):
		var c: Vector2i = walkable_cells[randi() % walkable_cells.size()]
		var dist: int = maxi(absi(c.x - avoid_cell.x), absi(c.y - avoid_cell.y))
		if dist >= min_chebyshev and not occupied.has(c) and not ore_cells.has(c) and not _is_cell_fire(c):
			return c
	for _j in range(60):
		var c2: Vector2i = walkable_cells[randi() % walkable_cells.size()]
		if not occupied.has(c2) and not ore_cells.has(c2):
			return c2
	return walkable_cells[randi() % walkable_cells.size()]


func _seed_showcase_action() -> void:
	# Coloca acción intensa de Pixel Dungeons justo alrededor del jugador para capturas y demo visual
	var c: Vector2 = player["pos"]
	var ore1_pos: Vector2 = c + Vector2(WORLD_TILE, 0)
	var ore1_cell: Vector2i = _world_to_cell(ore1_pos)
	ores.append({
		"pos": ore1_pos,
		"cell": ore1_cell,
		"hp": 24.0,
		"max_hp": ORE_HP_NORMAL,
		"value": 12,
		"is_epic": false,
		"alive": true,
		"shake_ttl": 0.15
	})
	_set_ore_block(ore1_cell, true)
	var ore2_pos: Vector2 = c + Vector2(-WORLD_TILE * 2.0, -WORLD_TILE)
	var ore2_cell: Vector2i = _world_to_cell(ore2_pos)
	ores.append({
		"pos": ore2_pos,
		"cell": ore2_cell,
		"hp": ORE_HP_EPIC * 0.77,
		"max_hp": ORE_HP_EPIC,
		"value": 45,
		"is_epic": true,
		"alive": true,
		"shake_ttl": 0.0
	})
	_set_ore_block(ore2_cell, true)
	loot_bags.append({
		"pos": c + Vector2(WORLD_TILE * 1.5, WORLD_TILE),
		"amount": 18
	})
	goblins.append({
		"pos": c + Vector2(-WORLD_TILE * 3.0, WORLD_TILE),
		"home_pos": c + Vector2(-WORLD_TILE * 3.0, WORLD_TILE),
		"vel": Vector2(40, 0),
		"facing_x": 1.0,
		"awake": true,
		"alive": true,
		"attack_timer": 0.0,
		"death_timer": 0.0,
		"loot": 20
	})
	tnt_list.append({
		"pos": c + Vector2(-WORLD_TILE * 2.0, WORLD_TILE),
		"timer": 0.85,
		"radius": TNT_BLAST_RADIUS,
		"owner": "You"
	})
	# Añadir una explosión en cruz activa cerca para mostrar el efecto de chispas del tileset
	explosions.append({
		"pos": c + Vector2(WORLD_TILE * 3.0, WORLD_TILE * 2.0),
		"radius": TNT_BLAST_RADIUS,
		"ttl": 0.65,
		"max_ttl": 1.1
	})
	if bots.size() > 0:
		bots[0]["pos"] = c + Vector2(-WORLD_TILE, WORLD_TILE * 2.0)
		bots[0]["pixels"] = 14
		bots[0]["skin"] = 2
	if bots.size() > 1:
		bots[1]["pos"] = c + Vector2(WORLD_TILE * 2.0, -WORLD_TILE * 1.5)
		bots[1]["pixels"] = 28
		bots[1]["skin"] = 7
		bots[1]["mining"] = true
	player["pixels"] = 24
	player["dynamites"] = 2
	player["mining"] = true
	player["mine_anim_timer"] = 0.4
	_spawn_floating_text(c + Vector2(WORLD_TILE, -26), "+ 12", Color.WHITE, 16, true)
	_push_feed("Nelliel found the epic ore", "diamond", true)
	_push_feed("Franvill fell into lava", "lava")
	_push_feed("Breadcrumb2044 killed by a goblin", "goblin")
	_push_feed("TaikoRunner escaped the dungeon", "player")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB or event.keycode == KEY_M:
			if dashboard_overlay != null:
				dashboard_overlay.visible = not dashboard_overlay.visible
				if dashboard_overlay.visible:
					_refresh_dashboard_cards()
			return
		if event.keycode == KEY_COMMA and event.ctrl_pressed:
			if settings_modal != null:
				settings_modal.visible = not settings_modal.visible
			return

		if not round_active:
			if event.keycode >= KEY_1 and event.keycode <= KEY_9:
				_on_select_dungeon(int(event.keycode - KEY_1))
			elif event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
				_on_select_dungeon(_state().selected_dungeon)
			return

		if event.keycode == KEY_E or event.keycode == KEY_Q:
			try_place_tnt(player)
		elif event.keycode == KEY_R:
			start_dungeon_run(_state().selected_dungeon)

	if round_active and event is InputEventMouseButton and event.pressed:
		if dashboard_overlay != null and dashboard_overlay.visible:
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			try_place_tnt(player)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_try_mine_nearby(player, 0.35)


func _process(delta: float) -> void:
	if shot_path != "" and not shot_taken:
		shot_elapsed += delta
		if shot_elapsed >= 0.8:
			shot_taken = true
			_take_screenshot_and_quit()

	ping_timer += delta
	if ping_timer >= 1.5:
		ping_timer = 0.0
		simulated_ping_ms = randi_range(34, 58)

	if round_active:
		_update_round(delta)

	_update_hud()
	if world_canvas != null:
		world_canvas.queue_redraw()


func _take_screenshot_and_quit() -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(shot_path)
	get_tree().quit(0)


func _update_round(delta: float) -> void:
	time_left = maxf(0.0, time_left - delta)
	if time_left <= 0.0 and player["alive"]:
		_handle_player_escape()
		return

	if player["alive"]:
		_update_player(delta)

	_update_bots(delta)
	_update_goblins(delta)
	_update_tnt(delta)
	_update_loot_pickup()
	_update_fx(delta)


func _update_player(delta: float) -> void:
	player["invulnerable_timer"] = maxf(0.0, float(player.get("invulnerable_timer", 0.0)) - delta)
	player["mine_anim_timer"] = maxf(0.0, float(player.get("mine_anim_timer", 0.0)) - delta)

	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0

	if dir.length_squared() > 0.0:
		dir = dir.normalized()
		if abs(dir.x) > 0.05:
			player["facing_x"] = sign(dir.x)
		footstep_timer -= delta
		if footstep_timer <= 0.0:
			footstep_timer = 0.28
			_play_sfx("footsteps", -16.0)

	var speed_mult: float = _state().compute_speed_multiplier(int(player["pixels"]), MAX_BAG_CAPACITY)
	var vel: Vector2 = dir * BASE_PLAYER_SPEED * speed_mult
	player["vel"] = vel
	player["pos"] = _move_with_obstacles(player["pos"], vel * delta)
	if camera != null:
		camera.position = camera.position.lerp(player["pos"], clampf(delta * 8.0, 0.0, 1.0))

	if _is_touching_lava(player["pos"]):
		_kill_miner(player, "fire")
		return

	var wants_mine: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_key_pressed(KEY_SPACE)
	player["mining"] = false
	if wants_mine:
		_try_mine_nearby(player, delta)


func _try_mine_nearby(miner: Dictionary, delta: float) -> void:
	var target_ore: Dictionary = _find_mineable_ore(miner["pos"], MINE_RANGE)
	if target_ore.is_empty():
		return
	miner["mining"] = true
	miner["mine_anim_timer"] = 0.25
	var diff_x: float = target_ore["pos"].x - miner["pos"].x
	if abs(diff_x) > 2.0:
		miner["facing_x"] = sign(diff_x)
	var dps: float = PLAYER_MINE_DPS
	if not bool(miner.get("is_player", false)):
		dps = BOT_MINE_DPS * float(miner.get("skill", 1.0))
	_damage_ore(target_ore, miner, dps * delta)


# ------------------------------------------------------------------ IA de bots


func _update_bots(delta: float) -> void:
	for bot in bots:
		if not bot["alive"]:
			bot["death_timer"] = maxf(0.0, float(bot.get("death_timer", 0.0)) - delta)
			continue

		bot["invulnerable_timer"] = maxf(0.0, float(bot.get("invulnerable_timer", 0.0)) - delta)
		bot["mine_anim_timer"] = maxf(0.0, float(bot.get("mine_anim_timer", 0.0)) - delta)
		bot["ai_timer"] = float(bot["ai_timer"]) - delta
		bot["mining"] = false
		var bpos: Vector2 = bot["pos"]

		var skill: float = float(bot.get("skill", 0.85))
		var speed_mult: float = _state().compute_speed_multiplier(int(bot["pixels"]), MAX_BAG_CAPACITY)
		var move_speed: float = BASE_PLAYER_SPEED * (0.80 + 0.16 * skill) * speed_mult

		# 1. Huir de bombas a punto de estallar (prioridad absoluta)
		var danger_tnt: Dictionary = _find_nearest_tnt(bpos, TNT_BLAST_RADIUS + 55.0)
		if not danger_tnt.is_empty():
			bot["state"] = "flee_bomb"
			_flee_from(bot, danger_tnt["pos"], move_speed * 1.06, delta)
			if _is_touching_lava(bot["pos"]):
				_kill_miner(bot, "fire")
			continue

		# 2. Huir de goblins que le ven (los cobardes no arriesgan)
		var threat: Dictionary = _find_visible_goblin(bpos, 200.0)
		if not threat.is_empty():
			var td: float = bpos.distance_to(threat["pos"])
			var bold: bool = float(bot.get("courage", 0.5)) > 0.85 and td > 130.0
			if not bold:
				bot["state"] = "flee_goblin"
				bot["path"] = []
				_flee_from(bot, threat["pos"], move_speed * 1.1, delta)
				if _is_touching_lava(bot["pos"]):
					_kill_miner(bot, "fire")
				continue

		# 3. Elegir objetivo: mochila caída > veta de mayor valor/cercanía > patrulla
		var bag: Dictionary = _find_nearest_bag(bpos, 300.0)
		var ore_target: Dictionary = _pick_bot_ore_target(bot, 540.0)
		var goal: Vector2 = bot["target_pos"]
		var mining: bool = false

		if not bag.is_empty() and (ore_target.is_empty() or bpos.distance_to(bag["pos"]) < bpos.distance_to(ore_target["pos"]) * 0.85):
			bot["state"] = "loot"
			goal = bag["pos"]
		elif not ore_target.is_empty():
			bot["state"] = "mine"
			goal = ore_target["pos"]
		else:
			bot["state"] = "wander"
			if float(bot["ai_timer"]) <= 0.0 or (bot["path"] as Array).is_empty():
				bot["ai_timer"] = randf_range(1.4, 3.2)
				var wc: Vector2i = _pick_walkable_cell(_world_to_cell(bpos), 2, {})
				bot["target_pos"] = _cell_to_world(wc)
			goal = bot["target_pos"]

		if not ore_target.is_empty() and bpos.distance_to(ore_target["pos"]) <= MINE_RANGE:
			bot["vel"] = Vector2.ZERO
			bot["mining"] = true
			bot["mine_anim_timer"] = 0.25
			bot["path"] = []
			bot["path_i"] = 0
			var dx: float = ore_target["pos"].x - bpos.x
			if abs(dx) > 2.0:
				bot["facing_x"] = sign(dx)
			_damage_ore(ore_target, bot, BOT_MINE_DPS * skill * delta)
			mining = true
		else:
			_entity_goto(bot, goal, move_speed, delta, 0.42)

		# 4. Bombas: sólo contra racimos de vetas, sin rivales de por medio
		if not mining and int(bot["dynamites"]) > 0 and randf() < delta * 0.28:
			var cluster: int = 0
			for o in ores:
				if o["alive"] and bpos.distance_to(o["pos"]) <= TNT_BLAST_RADIUS:
					cluster += 1
			var someone_close: bool = false
			if bool(player.get("alive", false)) and bpos.distance_to(player["pos"]) < TNT_BLAST_RADIUS + 25.0:
				someone_close = true
			for other in bots:
				if other == bot or not other["alive"]:
					continue
				if bpos.distance_to(other["pos"]) < TNT_BLAST_RADIUS + 25.0:
					someone_close = true
					break
			if cluster >= 3 and not someone_close:
				try_place_tnt(bot)

		if _is_touching_lava(bot["pos"]):
			_kill_miner(bot, "fire")


# Huye del peligro eligiendo la celda libre más alejada en un abanico de direcciones
func _flee_from(ent: Dictionary, danger_pos: Vector2, speed: float, delta: float) -> void:
	var away: Vector2 = ent["pos"] - danger_pos
	if away.length_squared() < 0.01:
		away = Vector2.RIGHT
	away = away.normalized()
	var best_goal: Vector2 = ent["pos"] + away * WORLD_TILE * 4.0
	var best_score: float = -1e9
	for ang in [-1.05, -0.6, -0.25, 0.0, 0.25, 0.6, 1.05]:
		var dir: Vector2 = away.rotated(ang)
		var cell: Vector2i = _world_to_cell(ent["pos"] + dir * WORLD_TILE * 5.0)
		if not _is_cell_raw_walkable(cell) or _is_cell_fire(cell) or ore_cells.has(cell):
			continue
		var score: float = _cell_to_world(cell).distance_to(danger_pos) - absf(ang) * 30.0
		if score > best_score:
			best_score = score
			best_goal = _cell_to_world(cell)
	_entity_goto(ent, best_goal, speed, delta, 0.28)


# Veta con mejor relación valor/distancia que ningún otro bot esté picando antes
func _pick_bot_ore_target(bot: Dictionary, max_dist: float) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = -1e9
	var bpos: Vector2 = bot["pos"]
	var greed: float = float(bot.get("greed", 0.6))
	for ore in ores:
		if not ore["alive"]:
			continue
		var d: float = bpos.distance_to(ore["pos"])
		if d > max_dist:
			continue
		var score: float = (float(ore["value"]) + (22.0 if bool(ore["is_epic"]) else 0.0) * greed) / (d + 60.0)
		score *= 0.35 + 0.65 * greed
		# Ceder la veta si otro bot está más cerca de ella
		for other in bots:
			if other == bot or not other["alive"]:
				continue
			if other["pos"].distance_to(ore["pos"]) < d - 40.0:
				score *= 0.3
				break
		if score > best_score:
			best_score = score
			best = ore
	return best


# Veta enfocable: en rango y con visión directa (no se pica a través de la roca)
func _find_mineable_ore(pos: Vector2, max_dist: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = max_dist
	for ore in ores:
		if not ore["alive"]:
			continue
		var d: float = pos.distance_to(ore["pos"])
		if d > best_d:
			continue
		if not _has_line_of_sight(pos, ore["pos"]):
			continue
		best_d = d
		best = ore
	return best


# ------------------------------------------------------------------ IA de goblins


func _update_goblins(delta: float) -> void:
	for gob in goblins:
		if not gob["alive"]:
			gob["death_timer"] = maxf(0.0, float(gob.get("death_timer", 0.0)) - delta)
			continue

		gob["attack_timer"] = maxf(0.0, float(gob.get("attack_timer", 0.0)) - delta)
		var gpos: Vector2 = gob["pos"]
		var home_pos: Vector2 = gob.get("home_pos", gpos)
		var sight: float = float(gob.get("sight_radius", GOBLIN_SIGHT_RADIUS))
		var is_returning: bool = bool(gob.get("returning", false))

		if is_returning:
			gob["awake"] = false
			if gob["pos"].distance_to(home_pos) <= 18.0:
				gob["pos"] = home_pos
				gob["vel"] = Vector2.ZERO
				gob["returning"] = false
				gob["path"] = []
				gob["path_i"] = 0
			else:
				var moved: bool = _entity_goto(gob, home_pos, GOBLIN_SPEED, delta, 0.6)
				if not moved:
					var dir_home: Vector2 = (home_pos - gob["pos"]).normalized()
					gob["vel"] = dir_home * GOBLIN_SPEED
					if abs(dir_home.x) > 0.05:
						gob["facing_x"] = sign(dir_home.x)
					gob["pos"] = _move_with_obstacles(gob["pos"], gob["vel"] * delta, true)
		elif bool(gob["awake"]):
			# Persigue lo que ve; si pierde visual, usa path finding hacia el último punto conocido
			var prey: Dictionary = _find_visible_prey(gob, sight)
			if not prey.is_empty():
				gob["lose_timer"] = GOBLIN_LOSE_SIGHT_TIME
				gob["last_seen"] = prey["pos"]
				_entity_goto(gob, prey["pos"], GOBLIN_CHASE_SPEED, delta, 0.32)
				if gob["pos"].distance_to(prey["pos"]) < GOBLIN_ATTACK_RANGE:
					gob["attack_timer"] = 0.45
					_play_sfx("goblin-attack", -5.0)
					_kill_miner(prey, "goblin")
				if gob["pos"].distance_to(home_pos) > GOBLIN_LEASH_RADIUS:
					gob["awake"] = false
					gob["returning"] = true
					gob["lose_timer"] = 0.0
					gob["path"] = []
					gob["path_i"] = 0
			elif float(gob.get("lose_timer", 0.0)) > 0.0:
				gob["lose_timer"] = maxf(0.0, float(gob["lose_timer"]) - delta)
				_entity_goto(gob, gob["last_seen"], GOBLIN_CHASE_SPEED * 0.92, delta, 0.5)
				if gob["pos"].distance_to(gob["last_seen"]) < 44.0:
					gob["lose_timer"] = 0.0
			else:
				# Ya no hay rastro: volver al punto de descanso original
				gob["awake"] = false
				gob["returning"] = true
				gob["path"] = []
				gob["path_i"] = 0
		else:
			# Sólo persigue lo que VE: radio de visión + línea de visión sobre la rejilla
			var prey2: Dictionary = _find_visible_prey(gob, sight)
			if not prey2.is_empty():
				if not bool(gob["awake"]):
					gob["awake"] = true
					_play_sfx("goblin-rage", -10.0)
					var dist_wake: float = gpos.distance_to(prey2["pos"])
					if dist_wake <= GOBLIN_WAKE_RADIUS:
						gob["attack_timer"] = 0.3
				gob["lose_timer"] = GOBLIN_LOSE_SIGHT_TIME
				gob["last_seen"] = prey2["pos"]
				_entity_goto(gob, prey2["pos"], GOBLIN_CHASE_SPEED, delta, 0.32)
				if gob["pos"].distance_to(prey2["pos"]) < GOBLIN_ATTACK_RANGE:
					gob["attack_timer"] = 0.45
					_play_sfx("goblin-attack", -5.0)
					_kill_miner(prey2, "goblin")
				if gob["pos"].distance_to(home_pos) > GOBLIN_LEASH_RADIUS:
					gob["awake"] = false
					gob["returning"] = true
					gob["lose_timer"] = 0.0
					gob["path"] = []
					gob["path_i"] = 0
			elif gob["pos"].distance_to(home_pos) > 18.0:
				gob["returning"] = true
				_entity_goto(gob, home_pos, GOBLIN_SPEED, delta, 0.6)
			else:
				gob["vel"] = Vector2.ZERO
				gob["path"] = []
				gob["path_i"] = 0

		# En cualquier estado (persiguiendo, volviendo o en su puesto), si toca a alguien lo mata
		var touched_miner: Dictionary = _find_touching_miner(gob["pos"], GOBLIN_ATTACK_RANGE)
		if not touched_miner.is_empty():
			gob["attack_timer"] = 0.45
			_play_sfx("goblin-attack", -5.0)
			_kill_miner(touched_miner, "goblin")

		if _is_touching_lava(gob["pos"]):
			gob["alive"] = false
			gob["death_timer"] = 1.2
			_spawn_loot_bag(gob["pos"], int(gob["loot"]))


# Comprueba contacto físico directo entre un monstruo y cualquier minero vivo
func _find_touching_miner(pos: Vector2, hit_radius: float) -> Dictionary:
	if bool(player.get("alive", false)) and float(player.get("invulnerable_timer", 0.0)) <= 0.0:
		if pos.distance_to(player["pos"]) <= hit_radius:
			return player
	for bot in bots:
		if not bot["alive"] or float(bot.get("invulnerable_timer", 0.0)) > 0.0:
			continue
		if pos.distance_to(bot["pos"]) <= hit_radius:
			return bot
	return {}


# Presa más cercana que el goblin pueda ver de verdad
func _find_visible_prey(gob: Dictionary, max_dist: float) -> Dictionary:
	var gpos: Vector2 = gob["pos"]
	var best: Dictionary = {}
	var best_d: float = max_dist
	if bool(player.get("alive", false)):
		var dp: float = gpos.distance_to(player["pos"])
		if dp <= best_d and _has_line_of_sight(gpos, player["pos"]):
			best_d = dp
			best = player
	for bot in bots:
		if not bot["alive"]:
			continue
		var db: float = gpos.distance_to(bot["pos"])
		if db <= best_d and _has_line_of_sight(gpos, bot["pos"]):
			best_d = db
			best = bot
	return best


# Goblin despierto y visible desde una posición (para que los bots huyan)
func _find_visible_goblin(pos: Vector2, max_dist: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = max_dist
	for gob in goblins:
		if not gob["alive"] or not bool(gob["awake"]):
			continue
		var d: float = pos.distance_to(gob["pos"])
		if d <= best_d and _has_line_of_sight(pos, gob["pos"]):
			best_d = d
			best = gob
	return best


func try_place_tnt(miner: Dictionary) -> bool:
	if not bool(miner.get("alive", false)):
		return false
	var count: int = int(miner.get("dynamites", 0))
	if count <= 0:
		return false

	miner["dynamites"] = count - 1
	tnt_list.append({
		"pos": miner["pos"],
		"timer": TNT_FUSE_TIME,
		"radius": TNT_BLAST_RADIUS,
		"owner": str(miner["name"])
	})
	return true


func _update_tnt(delta: float) -> void:
	var remaining: Array[Dictionary] = []
	for tnt in tnt_list:
		tnt["timer"] = float(tnt["timer"]) - delta
		if float(tnt["timer"]) <= 0.0:
			_detonate_tnt(tnt)
		else:
			remaining.append(tnt)
	tnt_list = remaining


func _detonate_tnt(tnt: Dictionary) -> void:
	var pos: Vector2 = tnt["pos"]
	var rad: float = float(tnt["radius"])
	_play_sfx("bomb-explosion", -4.0)

	# Patrón oficial de 13 celdas de explosión en la capa fx (3x3 + 4 puntas a distancia 2)
	var center_cell: Vector2i = _world_to_cell(pos)
	var blast_offsets: Array[Vector2i] = [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
		Vector2i(-1, 0),  Vector2i(0, 0),  Vector2i(1, 0),
		Vector2i(-1, 1),  Vector2i(0, 1),  Vector2i(1, 1),
		Vector2i(-2, 0),  Vector2i(2, 0),  Vector2i(0, -2), Vector2i(0, 2)
	]
	var world_cells: Array[Vector2] = []
	for bo in blast_offsets:
		world_cells.append(_cell_to_world(center_cell + bo))

	explosions.append({
		"pos": pos,
		"radius": rad,
		"cells": world_cells,
		"ttl": 1.1,
		"max_ttl": 1.1
	})

	for ore in ores:
		if ore["alive"] and pos.distance_to(ore["pos"]) <= rad:
			ore["hp"] = 0.0
			ore["alive"] = false
			if ore.has("cell"):
				_set_ore_block(ore["cell"], false)
			_spawn_loot_bag(ore["pos"], int(ore["value"]))

	for gob in goblins:
		if gob["alive"] and pos.distance_to(gob["pos"]) <= rad:
			gob["alive"] = false
			gob["death_timer"] = 1.2
			_spawn_loot_bag(gob["pos"], int(gob["loot"]))

	for bot in bots:
		if bot["alive"] and pos.distance_to(bot["pos"]) <= rad:
			_kill_miner(bot, "bomb")

	if player["alive"] and pos.distance_to(player["pos"]) <= rad:
		_kill_miner(player, "bomb")


func _damage_ore(ore: Dictionary, miner: Dictionary, amount: float) -> void:
	if not ore["alive"]:
		return
	var prev_hp: float = float(ore["hp"])
	ore["hp"] = prev_hp - amount
	ore["shake_ttl"] = 0.15

	if int(prev_hp / 12.0) != int(float(ore["hp"]) / 12.0) and bool(miner.get("is_player", false)):
		_play_sfx("mine-epic" if bool(ore["is_epic"]) else "mining", -8.0)

	if float(ore["hp"]) <= 0.0:
		ore["alive"] = false
		# La veta deja de bloquear el paso en cuanto se rompe
		if ore.has("cell"):
			_set_ore_block(ore["cell"], false)
		var val: int = int(ore["value"])
		miner["pixels"] = int(miner["pixels"]) + val
		if bool(miner.get("is_player", false)):
			_play_sfx("collect", -5.0)
		if bool(ore["is_epic"]):
			_play_sfx("epic-ore-found", -3.0)
			_spawn_floating_text(ore["pos"] + Vector2(-100, -24), "+ " + str(val), Color("#87ED00"), 20, true)
			_push_feed(str(miner["name"]) + " found the epic ore", "diamond", true)
		else:
			_spawn_floating_text(ore["pos"] + Vector2(-100, -20), "+ " + str(val), Color.WHITE, 16, true)


func _kill_miner(miner: Dictionary, reason: String) -> void:
	if not bool(miner["alive"]):
		return
	miner["alive"] = false
	miner["death_reason"] = reason
	miner["death_timer"] = 1.2

	var drop_amount: int = max(5, int(miner["pixels"]))
	miner["pixels"] = 0
	_spawn_loot_bag(miner["pos"], drop_amount)

	# Mensajes de feed idénticos al componente F() de playchunk2_8780
	var uname: String = str(miner["name"])
	if reason == "fire" or reason.find("lava") != -1:
		_play_sfx("lava-death", -5.0)
		_push_feed(uname + " fell into lava", "lava")
	elif reason == "bomb" or reason.find("TNT") != -1:
		_push_feed(uname + " killed by a bomb", "bomb")
	elif reason == "goblin" or reason.find("Goblin") != -1:
		_push_feed(uname + " killed by a goblin", "goblin")
	else:
		_push_feed(uname + " died (" + reason + ")", "player")

	if bool(miner.get("is_player", false)):
		round_active = false
		_state().record_death()
		var modal_title: String = "You lost the game"
		if reason == "bomb" or reason.find("TNT") != -1:
			modal_title = "You were blown up by a bomb"
		elif reason == "fire" or reason.find("lava") != -1:
			modal_title = "You fell into the lava"
		elif reason == "goblin" or reason.find("Goblin") != -1:
			modal_title = "A goblin killed you"
		_show_end_overlay(modal_title, "Lost " + str(drop_amount) + " $PIXEL in the dungeon.")


func _handle_player_escape() -> void:
	round_active = false
	player["escaping"] = true
	var haul: int = int(player["pixels"])
	_state().record_escape(haul)
	_push_feed(str(player["name"]) + " escaped the dungeon", "player")
	_show_end_overlay("You escaped the dungeon!", "Your reward of +" + str(haul) + " $PIXEL was sent to your wallet.")


func _show_end_overlay(title: String, subtitle: String) -> void:
	if overlay_panel != null:
		overlay_panel.visible = false
	if lbl_overlay_title != null:
		lbl_overlay_title.text = title
	_refresh_lobby_text(subtitle)

	if enter_modal != null:
		enter_modal.visible = true
		lbl_enter_title.text = title
		lbl_enter_bounty.text = subtitle + "  |  Wallet: " + str(_state().wallet_pixels) + " $PIXEL"
		btn_enter_start.text = "Play Again"


func _refresh_lobby_text(subtitle: String) -> void:
	if lbl_overlay_stats != null:
		lbl_overlay_stats.text = (
			subtitle + "\n\n" +
			"WALLET TOTAL: " + str(_state().wallet_pixels) + " $PIXEL\n" +
			"Escapes: " + str(_state().total_escaped_runs) +
			"  |  Deaths: " + str(_state().total_deaths) +
			"  |  Best Haul: " + str(_state().best_run_haul) + " $PIXEL"
		)


func _spawn_loot_bag(pos: Vector2, amount: int) -> void:
	if amount <= 0:
		return
	loot_bags.append({
		"pos": pos,
		"amount": amount
	})


func _update_loot_pickup() -> void:
	var remaining_bags: Array[Dictionary] = []
	for bag in loot_bags:
		var picked: bool = false
		# Radio de recogida aumentado: 40.0 para jugador, 36.0 para bots
		if player["alive"] and player["pos"].distance_to(bag["pos"]) < 40.0:
			var amt: int = int(bag["amount"])
			player["pixels"] = int(player["pixels"]) + amt
			_play_sfx("backpack-pickup", -5.0)
			_spawn_floating_text(bag["pos"] + Vector2(-100, -20), "+ " + str(amt), Color("#87ED00"), 17, true)
			picked = true
		else:
			for bot in bots:
				if bot["alive"] and bot["pos"].distance_to(bag["pos"]) < 36.0:
					bot["pixels"] = int(bot["pixels"]) + int(bag["amount"])
					picked = true
					break
		if not picked:
			remaining_bags.append(bag)
	loot_bags = remaining_bags


func _move_with_obstacles(pos: Vector2, delta_vec: Vector2, avoid_fire: bool = false) -> Vector2:
	# Sub-stepping para evitar atravesar rocas/minerales con pasos largos o caídas de FPS
	var total_len: float = delta_vec.length()
	if total_len <= 0.0001:
		return _resolve_solid_penetration(pos, avoid_fire)
	var steps: int = maxi(1, int(ceil(total_len / 6.0)))
	var step_vec: Vector2 = delta_vec / float(steps)
	var cur: Vector2 = pos
	for _s in range(steps):
		cur = _move_single_step(cur, step_vec, avoid_fire)
	return cur


func _move_single_step(pos: Vector2, step_vec: Vector2, avoid_fire: bool) -> Vector2:
	var next_pos: Vector2 = pos + step_vec
	next_pos.x = clampf(next_pos.x, 26.0, map_width - 26.0)
	next_pos.y = clampf(next_pos.y, 26.0, map_height - 26.0)

	if layer_ground.size() == grid_w * grid_h and grid_w > 0:
		# Si intenta caminar hacia fuego con avoid_fire activo (IA de bots y goblins), frenar o deslizar
		if avoid_fire and _is_touching_lava(next_pos):
			var slide_x := Vector2(next_pos.x, pos.y)
			if not _is_touching_lava(slide_x) and not _overlaps_any_solid_cell(slide_x, ENTITY_COLLIDER_RADIUS):
				return slide_x
			var slide_y := Vector2(pos.x, next_pos.y)
			if not _is_touching_lava(slide_y) and not _overlaps_any_solid_cell(slide_y, ENTITY_COLLIDER_RADIUS):
				return slide_y
			return pos

		return _resolve_solid_penetration(next_pos, avoid_fire)

	for rock in rock_pillars:
		var rpos: Vector2 = rock["pos"]
		var min_d: float = float(rock["radius"]) + ENTITY_COLLIDER_RADIUS
		var d: float = next_pos.distance_to(rpos)
		if d < min_d and d > 0.001:
			next_pos = rpos + (next_pos - rpos).normalized() * min_d
	return next_pos


func _is_cell_solid_obstacle(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.x >= grid_w or cell.y < 0 or cell.y >= grid_h:
		return true
	if ore_cells.has(cell):
		return true
	if not _is_cell_raw_walkable(cell) and not _is_cell_fire(cell):
		return true
	return false


func _overlaps_any_solid_cell(pos: Vector2, radius: float) -> bool:
	var c: Vector2i = _world_to_cell(pos)
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var nb := Vector2i(c.x + ox, c.y + oy)
			if not _is_cell_solid_obstacle(nb):
				continue
			var rect := Rect2(float(nb.x) * WORLD_TILE, float(nb.y) * WORLD_TILE, WORLD_TILE, WORLD_TILE)
			var closest := Vector2(
				clampf(pos.x, rect.position.x, rect.position.x + rect.size.x),
				clampf(pos.y, rect.position.y, rect.position.y + rect.size.y)
			)
			if pos.distance_to(closest) < radius:
				return true
	return false


# Empuja suavemente el círculo de colisión (radio ENTITY_COLLIDER_RADIUS) fuera de cualquier
# bloque de piedra, pilar o veta de mineral en el vecindario 3x3: imposible atravesar rocas.
func _resolve_solid_penetration(pos: Vector2, avoid_fire: bool = false) -> Vector2:
	var resolved: Vector2 = pos
	for _iter in range(3):
		var c: Vector2i = _world_to_cell(resolved)
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				var nb := Vector2i(c.x + ox, c.y + oy)
				var is_solid: bool = _is_cell_solid_obstacle(nb)
				if not is_solid and avoid_fire and _is_cell_fire(nb):
					# Para IA con avoid_fire, empujar también fuera de la zona ardiente real
					var lrect: Rect2 = _get_cell_lava_world_rect(nb)
					if lrect.size.x > 0.0:
						resolved = _push_circle_out_of_rect(resolved, ENTITY_COLLIDER_RADIUS, lrect)
					continue
				if not is_solid:
					continue
				var rect := Rect2(float(nb.x) * WORLD_TILE, float(nb.y) * WORLD_TILE, WORLD_TILE, WORLD_TILE)
				resolved = _push_circle_out_of_rect(resolved, ENTITY_COLLIDER_RADIUS, rect)
	return resolved


func _push_circle_out_of_rect(pos: Vector2, radius: float, rect: Rect2) -> Vector2:
	var cx: float = clampf(pos.x, rect.position.x, rect.position.x + rect.size.x)
	var cy: float = clampf(pos.y, rect.position.y, rect.position.y + rect.size.y)
	var diff: Vector2 = pos - Vector2(cx, cy)
	var dist_sq: float = diff.length_squared()
	if dist_sq >= radius * radius:
		return pos
	if dist_sq > 0.0001:
		var dist: float = sqrt(dist_sq)
		return pos + (diff / dist) * (radius - dist)
	# El centro cayó dentro del rectángulo: expulsar por el borde más cercano
	var dl: float = absf(pos.x - rect.position.x)
	var dr: float = absf((rect.position.x + rect.size.x) - pos.x)
	var dt: float = absf(pos.y - rect.position.y)
	var db: float = absf((rect.position.y + rect.size.y) - pos.y)
	var m: float = minf(minf(dl, dr), minf(dt, db))
	if m == dl:
		return Vector2(rect.position.x - radius, pos.y)
	elif m == dr:
		return Vector2(rect.position.x + rect.size.x + radius, pos.y)
	elif m == dt:
		return Vector2(pos.x, rect.position.y - radius)
	return Vector2(pos.x, rect.position.y + rect.size.y + radius)


# Devuelve el rectángulo en coordenadas de mundo donde realmente hay magma naranja dentro de la celda.
func _get_cell_lava_world_rect(cell: Vector2i) -> Rect2:
	if cell.x < 0 or cell.x >= grid_w or cell.y < 0 or cell.y >= grid_h:
		return Rect2()
	var idx: int = cell.y * grid_w + cell.x
	if idx < 0 or idx >= layer_interactive.size():
		return Rect2()
	var gid: int = layer_interactive[idx]
	if not fire_gids.has(gid):
		gid = layer_ground[idx]
		if not fire_gids.has(gid):
			return Rect2()
	var uv: Rect2 = DungeonGenerator.LAVA_HITBOX_UV.get(gid, Rect2(0.15, 0.15, 0.70, 0.70))
	return Rect2(
		(float(cell.x) + uv.position.x) * WORLD_TILE,
		(float(cell.y) + uv.position.y) * WORLD_TILE,
		uv.size.x * WORLD_TILE,
		uv.size.y * WORLD_TILE
	)


func _is_touching_lava(pos: Vector2) -> bool:
	if layer_interactive.size() == grid_w * grid_h and grid_w > 0:
		var c: Vector2i = _world_to_cell(pos)
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				var nb := Vector2i(c.x + ox, c.y + oy)
				var lrect: Rect2 = _get_cell_lava_world_rect(nb)
				if lrect.size.x <= 0.0:
					continue
				var closest := Vector2(
					clampf(pos.x, lrect.position.x, lrect.position.x + lrect.size.x),
					clampf(pos.y, lrect.position.y, lrect.position.y + lrect.size.y)
				)
				if pos.distance_to(closest) <= LAVA_PROBE_RADIUS:
					return true
		return false
	for lava in lava_pools:
		if pos.distance_to(lava["pos"]) < float(lava.get("radius", 18.0)):
			return true
	return false


func _find_nearest_ore(pos: Vector2, max_dist: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = max_dist
	for ore in ores:
		if not ore["alive"]:
			continue
		var d: float = pos.distance_to(ore["pos"])
		if d <= best_d:
			best_d = d
			best = ore
	return best


func _find_nearest_bag(pos: Vector2, max_dist: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = max_dist
	for bag in loot_bags:
		var d: float = pos.distance_to(bag["pos"])
		if d <= best_d:
			best_d = d
			best = bag
	return best


func _find_nearest_tnt(pos: Vector2, max_dist: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = max_dist
	for tnt in tnt_list:
		var d: float = pos.distance_to(tnt["pos"])
		if d <= best_d:
			best_d = d
			best = tnt
	return best


func _find_nearest_miner(pos: Vector2, max_dist: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = max_dist
	if player.get("alive", false):
		var dp: float = pos.distance_to(player["pos"])
		if dp <= best_d:
			best_d = dp
			best = player
	for bot in bots:
		if not bot["alive"]:
			continue
		var db: float = pos.distance_to(bot["pos"])
		if db <= best_d:
			best_d = db
			best = bot
	return best


func _spawn_floating_text(pos: Vector2, text: String, col: Color, size: int = 14, show_pixel_icon: bool = false) -> void:
	floating_texts.append({
		"pos": pos,
		"text": text,
		"color": col,
		"size": size,
		"show_pixel_icon": show_pixel_icon,
		"ttl": 0.95,
		"max_ttl": 0.95
	})


func _push_feed(msg: String, icon_key: String = "player", is_epic: bool = false) -> void:
	feed_entries.push_front({
		"text": msg,
		"icon": icon_key,
		"is_epic": is_epic,
		"ttl": 6.0
	})
	if feed_entries.size() > 5:
		feed_entries.resize(5)
	_rebuild_toast_notifications()


func _rebuild_toast_notifications() -> void:
	if toast_vbox == null:
		return
	for child in toast_vbox.get_children():
		child.queue_free()

	for fe in feed_entries:
		var toast_panel := PanelContainer.new()
		var is_ep: bool = bool(fe.get("is_epic", false))
		var bg_col: Color = Color("#4c1d95") if is_ep else Color(0.067, 0.094, 0.153, 0.94)
		var bd_col: Color = Color("#a855f7") if is_ep else Color(1, 1, 1, 0.14)
		toast_panel.add_theme_stylebox_override("panel", _make_stylebox(bg_col, bd_col, 6, 1, 8))
		toast_panel.size_flags_horizontal = Control.SIZE_SHRINK_END

		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		toast_panel.add_child(hb)

		var ikey: String = str(fe.get("icon", "player"))
		hb.add_child(_make_icon_rect(ikey, Vector2(20, 20)))

		var lbl := Label.new()
		lbl.text = str(fe["text"])
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", Color.WHITE)
		hb.add_child(lbl)

		toast_vbox.add_child(toast_panel)


func _update_fx(delta: float) -> void:
	for ore in ores:
		if float(ore.get("shake_ttl", 0.0)) > 0.0:
			ore["shake_ttl"] = maxf(0.0, float(ore["shake_ttl"]) - delta)

	var next_ft: Array[Dictionary] = []
	for ft in floating_texts:
		ft["ttl"] = float(ft["ttl"]) - delta
		ft["pos"] = ft["pos"] + Vector2(0, -36.0 * delta)
		if float(ft["ttl"]) > 0.0:
			next_ft.append(ft)
	floating_texts = next_ft

	var next_exp: Array[Dictionary] = []
	for ex in explosions:
		ex["ttl"] = float(ex["ttl"]) - delta
		if float(ex["ttl"]) > 0.0:
			next_exp.append(ex)
	explosions = next_exp

	var next_feed: Array[Dictionary] = []
	var changed_feed: bool = false
	for fe in feed_entries:
		fe["ttl"] = float(fe["ttl"]) - delta
		if float(fe["ttl"]) > 0.0:
			next_feed.append(fe)
		else:
			changed_feed = true
	feed_entries = next_feed
	if changed_feed:
		_rebuild_toast_notifications()


func _update_hud() -> void:
	var mins: int = int(time_left) / 60
	var secs: int = int(time_left) % 60
	var time_str: String = "%02d:%02d" % [mins, secs]

	var px_count: int = int(player.get("pixels", 0))
	var dyn_count: int = int(player.get("dynamites", 3))
	var weight_pct: int = _state().compute_bag_weight_percent(px_count, MAX_BAG_CAPACITY)

	var fps: int = Engine.get_frames_per_second()
	if fps <= 0:
		fps = 60

	# Actualizar etiquetas del HUD oficial (q() de pixeldungeons.xyz)
	if lbl_hud_time != null:
		lbl_hud_time.text = time_str
		if time_left < 10.0:
			lbl_hud_time.add_theme_color_override("font_color", Color("#f87171"))
		elif time_left < 20.0:
			lbl_hud_time.add_theme_color_override("font_color", Color("#facc15"))
		else:
			lbl_hud_time.add_theme_color_override("font_color", Color.WHITE)

	if lbl_hud_pixels != null:
		lbl_hud_pixels.text = str(px_count)
	if lbl_hud_bombs != null:
		lbl_hud_bombs.text = str(dyn_count)
	if lbl_hud_weight != null:
		lbl_hud_weight.text = str(weight_pct) + "%"
		if weight_pct >= 100:
			lbl_hud_weight.add_theme_color_override("font_color", Color("#f87171"))
		elif weight_pct >= 50:
			lbl_hud_weight.add_theme_color_override("font_color", Color("#facc15"))
		else:
			lbl_hud_weight.add_theme_color_override("font_color", Color.WHITE)

	if lbl_hud_ping != null:
		lbl_hud_ping.text = str(simulated_ping_ms) + " ms"
	if lbl_hud_fps != null:
		lbl_hud_fps.text = str(fps) + " fps"
	if lbl_sidebar_pixels != null:
		lbl_sidebar_pixels.text = " " + str(_state().wallet_pixels)
	if lbl_sidebar_pickaxes != null:
		lbl_sidebar_pickaxes.text = " " + str(_state().pickaxes_balance)

	# Mantener actualizados también los nodos clásicos por compatibilidad
	if lbl_timer != null:
		lbl_timer.text = time_str
	if lbl_pixels != null:
		lbl_pixels.text = "$PIXEL: " + str(px_count) + "  (Wallet: " + str(_state().wallet_pixels) + ")"
	if lbl_dynamite != null:
		lbl_dynamite.text = "TNT Dynamites: " + str(dyn_count)
	if lbl_weight != null:
		lbl_weight.text = "Bag Weight: " + str(weight_pct) + "%  (Speed x" + ("%.2f" % _state().compute_speed_multiplier(px_count, MAX_BAG_CAPACITY)) + ")"
	if lbl_ping_fps != null:
		lbl_ping_fps.text = str(simulated_ping_ms) + "ms  " + str(fps) + " FPS"
	if lbl_feed != null:
		var lines: PackedStringArray = []
		for fe in feed_entries:
			lines.append("• " + str(fe["text"]))
		lbl_feed.text = "\n".join(lines) if lines.size() > 0 else "• Dungeon open"
