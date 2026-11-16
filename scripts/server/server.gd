## Authoritative game server. Runs headless; owns the whole simulation.
## Start with:  godot --headless --path . -- --server [--port 7777] [--data DIR]
extends Node

const Hex = preload("res://scripts/shared/hex.gd")
const World = preload("res://scripts/shared/world_def.gd")
const Items = preload("res://scripts/shared/items_db.gd")
const Entity = preload("res://scripts/server/entity.gd")
const Pathfinder = preload("res://scripts/server/pathfinder.gd")
const Persistence = preload("res://scripts/server/persistence.gd")

const VIEW_RADIUS := 42 # hexes of world a client receives
const BUCKET := 16
const EPOCH := 1750000000.0
const SAVE_INTERVAL_TICKS := 60 * World.TICK_RATE
const LOOT_LIFETIME := 180 * World.TICK_RATE
const LOOT_LOCK := 20 * World.TICK_RATE
const MAX_PENDING := 4
const ENT_STRIDE := 9 # ints per entity in a snapshot
const ENTS_PER_PACKET := 30

var port := Net.DEFAULT_PORT
var max_players := 128
var dev_mode := false # enables /tp /give /credits /xp chat commands
var data_dir := "user://server_data"

var world: World
var db: Persistence
var rng := RandomNumberGenerator.new()
var tick := 0
var start_wt := 0.0
var acc := 0.0

var entities := {} # id -> Entity (only things in space)
var occupancy := {} # Vector2i -> entity id
var buckets := {} # Vector2i bucket -> Array[Entity]
var next_id := 1
var sessions := {} # peer -> {ship: Entity, known: {}, cmd_count: int}
var online := {} # username -> peer
var loot := {} # id -> crate dict
var fx: Array = [] # events this tick
var scheduled: Array = [] # delayed effects
var market := {}
var zone_counts := {}


func _ready() -> void:
	_parse_args()
	rng.randomize()
	world = World.new()
	db = Persistence.new(data_dir)
	market = db.load_market()
	start_wt = Time.get_unix_time_from_system() - EPOCH
	world.update(world_time())
	for i in World.ZONES.size():
		zone_counts[i] = 0
	# Pre-populate mercenaries.
	for i in World.ZONES.size():
		for _k in World.ZONES[i].pop:
			_spawn_merc(i)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_players)
	if err != OK:
		push_error("Could not start server on port %d (error %d)" % [port, err])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Net.server_handler = self
	print("[server] SpaceMMO server listening on UDP port %d, data dir: %s" % [port, ProjectSettings.globalize_path(data_dir)])
	print("[server] %d asteroids, %d mercenaries spawned" % [world.asteroids.size(), entities.size()])


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--port":
				port = int(args[i + 1])
			"--data":
				data_dir = args[i + 1]
			"--max-players":
				max_players = int(args[i + 1])
			"--dev":
				dev_mode = true


func world_time() -> float:
	return start_wt + float(tick) / World.TICK_RATE


func _process(delta: float) -> void:
	acc += delta
	var step := 1.0 / World.TICK_RATE
	var n := 0
	while acc >= step and n < 5:
		acc -= step
		n += 1
		_tick()
	if acc > step * 5:
		acc = 0.0 # server is overloaded, drop time rather than spiral


# =====================================================================
# Connections & accounts
# =====================================================================

func _on_peer_connected(peer: int) -> void:
	print("[server] peer %d connected" % peer)


func _on_peer_disconnected(peer: int) -> void:
	print("[server] peer %d disconnected" % peer)
	_logout(peer)


func on_login(peer: int, username: String, password: String, version: int) -> void:
	if sessions.has(peer):
		return
	if version != Net.PROTOCOL_VERSION:
		Net.send_msg(peer, "login_fail", {"reason": "Version mismatch: update your client."})
		return
	var re := RegEx.create_from_string("^[A-Za-z0-9_]{3,16}$")
	if re.search(username) == null:
		Net.send_msg(peer, "login_fail", {"reason": "Name must be 3-16 letters, digits or _."})
		return
	if password.length() < 4:
		Net.send_msg(peer, "login_fail", {"reason": "Password must be at least 4 characters."})
		return
	var key := username.to_lower()
	var acc_data: Dictionary
	if db.account_exists(key):
		acc_data = db.load_account(key)
		if Persistence.hash_password(password, acc_data.salt) != acc_data.hash:
			Net.send_msg(peer, "login_fail", {"reason": "Wrong password."})
			return
	else:
		acc_data = _new_account(username, password)
		db.save_account(acc_data)
		print("[server] new account: ", username)
	if online.has(key):
		var old: int = online[key]
		Net.send_msg(old, "notice", {"text": "Logged in from another location."})
		_logout(old)
		if multiplayer.multiplayer_peer:
			multiplayer.multiplayer_peer.disconnect_peer(old)

	var e := Entity.new()
	e.id = _new_id()
	e.kind = "player"
	e.peer = peer
	e.account = acc_data
	e.name = acc_data.display
	e.hull_id = acc_data.hull
	e.equipped = acc_data.equipped
	e.level = Items.level_for_xp(int(acc_data.xp))
	e.recalc()
	e.hp = minf(float(acc_data.get("hp", e.max_hp)), e.max_hp)
	e.shield = minf(float(acc_data.get("shield", e.max_shield)), e.max_shield)
	e.energy = minf(float(acc_data.get("energy", e.max_energy)), e.max_energy)
	e.facing = int(acc_data.get("facing", 0))
	e.auto_fire = acc_data.get("auto_fire", {})
	if e.hp <= 0:
		e.full_restore()
	sessions[peer] = {"ship": e, "known": {}, "cmds": 0, "cmd_tick": 0}
	online[key] = peer
	Net.send_msg(peer, "login_ok", {"id": e.id, "name": e.name, "world_time": world_time(), "tick": tick, "tick_rate": World.TICK_RATE})
	if acc_data.docked_at != "":
		_send_docked(e)
	else:
		var pos: Array = acc_data.get("pos", [0, 0])
		if not _place_ship(e, Vector2i(int(pos[0]), int(pos[1])), 8):
			acc_data.docked_at = acc_data.home
			_send_docked(e)
	_send_player(e)
	_broadcast_chat("", "%s has come online." % e.name)


func _new_account(username: String, password: String) -> Dictionary:
	var salt := Persistence.make_salt()
	return {
		"username": username.to_lower(), "display": username,
		"salt": salt, "hash": Persistence.hash_password(password, salt),
		"credits": Items.STARTER.credits, "xp": 0,
		"hull": Items.STARTER.hull, "equipped": Items.STARTER.equipped.duplicate(true),
		"cargo": Items.STARTER.cargo.duplicate(true),
		"docked_at": "earth", "home": "earth", "pos": [0, 0], "facing": 0,
		"auto_fire": {}, "created": Time.get_datetime_string_from_system(),
	}


