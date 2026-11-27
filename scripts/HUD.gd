extends CanvasLayer
## Minimal helmet-display HUD, built in code:
##   top-right    contract banner with task text and a progress bar
##   bottom-left  stamina bar and three gadget slots (empty until Stage 3)
##   centre       reactive crosshair with a context prompt underneath

const Crosshair := preload("res://scripts/Crosshair.gd")

const INK := Color(0.93, 0.95, 0.92)
const DIM := Color(0.60, 0.67, 0.68)
const PANEL := Color(0.035, 0.045, 0.055, 0.74)
const ACCENT := Color(0.95, 0.42, 0.08)
const TEAL := Color(0.25, 0.92, 0.82)
const WARN := Color(0.95, 0.27, 0.15)
const CONTROLS_HINT := "WASD move   SHIFT sprint   SPACE jump   CTRL crouch\nLMB / E grab   RMB throw   F use   V camera   T torch"
const HINT_DURATION := 16.0
const NOTICE_DURATION := 3.5

var _root: Control
var _title: Label
var _task: Label
var _progress: ProgressBar
var _progress_count: Label
var _stamina: ProgressBar
var _stamina_fill: StyleBoxFlat
var _crosshair: Crosshair
var _prompt: Label
var _notice: Label
var _hint: Label
var _slot_labels: Array[Label] = []
var _slot_styles: Array[StyleBoxFlat] = []

var _progress_target := 0.0
var _stamina_target := 1.0
var _notice_left := 0.0
var _hint_left := HINT_DURATION


func _ready() -> void:
	layer = 10
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_objective()
	_build_status()
	_build_reticle()
	_build_messages()
	GameState.objective_changed.connect(_on_objective_changed)
	GameState.notice_posted.connect(_on_notice_posted)
	GameState.refresh()


## Hooks the HUD up to a player controller's signals.
func bind_player(player: Node) -> void:
	player.connect(&"stamina_changed", _on_stamina_changed)
	player.connect(&"aim_changed", _on_aim_changed)
	_on_stamina_changed(player.get(&"stamina"), player.get(&"max_stamina"))


## Fills or clears one of the three gadget slots (0-2). Reserved for Stage 3.
func set_gadget_slot(index: int, gadget_name: String = "") -> void:
	if index < 0 or index >= _slot_labels.size():
		return
	var filled := not gadget_name.is_empty()
	_slot_labels[index].text = gadget_name if filled else "EMPTY"
	_slot_labels[index].add_theme_color_override(&"font_color", INK if filled else Color(DIM, 0.55))
	_slot_styles[index].border_color = TEAL if filled else Color(DIM, 0.45)


func _process(delta: float) -> void:
	var blend := minf(1.0, delta * 8.0)
	_progress.value = lerpf(_progress.value, _progress_target, blend)
	_stamina.value = lerpf(_stamina.value, _stamina_target, minf(1.0, delta * 14.0))
	_stamina_fill.bg_color = _stamina_fill.bg_color.lerp(WARN if _stamina_target < 0.22 else TEAL, blend)
	if _notice_left > 0.0:
		_notice_left -= delta
		_notice.modulate.a = clampf(_notice_left / 0.6, 0.0, 1.0)
	if _hint_left > 0.0:
		_hint_left -= delta
		_hint.modulate.a = clampf(_hint_left / 2.0, 0.0, 1.0) * 0.85


# --- Layout -------------------------------------------------------------------

func _build_objective() -> void:
	var panel := PanelContainer.new()
	panel.name = "ObjectiveBanner"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -404.0
	panel.offset_right = -24.0
	panel.offset_top = 22.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override(&"panel", _panel_style(ACCENT))
	_root.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 7)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)
	_title = _label("", 12, DIM)
	column.add_child(_title)
	_task = _label("", 19, INK)
	_task.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_task)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(row)
	_progress = _bar(ACCENT, 8.0)
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_progress)
	_progress_count = _label("0 / 0", 12, DIM)
	row.add_child(_progress_count)


