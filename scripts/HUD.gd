extends CanvasLayer
## Minimal helmet-display HUD, built in code:
##   top-right    contract banner (number, bank balance, task text, progress bar);
##                once the demon has been found, a status strip under it (AI state,
##                stun decay bar, bind pips)
##   bottom-left  stamina bar and the gadget belt: three drawn slot icons with
##                their keys, the taser's battery and the lasso's status
##   bottom-right control hints for whatever is in hand
##   centre       reactive crosshair with a context prompt underneath and the
##                duct tape's wrap ring round it
##   top-left     collapsible list of the test keys (F1)
##   full screen  red edge vignette that flashes when the player is knocked down

const Crosshair := preload("res://scripts/Crosshair.gd")
const SlotIcon := preload("res://scripts/GadgetSlotIcon.gd")

const INK := Color(0.93, 0.95, 0.92)
const DIM := Color(0.60, 0.67, 0.68)
const PANEL := Color(0.035, 0.045, 0.055, 0.74)
const ACCENT := Color(0.95, 0.42, 0.08)
const TEAL := Color(0.25, 0.92, 0.82)
const WARN := Color(0.95, 0.27, 0.15)
const GOLD := Color(1.0, 0.78, 0.3)
const CONTROLS_HINT := "WASD move   SHIFT sprint   SPACE jump   CTRL crouch   F use   V camera   T torch\n1 lasso   2 taser   3 duct tape   0 / wheel: hands   E always grabs by hand"
const DEBUG_HINT_CLOSED := "F1  test keys"
const DEBUG_HINT_OPEN := "F1  hide test keys\nK   stun / wake the demon\nJ   cycle AI: lurking > enraged > poltergeist throw\nL   cycle bind level 0-3\nP   summon the demon in front of you"
const HINT_DURATION := 16.0
const NOTICE_DURATION := 3.5
## Demon AI state index -> label colour (LURKING, STALKING, ENRAGED, POLTERGEIST, STUNNED, CAPTURED).
const DEMON_STATE_COLORS: Array[Color] = [DIM, INK, WARN, ACCENT, TEAL, TEAL]

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
var _debug_hint: Label
var _vignette: TextureRect
var _slots: Array[SlotIcon] = []
var _tool_title: Label
var _gadget_hint: Label
var _progress_label: Label
var _bank: Label
var _top_right: VBoxContainer
var _demon_panel: PanelContainer
var _demon_state: Label
var _stun_bar: ProgressBar
var _stun_value: Label
var _bind_pips: Array[StyleBoxFlat] = []
var _bind_count: Label

var _progress_target := 0.0
var _stamina_target := 1.0
var _notice_left := 0.0
var _hint_left := HINT_DURATION
var _demon: Node
var _demon_ai: Node
var _demon_found := false
var _vignette_flash := 0.0
var _player_down := false
var _debug_open := false
## The player's GadgetManager; polled every frame for the belt, the hints and the wrap ring.
var _gadgets: Node
var _bank_target := 0
var _bank_shown := 0.0
var _bank_flash := 0.0


func _ready() -> void:
	layer = 10
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_vignette()
	_build_objective()
	_build_demon_status()
	_build_status()
	_build_reticle()
	_build_messages()
	GameState.objective_changed.connect(_on_objective_changed)
	GameState.notice_posted.connect(_on_notice_posted)
	GameState.bank_changed.connect(_on_bank_changed)
	_bank_target = GameState.bank_cash
	_bank_shown = float(_bank_target)
	_bank.text = _money(_bank_target)
	GameState.refresh()


## Hooks the HUD up to a player controller's signals and its gadget belt.
func bind_player(player: Node) -> void:
	player.connect(&"stamina_changed", _on_stamina_changed)
	player.connect(&"aim_changed", _on_aim_changed)
	player.connect(&"knocked_down", _on_player_knocked_down)
	player.connect(&"recovered", _on_player_recovered)
	_on_stamina_changed(player.get(&"stamina"), player.get(&"max_stamina"))
	_gadgets = player.get(&"gadgets")


