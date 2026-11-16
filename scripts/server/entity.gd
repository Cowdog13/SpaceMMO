## A unit on the hex grid: player ship, mercenary or drone. Server-side only.
extends RefCounted

const Items = preload("res://scripts/shared/items_db.gd")
const World = preload("res://scripts/shared/world_def.gd")

const MIN_MOVE_TICKS := 15 # fastest possible: one hex per 2.5 seconds

var id := 0
var kind := "player" # player | merc | drone
var name := ""
var hex := Vector2i.ZERO
var facing := 0
var in_space := false

# loadout
var hull_id := "hull_scout"
var equipped := {} # port id -> item id

# stats (recalculated from loadout)
var max_hp := 100.0
var max_shield := 0.0
var shield_regen := 0.0 # per tick
var max_energy := 0.0
var energy_regen := 0.0 # per tick
var move_ticks := 15
var damage_mult := 1.0

# live state
var hp := 100.0
var shield := 0.0
var energy := 0.0
var move_cd := 0
var has_goal := false
var goal := Vector2i.ZERO
var path: Array = []
var wait_ticks := 0
var cooldowns := {} # system key -> ticks remaining
var pending: Array = [] # queued activation requests, processed next tick
var channel := {} # active channel {key, fire_tick, req}
var target_id := 0
var auto_fire := {} # port id -> bool
var last_damage_tick := -1000
var damage_by := {} # root entity id -> damage dealt
var level := 1
var dead := false

# player
var peer := 0
var account: Dictionary = {}
var drones: Array = [] # drone entity ids

# npc
var tier := 1
var home := Vector2i.ZERO
var zone := -1
var ai_state := "wander"
var think_offset := 0
var aggro_range := 7
var leash := 40

# drone
var owner_id := 0
var drone_def := {}
var attack_id := 0
var ordered := false # drone has an explicit player move order


func root_id() -> int:
	return owner_id if kind == "drone" else id


func is_hostile_npc() -> bool:
	return kind == "merc"


## Recompute derived stats from hull + equipped items. NPC tier scaling applied for mercs.
func recalc() -> void:
	var hull := Items.get_item(hull_id)
	var hp_add := 0.0
	var sh := 0.0
	var shr := 0.0
	var en: float = hull.get("energy", 30)
	var enr: float = hull.get("energy_regen", 1.0)
	var mv: int = hull.get("move_ticks", 20)
	for port_id in equipped:
		var it := Items.get_item(equipped[port_id])
		var st: Dictionary = it.get("stats", {})
		hp_add += st.get("max_hp", 0)
		sh += st.get("max_shield", 0)
		shr += st.get("shield_regen", 0)
		en += st.get("max_energy", 0)
		enr += st.get("energy_regen", 0)
		mv += int(st.get("move_ticks", 0))
	var scale := 1.0
	if kind == "merc":
		scale = 1.0 + 0.55 * (tier - 1)
		damage_mult = 1.0 + 0.35 * (tier - 1)
		enr *= 2.0
	max_hp = (hull.get("hp", 100) + hp_add) * scale
	max_shield = sh * scale
	shield_regen = shr * scale / World.TICK_RATE
	max_energy = en
	energy_regen = enr / World.TICK_RATE
	move_ticks = maxi(MIN_MOVE_TICKS, mv)
	if kind == "merc":
		move_ticks = maxi(MIN_MOVE_TICKS, move_ticks + 3) # mercs are a little slower than players
	hp = minf(hp, max_hp)
	shield = minf(shield, max_shield)
	energy = minf(energy, max_energy)


func full_restore() -> void:
	hp = max_hp
	shield = max_shield
	energy = max_energy


func ports() -> Array:
	return Items.get_item(hull_id).get("ports", [])


func port_def(port_id: String) -> Dictionary:
	return Items.get_port(hull_id, port_id)


func cargo() -> Array:
	return account.get("cargo", [])


func cargo_capacity() -> int:
	return int(Items.get_item(hull_id).get("cargo", 10))


func cargo_count(item_id: String) -> int:
	var n := 0
	for s in cargo():
		if s.id == item_id:
			n += int(s.qty)
	return n


## Number of free item units of `item_id` we could add.
func cargo_room_for(item_id: String) -> int:
	var stack := Items.stack_size(item_id)
	var room := (cargo_capacity() - cargo().size()) * stack
	for s in cargo():
		if s.id == item_id:
			room += stack - int(s.qty)
	return room


func cargo_add(item_id: String, qty: int) -> int:
	## Returns how many were actually added.
	var stack := Items.stack_size(item_id)
	var c: Array = account.cargo
	var left := qty
	for s in c:
		if left <= 0:
			break
		if s.id == item_id and s.qty < stack:
			var add := mini(stack - int(s.qty), left)
			s.qty = int(s.qty) + add
			left -= add
	while left > 0 and c.size() < cargo_capacity():
		var add := mini(stack, left)
		c.append({"id": item_id, "qty": add})
		left -= add
	return qty - left


func cargo_remove(item_id: String, qty: int) -> bool:
	if cargo_count(item_id) < qty:
		return false
	var c: Array = account.cargo
	var left := qty
	for i in range(c.size() - 1, -1, -1):
		if left <= 0:
			break
		if c[i].id == item_id:
			var take := mini(int(c[i].qty), left)
			c[i].qty = int(c[i].qty) - take
			left -= take
			if c[i].qty <= 0:
				c.remove_at(i)
	return true
