extends CanvasLayer
## Minimal helmet-display HUD, built in code:
##   top-right    contract banner (number, bank balance, task text, progress bar);
##                once the demon has been found, a status strip under it (AI state,
##                stun decay bar, bind pips)
##   bottom-left  health bar (with the solo second-wind pip), stamina bar and the
##                gadget belt: three drawn slot icons with their keys, the taser's
##                battery and the lasso's status
##   bottom-right control hints for whatever is in hand
##   centre       reactive crosshair with a context prompt underneath and the
##                duct tape's wrap ring round it
##   top-left     collapsible list of the test keys (F1); in co-op, the crew roster
##                under it (name, health, DOWN / POSSESSED)
##   full screen  red edge vignette: a flash on a knockdown, a blood edge at low
##                health, a crimson pulse while possessed; the second-wind blackout;
##                the POSSESSION STRUGGLE overlay; DOWNED and revive read-outs

const Crosshair := preload("res://scripts/Crosshair.gd")
const SlotIcon := preload("res://scripts/GadgetSlotIcon.gd")

const INK := Color(0.93, 0.95, 0.92)
const DIM := Color(0.60, 0.67, 0.68)
const PANEL := Color(0.035, 0.045, 0.055, 0.74)
const ACCENT := Color(0.95, 0.42, 0.08)
const TEAL := Color(0.25, 0.92, 0.82)
const WARN := Color(0.95, 0.27, 0.15)
const GOLD := Color(1.0, 0.78, 0.3)
const CONTROLS_HINT := "WASD move   SHIFT sprint   SPACE jump   CTRL crouch   F use   Q shove   V camera   T torch   ESC menu\n1 lasso   2 taser   3 duct tape   0 / wheel: hands   E always grabs by hand (hold on a downed crewmate to revive)"
const DEBUG_HINT_CLOSED := "F1  test keys"
const DEBUG_HINT_OPEN := "F1  hide test keys\nK   stun / wake the demon\nJ   cycle AI: lurking > enraged > poltergeist throw\nL   cycle bind level 0-3\nP   summon the demon in front of you"
const HINT_DURATION := 16.0
const NOTICE_DURATION := 3.5
## Demon AI state index -> label colour (LURKING, STALKING, ENRAGED, POLTERGEIST, STUNNED, CAPTURED).
const DEMON_STATE_COLORS: Array[Color] = [DIM, INK, WARN, ACCENT, TEAL, TEAL, WARN]
const BLOOD := Color(0.72, 0.05, 0.07)
const BLOOD_DARK := Color(0.34, 0.02, 0.04)
## Health fraction under which the screen edge starts to bleed.
const LOW_HEALTH := 0.4

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
## The player this HUD belongs to; polled for health, conditions and co-op read-outs.
var _player: Node
var _health: ProgressBar
var _health_fill: StyleBoxFlat
var _health_value: Label
var _health_target := 1.0
var _wind_pip: Label
var _status: Label
var _status_bar: ProgressBar
var _synergy: Label
var _blackout: ColorRect
var _eyes: Control
var _roster: VBoxContainer
var _roster_rows: Dictionary = {}
var _clock := 0.0


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
	_build_conditions()
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
	player.connect(&"health_changed", _on_health_changed)
	_on_stamina_changed(player.get(&"stamina"), player.get(&"max_stamina"))
	_on_health_changed(player.get(&"hp"), player.get(&"max_hp"))
	_gadgets = player.get(&"gadgets")
	_player = player


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


func get_health_bar() -> ProgressBar:
	return _health


## The big line in the middle of the screen (DOWNED, POSSESSED, SECOND WIND...), "" when clear.
func get_status_text() -> String:
	return _status.text if _status.visible else ""


func get_synergy_text() -> String:
	return _synergy.text if _synergy.visible else ""