## Hooks the status strip up to the demon (its ragdoll root with an `AI` child). Called
## again for every new contract's demon: the strip folds away until that one is found.
func bind_demon(demon: Node) -> void:
	_demon = demon
	_demon_ai = demon.get_node("AI")
	_demon_found = false
	_demon_panel.visible = false
	_demon_panel.modulate.a = 0.0
	_stun_bar.value = 0.0
	_demon_ai.connect(&"state_changed", _on_demon_state_changed)
	_demon_ai.connect(&"discovered", _on_demon_discovered)
	demon.connect(&"bind_changed", _on_bind_changed)
	_on_demon_state_changed(int(_demon_ai.get(&"state")))
	_on_bind_changed(int(demon.get(&"bind_level")))
	if _demon_ai.get(&"is_discovered"):
		_on_demon_discovered()


## One of the three belt slots (0-2, for keys 1-3).
func get_gadget_slot(index: int) -> Control:
	return _slots[index] if index >= 0 and index < _slots.size() else null


func get_crosshair() -> Control:
	return _crosshair


func get_gadget_hint() -> String:
	return _gadget_hint.text


func get_progress_text() -> String:
	return _progress_label.text if _progress_label.visible else ""


func get_bank_text() -> String:
	return _bank.text


func is_demon_status_visible() -> bool:
	return _demon_panel.visible


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.physical_keycode == KEY_F1:
		_debug_open = not _debug_open
		_debug_hint.text = DEBUG_HINT_OPEN if _debug_open else DEBUG_HINT_CLOSED
		_debug_hint.modulate.a = 0.9 if _debug_open else 0.5


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

	# Red at the edges: a hard flash on impact, a faint hold while still on the floor.
	_vignette_flash = maxf(0.0, _vignette_flash - delta * 1.6)
	var edge := maxf(_vignette_flash, 0.32 if _player_down else 0.0)
	_vignette.modulate.a = lerpf(_vignette.modulate.a, edge, minf(1.0, delta * 12.0))

	if _demon_found and is_instance_valid(_demon):
		_demon_panel.modulate.a = move_toward(_demon_panel.modulate.a, 1.0, delta * 3.0)
		var stun := float(_demon.get(&"stun_meter"))
		_stun_bar.value = lerpf(_stun_bar.value, stun / 100.0, minf(1.0, delta * 10.0))
		_stun_value.text = "%d" % int(ceil(stun))
	_update_gadgets(delta)
	_update_bank(delta)


## Belt, hints and wrap ring, read straight off the GadgetManager.
func _update_gadgets(_delta: float) -> void:
	if not is_instance_valid(_gadgets):
		return
	var active := int(_gadgets.get(&"slot"))
	for i in _slots.size():
		_slots[i].active = active == i + 1
		_slots[i].badge = str(_gadgets.call(&"get_badge", i + 1))
	_slots[1].battery = float(_gadgets.call(&"get_battery"))
	_tool_title.text = str(_gadgets.call(&"get_title"))
	_tool_title.modulate = GOLD if active != 0 else DIM
	_gadget_hint.text = str(_gadgets.call(&"get_hint"))
	var caption := str(_gadgets.call(&"get_progress_label"))
	_progress_label.text = caption
	_progress_label.visible = not caption.is_empty()
	# The ring shows from the first frame of a wrap, before there is anything to fill.
	_crosshair.set_progress(maxf(float(_gadgets.call(&"get_progress")), 0.004) if not caption.is_empty() else 0.0)


## The balance counts up to a payout and glows while it does.
func _update_bank(delta: float) -> void:
	_bank_flash = maxf(0.0, _bank_flash - delta * 0.6)
	if not is_equal_approx(_bank_shown, float(_bank_target)):
		_bank_shown = move_toward(_bank_shown, float(_bank_target), delta * maxf(300.0, absf(_bank_target - _bank_shown) * 2.5))
		_bank.text = _money(int(round(_bank_shown)))
	_bank.modulate = Color.WHITE.lerp(Color(1.6, 1.5, 1.2), _bank_flash)


