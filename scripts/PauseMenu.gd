extends CanvasLayer
## Esc menu: RESUME, back to the MAIN MENU, or QUIT.
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

var _main: Node
var _root: Control
var _resume: Button
var _leave: Button
var _session: Label
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
	card.custom_minimum_size = Vector2(400.0, 0.0)
	card.add_theme_stylebox_override(&"panel", style)
	centre.add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 12)
	card.add_child(column)
	column.add_child(_label("PAUSED", 30, INK))
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
	var keys := _label("[ESC] resume", 11, Color(DIM, 0.8))
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(keys)


func is_open() -> bool:
	return _root.visible


func get_leave_button() -> Button:
	return _leave


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
