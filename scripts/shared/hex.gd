## Hex grid math (pointy-top, axial coordinates q = x, r = y).
## Shared by server and client.
extends RefCounted

const SIZE := 24.0 # pixel radius of one hex (client rendering + angle math)
const SQRT3 := 1.7320508075688772
## Direction index -> axial offset. Index is also used as ship "facing".
const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]
## Pixel distance between two adjacent hex centers.
const STEP := SIZE * SQRT3


static func to_pixel(h: Vector2i) -> Vector2:
	return Vector2(SIZE * SQRT3 * (h.x + h.y * 0.5), SIZE * 1.5 * h.y)


static func from_pixel(p: Vector2) -> Vector2i:
	var q := (SQRT3 / 3.0 * p.x - 1.0 / 3.0 * p.y) / SIZE
	var r := (2.0 / 3.0 * p.y) / SIZE
	return axial_round(q, r)


static func axial_round(q: float, r: float) -> Vector2i:
	var s := -q - r
	var rq := roundf(q)
	var rr := roundf(r)
	var rs := roundf(s)
	var dq := absf(rq - q)
	var dr := absf(rr - r)
	var ds := absf(rs - s)
	if dq > dr and dq > ds:
		rq = -rr - rs
	elif dr > ds:
		rr = -rq - rs
	return Vector2i(int(rq), int(rr))


static func distance(a: Vector2i, b: Vector2i) -> int:
	var dq := a.x - b.x
	var dr := a.y - b.y
	return (absi(dq) + absi(dr) + absi(dq + dr)) / 2


static func neighbor(h: Vector2i, d: int) -> Vector2i:
	return h + DIRS[d]


## Direction index from a to an adjacent hex b, or -1.
static func direction_to(a: Vector2i, b: Vector2i) -> int:
	var d := b - a
	for i in 6:
		if DIRS[i] == d:
			return i
	return -1


## Angle (radians, screen space) a facing index points to.
static func dir_angle(d: int) -> float:
	return to_pixel(DIRS[d]).angle()


## Closest facing index for an arbitrary pixel-space vector.
static func facing_towards(from: Vector2i, to: Vector2i) -> int:
	var v := to_pixel(to) - to_pixel(from)
	if v == Vector2.ZERO:
		return 0
	var best := 0
	var best_d := 999.0
	for i in 6:
		var d := absf(angle_diff(v.angle(), dir_angle(i)))
		if d < best_d:
			best_d = d
			best = i
	return best


## Signed smallest difference between two angles, in radians.
static func angle_diff(a: float, b: float) -> float:
	return wrapf(a - b, -PI, PI)


## Is `target` inside an arc of `arc_deg` degrees centred on `facing` rotated by `offset_deg`?
static func in_arc(origin: Vector2i, facing: int, offset_deg: float, arc_deg: float, target: Vector2i) -> bool:
	if arc_deg >= 360.0:
		return true
	if origin == target:
		return true
	var v := to_pixel(target) - to_pixel(origin)
	var center := dir_angle(facing) + deg_to_rad(offset_deg)
	# Small epsilon so hexes exactly on the edge count as inside.
	return absf(angle_diff(v.angle(), center)) <= deg_to_rad(arc_deg) * 0.5 + 0.01


## Circular radius of a hex from the origin measured in hex steps (used for orbits/zones).
static func radius_f(h: Vector2i) -> float:
	return to_pixel(h).length() / STEP


static func ring(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if radius == 0:
		out.append(center)
		return out
	var h := center + DIRS[4] * radius
	for i in 6:
		for _j in radius:
			out.append(h)
			h = h + DIRS[i]
	return out


## All hexes within radius, nearest first.
static func spiral(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for k in radius + 1:
		out.append_array(ring(center, k))
	return out
