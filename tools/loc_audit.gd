extends SceneTree
## Finds text the Russian tables (res://autoload/loc/) do not cover yet.
##   godot --headless --path . -s tools/loc_audit.gd [-- --strict] [-- --strings <file> ...]
## 1. Live UI: switches to RU, boots the title screen (all three pages) and then a solo
##    contract (pause menu, field shop and both report cards opened), and walks every
##    Label, Button, Label3D, RichTextLabel and LineEdit placeholder, visible or not.
## 2. Source: scans autoload/ and scripts/ for the strings handed to post_notice(),
##    post_notice_for(), notify(), set_task_override() and set_alert(), and returned by
##    get_hint() / get_prompt() / get_badge() / get_title() / get_progress_label().
## 3. Lists: every line of each `--strings <file>` (the engineers' strings_<area>.txt:
##    one English string or format per line, `\n` for a line break).
## A string is reported as MISSING when no table answers for it at all, and as PARTIAL
## when its Russian still has English words in it. Key names, numbers, money, the
## name of the game and player names are not text. Prints `MISSING <n>` (both kinds)
## at the end; exits 0, or 1 with `--strict` when n > 0. Nothing is saved to
## user://settings.cfg.

const SCRIPT_ROOTS: Array[String] = ["res://autoload", "res://scripts"]
## Functions whose string arguments are shown to the player.
const NOTICE_CALLS := "(?:post_notice|post_notice_for|notify|set_task_override|set_alert)\\("
## Functions whose returned strings are shown to the player.
const TEXT_GETTERS: Array[String] = ["get_hint", "get_prompt", "get_badge", "get_title", "get_progress_label"]
## Words that are the same in both languages: key caps, units, abbreviations, the brand.
const SAME_IN_RUSSIAN: Array[String] = ["WASD", "SHIFT", "CTRL", "ESC", "ENTER", "TAB", "ALT", "IP", "LAN", "EN", "RU", "BIND", "DELIVER",
		"FPS", "ENet", "OK", "ID"]
## Stand-ins for format arguments: no Latin letters, so they pass through untouched.
const SAMPLE_TEXT := "Ж"

var _loc: Node
var _state: Node
var _strict := false
var _lists: Array[String] = []
var _seen: Dictionary = {}
var _missing: Array[String] = []
var _partial: Array[String] = []
var _names: Array[String] = []
var _checked := 0
var _latin := RegEx.create_from_string("[A-Za-z]{2,}")
var _key_cap := RegEx.create_from_string("\\[[^\\]\\n]{1,12}\\]|\\bF\\d{1,2}\\b|\\bx\\d+\\b")
var _literal := RegEx.create_from_string("\"((?:[^\"\\\\]|\\\\.)*)\"")
var _format := RegEx.create_from_string("%[-+ 0-9.]*[sdf]")


func _initialize() -> void:
	_run()


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _run() -> void:
	var arguments := OS.get_cmdline_user_args()
	for i in arguments.size():
		if arguments[i] == "--strict":
			_strict = true
		elif arguments[i] == "--strings" and i + 1 < arguments.size():
			_lists.append(arguments[i + 1])
	await _frames(2)
	_loc = root.get_node("Loc")
	_state = root.get_node("GameState")
	_loc.set("persist", false)
	_loc.call("set_language", "ru")
	_names.append(str(root.get_node("NetworkManager").get("local_name")))

	await _audit_title_screen()
	await _audit_contract()
	_audit_sources()
	for path in _lists:
		_audit_list(path)

	_loc.call("set_language", "en")
	print("loc_audit: %d distinct strings checked" % _checked)
	for line in _missing:
		print("MISSING  %s" % line)
	for line in _partial:
		print("PARTIAL  %s" % line)
	var total := _missing.size() + _partial.size()
	print("MISSING %d" % total)
	quit(1 if _strict and total > 0 else 0)


# --- Live UI --------------------------------------------------------------------------------

