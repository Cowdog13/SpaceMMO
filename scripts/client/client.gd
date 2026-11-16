## Game client: connection, replicated state, input. Rendering is in world_view.gd, UI in ui.gd.
extends Node

const Hex = preload("res://scripts/shared/hex.gd")
const World = preload("res://scripts/shared/world_def.gd")
const Items = preload("res://scripts/shared/items_db.gd")
const WorldView = preload("res://scripts/client/world_view.gd")
const UI = preload("res://scripts/client/ui.gd")

const ENT_STRIDE := 9
const STALE_TICKS := 9 # entity disappears if not updated for this many ticks

signal player_changed
signal station_changed
signal docked_changed

var world: World
var view: WorldView
var ui: UI

var connected := false
var logged_in := false
var my_id := 0
var my_name := ""
var player := {} # full player data from server (credits, cargo, equipped...)
var me := {} # per-tick private data (energy, cooldowns...)
var station := {} # docked station data
var ents := {} # id -> client entity dictionary
var infos := {} # id -> static info
var loot := {} # id -> Vector2i
var last_tick := 0
var wt_offset := 0.0 # server world time - local clock
var has_time := false

var selected: Array = [] # own unit ids
var target_id := 0
var pending_goal = null # optimistic goal marker

var _drag_start = null
var _drag_now := Vector2.ZERO
var _pan_drag := false
var server_pid := 0


func _ready() -> void:
	world = World.new()
	view = WorldView.new()
	view.client = self
	add_child(view)
	ui = UI.new()
	ui.client = self
	add_child(ui)
	Net.client_handler = self
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_dev_args()


## Testing helpers:  -- --autologin NAME PASS [--host H] [--shot out.png SECONDS] [--chat "/tp 0 -100"]
func _dev_args() -> void:
	var a := OS.get_cmdline_user_args()
	var host := "127.0.0.1"
	var i := a.find("--host")
	if i >= 0:
		host = a[i + 1]
	i = a.find("--autologin")
	if i >= 0:
		connect_to(host, Net.DEFAULT_PORT, a[i + 1], a[i + 2])
	i = a.find("--shot")
	if i >= 0:
		var path: String = a[i + 1]
		var secs := float(a[i + 2])
		get_tree().create_timer(secs).timeout.connect(func():
			get_viewport().get_texture().get_image().save_png(path)
			print("[client] screenshot saved ", path)
			get_tree().quit())
	i = a.find("--chat")
	if i >= 0:
		var text: String = a[i + 1]
		get_tree().create_timer(2.0).timeout.connect(func(): cmd("chat", {"text": text}))
	i = a.find("--do")
	if i >= 0:
		# comma separated: undock,target,zoom
		var steps: PackedStringArray = a[i + 1].split(",")
		var t := 2.5
		for st in steps:
			var step := st
			get_tree().create_timer(t).timeout.connect(func(): _dev_step(step))
			t += 1.0


func _dev_step(step: String) -> void:
	if step.begins_with("chat:"):
		cmd("chat", {"text": step.substr(5)})
		return
	if step.begins_with("wait"):
		return
	match step:
		"undock": cmd("undock")
		"dock": cmd("dock")
		"target": target_nearest()
		"fire": activate_slot(0)
		"map": ui.toggle_map()
		"help": ui.toggle_help()
		"zoomout": view.zoom_by(0.5)
		"zoomin": view.zoom_by(1.6)
		"move":
			var h := my_hex() + Vector2i(3, 0)
			order_move(h)
		"approach":
			if ents.has(target_id):
				order_move(ents[target_id].hex)
		"autofire":
			cmd("auto", {"port": "front", "on": true})


func local_secs() -> float:
	return Time.get_ticks_msec() / 1000.0


func world_time() -> float:
	return local_secs() + wt_offset


func _process(_delta: float) -> void:
	world.update(world_time())


# ---------------------------------------------------------------- connection

func connect_to(host: String, port: int, username: String, password: String) -> void:
	multiplayer.multiplayer_peer = null
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		ui.login_status("Could not create connection (%d)." % err)
		return
	multiplayer.multiplayer_peer = peer
	set_meta("login", [username, password])
	ui.login_status("Connecting to %s:%d ..." % [host, port])


