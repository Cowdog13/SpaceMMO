## Headless test bot: logs in, undocks, hunts mercenaries and prints what happens.
## godot --headless --path . -- --bot NAME [--host 127.0.0.1] [--port 7777] [--seconds 60]
extends Node

const Hex = preload("res://scripts/shared/hex.gd")

var host := "127.0.0.1"
var port := Net.DEFAULT_PORT
var bot_name := "Bot"
var seconds := 60.0
var my_id := 0
var me := {}
var player := {}
var ents := {} # id -> {hex, hp, ...}
var infos := {}
var elapsed := 0.0
var think := 0.0
var stats := {"states": 0, "fx": 0, "notices": 0, "dmg": 0}
var last_hex := Vector2i(999999, 0)
var moves := 0
var tp := ""
var steps: Array = [] # "--steps" scripted commands: "cmd k=v k=v;cmd2 ..."
var step_t := 0.0
var did_tp := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--bot": bot_name = args[i + 1]
			"--host": host = args[i + 1]
			"--port": port = int(args[i + 1])
			"--seconds": seconds = float(args[i + 1])
			"--tp": tp = args[i + 1]
			"--steps": steps = Array(args[i + 1].split(";"))
	Net.client_handler = self
	var peer := ENetMultiplayerPeer.new()
	peer.create_client(host, port)
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(func():
		print("[bot] connected")
		Net.c_login.rpc_id(1, bot_name, "botpass", Net.PROTOCOL_VERSION))
	multiplayer.connection_failed.connect(func(): print("[bot] connection failed"); get_tree().quit(1))


func cmd(c: String, a := {}) -> void:
	Net.c_cmd.rpc_id(1, c, a)


func on_msg(type: String, data: Dictionary) -> void:
	match type:
		"login_ok":
			my_id = data.id
			print("[bot] login ok id=%d" % my_id)
		"login_fail":
			print("[bot] login failed: ", data.reason)
			get_tree().quit(1)
		"player":
			player = data
		"docked":
			print("[bot] docked at %s, shop=%d items, market=%d" % [data.planet, data.shop.size(), data.market.size()])
		"undocked":
			print("[bot] undocked")
		"ent_info":
			for i in data.list:
				infos[i.id] = i
		"notice":
			stats.notices += 1
			print("[bot] notice: ", data.text)
		"chat":
			print("[bot] chat <%s> %s" % [data.from, data.text])
		"died":
			print("[bot] DIED, killed by ", data.by)


func on_state(d: Dictionary) -> void:
	stats.states += 1
	if d.has("e"):
		var a: PackedInt32Array = d.e
		for i in range(0, a.size(), 9):
			ents[a[i]] = {"hex": Vector2i(a[i + 1], a[i + 2]), "facing": a[i + 3] & 15, "hp": a[i + 4], "mhp": a[i + 5], "t": d.t}
		return
	me = d.me
	for id in ents.keys():
		if d.t - ents[id].t > 6:
			ents.erase(id)
	for f in d.fx:
		stats.fx += 1
		stats[f.k] = stats.get(f.k, 0) + 1
		if f.k == "dmg" and f.id == my_id:
			stats["taken"] = stats.get("taken", 0) + f.v
		if f.k == "dmg":
			stats.dmg += f.v


func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > seconds:
		print("[bot] done: ", stats, " moves=", moves, " credits=", player.get("credits"), " xp=", player.get("xp"))
		get_tree().quit(0)
		return
	if not steps.is_empty():
		step_t += delta
		if step_t > 1.0 and my_id != 0:
			step_t = 0.0
			var parts: PackedStringArray = String(steps.pop_front()).strip_edges().split(" ", false)
			var a := {}
			for kv in parts.slice(1):
				var p := kv.split("=")
				a[p[0]] = int(p[1]) if p[1].is_valid_int() else p[1].replace("_", " ") if p[0] == "text" else p[1]
			if parts[0] == "fire_target" or parts[0] == "fire_player":
				var want := "merc" if parts[0] == "fire_target" else "player"
				var best := 0
				for id in ents:
					if infos.has(id) and infos[id].kind == want and id != my_id:
						best = id
				cmd("activate", {"port": a.get("port", "front"), "target": best})
			elif parts[0] == "dump":
				print("[bot] PLAYER ", JSON.stringify({"credits": player.credits, "equipped": player.equipped, "cargo": player.cargo, "level": player.level, "docked": player.docked_at, "drones": me.get("drones", [])}))
			else:
				print("[bot] > ", parts[0], " ", a)
				cmd(parts[0], a)
		return
	think += delta
	if think < 0.5 or my_id == 0 or player.is_empty():
		return
	think = 0.0
	if player.docked_at != "":
		cmd("undock")
		return
	if not ents.has(my_id):
		return
	if tp != "" and not did_tp:
		did_tp = true
		cmd("chat", {"text": "/tp " + tp.replace(",", " ")})
		return
	var my_hex: Vector2i = ents[my_id].hex
	if my_hex != last_hex:
		moves += 1
		last_hex = my_hex
	# Find the nearest merc.
	var best := 0
	var bd := 9999
	for id in ents:
		if infos.has(id) and infos[id].kind == "merc":
			var dd := Hex.distance(my_hex, ents[id].hex)
			if dd < bd:
				bd = dd
				best = id
	if best and bd < 30:
		cmd("target", {"id": best})
		if not player.auto_fire.get("front", false):
			cmd("auto", {"port": "front", "on": true})
		if bd > 4 or me.get("goal") == null:
			cmd("move", {"units": [my_id], "q": ents[best].hex.x, "r": ents[best].hex.y})
	elif me.get("goal") == null:
		var h := my_hex + Vector2i(randi_range(-12, 12), randi_range(-12, 12))
		cmd("move", {"units": [my_id], "q": h.x, "r": h.y})
