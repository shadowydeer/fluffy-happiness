extends Node3D
## Title screen and co-op lobby (the project's main scene).
##
## Behind the menu the real site is running: the LevelBuilder's cursed house in its
## fog, the extraction van with its amber beacons turning, filmed by a camera that
## drifts slowly along the kerb. Nothing in that backdrop plays (see Main.backdrop).
##
##   PLAY SOLO    one exorcist, straight into contract #0413. No sockets, no company.
##   HOST CO-OP   opens a lobby on a port (7777 unless changed), shows this machine's
##                LAN address, name and suit colour, and lists who has joined (up to
##                four). START CONTRACT takes everyone to the site.
##   JOIN CO-OP   address (127.0.0.1 by default, for a second window on the same PC),
##                port, name and suit colour, then CONNECT and wait for the host.
##
## Every seat in the roster is a person. There are no bots to fill empty ones.

const MainScene := preload("res://scenes/Main.tscn")

enum Page { TITLE, HOST, JOIN }

const INK := Color(0.93, 0.95, 0.92)
const DIM := Color(0.60, 0.67, 0.68)
const ACCENT := Color(0.95, 0.42, 0.08)
const TEAL := Color(0.25, 0.92, 0.82)
const WARN := Color(0.95, 0.27, 0.15)
const GOLD := Color(1.0, 0.78, 0.3)
const PANEL := Color(0.025, 0.032, 0.04, 0.9)
const STEEL := Color(0.2, 0.24, 0.27)
const SUIT_SWATCHES: Array[Color] = [Color(0.86, 0.34, 0.06), Color(0.05, 0.50, 0.50), Color(0.38, 0.42, 0.17), Color(0.40, 0.20, 0.58)]
## The camera looks at this point while it tracks from one end of its rail to the other.
const LOOK_AT := Vector3(1.5, 1.7, -2.5)
const RAIL_FROM := Vector3(9.6, 3.1, 12.7)
const RAIL_TO := Vector3(13.8, 3.9, 10.4)

var page: Page = Page.TITLE

var _camera: Camera3D
var _clock := 0.0
var _suit := 0
var _status: Label
var _panel: PanelContainer
var _panel_title: Label
var _name_edit: LineEdit
var _port_edit: LineEdit
var _address_edit: LineEdit
var _address_row: Control
var _local_ip: Label
var _suit_buttons: Array[Button] = []
var _roster_title: Label
var _roster_rows: Array[Label] = []
var _lobby_status: Label
var _primary: Button
var _back: Button
var _menu_buttons: Dictionary = {}


func _ready() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var site := MainScene.instantiate()
	site.name = "Backdrop"
	site.set(&"backdrop", true)
	add_child(site)
	_camera = Camera3D.new()
	_camera.name = "MenuCamera"
	_camera.fov = 52.0
	_camera.far = 300.0
	add_child(_camera)
	_camera.make_current()
	_place_camera()
	_suit = NetworkManager.local_suit
	_build_ui()
	NetworkManager.roster_changed.connect(_refresh)
	NetworkManager.joined_lobby.connect(_on_joined)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.session_closed.connect(_on_session_closed)
	_show(Page.TITLE)
	if not NetworkManager.last_message.is_empty():
		_status.text = NetworkManager.last_message
		NetworkManager.last_message = ""


func _process(delta: float) -> void:
	_clock += delta
	_place_camera()


## A slow there-and-back dolly along the kerb, always turned toward the house and the van.
func _place_camera() -> void:
	var along := 0.5 - 0.5 * cos(_clock * 0.045)
	var at := RAIL_FROM.lerp(RAIL_TO, along) + Vector3(0.0, 0.12 * sin(_clock * 0.31), 0.0)
	_camera.global_transform = Transform3D(Basis.IDENTITY, at).looking_at(LOOK_AT, Vector3.UP)


# --- Accessors (tests and tooling) ---------------------------------------------------

func get_menu_button(id: String) -> Button:
	return _menu_buttons.get(id) as Button


func get_primary_button() -> Button:
	return _primary


func get_roster_text() -> String:
	var lines := PackedStringArray()
	for row in _roster_rows:
		lines.append(row.text)
	return "\n".join(lines)


func get_status_text() -> String:
	return _lobby_status.text if page != Page.TITLE else _status.text


# --- Pages ---------------------------------------------------------------------------

