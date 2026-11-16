## Item, hull, mercenary and shop definitions. Shared by server and client.
## Add new content here; the systems read everything generically.
##
## Item types: hull, weapon, shield, mod, energy, consumable.
## slot: which port kind the item fits ("weapon" or "body"). Consumables are not equipped.
## stats: passive bonuses while equipped. Rates are per second.
##   max_hp, max_shield, shield_regen, max_energy, energy_regen, move_ticks (added, negative = faster)
## active: an activatable system.
##   effect: damage | restore_shield | restore_energy | heal | spawn_drone
##   energy: energy cost, cooldown: ticks, channel: ticks (cancelled if the ship moves),
##   delay: ticks before effect (not cancelled), range: hexes, damage, projectile_speed: hexes/tick
##   needs_target: true for effects aimed at another entity
extends RefCounted

const ITEMS := {
	# ---------------- Hulls ----------------
	"hull_scout": {
		"name": "Scout Hull", "type": "hull", "price": 0, "level": 1,
		"hp": 100, "move_ticks": 15, "cargo": 12, "energy": 40, "energy_regen": 2.0,
		"ports": [
			{"id": "front", "name": "Front", "kind": "weapon", "dir": 0.0, "arc": 90.0},
			{"id": "body1", "name": "Body 1", "kind": "body"},
			{"id": "body2", "name": "Body 2", "kind": "body"},
		],
		"desc": "Fast and fragile. The fastest hull in the system.",
	},
	"hull_corvette": {
		"name": "Corvette Hull", "type": "hull", "price": 6000, "level": 3,
		"hp": 200, "move_ticks": 18, "cargo": 20, "energy": 60, "energy_regen": 3.0,
		"ports": [
			{"id": "front", "name": "Front", "kind": "weapon", "dir": 0.0, "arc": 90.0},
			{"id": "left", "name": "Port Side", "kind": "weapon", "dir": -90.0, "arc": 120.0},
			{"id": "right", "name": "Starboard", "kind": "weapon", "dir": 90.0, "arc": 120.0},
			{"id": "body1", "name": "Body 1", "kind": "body"},
			{"id": "body2", "name": "Body 2", "kind": "body"},
			{"id": "body3", "name": "Body 3", "kind": "body"},
		],
		"desc": "Balanced warship with broadside weapon ports.",
	},
	"hull_frigate": {
		"name": "Frigate Hull", "type": "hull", "price": 25000, "level": 6,
		"hp": 380, "move_ticks": 22, "cargo": 30, "energy": 90, "energy_regen": 4.0,
		"ports": [
			{"id": "front", "name": "Front", "kind": "weapon", "dir": 0.0, "arc": 90.0},
			{"id": "front2", "name": "Front Spinal", "kind": "weapon", "dir": 0.0, "arc": 40.0},
			{"id": "left", "name": "Port Side", "kind": "weapon", "dir": -90.0, "arc": 120.0},
			{"id": "right", "name": "Starboard", "kind": "weapon", "dir": 90.0, "arc": 120.0},
			{"id": "rear", "name": "Rear", "kind": "weapon", "dir": 180.0, "arc": 90.0},
			{"id": "body1", "name": "Body 1", "kind": "body"},
			{"id": "body2", "name": "Body 2", "kind": "body"},
			{"id": "body3", "name": "Body 3", "kind": "body"},
			{"id": "body4", "name": "Body 4", "kind": "body"},
		],
		"desc": "Heavy line ship. Slow but bristling with ports.",
	},
	"hull_hauler": {
		"name": "Hauler Hull", "type": "hull", "price": 9000, "level": 2,
		"hp": 260, "move_ticks": 24, "cargo": 80, "energy": 50, "energy_regen": 2.5,
		"ports": [
			{"id": "rear", "name": "Rear", "kind": "weapon", "dir": 180.0, "arc": 120.0},
			{"id": "body1", "name": "Body 1", "kind": "body"},
			{"id": "body2", "name": "Body 2", "kind": "body"},
		],
		"desc": "Huge cargo hold for traders.",
	},

	# ---------------- Weapons ----------------
	"laser_mk1": {
		"name": "Pulse Laser Mk I", "type": "weapon", "slot": "weapon", "price": 300, "level": 1,
		"active": {"effect": "damage", "needs_target": true, "damage": 9, "range": 6, "energy": 4, "cooldown": 12, "fx": "beam", "color": Color(1, 0.3, 0.3)},
		"desc": "Instant-hit beam.",
	},
	"laser_mk2": {
		"name": "Pulse Laser Mk II", "type": "weapon", "slot": "weapon", "price": 1800, "level": 3,
		"active": {"effect": "damage", "needs_target": true, "damage": 15, "range": 7, "energy": 6, "cooldown": 12, "fx": "beam", "color": Color(1, 0.5, 0.2)},
		"desc": "Improved focusing optics.",
	},
	"railgun_mk1": {
		"name": "Railgun Mk I", "type": "weapon", "slot": "weapon", "price": 3500, "level": 4,
		"active": {"effect": "damage", "needs_target": true, "damage": 40, "range": 11, "energy": 14, "cooldown": 42, "channel": 6, "fx": "rail", "color": Color(0.6, 0.8, 1)},
		"desc": "Charges for 1 second (cancelled by moving), then hits hard at long range.",
	},
	"missile_mk1": {
		"name": "Missile Rack Mk I", "type": "weapon", "slot": "weapon", "price": 2200, "level": 2,
		"active": {"effect": "damage", "needs_target": true, "damage": 26, "range": 9, "energy": 9, "cooldown": 30, "projectile_speed": 2.0, "fx": "missile", "color": Color(1, 0.9, 0.3)},
		"desc": "Projectile that takes time to reach the target.",
	},

	# ---------------- Shields ----------------
	"shield_mk1": {
		"name": "Deflector Mk I", "type": "shield", "slot": "body", "price": 400, "level": 1,
		"stats": {"max_shield": 40, "shield_regen": 2.0},
		"desc": "Basic shield generator.",
	},
	"shield_mk2": {
		"name": "Deflector Mk II", "type": "shield", "slot": "body", "price": 2600, "level": 3,
		"stats": {"max_shield": 90, "shield_regen": 4.0},
		"active": {"effect": "restore_shield", "amount": 35, "energy": 15, "cooldown": 120, "channel": 3},
		"desc": "Stronger shield with an emergency burst.",
	},

	# ---------------- Energy ----------------
	"reactor_mk1": {
		"name": "Fusion Reactor Mk I", "type": "energy", "slot": "body", "price": 350, "level": 1,
		"stats": {"energy_regen": 2.0, "max_energy": 10},
		"desc": "Increases energy regeneration.",
	},
	"battery_mk1": {
		"name": "Capacitor Bank Mk I", "type": "energy", "slot": "body", "price": 300, "level": 1,
		"stats": {"max_energy": 50},
		"desc": "Increases energy capacity.",
	},

	# ---------------- Mods ----------------
	"armor_plating": {
		"name": "Armor Plating", "type": "mod", "slot": "body", "price": 500, "level": 1,
		"stats": {"max_hp": 50, "move_ticks": 1},
		"desc": "+50 hull, slightly slower.",
	},
	"engine_tuner": {
		"name": "Engine Tuner", "type": "mod", "slot": "body", "price": 1500, "level": 2,
		"stats": {"move_ticks": -2},
		"desc": "Faster movement (can never beat 2.5s per hex).",
	},
	"drone_bay_mk1": {
		"name": "Drone Bay Mk I", "type": "mod", "slot": "body", "price": 1600, "level": 2,
		"active": {"effect": "spawn_drone", "energy": 20, "cooldown": 60, "channel": 12, "max_drones": 2,
			"drone": {"name": "Combat Drone", "hp": 40, "move_ticks": 15, "damage": 4, "range": 4, "cooldown": 12, "color": Color(0.5, 1, 0.6)}},
		"desc": "Launches up to 2 combat drones (2s channel).",
	},

	# ---------------- Consumables ----------------
	"repair_kit": {
		"name": "Repair Kit", "type": "consumable", "price": 100, "level": 1, "stack": 20,
		"active": {"effect": "heal", "amount": 50, "cooldown": 30, "channel": 6},
		"desc": "Repairs 50 hull over a 1s channel.",
	},
	"energy_cell": {
		"name": "Energy Cell", "type": "consumable", "price": 80, "level": 1, "stack": 20,
		"active": {"effect": "restore_energy", "amount": 40, "cooldown": 30},
		"desc": "Restores 40 energy. Usable when empty.",
	},
	"shield_cell": {
		"name": "Shield Cell", "type": "consumable", "price": 90, "level": 1, "stack": 20,
		"active": {"effect": "restore_shield", "amount": 40, "cooldown": 30},
		"desc": "Restores 40 shield.",
	},
	# ---------------- Trade goods (loot) ----------------
	"salvage": {
		"name": "Salvage", "type": "consumable", "price": 60, "level": 1, "stack": 50,
		"desc": "Scrap from destroyed ships. Sell it at a station.",
	},
}