func get_vignette_alpha() -> float:
	return _vignette.modulate.a


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

	_clock += delta
	_health.value = lerpf(_health.value, _health_target, minf(1.0, delta * 10.0))
	_health_fill.bg_color = BLOOD.lerp(Color(1.0, 0.16, 0.12), 0.5 + 0.5 * sin(_clock * 9.0)) if _health_target < LOW_HEALTH else BLOOD
	# Red at the edges: a hard flash on impact, a faint hold while still on the floor, a
	# slow bleed as health runs out and a crimson pulse with a demon aboard.
	_vignette_flash = maxf(0.0, _vignette_flash - delta * 1.6)
	var edge := maxf(_vignette_flash, 0.32 if _player_down else 0.0)
	if is_instance_valid(_player):
		edge = maxf(edge, _condition_edge())
		_update_conditions()
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
	# Health sits right above stamina: a dark crimson bar, with the solo auto-injector beside its caption.
	var health_head := _row(column)
	var health_caption := _label("HEALTH", 11, DIM)
	health_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	health_head.add_child(health_caption)
	_wind_pip = _label("", 10, GOLD)
	_wind_pip.name = "SecondWind"
	health_head.add_child(_wind_pip)
	_health_value = _label("100", 11, INK)
	_health_value.custom_minimum_size = Vector2(26.0, 0.0)
	_health_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	health_head.add_child(_health_value)
	_health = _bar(BLOOD, 10.0)
	_health.name = "Health"
	_health.custom_minimum_size = Vector2(198.0, 10.0)
	_health.value = 1.0
	_health_fill = _health.get_theme_stylebox(&"fill") as StyleBoxFlat
	var health_back := _health.get_theme_stylebox(&"background") as StyleBoxFlat
	health_back.bg_color = Color(BLOOD_DARK, 0.75)
	health_back.border_color = Color(0.0, 0.0, 0.0, 0.7)
	health_back.set_border_width_all(1)
	column.add_child(_health)
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


## Everything Stage 4 can do to a player: the centre-screen status line and its meter,
## the co-op drag read-out, the second-wind blackout, the struggle's eyes, the crew roster.
func _build_conditions() -> void:
	_blackout = ColorRect.new()
	_blackout.name = "Blackout"
	_blackout.color = Color(0.0, 0.0, 0.0, 0.0)
	_blackout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blackout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_blackout)
	_root.move_child(_blackout, 1)
	_eyes = DemonEyes.new()
	_eyes.name = "DemonEyes"
	_eyes.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_eyes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_eyes.visible = false
	_root.add_child(_eyes)
	_root.move_child(_eyes, 2)

	_status = _label("", 26, WARN)
	_status.name = "Status"
	_status.anchor_left = 0.5
	_status.anchor_right = 0.5
	_status.anchor_top = 0.5
	_status.anchor_bottom = 0.5
	_status.offset_left = -480.0
	_status.offset_right = 480.0
	_status.offset_top = 104.0
	_status.offset_bottom = 172.0
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.visible = false
	_root.add_child(_status)
	_status_bar = _bar(WARN, 9.0)
	_status_bar.name = "StatusMeter"
	_status_bar.anchor_left = 0.5
	_status_bar.anchor_right = 0.5
	_status_bar.anchor_top = 0.5
	_status_bar.anchor_bottom = 0.5
	_status_bar.offset_left = -150.0
	_status_bar.offset_right = 150.0
	_status_bar.offset_top = 178.0
	_status_bar.offset_bottom = 187.0
	_status_bar.visible = false
	_root.add_child(_status_bar)
	_synergy = _label("", 14, GOLD)
	_synergy.name = "Synergy"
	_synergy.anchor_left = 0.5
	_synergy.anchor_right = 0.5
	_synergy.anchor_top = 0.5
	_synergy.anchor_bottom = 0.5
	_synergy.offset_left = -200.0
	_synergy.offset_right = 200.0
	_synergy.offset_top = 72.0
	_synergy.offset_bottom = 92.0
	_synergy.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_synergy.visible = false
	_root.add_child(_synergy)

	_roster = VBoxContainer.new()
	_roster.name = "Crew"
	_roster.offset_left = 24.0
	_roster.offset_top = 128.0
	_roster.add_theme_constant_override(&"separation", 4)
	_roster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_roster.visible = false
	_root.add_child(_roster)