func _logout(peer: int) -> void:
	if not sessions.has(peer):
		return
	var e: Entity = sessions[peer].ship
	_save_player(e)
	if e.in_space:
		_despawn_drones(e)
		_remove_entity(e)
	sessions.erase(peer)
	if online.get(e.account.username, -1) == peer:
		online.erase(e.account.username)
	_broadcast_chat("", "%s went offline." % e.name)


func _save_player(e: Entity) -> void:
	var a := e.account
	a.hull = e.hull_id
	a.equipped = e.equipped
	a.hp = e.hp
	a.shield = e.shield
	a.energy = e.energy
	a.facing = e.facing
	a.auto_fire = e.auto_fire
	if e.in_space:
		a.pos = [e.hex.x, e.hex.y]
	db.save_account(a)


func _new_id() -> int:
	next_id += 1
	return next_id


# =====================================================================
# Commands from clients
# =====================================================================

func on_cmd(peer: int, cmd: String, args: Dictionary) -> void:
	if not sessions.has(peer):
		return
	var s: Dictionary = sessions[peer]
	# Simple flood protection.
	if s.cmd_tick != tick / World.TICK_RATE:
		s.cmd_tick = tick / World.TICK_RATE
		s.cmds = 0
	s.cmds += 1
	if s.cmds > 40:
		return
	var e: Entity = s.ship
	match cmd:
		"move": _cmd_move(e, args)
		"stop":
			e.has_goal = false
			e.path.clear()
		"target":
			e.target_id = int(args.get("id", 0))
		"activate": _cmd_activate(e, str(args.get("port", "")), int(args.get("target", 0)))
		"use": _cmd_use(e, str(args.get("item", "")))
		"auto":
			e.auto_fire[str(args.get("port", ""))] = bool(args.get("on", false))
			_send_player(e)
		"drone_attack": _cmd_drone_attack(e, args)
		"recall":
			for did in e.drones:
				var d: Entity = entities.get(did)
				if d:
					d.attack_id = 0
					d.ordered = false
		"dock": _cmd_dock(e)
		"undock": _cmd_undock(e)
		"station":
			if e.account.docked_at != "":
				_send_docked(e)
		"buy": _cmd_buy(e, str(args.get("item", "")), int(args.get("qty", 1)))
		"sell": _cmd_sell(e, str(args.get("item", "")), int(args.get("qty", 1)))
		"equip": _cmd_equip(e, str(args.get("item", "")), str(args.get("port", "")))
		"unequip": _cmd_unequip(e, str(args.get("port", "")))
		"set_hull": _cmd_set_hull(e, str(args.get("item", "")))
		"set_home":
			if e.account.docked_at != "":
				e.account.home = e.account.docked_at
				_notice(e, "Home station set to %s." % World.get_planet(e.account.home).name)
				_send_player(e)
		"market_list": _cmd_market_list(e, str(args.get("item", "")), int(args.get("qty", 1)), int(args.get("price", 0)))
		"market_buy": _cmd_market_buy(e, int(args.get("listing", 0)))
		"market_cancel": _cmd_market_cancel(e, int(args.get("listing", 0)))
		"chat":
			var text := str(args.get("text", "")).strip_edges().left(200)
			if text.begins_with("/"):
				_chat_command(e, text)
			elif text != "":
				_broadcast_chat(e.name, text)


func _chat_command(e: Entity, text: String) -> void:
	var parts := text.split(" ", false)
	match parts[0]:
		"/who":
			var names := []
			for p in sessions:
				names.append(sessions[p].ship.name)
			_notice(e, "Online (%d): %s" % [names.size(), ", ".join(names)])
			return
		"/where":
			_notice(e, "You are at %s in %s." % [e.hex, World.zone_name(e.hex)])
			return
	if not dev_mode:
		_notice(e, "Unknown command. Try /who or /where.", "error")
		return
	match parts[0]:
		"/tp":
			if parts.size() == 2 and not World.get_planet(parts[1]).is_empty():
				if e.in_space:
					_despawn_drones(e)
					_remove_entity(e)
				e.account.docked_at = parts[1]
				_send_docked(e)
				_send_player(e)
			elif parts.size() >= 3 and e.in_space:
				occupancy.erase(e.hex)
				entities.erase(e.id)
				_despawn_drones(e)
				if not _place_ship(e, Vector2i(int(parts[1]), int(parts[2])), 10):
					_place_ship(e, e.hex, 10)
		"/give":
			if parts.size() >= 2 and Items.ITEMS.has(parts[1]):
				e.cargo_add(parts[1], int(parts[2]) if parts.size() > 2 else 1)
				_send_player(e)
		"/credits":
			e.account.credits = int(e.account.credits) + (int(parts[1]) if parts.size() > 1 else 10000)
			_send_player(e)
		"/xp":
			_give_xp(e, int(parts[1]) if parts.size() > 1 else 1000)
		_:
			_notice(e, "Dev commands: /tp q r | /tp planet, /give item [qty], /credits n, /xp n", "error")


func _notice(e: Entity, text: String, kind := "info") -> void:
	if e.peer and sessions.has(e.peer) and e.peer in multiplayer.get_peers():
		Net.send_msg(e.peer, "notice", {"text": text, "kind": kind})


func _broadcast_chat(from: String, text: String) -> void:
	var connected := multiplayer.get_peers()
	for p in sessions:
		if not p in connected:
			continue
		Net.send_msg(p, "chat", {"from": from, "text": text})


func _cmd_move(e: Entity, args: Dictionary) -> void:
	if not e.in_space:
		return
	var dest := Vector2i(int(args.get("q", 0)), int(args.get("r", 0)))
	var units: Array = args.get("units", [e.id])
	var drone_slot := 0
	var spots := Hex.spiral(dest, 3)
	for uid in units:
		uid = int(uid)
		if uid == e.id:
			_set_goal(e, dest)
		elif uid in e.drones and entities.has(uid):
			var d: Entity = entities[uid]
			# Spread drones around the destination so they don't fight over one hex.
			drone_slot += 1
			_set_goal(d, spots[mini(drone_slot, spots.size() - 1)])
			d.ordered = true
			d.attack_id = 0


func _set_goal(e: Entity, dest: Vector2i) -> void:
	e.goal = dest
	e.has_goal = dest != e.hex
	e.path.clear()
	e.wait_ticks = 0


func _cmd_drone_attack(e: Entity, args: Dictionary) -> void:
	var tid := int(args.get("target", 0))
	if not entities.has(tid):
		return
	for uid in args.get("units", e.drones):
		uid = int(uid)
		if uid in e.drones and entities.has(uid):
			var d: Entity = entities[uid]
			d.attack_id = tid
			d.ordered = false


