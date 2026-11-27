extends CanvasLayer
## The field shop screen (scenes/ShopUI.tscn): the van terminal's requisitions list.
##
## Built in code like the rest of the UI. ShopManager owns one instance and shows it
## for this machine's player: one row per ShopManager.ITEM_IDS entry (what it is, what
## it does, level or stock, price, BUY), the crew's bank, and a status line with the
## answer to the last order. The screen only asks (`request_buy`): the host decides,
## and the result comes back through GameState and the shop's signals, which redraw it.
## CLOSE, Esc or F shuts it. ShopManager, not this screen, looks after the mouse and
## the player's controls.

signal closed

const INK := Color(0.93, 0.95, 0.92)
const DIM := Color(0.60, 0.67, 0.68)
const GOLD := Color(1.0, 0.78, 0.3)
const ACCENT := Color(0.95, 0.42, 0.08)
const TEAL := Color(0.25, 0.92, 0.82)
const WARN := Color(0.95, 0.27, 0.15)
const PANEL := Color(0.025, 0.032, 0.04, 0.96)
const ROW := Color(0.06, 0.072, 0.085, 0.94)
const ITEM_SALT := &"salt"
## Listed when the screen is built before a shop is attached.
const DEFAULT_ITEMS: Array[StringName] = [&"taser", &"lasso", &"tape", ITEM_SALT, &"injector"]
const READY_LINE := "TERMINAL READY  -  gear is paid for out of the crew's bank"

var _shop: Node
var _root: Control
var _card: PanelContainer
var _bank: Label
var _list: VBoxContainer
var _status: Label
var _close: Button
var _rows: Array[Row] = []


## The widgets of one item for sale.
class Row:
	var id: StringName
	var frame: StyleBoxFlat
	var title: Label
	var desc: Label
	var stats: Label
	var level: Label
	var pips: HBoxContainer
	var price: Label
	var buy: Button


func _ready() -> void:
	layer = 25
	_build()
	GameState.bank_changed.connect(_on_bank_changed)
	GameState.loadout_changed.connect(refresh)
	_fill_rows()
	refresh()


## Attaches the ShopManager this screen sells for. Safe before or after it enters the tree.
func setup(shop: Node) -> void:
	if shop == _shop:
		return
	if is_instance_valid(_shop):
		if _shop.is_connected(&"purchased", _on_purchased):
			_shop.disconnect(&"purchased", _on_purchased)
		if _shop.is_connected(&"purchase_denied", _on_purchase_denied):
			_shop.disconnect(&"purchase_denied", _on_purchase_denied)
	_shop = shop
	if is_instance_valid(shop):
		if shop.has_signal(&"purchased"):
			shop.connect(&"purchased", _on_purchased)
		if shop.has_signal(&"purchase_denied"):
			shop.connect(&"purchase_denied", _on_purchase_denied)
	if _list:
		_fill_rows()
		refresh()


func is_open() -> bool:
	return visible


func open() -> void:
	if visible:
		return
	visible = true
	_say(READY_LINE, DIM)
	refresh()
	_focus_first()
	SoundManager.play_ui(&"ui_click")


func close() -> void:
	if not visible:
		return
	visible = false
	SoundManager.play_ui(&"ui_click", -4.0)
	closed.emit()


