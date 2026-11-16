## Draws the solar system, hex grid, units and effects. Everything is procedural (no assets).
extends Node2D

const Hex = preload("res://scripts/shared/hex.gd")
const World = preload("res://scripts/shared/world_def.gd")
const Items = preload("res://scripts/shared/items_db.gd")

const MOVE_ANIM := 0.45 # seconds to slide between hexes

var client # client.gd
var cam: Camera2D
var zoom := 1.0
var follow := true
var fx_list: Array = []
var stars: Array = []
var font: Font
var hex_corners := PackedVector2Array()


func _ready() -> void:
	cam = Camera2D.new()
	add_child(cam)
	cam.make_current()
	font = ThemeDB.fallback_font
	for i in 6:
		var a := deg_to_rad(60.0 * i - 30.0)
		hex_corners.append(Vector2(cos(a), sin(a)) * Hex.SIZE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for _i in 500:
		stars.append([Vector2(rng.randf(), rng.randf()), rng.randf_range(0.3, 1.0), rng.randf_range(0.05, 0.3)])


func zoom_by(f: float) -> void:
	zoom = clampf(zoom * f, 0.08, 2.5)


func pan(screen_delta: Vector2) -> void:
	cam.position += screen_delta / zoom


func add_fx(f: Dictionary) -> void:
	f["age"] = 0.0
	fx_list.append(f)


func add_click_marker(h: Vector2i) -> void:
	fx_list.append({"k": "click", "p": h, "age": 0.0})


func _process(delta: float) -> void:
	for e in client.ents.values():
		if e.anim < 1.0:
			e.anim = minf(1.0, e.anim + delta / MOVE_ANIM)
		var target := Hex.to_pixel(e.hex)
		e.pos = e.from.lerp(target, ease_in_out(e.anim))
		e.angle = lerp_angle(e.angle, Hex.dir_angle(e.facing), minf(1.0, delta * 10.0))
	for f in fx_list:
		f.age += delta
	fx_list = fx_list.filter(func(f): return f.age < _fx_life(f))
	cam.zoom = cam.zoom.lerp(Vector2(zoom, zoom), minf(1.0, delta * 12.0))
	if follow and client.logged_in:
		var focus: Vector2
		if client.ents.has(client.my_id):
			focus = client.ents[client.my_id].pos
		else:
			focus = client.world.planet_pos.get(client.player.get("docked_at", "earth"), Vector2.ZERO)
		cam.position = cam.position.lerp(focus, minf(1.0, delta * 8.0))
	queue_redraw()


static func ease_in_out(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


func _fx_life(f: Dictionary) -> float:
	match f.k:
		"missile": return f.t / float(World.TICK_RATE) + 0.1
		"dmg": return 1.2
		"boom": return 1.0
		"click": return 0.6
		"channel": return f.t / float(World.TICK_RATE)
	return 0.35


func _view_rect() -> Rect2:
	var size := get_viewport_rect().size / cam.zoom
	return Rect2(cam.position - size * 0.5, size)


# ------------------------------------------------------------------ drawing

func _draw() -> void:
	var vr := _view_rect()
	var z := cam.zoom.x
	_draw_stars(vr)
	_draw_system(vr, z)
	if z > 0.3:
		_draw_grid(vr, z)
	if not client.logged_in:
		return
	_draw_hover(z)
	_draw_goal()
	_draw_arcs()
	for id in client.loot:
		var p := Hex.to_pixel(client.loot[id])
		var s := 7.0
		draw_colored_polygon(PackedVector2Array([p + Vector2(0, -s), p + Vector2(s, 0), p + Vector2(0, s), p + Vector2(-s, 0)]), Color(1, 0.85, 0.2))
	for e in client.ents.values():
		_draw_entity(e, z)
	_draw_fx(z)
	var dr = client.drag_rect()
	if dr != null:
		draw_rect(dr, Color(0.4, 1, 0.5, 0.12), true)
		draw_rect(dr, Color(0.4, 1, 0.5, 0.8), false, 1.0 / z)


func _draw_stars(vr: Rect2) -> void:
	for s in stars:
		# parallax: stars barely move with the camera
		var p: Vector2 = vr.position + Vector2(fposmod(s[0].x * 3000.0 - cam.position.x * s[2], 3000.0) / 3000.0 * vr.size.x,
			fposmod(s[0].y * 2000.0 - cam.position.y * s[2], 2000.0) / 2000.0 * vr.size.y)
		draw_circle(p, 1.2 / cam.zoom.x, Color(1, 1, 1, s[1] * 0.6))


func _draw_system(vr: Rect2, z: float) -> void:
	var w := 1.0 / z
	# Sun
	var sr := (World.SUN_RADIUS + 0.5) * Hex.STEP
	if vr.grow(sr * 3).has_point(Vector2.ZERO):
		for i in 6:
			draw_circle(Vector2.ZERO, sr * (2.6 - i * 0.28), Color(1, 0.6, 0.1, 0.05))
		draw_circle(Vector2.ZERO, sr, Color(1, 0.85, 0.35))
	# Orbits
	for p in World.PLANETS:
		draw_arc(Vector2.ZERO, p.orbit * Hex.STEP, 0, TAU, 256, Color(1, 1, 1, 0.06), w)
	# Asteroids
	if z > 0.12:
		var big := vr.grow(Hex.SIZE)
		for h in client.world.asteroids:
			var p := Hex.to_pixel(h)
			if big.has_point(p):
				var r := Hex.SIZE * (0.55 + 0.3 * sin(h.x * 12.9898 + h.y * 78.233))
				draw_circle(p, r, Color(0.45, 0.4, 0.36))
				draw_circle(p + Vector2(-3, -3), r * 0.5, Color(0.55, 0.5, 0.45))
	else:
		draw_arc(Vector2.ZERO, (World.BELT_INNER + World.BELT_OUTER) * 0.5 * Hex.STEP, 0, TAU, 256,
			Color(0.5, 0.45, 0.4, 0.25), (World.BELT_OUTER - World.BELT_INNER) * Hex.STEP)
	# Planets
	for p in World.PLANETS:
		var pos: Vector2 = client.world.planet_pos[p.id]
		var safe_r: float = (p.safe + 0.5) * Hex.STEP
		if not vr.grow(safe_r).has_point(pos):
			continue
		draw_circle(pos, safe_r, Color(0.2, 1, 0.4, 0.035))
		draw_arc(pos, safe_r, 0, TAU, 128, Color(0.3, 1, 0.5, 0.35), 2.0 * w)
		var dock_r: float = (p.radius + World.DOCK_RANGE + 0.5) * Hex.STEP
		draw_arc(pos, dock_r, 0, TAU, 96, Color(0.6, 0.8, 1, 0.25), w)
		var body_r: float = (p.radius + 0.6) * Hex.STEP
		draw_circle(pos, body_r, p.color.darkened(0.3))
		draw_circle(pos - Vector2(body_r, body_r) * 0.15, body_r * 0.85, p.color)
		if p.id == "saturn":
			draw_arc(pos, body_r * 1.6, 0, TAU, 64, Color(0.9, 0.85, 0.6, 0.6), body_r * 0.25)
		_label(pos + Vector2(0, -body_r - 10 / z), p.name, Color(1, 1, 1, 0.9), 18, z)
		_label(pos + Vector2(0, -safe_r + 18 / z), "SAFE ZONE", Color(0.4, 1, 0.5, 0.6), 11, z)


func _draw_grid(vr: Rect2, z: float) -> void:
	var a := Hex.from_pixel(vr.position)
	var b := Hex.from_pixel(vr.end)
	var r0 := mini(a.y, b.y) - 1
	var r1 := maxi(a.y, b.y) + 1
	var segs := PackedVector2Array()
	var alpha := clampf((z - 0.3) * 0.5, 0.0, 0.12)
	for r in range(r0, r1 + 1):
		var q0 := Hex.from_pixel(Vector2(vr.position.x, r * Hex.SIZE * 1.5)).x - 1
		var q1 := Hex.from_pixel(Vector2(vr.end.x, r * Hex.SIZE * 1.5)).x + 1
		for q in range(q0, q1 + 1):
			var h := Vector2i(q, r)
			if Hex.distance(h, Vector2i.ZERO) > World.MAP_RADIUS:
				continue
			var c := Hex.to_pixel(h)
			# three edges per hex is enough to tile the grid without duplicates
			segs.append(c + hex_corners[0]); segs.append(c + hex_corners[1])
			segs.append(c + hex_corners[1]); segs.append(c + hex_corners[2])
			segs.append(c + hex_corners[2]); segs.append(c + hex_corners[3])
	if not segs.is_empty():
		draw_multiline(segs, Color(0.5, 0.7, 1, alpha), 1.0 / z)


func _hex_outline(h: Vector2i, col: Color, width: float) -> void:
	var c := Hex.to_pixel(h)
	var pts := PackedVector2Array()
	for i in 7:
		pts.append(c + hex_corners[i % 6])
	draw_polyline(pts, col, width)


func _hex_fill(h: Vector2i, col: Color) -> void:
	var c := Hex.to_pixel(h)
	var pts := PackedVector2Array()
	for i in 6:
		pts.append(c + hex_corners[i])
	draw_colored_polygon(pts, col)


func _draw_hover(z: float) -> void:
	var h := Hex.from_pixel(get_global_mouse_position())
	_hex_outline(h, Color(1, 1, 1, 0.35), 1.5 / z)


func _draw_goal() -> void:
	var g = client.me.get("goal")
	if g == null:
		g = client.pending_goal
	if g == null or not client.ents.has(client.my_id):
		return
	_hex_fill(g, Color(0.3, 1, 0.5, 0.15))
	_hex_outline(g, Color(0.3, 1, 0.5, 0.7), 2.0 / cam.zoom.x)
	var a: Vector2 = client.ents[client.my_id].pos
	var b := Hex.to_pixel(g)
	draw_dashed_line(a, b, Color(0.3, 1, 0.5, 0.35), 1.5 / cam.zoom.x, 10.0)


## Weapon firing arcs for the player's ship.
func _draw_arcs() -> void:
	if not client.ents.has(client.my_id):
		return
	var e: Dictionary = client.ents[client.my_id]
	var tgt: Dictionary = client.ents.get(client.target_id, {})
	for s in client.system_slots():
		var act: Dictionary = s.def.active
		if act.get("effect", "") != "damage":
			continue
		var p: Dictionary = s.port
		var rng: float = (act.range + 0.5) * Hex.STEP
		var center: float = e.angle + deg_to_rad(p.get("dir", 0.0))
		var half := deg_to_rad(p.get("arc", 360.0)) * 0.5
		var in_it := false
		if not tgt.is_empty():
			in_it = Hex.distance(e.hex, tgt.hex) <= int(act.range) and Hex.in_arc(e.hex, e.facing, p.get("dir", 0.0), p.get("arc", 360.0), tgt.hex)
		var col: Color = act.get("color", Color.WHITE)
		col.a = 0.18 if in_it else 0.07
		var pts := PackedVector2Array([e.pos])
		for i in 25:
			var a := center - half + 2.0 * half * i / 24.0
			pts.append(e.pos + Vector2(cos(a), sin(a)) * rng)
		draw_colored_polygon(pts, col)
		col.a = 0.4 if in_it else 0.15
		pts.append(e.pos)
		draw_polyline(pts, col, 1.0 / cam.zoom.x)


func _entity_color(id: int, inf: Dictionary) -> Color:
	if id == client.my_id:
		return Color(0.35, 1, 0.45)
	match inf.get("kind", ""):
		"merc":
			return Color(1, 0.3, 0.25).lerp(Color(0.8, 0.2, 1), clampf((inf.get("tier", 1) - 1) / 9.0, 0, 1))
		"drone":
			return Color(0.6, 1, 0.7) if client.is_mine(id) else Color(0.4, 0.8, 0.9)
		"player":
			return Color(0.35, 0.8, 1)
	return Color.GRAY


func _ship_shape(kind: String, hull: String) -> PackedVector2Array:
	if kind == "drone":
		return PackedVector2Array([Vector2(9, 0), Vector2(-6, 6), Vector2(-3, 0), Vector2(-6, -6)])
	match hull:
		"hull_corvette":
			return PackedVector2Array([Vector2(18, 0), Vector2(4, 8), Vector2(-4, 14), Vector2(-12, 9), Vector2(-9, 0), Vector2(-12, -9), Vector2(-4, -14), Vector2(4, -8)])
		"hull_frigate":
			return PackedVector2Array([Vector2(20, 0), Vector2(10, 7), Vector2(-14, 12), Vector2(-18, 6), Vector2(-18, -6), Vector2(-14, -12), Vector2(10, -7)])
		"hull_hauler":
			return PackedVector2Array([Vector2(14, 0), Vector2(10, 10), Vector2(-16, 10), Vector2(-16, -10), Vector2(10, -10)])
	return PackedVector2Array([Vector2(16, 0), Vector2(-10, 10), Vector2(-5, 0), Vector2(-10, -10)])


func _draw_entity(e: Dictionary, z: float) -> void:
	var inf: Dictionary = client.info(e.id)
	var col := _entity_color(e.id, inf)
	var pos: Vector2 = e.pos
	var w := 1.0 / z
	if client.target_id == e.id:
		draw_arc(pos, Hex.SIZE * 0.95, 0, TAU, 32, Color(1, 0.9, 0.2), 2.5 * w)
	if e.id in client.selected:
		draw_arc(pos, Hex.SIZE * 0.8, 0, TAU, 32, Color(0.4, 1, 0.5, 0.8), 1.5 * w)
	if e.ch:
		var t := fmod(Time.get_ticks_msec() / 400.0, 1.0)
		draw_arc(pos, Hex.SIZE * (0.4 + 0.6 * t), 0, TAU, 32, Color(0.6, 0.8, 1, 1 - t), 2 * w)
	if e.msh > 0 and e.sh > 0:
		draw_arc(pos, Hex.SIZE * 0.7, 0, TAU, 32, Color(0.4, 0.7, 1, 0.25 + 0.5 * e.sh / float(e.msh)), 1.5 * w)
	var shape := _ship_shape(inf.get("kind", ""), inf.get("hull", ""))
	var xf := Transform2D(e.angle, pos)
	var pts := xf * shape
	draw_colored_polygon(pts, col.darkened(0.25))
	pts.append(pts[0])
	draw_polyline(pts, col.lightened(0.3), 1.5 * w)
	if z < 0.35:
		return
	# health / shield bars
	var bw := Hex.SIZE * 1.4
	var bp := pos + Vector2(-bw * 0.5, -Hex.SIZE * 1.05)
	draw_rect(Rect2(bp, Vector2(bw, 4)), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bp, Vector2(bw * clampf(e.hp / maxf(e.mhp, 1.0), 0, 1), 4)), Color(0.3, 1, 0.3) if e.hp > e.mhp * 0.35 else Color(1, 0.3, 0.2))
	if e.msh > 0:
		draw_rect(Rect2(bp - Vector2(0, 4), Vector2(bw * clampf(e.sh / float(e.msh), 0, 1), 3)), Color(0.4, 0.7, 1))
	if z > 0.55:
		var nm: String = inf.get("name", "?")
		if inf.get("kind", "") == "player" and inf.has("level"):
			nm = "%s" % nm
		_label(pos + Vector2(0, Hex.SIZE * 1.25), nm, col.lightened(0.2), 12, z)


func _draw_fx(z: float) -> void:
	var w := 1.0 / z
	for f in fx_list:
		var life := _fx_life(f)
		var k: float = 1.0 - f.age / life
		match f.k:
			"beam", "rail":
				var a = _ent_pos(f.a)
				var b = _ent_pos(f.b)
				if a != null and b != null:
					var c: Color = f.get("c", Color.WHITE)
					c.a = k
					draw_line(a, b, c, (5.0 if f.k == "rail" else 2.5) * w * (0.5 + k))
					draw_line(a, b, Color(1, 1, 1, k), 1.0 * w)
			"missile":
				var a = _ent_pos(f.a)
				var b = _ent_pos(f.b)
				if a != null and b != null:
					var t := clampf(f.age / (f.t / float(World.TICK_RATE)), 0, 1)
					var p: Vector2 = a.lerp(b, t)
					draw_circle(p, 4 * w + 2, f.get("c", Color.YELLOW))
					draw_line(p, a.lerp(b, maxf(0, t - 0.1)), Color(1, 0.6, 0.2, 0.6), 2 * w)
			"dmg":
				var p = _ent_pos(f.id)
				if p == null:
					p = Hex.to_pixel(f.p)
				var col := Color(0.5, 0.75, 1, k) if f.get("s", false) else Color(1, 0.4, 0.3, k)
				_label(p + Vector2(0, -Hex.SIZE - 20 * f.age / z - 8 / z), str(f.v), col, 16, z)
			"boom":
				var p := Hex.to_pixel(f.p)
				var r: float = Hex.SIZE * (0.5 + f.age * (3.0 if f.get("big", true) else 1.5))
				draw_circle(p, r, Color(1, 0.6, 0.2, k * 0.5))
				draw_arc(p, r * 1.2, 0, TAU, 32, Color(1, 0.9, 0.5, k), 3 * w)
			"bump":
				var p = _ent_pos(f.id)
				if p != null:
					draw_arc(p, Hex.SIZE * 0.9, 0, TAU, 24, Color(1, 0.4, 0.2, k), 3 * w)
			"buff":
				var p = _ent_pos(f.id)
				if p != null:
					var c: Color = f.get("c", Color.WHITE)
					c.a = k
					draw_arc(p, Hex.SIZE * (0.6 + (1 - k)), 0, TAU, 32, c, 3 * w)
			"click":
				_hex_outline(f.p, Color(0.4, 1, 0.5, k), 3 * w)


func _ent_pos(id):
	var e = client.ents.get(id)
	return e.pos if e != null else null


func _label(pos: Vector2, text: String, col: Color, size: int, z: float) -> void:
	# Keep text a constant size on screen regardless of zoom.
	var s := 1.0 / z
	draw_set_transform(pos, 0, Vector2(s, s))
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string_outline(font, Vector2(-tw * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 3, Color(0, 0, 0, col.a * 0.8))
	draw_string(font, Vector2(-tw * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
	draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