## Resolve a system key ("front" port or "item:repair_kit") to its active definition.
func _system_active(e: Entity, key: String) -> Dictionary:
	if key.begins_with("item:"):
		return Items.get_item(key.substr(5)).get("active", {})
	if not e.equipped.has(key):
		return {}
	return Items.get_item(e.equipped[key]).get("active", {})


func _cmd_activate(e: Entity, key: String, target: int) -> void:
	if not e.in_space or key.begins_with("item:"):
		return
	if _system_active(e, key).is_empty():
		_notice(e, "That system has nothing to activate.", "error")
		return
	if e.pending.size() < MAX_PENDING:
		e.pending.append({"key": key, "target": target})


func _cmd_use(e: Entity, item_id: String) -> void:
	if not e.in_space:
		return
	if e.cargo_count(item_id) <= 0 or Items.get_item(item_id).get("active", {}).is_empty():
		return
	if e.pending.size() < MAX_PENDING:
		e.pending.append({"key": "item:" + item_id, "target": 0})


# =====================================================================
# Stations: dock, shop, hangar, market
# =====================================================================

func _cmd_dock(e: Entity) -> void:
	if not e.in_space:
		return
	var pid := world.dock_planet_at(e.hex)
	if pid == "":
		_notice(e, "Too far from a planet to dock.", "error")
		return
	_despawn_drones(e)
	_remove_entity(e)
	e.account.docked_at = pid
	e.full_restore()
	e.channel = {}
	e.pending.clear()
	e.has_goal = false
	_notice(e, "Docked at %s. Ship repaired and resupplied." % World.get_planet(pid).name)
	_send_docked(e)
	_send_player(e)
	_save_player(e)


func _cmd_undock(e: Entity) -> void:
	if e.in_space or e.account.docked_at == "":
		return
	var p := World.get_planet(e.account.docked_at)
	var ph: Vector2i = world.planet_hexes[p.id]
	for r in range(p.radius + 1, p.radius + 8):
		var ring := Hex.ring(ph, r)
		ring.shuffle()
		for h in ring:
			if _hex_free(h):
				e.account.docked_at = ""
				e.facing = Hex.facing_towards(ph, h)
				_place_ship(e, h, 0)
				Net.send_msg(e.peer, "undocked", {})
				_send_player(e)
				return
	_notice(e, "Launch bay blocked, try again.", "error")


func _require_docked(e: Entity) -> bool:
	if e.in_space or e.account.docked_at == "":
		_notice(e, "You must be docked at a station.", "error")
		return false
	return true


func _cmd_buy(e: Entity, item_id: String, qty: int) -> void:
	if not _require_docked(e):
		return
	qty = clampi(qty, 1, 100)
	if not item_id in Items.SHOPS.get(e.account.docked_at, []):
		_notice(e, "This station doesn't sell that.", "error")
		return
	var it := Items.get_item(item_id)
	var cost := int(it.price) * qty
	if int(e.account.credits) < cost:
		_notice(e, "Not enough credits.", "error")
		return
	if e.cargo_room_for(item_id) < qty:
		_notice(e, "Not enough cargo space.", "error")
		return
	e.account.credits = int(e.account.credits) - cost
	e.cargo_add(item_id, qty)
	_notice(e, "Bought %d x %s for %d cr." % [qty, it.name, cost])
	_send_player(e)


func _cmd_sell(e: Entity, item_id: String, qty: int) -> void:
	if not _require_docked(e):
		return
	qty = clampi(qty, 1, 1000)
	if not e.cargo_remove(item_id, qty):
		_notice(e, "You don't have that many.", "error")
		return
	var gain := Items.sell_price(item_id) * qty
	e.account.credits = int(e.account.credits) + gain
	_notice(e, "Sold %d x %s for %d cr." % [qty, Items.item_name(item_id), gain])
	_send_player(e)


func _cmd_equip(e: Entity, item_id: String, port_id: String) -> void:
	if not _require_docked(e):
		return
	var port := e.port_def(port_id)
	if port.is_empty() or not Items.fits(item_id, port):
		_notice(e, "That item doesn't fit that port.", "error")
		return
	if int(Items.get_item(item_id).get("level", 1)) > e.level:
		_notice(e, "Requires level %d." % Items.get_item(item_id).level, "error")
		return
	if not e.cargo_remove(item_id, 1):
		_notice(e, "You don't have that item.", "error")
		return
	if e.equipped.has(port_id):
		e.cargo_add(e.equipped[port_id], 1) # always room: we just freed a unit
	e.equipped[port_id] = item_id
	e.recalc()
	_send_player(e)


func _cmd_unequip(e: Entity, port_id: String) -> void:
	if not _require_docked(e) or not e.equipped.has(port_id):
		return
	if e.cargo_room_for(e.equipped[port_id]) < 1:
		_notice(e, "Cargo full.", "error")
		return
	e.cargo_add(e.equipped[port_id], 1)
	e.equipped.erase(port_id)
	e.recalc()
	_send_player(e)


func _cmd_set_hull(e: Entity, item_id: String) -> void:
	if not _require_docked(e):
		return
	var it := Items.get_item(item_id)
	if it.get("type", "") != "hull" or e.cargo_count(item_id) < 1:
		return
	if int(it.get("level", 1)) > e.level:
		_notice(e, "Requires level %d." % it.level, "error")
		return
	# Everything equipped goes back to cargo, the old hull too.
	var returning := e.equipped.size() + 1
	if e.cargo().size() - 1 + returning > int(it.cargo):
		_notice(e, "Not enough cargo space to unload your current fittings.", "error")
		return
	e.cargo_remove(item_id, 1)
	var old_hull := e.hull_id
	var old_items: Array = e.equipped.values()
	e.equipped = {}
	e.hull_id = item_id
	e.cargo_add(old_hull, 1)
	for i in old_items:
		e.cargo_add(i, 1)
	e.recalc()
	e.full_restore()
	_notice(e, "Now flying a %s." % it.name)
	_send_player(e)


func _station_data(planet_id: String) -> Dictionary:
	var listings := []
	for l in market.listings:
		if l.station == planet_id:
			listings.append(l)
	return {"planet": planet_id, "shop": Items.SHOPS.get(planet_id, []), "market": listings}


func _send_docked(e: Entity) -> void:
	Net.send_msg(e.peer, "docked", _station_data(e.account.docked_at))


func _refresh_station_viewers(planet_id: String) -> void:
	for p in sessions:
		var s: Entity = sessions[p].ship
		if not s.in_space and s.account.docked_at == planet_id:
			_send_docked(s)


