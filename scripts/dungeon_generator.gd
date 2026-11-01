extends RefCounted

# Generador de mazmorras procedurales de Pixel Dungeons.
#
# Produce mapas de 3 tamaños (small / med / big) con 5 familias de layout
# (chambers, corridors, caverns, labyrinth, rings) usando EXACTAMENTE el mismo
# autotile de 9 piezas y las mismas decoraciones de los 10 mapas Tiled oficiales:
#
#   - Suelo de piedra: ajedrez 2x2 (fila par 130/131, fila impar 153/154).
#   - Foso exterior e islas interiores de lava: 9-slice en interactive_objects
#     (esquinas 136/138/182/184, bordes 137/183/159/161, centro 160) más
#     burbujas animadas en decorative (242/243/244/265/266/267).
#   - Macizos de roca (203..207 / 226..230 / 249..253) con antorchas (273) en la
#     cara sur y pilares sueltos (176/177/199) como coberturas tácticas.

const GID_GROUND_EVEN: Array[int] = [130, 131]
const GID_GROUND_ODD: Array[int] = [153, 154]

# Rocas / muros con ge_collide = true en el tileset oficial
const GID_WALL_TOP_L: int = 203
const GID_WALL_TOP_M: Array[int] = [204, 205, 206]
const GID_WALL_TOP_R: int = 207
const GID_WALL_MID_L: int = 226
const GID_WALL_MID_M: Array[int] = [227, 228, 229]
const GID_WALL_MID_R: int = 230
const GID_WALL_BOT_L: int = 249
const GID_WALL_BOT_M: Array[int] = [250, 251, 252]
const GID_WALL_BOT_R: int = 253
const GID_PILLARS: Array[int] = [176, 177, 199]

const GID_WALL: Array[int] = [
	176, 177, 199,
	203, 204, 205, 206, 207,
	226, 227, 228, 229, 230,
	249, 250, 251, 252, 253
]

# Lava con autotile 9-slice (bordes de piedra sobre el magma + centro 160)
const GID_LAVA_TL: int = 136
const GID_LAVA_TM: int = 137
const GID_LAVA_TR: int = 138
const GID_LAVA_ML: int = 159
const GID_LAVA_MM: int = 160
const GID_LAVA_MR: int = 161
const GID_LAVA_BL: int = 182
const GID_LAVA_BM: int = 183
const GID_LAVA_BR: int = 184

const GID_LAVA: Array[int] = [
	133, 134, 135, 136, 137, 138,
	156, 158, 159, 160, 161,
	179, 180, 181, 182, 183, 184
]

# Rectángulo exacto de magma ardiente (en coordenadas normalizadas 0..1 dentro de la celda 16x16)
# Los bordes de piedra morada (como la mitad inferior de 182/183/184 o la superior de 136/137/138)
# NO son lava real: así el jugador sólo muere cuando pisa físicamente el magma naranja.
const LAVA_HITBOX_UV: Dictionary = {
	160: Rect2(0.00, 0.00, 1.00, 1.00),
	133: Rect2(0.00, 0.00, 0.88, 0.88),
	135: Rect2(0.12, 0.00, 0.88, 0.88),
	179: Rect2(0.00, 0.12, 0.88, 0.88),
	181: Rect2(0.12, 0.12, 0.88, 0.88),
	136: Rect2(0.32, 0.56, 0.68, 0.44),
	137: Rect2(0.00, 0.56, 1.00, 0.44),
	180: Rect2(0.00, 0.56, 1.00, 0.44),
	138: Rect2(0.00, 0.56, 0.68, 0.44),
	158: Rect2(0.34, 0.00, 0.66, 1.00),
	159: Rect2(0.34, 0.00, 0.66, 1.00),
	156: Rect2(0.00, 0.00, 0.66, 1.00),
	161: Rect2(0.00, 0.00, 0.66, 1.00),
	182: Rect2(0.34, 0.00, 0.66, 0.25),
	134: Rect2(0.00, 0.00, 1.00, 0.25),
	183: Rect2(0.00, 0.00, 1.00, 0.25),
	184: Rect2(0.00, 0.00, 0.66, 0.25),
}

const GID_BUBBLES: Array[int] = [242, 243, 244, 265, 266, 267]
const GID_TORCH: int = 273