# --- Layout -------------------------------------------------------------------

func _build_vignette() -> void:
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	fade.colors = PackedColorArray([Color(0.7, 0.0, 0.0, 0.0), Color(0.7, 0.0, 0.0, 0.0), Color(0.78, 0.03, 0.0, 0.9)])
	var ring := GradientTexture2D.new()
	ring.width = 256
	ring.height = 256
	ring.fill = GradientTexture2D.FILL_RADIAL
	ring.fill_from = Vector2(0.5, 0.5)
	ring.fill_to = Vector2(1.0, 0.5)
	ring.gradient = fade
	_vignette = TextureRect.new()
	_vignette.name = "HitVignette"
	_vignette.texture = ring
	_vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.modulate.a = 0.0
	_root.add_child(_vignette)


func _build_objective() -> void:
	_top_right = VBoxContainer.new()
	_top_right.name = "TopRight"
	_top_right.anchor_left = 1.0
	_top_right.anchor_right = 1.0
	_top_right.offset_left = -404.0
	_top_right.offset_right = -24.0
	_top_right.offset_top = 22.0
	_top_right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_top_right.add_theme_constant_override(&"separation", 8)
	_top_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_top_right)
	var panel := PanelContainer.new()
	panel.name = "ObjectiveBanner"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override(&"panel", _panel_style(ACCENT))
	_top_right.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 7)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)
	_title = _label("", 12, DIM)
	column.add_child(_title)
	# The crew's bank balance, right under the contract header.
	var bank_row := _row(column)
	bank_row.name = "BankRow"
	bank_row.add_child(_label("BANK", 11, DIM))
	_bank = _label("$0", 16, GOLD)
	_bank.name = "BankCash"
	bank_row.add_child(_bank)
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


## Compact demon read-out under the contract banner; stays hidden until the demon is found.
func _build_demon_status() -> void:
	_demon_panel = PanelContainer.new()
	_demon_panel.name = "DemonStatus"
	_demon_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_demon_panel.add_theme_stylebox_override(&"panel", _panel_style(WARN))
	_demon_panel.visible = false
	_demon_panel.modulate.a = 0.0
	_top_right.add_child(_demon_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 6)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_demon_panel.add_child(column)

	var head := _row(column)
	var caption := _label("DEMON", 11, DIM)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(caption)
	_demon_state = _label("LURKING", 15, DIM)
	head.add_child(_demon_state)

	var stun := _row(column)
	var stun_caption := _label("STUN", 11, DIM)
	stun_caption.custom_minimum_size = Vector2(40.0, 0.0)
	stun.add_child(stun_caption)
	_stun_bar = _bar(TEAL, 7.0)
	_stun_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stun_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stun.add_child(_stun_bar)
	_stun_value = _label("0", 11, DIM)
	_stun_value.custom_minimum_size = Vector2(26.0, 0.0)
	_stun_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stun.add_child(_stun_value)

	var bind := _row(column)
	var bind_caption := _label("BIND", 11, DIM)
	bind_caption.custom_minimum_size = Vector2(40.0, 0.0)
	bind.add_child(bind_caption)
	for i in 3:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.0, 0.0, 0.0, 0.6)
		style.set_corner_radius_all(2)
		var pip := Panel.new()
		pip.name = "BindPip%d" % (i + 1)
		pip.custom_minimum_size = Vector2(26.0, 7.0)
		pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.add_theme_stylebox_override(&"panel", style)
		bind.add_child(pip)
		_bind_pips.append(style)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bind.add_child(spacer)
	_bind_count = _label("0/3", 11, DIM)
	bind.add_child(_bind_count)


