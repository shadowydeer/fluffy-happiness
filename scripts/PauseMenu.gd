extends CanvasLayer
## Esc menu: RESUME, back to the MAIN MENU, or QUIT, plus the settings that have to be
## reachable mid-contract: the EN | RU switch and the MASTER / SFX / AMBIENT volumes
## (kept by `Loc` and `SoundManager` in user://settings.cfg).
##
## Solo, the whole tree is paused while it is open. In co-op the world belongs to
## everybody, so only this player's controls are locked and the contract carries on
## around them. Leaving goes through NetworkManager, which closes the socket cleanly:
## a client that leaves is simply removed from the others' site, and when the host
## leaves every client is returned to its own title screen.

const INK := Color(0.93, 0.95, 0.92)
const DIM := Color(0.60, 0.67, 0.68)
const ACCENT := Color(0.95, 0.42, 0.08)
const WARN := Color(0.95, 0.27, 0.15)
const PANEL := Color(0.025, 0.032, 0.04, 0.95)
## Audio bus and its caption, top to bottom.
const VOLUME_ROWS: Array[Array] = [["Master", "MASTER"], ["SFX", "SFX"], ["Ambient", "AMBIENT"]]

var _main: Node
var _root: Control
var _resume: Button
var _leave: Button
var _session: Label
var _language: Button
var _sliders: Dictionary = {}
var _readouts: Dictionary = {}
var _was_locked := false


func setup(main: Node) -> void:
	_main = main


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.66)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(centre)

	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = ACCENT
	style.border_width_top = 4
	style.set_corner_radius_all(4)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.6)
	style.shadow_size = 24
	style.content_margin_left = 34.0
	style.content_margin_right = 34.0
	style.content_margin_top = 26.0
	style.content_margin_bottom = 26.0
	var card := PanelContainer.new()
	card.name = "Card"
	card.custom_minimum_size = Vector2(440.0, 0.0)
	card.add_theme_stylebox_override(&"panel", style)
	centre.add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 12)
	card.add_child(column)
	var head := HBoxContainer.new()
	column.add_child(head)
	var title := _label("PAUSED", 32, INK)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	Loc.style_header(title)
	head.add_child(title)
	_language = Loc.make_toggle()
	_language.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_language)
	_session = _label("", 12, DIM)
	column.add_child(_session)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, 6.0)
	column.add_child(gap)
	_resume = _button("RESUME", ACCENT)
	_resume.pressed.connect(close)
	column.add_child(_resume)
	_leave = _button("MAIN MENU", Color(0.2, 0.24, 0.27))
	_leave.pressed.connect(_on_leave)
	column.add_child(_leave)
	var quit := _button("QUIT TO DESKTOP", Color(0.16, 0.08, 0.07))
	quit.pressed.connect(_on_quit)
	column.add_child(quit)
	_build_volumes(column)
	var keys := _label("[ESC] resume", 11, Color(DIM, 0.8))
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(keys)
	SoundManager.volume_changed.connect(_on_volume_changed)


func is_open() -> bool:
	return _root.visible


func get_leave_button() -> Button:
	return _leave


## The EN | RU switch in the card's top-right corner.
func get_language_toggle() -> Button:
	return _language


## The slider of an audio bus: "Master", "SFX" or "Ambient".
func get_volume_slider(bus: StringName) -> HSlider:
	return _sliders.get(String(bus)) as HSlider


func open() -> void:
	if _root.visible or _main == null:
		return
	var player: Variant = _main.get(&"player")
	if not is_instance_valid(player):
		return
	# A report card already owns the mouse and the controls; it keeps them afterwards.
	_was_locked = bool(player.get(&"controls_locked"))
	player.set(&"controls_locked", true)
	match NetworkManager.mode:
		NetworkManager.Mode.SOLO:
			_session.text = "SOLO CONTRACT  -  the site is frozen while this is open"
			_leave.text = "MAIN MENU"
			get_tree().paused = true
		NetworkManager.Mode.HOST:
			_session.text = "HOSTING %d PLAYER(S)  -  the contract carries on; leaving ends it for everyone" % NetworkManager.get_player_count()
			_leave.text = "END SESSION & MAIN MENU"
		NetworkManager.Mode.CLIENT:
			_session.text = "CO-OP  -  the contract carries on without you"
			_leave.text = "DISCONNECT & MAIN MENU"
	for bus: String in _sliders:
		_show_volume(bus, SoundManager.get_volume(StringName(bus)))
	_root.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_resume.grab_focus()


