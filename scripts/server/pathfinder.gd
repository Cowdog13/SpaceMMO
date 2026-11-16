## Bounded A* on the hex grid. Returns a path toward the goal; if the goal can't be
## reached within the node budget, returns the path to the closest hex found.
extends RefCounted

const Hex = preload("res://scripts/shared/hex.gd")

const MAX_NODES := 3000


## blocked: Callable(hex: Vector2i) -> bool
static func find_path(start: Vector2i, goal: Vector2i, blocked: Callable) -> Array:
	if start == goal:
		return []
	var heap: Array = [] # [f, seq, hex]
	var g := {start: 0}
	var came := {}
	var seq := 0
	_push(heap, [Hex.distance(start, goal), seq, start])
	var best := start
	var best_h := Hex.distance(start, goal)
	var expanded := 0
	while not heap.is_empty() and expanded < MAX_NODES:
		var cur: Vector2i = _pop(heap)[2]
		if cur == goal:
			best = cur
			break
		expanded += 1
		var cg: int = g[cur]
		for d in 6:
			var n := cur + Hex.DIRS[d]
			if n != goal and blocked.call(n):
				continue
			if n == goal and blocked.call(n):
				# Goal itself is blocked (e.g. clicked on a planet) -> just get close.
				continue
			var ng := cg + 1
			if ng < g.get(n, 1 << 30):
				g[n] = ng
				came[n] = cur
				var h := Hex.distance(n, goal)
				if h < best_h:
					best_h = h
					best = n
				seq += 1
				_push(heap, [ng + h, seq, n])
	if best == start:
		return []
	var path: Array = []
	var c: Vector2i = best
	while c != start:
		path.push_front(c)
		c = came[c]
	return path


static func _less(a: Array, b: Array) -> bool:
	return a[0] < b[0] or (a[0] == b[0] and a[1] > b[1]) # prefer newer (deeper) nodes on ties


static func _push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i := heap.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if _less(heap[i], heap[p]):
			var t = heap[i]
			heap[i] = heap[p]
			heap[p] = t
			i = p
		else:
			break


static func _pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i := 0
		var n := heap.size()
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var m := i
			if l < n and _less(heap[l], heap[m]):
				m = l
			if r < n and _less(heap[r], heap[m]):
				m = r
			if m == i:
				break
			var t = heap[i]
			heap[i] = heap[m]
			heap[m] = t
			i = m
	return top
