extends Node
## Live EN / RU localisation and typography (autoload: `Loc`).
##
## Source strings stay English everywhere in the code and on the wire. Russian is a
## Translation registered with the TranslationServer, so every Label, Button and
## Label3D re-renders the moment the language flips; text that is drawn by hand goes
## through `t()` and listens to `language_changed`. The choice is kept in
## user://settings.cfg. The OFL fonts under res://assets/fonts/ (full Cyrillic) are
## installed as the project-wide default, with a display face for headings.
##
## The Russian itself lives in res://autoload/loc/ (see RuTranslation.gd for how a
## string is looked up and how to add one).

signal language_changed(code: String)

const RuTranslation := preload("res://autoload/loc/RuTranslation.gd")

const LANGUAGES: Array[String] = ["en", "ru"]
const FONT_DIR := "res://assets/fonts/"
const HEADER_FACE := "Oswald-Bold"
const UI_FACE := "Inter-Medium"
const MONO_FACE := "JetBrainsMono-Medium"
const FONT_EXTENSIONS: Array[String] = ["ttf", "otf"]
const CYRILLIC := "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя"
## Everything the UI has to be able to draw in either language.
const GLYPHS := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" + CYRILLIC \
		+ ".,:;!?'\"()[]<>/|\\+-=*#%&@_$№«»—–·…×"
const SETTINGS_SECTION := "ui"
const SETTINGS_KEY := "language"

const INK := Color(0.93, 0.95, 0.92)
const DIM := Color(0.60, 0.67, 0.68)
const ACCENT := Color(0.95, 0.42, 0.08)
const PANEL := Color(0.025, 0.032, 0.04, 0.88)
const TOGGLE_CODES: Array[String] = ["EN", "|", "RU"]
const TOGGLE_FONT_SIZE := 15

var language := "en"
## Tests clear this so that flipping the language never reaches user://settings.cfg.
var persist := true

var _russian: RuTranslation
var _builtin: Font
var _header: Font
var _ui: Font
var _mono: Font


func _ready() -> void:
	_install_fonts()
	_russian = RuTranslation.new()
	TranslationServer.add_translation(_russian)
	var saved := str(GameState.get_setting(SETTINGS_SECTION, SETTINGS_KEY, LANGUAGES[0]))
	language = saved if LANGUAGES.has(saved) else LANGUAGES[0]
	# Not the system's locale: the game speaks the language its own switch says.
	TranslationServer.set_locale(language)


func _exit_tree() -> void:
	# A scripted Translation must not outlive the script engine: the server is torn down later and crashes on it.
	if _russian:
		TranslationServer.remove_translation(_russian)


## Switches language now, for every piece of text on screen, and remembers it.
func set_language(code: String) -> void:
	if code == language or not LANGUAGES.has(code):
		return
	language = code
	TranslationServer.set_locale(code)
	if persist:
		GameState.set_setting(SETTINGS_SECTION, SETTINGS_KEY, code)
	language_changed.emit(code)


## EN -> RU -> EN.
func toggle() -> void:
	set_language(LANGUAGES[posmod(LANGUAGES.find(language) + 1, LANGUAGES.size())])


## `text` (an English source string) in the current language; unknown text comes back as it is.
func t(text: String) -> String:
	if language == LANGUAGES[0] or _russian == null:
		return text
	return _russian.lookup(text)


## True when the Russian tables answer for `text` (whatever the current language is).
func has_translation(text: String) -> bool:
	return _russian != null and _russian.knows(text)


## Display face for titles and big numbers.
func header_font() -> Font:
	return _header if _header else ThemeDB.fallback_font


## Body face for the HUD and menus.
func ui_font() -> Font:
	return _ui if _ui else ThemeDB.fallback_font


## Monospaced face for the shop terminal and key hints.
func mono_font() -> Font:
	return _mono if _mono else ThemeDB.fallback_font


## Gives `control` (a Label or Button) the display face.
func style_header(control: Control) -> void:
	var font := header_font()
	if control is RichTextLabel:
		control.add_theme_font_override(&"normal_font", font)
		control.add_theme_font_override(&"bold_font", font)
		return
	control.add_theme_font_override(&"font", font)


## The characters of `text` that `font` cannot draw, even through its fallbacks ("" = all there).
func missing_glyphs(font: Font, text: String = GLYPHS) -> String:
	var missing := ""
	for i in text.length():
		if not _has_glyph(font, text.unicode_at(i), 0):
			missing += text[i]
	return missing


## True when `face` (HEADER_FACE, UI_FACE or MONO_FACE) came from res://assets/fonts/.
func has_font_file(face: String) -> bool:
	return not _font_path(face).is_empty()


## The small "EN | RU" switch for the main menu and the pause menu. It keeps itself up to date.
func make_toggle() -> Button:
	var button := Button.new()
	button.name = "LanguageToggle"
	button.text = "EN | RU"
	# The two codes are painted by `_draw_toggle`, each in its own colour.
	button.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	button.custom_minimum_size = Vector2(88.0, 32.0)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override(&"font", header_font())
	button.add_theme_font_size_override(&"font_size", TOGGLE_FONT_SIZE)
	for item: StringName in [&"font_color", &"font_hover_color", &"font_pressed_color", &"font_hover_pressed_color",
			&"font_focus_color", &"font_disabled_color"]:
		button.add_theme_color_override(item, Color(0.0, 0.0, 0.0, 0.0))
	for state: Array in [[&"normal", PANEL, 0.55], [&"hover", PANEL.lightened(0.08), 1.0], [&"pressed", PANEL.darkened(0.4), 1.0],
			[&"disabled", PANEL, 0.25], [&"focus", PANEL, 1.0]]:
		var style := StyleBoxFlat.new()
		style.bg_color = state[1]
		style.border_color = Color(ACCENT, float(state[2]))
		style.set_border_width_all(1)
		style.set_corner_radius_all(6)
		style.content_margin_left = 12.0
		style.content_margin_right = 12.0
		style.anti_aliasing = true
		if state[0] == &"focus":
			style.draw_center = false
		button.add_theme_stylebox_override(state[0], style)
	button.pressed.connect(_on_toggle_pressed)
	button.draw.connect(_draw_toggle.bind(button))
	language_changed.connect(button.queue_redraw.unbind(1))
	return button