func _row(parent: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)
	return row


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
	_tool_title = _label("HANDS", 11, Color.WHITE)
	_tool_title.name = "ToolTitle"
	_tool_title.modulate = DIM
	column.add_child(_tool_title)
	var slots := HBoxContainer.new()
	slots.name = "GadgetSlots"
	slots.add_theme_constant_override(&"separation", 9)
	slots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(slots)
	for i in 3:
		var slot := SlotIcon.new()
		slot.name = "GadgetSlot%d" % (i + 1)
		slot.kind = i + 1
		slots.add_child(slot)
		_slots.append(slot)
	# Slot 2 carries the taser's battery bar.
	_slots[1].battery = 1.0


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
	_progress_label = _label("", 15, Color(0.9, 0.93, 0.97))
	_progress_label.name = "ProgressLabel"
	_progress_label.anchor_left = 0.5
	_progress_label.anchor_right = 0.5
	_progress_label.anchor_top = 0.5
	_progress_label.anchor_bottom = 0.5
	_progress_label.offset_left = -320.0
	_progress_label.offset_right = 320.0
	_progress_label.offset_top = -74.0
	_progress_label.offset_bottom = -50.0
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_progress_label.visible = false
	_root.add_child(_progress_label)
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
	_hint.offset_left = -760.0
	_hint.offset_right = -24.0
	_hint.offset_top = -96.0
	_hint.offset_bottom = -52.0
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_root.add_child(_hint)
	# What the buttons do right now, for whatever is in hand. Always on.
	_gadget_hint = _label("", 13, Color(INK, 0.9))
	_gadget_hint.name = "GadgetHint"
	_gadget_hint.anchor_left = 1.0
	_gadget_hint.anchor_right = 1.0
	_gadget_hint.anchor_top = 1.0
	_gadget_hint.anchor_bottom = 1.0
	_gadget_hint.offset_left = -900.0
	_gadget_hint.offset_right = -24.0
	_gadget_hint.offset_top = -46.0
	_gadget_hint.offset_bottom = -22.0
	_gadget_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_gadget_hint.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_root.add_child(_gadget_hint)
	# Test keys: one dim line in the corner until F1 unfolds it.
	_debug_hint = _label(DEBUG_HINT_CLOSED, 11, DIM)
	_debug_hint.name = "DebugHint"
	_debug_hint.offset_left = 24.0
	_debug_hint.offset_top = 20.0
	_debug_hint.modulate.a = 0.5
	_root.add_child(_debug_hint)


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


func _on_bank_changed(total: int) -> void:
	_bank_target = total
	_bank_flash = 1.0


func _money(amount: int) -> String:
	var digits := str(absi(amount))
	var grouped := ""
	while digits.length() > 3:
		grouped = "," + digits.substr(digits.length() - 3) + grouped
		digits = digits.substr(0, digits.length() - 3)
	return ("-$" if amount < 0 else "$") + digits + grouped


func _on_stamina_changed(current: float, maximum: float) -> void:
	_stamina_target = current / maxf(maximum, 0.001)


func _on_aim_changed(kind: int, prompt: String) -> void:
	_crosshair.set_kind(kind)
	_prompt.text = prompt


func _on_player_knocked_down(_duration: float) -> void:
	_vignette_flash = 1.0
	_player_down = true


func _on_player_recovered() -> void:
	_player_down = false


func _on_demon_discovered() -> void:
	_demon_found = true
	_demon_panel.visible = true


func _on_demon_state_changed(state: int) -> void:
	var names: Array = _demon_ai.get(&"STATE_NAMES")
	_demon_state.text = str(names[state])
	var color := DEMON_STATE_COLORS[clampi(state, 0, DEMON_STATE_COLORS.size() - 1)]
	_demon_state.add_theme_color_override(&"font_color", color)


func _on_bind_changed(level: int) -> void:
	for i in _bind_pips.size():
		_bind_pips[i].bg_color = TEAL if i < level else Color(0.0, 0.0, 0.0, 0.6)
	_bind_count.text = "%d/3" % level


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
