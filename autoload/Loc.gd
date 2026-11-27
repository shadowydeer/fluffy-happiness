extends Node
## Live EN / RU localisation and typography (autoload: `Loc`).
##
## Source strings stay English everywhere in the code and on the wire. Russian is a
## Translation registered with the TranslationServer, so every Label, Button and
## Label3D re-renders the moment the language flips; text that is drawn by hand goes
## through `t()` and listens to `language_changed`. The choice is kept in
## user://settings.cfg. The OFL fonts under res://assets/fonts/ (full Cyrillic) are
## installed as the project-wide default, with a display face for headings.

signal language_changed(code: String)

const LANGUAGES: Array[String] = ["en", "ru"]
const FONT_DIR := "res://assets/fonts/"

var language := "en"


## Switches language now, for every piece of text on screen, and remembers it.
func set_language(code: String) -> void:
	if code == language or not LANGUAGES.has(code):
		return
	language = code
	language_changed.emit(code)


## EN -> RU -> EN.
func toggle() -> void:
	set_language(LANGUAGES[posmod(LANGUAGES.find(language) + 1, LANGUAGES.size())])


## `text` (an English source string) in the current language; unknown text comes back as it is.
func t(text: String) -> String:
	return text


## Display face for titles and big numbers.
func header_font() -> Font:
	return ThemeDB.fallback_font


## Body face for the HUD and menus.
func ui_font() -> Font:
	return ThemeDB.fallback_font


## Monospaced face for the shop terminal and key hints.
func mono_font() -> Font:
	return ThemeDB.fallback_font


## Gives `control` (a Label or Button) the display face.
func style_header(control: Control) -> void:
	control.add_theme_font_override(&"font", header_font())


## The small "EN | RU" switch for the main menu and the pause menu. It keeps itself up to date.
func make_toggle() -> Button:
	var button := Button.new()
	button.name = "LanguageToggle"
	button.text = "EN | RU"
	button.pressed.connect(toggle)
	return button
