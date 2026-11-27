extends CanvasLayer
## Mission-complete card: a dark tactical read-out of the contract's payout.
##
## Built in code like the HUD. `show_summary()` takes the dictionary from
## ContractManager.compute_payout() (plus "bank"); the total counts up, and the
## two buttons emit `next_pressed` / `explore_pressed` (Enter and Esc do the same).
## The whole screen swallows mouse clicks while the card is up.

signal next_pressed
signal explore_pressed

const INK := Color(0.93, 0.95, 0.92)
const DIM := Color(0.60, 0.67, 0.68)
const GOLD := Color(1.0, 0.78, 0.3)
const ACCENT := Color(0.95, 0.42, 0.08)
const TEAL := Color(0.25, 0.92, 0.82)
const WARN := Color(0.95, 0.27, 0.15)
const PANEL := Color(0.025, 0.032, 0.04, 0.95)

var _root: Control
var _header: Label
var _sub: Label
var _rows: VBoxContainer
var _total: Label
var _bank: Label
var _next: Button
var _explore: Button
var _target_total := 0
var _shown_total := 0.0


func _ready() -> void:
	layer = 20
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.62)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(centre)

	var card_style := StyleBoxFlat.new()
	card_style.bg_color = PANEL
	card_style.border_color = Color(DIM, 0.35)
	card_style.set_border_width_all(1)
	card_style.border_width_top = 4
	card_style.border_color = GOLD
	card_style.set_corner_radius_all(4)
	card_style.shadow_color = Color(0.0, 0.0, 0.0, 0.6)
	card_style.shadow_size = 24
	card_style.content_margin_left = 34.0
	card_style.content_margin_right = 34.0
	card_style.content_margin_top = 26.0
	card_style.content_margin_bottom = 26.0
	var card := PanelContainer.new()
	card.name = "Card"
	card.custom_minimum_size = Vector2(560.0, 0.0)
	card.add_theme_stylebox_override(&"panel", card_style)
	centre.add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 10)
	card.add_child(column)

	column.add_child(_label("EXTRACTION REPORT", 12, DIM))
	_header = _label("", 30, GOLD)
	column.add_child(_header)
	_sub = _label("", 14, DIM)
	column.add_child(_sub)
	column.add_child(_rule())
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override(&"separation", 8)
	column.add_child(_rows)
	column.add_child(_rule())
	var total_row := _row(column, "TOTAL PAYOUT", 18, INK)
	_total = _label("$0", 30, GOLD)
	total_row.add_child(_total)
	var bank_row := _row(column, "BANK", 14, DIM)
	_bank = _label("$0", 18, TEAL)
	bank_row.add_child(_bank)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0.0, 8.0)
	column.add_child(spacer)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override(&"separation", 14)
	column.add_child(buttons)
	_next = _button("NEXT CONTRACT", ACCENT)
	_next.pressed.connect(func() -> void: next_pressed.emit())
	buttons.add_child(_next)
	_explore = _button("KEEP EXPLORING", Color(0.2, 0.24, 0.27))
	_explore.pressed.connect(func() -> void: explore_pressed.emit())
	buttons.add_child(_explore)
	var keys := _label("[ENTER] next contract     [ESC] keep exploring", 11, Color(DIM, 0.8))
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(keys)


func is_showing() -> bool:
	return _root.visible


func get_next_button() -> Button:
	return _next


func get_explore_button() -> Button:
	return _explore


func show_summary(payout: Dictionary) -> void:
	_header.text = "CONTRACT #%04d COMPLETE" % int(payout.get("contract", 0))
	var seconds := int(payout.get("time", 0.0))
	_sub.text = "%s   //   TIME %02d:%02d   //   DEMON EXTRACTED" % [GameState.SITE_NAME, int(seconds / 60.0), seconds % 60]
	for child in _rows.get_children():
		child.queue_free()
	_line("Base capture bounty", int(payout.get("base", 0)), INK)
	_line("Speed bonus", int(payout.get("speed", 0)), INK)
	var bind := int(payout.get("bind_level", 0))
	_line("Gift-wrapped!  Binding bonus (3/3)" if bind >= 3 else "Binding bonus (%d/3)" % bind, int(payout.get("bind", 0)), GOLD if bind >= 3 else INK)
	var care := int(payout.get("care", 0))
	_line(str(payout.get("care_note", "Property")), care, INK if care > 0 else WARN)
	_target_total = int(payout.get("total", 0))
	_shown_total = 0.0
	_total.text = "$0"
	_bank.text = _money(int(payout.get("bank", GameState.bank_cash)))
	_root.visible = true
	_next.grab_focus()


func hide_summary() -> void:
	_root.visible = false


func _process(delta: float) -> void:
	if not _root.visible or is_equal_approx(_shown_total, float(_target_total)):
		return
	_shown_total = move_toward(_shown_total, float(_target_total), delta * maxf(400.0, _target_total * 1.4))
	_total.text = _money(int(_shown_total))


func _input(event: InputEvent) -> void:
	if not _root.visible:
		return
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		explore_pressed.emit()


# --- Widgets -----------------------------------------------------------------------

func _money(amount: int) -> String:
	var digits := str(absi(amount))
	var grouped := ""
	while digits.length() > 3:
		grouped = "," + digits.substr(digits.length() - 3) + grouped
		digits = digits.substr(0, digits.length() - 3)
	return ("-$" if amount < 0 else "$") + digits + grouped


func _line(caption: String, amount: int, color: Color) -> void:
	var row := _row(_rows, caption, 16, color)
	var value := _label(("+" + _money(amount)) if amount > 0 else "--", 16, color if amount > 0 else DIM)
	row.add_child(value)


## A row with a caption that takes the slack; the caller adds the right-hand value.
func _row(parent: Control, caption: String, font_size: int, color: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 16)
	parent.add_child(row)
	var label := _label(caption, font_size, color)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	return row


func _rule() -> ColorRect:
	var rule := ColorRect.new()
	rule.color = Color(DIM, 0.3)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	return rule


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	return label


func _button(text: String, color: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, 44.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
			style.border_color = GOLD
		button.add_theme_stylebox_override(StringName(state[0]), style)
	return button