## Re-reads prices, levels and the bank.
func refresh() -> void:
	if _bank == null:
		return
	_bank.text = _money(GameState.bank_cash)
	var live := is_instance_valid(_shop)
	for row in _rows:
		var item: Dictionary = {}
		if live and _shop.has_method(&"get_item"):
			var data: Variant = _shop.call(&"get_item", row.id)
			if data is Dictionary:
				item = data
		var top := int(item.get("max", 0))
		var level := int(_shop.call(&"get_level", row.id)) if live and _shop.has_method(&"get_level") else 0
		var cost := int(_shop.call(&"get_cost", row.id)) if live and _shop.has_method(&"get_cost") else -1
		var can := bool(_shop.call(&"can_buy", row.id)) if live and _shop.has_method(&"can_buy") else false
		row.title.text = str(item.get("title", String(row.id).to_upper()))
		row.desc.text = str(item.get("desc", ""))
		row.desc.visible = not row.desc.text.is_empty()
		row.stats.text = str(item.get("stats", ""))
		row.stats.visible = not row.stats.text.is_empty()
		if top <= 0:
			row.level.text = "SINGLE USE" if cost >= 0 else ""
		elif row.id == ITEM_SALT:
			row.level.text = "%d / %d JARS" % [level, top]
		else:
			row.level.text = "LV %d / %d" % [level, top]
		row.level.visible = not row.level.text.is_empty()
		_set_pips(row, level, top, GOLD if row.id == ITEM_SALT else TEAL)
		if cost >= 0:
			row.price.text = _money(cost)
			row.price.add_theme_color_override(&"font_color", GOLD if cost <= GameState.bank_cash else WARN)
		else:
			row.price.text = "MAXED" if not item.is_empty() else "--"
			row.price.add_theme_color_override(&"font_color", DIM)
		row.buy.disabled = not can
		row.frame.border_color = Color(ACCENT, 0.8) if can else Color(DIM, 0.3)
		row.title.add_theme_color_override(&"font_color", INK if can or cost < 0 else Color(INK, 0.75))


func get_row_count() -> int:
	return _rows.size()


## The BUY button of `item`, null when it is not listed.
func get_buy_button(item: StringName) -> Button:
	var row := _row_of(item)
	return row.buy if row else null


## One text of an item's row: "title", "desc", "stats", "level" or "price".
func get_row_text(item: StringName, field: String) -> String:
	var row := _row_of(item)
	var label: Variant = row.get(field) if row else null
	return (label as Label).text if label is Label else ""


func get_close_button() -> Button:
	return _close


func get_bank_text() -> String:
	return _bank.text


func get_status_text() -> String:
	return _status.text


func get_status_color() -> Color:
	return _status.get_theme_color(&"font_color")


## The terminal's panel, for layout checks.
func get_card() -> Control:
	return _card


func _input(event: InputEvent) -> void:
	if not visible:
		return
	# Taken before the GUI, the report card and the pause menu get a look: while the
	# terminal is up, Esc and F mean "close this" and nothing else.
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"interact"):
		get_viewport().set_input_as_handled()
		close()


func _unhandled_input(event: InputEvent) -> void:
	# A key no button wanted must not fall through to the site behind the terminal.
	if visible and (event is InputEventKey or event is InputEventJoypadButton):
		get_viewport().set_input_as_handled()


func _on_bank_changed(_total: int) -> void:
	refresh()


func _on_buy_pressed(item: StringName) -> void:
	if not is_instance_valid(_shop) or not _shop.has_method(&"request_buy"):
		return
	SoundManager.play_ui(&"ui_click")
	_shop.call(&"request_buy", item)


func _on_purchased(item: StringName, _peer_id: int) -> void:
	refresh()
	if visible:
		var row := _row_of(item)
		_say("PURCHASED: %s" % (row.title.text if row else String(item).to_upper()), TEAL)
		SoundManager.play_ui(&"ui_buy")


func _on_purchase_denied(_item: StringName, reason: String) -> void:
	refresh()
	if visible:
		_say(reason if not reason.is_empty() else "PURCHASE DENIED", WARN)
		SoundManager.play_ui(&"ui_deny")