## How red the edge of the screen should be for the player's condition alone.
func _condition_edge() -> float:
	var edge := 0.0
	var health := float(_player.get(&"hp")) / maxf(float(_player.get(&"max_hp")), 1.0)
	if health < LOW_HEALTH:
		# Blood creeping in from the edges, throbbing faster the less there is left.
		var need := 1.0 - health / LOW_HEALTH
		edge = need * (0.34 + 0.12 * sin(_clock * (3.0 + 5.0 * need)))
	if _player.get(&"is_downed"):
		edge = maxf(edge, 0.55 + 0.1 * sin(_clock * 3.0))
	if _player.get(&"possessed"):
		edge = maxf(edge, 0.5 + 0.3 * sin(_clock * 6.5))
	if float(_player.call(&"get_struggle")) >= 0.0:
		edge = maxf(edge, 0.7 + 0.25 * sin(_clock * 17.0))
	return maxf(edge, 0.5 * float(_player.call(&"get_hurt_flash")))


func _update_conditions() -> void:
	var alone := NetworkManager.get_player_count() <= 1
	_wind_pip.text = ("SECOND WIND  READY" if _player.get(&"second_wind_ready") else "SECOND WIND  USED") if alone else ""
	_wind_pip.add_theme_color_override(&"font_color", GOLD if _player.get(&"second_wind_ready") else DIM)

	var text := ""
	var color := WARN
	var meter := -1.0
	var wind := float(_player.call(&"get_second_wind"))
	var struggle := float(_player.call(&"get_struggle"))
	# Second wind: the lights go out, then come back in a white surge.
	_blackout.color = Color(0.0, 0.0, 0.0, 0.0)
	if wind >= 0.0:
		var dark := smoothstep(0.0, 0.18, wind) * (1.0 - smoothstep(0.78, 1.0, wind))
		_blackout.color = Color(0.0, 0.0, 0.0, 0.94 * dark)
		text = "FLATLINING...\nAUTO-INJECTOR FIRING" if wind < 0.6 else "SECOND WIND!"
		color = GOLD
		meter = wind
	elif struggle >= 0.0:
		text = "POSSESSION STRUGGLE\nMASH [SPACE]!"
		meter = struggle
	elif _player.get(&"is_downed"):
		var helper := _reviver()
		if helper:
			text = "%s IS GETTING YOU UP..." % str(helper.get(&"display_name"))
			color = TEAL
			meter = float(helper.get(&"revive_progress"))
		elif alone:
			text = "DOWN"
		else:
			text = "DOWNED\ncrawl to a crewmate  -  they hold [E] to revive you"
	elif _player.get(&"possessed"):
		text = "YOU ARE POSSESSED\nget to the salt circle  -  or get tased"
	elif _player.call(&"is_leashed"):
		var leash: Dictionary = _player.call(&"get_leash")
		var holder := GameState.get_player_at_seat(int(leash["by"]))
		var who := str(holder.get(&"display_name")) if holder else "A CREWMATE"
		text = "%s BY %s\nmash [SPACE]%s" % ["PINNED" if leash["anchored"] else "ROPED", who, "  or press [R]" if float(leash["time"]) >= 2.0 else "  -  [R] in %.0f s" % ceilf(2.0 - float(leash["time"]))]
		color = GOLD
		meter = float(leash["mash"]) / 6.0
	elif int(_player.get(&"revive_seat")) >= 0:
		var patient := GameState.get_player_at_seat(int(_player.get(&"revive_seat")))
		text = "REVIVING %s..." % (str(patient.get(&"display_name")) if patient else "CREWMATE")
		color = TEAL
		meter = float(_player.get(&"revive_progress"))
	_eyes.visible = struggle >= 0.0
	if _eyes.visible:
		_eyes.queue_redraw()
	_status.visible = not text.is_empty()
	if _status.visible:
		_status.text = text
		_status.add_theme_color_override(&"font_color", color)
	_status_bar.visible = meter >= 0.0
	if _status_bar.visible:
		_status_bar.value = clampf(meter, 0.0, 1.0)
		(_status_bar.get_theme_stylebox(&"fill") as StyleBoxFlat).bg_color = color

	# Hauling the demon alongside somebody else: say so.
	var haulers := int(_demon.call(&"get_hauler_count")) if is_instance_valid(_demon) else 0
	_synergy.visible = haulers >= 2 and _is_hauling()
	if _synergy.visible:
		_synergy.text = "CO-OP DRAG x%d" % haulers
		_synergy.modulate.a = 0.75 + 0.25 * sin(_clock * 6.0)
	_update_roster(alone)