const STYLES: Dictionary = {
	"small": {"w": 36, "h": 28, "lava_pools": 3, "pillars": 6, "wall_blocks": 3},
	"med": {"w": 56, "h": 44, "lava_pools": 6, "pillars": 14, "wall_blocks": 6},
	"big": {"w": 80, "h": 62, "lava_pools": 11, "pillars": 24, "wall_blocks": 10},
}

const LAYOUTS: Array[String] = ["chambers", "corridors", "caverns", "labyrinth", "rings"]

var rng := RandomNumberGenerator.new()
var grid_w: int = 36
var grid_h: int = 28
var style: String = "small"
var layout: String = "chambers"

# 1 = fuera de la caverna (mar de lava exterior) o pozo de lava interior, 0 = suelo de piedra
var solid: PackedByteArray = PackedByteArray()
# 1 = celda con lava (mar exterior + pozos interiores)
var lava: PackedByteArray = PackedByteArray()
# GID de muro/roca por celda (0 = sin muro)
var wall_gid: PackedInt32Array = PackedInt32Array()

var layer_ground: PackedInt32Array = PackedInt32Array()
var layer_interactive: PackedInt32Array = PackedInt32Array()
var layer_walls: PackedInt32Array = PackedInt32Array()
var layer_decorative: PackedInt32Array = PackedInt32Array()

var spawn_cell: Vector2i = Vector2i(2, 2)


func _init(p_style: String = "small", p_layout: String = "chambers") -> void:
	style = p_style if STYLES.has(p_style) else "small"
	layout = p_layout if LAYOUTS.has(p_layout) else "chambers"


func generate(seed_value: int = -1) -> Dictionary:
	if seed_value < 0:
		seed_value = randi()
	rng.seed = seed_value

	var cfg: Dictionary = STYLES[style]
	grid_w = int(cfg["w"])
	grid_h = int(cfg["h"])

	_fill_solid()
	_carve_layout()
	_keep_largest_region()
	_clamp_border()
	_pick_spawn()

	# En Pixel Dungeons el exterior no excavado es un foso de lava ardiente,
	# más pozos de lava 2x2..3x3 recortados dentro de las salas amplias.
	wall_gid.resize(grid_w * grid_h)
	wall_gid.fill(0)
	lava.resize(grid_w * grid_h)
	for i in range(solid.size()):
		lava[i] = 1 if solid[i] != 0 else 0
	_place_lava_pools(int(cfg["lava_pools"]))
	_place_wall_structures(int(cfg["wall_blocks"]), int(cfg["pillars"]))

	_build_layers()
	return to_result()


# ------------------------------------------------------------------ carving


func _fill_solid() -> void:
	solid.resize(grid_w * grid_h)
	solid.fill(1)


func _idx(x: int, y: int) -> int:
	return y * grid_w + x


func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < grid_w and y < grid_h


func _is_floor(x: int, y: int) -> bool:
	return _in_bounds(x, y) and solid[_idx(x, y)] == 0


func _dig(x: int, y: int) -> void:
	if x >= 3 and y >= 3 and x < grid_w - 3 and y < grid_h - 3:
		solid[_idx(x, y)] = 0


func _carve_layout() -> void:
	match layout:
		"chambers":
			_carve_chambers()
		"corridors":
			_carve_bsp()
		"caverns":
			_carve_caverns()
		"labyrinth":
			_carve_labyrinth()
		"rings":
			_carve_rings()
		_:
			_carve_chambers()


# Cámaras circulares conectadas por puentes anchos sobre la lava.
func _carve_chambers() -> void:
	var count: int = int(clampf(float(grid_w * grid_h) / 170.0, 6.0, 18.0))
	var centers: Array[Vector2i] = []
	for i in range(count):
		var radius: float = rng.randf_range(3.2, 6.0)
		var cx: int = rng.randi_range(5, max(6, grid_w - 6))
		var cy: int = rng.randi_range(5, max(6, grid_h - 6))
		_carve_circle(cx, cy, radius)
		centers.append(Vector2i(cx, cy))
	for i in range(1, centers.size()):
		_carve_corridor(centers[i - 1], centers[i], 2)
	if centers.size() > 2:
		_carve_corridor(centers[0], centers[centers.size() - 1], 2)


func _carve_circle(cx: int, cy: int, radius: float) -> void:
	var r: int = int(ceil(radius))
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			var d: float = Vector2(float(x - cx) * 0.95, float(y - cy) * 1.1).length()
			if d <= radius + rng.randf_range(-0.25, 0.25):
				_dig(x, y)