func _cmd_market_list(e: Entity, item_id: String, qty: int, price: int) -> void:
	if not _require_docked(e):
		return
	if qty < 1 or price < 1 or price > 100000000:
		_notice(e, "Invalid quantity or price.", "error")
		return
	if not e.cargo_remove(item_id, qty):
		_notice(e, "You don't have that many.", "error")
		return
	market.next_id = int(market.next_id) + 1
	market.listings.append({"id": int(market.next_id), "station": e.account.docked_at, "seller": e.account.username,
		"seller_name": e.name, "item": item_id, "qty": qty, "price": price})
	db.save_market(market)
	_notice(e, "Listed %d x %s for %d cr each." % [qty, Items.item_name(item_id), price])
	_send_player(e)
	_refresh_station_viewers(e.account.docked_at)


func _find_listing(listing_id: int) -> int:
	for i in market.listings.size():
		if int(market.listings[i].id) == listing_id:
			return i
	return -1


func _cmd_market_buy(e: Entity, listing_id: int) -> void:
	if not _require_docked(e):
		return
	var idx := _find_listing(listing_id)
	if idx < 0:
		_notice(e, "Listing no longer available.", "error")
		return
	var l: Dictionary = market.listings[idx]
	if l.station != e.account.docked_at:
		_notice(e, "That listing is at another station.", "error")
		return
	if l.seller == e.account.username:
		_notice(e, "Use cancel to take back your own listing.", "error")
		return
	var total := int(l.price) * int(l.qty)
	if int(e.account.credits) < total:
		_notice(e, "Not enough credits.", "error")
		return
	if e.cargo_room_for(l.item) < int(l.qty):
		_notice(e, "Not enough cargo space.", "error")
		return
	e.account.credits = int(e.account.credits) - total
	e.cargo_add(l.item, int(l.qty))
	market.listings.remove_at(idx)
	_pay_account(l.seller, total, "%s bought your %d x %s for %d cr." % [e.name, int(l.qty), Items.item_name(l.item), total])
	db.save_market(market)
	_notice(e, "Purchased %d x %s." % [int(l.qty), Items.item_name(l.item)])
	_send_player(e)
	_refresh_station_viewers(e.account.docked_at)


func _pay_account(username: String, amount: int, msg: String) -> void:
	if online.has(username):
		var s: Entity = sessions[online[username]].ship
		s.account.credits = int(s.account.credits) + amount
		_notice(s, msg)
		_send_player(s)
	else:
		var a := db.load_account(username)
		if not a.is_empty():
			a.credits = int(a.credits) + amount
			db.save_account(a)


func _cmd_market_cancel(e: Entity, listing_id: int) -> void:
	if not _require_docked(e):
		return
	var idx := _find_listing(listing_id)
	if idx < 0:
		return
	var l: Dictionary = market.listings[idx]
	if l.seller != e.account.username:
		return
	if l.station != e.account.docked_at:
		_notice(e, "Go to %s to collect that listing." % World.get_planet(l.station).name, "error")
		return
	if e.cargo_room_for(l.item) < int(l.qty):
		_notice(e, "Not enough cargo space.", "error")
		return
	e.cargo_add(l.item, int(l.qty))
	market.listings.remove_at(idx)
	db.save_market(market)
	_send_player(e)
	_refresh_station_viewers(e.account.docked_at)


func _send_player(e: Entity) -> void:
	if not e.peer:
		return
	var a := e.account
	Net.send_msg(e.peer, "player", {
		"id": e.id, "name": e.name, "credits": int(a.credits), "xp": int(a.xp), "level": e.level,
		"hull": e.hull_id, "equipped": e.equipped, "cargo": a.cargo, "docked_at": a.docked_at,
		"home": a.home, "auto_fire": e.auto_fire,
		"stats": {"max_hp": e.max_hp, "max_shield": e.max_shield, "max_energy": e.max_energy,
			"move_ticks": e.move_ticks, "shield_regen": e.shield_regen * World.TICK_RATE,
			"energy_regen": e.energy_regen * World.TICK_RATE, "cargo_cap": e.cargo_capacity()},
	})


# =====================================================================
# Grid helpers
# =====================================================================

func _hex_free(h: Vector2i) -> bool:
	return not occupancy.has(h) and not world.is_blocked(h)


## Put an entity into space at (or near) a hex. Returns false if no room.
func _place_ship(e: Entity, h: Vector2i, search: int) -> bool:
	for c in Hex.spiral(h, search):
		if _hex_free(c):
			e.hex = c
			e.in_space = true
			e.move_cd = 0
			e.has_goal = false
			e.path.clear()
			entities[e.id] = e
			occupancy[c] = e.id
			return true
	return false


func _remove_entity(e: Entity) -> void:
	if occupancy.get(e.hex, -1) == e.id:
		occupancy.erase(e.hex)
	entities.erase(e.id)
	e.in_space = false
	e.channel = {}


func _rebuild_buckets() -> void:
	buckets.clear()
	for e in entities.values():
		var b := Vector2i(floori(e.hex.x / float(BUCKET)), floori(e.hex.y / float(BUCKET)))
		if not buckets.has(b):
			buckets[b] = []
		buckets[b].append(e)


func _query(center: Vector2i, radius: int) -> Array:
	var out := []
	var b0 := Vector2i(floori((center.x - radius) / float(BUCKET)), floori((center.y - radius) / float(BUCKET)))
	var b1 := Vector2i(floori((center.x + radius) / float(BUCKET)), floori((center.y + radius) / float(BUCKET)))
	for bx in range(b0.x, b1.x + 1):
		for by in range(b0.y, b1.y + 1):
			for e in buckets.get(Vector2i(bx, by), []):
				if Hex.distance(e.hex, center) <= radius:
					out.append(e)
	return out


func _blocked_for(e: Entity, h: Vector2i, avoid_units: bool) -> bool:
	if world.is_blocked(h):
		return true
	if avoid_units and occupancy.has(h) and Hex.distance(h, e.hex) <= 4:
		return true
	# Mercenaries stay out of safe zones (unless already inside one).
	if e.kind == "merc" and world.is_safe(h) and not world.is_safe(e.hex):
		return true
	return false


# =====================================================================
# Simulation tick
# =====================================================================

var _tick_usec_total := 0


func _tick() -> void:
	var t0 := Time.get_ticks_usec()
	_tick_inner()
	_tick_usec_total += Time.get_ticks_usec() - t0
	if tick % (60 * World.TICK_RATE) == 0:
		print("[server] players %d, units in space %d, loot %d, avg tick %.2f ms (budget %.0f ms)" % [
			sessions.size(), entities.size(), loot.size(), _tick_usec_total / 1000.0 / (60 * World.TICK_RATE), 1000.0 / World.TICK_RATE])
		_tick_usec_total = 0