func _show(next: Page) -> void:
	page = next
	_panel.visible = next != Page.TITLE
	if next == Page.TITLE:
		_status.text = ""
		return
	_panel_title.text = "HOST CO-OP" if next == Page.HOST else "JOIN CO-OP"
	_address_row.visible = next == Page.JOIN
	_local_ip.visible = next == Page.HOST
	_lobby_status.text = ""
	_refresh()


func _on_solo() -> void:
	NetworkManager.local_name = _name_edit.text
	NetworkManager.start_solo()


func _on_host() -> void:
	_show(Page.HOST)
	_open_lobby()


func _on_join() -> void:
	NetworkManager.leave()
	_show(Page.JOIN)
	_lobby_status.text = "Enter the host's address and press CONNECT."


func _on_back() -> void:
	NetworkManager.leave()
	_show(Page.TITLE)


func _on_quit() -> void:
	NetworkManager.leave()
	get_tree().quit()


## Starts (or restarts, after a port change) listening for players.
func _open_lobby() -> void:
	var port := _read_port()
	var error := NetworkManager.host_game(port, _name_edit.text, _suit)
	if error != OK:
		_lobby_status.text = "Could not open port %d (%s). Pick another port." % [port, error_string(error)]
		_lobby_status.add_theme_color_override(&"font_color", WARN)
	else:
		_lobby_status.text = "LOBBY OPEN on port %d  -  waiting for players" % port
		_lobby_status.add_theme_color_override(&"font_color", TEAL)
	_refresh()


func _on_primary() -> void:
	match page:
		Page.HOST:
			if NetworkManager.mode == NetworkManager.Mode.HOST:
				NetworkManager.start_contract()
			else:
				_open_lobby()
		Page.JOIN:
			if NetworkManager.mode == NetworkManager.Mode.CLIENT:
				return
			var address := _address_edit.text.strip_edges()
			if address.is_empty():
				address = "127.0.0.1"
			var port := _read_port()
			var error := NetworkManager.join_game(address, port, _name_edit.text, _suit)
			if error != OK:
				_lobby_status.text = "Could not start a connection to %s:%d (%s)." % [address, port, error_string(error)]
				_lobby_status.add_theme_color_override(&"font_color", WARN)
			else:
				_lobby_status.text = "CONNECTING to %s:%d ..." % [address, port]
				_lobby_status.add_theme_color_override(&"font_color", GOLD)
			_refresh()


func _on_joined() -> void:
	_lobby_status.text = "CONNECTED  -  waiting for the host to start the contract"
	_lobby_status.add_theme_color_override(&"font_color", TEAL)
	_refresh()


func _on_connection_failed(reason: String) -> void:
	_lobby_status.text = "%s  Check the address and port, and that the host's lobby is open." % reason
	_lobby_status.add_theme_color_override(&"font_color", WARN)
	_refresh()


func _on_session_closed(reason: String) -> void:
	_lobby_status.text = reason
	_lobby_status.add_theme_color_override(&"font_color", WARN)
	_refresh()


func _on_identity_changed(_text: String = "") -> void:
	if NetworkManager.mode != NetworkManager.Mode.SOLO or page == Page.TITLE:
		NetworkManager.set_identity(_name_edit.text, _suit)
	_refresh()


func _on_suit_picked(index: int) -> void:
	_suit = index
	_on_identity_changed()


func _on_port_committed(_text: String = "") -> void:
	if page == Page.HOST and _read_port() != NetworkManager.port:
		_open_lobby()


func _read_port() -> int:
	var port := _port_edit.text.strip_edges().to_int()
	if port < 1024 or port > 65535:
		port = NetworkManager.DEFAULT_PORT
		_port_edit.text = str(port)
	return port