const STARTER := {
	"hull": "hull_scout",
	"equipped": {"front": "laser_mk1", "body1": "shield_mk1"},
	"cargo": [{"id": "repair_kit", "qty": 3}, {"id": "energy_cell", "qty": 2}],
	"credits": 1000,
}

## What each planet's station sells.
const SHOPS := {
	"earth": ["hull_scout", "hull_hauler", "laser_mk1", "shield_mk1", "reactor_mk1", "battery_mk1", "armor_plating", "repair_kit", "energy_cell", "shield_cell"],
	"venus": ["hull_corvette", "laser_mk1", "laser_mk2", "missile_mk1", "shield_mk1", "reactor_mk1", "battery_mk1", "drone_bay_mk1", "engine_tuner", "repair_kit", "energy_cell", "shield_cell"],
	"mercury": ["hull_corvette", "laser_mk2", "missile_mk1", "railgun_mk1", "shield_mk2", "drone_bay_mk1", "engine_tuner", "repair_kit", "energy_cell", "shield_cell"],
	"mars": ["hull_corvette", "hull_frigate", "laser_mk2", "railgun_mk1", "missile_mk1", "shield_mk2", "armor_plating", "repair_kit", "energy_cell", "shield_cell"],
	"jupiter": ["hull_frigate", "railgun_mk1", "shield_mk2", "drone_bay_mk1", "repair_kit", "energy_cell", "shield_cell"],
	"saturn": ["hull_frigate", "railgun_mk1", "shield_mk2", "repair_kit", "energy_cell", "shield_cell"],
	"uranus": ["repair_kit", "energy_cell", "shield_cell"],
	"neptune": ["repair_kit", "energy_cell", "shield_cell"],
}