# Puente / pasillo en L con anchura mínima de 2 celdas para buen combate y visión.
func _carve_corridor(from_cell: Vector2i, to_cell: Vector2i, width: int = 2) -> void:
	var half: int = maxi(1, width - 1)
	if rng.randf() < 0.5:
		for x in range(mini(from_cell.x, to_cell.x), maxi(from_cell.x, to_cell.x) + 1):
			for o in range(-half, half + 1):
				_dig(x, from_cell.y + o)
		for y in range(mini(from_cell.y, to_cell.y), maxi(from_cell.y, to_cell.y) + 1):
			for o in range(-half, half + 1):
				_dig(to_cell.x + o, y)
	else:
		for y in range(mini(from_cell.y, to_cell.y), maxi(from_cell.y, to_cell.y) + 1):
			for o in range(-half, half + 1):
				_dig(from_cell.x + o, y)
		for x in range(mini(from_cell.x, to_cell.x), maxi(from_cell.x, to_cell.x) + 1):
			for o in range(-half, half + 1):
				_dig(x, to_cell.y + o)


# Salas rectangulares BSP conectadas por puentes de piedra.
func _carve_bsp() -> void:
	var leaves: Array[Rect2i] = []
	_split_room(Rect2i(3, 3, grid_w - 6, grid_h - 6), leaves, 0)
	for leaf in leaves:
		var rw: int = maxi(5, int(float(leaf.size.x) * rng.randf_range(0.62, 0.90)))
		var rh: int = maxi(4, int(float(leaf.size.y) * rng.randf_range(0.62, 0.90)))
		var rx: int = leaf.position.x + rng.randi_range(0, maxi(0, leaf.size.x - rw))
		var ry: int = leaf.position.y + rng.randi_range(0, maxi(0, leaf.size.y - rh))
		for y in range(ry, ry + rh):
			for x in range(rx, rx + rw):
				_dig(x, y)
	var centers: Array[Vector2i] = []
	for i in range(leaves.size()):
		var lf: Rect2i = leaves[i]
		centers.append(Vector2i(lf.position.x + lf.size.x / 2, lf.position.y + lf.size.y / 2))
	for i in range(1, centers.size()):
		_carve_corridor(centers[i - 1], centers[i], 2)
	var shortcuts: int = maxi(1, centers.size() / 3)
	for i in range(shortcuts):
		var a: Vector2i = centers[rng.randi() % centers.size()]
		var b: Vector2i = centers[rng.randi() % centers.size()]
		_carve_corridor(a, b, 2)


func _split_room(rect: Rect2i, out: Array[Rect2i], depth: int) -> void:
	var min_side: int = 11
	var can_split_h: bool = rect.size.x >= min_side * 2
	var can_split_v: bool = rect.size.y >= min_side * 2
	if depth > 4 or (not can_split_h and not can_split_v) or (depth > 2 and rng.randf() < 0.25):
		out.append(rect)
		return
	var horizontal: bool = can_split_h if rng.randf() < 0.5 else not can_split_v
	if not can_split_h:
		horizontal = false
	elif not can_split_v:
		horizontal = true
	if horizontal:
		var cut: int = rng.randi_range(min_side, rect.size.x - min_side)
		_split_room(Rect2i(rect.position.x, rect.position.y, cut, rect.size.y), out, depth + 1)
		_split_room(Rect2i(rect.position.x + cut, rect.position.y, rect.size.x - cut, rect.size.y), out, depth + 1)
	else:
		var cutv: int = rng.randi_range(min_side, rect.size.y - min_side)
		_split_room(Rect2i(rect.position.x, rect.position.y, rect.size.x, cutv), out, depth + 1)
		_split_room(Rect2i(rect.position.x, rect.position.y + cutv, rect.size.x, rect.size.y - cutv), out, depth + 1)


