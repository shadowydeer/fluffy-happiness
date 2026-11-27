extends SceneTree
## Headless Stage 5 regression for localisation and typography (the `Loc` autoload).
##   godot --headless --fixed-fps 60 --path . -s tools/stage5_loc_test.gd
## Fonts:      the three OFL faces load from res://assets/fonts/, cover both alphabets
##             (Ёё included) and the HUD's symbols, and the UI face is the default
##             for every Control without disturbing font-size overrides.
## Switch:     EN is the default; RU re-renders Labels, Buttons and Label3Ds at once
##             while `.text` keeps the English source; the choice is saved and read back.
## Copy:       the product owner's exact Russian strings, patterns with nested
##             arguments, plurals, cases, multi-part HUD lines; every objective,
##             demon state, archetype and suit colour has a translation.
## Menus:      the title screen's EN | RU switch and its four buttons in Russian, the
##             lobby card inside 1280x720; the pause menu's switch and the MASTER /
##             SFX / AMBIENT sliders driving SoundManager both ways.
## The language in user://settings.cfg is put back the way it was found.
## Exits 0 when every check passes, 1 otherwise.

const VIEW := Vector2(1280.0, 720.0)
const RUSSIAN_ALPHABET := "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя"
const UI_SYMBOLS := "$%#№&.,:;!?()[]<>/|+-=*'\"«»—–·…×"
## English source -> the exact Russian the product owner asked for.
const REQUIRED := {
	"Enter the cursed house & locate the demon": "ПРОНИКНИ В ДОМ И НАЙДИ ДЕМОНА",
	"Subdue the demon! [2: Holy Taser]": "СКРУТИТЬ ДЕМОНА! [2: Тазер]",
	"Bind with Duct Tape [3] & haul to the van": "ЗАМОТАЙ СКОТЧЕМ [3] И ТАЩИ В ФУРГОН!",
	"Close the van's rear doors [F] to extract!": "ЗАКРОЙ ДВЕРИ ФУРГОНА [F]!",
	"EXORCISE VERA! Tase or drag to Salt Circle!": "ДРУГ ОДЕРЖИМ! БЕЙ ТАЗЕРОМ ИЛИ ТАЩИ В КРУГ СОЛИ!",
	"CONTRACT COMPLETE!": "КОНТРАКТ ВЫПОЛНЕН!",
	"PLAY SOLO": "ИГРАТЬ СОЛО",
	"HOST CO-OP": "СОЗДАТЬ КООП",
	"JOIN CO-OP": "ВОЙТИ В КООП",
	"QUIT": "ВЫХОД",
	"SCUTTLER": "ПОЛЗУН",
	"BRUTE": "ГРОМИЛА",
	"POLTERGEIST": "ПОЛТЕРГЕЙСТ",
	"DEMON // BRUTE": "ДЕМОН // ГРОМИЛА",
	"DEMON // SCUTTLER": "ДЕМОН // ПОЛЗУН",
}
## Formats, nesting, plurals, cases and the HUD's multi-part lines.
const COMPOSED := {
	"DONE: Subdue the demon! [2: Holy Taser]": "ГОТОВО: СКРУТИТЬ ДЕМОНА! [2: Тазер]",
	"> Enter the cursed house & locate the demon": "> ПРОНИКНИ В ДОМ И НАЙДИ ДЕМОНА",
	"CONTRACT #0413 // 13 HOLLOW LANE": "КОНТРАКТ №0413 // ГЛУХОЙ ПЕРЕУЛОК, 13",
	"> CONTRACT COMPLETE!  [N] next contract": "> КОНТРАКТ ВЫПОЛНЕН!  [N] следующий контракт",
	"[E] Grab Nightstand": "[E] Взять тумбочку",
	"[LMB / E] GRAB DEMON (ARM)": "[ЛКМ / E] СХВАТИТЬ ДЕМОНА ЗА РУКУ",
	"LASSO ON KEROSENE LANTERN": "ЛАССО ДЕРЖИТ КЕРОСИНОВУЮ ЛАМПУ",
	"[F] Close rear doors": "[F] Закрыть задние двери",
	"VERA   DOWN  -  hold [E]": "VERA   В НОКАУТЕ  —  зажми [E]",
	"TASER OVERHEATED  -  2.3 s": "ТАЗЕР ПЕРЕГРЕЛСЯ  —  2.3 с",
	"BIND 3/3  -  GIFT-WRAPPED!": "ПУТЫ 3/3  —  ПОДАРОЧНАЯ УПАКОВКА!",
	"1 exorcists down at once. Nobody left to do the reviving.": "В нокауте одновременно 1 экзорцист. Поднимать их было уже некому.",
	"3 exorcists down at once. Nobody left to do the reviving.": "В нокауте одновременно 3 экзорциста. Поднимать их было уже некому.",
	"12 exorcists down at once. Nobody left to do the reviving.": "В нокауте одновременно 12 экзорцистов. Поднимать их было уже некому.",
	"F1  hide test keys\nK   stun / wake the demon": "F1  скрыть тестовые клавиши\nK   оглушить / разбудить демона",
	"1   VERA   ORANGE   (HOST, YOU)": "1   VERA   ОРАНЖ   (ХОСТ, ТЫ)",
}
const UNTOUCHED: Array[String] = ["", "01:23", "$1,250", "3 / 4", "100%", "Zzyzx quorble", "192.168.0.12"]

