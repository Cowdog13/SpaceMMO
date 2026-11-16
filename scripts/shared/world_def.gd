## The solar system layout: sun, orbiting planets, asteroid belt and zones.
## Deterministic so server and client compute identical positions from world time.
extends RefCounted

const Hex = preload("res://scripts/shared/hex.gd")

const TICK_RATE := 6 # simulation ticks per second
const MAP_RADIUS := 500 # hex radius of the playable map (1001 hexes across)
const SUN_RADIUS := 9 # hexes, impassable
## Real-time seconds for one Earth year. Other planets use their real period ratios.
const YEAR_SECONDS := 4.0 * 3600.0
const ASTEROID_SEED := 424242
const BELT_INNER := 160.0
const BELT_OUTER := 215.0
const DOCK_RANGE := 4 # hexes from a planet's surface you can dock from

## orbit = hex radius, period = Earth years, radius = body radius in hexes,
## safe = safe-zone radius in hexes measured from the planet centre.
const PLANETS := [
	{"id": "mercury", "name": "Mercury", "orbit": 40.0, "period": 0.241, "phase": 0.6, "radius": 1, "safe": 9, "color": Color(0.7, 0.65, 0.6)},
	{"id": "venus", "name": "Venus", "orbit": 66.0, "period": 0.615, "phase": 2.4, "radius": 2, "safe": 11, "color": Color(0.95, 0.8, 0.5)},
	{"id": "earth", "name": "Earth", "orbit": 98.0, "period": 1.0, "phase": 0.0, "radius": 2, "safe": 12, "color": Color(0.3, 0.55, 1.0)},
	{"id": "mars", "name": "Mars", "orbit": 132.0, "period": 1.881, "phase": 4.0, "radius": 1, "safe": 10, "color": Color(0.9, 0.4, 0.25)},
	{"id": "jupiter", "name": "Jupiter", "orbit": 270.0, "period": 11.86, "phase": 1.2, "radius": 6, "safe": 18, "color": Color(0.85, 0.7, 0.55)},
	{"id": "saturn", "name": "Saturn", "orbit": 340.0, "period": 29.46, "phase": 3.1, "radius": 5, "safe": 17, "color": Color(0.9, 0.85, 0.6)},
	{"id": "uranus", "name": "Uranus", "orbit": 410.0, "period": 84.01, "phase": 5.0, "radius": 3, "safe": 14, "color": Color(0.6, 0.9, 0.95)},
	{"id": "neptune", "name": "Neptune", "orbit": 470.0, "period": 164.8, "phase": 2.0, "radius": 3, "safe": 14, "color": Color(0.35, 0.45, 1.0)},
]

## Mercenary danger bands (by distance from the sun). Low level -> go sunward, belt is deadly.
const ZONES := [
	{"name": "Solar Corona", "min": 12.0, "max": 28.0, "tier": 4, "pop": 12},
	{"name": "Mercury Orbit", "min": 28.0, "max": 52.0, "tier": 3, "pop": 18},
	{"name": "Venus Orbit", "min": 52.0, "max": 80.0, "tier": 2, "pop": 26},
	{"name": "Earth Orbit", "min": 80.0, "max": 115.0, "tier": 1, "pop": 34},
	{"name": "Mars Orbit", "min": 115.0, "max": 155.0, "tier": 4, "pop": 30},
	{"name": "Asteroid Belt", "min": 155.0, "max": 222.0, "tier": 7, "pop": 50},
	{"name": "Jovian Space", "min": 222.0, "max": 305.0, "tier": 8, "pop": 40},
	{"name": "Saturnian Space", "min": 305.0, "max": 375.0, "tier": 9, "pop": 30},
	{"name": "Outer Reaches", "min": 375.0, "max": 500.0, "tier": 10, "pop": 30},
]

var asteroids := {} # Vector2i -> true
var planet_hexes := {} # planet id -> Vector2i (for the current time)
var planet_pos := {} # planet id -> Vector2 pixel (continuous, for rendering)
var time := 0.0


func _init() -> void:
	_generate_asteroids()
	update(0.0)


func _generate_asteroids() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = ASTEROID_SEED
	for _i in 1800:
		var ang := rng.randf() * TAU
		var rad := rng.randf_range(BELT_INNER, BELT_OUTER)
		var h := Hex.from_pixel(Vector2(cos(ang), sin(ang)) * rad * Hex.STEP)
		asteroids[h] = true
		# small clusters
		var extra := rng.randi_range(0, 3)
		for _k in extra:
			h = Hex.neighbor(h, rng.randi_range(0, 5))
			asteroids[h] = true


func update(t: float) -> void:
	time = t
	for p in PLANETS:
		var pos := planet_pixel(p, t)
		planet_pos[p.id] = pos
		planet_hexes[p.id] = Hex.from_pixel(pos)


static func planet_pixel(p: Dictionary, t: float) -> Vector2:
	var ang: float = p.phase + TAU * t / (p.period * YEAR_SECONDS)
	return Vector2(cos(ang), sin(ang)) * p.orbit * Hex.STEP


static func get_planet(id: String) -> Dictionary:
	for p in PLANETS:
		if p.id == id:
			return p
	return {}


func in_bounds(h: Vector2i) -> bool:
	return Hex.distance(h, Vector2i.ZERO) <= MAP_RADIUS


## Static obstacles: map edge, sun, asteroids, planet bodies.
func is_blocked(h: Vector2i) -> bool:
	if not in_bounds(h):
		return true
	if Hex.distance(h, Vector2i.ZERO) <= SUN_RADIUS:
		return true
	if asteroids.has(h):
		return true
	return planet_at(h) != ""


## Planet whose body covers this hex, or "".
func planet_at(h: Vector2i) -> String:
	for p in PLANETS:
		if Hex.distance(h, planet_hexes[p.id]) <= p.radius:
			return p.id
	return ""


## Planet whose safe zone contains the hex, or "".
func safe_zone_at(h: Vector2i) -> String:
	for p in PLANETS:
		if Hex.distance(h, planet_hexes[p.id]) <= p.safe:
			return p.id
	return ""


func is_safe(h: Vector2i) -> bool:
	return safe_zone_at(h) != ""


## Planet the hex is close enough to dock at, or "".
func dock_planet_at(h: Vector2i) -> String:
	for p in PLANETS:
		if Hex.distance(h, planet_hexes[p.id]) <= p.radius + DOCK_RANGE:
			return p.id
	return ""


static func zone_index(h: Vector2i) -> int:
	var rf := Hex.radius_f(h)
	for i in ZONES.size():
		if rf >= ZONES[i].min and rf < ZONES[i].max:
			return i
	return -1


static func zone_name(h: Vector2i) -> String:
	var i := zone_index(h)
	return ZONES[i].name if i >= 0 else "Deep Space"


static func zone_tier(h: Vector2i) -> int:
	var i := zone_index(h)
	return ZONES[i].tier if i >= 0 else 1