# Autómata celular: cavernas orgánicas rodeadas de magma.
func _carve_caverns() -> void:
	var fill_chance: float = rng.randf_range(0.38, 0.45)
	for y in range(grid_h):
		for x in range(grid_w):
			var border: bool = x < 3 or y < 3 or x >= grid_w - 3 or y >= grid_h - 3
			solid[_idx(x, y)] = 1 if (border or rng.randf() < fill_chance) else 0

	var next: PackedByteArray = PackedByteArray()
	next.resize(grid_w * grid_h)
	for _pass in range(5):
		next = solid.duplicate()
		for y in range(2, grid_h - 2):
			for x in range(2, grid_w - 2):
				var walls: int = 0
				for oy in range(-1, 2):
					for ox in range(-1, 2):
						if ox == 0 and oy == 0:
							continue
						if solid[_idx(x + ox, y + oy)] != 0:
							walls += 1
				if solid[_idx(x, y)] != 0:
					next[_idx(x, y)] = 1 if walls >= 4 else 0
				else:
					next[_idx(x, y)] = 1 if walls >= 6 else 0
		solid = next


# Laberinto de pasarelas anchas (paso de 3 celdas, pasillos de 2 de ancho).
func _carve_labyrinth() -> void:
	var cells: Array[Vector2i] = []
	for y in range(4, grid_h - 4, 4):
		for x in range(4, grid_w - 4, 4):
			for oy in range(2):
				for ox in range(2):
					_dig(x + ox, y + oy)
			cells.append(Vector2i(x, y))
	if cells.is_empty():
		_carve_chambers()
		return
	var stack: Array[Vector2i] = [cells[0]]
	var visited: Dictionary = {cells[0]: true}
	while stack.size() > 0:
		var cur: Vector2i = stack[stack.size() - 1]
		var options: Array[Vector2i] = []
		for d in [Vector2i(4, 0), Vector2i(-4, 0), Vector2i(0, 4), Vector2i(0, -4)]:
			var nxt: Vector2i = cur + d
			if nxt.x >= 4 and nxt.y >= 4 and nxt.x < grid_w - 4 and nxt.y < grid_h - 4 and not visited.has(nxt):
				options.append(nxt)
		if options.is_empty():
			stack.pop_back()
			continue
		var chosen: Vector2i = options[rng.randi() % options.size()]
		var step: Vector2i = Vector2i(signi(chosen.x - cur.x), signi(chosen.y - cur.y))
		var p: Vector2i = cur
		while p != chosen:
			for oy in range(2):
				for ox in range(2):
					_dig(p.x + ox, p.y + oy)
			p += step
		visited[chosen] = true
		stack.append(chosen)

	# Abrir atajos para que el laberinto tenga bucles y emboscadas
	for c in cells:
		if rng.randf() < 0.35:
			var d2: Vector2i = [Vector2i(4, 0), Vector2i(0, 4)][rng.randi() % 2]
			var tgt: Vector2i = c + d2
			if tgt.x < grid_w - 4 and tgt.y < grid_h - 4:
				_carve_corridor(c, tgt, 2)
	var rooms: int = int(clampf(float(grid_w * grid_h) / 580.0, 3.0, 8.0))
	for i in range(rooms):
		_carve_circle(rng.randi_range(5, grid_w - 6), rng.randi_range(5, grid_h - 6), rng.randf_range(3.0, 4.6))


# Anillos concéntricos con radios y arena central.
func _carve_rings() -> void:
	var cx: float = float(grid_w) * 0.5
	var cy: float = float(grid_h) * 0.5
	var max_r: float = minf(cx, cy) - 3.5
	var ring_count: int = int(clampf(max_r / 5.5, 2.0, 4.0))
	for ring in range(1, ring_count + 1):
		var radius: float = max_r * (float(ring) / float(ring_count))
		var thickness: float = 2.3
		var gaps: int = rng.randi_range(2, 3)
		var gap_centers: Array[float] = []
		for g in range(gaps):
			gap_centers.append(rng.randf() * TAU)
		for y in range(grid_h):
			for x in range(grid_w):
				var d: float = Vector2(float(x) - cx, float(y) - cy).length()
				if absf(d - radius) > thickness:
					continue
				var ang: float = atan2(float(y) - cy, float(x) - cx)
				var in_gap: bool = false
				for gc in gap_centers:
					var diff: float = absf(wrapf(ang - gc, -PI, PI))
					if diff < 0.24:
						in_gap = true
						break
				if not in_gap:
					_dig(x, y)

	var spokes: int = rng.randi_range(4, 6)
	for s in range(spokes):
		var ang2: float = (TAU / float(spokes)) * float(s) + rng.randf_range(-0.22, 0.22)
		var dir := Vector2(cos(ang2), sin(ang2))
		var steps: int = int(max_r * 1.05)
		for step in range(steps):
			var px: int = int(cx + dir.x * float(step))
			var py: int = int(cy + dir.y * float(step))
			for oy in range(-1, 2):
				for ox in range(-1, 2):
					_dig(px + ox, py + oy)

	_carve_circle(int(cx), int(cy), maxf(3.5, max_r * 0.26))
	var extra: int = rng.randi_range(3, 5)
	for e in range(extra):
		_carve_circle(rng.randi_range(5, grid_w - 6), rng.randi_range(5, grid_h - 6), rng.randf_range(2.8, 4.5))