func _say(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override(&"font_color", color)


## Keyboard and gamepad start on the first thing that can be bought, else on CLOSE.
func _focus_first() -> void:
	for row in _rows:
		if not row.buy.disabled:
			row.buy.grab_focus()
			return
	_close.grab_focus()


func _row_of(item: StringName) -> Row:
	for row in _rows:
		if row.id == item:
			return row
	return null


func _item_ids() -> Array:
	var ids: Variant = _shop.get(&"ITEM_IDS") if is_instance_valid(_shop) else null
	if ids is Array and not (ids as Array).is_empty():
		return ids
	return DEFAULT_ITEMS


# --- Layout ------------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.6)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(centre)

	# A rugged field terminal: near-black case, thin orange frame, heavy top edge.
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = Color(ACCENT, 0.9)
	style.set_border_width_all(1)
	style.border_width_top = 4
	style.set_corner_radius_all(4)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.6)
	style.shadow_size = 24
	style.content_margin_left = 26.0
	style.content_margin_right = 26.0
	style.content_margin_top = 18.0
	style.content_margin_bottom = 18.0
	_card = PanelContainer.new()
	_card.name = "Card"
	_card.custom_minimum_size = Vector2(840.0, 0.0)
	_card.add_theme_stylebox_override(&"panel", style)
	centre.add_child(_card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 8)
	_card.add_child(column)

	var head := HBoxContainer.new()
	head.add_theme_constant_override(&"separation", 20)
	column.add_child(head)
	var name_column := VBoxContainer.new()
	name_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_column.add_theme_constant_override(&"separation", 0)
	head.add_child(name_column)
	name_column.add_child(_label("VAN TERMINAL  //  REQUISITIONS", 11, DIM, Loc.mono_font()))
	var title := _label("FIELD SHOP", 30, ACCENT, Loc.header_font())
	title.name = "Title"
	name_column.add_child(title)
	var bank_column := VBoxContainer.new()
	bank_column.add_theme_constant_override(&"separation", 0)
	head.add_child(bank_column)
	var bank_caption := _label("CREW BANK", 11, DIM, Loc.mono_font())
	bank_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bank_column.add_child(bank_caption)
	_bank = _label("$0", 28, GOLD, Loc.header_font())
	_bank.name = "Bank"
	_bank.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bank_column.add_child(_bank)
	column.add_child(_rule())

	_list = VBoxContainer.new()
	_list.name = "Rows"
	_list.add_theme_constant_override(&"separation", 6)
	column.add_child(_list)
	column.add_child(_rule())

	var answer := HBoxContainer.new()
	answer.add_theme_constant_override(&"separation", 8)
	column.add_child(answer)
	answer.add_child(_label(">", 13, ACCENT, Loc.mono_font()))
	_status = _label(READY_LINE, 13, DIM, Loc.mono_font())
	_status.name = "Status"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	answer.add_child(_status)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override(&"separation", 16)
	column.add_child(foot)
	var keys := _label("[ENTER] buy     [ESC] / [F] close", 11, Color(DIM, 0.8), Loc.mono_font())
	keys.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keys.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	foot.add_child(keys)
	_close = _button("CLOSE", Color(0.2, 0.24, 0.27))
	_close.name = "Close"
	_close.custom_minimum_size = Vector2(150.0, 38.0)
	_close.pressed.connect(close)
	foot.add_child(_close)


## One row per item the attached shop lists; rebuilt when the shop changes.
func _fill_rows() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	_rows.clear()
	for entry: Variant in _item_ids():
		_add_row(StringName(str(entry)))


