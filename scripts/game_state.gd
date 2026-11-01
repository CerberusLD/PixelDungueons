extends Node
class_name PixelDungeonsState

# Wallet y economía persistente de Pixel Dungeons (pixeldungeons.xyz)
var wallet_pixels: int = 50
var pickaxes_balance: int = 400
var social_tickets_balance: int = 3
var free_games_left: int = 5
var selected_skin: int = 1 # 1..13 skins oficiales de characters.png
var membership_tier: String = "gold" # "none", "gold", "diamond"
var total_escaped_runs: int = 0
var total_deaths: int = 0
var best_run_haul: int = 0
var selected_dungeon: int = 0

# Ajustes oficiales (pixeldungeons.game-settings)
var lights_enabled: bool = true
var hide_hud: bool = false
var hide_names: bool = false
var hide_rewards: bool = false
var camera_shift: float = 0.0

const SKIN_NAMES: Dictionary = {
	1: "Classic Miner",
	2: "Blonde Explorer",
	3: "Crimson Raider",
	4: "Shadow Ninja",
	5: "Incognito Hood",
	6: "Emerald Ranger",
	7: "Cyber Punk",
	8: "Viking Berserker",
	9: "Golden Knight",
	10: "Void Mage",
	11: "Frost Guardian",
	12: "Inferno Demon",
	13: "Ronin Samurai"
}

const DUNGEON_CONFIGS: Array[Dictionary] = [
	{
		"id": 0,
		"name": "Practice Caverns (The Clock)",
		"style": "small",
		"layout": "chambers",
		"region": "as",
		"region_name": "Asia",
		"entry_fee": 0,
		"pickaxe_cost": 0,
		"bounty_pool": 173.18,
		"reward_mult": 1.0,
		"duration": 60.0,
		"initial_bombs": 3,
		"ore_density": 0.078,
		"goblin_density": 0.0105,
		"bot_count": 5,
		"lava_scale": 0.8,
		"epic_chance": 0.12,
		"desc": "FREE · Proc SMALL · 1 min · 3 bombs"
	},
	{
		"id": 1,
		"name": "The Bridge",
		"style": "med",
		"layout": "corridors",
		"region": "eu",
		"region_name": "Europe",
		"entry_fee": 20,
		"pickaxe_cost": 400,
		"bounty_pool": 1515.00,
		"reward_mult": 2.5,
		"duration": 120.0,
		"initial_bombs": 5,
		"ore_density": 0.058,
		"goblin_density": 0.0090,
		"bot_count": 6,
		"lava_scale": 1.0,
		"epic_chance": 0.18,
		"desc": "20 $PIXEL · Proc MED · 2 min · 5 bombs"
	},
	{
		"id": 2,
		"name": "Chaos Rings",
		"style": "big",
		"layout": "rings",
		"region": "us",
		"region_name": "North America",
		"entry_fee": 20,
		"pickaxe_cost": 400,
		"bounty_pool": 2840.50,
		"reward_mult": 2.5,
		"duration": 120.0,
		"initial_bombs": 3,
		"ore_density": 0.036,
		"goblin_density": 0.0050,
		"bot_count": 8,
		"lava_scale": 1.3,
		"epic_chance": 0.20,
		"desc": "20 $PIXEL · Proc BIG · Anillos · Extra Ores"
	},
	{
		"id": 3,
		"name": "Deep Ethers",
		"style": "big",
		"layout": "caverns",
		"region": "sa",
		"region_name": "South America",
		"entry_fee": 50,
		"pickaxe_cost": 1000,
		"bounty_pool": 6420.00,
		"reward_mult": 4.0,
		"duration": 120.0,
		"initial_bombs": 5,
		"ore_density": 0.034,
		"goblin_density": 0.0055,
		"bot_count": 8,
		"lava_scale": 1.5,
		"epic_chance": 0.28,
		"desc": "50 $PIXEL · Proc BIG · Cuevas · Epic Ores"
	},
	{
		"id": 4,
		"name": "The Cage",
		"style": "med",
		"layout": "labyrinth",
		"region": "eu",
		"region_name": "Europe",
		"entry_fee": 0,
		"pickaxe_cost": 0,
		"bounty_pool": 420.75,
		"reward_mult": 1.2,
		"duration": 90.0,
		"initial_bombs": 3,
		"ore_density": 0.060,
		"goblin_density": 0.0095,
		"bot_count": 6,
		"lava_scale": 0.9,
		"epic_chance": 0.14,
		"desc": "FREE · Proc MED · Laberinto · 90 sec"
	},
	{
		"id": 5,
		"name": "The Grid",
		"style": "med",
		"layout": "corridors",
		"region": "us",
		"region_name": "North America",
		"entry_fee": 20,
		"pickaxe_cost": 400,
		"bounty_pool": 1980.00,
		"reward_mult": 2.5,
		"duration": 120.0,
		"initial_bombs": 4,
		"ore_density": 0.052,
		"goblin_density": 0.0100,
		"bot_count": 6,
		"lava_scale": 1.0,
		"epic_chance": 0.16,
		"desc": "20 $PIXEL · Proc MED · Salas BSP · 4 bombs"
	},
	{
		"id": 6,
		"name": "The Lair",
		"style": "big",
		"layout": "chambers",
		"region": "as",
		"region_name": "Asia",
		"entry_fee": 20,
		"pickaxe_cost": 400,
		"bounty_pool": 2150.00,
		"reward_mult": 2.5,
		"duration": 120.0,
		"initial_bombs": 3,
		"ore_density": 0.038,
		"goblin_density": 0.0065,
		"bot_count": 7,
		"lava_scale": 1.2,
		"epic_chance": 0.18,
		"desc": "20 $PIXEL · Proc BIG · Salas · Extra Goblins"
	},
	{
		"id": 7,
		"name": "The Octopus",
		"style": "small",
		"layout": "rings",
		"region": "sa",
		"region_name": "South America",
		"entry_fee": 20,
		"pickaxe_cost": 400,
		"bounty_pool": 1640.00,
		"reward_mult": 2.5,
		"duration": 120.0,
		"initial_bombs": 5,
		"ore_density": 0.075,
		"goblin_density": 0.0115,
		"bot_count": 6,
		"lava_scale": 1.0,
		"epic_chance": 0.18,
		"desc": "20 $PIXEL · Proc SMALL · Anillos · 5 bombs"
	},
	{
		"id": 8,
		"name": "The Swamp",
		"style": "med",
		"layout": "caverns",
		"region": "eu",
		"region_name": "Europe",
		"entry_fee": 0,
		"pickaxe_cost": 0,
		"bounty_pool": 510.25,
		"reward_mult": 1.2,
		"duration": 120.0,
		"initial_bombs": 3,
		"ore_density": 0.056,
		"goblin_density": 0.0090,
		"bot_count": 6,
		"lava_scale": 1.1,
		"epic_chance": 0.12,
		"desc": "FREE · Proc MED · Cuevas · 2 min"
	},
	{
		"id": 9,
		"name": "The Samba",
		"style": "small",
		"layout": "labyrinth",
		"region": "sa",
		"region_name": "South America",
		"entry_fee": 0,
		"pickaxe_cost": 0,
		"bounty_pool": 325.40,
		"reward_mult": 1.0,
		"duration": 60.0,
		"initial_bombs": 3,
		"ore_density": 0.082,
		"goblin_density": 0.0110,
		"bot_count": 5,
		"lava_scale": 0.7,
		"epic_chance": 0.12,
		"desc": "FREE · Proc SMALL · Laberinto · Fast Run"
	}
]

