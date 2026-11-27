extends Control
## One gadget slot on the HUD belt: a drawn icon (lasso coil, lightning bolt or
## tape roll), its key, a gold glow while it is the tool in hand, a battery bar
## for the taser and a one-word status badge for the lasso.

const PANEL := Color(0.035, 0.045, 0.055, 0.78)
const DIM := Color(0.60, 0.67, 0.68)
const INK := Color(0.93, 0.95, 0.92)
const GOLD := Color(1.0, 0.76, 0.28)
const CYAN := Color(0.3, 0.92, 1.0)
const WARN := Color(0.95, 0.27, 0.15)
const SILVER := Color(0.8, 0.83, 0.87)

enum Kind { LASSO = 1, TASER = 2, TAPE = 3 }

## 1 lasso, 2 taser, 3 tape.
var kind := 1
var active := false
## 0..1, or negative for no battery bar.
var battery := -1.0
var badge := ""

var _glow := 0.0
var _frame := StyleBoxFlat.new()


func _ready() -> void:
	custom_minimum_size = Vector2(66.0, 66.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.bg_color = PANEL
	_frame.set_border_width_all(2)
	_frame.set_corner_radius_all(6)


func _process(delta: float) -> void:
	_glow = move_toward(_glow, 1.0 if active else 0.0, delta * 8.0)
	queue_redraw()


func _draw() -> void:
	var lit := Color(DIM, 0.45).lerp(GOLD, _glow)
	_frame.border_color = lit
	_frame.shadow_color = Color(GOLD, 0.45 * _glow)
	_frame.shadow_size = int(8.0 * _glow)
	draw_style_box(_frame, Rect2(Vector2.ZERO, size))
	var font := get_theme_default_font()
	draw_string(font, Vector2(7.0, 16.0), str(kind), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, lit.lerp(INK, 0.3))
	var centre := size * 0.5 + Vector2(1.0, 0.0)
	var tint := DIM.lerp(INK, 0.35 + 0.65 * _glow)
	match kind:
		Kind.LASSO:
			_draw_lasso(centre, GOLD.lerp(tint, 0.25 * (1.0 - _glow)))
		Kind.TASER:
			_draw_bolt(centre + Vector2(0.0, -3.0), CYAN.lerp(tint, 0.3 * (1.0 - _glow)))
		Kind.TAPE:
			_draw_tape(centre, SILVER.lerp(tint, 0.3 * (1.0 - _glow)))
	if battery >= 0.0:
		var track := Rect2(8.0, size.y - 12.0, size.x - 16.0, 5.0)
		draw_rect(track, Color(0.0, 0.0, 0.0, 0.7))
		draw_rect(Rect2(track.position, Vector2(track.size.x * clampf(battery, 0.0, 1.0), track.size.y)), WARN if battery < 0.25 else CYAN)
	if not badge.is_empty():
		var hot := badge == "OVERHEAT"
		var at := Vector2(0.0, size.y - (16.0 if battery >= 0.0 else 7.0))
		draw_string(font, at, badge, HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, WARN if hot else GOLD)


## A coil of rope with the running end and its noose.
func _draw_lasso(centre: Vector2, color: Color) -> void:
	for i in 3:
		draw_arc(centre + Vector2(-2.0 + i * 1.5, 1.0 + i * 0.8), 12.0 - i * 3.2, 0.0, TAU, 28, color, 2.0, true)
	draw_polyline(PackedVector2Array([centre + Vector2(9.0, -4.0), centre + Vector2(15.0, -12.0), centre + Vector2(13.0, -17.0)]), color, 2.0, true)
	draw_arc(centre + Vector2(10.0, -19.0), 4.0, 0.0, TAU, 14, color, 2.0, true)


func _draw_bolt(centre: Vector2, color: Color) -> void:
	var points := PackedVector2Array([Vector2(4.0, -17.0), Vector2(-9.0, 2.0), Vector2(-1.5, 2.0), Vector2(-5.0, 17.0), Vector2(9.0, -4.0), Vector2(1.5, -4.0)])
	for i in points.size():
		points[i] += centre
	draw_colored_polygon(points, color)
	points.append(points[0])
	draw_polyline(points, Color(1.0, 1.0, 1.0, 0.55), 1.0, true)


## A roll seen face on: wound tape, cardboard core, and the loose end.
func _draw_tape(centre: Vector2, color: Color) -> void:
	draw_arc(centre, 12.5, 0.0, TAU, 32, color, 7.0, true)
	draw_arc(centre, 7.0, 0.0, TAU, 24, Color(0.62, 0.45, 0.26), 2.5, true)
	draw_arc(centre, 16.2, 0.0, TAU, 32, Color(1.0, 1.0, 1.0, 0.35), 1.0, true)
	draw_polyline(PackedVector2Array([centre + Vector2(14.0, 8.0), centre + Vector2(20.0, 14.0), centre + Vector2(13.0, 16.0)]), color, 4.0, true)