func _build_status() -> void:
	var column := VBoxContainer.new()
	column.name = "Status"
	column.anchor_top = 1.0
	column.anchor_bottom = 1.0
	column.offset_left = 24.0
	column.offset_bottom = -22.0
	column.grow_vertical = Control.GROW_DIRECTION_BEGIN
	column.add_theme_constant_override(&"separation", 6)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(column)
	column.add_child(_label("STAMINA", 11, DIM))
	_stamina = _bar(TEAL, 10.0)
	_stamina.custom_minimum_size = Vector2(198.0, 10.0)
	_stamina.value = 1.0
	_stamina_fill = _stamina.get_theme_stylebox(&"fill") as StyleBoxFlat
	column.add_child(_stamina)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 4.0)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(spacer)
	var slots := HBoxContainer.new()
	slots.add_theme_constant_override(&"separation", 9)
	slots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(slots)
	for i in 3:
		var style := StyleBoxFlat.new()
		style.bg_color = PANEL
		style.set_border_width_all(2)
		style.border_color = Color(DIM, 0.45)
		style.set_corner_radius_all(6)
		var slot := Panel.new()
		slot.name = "GadgetSlot%d" % (i + 1)
		slot.custom_minimum_size = Vector2(60.0, 60.0)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_theme_stylebox_override(&"panel", style)
		slots.add_child(slot)
		var key := _label(str(i + 1), 12, DIM)
		key.position = Vector2(7.0, 3.0)
		slot.add_child(key)
		var content := _label("EMPTY", 9, Color(DIM, 0.55))
		content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		content.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		content.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		slot.add_child(content)
		_slot_labels.append(content)
		_slot_styles.append(style)


func _build_reticle() -> void:
	_crosshair = Crosshair.new()
	_crosshair.name = "Crosshair"
	_crosshair.anchor_left = 0.5
	_crosshair.anchor_right = 0.5
	_crosshair.anchor_top = 0.5
	_crosshair.anchor_bottom = 0.5
	_crosshair.offset_left = -48.0
	_crosshair.offset_right = 48.0
	_crosshair.offset_top = -48.0
	_crosshair.offset_bottom = 48.0
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_crosshair)
	_prompt = _label("", 15, INK)
	_prompt.name = "Prompt"
	_prompt.anchor_left = 0.5
	_prompt.anchor_right = 0.5
	_prompt.anchor_top = 0.5
	_prompt.anchor_bottom = 0.5
	_prompt.offset_left = -320.0
	_prompt.offset_right = 320.0
	_prompt.offset_top = 46.0
	_prompt.offset_bottom = 70.0
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_prompt)


func _build_messages() -> void:
	_notice = _label("", 16, TEAL)
	_notice.name = "Notice"
	_notice.anchor_left = 0.5
	_notice.anchor_right = 0.5
	_notice.offset_left = -400.0
	_notice.offset_right = 400.0
	_notice.offset_top = 84.0
	_notice.offset_bottom = 110.0
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.modulate.a = 0.0
	_root.add_child(_notice)
	_hint = _label(CONTROLS_HINT, 12, DIM)
	_hint.name = "ControlsHint"
	_hint.anchor_left = 1.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_left = -520.0
	_hint.offset_right = -24.0
	_hint.offset_top = -62.0
	_hint.offset_bottom = -22.0
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_root.add_child(_hint)


# --- Signal handlers ------------------------------------------------------------

func _on_objective_changed(title: String, task: String, progress: float, done: int, total: int) -> void:
	_title.text = title
	_task.text = "> %s" % task
	_progress_target = progress
	_progress_count.text = "%d / %d" % [done, total]


func _on_notice_posted(text: String) -> void:
	_notice.text = text
	_notice.modulate.a = 1.0
	_notice_left = NOTICE_DURATION


func _on_stamina_changed(current: float, maximum: float) -> void:
	_stamina_target = current / maxf(maximum, 0.001)


func _on_aim_changed(kind: int, prompt: String) -> void:
	_crosshair.set_kind(kind)
	_prompt.text = prompt


# --- Widget helpers ---------------------------------------------------------------

func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_shadow_color", Color(0.0, 0.0, 0.0, 0.7))
	label.add_theme_constant_override(&"shadow_offset_x", 1)
	label.add_theme_constant_override(&"shadow_offset_y", 1)
	return label


func _panel_style(stripe: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = stripe
	style.border_width_left = 4
	style.set_corner_radius_all(3)
	style.content_margin_left = 16.0
	style.content_margin_right = 14.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 12.0
	return style


## Thin 0..1 progress bar with flat fill.
func _bar(fill_color: Color, height: float) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.step = 0.001
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0.0, height)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	background.set_corner_radius_all(2)
	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	fill.set_corner_radius_all(2)
	bar.add_theme_stylebox_override(&"background", background)
	bar.add_theme_stylebox_override(&"fill", fill)
	return bar
