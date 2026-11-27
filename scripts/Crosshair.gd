extends Control
## Reticle drawn at screen centre. A small dot with four ticks that spread out
## and recolour when the player is looking at something they can act on.
## Kinds mirror Player.AimKind: 0 none, 1 grabbable, 2 interactable, 3 holding.

const IDLE_COLOR := Color(1.0, 1.0, 1.0, 0.6)
const GRAB_COLOR := Color(0.25, 0.95, 0.82, 1.0)
const USE_COLOR := Color(1.0, 0.78, 0.22, 1.0)
const SHADOW := Color(0.0, 0.0, 0.0, 0.45)

var _kind := 0
var _gap := 5.0
var _length := 4.0
var _dot := 1.6
var _halo := 0.0
var _color := IDLE_COLOR


func set_kind(kind: int) -> void:
	_kind = kind


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
	if _halo > 0.02:
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