var _loc: Node
var _state: Node
var _sound: Node
var _failures := 0
var _switches: Array[String] = []
var _original_language := "en"


func _initialize() -> void:
	_run()


func _check(label: String, ok: bool, detail: String = "") -> void:
	print("%s  %s%s" % ["PASS" if ok else "FAIL", label, ("  (" + detail + ")") if not detail.is_empty() else ""])
	if not ok:
		_failures += 1


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _t(text: String) -> String:
	return str(_loc.call("t", text))


## What a Label or Button puts on screen: its text through the engine's own auto-translation.
func _shown(control: Node) -> String:
	return str(control.call("atr", str(control.get("text"))))


func _run() -> void:
	# Autoloads become ready on the first frame.
	await _frames(2)
	_loc = root.get_node("Loc")
	_state = root.get_node("GameState")
	_sound = root.get_node("SoundManager")
	_original_language = str(_state.call("get_setting", "ui", "language", "en"))
	var boot_language := str(_loc.get("language"))
	_loc.set("persist", false)
	_loc.connect(&"language_changed", func(code: String) -> void: _switches.append(code))

	_test_fonts()
	await _test_switch(boot_language)
	_test_persistence()
	_test_copy()
	await _test_lobby()
	await _test_pause_menu()

	_loc.set("persist", false)
	_loc.call("set_language", "en")
	_state.call("set_setting", "ui", "language", _original_language)
	_check("the saved language is left as it was found", str(_state.call("get_setting", "ui", "language", "en")) == _original_language, _original_language)
	print("RESULT %s (%d failed)" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(0 if _failures == 0 else 1)


# --- 1: fonts -----------------------------------------------------------------------------

func _test_fonts() -> void:
	var faces := {"header_font": _loc.get("HEADER_FACE"), "ui_font": _loc.get("UI_FACE"), "mono_font": _loc.get("MONO_FACE")}
	for getter: String in faces:
		var font := _loc.call(getter) as Font
		var face := str(faces[getter])
		_check("%s() is a font" % getter, font != null)
		if font == null:
			continue
		var on_disk := bool(_loc.call("has_font_file", face))
		_check("%s is installed from %s" % [face, str(_loc.get("FONT_DIR"))], on_disk and font is FontFile,
				"%s / %s%s" % [font.get_font_name(), font.get_class(), "" if on_disk else " - file missing, fallback in use"])
		_check("%s draws the whole Russian alphabet, Ёё included" % face, str(_loc.call("missing_glyphs", font, RUSSIAN_ALPHABET)).is_empty(),
				str(_loc.call("missing_glyphs", font, RUSSIAN_ALPHABET)))
		_check("%s draws Latin, digits and the UI's symbols" % face, str(_loc.call("missing_glyphs", font)).is_empty() \
				and str(_loc.call("missing_glyphs", font, UI_SYMBOLS)).is_empty(), str(_loc.call("missing_glyphs", font)) + str(_loc.call("missing_glyphs", font, UI_SYMBOLS)))
	var ui := _loc.call("ui_font") as Font
	_check("arrows come through the fallback chain", str(_loc.call("missing_glyphs", ui, "←→↑↓")).is_empty(), str(_loc.call("missing_glyphs", ui, "←→↑↓")))
	_check("the three faces are different fonts", _loc.call("header_font") != ui and _loc.call("mono_font") != ui)

	# Under a CanvasLayer, the way the HUD and the menus hang: no themed parent to inherit from.
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var plain := Label.new()
	plain.text = "Щука"
	layer.add_child(plain)
	var sized := Label.new()
	sized.text = "Щука"
	sized.add_theme_font_size_override(&"font_size", 40)
	layer.add_child(sized)
	var button := Button.new()
	layer.add_child(button)
	_check("the UI face is the default font of every Control", plain.get_theme_font(&"font") == ui and button.get_theme_font(&"font") == ui)
	_check("explicit font sizes still apply", sized.get_theme_font_size(&"font_size") == 40 and sized.get_minimum_size().y > plain.get_minimum_size().y * 1.8,
			"%.0f vs %.0f px" % [sized.get_minimum_size().y, plain.get_minimum_size().y])
	var headed := Label.new()
	layer.add_child(headed)
	_loc.call("style_header", headed)
	_check("style_header() applies the display face", headed.get_theme_font(&"font") == _loc.call("header_font"))
	layer.free()


# --- 2: the live switch -------------------------------------------------------------------

func _test_switch(boot_language: String) -> void:
	var saved := ConfigFile.new()
	saved.load("user://settings.cfg")
	if saved.has_section_key("ui", "language"):
		_check("start-up language is the saved one", boot_language == str(saved.get_value("ui", "language")), boot_language)
	else:
		_check("start-up language defaults to English", boot_language == "en", boot_language)
	_loc.call("set_language", "en")
	_switches.clear()
	_check("English is the first language and the locale follows", (_loc.get("LANGUAGES") as Array)[0] == "en" \
			and str(_loc.get("language")) == "en" and TranslationServer.get_locale().begins_with("en"), TranslationServer.get_locale())

	var layer := CanvasLayer.new()
	root.add_child(layer)
	var label := Label.new()
	label.text = "PLAY SOLO"
	layer.add_child(label)
	var button := Button.new()
	button.text = "HOST CO-OP"
	layer.add_child(button)
	var sign := Label3D.new()
	sign.text = "FOR SALE"
	root.add_child(sign)
	await _frames(2)
	var english_width := button.get_minimum_size().x
	_check("in English a Label shows its source text", _shown(label) == "PLAY SOLO" and label.get_total_character_count() == 9 and _t("PLAY SOLO") == "PLAY SOLO")

	_loc.call("set_language", "ru")
	await _frames(2)
	_check("switching to RU fires language_changed(\"ru\") once", _switches == ["ru"], str(_switches))
	_check("the locale is Russian", TranslationServer.get_locale().begins_with("ru") and str(_loc.get("language")) == "ru", TranslationServer.get_locale())
	_check("the Label re-renders in Russian at once", _shown(label) == "ИГРАТЬ СОЛО" and label.get_total_character_count() == 11,
			"%s, %d characters drawn" % [_shown(label), label.get_total_character_count()])
	_check("its .text is still the English source", label.text == "PLAY SOLO" and button.text == "HOST CO-OP" and sign.text == "FOR SALE")
	_check("Buttons and Label3Ds follow", _shown(button) == "СОЗДАТЬ КООП" and not is_equal_approx(button.get_minimum_size().x, english_width) \
			and _shown(sign) == "ПРОДАЁТСЯ", "%s / %s" % [_shown(button), _shown(sign)])
	_check("Loc.t() gives the same answer for hand-drawn text", _t("PLAY SOLO") == "ИГРАТЬ СОЛО")
	label.text = "QUIT"
	await _frames(1)
	_check("text set while in Russian is translated too", _shown(label) == "ВЫХОД" and label.get_total_character_count() == 5)
	label.text = "PLAY SOLO"

	_loc.call("set_language", "ru")
	_loc.call("set_language", "de")
	_check("repeats and unknown codes are ignored", _switches == ["ru"] and str(_loc.get("language")) == "ru", str(_switches))
	_loc.call("toggle")
	await _frames(2)
	_check("toggle() goes back to English", _switches == ["ru", "en"] and str(_loc.get("language")) == "en" and TranslationServer.get_locale().begins_with("en"))
	_check("the Label is English again", _shown(label) == "PLAY SOLO" and label.get_total_character_count() == 9 and _t("PLAY SOLO") == "PLAY SOLO")

	var toggle := _loc.call("make_toggle") as Button
	layer.add_child(toggle)
	_check("make_toggle() is a compact \"EN | RU\" button that is not translated itself", toggle != null and toggle.text == "EN | RU" \
			and not toggle.can_auto_translate() and toggle.get_minimum_size().x <= 120.0)
	toggle.pressed.emit()
	_check("pressing it flips the language", str(_loc.get("language")) == "ru" and _switches == ["ru", "en", "ru"], str(_switches))
	toggle.pressed.emit()
	_check("and back", str(_loc.get("language")) == "en")
	sign.free()
	layer.free()


# --- 3: user://settings.cfg ---------------------------------------------------------------

func _test_persistence() -> void:
	_loc.call("set_language", "ru")
	_check("with persist off nothing is written", str(_state.call("get_setting", "ui", "language", "en")) == _original_language)
	_loc.call("set_language", "en")
	_loc.set("persist", true)
	_loc.call("set_language", "ru")
	var saved_ru := str(_state.call("get_setting", "ui", "language", ""))
	_loc.call("set_language", "en")
	var saved_en := str(_state.call("get_setting", "ui", "language", ""))
	_loc.set("persist", false)
	_state.call("set_setting", "ui", "language", _original_language)
	_check("the choice is saved to user://settings.cfg [ui] language", saved_ru == "ru" and saved_en == "en", "%s then %s" % [saved_ru, saved_en])


# --- 4: the Russian copy ------------------------------------------------------------------

func _test_copy() -> void:
	_loc.call("set_language", "ru")
	for source: String in REQUIRED:
		_check("required: %s" % source, _t(source) == str(REQUIRED[source]), _t(source))
	for source: String in COMPOSED:
		_check("composed: %s" % source.c_escape(), _t(source) == str(COMPOSED[source]), _t(source).c_escape())
	var untouched := true
	for source in UNTOUCHED:
		untouched = untouched and _t(source) == source
	_check("numbers, money and unknown text pass through unchanged", untouched)

	var missing := PackedStringArray()
	for step: Dictionary in _state.get("STEPS"):
		if not _loc.call("has_translation", str(step["task"])):
			missing.append(str(step["task"]))
	for suit: String in root.get_node("NetworkManager").get("SUIT_NAMES"):
		if not _loc.call("has_translation", suit):
			missing.append(suit)
	var brain := load("res://scripts/DemonAI.gd") as GDScript
	for state: String in brain.get_script_constant_map().get("STATE_NAMES", []):
		if not _loc.call("has_translation", state):
			missing.append(state)
	var ragdoll := load("res://scripts/DemonRagdoll.gd") as GDScript
	for part: String in ragdoll.get_script_constant_map().get("PART_LABELS", []):
		if not _loc.call("has_translation", part):
			missing.append(part)
	var archetypes := load("res://scripts/DemonArchetypes.gd") as GDScript
	var profiles: Dictionary = archetypes.get_script_constant_map().get("PROFILES", {})
	for kind: Variant in profiles:
		for key: String in ["title", "blurb"]:
			var text := str((profiles[kind] as Dictionary).get(key, ""))
			if not text.is_empty() and not _loc.call("has_translation", text):
				missing.append(text)
	_check("every objective, suit, demon state, limb and archetype has Russian", missing.is_empty(), ", ".join(missing))
	var translation: Object = _loc.get("_russian")
	_check("the tables are loaded", int(translation.call("get_entry_count")) > 300, "%d entries" % int(translation.call("get_entry_count")))
	_loc.call("set_language", "en")
	_check("in English Loc.t() is the identity", _t("DONE: Subdue the demon! [2: Holy Taser]") == "DONE: Subdue the demon! [2: Holy Taser]")


# --- 5: title screen and lobby ------------------------------------------------------------

func _test_lobby() -> void:
	_loc.call("set_language", "en")
	var menu := (load("res://scenes/LobbyMenu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	await _frames(4)
	var toggle := menu.call("get_language_toggle") as Button
	_check("the title screen has the EN | RU switch", toggle != null and toggle.text == "EN | RU" and toggle.is_visible_in_tree())
	if toggle == null:
		menu.free()
		return
	var corner := toggle.get_global_rect()
	_check("it sits in the top-right corner", corner.position.x > VIEW.x * 0.75 and corner.end.x <= VIEW.x and corner.position.y < 80.0, str(corner))
	var english := PackedStringArray()
	for id: String in ["solo", "host", "join", "quit"]:
		english.append(_shown(menu.call("get_menu_button", id)))
	_check("in English the buttons read PLAY SOLO / HOST CO-OP / JOIN CO-OP / QUIT", english == PackedStringArray(["PLAY SOLO", "HOST CO-OP", "JOIN CO-OP", "QUIT"]), ", ".join(english))

	toggle.pressed.emit()
	await _frames(3)
	var russian := PackedStringArray()
	var sources := PackedStringArray()
	for id: String in ["solo", "host", "join", "quit"]:
		var button := menu.call("get_menu_button", id) as Button
		russian.append(_shown(button))
		sources.append(button.text)
	_check("pressing it turns them into ИГРАТЬ СОЛО / СОЗДАТЬ КООП / ВОЙТИ В КООП / ВЫХОД",
			russian == PackedStringArray(["ИГРАТЬ СОЛО", "СОЗДАТЬ КООП", "ВОЙТИ В КООП", "ВЫХОД"]), ", ".join(russian))
	_check("their .text stays English", sources == PackedStringArray(["PLAY SOLO", "HOST CO-OP", "JOIN CO-OP", "QUIT"]))
	_check("the main buttons use the display face", (menu.call("get_menu_button", "solo") as Button).get_theme_font(&"font") == _loc.call("header_font"))

	# Both lobby pages, in Russian, have to fit the 1280x720 design size.
	for page: int in [1, 2]:
		menu.call("_show", page)
		await _frames(3)
		var problems := _layout_problems(menu.get_node("UI/Root"))
		_check("the %s page fits 1280x720 in Russian" % ("HOST" if page == 1 else "JOIN"), problems.is_empty(), "; ".join(problems))
	_check("the roster is translated where it is shown", _t("%d   - open seat -" % 2) == "2   - свободное место -" and str(menu.call("get_roster_text")).contains("- open seat -"))
	menu.call("_show", 0)
	await _frames(2)
	var title_problems := _layout_problems(menu.get_node("UI/Root"))
	_check("the title page fits 1280x720 in Russian", title_problems.is_empty(), "; ".join(title_problems))
	toggle.pressed.emit()
	await _frames(2)
	_check("the switch goes back to English", str(_loc.get("language")) == "en" and _shown(menu.call("get_menu_button", "solo")) == "PLAY SOLO")
	menu.free()
	await _frames(3)


## Visible Labels and Buttons that leave the screen or are cut short by their own box.
func _layout_problems(from: Node) -> PackedStringArray:
	var problems := PackedStringArray()
	var stack: Array[Node] = [from]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		var control := node as Control
		if control == null or not control.is_visible_in_tree() or not (control is Label or control is Button):
			continue
		if str(control.get("text")).is_empty():
			continue
		var box := control.get_global_rect()
		if box.position.x < -0.5 or box.position.y < -0.5 or box.end.x > VIEW.x + 0.5 or box.end.y > VIEW.y + 0.5:
			problems.append("%s is off screen %s" % [str(control.get("text")).c_escape(), str(box)])
		elif control is Button and not (control as Button).clip_text and control.get_minimum_size().x > control.size.x + 0.5:
			problems.append("%s is clipped" % str(control.get("text")))
	return problems


# --- 6: pause menu ------------------------------------------------------------------------

func _test_pause_menu() -> void:
	_state.set("archetype_lock", 3)
	var main := (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await _frames(30)
	var menu := main.get("pause_menu") as Node
	_check("the site has its pause menu", menu != null and menu.has_method("get_volume_slider") and menu.has_method("get_language_toggle"))
	if menu == null:
		return
	var volumes := {}
	for bus: StringName in [&"Master", &"SFX", &"Ambient"]:
		volumes[bus] = float(_sound.call("get_volume", bus))
	menu.call("open")
	await _frames(3)
	_check("it opens and freezes a solo site, as before", menu.call("is_open") == true and paused)
	var toggle := menu.call("get_language_toggle") as Button
	_check("the pause menu has the EN | RU switch", toggle != null and toggle.text == "EN | RU" and toggle.is_visible_in_tree())
	var leave := menu.call("get_leave_button") as Button
	toggle.pressed.emit()
	await _frames(2)
	_check("it works while the tree is paused", str(_loc.get("language")) == "ru" and _shown(leave) == "ГЛАВНОЕ МЕНЮ" and leave.text == "MAIN MENU", _shown(leave))

	var task := "> %s" % str((_state.get("STEPS") as Array)[0]["task"])
	var objective := _find_label(main, task)
	_check("behind it the HUD objective reads ПРОНИКНИ В ДОМ И НАЙДИ ДЕМОНА", objective != null and _shown(objective) == "> ПРОНИКНИ В ДОМ И НАЙДИ ДЕМОНА",
			_shown(objective) if objective else "no label shows '%s'" % task)

	for bus: StringName in [&"Master", &"SFX", &"Ambient"]:
		var slider := menu.call("get_volume_slider", bus) as HSlider
		_check("%s has a 0..1 slider showing the mixer's level" % bus, slider != null and slider.is_visible_in_tree() and is_zero_approx(slider.min_value) \
				and is_equal_approx(slider.max_value, 1.0) and absf(slider.value - float(volumes[bus])) < 0.011, ("%.2f vs %.2f" % [slider.value, float(volumes[bus])]) if slider else "missing")
		if slider == null:
			continue
		slider.value = 0.35
		_check("moving it sets SoundManager's %s volume" % bus, absf(float(_sound.call("get_volume", bus)) - 0.35) < 0.011, "%.2f" % float(_sound.call("get_volume", bus)))
		var readout := (slider.get_parent().get_child(slider.get_index() + 1) as Label).text
		_check("and the read-out says 35%", readout == "35%", readout)
		_sound.call("set_volume", bus, 0.8)
		_check("it follows SoundManager.volume_changed", absf(slider.value - 0.8) < 0.011, "%.2f" % slider.value)
	for bus: StringName in volumes:
		_sound.call("set_volume", bus, float(volumes[bus]))
	var problems := _layout_problems(menu)
	_check("the card fits the screen in Russian", problems.is_empty(), "; ".join(problems))

	toggle.pressed.emit()
	menu.call("close")
	await _frames(2)
	_check("it closes and the site runs again", menu.call("is_open") == false and not paused and str(_loc.get("language")) == "en")


func _find_label(from: Node, text: String) -> Label:
	var stack: Array[Node] = [from]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Label and (node as Label).text == text:
			return node
		stack.append_array(node.get_children())
	return null