func _on_toggle_pressed() -> void:
	toggle()
	SoundManager.play_ui(&"ui_click", -8.0)


## "EN | RU" with the language in use bright and underlined, the other one dim.
func _draw_toggle(button: Button) -> void:
	var font := header_font()
	var gap := 7.0
	var widths := PackedFloat32Array()
	var total := gap * float(TOGGLE_CODES.size() - 1)
	for code in TOGGLE_CODES:
		widths.append(font.get_string_size(code, HORIZONTAL_ALIGNMENT_LEFT, -1.0, TOGGLE_FONT_SIZE).x)
		total += widths[-1]
	var x := roundf((button.size.x - total) * 0.5)
	var baseline := roundf((button.size.y - font.get_height(TOGGLE_FONT_SIZE)) * 0.5 + font.get_ascent(TOGGLE_FONT_SIZE))
	for i in TOGGLE_CODES.size():
		var code := TOGGLE_CODES[i]
		var active := code.to_lower() == language
		var color := Color(DIM, 0.4)
		if active:
			color = INK
		elif LANGUAGES.has(code.to_lower()):
			color = Color(DIM, 0.75)
		button.draw_string(font, Vector2(x, baseline), code, HORIZONTAL_ALIGNMENT_LEFT, -1.0, TOGGLE_FONT_SIZE, color)
		if active:
			button.draw_rect(Rect2(x, baseline + 4.0, widths[i], 2.0), ACCENT)
		x += widths[i] + gap


# --- Fonts -----------------------------------------------------------------------------

## Loads the three faces and makes the UI one the default for every Control and Label3D.
func _install_fonts() -> void:
	_builtin = ThemeDB.fallback_font
	_mono = _load_face(MONO_FACE)
	_ui = _load_face(UI_FACE)
	_header = _load_face(HEADER_FACE)
	if _ui == null:
		_ui = _builtin if missing_glyphs(_builtin, CYRILLIC).is_empty() else _system_font(["Noto Sans", "DejaVu Sans", "Segoe UI", "Arial"])
	if _mono == null:
		_mono = _system_font(["JetBrains Mono", "DejaVu Sans Mono", "Consolas", "Menlo", "Courier New", "monospace"])
	if _header == null:
		# No display face on disk: the body face, drawn heavier.
		var heavy := FontVariation.new()
		heavy.base_font = _ui
		heavy.variation_embolden = 0.7
		_header = heavy
	# Symbols one face lacks (arrows, box drawing) come from the next. Never a loop.
	_chain(_mono, [_builtin])
	_chain(_ui, [_mono, _builtin])
	_chain(_header, [_ui])
	# The default theme is the one place every Control and Label3D ends up asking,
	# whatever sits between it and the root window (CanvasLayers, Node3Ds).
	ThemeDB.get_default_theme().default_font = _ui
	ThemeDB.fallback_font = _ui


func _load_face(face: String) -> Font:
	var path := _font_path(face)
	if path.is_empty():
		return null
	if _is_imported(path):
		var imported := load(path) as Font
		if imported:
			return imported
	# Downloaded but never opened in the editor: read the file as it is.
	var file := FontFile.new()
	if file.load_dynamic_font(path) != OK:
		return null
	return file


func _font_path(face: String) -> String:
	for extension in FONT_EXTENSIONS:
		var path := FONT_DIR + face + "." + extension
		if FileAccess.file_exists(path) or ResourceLoader.exists(path):
			return path
	return ""


## True when `load()` will find the editor's imported copy (asking for one that is not there logs an error).
func _is_imported(path: String) -> bool:
	if not ResourceLoader.exists(path):
		return false
	var remap := ConfigFile.new()
	if remap.load(path + ".import") != OK:
		return true
	var target := str(remap.get_value("remap", "path", ""))
	return target.is_empty() or FileAccess.file_exists(target)


func _system_font(names: Array[String]) -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(names)
	return font


func _chain(font: Font, fallbacks: Array[Font]) -> void:
	if font == _builtin:
		return
	var list: Array[Font] = []
	for fallback in fallbacks:
		if fallback != null and fallback != font and not list.has(fallback) and not _reaches(fallback, font, 0):
			list.append(fallback)
	font.fallbacks = list


## True when `target` is `font` itself or one of the fonts it falls back on.
func _reaches(font: Font, target: Font, depth: int) -> bool:
	if font == target:
		return true
	if depth > 6:
		return false
	if font is FontVariation and (font as FontVariation).base_font and _reaches((font as FontVariation).base_font, target, depth + 1):
		return true
	for fallback in font.fallbacks:
		if _reaches(fallback, target, depth + 1):
			return true
	return false


func _has_glyph(font: Font, code: int, depth: int) -> bool:
	if font == null or depth > 6:
		return false
	if font.has_char(code):
		return true
	for fallback in font.fallbacks:
		if _has_glyph(fallback, code, depth + 1):
			return true
	return false