func _tick_inner() -> void:
	tick += 1
	fx.clear()
	world.update(world_time())
	_push_out_of_planets()
	_process_activations()
	_process_channels_and_scheduled()
	_process_movement()
	_process_regen()
	_process_loot()
	_rebuild_buckets()
	_process_ai()
	if tick % (5 * World.TICK_RATE) == 0:
		_respawn_mercs()
	if tick % SAVE_INTERVAL_TICKS == 0:
		for p in sessions:
			_save_player(sessions[p].ship)
	_send_snapshots()


func _push_out_of_planets() -> void:
	for p in World.PLANETS:
		var ph: Vector2i = world.planet_hexes[p.id]
		for h in Hex.spiral(ph, p.radius):
			if occupancy.has(h):
				var e: Entity = entities[occupancy[h]]
				occupancy.erase(h)
				for c in Hex.spiral(h, p.radius + 4):
					if _hex_free(c):
						e.hex = c
						occupancy[c] = e.id
						e.path.clear()
						break


# ---------- systems / activations ----------

func _process_activations() -> void:
	for e in entities.values():
		if e.pending.is_empty():
			continue
		var reqs: Array = e.pending
		e.pending = []
		for req in reqs:
			if e.in_space:
				_start_activation(e, req, e.kind == "player")


func _start_activation(e: Entity, req: Dictionary, report: bool) -> void:
	var key: String = req.key
	var act := _system_active(e, key)
	if act.is_empty():
		return
	if not e.channel.is_empty():
		if report: _notice(e, "Busy channeling.", "error")
		return
	if int(e.cooldowns.get(key, 0)) > 0:
		if report: _notice(e, "System on cooldown.", "error")
		return
	var is_item := key.begins_with("item:")
	var cost: float = act.get("energy", 0)
	if not is_item and e.energy < cost:
		if report: _notice(e, "Not enough energy.", "error")
		return
	if is_item and e.cargo_count(key.substr(5)) <= 0:
		return
	var err := _validate_effect(e, key, act, req)
	if err != "":
		if report: _notice(e, err, "error")
		return
	# Committed: pay costs and start.
	if not is_item:
		e.energy -= cost
	else:
		e.cargo_remove(key.substr(5), 1)
		_send_player(e)
	e.cooldowns[key] = int(act.get("cooldown", 6))
	var ch := int(act.get("channel", 0))
	var dl := int(act.get("delay", 0))
	if ch > 0:
		e.channel = {"key": key, "fire_tick": tick + ch, "req": req, "total": ch}
		fx.append({"k": "channel", "id": e.id, "p": e.hex, "t": ch})
	elif dl > 0:
		scheduled.append({"tick": tick + dl, "type": "effect", "src": e.id, "key": key, "req": req})
	else:
		_apply_effect(e, key, act, req)


## Returns "" if the effect could be applied right now, otherwise a reason.
func _validate_effect(e: Entity, key: String, act: Dictionary, req: Dictionary) -> String:
	match act.get("effect", ""):
		"damage":
			var t: Entity = entities.get(int(req.get("target", 0)))
			if t == null or t.dead:
				return "No valid target."
			if t.root_id() == e.root_id():
				return "Can't attack your own units."
			if not _combat_allowed(e, t):
				return "Combat is not allowed in a safe zone."
			if Hex.distance(e.hex, t.hex) > int(act.range):
				return "Target out of range."
			var port := e.port_def(key)
			if not Hex.in_arc(e.hex, e.facing, port.get("dir", 0.0), port.get("arc", 360.0), t.hex):
				return "Target outside this port's firing arc."
		"spawn_drone":
			if e.drones.size() >= int(act.get("max_drones", 1)) * _count_equipped_effect(e, "spawn_drone"):
				return "Maximum drones already deployed."
		"heal":
			if e.hp >= e.max_hp:
				return "Hull already at full strength."
	return ""


func _count_equipped_effect(e: Entity, effect: String) -> int:
	var n := 0
	for p in e.equipped:
		if Items.get_item(e.equipped[p]).get("active", {}).get("effect", "") == effect:
			n += 1
	return maxi(n, 1)


func _combat_allowed(a: Entity, b: Entity) -> bool:
	if a.kind == "merc" and b.kind == "merc":
		return false
	return not world.is_safe(a.hex) and not world.is_safe(b.hex)


func _apply_effect(e: Entity, key: String, act: Dictionary, req: Dictionary) -> void:
	match act.get("effect", ""):
		"damage":
			var t: Entity = entities.get(int(req.get("target", 0)))
			if t == null:
				return
			var dmg: float = act.damage * e.damage_mult
			var speed: float = act.get("projectile_speed", 0.0)
			if speed > 0.0:
				var travel := maxi(1, ceili(Hex.distance(e.hex, t.hex) / speed))
				fx.append({"k": "missile", "a": e.id, "b": t.id, "p": e.hex, "t": travel, "c": act.get("color", Color.WHITE)})
				scheduled.append({"tick": tick + travel, "type": "hit", "src": e.id, "root": e.root_id(), "tgt": t.id, "dmg": dmg})
			else:
				fx.append({"k": act.get("fx", "beam"), "a": e.id, "b": t.id, "p": e.hex, "c": act.get("color", Color.WHITE)})
				_damage(t, dmg, e)
		"restore_shield":
			e.shield = minf(e.max_shield, e.shield + float(act.amount))
			fx.append({"k": "buff", "id": e.id, "p": e.hex, "c": Color(0.4, 0.7, 1)})
		"restore_energy":
			e.energy = minf(e.max_energy, e.energy + float(act.amount))
			fx.append({"k": "buff", "id": e.id, "p": e.hex, "c": Color(1, 1, 0.4)})
		"heal":
			e.hp = minf(e.max_hp, e.hp + float(act.amount))
			fx.append({"k": "buff", "id": e.id, "p": e.hex, "c": Color(0.4, 1, 0.4)})
		"spawn_drone":
			_spawn_drone(e, act)


func _process_channels_and_scheduled() -> void:
	for e in entities.values():
		if e.in_space and not e.channel.is_empty() and tick >= int(e.channel.fire_tick):
			var ch: Dictionary = e.channel
			e.channel = {}
			var act := _system_active(e, ch.key)
			if act.is_empty():
				continue
			var err := _validate_effect(e, ch.key, act, ch.req)
			if err == "":
				_apply_effect(e, ch.key, act, ch.req)
			elif e.kind == "player":
				_notice(e, "Channel fizzled: " + err, "error")
	var keep: Array = []
	for s in scheduled:
		if tick < int(s.tick):
			keep.append(s)
			continue
		match s.type:
			"hit":
				var t: Entity = entities.get(s.tgt)
				if t and not t.dead:
					var src: Entity = entities.get(s.src)
					_damage(t, s.dmg, src, int(s.root))
			"effect":
				var src: Entity = entities.get(s.src)
				if src:
					_apply_effect(src, s.key, _system_active(src, s.key), s.req)
	scheduled = keep