# ------------------------------------------------------------------ post-proceso


func _keep_largest_region() -> void:
	var best: Array[int] = []
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(grid_w * grid_h)
	seen.fill(0)

	for y in range(grid_h):
		for x in range(grid_w):
			if not _is_floor(x, y) or seen[_idx(x, y)] != 0:
				continue
			var region: Array[int] = []
			var queue: Array[Vector2i] = [Vector2i(x, y)]
			seen[_idx(x, y)] = 1
			while queue.size() > 0:
				var cur: Vector2i = queue.pop_back()
				region.append(_idx(cur.x, cur.y))
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = cur.x + d.x
					var ny: int = cur.y + d.y
					if _is_floor(nx, ny) and seen[_idx(nx, ny)] == 0:
						seen[_idx(nx, ny)] = 1
						queue.append(Vector2i(nx, ny))
			if region.size() > best.size():
				best = region

	var keep: PackedByteArray = PackedByteArray()
	keep.resize(grid_w * grid_h)
	keep.fill(1)
	for i in best:
		keep[i] = 0
	solid = keep


# Margen de al menos 3 celdas de lava alrededor de toda la mazmorra.
func _clamp_border() -> void:
	for y in range(grid_h):
		for x in range(grid_w):
			if x < 3 or y < 3 or x >= grid_w - 3 or y >= grid_h - 3:
				solid[_idx(x, y)] = 1


func _pick_spawn() -> void:
	var cx: int = grid_w / 2
	var cy: int = grid_h / 2
	var best: Vector2i = Vector2i(cx, cy)
	var best_d: float = 1e20
	for y in range(4, grid_h - 4):
		for x in range(4, grid_w - 4):
			if not _is_floor(x, y):
				continue
			var open: int = 0
			for oy in range(-2, 3):
				for ox in range(-2, 3):
					if _is_floor(x + ox, y + oy):
						open += 1
			var d: float = Vector2(float(x - cx), float(y - cy)).length() - float(open) * 0.55
			if d < best_d:
				best_d = d
				best = Vector2i(x, y)
	spawn_cell = best


# Pozos interiores de lava (2x2 o 3x2) dentro de salas amplias, sin cortar caminos.
func _place_lava_pools(count: int) -> void:
	var attempts: int = 0
	var placed: int = 0
	while placed < count and attempts < 450:
		attempts += 1
		var pw: int = rng.randi_range(2, 3)
		var ph: int = rng.randi_range(2, 3)
		var x0: int = rng.randi_range(5, grid_w - pw - 5)
		var y0: int = rng.randi_range(5, grid_h - ph - 5)
		if Vector2(float(x0), float(y0)).distance_to(Vector2(spawn_cell)) < 7.0:
			continue
		# El pozo y su anillo de 1 celda alrededor deben ser suelo limpio
		var clear_ring: bool = true
		for y in range(y0 - 1, y0 + ph + 1):
			for x in range(x0 - 1, x0 + pw + 1):
				if not _is_floor(x, y) or lava[_idx(x, y)] != 0:
					clear_ring = false
					break
			if not clear_ring:
				break
		if not clear_ring:
			continue

		var marked: Array[int] = []
		for y in range(y0, y0 + ph):
			for x in range(x0, x0 + pw):
				var i: int = _idx(x, y)
				lava[i] = 1
				solid[i] = 1
				marked.append(i)
		if _reachable_floor_count() < _total_floor_count():
			for i in marked:
				lava[i] = 0
				solid[i] = 0
			continue
		placed += 1


