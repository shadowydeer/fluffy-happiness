extends Control
## One gadget slot on the HUD belt: a drawn icon (lasso coil, lightning bolt, tape
## roll or salt jar), its key, a gold glow while it is the tool in hand, a battery bar
## for the taser, a one-word status badge for the lasso and a charge count for the salt.

const PANEL := Color(0.035, 0.045, 0.055, 0.78)
const DIM := Color(0.60, 0.67, 0.68)
const INK := Color(0.93, 0.95, 0.92)
const GOLD := Color(1.0, 0.76, 0.28)
const CYAN := Color(0.3, 0.92, 1.0)
const WARN := Color(0.95, 0.27, 0.15)
const SILVER := Color(0.8, 0.83, 0.87)
const SALT := Color(1.0, 0.95, 0.76)
const GLASS := Color(0.72, 0.9, 0.96)
const CORK := Color(0.62, 0.45, 0.26)

enum Kind { LASSO = 1, TASER = 2, TAPE = 3, SALT = 4 }

## 1 lasso, 2 taser, 3 tape, 4 salt grenade.
var kind := 1
var active := false
## 0..1, or negative for no battery bar.
var battery := -1.0
var badge := ""
## Charges left, shown in the corner (red at 0) in place of the word badge; negative for none.
var count := -1:
	set(value):
		if value != count:
			count = value
			_pulse = 1.0

var _glow := 0.0
var _pulse := 0.0
var _frame := StyleBoxFlat.new()
var _jar := StyleBoxFlat.new()