func _damage(t: Entity, amount: float, src: Entity, root := 0) -> void:
	if t.dead or not t.in_space:
		return
	if root == 0 and src:
		root = src.root_id()
	var absorbed := minf(t.shield, amount)
	t.shield -= absorbed
	var hull_dmg := amount - absorbed
	t.hp -= hull_dmg
	t.last_damage_tick = tick
	t.damage_by[root] = t.damage_by.get(root, 0.0) + amount
	fx.append({"k": "dmg", "id": t.id, "p": t.hex, "v": int(round(amount)), "s": absorbed > hull_dmg})
	# Retaliation.
	if t.kind == "merc" and root != 0 and entities.has(root):
		if t.target_id == 0:
			t.target_id = root
			t.ai_state = "chase"
			t.home = t.hex
	if t.hp <= 0:
		_kill(t, root)


func _kill(t: Entity, killer_root: int) -> void:
	t.dead = true
	fx.append({"k": "boom", "id": t.id, "p": t.hex, "big": t.kind != "drone"})
	match t.kind:
		"merc":
			_merc_killed(t, killer_root)
			_remove_entity(t)
			zone_counts[t.zone] = zone_counts.get(t.zone, 1) - 1
		"drone":
			var o: Entity = _find_ship(t.owner_id)
			if o:
				o.drones.erase(t.id)
			_remove_entity(t)
		"player":
			_player_killed(t, killer_root)


func _find_ship(id: int) -> Entity:
	if entities.has(id):
		return entities[id]
	for p in sessions:
		if sessions[p].ship.id == id:
			return sessions[p].ship
	return null


func _merc_killed(t: Entity, killer_root: int) -> void:
	var total := 0.0
	for k in t.damage_by:
		total += t.damage_by[k]
	var top := 0
	var top_dmg := 0.0
	for k in t.damage_by:
		var p: Entity = entities.get(k)
		if p == null or p.kind != "player":
			continue
		var share: float = t.damage_by[k] / maxf(total, 1.0)
		_give_xp(p, int(ceil(t.tier * 25 * share)))
		if t.damage_by[k] > top_dmg:
			top_dmg = t.damage_by[k]
			top = k
	var items := []
	for row in Items.LOOT_TABLE:
		if rng.randf() < row[1] * (1.0 + 0.15 * (t.tier - 1)):
			var q := rng.randi_range(1, 2 + t.tier / 3) if Items.stack_size(row[0]) > 1 else 1
			items.append({"id": row[0], "qty": q})
	var credits := rng.randi_range(15, 35) * t.tier * t.tier
	_spawn_loot(t.hex, credits, items, top if top else killer_root)


func _player_killed(t: Entity, killer_root: int) -> void:
	var killer: Entity = entities.get(killer_root)
	var kname := killer.name if killer else "unknown"
	# Drop all cargo and 10% credits.
	var lost := int(int(t.account.credits) * 0.1)
	t.account.credits = int(t.account.credits) - lost
	var items: Array = t.account.cargo.duplicate(true)
	t.account.cargo = []
	_spawn_loot(t.hex, lost, items, killer_root)
	_despawn_drones(t)
	_remove_entity(t)
	t.dead = false
	t.damage_by.clear()
	t.target_id = 0
	t.pending.clear()
	t.cooldowns.clear()
	t.full_restore()
	t.account.docked_at = t.account.home
	_notice(t, "Your ship was destroyed by %s! You lost your cargo and %d cr." % [kname, lost], "error")
	Net.send_msg(t.peer, "died", {"by": kname})
	_broadcast_chat("", "%s was destroyed by %s." % [t.name, kname])
	_send_docked(t)
	_send_player(t)
	_save_player(t)


func _give_xp(p: Entity, amount: int) -> void:
	p.account.xp = int(p.account.xp) + amount
	var lvl := Items.level_for_xp(int(p.account.xp))
	if lvl > p.level:
		p.level = lvl
		_notice(p, "Level up! You are now level %d." % lvl, "good")
	_send_player(p)


func _spawn_loot(h: Vector2i, credits: int, items: Array, owner_root: int) -> void:
	if credits <= 0 and items.is_empty():
		return
	var id := _new_id()
	loot[id] = {"id": id, "hex": h, "credits": credits, "items": items, "owner": owner_root,
		"lock": tick + LOOT_LOCK, "expire": tick + LOOT_LIFETIME}


func _process_loot() -> void:
	if tick % 3 != 0:
		return
	for id in loot.keys():
		var l: Dictionary = loot[id]
		if tick > int(l.expire):
			loot.erase(id)
			continue
		for h in Hex.spiral(l.hex, 1):
			if not occupancy.has(h):
				continue
			var p: Entity = entities[occupancy[h]]
			if p.kind != "player":
				continue
			if tick < int(l.lock) and l.owner != p.id:
				continue
			var got := []
			if l.credits > 0:
				p.account.credits = int(p.account.credits) + int(l.credits)
				got.append("%d cr" % l.credits)
				l.credits = 0
			var rest := []
			for it in l.items:
				var added := p.cargo_add(it.id, int(it.qty))
				if added > 0:
					got.append("%d x %s" % [added, Items.item_name(it.id)])
				if added < int(it.qty):
					rest.append({"id": it.id, "qty": int(it.qty) - added})
			l.items = rest
			if not got.is_empty():
				_notice(p, "Looted: " + ", ".join(got), "good")
				_send_player(p)
			elif not rest.is_empty():
				pass # cargo full, leave the crate
			if rest.is_empty():
				loot.erase(id)
			break


# ---------- movement ----------