# Bloques de muro 3x2 / 3x3 (con top/mid/bot oficiales) + pilares de roca sueltos.
func _place_wall_structures(block_count: int, pillar_count: int) -> void:
	var attempts: int = 0
	var placed_blocks: int = 0
	while placed_blocks < block_count and attempts < 400:
		attempts += 1
		var bw: int = rng.randi_range(3, 5)
		var bh: int = rng.randi_range(2, 3)
		var x0: int = rng.randi_range(5, grid_w - bw - 5)
		var y0: int = rng.randi_range(5, grid_h - bh - 5)
		if Vector2(float(x0 + bw / 2), float(y0 + bh / 2)).distance_to(Vector2(spawn_cell)) < 6.5:
			continue
		var ok: bool = true
		for y in range(y0 - 1, y0 + bh + 1):
			for x in range(x0 - 1, x0 + bw + 1):
				if not _is_walkable_floor(x, y):
					ok = false
					break
			if not ok:
				break
		if not ok:
			continue
		for y in range(y0, y0 + bh):
			for x in range(x0, x0 + bw):
				var g: int = 0
				var is_top: bool = (y == y0)
				var is_bot: bool = (y == y0 + bh - 1)
				var is_left: bool = (x == x0)
				var is_right: bool = (x == x0 + bw - 1)
				if is_top:
					if is_left:
						g = GID_WALL_TOP_L
					elif is_right:
						g = GID_WALL_TOP_R
					else:
						g = GID_WALL_TOP_M[(x + y) % GID_WALL_TOP_M.size()]
				elif is_bot:
					if is_left:
						g = GID_WALL_BOT_L
					elif is_right:
						g = GID_WALL_BOT_R
					else:
						g = GID_WALL_BOT_M[(x + y) % GID_WALL_BOT_M.size()]
				else:
					if is_left:
						g = GID_WALL_MID_L
					elif is_right:
						g = GID_WALL_MID_R
					else:
						g = GID_WALL_MID_M[(x + y) % GID_WALL_MID_M.size()]
				wall_gid[_idx(x, y)] = g
		placed_blocks += 1

	var p_attempts: int = 0
	var placed_pillars: int = 0
	while placed_pillars < pillar_count and p_attempts < 500:
		p_attempts += 1
		var px: int = rng.randi_range(4, grid_w - 5)
		var py: int = rng.randi_range(4, grid_h - 5)
		if Vector2(float(px), float(py)).distance_to(Vector2(spawn_cell)) < 4.5:
			continue
		var free_ring: bool = true
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				if not _is_walkable_floor(px + ox, py + oy):
					free_ring = false
					break
			if not free_ring:
				break
		if not free_ring:
			continue
		wall_gid[_idx(px, py)] = GID_PILLARS[rng.randi() % GID_PILLARS.size()]
		placed_pillars += 1


func _is_walkable_floor(x: int, y: int) -> bool:
	if not _in_bounds(x, y):
		return false
	var i: int = _idx(x, y)
	return solid[i] == 0 and lava[i] == 0 and wall_gid[i] == 0


func _total_floor_count() -> int:
	var n: int = 0
	for i in range(solid.size()):
		if solid[i] == 0 and lava[i] == 0 and wall_gid[i] == 0:
			n += 1
	return n


func _reachable_floor_count() -> int:
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(grid_w * grid_h)
	seen.fill(0)
	if not _is_walkable_floor(spawn_cell.x, spawn_cell.y):
		return 0
	var queue: Array[Vector2i] = [spawn_cell]
	seen[_idx(spawn_cell.x, spawn_cell.y)] = 1
	var count: int = 0
	while queue.size() > 0:
		var cur: Vector2i = queue.pop_back()
		count += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = cur.x + d.x
			var ny: int = cur.y + d.y
			if not _in_bounds(nx, ny) or seen[_idx(nx, ny)] != 0:
				continue
			if not _is_walkable_floor(nx, ny):
				continue
			seen[_idx(nx, ny)] = 1
			queue.append(Vector2i(nx, ny))
	return count


# ------------------------------------------------------------------ autotile Tiled


func _is_lava_cell(x: int, y: int) -> bool:
	if not _in_bounds(x, y):
		return true
	return lava[_idx(x, y)] != 0