## Mercenary loadouts per tier (1 weak .. 10 deadly). Stats are scaled by tier.
const MERC_TEMPLATES := [
	{"min_tier": 1, "name": "Merc Raider", "hull": "hull_scout", "equipped": {"front": "laser_mk1", "body1": "shield_mk1"}},
	{"min_tier": 2, "name": "Merc Gunship", "hull": "hull_scout", "equipped": {"front": "missile_mk1", "body1": "shield_mk1", "body2": "reactor_mk1"}},
	{"min_tier": 4, "name": "Merc Corvette", "hull": "hull_corvette", "equipped": {"front": "laser_mk2", "left": "laser_mk1", "right": "laser_mk1", "body1": "shield_mk2", "body2": "reactor_mk1"}},
	{"min_tier": 7, "name": "Merc Warlord", "hull": "hull_frigate", "equipped": {"front": "railgun_mk1", "front2": "laser_mk2", "left": "laser_mk2", "right": "laser_mk2", "body1": "shield_mk2", "body2": "reactor_mk1", "body3": "reactor_mk1"}},
]

## [item id, drop chance] rolled per kill. Tier adds bonus chance.
const LOOT_TABLE := [
	["salvage", 0.8], ["repair_kit", 0.25], ["energy_cell", 0.2], ["shield_cell", 0.15],
	["laser_mk1", 0.06], ["shield_mk1", 0.06], ["reactor_mk1", 0.05], ["battery_mk1", 0.05],
	["armor_plating", 0.04], ["missile_mk1", 0.03], ["laser_mk2", 0.02], ["engine_tuner", 0.02],
	["drone_bay_mk1", 0.015], ["shield_mk2", 0.015], ["railgun_mk1", 0.01],
]


static func get_item(id: String) -> Dictionary:
	return ITEMS.get(id, {})


static func item_name(id: String) -> String:
	return ITEMS.get(id, {}).get("name", id)


static func stack_size(id: String) -> int:
	return int(ITEMS.get(id, {}).get("stack", 1))


static func sell_price(id: String) -> int:
	return int(ITEMS.get(id, {}).get("price", 0) * 0.5)


static func get_port(hull_id: String, port_id: String) -> Dictionary:
	for p in ITEMS.get(hull_id, {}).get("ports", []):
		if p.id == port_id:
			return p
	return {}


## Can this item be placed into this port?
static func fits(item_id: String, port: Dictionary) -> bool:
	var it := get_item(item_id)
	return not it.is_empty() and it.get("slot", "") == port.get("kind", "?")


static func level_for_xp(xp: int) -> int:
	return int(floor(sqrt(xp / 100.0))) + 1


static func xp_for_level(level: int) -> int:
	return (level - 1) * (level - 1) * 100


static func merc_template_for_tier(tier: int, rng: RandomNumberGenerator) -> Dictionary:
	var options := []
	for t in MERC_TEMPLATES:
		if t.min_tier <= tier:
			options.append(t)
	# Prefer the strongest templates the tier allows.
	var idx := options.size() - 1 - (rng.randi() % mini(2, options.size()))
	return options[idx]