const SAVE_PATH: String = "user://pixel_dungeons_save.cfg"

func _ready() -> void:
	load_state()

func get_current_config() -> Dictionary:
	var idx: int = clampi(selected_dungeon, 0, DUNGEON_CONFIGS.size() - 1)
	return DUNGEON_CONFIGS[idx]

func get_dungeon_config(dungeon_id: int) -> Dictionary:
	var idx: int = clampi(dungeon_id, 0, DUNGEON_CONFIGS.size() - 1)
	return DUNGEON_CONFIGS[idx]

func can_enter_dungeon(dungeon_id: int) -> bool:
	var idx: int = clampi(dungeon_id, 0, DUNGEON_CONFIGS.size() - 1)
	var fee: int = int(DUNGEON_CONFIGS[idx]["entry_fee"])
	return wallet_pixels >= fee

func pay_entry_fee(dungeon_id: int) -> bool:
	if not can_enter_dungeon(dungeon_id):
		return false
	selected_dungeon = clampi(dungeon_id, 0, DUNGEON_CONFIGS.size() - 1)
	var fee: int = int(DUNGEON_CONFIGS[selected_dungeon]["entry_fee"])
	wallet_pixels -= fee
	save_state()
	return true

func record_escape(haul: int) -> void:
	wallet_pixels += max(0, haul)
	total_escaped_runs += 1
	if haul > best_run_haul:
		best_run_haul = haul
	save_state()

func record_death() -> void:
	total_deaths += 1
	save_state()

func compute_speed_multiplier(pixels_carried: int, max_bag_capacity: int = 100) -> float:
	# En Pixel Dungeons, cuanto más $PIXEL llevas en la bolsa, más pesa (weight %) y más lento caminas
	var ratio: float = clampf(float(pixels_carried) / float(max(1, max_bag_capacity)), 0.0, 1.5)
	return clampf(1.0 - ratio * 0.45, 0.42, 1.0)

func compute_bag_weight_percent(pixels_carried: int, max_bag_capacity: int = 100) -> int:
	return int(round(clampf(float(pixels_carried) / float(max(1, max_bag_capacity)) * 100.0, 0.0, 200.0)))

func save_state() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "wallet_pixels", wallet_pixels)
	cfg.set_value("progress", "pickaxes_balance", pickaxes_balance)
	cfg.set_value("progress", "selected_skin", selected_skin)
	cfg.set_value("progress", "total_escaped_runs", total_escaped_runs)
	cfg.set_value("progress", "total_deaths", total_deaths)
	cfg.set_value("progress", "best_run_haul", best_run_haul)
	cfg.set_value("settings", "lights_enabled", lights_enabled)
	cfg.set_value("settings", "hide_hud", hide_hud)
	cfg.set_value("settings", "hide_names", hide_names)
	cfg.set_value("settings", "hide_rewards", hide_rewards)
	cfg.save(SAVE_PATH)

func load_state() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		wallet_pixels = int(cfg.get_value("progress", "wallet_pixels", 50))
		pickaxes_balance = int(cfg.get_value("progress", "pickaxes_balance", 400))
		selected_skin = clampi(int(cfg.get_value("progress", "selected_skin", 1)), 1, 13)
		total_escaped_runs = int(cfg.get_value("progress", "total_escaped_runs", 0))
		total_deaths = int(cfg.get_value("progress", "total_deaths", 0))
		best_run_haul = int(cfg.get_value("progress", "best_run_haul", 0))
		lights_enabled = bool(cfg.get_value("settings", "lights_enabled", true))
		hide_hud = bool(cfg.get_value("settings", "hide_hud", false))
		hide_names = bool(cfg.get_value("settings", "hide_names", false))
		hide_rewards = bool(cfg.get_value("settings", "hide_rewards", false))