func _process_movement() -> void:
	var intents := {} # dest -> Array[Entity]
	for e in entities.values():
		if e.move_cd > 0:
			e.move_cd -= 1
		if not e.has_goal:
			continue
		if e.hex == e.goal:
			e.has_goal = false
			continue
		if e.move_cd > 0:
			continue
		var nxt = _next_step(e)
		if nxt == null:
			e.has_goal = false # nothing closer reachable
			continue
		if occupancy.has(nxt):
			e.wait_ticks += 1
			if e.wait_ticks >= 3:
				e.path.clear()
			if e.wait_ticks > 30:
				e.has_goal = false
			continue
		if not intents.has(nxt):
			intents[nxt] = []
		intents[nxt].append(e)
	for dest in intents:
		var movers: Array = intents[dest]
		if movers.size() > 1:
			# Two ships tried to enter the same hex on the same tick: both moves are cancelled.
			for e in movers:
				e.move_cd = rng.randi_range(2, 6)
				e.path.clear()
				fx.append({"k": "bump", "id": e.id, "p": e.hex})
			continue
		var m: Entity = movers[0]
		occupancy.erase(m.hex)
		m.facing = Hex.direction_to(m.hex, dest) # front points away from the hex we left
		m.hex = dest
		occupancy[dest] = m.id
		m.move_cd = m.move_ticks
		m.wait_ticks = 0
		if not m.path.is_empty() and m.path[0] == dest:
			m.path.pop_front()
		if m.hex == m.goal:
			m.has_goal = false
		# Moving interrupts channeled systems.
		if not m.channel.is_empty():
			m.channel = {}
			if m.kind == "player":
				_notice(m, "Channel interrupted by movement.", "error")


func _next_step(e: Entity):
	if not e.path.is_empty():
		var n: Vector2i = e.path[0]
		if Hex.distance(n, e.hex) == 1 and not _blocked_for(e, n, false):
			return n
	var avoid := e.wait_ticks >= 3
	e.path = Pathfinder.find_path(e.hex, e.goal, func(h): return _blocked_for(e, h, avoid))
	if e.path.is_empty():
		return null
	return e.path[0]


# ---------- regen ----------

func _process_regen() -> void:
	for e in entities.values():
		for k in e.cooldowns.keys():
			e.cooldowns[k] -= 1
			if e.cooldowns[k] <= 0:
				e.cooldowns.erase(k)
		e.energy = minf(e.max_energy, e.energy + e.energy_regen)
		if tick - e.last_damage_tick > 4 * World.TICK_RATE:
			e.shield = minf(e.max_shield, e.shield + e.shield_regen)
		if e.kind == "merc" and e.ai_state == "wander" and tick - e.last_damage_tick > 15 * World.TICK_RATE:
			e.hp = minf(e.max_hp, e.hp + e.max_hp * 0.01)
			e.damage_by.clear()


# =====================================================================
# AI: mercenaries, drones, player auto-fire
# =====================================================================

func _process_ai() -> void:
	for e in entities.values():
		if e.dead or not e.in_space:
			continue
		match e.kind:
			"merc":
				if (tick + e.think_offset) % 3 == 0:
					_merc_think(e)
			"drone":
				_drone_think(e)
			"player":
				_player_auto_fire(e)


func _player_auto_fire(e: Entity) -> void:
	if e.target_id == 0 or not e.pending.is_empty() or not e.channel.is_empty():
		return
	var t: Entity = entities.get(e.target_id)
	if t == null:
		return
	for port_id in e.auto_fire:
		if not e.auto_fire[port_id] or not e.equipped.has(port_id):
			continue
		var act := _system_active(e, port_id)
		if act.get("effect", "") != "damage" or e.cooldowns.has(port_id):
			continue
		if e.energy >= act.get("energy", 0) and act.get("channel", 0) == 0 \
				and _validate_effect(e, port_id, act, {"target": t.id}) == "":
			e.pending.append({"key": port_id, "target": t.id})


func _merc_think(e: Entity) -> void:
	var t: Entity = entities.get(e.target_id)
	if t and (t.dead or not t.in_space or world.is_safe(t.hex) or Hex.distance(e.hex, e.home) > e.leash
			or Hex.distance(e.hex, t.hex) > e.aggro_range * 3):
		t = null
	if t == null:
		e.target_id = 0
		if e.ai_state == "chase":
			e.ai_state = "wander"
			e.has_goal = false
		# Look for prey.
		var best_d := e.aggro_range + 1
		for o in _query(e.hex, e.aggro_range):
			if (o.kind == "player" or o.kind == "drone") and not world.is_safe(o.hex):
				var d := Hex.distance(e.hex, o.hex)
				if d < best_d:
					best_d = d
					t = o
		if t:
			e.target_id = t.id
			e.ai_state = "chase"
			e.home = e.hex
	if t == null:
		_merc_wander(e)
		return
	_engage(e, t)


## Fire everything that can hit, and maneuver so weapons bear on the target.
func _engage(e: Entity, t: Entity) -> void:
	var d := Hex.distance(e.hex, t.hex)
	var any_in_arc := false
	var max_range := 1
	for p in e.ports():
		if p.kind != "weapon" or not e.equipped.has(p.id):
			continue
		var act := _system_active(e, p.id)
		max_range = maxi(max_range, int(act.get("range", 1)))
		if Hex.in_arc(e.hex, e.facing, p.get("dir", 0.0), p.get("arc", 360.0), t.hex) and d <= int(act.range):
			any_in_arc = true
			if not e.cooldowns.has(p.id) and e.channel.is_empty() and e.energy >= act.get("energy", 0) \
					and e.pending.size() < 2:
				e.pending.append({"key": p.id, "target": t.id})
	if any_in_arc and d >= 2:
		e.has_goal = false
		return
	if e.move_cd > 2:
		return
	# Choose a neighbour hex from which our front port would face the target.
	var best = null
	var best_score := 99999
	for dir in 6:
		var n := e.hex + Hex.DIRS[dir]
		if not _hex_free(n) or _blocked_for(e, n, false):
			continue
		var nd := Hex.distance(n, t.hex)
		var score := absi(nd - maxi(2, max_range - 2)) * 2
		for p in e.ports():
			if p.kind == "weapon" and e.equipped.has(p.id) and Hex.in_arc(n, dir, p.get("dir", 0.0), p.get("arc", 360.0), t.hex):
				score -= 5
				break
		if score < best_score:
			best_score = score
			best = n
	if d > max_range or best == null:
		_set_goal(e, t.hex)
	else:
		e.goal = best
		e.has_goal = true
		e.path = [best]


func _merc_wander(e: Entity) -> void:
	if e.has_goal:
		return
	if rng.randf() < 0.3:
		return # idle a moment
	var z: Dictionary = World.ZONES[e.zone]
	var ang := Hex.to_pixel(e.hex).angle() + rng.randf_range(-0.12, 0.12) * (300.0 / maxf(Hex.radius_f(e.hex), 30.0))
	for _try in 6:
		var rad := rng.randf_range(z.min + 2, z.max - 2)
		var h := Hex.from_pixel(Vector2(cos(ang), sin(ang)) * rad * Hex.STEP)
		if not world.is_blocked(h) and not world.is_safe(h):
			_set_goal(e, h)
			return