## The standing crewmate who is holding E on this player, if anyone is.
func _reviver() -> Node:
	var seat := int(_player.get(&"seat"))
	for other in GameState.get_players():
		if other != _player and int(other.get(&"revive_seat")) == seat:
			return other
	return null


## True while this player has hold of the demon, by hand or on their rope.
func _is_hauling() -> bool:
	var held: Variant = _player.call(&"get_held")
	if is_instance_valid(held) and (held as Node).has_meta(&"demon"):
		return true
	if is_instance_valid(_gadgets):
		var roped: Variant = (_gadgets.get(&"lasso") as Node).call(&"get_target")
		return is_instance_valid(roped) and (roped as Node).has_meta(&"demon")
	return false


## Co-op only: one line per crewmate with their health and anything that needs doing about them.
func _update_roster(alone: bool) -> void:
	_roster.visible = not alone
	if alone:
		return
	var seen: Dictionary = {}
	for other in GameState.get_players():
		if other == _player:
			continue
		var key := other.get_instance_id()
		seen[key] = true
		var row: Label = _roster_rows.get(key)
		if row == null:
			row = _label("", 12, INK)
			_roster.add_child(row)
			_roster_rows[key] = row
		var state := "%3d HP" % int(ceil(float(other.get(&"hp"))))
		var tint := INK
		if other.get(&"is_downed"):
			state = "DOWN  -  hold [E]"
			tint = WARN
		elif other.get(&"possessed"):
			state = "POSSESSED"
			tint = ACCENT
		row.text = "%s   %s" % [str(other.get(&"display_name")), state]
		row.add_theme_color_override(&"font_color", tint)
	for key: int in _roster_rows.keys():
		if not seen.has(key):
			(_roster_rows[key] as Label).queue_free()
			_roster_rows.erase(key)


## The demon's eyes, burning across the screen for the length of a possession struggle.
class DemonEyes extends Control:
	func _draw() -> void:
		var clock := Time.get_ticks_msec() * 0.001
		var centre := size * 0.5 + Vector2(sin(clock * 31.0), cos(clock * 27.0)) * 9.0
		var spread := size.x * 0.17
		var flare := 0.75 + 0.25 * sin(clock * 23.0)
		for side: float in [-1.0, 1.0]:
			var at := centre + Vector2(side * spread, -size.y * 0.06)
			# A slanted, glowing slit: wide halo, hot core, black pupil.
			for layer: Vector3 in [Vector3(1.0, 0.12, 0.16), Vector3(0.62, 0.3, 0.42), Vector3(0.34, 0.75, 0.9)]:
				var half := Vector2(size.x * 0.085, size.y * 0.035) * layer.x
				var points := PackedVector2Array()
				for i in 24:
					var angle := TAU * float(i) / 24.0
					var p := Vector2(cos(angle) * half.x, sin(angle) * half.y)
					points.append(at + p.rotated(-0.22 * side))
				draw_colored_polygon(points, Color(1.0, 0.32 * layer.z + 0.1, 0.03, layer.y * flare))
			draw_circle(at, size.y * 0.012, Color(0.02, 0.0, 0.0, 0.9))


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


func _on_health_changed(current: float, maximum: float) -> void:
	var before := _health_target
	_health_target = current / maxf(maximum, 0.001)
	_health_value.text = "%d" % int(ceil(current))
	if _health_target < before - 0.001:
		_vignette_flash = maxf(_vignette_flash, 0.85)


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