func _add_row(id: StringName) -> void:
	var row := Row.new()
	row.id = id
	row.frame = StyleBoxFlat.new()
	row.frame.bg_color = ROW
	row.frame.border_color = Color(DIM, 0.3)
	row.frame.border_width_left = 3
	row.frame.set_corner_radius_all(3)
	row.frame.content_margin_left = 14.0
	row.frame.content_margin_right = 12.0
	row.frame.content_margin_top = 7.0
	row.frame.content_margin_bottom = 8.0
	var panel := PanelContainer.new()
	panel.name = "Item_%s" % id
	panel.add_theme_stylebox_override(&"panel", row.frame)
	_list.add_child(panel)
	var line := HBoxContainer.new()
	line.add_theme_constant_override(&"separation", 16)
	panel.add_child(line)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override(&"separation", 1)
	line.add_child(text)
	row.title = _label("", 18, INK, Loc.header_font())
	row.title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(row.title)
	row.desc = _label("", 12, DIM, null)
	row.desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(row.desc)
	row.stats = _label("", 12, TEAL, Loc.mono_font())
	row.stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(row.stats)

	var stock := VBoxContainer.new()
	stock.custom_minimum_size = Vector2(104.0, 0.0)
	stock.alignment = BoxContainer.ALIGNMENT_CENTER
	stock.add_theme_constant_override(&"separation", 5)
	line.add_child(stock)
	row.level = _label("", 12, DIM, Loc.mono_font())
	row.level.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stock.add_child(row.level)
	row.pips = HBoxContainer.new()
	row.pips.alignment = BoxContainer.ALIGNMENT_CENTER
	row.pips.add_theme_constant_override(&"separation", 4)
	stock.add_child(row.pips)

	row.price = _label("", 20, GOLD, Loc.header_font())
	row.price.custom_minimum_size = Vector2(84.0, 0.0)
	row.price.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.price.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(row.price)

	row.buy = _button("BUY", ACCENT)
	row.buy.name = "Buy"
	row.buy.custom_minimum_size = Vector2(104.0, 38.0)
	row.buy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.buy.pressed.connect(_on_buy_pressed.bind(id))
	line.add_child(row.buy)
	_rows.append(row)


## `top` little lamps under the level text, the first `level` of them lit.
func _set_pips(row: Row, level: int, top: int, color: Color) -> void:
	row.pips.visible = top > 0
	while row.pips.get_child_count() > maxi(top, 0):
		var extra := row.pips.get_child(row.pips.get_child_count() - 1)
		row.pips.remove_child(extra)
		extra.queue_free()
	while row.pips.get_child_count() < top:
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(2)
		var pip := Panel.new()
		pip.custom_minimum_size = Vector2(18.0, 6.0)
		pip.add_theme_stylebox_override(&"panel", style)
		row.pips.add_child(pip)
	for i in row.pips.get_child_count():
		var lamp := (row.pips.get_child(i) as Panel).get_theme_stylebox(&"panel") as StyleBoxFlat
		lamp.bg_color = color if i < level else Color(0.0, 0.0, 0.0, 0.65)


# --- Widgets -----------------------------------------------------------------------

func _money(amount: int) -> String:
	var digits := str(absi(amount))
	var grouped := ""
	while digits.length() > 3:
		grouped = "," + digits.substr(digits.length() - 3) + grouped
		digits = digits.substr(0, digits.length() - 3)
	return ("-$" if amount < 0 else "$") + digits + grouped


func _rule() -> ColorRect:
	var rule := ColorRect.new()
	rule.color = Color(ACCENT, 0.28)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	return rule


func _label(text: String, font_size: int, color: Color, font: Font) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	if font:
		label.add_theme_font_override(&"font", font)
	return label


func _button(text: String, color: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override(&"font_size", 16)
	button.add_theme_color_override(&"font_color", INK)
	button.add_theme_color_override(&"font_disabled_color", Color(DIM, 0.55))
	if Loc.header_font():
		button.add_theme_font_override(&"font", Loc.header_font())
	for state: Array in [["normal", 0.0], ["hover", 0.18], ["pressed", -0.2], ["focus", 0.0], ["disabled", 0.0]]:
		var style := StyleBoxFlat.new()
		var shade: float = state[1]
		style.bg_color = color.lightened(shade) if shade >= 0.0 else color.darkened(-shade)
		style.set_corner_radius_all(3)
		style.content_margin_left = 12.0
		style.content_margin_right = 12.0
		if state[0] == "focus":
			style.draw_center = false
			style.set_border_width_all(2)
			style.border_color = GOLD
		elif state[0] == "disabled":
			style.bg_color = Color(0.1, 0.115, 0.13)
		button.add_theme_stylebox_override(StringName(state[0]), style)
	return button
