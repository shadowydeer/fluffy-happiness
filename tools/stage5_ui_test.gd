extends SceneTree
## Headless Stage 5 regression for the HUD, the report card and the field shop screen.
##   godot --headless --fixed-fps 60 --path . -s tools/stage5_ui_test.gd
## Belt:   slot 4 (the salt jar) and its charge count, which follows GameState's pool.
## Demon:  the status strip names the archetype once the demon is found, for all three,
##         and stays a plain DEMON for the classic one.
## Hints:  the bottom-right key hints on their dark backdrop; M and G in the F1 list.
## Card:   the payout's TARGET line with its hazard bonus, the failure card's, and
##         OPEN FIELD SHOP on both.
## Shop:   the screen against a stand-in shop (rows, live bank, BUY, a denial, Esc / F,
##         keyboard focus, layout in both languages) and then, once the real ShopManager
##         has a catalogue, against that one too.
## Exits 0 when every check passes, 1 otherwise.

const SCUTTLER := 0
const BRUTE := 1
const POLTERGEIST := 2
const CLASSIC := 3
const RUNNING := 0
const BACKDROP := Color(0.05, 0.06, 0.08, 0.72)
const WARN := Color(0.95, 0.27, 0.15)
const SLOT_ICON := "res://scripts/GadgetSlotIcon.gd"
const SHOP_UI := "res://scripts/ShopUI.gd"

var _main: Node
var _state: Node
var _player: CharacterBody3D
var _gadgets: Node
var _demon: Node3D
var _brain: Node
var _hud: Node
var _contracts: Node
var _archetypes: GDScript
var _failures := 0
var _closes := 0


## What the shop screen talks to, with a small fixed catalogue and a record of the orders.
class FakeShop extends Node:
	signal purchased(item: StringName, peer_id: int)
	signal purchase_denied(item: StringName, reason: String)

	const ITEM_IDS: Array[StringName] = [&"taser", &"lasso", &"tape", &"salt", &"injector"]
	const COSTS := {&"taser": 400, &"lasso": 350, &"tape": 300, &"salt": 250, &"injector": 200}
	const TITLES := {&"taser": "OVERCLOCKED TASER", &"lasso": "REINFORCED HOLY LASSO", &"tape": "TURBO DUCT TAPE",
			&"salt": "SALT GRENADE PACK", &"injector": "ADRENALINE AUTO-INJECTOR"}
	const TOPS := {&"taser": 2, &"lasso": 2, &"tape": 2, &"salt": 4, &"injector": 0}

	var state: Node
	var levels := {&"taser": 0, &"lasso": 0, &"tape": 2, &"salt": 1, &"injector": 0}
	## Answers like the unfinished stub: no catalogue at all.
	var bare := false
	var requests: Array[StringName] = []
	var opened := 0

	func get_item(id: StringName) -> Dictionary:
		if bare:
			return {}
		return {"title": TITLES[id], "desc": "What the %s does." % id, "stats": "+1 %s" % id, "max": TOPS[id]}

	func get_level(id: StringName) -> int:
		return int(levels[id])

	func get_cost(id: StringName) -> int:
		return -1 if bare or (int(TOPS[id]) > 0 and int(levels[id]) >= int(TOPS[id])) else int(COSTS[id])

	func can_buy(id: StringName) -> bool:
		var cost := get_cost(id)
		return cost >= 0 and cost <= int(state.get("bank_cash"))

	func request_buy(id: StringName) -> void:
		requests.append(id)

	func open_ui() -> void:
		opened += 1

	func close_ui() -> void:
		pass

	func is_ui_open() -> bool:
		return false


func _initialize() -> void:
	_run()


func _check(label: String, ok: bool, detail: String = "") -> void:
	print("%s  %s%s" % ["PASS" if ok else "FAIL", label, ("  (" + detail + ")") if not detail.is_empty() else ""])
	if not ok:
		_failures += 1


func _frames(count: int) -> void:
	for i in count:
		await physics_frame