func _drone_think(e: Entity) -> void:
	var o: Entity = entities.get(e.owner_id)
	if o == null:
		_kill(e, 0)
		return
	if (tick + e.think_offset) % 2 != 0:
		return
	var t: Entity = entities.get(e.attack_id)
	if t and (t.dead or Hex.distance(t.hex, o.hex) > 30):
		t = null
		e.attack_id = 0
	if t == null and not e.ordered:
		# Defend: attack mercs near us, or whoever is shooting our owner.
		var best_d := 7
		for c in _query(e.hex, 6):
			if c.kind == "merc" and Hex.distance(c.hex, e.hex) < best_d:
				best_d = Hex.distance(c.hex, e.hex)
				t = c
		if t == null:
			for rid in o.damage_by:
				if entities.has(rid) and rid != o.id and tick - o.last_damage_tick < 10 * World.TICK_RATE:
					t = entities[rid]
					break
	if t and not _combat_allowed(e, t):
		t = null
	if t:
		var d := Hex.distance(e.hex, t.hex)
		var dd: Dictionary = e.drone_def
		if d <= int(dd.range):
			e.has_goal = false
			if not e.cooldowns.has("gun"):
				e.cooldowns["gun"] = int(dd.cooldown)
				fx.append({"k": "beam", "a": e.id, "b": t.id, "p": e.hex, "c": dd.get("color", Color.GREEN)})
				_damage(t, float(dd.damage), e)
		elif not e.has_goal or Hex.distance(e.goal, t.hex) > 2:
			_set_goal(e, t.hex)
		return
	if e.ordered:
		if not e.has_goal:
			e.ordered = Hex.distance(e.hex, o.hex) < 20 # hold position near owner
		return
	if Hex.distance(e.hex, o.hex) > 2 and (not e.has_goal or Hex.distance(e.goal, o.hex) > 2):
		_set_goal(e, o.hex)


func _spawn_drone(owner: Entity, act: Dictionary) -> void:
	var dd: Dictionary = act.drone
	for h in Hex.spiral(owner.hex, 2):
		if _hex_free(h):
			var d := Entity.new()
			d.id = _new_id()
			d.kind = "drone"
			d.name = dd.name
			d.owner_id = owner.id
			d.drone_def = dd
			d.hull_id = ""
			d.max_hp = dd.hp
			d.hp = dd.hp
			d.move_ticks = int(dd.move_ticks)
			d.think_offset = d.id % 2
			d.facing = owner.facing
			_place_ship(d, h, 0)
			owner.drones.append(d.id)
			return


func _despawn_drones(e: Entity) -> void:
	for did in e.drones:
		var d: Entity = entities.get(did)
		if d:
			_remove_entity(d)
	e.drones.clear()


func _spawn_merc(zone_i: int) -> void:
	var z: Dictionary = World.ZONES[zone_i]
	for _try in 20:
		var ang := rng.randf() * TAU
		var rad := rng.randf_range(z.min + 1, z.max - 1)
		var h := Hex.from_pixel(Vector2(cos(ang), sin(ang)) * rad * Hex.STEP)
		if not _hex_free(h) or world.is_safe(h):
			continue
		var tier: int = clampi(z.tier + rng.randi_range(-1, 1) * int(rng.randf() < 0.3), 1, 10)
		var tpl := Items.merc_template_for_tier(tier, rng)
		var e := Entity.new()
		e.id = _new_id()
		e.kind = "merc"
		e.tier = tier
		e.zone = zone_i
		e.name = "%s T%d" % [tpl.name, tier]
		e.hull_id = tpl.hull
		e.equipped = tpl.equipped.duplicate()
		e.think_offset = rng.randi() % 3
		e.aggro_range = 6 + mini(tier, 4)
		e.recalc()
		e.full_restore()
		e.facing = rng.randi() % 6
		e.home = h
		_place_ship(e, h, 0)
		zone_counts[zone_i] = zone_counts.get(zone_i, 0) + 1
		return


func _respawn_mercs() -> void:
	for i in World.ZONES.size():
		if zone_counts.get(i, 0) < World.ZONES[i].pop:
			_spawn_merc(i)


# =====================================================================
# Snapshots
# =====================================================================

func _send_snapshots() -> void:
	var wt := world_time()
	var connected := {}
	for p in multiplayer.get_peers():
		connected[p] = true
	for peer in sessions:
		if not connected.has(peer):
			continue
		var s: Dictionary = sessions[peer]
		var me: Entity = s.ship
		var center: Vector2i = me.hex if me.in_space else world.planet_hexes.get(me.account.docked_at, Vector2i.ZERO)
		var vis := _query(center, VIEW_RADIUS)
		var states := PackedInt32Array()
		var infos := []
		var known: Dictionary = s.known
		var seen := {}
		for e in vis:
			seen[e.id] = true
			if not known.has(e.id):
				known[e.id] = true
				infos.append({"id": e.id, "kind": e.kind, "name": e.name, "hull": e.hull_id,
					"owner": e.owner_id, "tier": e.tier, "level": e.level})
			# Packed: id, q, r, facing | channeling<<4, hp, max_hp, shield, max_shield, move_ticks
			states.append_array([e.id, e.hex.x, e.hex.y, e.facing | ((0 if e.channel.is_empty() else 1) << 4),
				ceili(e.hp), int(e.max_hp), ceili(e.shield), int(e.max_shield), e.move_ticks])
		# Forget entities that left view so their info is re-sent if they return.
		for id in known.keys():
			if not seen.has(id):
				known.erase(id)
		if not infos.is_empty():
			Net.send_msg(peer, "ent_info", {"list": infos})
		var lts := []
		for l in loot.values():
			if Hex.distance(l.hex, center) <= VIEW_RADIUS:
				lts.append([l.id, l.hex])
		var my_fx := []
		for f in fx:
			if Hex.distance(f.p, center) <= VIEW_RADIUS + 5:
				my_fx.append(f)
		var meinfo := {"en": e_round(me.energy), "men": me.max_energy, "cd": me.cooldowns,
			"tgt": me.target_id, "space": me.in_space, "goal": me.goal if me.has_goal else null,
			"drones": me.drones, "mcd": me.move_cd}
		if not me.channel.is_empty():
			meinfo["ch"] = {"key": me.channel.key, "left": int(me.channel.fire_tick) - tick, "total": me.channel.total}
		if not me.in_space:
			meinfo["hp"] = me.hp
			meinfo["sh"] = me.shield
		Net.send_state(peer, {"t": tick, "wt": wt, "l": lts, "fx": my_fx, "me": meinfo})
		# Entity states go in chunks that each fit in one UDP packet.
		var chunk := ENT_STRIDE * ENTS_PER_PACKET
		for i in range(0, states.size(), chunk):
			Net.send_state(peer, {"t": tick, "e": states.slice(i, i + chunk)})


func e_round(v: float) -> float:
	return snappedf(v, 0.1)