## Launch a dedicated server process from this same executable on this PC.
func start_local_server(port: int) -> void:
	var exe := OS.get_executable_path()
	var args := PackedStringArray()
	if OS.has_feature("editor") or not OS.has_feature("template"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(["--headless", "--", "--server", "--port", str(port)])
	server_pid = OS.create_process(exe, args)
	if server_pid > 0:
		ui.login_status("Local server started (pid %d). Connecting..." % server_pid)
	else:
		ui.login_status("Failed to start local server.")


func _exit_tree() -> void:
	if server_pid > 0:
		OS.kill(server_pid)


func _on_connected() -> void:
	connected = true
	var l: Array = get_meta("login")
	Net.c_login.rpc_id(1, l[0], l[1], Net.PROTOCOL_VERSION)
	ui.login_status("Connected, logging in...")


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	ui.login_status("Connection failed.")


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	connected = false
	logged_in = false
	ents.clear()
	ui.show_login("Disconnected from server.")


func cmd(c: String, args := {}) -> void:
	if logged_in:
		Net.c_cmd.rpc_id(1, c, args)


# ---------------------------------------------------------------- network in

func on_msg(type: String, d: Dictionary) -> void:
	match type:
		"login_ok":
			logged_in = true
			my_id = d.id
			my_name = d.name
			selected = [my_id]
			wt_offset = float(d.world_time) - local_secs()
			has_time = true
			ui.show_game()
		"login_fail":
			multiplayer.multiplayer_peer = null
			ui.login_status("Login failed: " + str(d.reason))
		"player":
			player = d
			my_id = d.id
			player_changed.emit()
		"docked":
			station = d
			station_changed.emit()
			docked_changed.emit()
		"undocked":
			station = {}
			docked_changed.emit()
		"ent_info":
			for i in d.list:
				infos[i.id] = i
		"notice":
			ui.toast(d.text, d.get("kind", "info"))
		"chat":
			ui.chat_line(d.from, d.text)
		"died":
			target_id = 0
			ui.toast("Destroyed by %s. Respawned at your home station." % d.by, "error")


func on_state(d: Dictionary) -> void:
	var t: int = d.t
	if d.has("e"):
		_apply_entities(t, d.e)
		return
	if t < last_tick:
		return
	last_tick = t
	var wt: float = d.wt
	var off := wt - local_secs()
	wt_offset = off if absf(off - wt_offset) > 1.0 else lerpf(wt_offset, off, 0.05)
	me = d.me
	if me.has("drones"):
		var keep := []
		for id in selected:
			if id == my_id or id in me.drones:
				keep.append(id)
		selected = keep if not keep.is_empty() else [my_id]
	loot.clear()
	for l in d.l:
		loot[l[0]] = l[1]
	for id in ents.keys():
		if t - ents[id].t > STALE_TICKS:
			ents.erase(id)
	if target_id and not ents.has(target_id):
		target_id = 0
	if me.get("goal") == null:
		pending_goal = null
	for f in d.fx:
		view.add_fx(f)


func _apply_entities(t: int, a: PackedInt32Array) -> void:
	for i in range(0, a.size(), ENT_STRIDE):
		var id := a[i]
		var h := Vector2i(a[i + 1], a[i + 2])
		var e: Dictionary = ents.get(id, {})
		if e.is_empty():
			var px := Hex.to_pixel(h)
			e = {"id": id, "hex": h, "pos": px, "from": px, "anim": 1.0, "angle": Hex.dir_angle(a[i + 3] & 15)}
			ents[id] = e
		elif e.hex != h:
			e.from = e.pos
			e.anim = 0.0
			e.hex = h
		e.facing = a[i + 3] & 15
		e.ch = (a[i + 3] >> 4) & 1
		e.hp = a[i + 4]
		e.mhp = a[i + 5]
		e.sh = a[i + 6]
		e.msh = a[i + 7]
		e.mt = a[i + 8]
		e.t = t


# ---------------------------------------------------------------- helpers

func info(id: int) -> Dictionary:
	return infos.get(id, {})


func is_mine(id: int) -> bool:
	return id == my_id or id in me.get("drones", [])


func is_docked() -> bool:
	return player.get("docked_at", "") != ""


func my_hex() -> Vector2i:
	if ents.has(my_id):
		return ents[my_id].hex
	return world.planet_hexes.get(player.get("docked_at", "earth"), Vector2i.ZERO)


func entity_at(h: Vector2i) -> int:
	for id in ents:
		if ents[id].hex == h:
			return id
	return 0


## Systems in hotkey order: every equipped port with an active ability.
func system_slots() -> Array:
	var out := []
	var eq: Dictionary = player.get("equipped", {})
	for p in Items.get_item(player.get("hull", "")).get("ports", []):
		if eq.has(p.id):
			var it := Items.get_item(eq[p.id])
			if it.has("active"):
				out.append({"key": p.id, "port": p, "item": eq[p.id], "def": it})
	return out


func consumable_slots() -> Array:
	var out := []
	var seen := {}
	for s in player.get("cargo", []):
		var it := Items.get_item(s.id)
		if it.get("type", "") == "consumable" and it.has("active") and not seen.has(s.id):
			seen[s.id] = true
			var n := 0
			for s2 in player.cargo:
				if s2.id == s.id:
					n += int(s2.qty)
			out.append({"key": "item:" + s.id, "item": s.id, "def": it, "qty": n})
	return out


func activate_slot(i: int) -> void:
	var slots := system_slots()
	if i < slots.size():
		cmd("activate", {"port": slots[i].key, "target": target_id})
	else:
		var cons := consumable_slots()
		var j := i - slots.size()
		if j < cons.size():
			cmd("use", {"item": cons[j].item})


func set_target(id: int) -> void:
	target_id = id
	cmd("target", {"id": id})


func target_nearest() -> void:
	var best := 0
	var bd := 99999
	var mh := my_hex()
	for id in ents:
		if is_mine(id):
			continue
		var d := Hex.distance(mh, ents[id].hex)
		var k: String = info(id).get("kind", "")
		if k == "merc":
			d -= 1000 # prefer hostiles
		if d < bd and id != target_id:
			bd = d
			best = id
	if best:
		set_target(best)


func order_move(h: Vector2i) -> void:
	cmd("move", {"units": selected, "q": h.x, "r": h.y})
	if my_id in selected:
		pending_goal = h
	view.add_click_marker(h)


# ---------------------------------------------------------------- input

func _unhandled_input(ev: InputEvent) -> void:
	if not logged_in:
		return
	if ev is InputEventMouseButton:
		_mouse_button(ev)
	elif ev is InputEventMouseMotion:
		if _pan_drag:
			view.pan(-ev.relative)
		if _drag_start != null:
			_drag_now = view.get_global_mouse_position()
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		_key(ev)


func _mouse_button(ev: InputEventMouseButton) -> void:
	var wpos := view.get_global_mouse_position()
	var h := Hex.from_pixel(wpos)
	match ev.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			view.zoom_by(1.12)
		MOUSE_BUTTON_WHEEL_DOWN:
			view.zoom_by(1.0 / 1.12)
		MOUSE_BUTTON_MIDDLE:
			_pan_drag = ev.pressed
			if ev.pressed:
				view.follow = false
		MOUSE_BUTTON_LEFT:
			if ev.pressed:
				_drag_start = wpos
				_drag_now = wpos
			elif _drag_start != null:
				var start: Vector2 = _drag_start
				_drag_start = null
				if start.distance_to(wpos) > 12.0 / view.zoom:
					_box_select(Rect2(start, Vector2.ZERO).expand(wpos), ev.shift_pressed)
				else:
					_click_select(h, ev.shift_pressed)
		MOUSE_BUTTON_RIGHT:
			if not ev.pressed or is_docked():
				return
			var id := entity_at(h)
			if id and not is_mine(id):
				set_target(id)
				var drones := []
				for s in selected:
					if s != my_id:
						drones.append(s)
				if not drones.is_empty():
					cmd("drone_attack", {"units": drones, "target": id})
			else:
				order_move(h)


func _click_select(h: Vector2i, shift: bool) -> void:
	var id := entity_at(h)
	if id == 0:
		if not shift:
			selected = [my_id]
		return
	if is_mine(id):
		if shift:
			if id in selected:
				selected.erase(id)
			else:
				selected.append(id)
		else:
			selected = [id]
	else:
		set_target(id)


func _box_select(r: Rect2, shift: bool) -> void:
	var picked := [] if not shift else selected.duplicate()
	for id in ents:
		if is_mine(id) and r.has_point(ents[id].pos) and not id in picked:
			picked.append(id)
	if not picked.is_empty():
		selected = picked


func drag_rect():
	if _drag_start == null:
		return null
	var s: Vector2 = _drag_start
	if s.distance_to(_drag_now) <= 12.0 / view.zoom:
		return null
	return Rect2(s, Vector2.ZERO).expand(_drag_now)


func _key(ev: InputEventKey) -> void:
	var k := ev.keycode
	if k >= KEY_1 and k <= KEY_9:
		activate_slot(k - KEY_1)
		return
	match k:
		KEY_0:
			activate_slot(9)
		KEY_TAB:
			target_nearest()
		KEY_F:
			cmd("undock" if is_docked() else "dock")
		KEY_M:
			ui.toggle_map()
		KEY_SPACE:
			view.follow = true
		KEY_S:
			cmd("stop")
			pending_goal = null
		KEY_R:
			cmd("recall")
		KEY_A:
			selected = [my_id] + me.get("drones", [])
		KEY_ESCAPE:
			if ui.map_visible():
				ui.toggle_map()
			else:
				set_target(0)
		KEY_ENTER, KEY_KP_ENTER:
			ui.focus_chat()
		KEY_H:
			ui.toggle_help()
	get_viewport().set_input_as_handled()
