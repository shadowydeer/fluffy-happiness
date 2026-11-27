extends Control
## Reticle drawn at screen centre. A small dot with four ticks that spread out
## and recolour when the player is looking at something they can act on.
## Kinds mirror Player.AimKind: 0 none, 1 grabbable, 2 interactable, 3 holding.
## `set_progress()` draws a ring round it that fills clockwise from the top
## (the duct tape's wrap timer).

const IDLE_COLOR := Color(1.0, 1.0, 1.0, 0.6)
const GRAB_COLOR := Color(0.25, 0.95, 0.82, 1.0)
const USE_COLOR := Color(1.0, 0.78, 0.22, 1.0)
const SHADOW := Color(0.0, 0.0, 0.0, 0.45)
const RING_COLOR := Color(0.86, 0.9, 0.95, 1.0)
const RING_DONE := Color(1.0, 0.8, 0.32, 1.0)
const RING_RADIUS := 30.0
const RING_WIDTH := 5.0

var _kind := 0
var _gap := 5.0
var _length := 4.0
var _dot := 1.6
var _halo := 0.0
var _color := IDLE_COLOR
var _progress := 0.0
var _ring := 0.0


func set_kind(kind: int) -> void:
	_kind = kind


## 0 hides the ring; anything above shows it filled that far (0..1).
func set_progress(value: float) -> void:
	_progress = clampf(value, 0.0, 1.0)


func get_progress() -> float:
	return _progress


func _process(delta: float) -> void:
	var gap := 5.0
	var length := 4.0
	var dot := 1.6
	var halo := 0.0
	var color := IDLE_COLOR
	match _kind:
		1:
			gap = 13.0
			length = 8.0
			halo = 1.0
			color = GRAB_COLOR
		2:
			gap = 11.0
			length = 7.0
			halo = 1.0
			color = USE_COLOR
		3:
			gap = 3.5
			length = 5.0
			dot = 3.2
			color = GRAB_COLOR
	var blend := minf(1.0, delta * 16.0)
	_gap = lerpf(_gap, gap, blend)
	_length = lerpf(_length, length, blend)
	_dot = lerpf(_dot, dot, blend)
	_halo = lerpf(_halo, halo, blend)
	_color = _color.lerp(color, blend)
	_ring = move_toward(_ring, 1.0 if _progress > 0.0 else 0.0, delta * 9.0)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	draw_circle(center, _dot + 1.0, SHADOW)
	draw_circle(center, _dot, _color)
	for direction: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		var from := center + direction * _gap
		var to := center + direction * (_gap + _length)
		draw_line(from, to, SHADOW, 4.0)
		draw_line(from, to, _color, 2.0)
	if _halo > 0.02 and _ring < 0.5:
		var radius := _gap + _length + 4.0
		var tint := Color(_color, _halo * 0.5)
		if _kind == 2:
			# Interactables get a diamond instead of a ring.
			var points := PackedVector2Array()
			for i in 5:
				points.append(center + Vector2.RIGHT.rotated(TAU * float(i) / 4.0) * radius)
			draw_polyline(points, tint, 1.5, true)
		else:
			draw_arc(center, radius, 0.0, TAU, 48, tint, 1.5, true)
	if _ring > 0.02:
		# A dark track, then the fill sweeping clockwise from twelve o'clock.
		draw_arc(center, RING_RADIUS, 0.0, TAU, 64, Color(0.0, 0.0, 0.0, 0.55 * _ring), RING_WIDTH + 3.0, true)
		draw_arc(center, RING_RADIUS, 0.0, TAU, 64, Color(RING_COLOR, 0.16 * _ring), RING_WIDTH, true)
		if _progress > 0.001:
			var fill := RING_COLOR.lerp(RING_DONE, smoothstep(0.75, 1.0, _progress))
			var steps := maxi(4, int(64.0 * _progress))
			draw_arc(center, RING_RADIUS, -PI * 0.5, -PI * 0.5 + TAU * _progress, steps, Color(fill, _ring), RING_WIDTH, true)
			# A bright bead on the leading edge.
			draw_circle(center + Vector2.UP.rotated(TAU * _progress) * RING_RADIUS, RING_WIDTH * 0.62, Color(1.0, 1.0, 1.0, _ring))