## Redraws everything that depends on the session: suit picker, roster, the main button.
func _refresh() -> void:
	if _panel == null:
		return
	for i in _suit_buttons.size():
		_suit_buttons[i].set_pressed_no_signal(i == _suit)
	var ids := NetworkManager.get_ids()
	var hosting := NetworkManager.mode == NetworkManager.Mode.HOST
	var joined := NetworkManager.mode == NetworkManager.Mode.CLIENT and not ids.is_empty()
	var connecting := NetworkManager.mode == NetworkManager.Mode.CLIENT and ids.is_empty()
	var listed := hosting or joined
	_roster_title.text = "CONNECTED PLAYERS  %d / %d" % [ids.size() if listed else 0, NetworkManager.MAX_PLAYERS]
	for seat in _roster_rows.size():
		var row := _roster_rows[seat]
		if listed and seat < ids.size():
			var id := ids[seat]
			var tags := PackedStringArray()
			if id == 1:
				tags.append("HOST")
			if id == NetworkManager.local_id():
				tags.append("YOU")
			var suit := NetworkManager.get_player_suit(id)
			row.text = "%d   %s   %s%s" % [seat + 1, NetworkManager.get_player_name(id), NetworkManager.SUIT_NAMES[suit],
					("   (%s)" % ", ".join(tags)) if not tags.is_empty() else ""]
			row.add_theme_color_override(&"font_color", SUIT_SWATCHES[suit].lightened(0.35))
		else:
			row.text = "%d   - open seat -" % (seat + 1)
			row.add_theme_color_override(&"font_color", Color(DIM, 0.6))
	match page:
		Page.HOST:
			_primary.text = "START CONTRACT" if hosting else "OPEN LOBBY"
			_primary.disabled = false
		Page.JOIN:
			_primary.text = "CONNECTED" if joined else ("CONNECTING..." if connecting else "CONNECT")
			_primary.disabled = joined or connecting
	_address_edit.editable = not (joined or connecting)
	_port_edit.editable = not (joined or connecting)


# --- Layout --------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	# Darkness pooled on the left, where the type sits; the site stays clear on the right.
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.42, 1.0])
	fade.colors = PackedColorArray([Color(0.0, 0.0, 0.0, 0.86), Color(0.0, 0.0, 0.0, 0.5), Color(0.0, 0.0, 0.0, 0.0)])
	var ramp := GradientTexture2D.new()
	ramp.gradient = fade
	ramp.width = 256
	ramp.height = 4
	var shade := TextureRect.new()
	shade.texture = ramp
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.anchor_right = 0.7
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(shade)

	var column := VBoxContainer.new()
	column.name = "Title"
	column.anchor_top = 0.5
	column.anchor_bottom = 0.5
	column.offset_left = 72.0
	column.offset_right = 460.0
	column.offset_top = -250.0
	column.offset_bottom = 250.0
	column.add_theme_constant_override(&"separation", 10)
	root.add_child(column)
	column.add_child(_label("ECTO-LOGISTICS  //  FIELD TERMINAL", 12, DIM))
	var title := _label("BIND &\nDELIVER", 68, INK)
	title.add_theme_constant_override(&"line_spacing", -14)
	column.add_child(title)
	var rule := ColorRect.new()
	rule.color = ACCENT
	rule.custom_minimum_size = Vector2(0.0, 4.0)
	column.add_child(rule)
	column.add_child(_label("Break in. Bind the demon. Shove it in the van.", 15, DIM))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, 14.0)
	column.add_child(gap)
	for entry: Array in [["solo", "PLAY SOLO", ACCENT, _on_solo], ["host", "HOST CO-OP", STEEL, _on_host],
			["join", "JOIN CO-OP", STEEL, _on_join], ["quit", "QUIT", Color(0.12, 0.13, 0.14), _on_quit]]:
		var button := _button(str(entry[1]), entry[2] as Color)
		button.pressed.connect(entry[3] as Callable)
		column.add_child(button)
		_menu_buttons[str(entry[0])] = button
	_status = _label("", 13, WARN)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	var foot := _label("SOLO: one exorcist, no backup.\nCO-OP: 2-4 players, LAN or direct IP. No bots, ever.", 11, Color(DIM, 0.75))
	column.add_child(foot)
	(_menu_buttons["solo"] as Button).grab_focus()

	_build_panel(root)