func _audit_title_screen() -> void:
	var menu := (load("res://scenes/LobbyMenu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	await _frames(4)
	_walk(menu, "LobbyMenu")
	for page: int in [1, 2]:
		if menu.has_method("_show"):
			menu.call("_show", page)
			await _frames(2)
			_walk(menu, "LobbyMenu")
	menu.free()
	await _frames(3)


func _audit_contract() -> void:
	_state.set("archetype_lock", 3)
	var main := (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await _frames(90)
	for player: Variant in _state.call("get_players"):
		_names.append(str((player as Object).get("display_name")))
	_walk(main, "Main")
	var pause: Variant = main.get("pause_menu")
	if pause is Node and (pause as Node).has_method("open"):
		(pause as Node).call("open")
		await _frames(2)
		_walk(pause, "PauseMenu")
		(pause as Node).call("close")
	var shop: Variant = main.get("shop")
	if shop is Node and (shop as Node).has_method("open_ui"):
		(shop as Node).call("open_ui")
		await _frames(3)
		_walk(main, "ShopUI")
		if (shop as Node).has_method("close_ui"):
			(shop as Node).call("close_ui")
	# Both report cards, filled in the way ContractManager fills them.
	var contracts: Variant = main.get("contracts")
	var card := _find_with_method(main, "show_summary")
	if card and contracts is Node:
		if (contracts as Node).has_method("compute_payout"):
			card.call("show_summary", (contracts as Node).call("compute_payout"))
			await _frames(2)
			_walk(card, "ContractSummaryUI")
		if (contracts as Node).has_method("compute_report") and card.has_method("show_failure"):
			card.call("show_failure", (contracts as Node).call("compute_report"))
			await _frames(2)
			_walk(card, "ContractSummaryUI")
	await _frames(30)
	_walk(main, "Main")


func _find_with_method(from: Node, method: String) -> Node:
	var stack: Array[Node] = [from]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.has_method(method):
			return node
		stack.append_array(node.get_children())
	return null


## Checks the text of every text-bearing node under `from` that the engine would translate.
func _walk(from: Node, where: String) -> void:
	var stack: Array[Node] = [from]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children(true))
		if not node.can_auto_translate():
			continue
		var origin := "%s  %s" % [where, node.name]
		if node is Label or node is Button or node is Label3D or node is RichTextLabel:
			_examine(str(node.get("text")), origin)
		elif node is LineEdit:
			_examine((node as LineEdit).placeholder_text, origin)
		if node is Control and not (node as Control).tooltip_text.is_empty():
			_examine((node as Control).tooltip_text, origin)


# --- Source scan ----------------------------------------------------------------------------

func _audit_sources() -> void:
	var files: Array[String] = []
	for folder in SCRIPT_ROOTS:
		_collect_scripts(folder, files)
	var call_site := RegEx.create_from_string(NOTICE_CALLS)
	var function := RegEx.create_from_string("^(?:static )?func (\\w+)")
	for path in files:
		if path.begins_with("res://autoload/loc"):
			continue
		var inside := ""
		var number := 0
		for line in FileAccess.get_file_as_string(path).split("\n"):
			number += 1
			var header := function.search(line)
			if header:
				inside = header.get_string(1)
				continue
			var code := line.strip_edges()
			if code.begins_with("#"):
				continue
			var from := -1
			var site := call_site.search(code)
			if site:
				from = site.get_end()
			elif TEXT_GETTERS.has(inside) and code.begins_with("return "):
				from = 0
			if from < 0:
				continue
			for found in _literal.search_all(code, from):
				_examine(_sample(found.get_string(1).c_unescape()), "%s:%d" % [path.trim_prefix("res://"), number])


func _collect_scripts(folder: String, out: Array[String]) -> void:
	var dir := DirAccess.open(folder)
	if dir == null:
		return
	for sub in dir.get_directories():
		_collect_scripts(folder.path_join(sub), out)
	for file in dir.get_files():
		if file.get_extension() == "gd":
			out.append(folder.path_join(file))


func _audit_list(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		print("loc_audit: cannot read %s" % path)
		return
	var number := 0
	while not file.eof_reached():
		var line := file.get_line()
		number += 1
		if line.strip_edges().is_empty() or line.begins_with("#"):
			continue
		_examine(_sample(line.replace("\\n", "\n")), "%s:%d" % [path.get_file(), number])


## A format string with its arguments filled in by things that need no translation.
func _sample(format: String) -> String:
	var out := ""
	var at := 0
	for token in _format.search_all(format):
		out += format.substr(at, token.get_start() - at)
		at = token.get_end()
		var spec := token.get_string()
		if spec.ends_with("s"):
			out += SAMPLE_TEXT
		elif spec.ends_with("d"):
			out += spec % 7
		else:
			out += spec % 1.5
	return (out + format.substr(at)).replace("%%", "%")


# --- Verdict --------------------------------------------------------------------------------

func _examine(text: String, origin: String) -> void:
	if text.strip_edges().is_empty() or _seen.has(text):
		return
	_seen[text] = true
	if _foreign(text).is_empty():
		return
	_checked += 1
	var russian := str(_loc.call("t", text))
	if russian == text:
		_missing.append("%s    <- %s" % [text.c_escape(), origin])
		return
	var left := _foreign(russian)
	if not left.is_empty():
		_partial.append("%s    => %s    [%s]    <- %s" % [text.c_escape(), russian.c_escape(), ", ".join(left), origin])


## The English words in `text`, once key caps, units, the brand and player names are set aside.
func _foreign(text: String) -> PackedStringArray:
	var words := PackedStringArray()
	var bare := _key_cap.sub(text, " ", true)
	for name in _names:
		if not name.is_empty():
			bare = bare.replace(name, " ")
	for found in _latin.search_all(bare):
		var word := found.get_string()
		if not SAME_IN_RUSSIAN.has(word) and not words.has(word):
			words.append(word)
	return words