# Autotile 9-slice idéntico al de the_bridge.json / the_grid.json:
# las celdas de lava pegadas al suelo muestran el borde de roca sobre el magma,
# y el interior profundo usa el tile 160 (magma naranja sólido).
func _pick_lava_gid(x: int, y: int) -> int:
	var u: bool = _is_lava_cell(x, y - 1)
	var d: bool = _is_lava_cell(x, y + 1)
	var l: bool = _is_lava_cell(x - 1, y)
	var r: bool = _is_lava_cell(x + 1, y)
	if not u and not l:
		return GID_LAVA_TL
	if not u and not r:
		return GID_LAVA_TR
	if not d and not l:
		return GID_LAVA_BL
	if not d and not r:
		return GID_LAVA_BR
	if not u:
		return GID_LAVA_TM
	if not d:
		return GID_LAVA_BM
	if not l:
		return GID_LAVA_ML
	if not r:
		return GID_LAVA_MR
	return GID_LAVA_MM


func _build_layers() -> void:
	var total: int = grid_w * grid_h
	layer_ground.resize(total)
	layer_interactive.resize(total)
	layer_walls.resize(total)
	layer_decorative.resize(total)
	layer_ground.fill(0)
	layer_interactive.fill(0)
	layer_walls.fill(0)
	layer_decorative.fill(0)

	# 1. Suelo en ajedrez 2x2 oficial (necesario también bajo los bordes semitransparentes de lava y muros)
	for y in range(grid_h):
		var row_tiles: Array[int] = GID_GROUND_EVEN if (y % 2 == 0) else GID_GROUND_ODD
		for x in range(grid_w):
			layer_ground[_idx(x, y)] = row_tiles[x % 2]

	# 2. Capa interactive_objects: mar de lava exterior + pozos de lava interiores con bordes 9-slice
	for y in range(grid_h):
		for x in range(grid_w):
			var i: int = _idx(x, y)
			if lava[i] != 0:
				var lg: int = _pick_lava_gid(x, y)
				layer_interactive[i] = lg
				# Burbujas animadas sobre el magma profundo (igual que en los mapas oficiales)
				if lg == GID_LAVA_MM and rng.randf() < 0.32:
					layer_decorative[i] = GID_BUBBLES[rng.randi() % GID_BUBBLES.size()]

	# 3. Capa walls + antorchas: bloques de roca y pilares, con antorchas en la cara sur o junto a costas
	for y in range(1, grid_h - 1):
		for x in range(1, grid_w - 1):
			var i: int = _idx(x, y)
			var wg: int = wall_gid[i]
			if wg > 0:
				layer_walls[i] = wg
				if wg in GID_WALL_BOT_M and rng.randf() < 0.55:
					layer_decorative[i] = GID_TORCH
			elif lava[i] == 0:
				# Antorchas de suelo cerca de bordes de lava o pilares para dar luz cálida
				var near_feature: bool = false
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var ni: int = _idx(x + d.x, y + d.y)
					if lava[ni] != 0 or wall_gid[ni] > 0:
						near_feature = true
						break
				if near_feature and rng.randf() < 0.08:
					layer_decorative[i] = GID_TORCH


# ------------------------------------------------------------------ salida


func to_result() -> Dictionary:
	var walkable: Array[Vector2i] = []
	var ore_spots: Array[Vector2i] = []
	var torches: Array[Vector2i] = []
	var fires: Array[Vector2i] = []
	for y in range(grid_h):
		for x in range(grid_w):
			var i: int = _idx(x, y)
			if layer_decorative[i] == GID_TORCH:
				torches.append(Vector2i(x, y))
			if lava[i] != 0:
				fires.append(Vector2i(x, y))
				continue
			if wall_gid[i] > 0 or solid[i] != 0:
				continue
			walkable.append(Vector2i(x, y))
			var near_obstacle: bool = false
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + d.x
				var ny: int = y + d.y
				if not _in_bounds(nx, ny):
					continue
				var ni: int = _idx(nx, ny)
				if lava[ni] != 0 or wall_gid[ni] > 0:
					near_obstacle = true
					break
			if near_obstacle:
				ore_spots.append(Vector2i(x, y))

	return {
		"width": grid_w,
		"height": grid_h,
		"style": style,
		"layout": layout,
		"seed": rng.seed,
		"layer_ground": layer_ground,
		"layer_interactive": layer_interactive,
		"layer_walls": layer_walls,
		"layer_decorative": layer_decorative,
		"walkable": walkable,
		"ore_spots": ore_spots,
		"torches": torches,
		"fires": fires,
		"spawn_cell": spawn_cell,
		"floor_count": walkable.size(),
	}