func _tap(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	root.push_input(event)


func _action(action: StringName) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	root.push_input(event)


func _on_closed() -> void:
	_closes += 1


## Picks up the demon on site (a new one after every archetype change) and keeps it quiet.
func _bind_demon() -> void:
	_demon = _main.get("demon")
	_brain = _demon.get_node("AI")
	_brain.set("passive", true)


func _money(amount: int) -> String:
	var digits := str(amount)
	var grouped := ""
	while digits.length() > 3:
		grouped = "," + digits.substr(digits.length() - 3) + grouped
		digits = digits.substr(0, digits.length() - 3)
	return "$" + digits + grouped


## True when `control` lies wholly inside the window.
func _on_screen(control: Control) -> bool:
	return root.get_visible_rect().grow(1.0).encloses(control.get_global_rect())


func _rect(control: Control) -> String:
	var rect := control.get_global_rect()
	return "%d,%d %dx%d in %dx%d" % [rect.position.x, rect.position.y, rect.size.x, rect.size.y, root.get_visible_rect().size.x, root.get_visible_rect().size.y]


func _run() -> void:
	_state = root.get_node("GameState")
	_archetypes = load("res://scripts/DemonArchetypes.gd") as GDScript
	# The first contract's demon is pinned, so the walk through the archetypes starts from a known one.
	_state.set("archetype_lock", BRUTE)
	_main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	# The site builds itself on the first frame after it enters the tree.
	await _frames(3)
	_player = _main.get("player")
	_gadgets = _player.get("gadgets")
	_hud = _main.get("hud")
	_contracts = _main.get("contracts")
	_bind_demon()
	(_main.get("possession") as Node).set("cooldown_left", 9999.0)
	await _frames(60)

	await _test_belt()
	await _test_archetypes()
	await _test_hints()
	await _test_card()
	await _test_shop_screen()
	await _test_languages()
	await _test_real_shop()

	print("RESULT %s (%d failed)" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(0 if _failures == 0 else 1)


# --- 1: the belt's fourth slot ----------------------------------------------------------

func _test_belt() -> void:
	var slot := _hud.call("get_gadget_slot", 3) as Control
	_check("HUD belt has a fourth drawn slot, keyed 4", slot != null and String(slot.name) == "GadgetSlot4" and int(slot.get("kind")) == 4
			and (slot.get_script() as Script).resource_path == SLOT_ICON)
	if slot == null:
		return
	_check("it also answers to its key number", _hud.call("get_gadget_slot", 4) == slot and _hud.call("get_gadget_slot", 5) == null)
	var old_ok := true
	for i in 3:
		var other := _hud.call("get_gadget_slot", i) as Control
		if other == null or int(other.get("kind")) != i + 1 or int(other.get("count")) >= 0:
			old_ok = false
	_check("slots 1-3 are where they were, without a count", old_ok)
	var pool := int(_state.get("salt_charges"))
	_check("the contract's free starter grenade shows on the badge", pool >= 1 and int(slot.get("count")) == pool, "pool %d, badge %d" % [pool, int(slot.get("count"))])
	_state.call("add_salt", 2)
	_check("add_salt(2): the badge follows", int(slot.get("count")) == pool + 2 and int(_state.get("salt_charges")) == pool + 2, "badge %d" % int(slot.get("count")))
	_state.call("add_salt", 10)
	_check("the pool and the badge stop at 4", int(slot.get("count")) == 4 and int(_state.get("salt_charges")) == 4)
	var thrown := 0
	while _state.call("use_salt") and thrown < 10:
		thrown += 1
	_check("use_salt drains it one at a time down to 0", thrown == 4 and int(slot.get("count")) == 0 and int(_state.get("salt_charges")) == 0, "%d thrown, badge %d" % [thrown, int(slot.get("count"))])
	_state.call("add_salt", 1)
	_check("and one more jar brings the badge back to 1", int(slot.get("count")) == 1)
	await _frames(2)
	_check("slot 4 is dark while the hands are empty", int(_gadgets.get("slot")) == 0 and slot.get("active") == false)
	# The belt itself gains the salt grenade from the shop side: light the slot when it is there.
	var slots: Dictionary = (_gadgets.get_script() as Script).get_script_constant_map().get("Slot", {})
	if slots.has("SALT"):
		_gadgets.call("select", int(slots["SALT"]))
		await _frames(30)
		_check("key 4: slot 4 lights up, the others do not", int(_gadgets.get("slot")) == 4 and slot.get("active") == true
				and (_hud.call("get_gadget_slot", 0) as Control).get("active") == false)
		_gadgets.call("holster")
		await _frames(30)
		_check("holstered: slot 4 goes dark again", slot.get("active") == false)
	else:
		print("SKIP  the belt has no SALT slot yet: lighting slot 4 was not exercised")


# --- 2: the archetype on the demon's status strip ------------------------------------------

func _test_archetypes() -> void:
	_check("the first contract's demon is the pinned BRUTE", int(_state.get("demon_archetype")) == BRUTE)
	_check("nothing is named before the demon is found", _hud.call("is_demon_status_visible") == false and str(_hud.call("get_archetype_text")) == "")
	var tints: Array[Color] = []
	for step: Array in [[BRUTE, "DEMON // BRUTE"], [SCUTTLER, "DEMON // SCUTTLER"], [POLTERGEIST, "DEMON // POLTERGEIST"]]:
		var kind: int = step[0]
		if kind != BRUTE:
			# The M test key: the next archetype, awake on the dais and not yet found.
			_main.call("cycle_archetype")
			await _frames(3)
			_bind_demon()
			_check("M: the next demon is the %s, and the strip folds away until it is found" % str(step[1]).get_slice(" // ", 1),
					int(_state.get("demon_archetype")) == kind and _hud.call("is_demon_status_visible") == false and str(_hud.call("get_archetype_text")) == "",
					"archetype %d, '%s'" % [int(_state.get("demon_archetype")), str(_hud.call("get_archetype_text"))])
		# Found the way gameplay finds it: the brain's own `discovered` signal.
		_brain.call("_discover")
		await _frames(2)
		var caption := _hud.get("_demon_caption") as Label
		var tint := caption.get_theme_color(&"font_color")
		var look: Dictionary = _archetypes.call("profile", kind)
		var eye: Color = look["eye_color"]
		var stripe := (_hud.get("_demon_style") as StyleBoxFlat).border_color
		_check("found: the strip reads %s" % step[1], _hud.call("is_demon_status_visible") == true and str(_hud.call("get_archetype_text")) == step[1], str(_hud.call("get_archetype_text")))
		_check("  in its own colours (eye-coloured text, glow-coloured stripe)", Vector3(tint.r - eye.r, tint.g - eye.g, tint.b - eye.b).length() < 0.4
				and stripe.is_equal_approx(look["glow_color"]), "text %s, eye %s, stripe %s" % [tint, eye, stripe])
		tints.append(tint)
	_check("the three archetypes read differently at a glance", not tints[0].is_equal_approx(tints[1]) and not tints[1].is_equal_approx(tints[2]) and not tints[0].is_equal_approx(tints[2]))

	# The regression tools' classic demon has no name of its own.
	_state.call("set_archetype", CLASSIC)
	_contracts.call("bind_demon", _main.call("respawn_demon", 0))
	await _frames(3)
	_bind_demon()
	_brain.call("_discover")
	await _frames(2)
	_check("the classic demon is just DEMON", str(_hud.call("get_archetype_text")) == "DEMON", str(_hud.call("get_archetype_text")))
	# A change of archetype is picked up the moment GameState announces it.
	_state.call("set_archetype", BRUTE)
	_check("archetype_changed renames the strip at once", str(_hud.call("get_archetype_text")) == "DEMON // BRUTE", str(_hud.call("get_archetype_text")))


# --- 3: key hints on their backdrop ---------------------------------------------------------

func _test_hints() -> void:
	var panel := _hud.call("get_hint_backdrop") as PanelContainer
	var box := (panel.get_theme_stylebox(&"panel") as StyleBoxFlat) if panel else null
	_check("the key hints have a backdrop panel", panel != null and box != null and String(panel.name) == "HintBackdrop")
	if box == null:
		return
	_check("it is the dark semi-transparent Color(0.05, 0.06, 0.08, 0.72)", box.bg_color.is_equal_approx(BACKDROP), str(box.bg_color))
	_check("rounded, with a thin border and padding", box.corner_radius_top_left >= 4 and box.corner_radius_bottom_right >= 4 and box.border_width_left == 1
			and box.border_color.a > 0.0 and box.border_color.a < 0.5 and box.content_margin_left >= 8.0 and box.content_margin_top >= 6.0)
	var hint := _hud.get("_hint") as Label
	var gadget_hint := _hud.get("_gadget_hint") as Label
	_check("the controls and the gadget's own hint both sit on it", panel.visible and panel.is_ancestor_of(hint) and panel.is_ancestor_of(gadget_hint)
			and hint.is_visible_in_tree() and str(_hud.call("get_gadget_hint")).contains("[LMB / E] Grab"), str(_hud.call("get_gadget_hint")))
	var rect := panel.get_global_rect()
	var window := root.get_visible_rect().size
	_check("in the bottom right corner, wholly on screen", _on_screen(panel) and rect.end.x > window.x - 40.0 and rect.end.y > window.y - 40.0 and rect.size.x > 200.0, _rect(panel))
	_check("the controls list 4 for the salt grenade", hint.text.contains("4 salt grenade") and hint.text.contains("1 lasso") and hint.text.contains("ESC menu"))
	var tall := rect.size.y

	_tap(KEY_F1)
	await _frames(2)
	var keys := str((_hud.get("_debug_hint") as Label).text)
	var debug_panel := _hud.get("_debug_panel") as PanelContainer
	_check("F1 lists M (next archetype) and G (test cash) with the old keys", keys.contains("M   next demon archetype") and keys.contains("G   +$1000 test cash")
			and keys.contains("K   stun") and keys.contains("P   summon"))
	_check("the test-key list has the same backdrop", debug_panel != null and debug_panel.is_ancestor_of(_hud.get("_debug_hint") as Label)
			and (debug_panel.get_theme_stylebox(&"panel") as StyleBoxFlat).bg_color.is_equal_approx(BACKDROP) and _on_screen(debug_panel), _rect(debug_panel))
	_tap(KEY_F1)
	await _frames(2)
	_check("F1 folds it away again", str((_hud.get("_debug_hint") as Label).text) == "F1  test keys")

	# The opening lines still fade after a while; the gadget's hint keeps its backdrop.
	_hud.set("_hint_left", 0.05)
	await _frames(12)
	_check("the controls fade out as before, and the backdrop shrinks to the gadget hint", not hint.visible and panel.visible and gadget_hint.is_visible_in_tree()
			and panel.size.y < tall and _on_screen(panel), "%.0f px tall, was %.0f" % [panel.size.y, tall])


# --- 4: the report card -----------------------------------------------------------------------

func _test_card() -> void:
	var card := _contracts.get("summary") as Node
	var next := card.call("get_next_button") as Button
	var explore := card.call("get_explore_button") as Button
	var shop_button := card.call("get_shop_button") as Button
	_state.call("set_archetype", BRUTE)
	var payout: Dictionary = _contracts.call("compute_payout")
	payout["bank"] = int(_state.get("bank_cash"))
	_check("the payout knows its target", str(payout.get("archetype_name", "")) == "BRUTE" and int(payout.get("archetype_bonus", 0)) == 300, str(payout))
	card.call("show_summary", payout, true)
	await _frames(2)
	var lines: PackedStringArray = card.call("get_line_texts")
	var at := lines.find("TARGET: BRUTE")
	_check("payout card: TARGET: BRUTE  +$300", at >= 0 and at + 1 < lines.size() and lines[at + 1] == "+$300", " | ".join(lines))
	_check("the other line items are still there", lines.has("Base capture bounty") and lines.has("Speed bonus") and at == lines.find("Base capture bounty") + 2)
	_check("NEXT CONTRACT and KEEP EXPLORING are untouched", next.text == "NEXT CONTRACT" and not next.disabled and explore.text == "KEEP EXPLORING" and card.call("is_showing") == true)
	_check("OPEN FIELD SHOP is on the payout card", shop_button != null and shop_button.text == "OPEN FIELD SHOP" and shop_button.is_visible_in_tree() and not shop_button.disabled)
	_check("the card still fits the screen", _on_screen(card.get_node("Root").find_child("Card", true, false) as Control))

	# The button asks whatever shop the site has for its screen.
	var site_shop: Variant = _state.get("shop")
	var fake := FakeShop.new()
	fake.state = _state
	root.add_child(fake)
	_state.set("shop", fake)
	shop_button.pressed.emit()
	_check("pressing it calls the shop's open_ui()", fake.opened == 1)

	card.call("show_summary", {"contract": 7, "base": 500, "total": 500}, false)
	await _frames(2)
	lines = card.call("get_line_texts")
	var stray := false
	for line in lines:
		if line.begins_with("TARGET"):
			stray = true
	_check("an old payout without the archetype fields just has no TARGET line", not stray and lines.has("Base capture bounty"), " | ".join(lines))
	_check("a client still waits for the host, and may shop meanwhile", next.disabled and next.text == "WAITING FOR HOST..." and shop_button.is_visible_in_tree())

	card.call("show_failure", {"contract": 413, "time": 61.0, "lines": ["Paperwork."], "total": 0}, true)
	await _frames(2)
	lines = card.call("get_line_texts")
	_check("failure card names the one that got away", card.call("is_failure") == true and lines.size() >= 2 and lines[0] == "TARGET AT LARGE: BRUTE" and lines.has("-  Paperwork."), " | ".join(lines))
	_check("and offers the shop under RETRY CONTRACT / MAIN MENU", next.text == "RETRY CONTRACT" and explore.text == "MAIN MENU" and shop_button.is_visible_in_tree())
	shop_button.pressed.emit()
	_check("which opens from there too", fake.opened == 2)

	_state.set("shop", null)
	card.call("show_failure", {"contract": 413, "lines": []}, true)
	_check("no shop on site: no shop button", not shop_button.visible)
	_state.set("shop", site_shop)
	card.call("hide_summary")
	fake.queue_free()
	await _frames(2)


# --- 5: the shop screen, against a stand-in shop -----------------------------------------------

func _test_shop_screen() -> void:
	var fake := FakeShop.new()
	fake.state = _state
	root.add_child(fake)
	var ui := (load("res://scenes/ShopUI.tscn") as PackedScene).instantiate() as CanvasLayer
	root.add_child(ui)
	ui.call("setup", fake)
	ui.connect(&"closed", _on_closed)
	var pause := _main.get("pause_menu") as Node
	_check("the screen starts closed, above the report card (20) and under the pause menu (30)", ui.call("is_open") == false and ui.layer > 20 and ui.layer < 30, "layer %d" % ui.layer)

	_state.call("spend_cash", int(_state.get("bank_cash")))
	ui.call("open")
	await _frames(3)
	var taser := ui.call("get_buy_button", &"taser") as Button
	var close := ui.call("get_close_button") as Button
	_check("open(): five rows, one per item", ui.call("is_open") == true and int(ui.call("get_row_count")) == 5 and taser != null and ui.call("get_buy_button", &"injector") != null)
	_check("a row shows the item's title, description and stats", ui.call("get_row_text", &"taser", "title") == "OVERCLOCKED TASER"
			and ui.call("get_row_text", &"taser", "desc") == "What the taser does." and ui.call("get_row_text", &"taser", "stats") == "+1 taser")
	_check("levels as LV 0 / 2, salt as jars, the injector as single use", ui.call("get_row_text", &"taser", "level") == "LV 0 / 2"
			and ui.call("get_row_text", &"salt", "level") == "1 / 4 JARS" and ui.call("get_row_text", &"injector", "level") == "SINGLE USE",
			"%s | %s | %s" % [ui.call("get_row_text", &"taser", "level"), ui.call("get_row_text", &"salt", "level"), ui.call("get_row_text", &"injector", "level")])
	_check("prices, and MAXED for a finished upgrade", ui.call("get_row_text", &"taser", "price") == "$400" and ui.call("get_row_text", &"tape", "price") == "MAXED"
			and (ui.call("get_buy_button", &"tape") as Button).disabled)
	var none := true
	for id: StringName in FakeShop.ITEM_IDS:
		if not (ui.call("get_buy_button", id) as Button).disabled:
			none = false
	_check("an empty bank: $0, every BUY greyed out, CLOSE holds the focus", ui.call("get_bank_text") == "$0" and none and root.gui_get_focus_owner() == close)
	_check("the terminal fits the screen", _on_screen(ui.call("get_card") as Control), _rect(ui.call("get_card") as Control))

	_state.call("add_cash", 1000)
	await _frames(2)
	_check("the bank is live: $1,000, and BUY wakes up for what it covers", ui.call("get_bank_text") == "$1,000" and not taser.disabled
			and not (ui.call("get_buy_button", &"injector") as Button).disabled and (ui.call("get_buy_button", &"tape") as Button).disabled)
	ui.call("close")
	_check("close() shuts it and says so once", ui.call("is_open") == false and _closes == 1)
	ui.call("close")
	_check("closing a closed screen says nothing", _closes == 1)
	ui.call("open")
	await _frames(3)
	_check("opened with money in the bank, the first BUY has the focus", root.gui_get_focus_owner() == taser)

	taser.pressed.emit()
	_check("BUY asks the shop: request_buy(taser)", fake.requests.size() == 1 and fake.requests[0] == &"taser", str(fake.requests))
	fake.levels[&"taser"] = 1
	_state.call("spend_cash", 400)
	fake.purchased.emit(&"taser", 1)
	await _frames(2)
	_check("purchased: a confirmation on the status line, the row and the bank move on", ui.call("get_status_text") == "PURCHASED: OVERCLOCKED TASER"
			and ui.call("get_row_text", &"taser", "level") == "LV 1 / 2" and ui.call("get_bank_text") == "$600", str(ui.call("get_status_text")))
	fake.purchase_denied.emit(&"lasso", "NOT ENOUGH CASH")
	_check("denied: the reason, in the warning colour", ui.call("get_status_text") == "NOT ENOUGH CASH" and (ui.call("get_status_color") as Color).is_equal_approx(WARN),
			"%s %s" % [ui.call("get_status_text"), ui.call("get_status_color")])

	# Keys meant for the terminal stop at the terminal.
	var kind := int(_state.get("demon_archetype"))
	_tap(KEY_M)
	await _frames(3)
	_check("a test key pressed at the terminal does not reach the site", int(_state.get("demon_archetype")) == kind and ui.call("is_open") == true)
	_action(&"ui_cancel")
	await _frames(3)
	_check("Esc closes the shop, emits closed, and the pause menu stays shut", ui.call("is_open") == false and _closes == 2 and pause.call("is_open") == false and paused == false)
	ui.call("open")
	await _frames(2)
	_action(&"interact")
	await _frames(3)
	_check("F closes it as well", ui.call("is_open") == false and _closes == 3)
	ui.call("open")
	await _frames(2)
	close.pressed.emit()
	_check("and so does CLOSE", ui.call("is_open") == false and _closes == 4)

	# Opened over the payout card, Esc belongs to the shop: the card must not take it for KEEP EXPLORING.
	var card := _contracts.get("summary") as Node
	card.call("show_summary", {"contract": 413, "base": 500, "total": 500}, true)
	ui.call("open")
	await _frames(2)
	_tap(KEY_ESCAPE)
	await _frames(3)
	_check("over the payout card, Esc shuts only the shop", ui.call("is_open") == false and card.call("is_showing") == true and int(_contracts.get("phase")) == RUNNING
			and pause.call("is_open") == false, "phase %d" % int(_contracts.get("phase")))
	await _frames(2)
	_check("and the card takes the keyboard back", root.gui_get_focus_owner() == card.call("get_next_button"))
	card.call("hide_summary")

	# The unfinished ShopManager has no catalogue: the screen still builds, by id.
	fake.bare = true
	ui.call("refresh")
	_check("a shop with nothing to say still gets five rows, titled by id", int(ui.call("get_row_count")) == 5 and ui.call("get_row_text", &"taser", "title") == "TASER"
			and ui.call("get_row_text", &"injector", "title") == "INJECTOR" and taser.disabled, str(ui.call("get_row_text", &"taser", "title")))
	ui.queue_free()

	# setup() before the screen enters the tree, and no shop at all, both build.
	fake.bare = false
	var early := (load("res://scenes/ShopUI.tscn") as PackedScene).instantiate() as CanvasLayer
	early.call("setup", fake)
	root.add_child(early)
	var orphan := (load("res://scenes/ShopUI.tscn") as PackedScene).instantiate() as CanvasLayer
	root.add_child(orphan)
	orphan.call("open")
	await _frames(2)
	_check("setup() before _ready, or no shop at all: five rows either way", int(early.call("get_row_count")) == 5 and early.call("get_row_text", &"lasso", "title") == "REINFORCED HOLY LASSO"
			and int(orphan.call("get_row_count")) == 5 and (orphan.call("get_buy_button", &"taser") as Button).disabled)
	early.queue_free()
	orphan.queue_free()
	fake.queue_free()
	await _frames(2)


# --- 6: both languages fit ---------------------------------------------------------------------

func _test_languages() -> void:
	var loc := root.get_node_or_null("Loc")
	if loc == null or not loc.has_method("set_language"):
		print("SKIP  no Loc autoload: the Russian layout was not checked")
		return
	var before := str(loc.get("language"))
	var fake := FakeShop.new()
	fake.state = _state
	root.add_child(fake)
	var ui := (load("res://scenes/ShopUI.tscn") as PackedScene).instantiate() as CanvasLayer
	root.add_child(ui)
	ui.call("setup", fake)
	ui.call("open")
	_hud.set("_hint_left", 16.0)
	var slot := _hud.call("get_gadget_slot", 3) as Control
	for code: String in ["ru", "en"]:
		loc.call("set_language", code)
		await _frames(6)
		var panel := _hud.call("get_hint_backdrop") as PanelContainer
		var strip := _hud.get("_demon_panel") as Control
		var banner := (_hud.get("_title") as Control).get_parent().get_parent() as Control
		_check("%s: hints, objective banner, demon strip and shop terminal all stay on screen" % code.to_upper(), _on_screen(panel) and (_hud.get("_hint") as Label).is_visible_in_tree()
				and _on_screen(banner) and _on_screen(strip) and _on_screen(ui.call("get_card") as Control),
				"hints %s | banner %s | strip %s | shop %s" % [_rect(panel), _rect(banner), _rect(strip), _rect(ui.call("get_card") as Control)])
		_check("%s: the source strings stay English underneath" % code.to_upper(), str(_hud.call("get_archetype_text")) == "DEMON // BRUTE" and ui.call("get_row_text", &"taser", "price") == "$400"
				and int(slot.get("count")) == int(_state.get("salt_charges")))
	loc.call("set_language", before)
	ui.queue_free()
	fake.queue_free()
	await _frames(2)


# --- 7: the real ShopManager, when it is finished -------------------------------------------------

func _find_shop_ui(node: Node) -> Node:
	var script := node.get_script() as Script
	if script and script.resource_path == SHOP_UI and not node.is_queued_for_deletion():
		return node
	for child in node.get_children():
		var found := _find_shop_ui(child)
		if found:
			return found
	return null


func _test_real_shop() -> void:
	var shop := _main.get("shop") as Node
	var item: Variant = shop.call("get_item", &"taser") if shop and shop.has_method("get_item") else null
	if not (item is Dictionary) or (item as Dictionary).is_empty():
		print("SKIP  ShopManager has no catalogue yet: the screen was checked against the stand-in shop only")
		return
	var pause := _main.get("pause_menu") as Node
	_state.call("add_cash", 2000)
	shop.call("open_ui")
	await _frames(5)
	var ui := _find_shop_ui(root)
	_check("ShopManager puts the screen up", ui != null and shop.call("is_ui_open") == true and ui.call("is_open") == true)
	if ui == null:
		return
	var cost := int(shop.call("get_cost", &"taser"))
	var level := int(shop.call("get_level", &"taser"))
	var top := int((item as Dictionary).get("max", 0))
	var bank := int(_state.get("bank_cash"))
	_check("its five items are listed with their real titles and prices", int(ui.call("get_row_count")) == 5 and ui.call("get_row_text", &"taser", "title") == str((item as Dictionary)["title"])
			and ui.call("get_row_text", &"taser", "price") == _money(cost) and ui.call("get_row_text", &"taser", "level") == "LV %d / %d" % [level, top]
			and ui.call("get_bank_text") == _money(bank), "%s | %s | %s" % [ui.call("get_row_text", &"taser", "title"), ui.call("get_row_text", &"taser", "price"), ui.call("get_row_text", &"taser", "level")])
	_check("the terminal fits the screen with the real catalogue", _on_screen(ui.call("get_card") as Control), _rect(ui.call("get_card") as Control))
	var buy := ui.call("get_buy_button", &"taser") as Button
	_check("with $2,000 in the bank the taser can be bought", not buy.disabled and shop.call("can_buy", &"taser") == true)
	buy.pressed.emit()
	await _frames(5)
	_check("BUY goes through the host: level up, bank down, screen redrawn", int(shop.call("get_level", &"taser")) == level + 1 and int(_state.get("bank_cash")) == bank - cost
			and ui.call("get_row_text", &"taser", "level") == "LV %d / %d" % [level + 1, top] and ui.call("get_bank_text") == _money(bank - cost),
			"level %d, bank %d, '%s'" % [int(shop.call("get_level", &"taser")), int(_state.get("bank_cash")), ui.call("get_status_text")])
	_check("and the status line confirms it", str(ui.call("get_status_text")).begins_with("PURCHASED: "), str(ui.call("get_status_text")))
	_state.call("spend_cash", int(_state.get("bank_cash")))
	await _frames(2)
	(ui.call("get_buy_button", &"lasso") as Button).pressed.emit()
	await _frames(5)
	_check("broke: BUY is greyed out and nothing is sold", (ui.call("get_buy_button", &"lasso") as Button).disabled and int(shop.call("get_level", &"lasso")) == 0)
	_action(&"ui_cancel")
	await _frames(5)
	_check("Esc closes the real screen and the pause menu stays shut", shop.call("is_ui_open") == false and ui.call("is_open") == false and pause.call("is_open") == false and paused == false)

	# From the payout card and back.
	var card := _contracts.get("summary") as Node
	card.call("show_summary", {"contract": 413, "base": 500, "total": 500}, true)
	(card.call("get_shop_button") as Button).pressed.emit()
	await _frames(5)
	_check("OPEN FIELD SHOP on the card opens the real screen", shop.call("is_ui_open") == true)
	_tap(KEY_ESCAPE)
	await _frames(5)
	_check("Esc there shuts the shop and leaves the card up", shop.call("is_ui_open") == false and card.call("is_showing") == true and int(_contracts.get("phase")) == RUNNING)
	card.call("hide_summary")
	_player.set("controls_locked", false)