## The lobby card on the right: identity, connection details, roster and the big button.
func _build_panel(root: Control) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = ACCENT
	style.border_width_left = 4
	style.set_corner_radius_all(4)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
	style.shadow_size = 20
	style.content_margin_left = 26.0
	style.content_margin_right = 24.0
	style.content_margin_top = 20.0
	style.content_margin_bottom = 22.0
	_panel = PanelContainer.new()
	_panel.name = "Lobby"
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -520.0
	_panel.offset_right = -64.0
	_panel.offset_top = -270.0
	_panel.offset_bottom = 270.0
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.add_theme_stylebox_override(&"panel", style)
	root.add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 9)
	_panel.add_child(column)

	_panel_title = _label("HOST CO-OP", 26, INK)
	column.add_child(_panel_title)
	_local_ip = _label("LOCAL IP   %s" % "   ".join(NetworkManager.get_local_addresses()), 13, TEAL)
	_local_ip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_local_ip)

	_address_edit = _edit("127.0.0.1", 40)
	_address_row = _field(column, "HOST IP ADDRESS", _address_edit)
	_port_edit = _edit(str(NetworkManager.DEFAULT_PORT), 5)
	_port_edit.text_submitted.connect(_on_port_committed)
	_port_edit.focus_exited.connect(_on_port_committed)
	_field(column, "PORT", _port_edit)
	_name_edit = _edit(NetworkManager.local_name, NetworkManager.NAME_LIMIT)
	_name_edit.text_submitted.connect(_on_identity_changed)
	_name_edit.focus_exited.connect(_on_identity_changed)
	_field(column, "PLAYER NAME", _name_edit)

	var suits := HBoxContainer.new()
	suits.add_theme_constant_override(&"separation", 6)
	var group := ButtonGroup.new()
	for i in NetworkManager.SUIT_NAMES.size():
		var pick := _button(NetworkManager.SUIT_NAMES[i], SUIT_SWATCHES[i].darkened(0.35))
		pick.toggle_mode = true
		pick.button_group = group
		pick.custom_minimum_size = Vector2(0.0, 34.0)
		pick.add_theme_font_size_override(&"font_size", 12)
		var chosen := StyleBoxFlat.new()
		chosen.bg_color = SUIT_SWATCHES[i]
		chosen.set_corner_radius_all(3)
		chosen.set_border_width_all(2)
		chosen.border_color = INK
		pick.add_theme_stylebox_override(&"pressed", chosen)
		pick.pressed.connect(_on_suit_picked.bind(i))
		suits.add_child(pick)
		_suit_buttons.append(pick)
	_field(column, "HAZMAT SUIT COLOUR", suits)

	var rule := ColorRect.new()
	rule.color = Color(DIM, 0.3)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	column.add_child(rule)
	_roster_title = _label("CONNECTED PLAYERS  0 / 4", 11, DIM)
	column.add_child(_roster_title)
	for seat in NetworkManager.MAX_PLAYERS:
		var row := _label("", 15, INK)
		column.add_child(row)
		_roster_rows.append(row)
	_lobby_status = _label("", 12, TEAL)
	_lobby_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lobby_status.custom_minimum_size = Vector2(0.0, 34.0)
	column.add_child(_lobby_status)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override(&"separation", 12)
	column.add_child(buttons)
	_primary = _button("START CONTRACT", ACCENT)
	_primary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_primary.size_flags_stretch_ratio = 2.0
	_primary.pressed.connect(_on_primary)
	buttons.add_child(_primary)
	_back = _button("BACK", STEEL)
	_back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_back.pressed.connect(_on_back)
	buttons.add_child(_back)


## A captioned row; returns the row so the caller can hide it.
func _field(parent: Control, caption: String, control: Control) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override(&"separation", 3)
	row.add_child(_label(caption, 10, DIM))
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	parent.add_child(row)
	return row


func _edit(text: String, max_length: int) -> LineEdit:
	var edit := LineEdit.new()
	edit.text = text
	edit.max_length = max_length
	edit.custom_minimum_size = Vector2(0.0, 34.0)
	edit.add_theme_font_size_override(&"font_size", 15)
	edit.add_theme_color_override(&"font_color", INK)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	box.border_color = Color(DIM, 0.4)
	box.set_border_width_all(1)
	box.set_corner_radius_all(3)
	box.content_margin_left = 10.0
	box.content_margin_right = 10.0
	edit.add_theme_stylebox_override(&"normal", box)
	var lit := box.duplicate() as StyleBoxFlat
	lit.border_color = ACCENT
	edit.add_theme_stylebox_override(&"focus", lit)
	return edit


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


func _button(text: String, color: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 46.0)
	button.add_theme_font_size_override(&"font_size", 17)
	button.add_theme_color_override(&"font_color", INK)
	button.add_theme_color_override(&"font_disabled_color", Color(INK, 0.45))
	for state: Array in [["normal", 0.0], ["hover", 0.18], ["pressed", -0.2], ["disabled", -0.45], ["focus", 0.0]]:
		var style := StyleBoxFlat.new()
		var shade: float = state[1]
		style.bg_color = color.lightened(shade) if shade >= 0.0 else color.darkened(-shade)
		style.set_corner_radius_all(3)
		style.content_margin_left = 14.0
		style.content_margin_right = 14.0
		if state[0] == "focus":
			style.draw_center = false
			style.set_border_width_all(2)
			style.border_color = GOLD
		button.add_theme_stylebox_override(StringName(state[0]), style)
	return button