func _ready() -> void:
	custom_minimum_size = Vector2(66.0, 66.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.bg_color = PANEL
	_frame.set_border_width_all(2)
	_frame.set_corner_radius_all(6)
	_jar.set_border_width_all(2)
	_jar.corner_radius_top_left = 3
	_jar.corner_radius_top_right = 3
	_jar.corner_radius_bottom_left = 5
	_jar.corner_radius_bottom_right = 5
	Loc.language_changed.connect(_on_language_changed)


func _on_language_changed(_code: String) -> void:
	queue_redraw()


func _process(delta: float) -> void:
	_glow = move_toward(_glow, 1.0 if active else 0.0, delta * 8.0)
	_pulse = move_toward(_pulse, 0.0, delta * 3.0)
	queue_redraw()


func _draw() -> void:
	var lit := Color(DIM, 0.45).lerp(GOLD, _glow)
	_frame.border_color = lit
	_frame.shadow_color = Color(GOLD, 0.45 * _glow)
	_frame.shadow_size = int(8.0 * _glow)
	draw_style_box(_frame, Rect2(Vector2.ZERO, size))
	draw_string(_font(Loc.mono_font()), Vector2(7.0, 16.0), str(kind), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, lit.lerp(INK, 0.3))
	var centre := size * 0.5 + Vector2(1.0, 0.0)
	var tint := DIM.lerp(INK, 0.35 + 0.65 * _glow)
	match kind:
		Kind.LASSO:
			_draw_lasso(centre, GOLD.lerp(tint, 0.25 * (1.0 - _glow)))
		Kind.TASER:
			_draw_bolt(centre + Vector2(0.0, -3.0), CYAN.lerp(tint, 0.3 * (1.0 - _glow)))
		Kind.TAPE:
			_draw_tape(centre, SILVER.lerp(tint, 0.3 * (1.0 - _glow)))
		Kind.SALT:
			_draw_salt(centre + Vector2(-1.0, 3.0), GLASS.lerp(tint, 0.3 * (1.0 - _glow)))
	if battery >= 0.0:
		var track := Rect2(8.0, size.y - 12.0, size.x - 16.0, 5.0)
		draw_rect(track, Color(0.0, 0.0, 0.0, 0.7))
		draw_rect(Rect2(track.position, Vector2(track.size.x * clampf(battery, 0.0, 1.0), track.size.y)), WARN if battery < 0.25 else CYAN)
	if count >= 0:
		_draw_count()
	elif not badge.is_empty():
		var hot := badge == "OVERHEAT"
		var font := _font(Loc.ui_font())
		var word := Loc.t(badge)
		# The Russian words run longer: shrink them to the slot rather than clip them.
		var font_size := 9
		var width := font.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
		if width > size.x - 6.0:
			font_size = maxi(6, int(floor(font_size * (size.x - 6.0) / width)))
		var at := Vector2(0.0, size.y - (16.0 if battery >= 0.0 else 7.0))
		draw_string(font, at, word, HORIZONTAL_ALIGNMENT_CENTER, size.x, font_size, WARN if hot else GOLD)


func _font(wanted: Font) -> Font:
	return wanted if wanted else get_theme_default_font()


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


## A corked glass jar with a heap of glowing salt in it; just a few grains once the pool is empty.
func _draw_salt(centre: Vector2, glass: Color) -> void:
	var stocked := count != 0
	if stocked:
		draw_circle(centre + Vector2(0.0, 7.0), 15.0, Color(SALT, 0.07 + 0.07 * _glow + 0.1 * _pulse))
	_jar.bg_color = Color(glass, 0.12)
	_jar.border_color = Color(glass, 0.9 if stocked else 0.5)
	draw_style_box(_jar, Rect2(centre + Vector2(-11.0, -7.0), Vector2(22.0, 23.0)))
	# Neck and rim, then the cork pushed into it.
	draw_line(centre + Vector2(-7.0, -7.0), centre + Vector2(-7.0, -11.0), _jar.border_color, 2.0, true)
	draw_line(centre + Vector2(7.0, -7.0), centre + Vector2(7.0, -11.0), _jar.border_color, 2.0, true)
	draw_line(centre + Vector2(-9.0, -11.0), centre + Vector2(9.0, -11.0), _jar.border_color, 2.0, true)
	var cork := PackedVector2Array([Vector2(-5.5, -12.0), Vector2(-6.5, -18.0), Vector2(6.5, -18.0), Vector2(5.5, -12.0)])
	for i in cork.size():
		cork[i] += centre
	draw_colored_polygon(cork, CORK if stocked else CORK.darkened(0.3))
	draw_line(centre + Vector2(-5.5, -17.0), centre + Vector2(5.5, -17.0), Color(1.0, 0.9, 0.7, 0.4), 1.0, true)
	if stocked:
		var heap := PackedVector2Array([Vector2(-6.5, 14.0), Vector2(-9.0, 11.5), Vector2(-9.0, 6.0), Vector2(-5.0, 3.0), Vector2(-1.0, 1.5),
				Vector2(3.0, 2.5), Vector2(6.0, 4.5), Vector2(9.0, 6.5), Vector2(9.0, 11.5), Vector2(6.5, 14.0)])
		for i in heap.size():
			heap[i] += centre
		draw_colored_polygon(heap, SALT.lerp(Color.WHITE, 0.35 * _glow))
		draw_polyline(PackedVector2Array([heap[2], heap[3], heap[4], heap[5], heap[6], heap[7]]), Color(1.0, 1.0, 1.0, 0.85), 1.0, true)
		for grain: Vector2 in [Vector2(-4.0, -2.0), Vector2(3.5, -3.5), Vector2(6.0, 0.5)]:
			draw_circle(centre + grain, 1.1, Color(SALT, 0.9))
	else:
		draw_line(centre + Vector2(-6.0, 13.0), centre + Vector2(5.0, 13.0), Color(SALT, 0.45), 1.5, true)
	draw_line(centre + Vector2(-7.5, -3.0), centre + Vector2(-7.5, 8.0), Color(1.0, 1.0, 1.0, 0.4), 1.5, true)


## The charge count in the top right corner: gold while there is something to throw, red at zero.
func _draw_count() -> void:
	var empty := count <= 0
	var ink := WARN if empty else GOLD
	var at := Vector2(size.x - 13.0, 13.0)
	var radius := 9.5 + 3.0 * _pulse
	draw_circle(at, radius, Color(0.03, 0.04, 0.05, 0.94))
	draw_arc(at, radius, 0.0, TAU, 24, ink.lerp(Color.WHITE, 0.6 * _pulse), 1.5, true)
	var font := _font(Loc.header_font())
	var font_size := 13
	var baseline := at.y + (font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	draw_string(font, Vector2(at.x - 12.0, baseline), str(count), HORIZONTAL_ALIGNMENT_CENTER, 24.0, font_size, ink.lerp(INK, 0.25))