func close() -> void:
	if not _root.visible:
		return
	_root.visible = false
	get_tree().paused = false
	var player: Variant = _main.get(&"player")
	if not is_instance_valid(player) or _was_locked:
		return
	player.set(&"controls_locked", false)
	# The click on RESUME must not also fire a gadget.
	(player.get(&"gadgets") as Node).call(&"lock_fire")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		if _root.visible:
			close()
		else:
			open()


func _on_leave() -> void:
	_root.visible = false
	NetworkManager.return_to_menu()


func _on_quit() -> void:
	NetworkManager.leave()
	get_tree().quit()


# --- Volumes ---------------------------------------------------------------------------

## MASTER / SFX / AMBIENT: a caption, a 0..1 slider and its percentage, under a thin rule.
func _build_volumes(column: VBoxContainer) -> void:
	var rule := ColorRect.new()
	rule.color = Color(DIM, 0.25)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	column.add_child(rule)
	column.add_child(_label("VOLUME", 11, DIM))
	var track := StyleBoxFlat.new()
	track.bg_color = Color(DIM, 0.22)
	track.set_corner_radius_all(2)
	track.content_margin_top = 2.0
	track.content_margin_bottom = 2.0
	var fill := track.duplicate() as StyleBoxFlat
	fill.bg_color = ACCENT
	for entry in VOLUME_ROWS:
		var bus: String = entry[0]
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 12)
		column.add_child(row)
		var caption := _label(str(entry[1]), 12, INK)
		caption.autowrap_mode = TextServer.AUTOWRAP_OFF
		caption.custom_minimum_size = Vector2(104.0, 0.0)
		row.add_child(caption)
		var slider := HSlider.new()
		slider.name = "%sVolume" % bus
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.01
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slider.custom_minimum_size = Vector2(160.0, 20.0)
		slider.add_theme_stylebox_override(&"slider", track)
		slider.add_theme_stylebox_override(&"grabber_area", fill)
		slider.add_theme_stylebox_override(&"grabber_area_highlight", fill)
		slider.value_changed.connect(_on_slider_moved.bind(bus))
		slider.drag_ended.connect(_on_slider_released)
		row.add_child(slider)
		var readout := _label("100%", 12, DIM)
		readout.autowrap_mode = TextServer.AUTOWRAP_OFF
		readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		readout.custom_minimum_size = Vector2(46.0, 0.0)
		readout.add_theme_font_override(&"font", Loc.mono_font())
		row.add_child(readout)
		_sliders[bus] = slider
		_readouts[bus] = readout
		_show_volume(bus, SoundManager.get_volume(StringName(bus)))


func _on_slider_moved(value: float, bus: String) -> void:
	(_readouts[bus] as Label).text = "%d%%" % roundi(value * 100.0)
	SoundManager.set_volume(StringName(bus), value)


## Lets the new level be heard.
func _on_slider_released(changed: bool) -> void:
	if changed:
		SoundManager.play_ui(&"ui_click")


## The mixer moved for another reason (settings loaded, another menu): follow it.
func _on_volume_changed(bus: StringName, linear: float) -> void:
	if _sliders.has(String(bus)):
		_show_volume(String(bus), linear)


func _show_volume(bus: String, linear: float) -> void:
	(_sliders[bus] as HSlider).set_value_no_signal(linear)
	(_readouts[bus] as Label).text = "%d%%" % roundi(clampf(linear, 0.0, 1.0) * 100.0)


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	return label


func _button(text: String, color: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 44.0)
	button.add_theme_font_size_override(&"font_size", 16)
	button.add_theme_color_override(&"font_color", INK)
	for state: Array in [["normal", 0.0], ["hover", 0.18], ["pressed", -0.2], ["focus", 0.0]]:
		var style := StyleBoxFlat.new()
		var shade: float = state[1]
		style.bg_color = color.lightened(shade) if shade >= 0.0 else color.darkened(-shade)
		style.set_corner_radius_all(3)
		if state[0] == "focus":
			style.draw_center = false
			style.set_border_width_all(2)
			style.border_color = ACCENT
		button.add_theme_stylebox_override(StringName(state[0]), style)
	return button
