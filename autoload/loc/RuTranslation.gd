extends Translation
## Russian for BIND & DELIVER, answered on demand (registered by the `Loc` autoload).
##
## The TranslationServer hands every English source string a Label, Button or Label3D
## is about to show to `_get_message()`. The answer comes from the plain dictionaries
## in the scripts listed in TABLES (add new strings there, nothing else to touch):
##
##   EXACT     "PLAY SOLO": "ИГРАТЬ СОЛО"            the whole string
##   PATTERNS  "DONE: %s": "ГОТОВО: %s"              an English format string; its text
##                                                   arguments are translated in turn,
##                                                   numbers pass through as printed
##   FORMS     {"acc": {"skull": "череп"}}           inflected names, lower-case keys
##
## A Russian pattern takes its arguments in order (`%s`, `%d`, `%.1f` all mean "the
## next one") or by number: `{1}`, `{0:acc}` (argument 0 in the "acc" form when FORMS
## has it, as it is otherwise), `{0|вещь|вещи|вещей}` (the word that goes with number 0).
##
## Lookup order: EXACT, then the same in capitals, then PATTERNS (most specific
## first), then line by line and across the wide separators the HUD joins phrases
## with ("   ", "  -  ", "  //  "; three spaces before two). Whatever is left stays
## in English. Answers are cached, because the HUD rewrites some labels every frame.

const TABLES: Array[GDScript] = [
	preload("res://autoload/loc/RuMenus.gd"),
	preload("res://autoload/loc/RuGame.gd"),
	preload("res://autoload/loc/RuReports.gd"),
	preload("res://autoload/loc/RuWorld.gd"),
]
const CACHE_LIMIT := 4096
## How deep arguments inside arguments are followed.
const MAX_DEPTH := 5
const REGEX_META := "\\^$.|?*+()[]{}"

var _exact: Dictionary = {}
var _capitals: Dictionary = {}
var _forms: Dictionary = {}
var _patterns: Array[Dictionary] = []
var _cache: Dictionary = {}
var _letters := RegEx.create_from_string("[A-Za-z]")
var _wide := RegEx.create_from_string(" {3,}(?:(?:-|—|/{1,2}|\\|) {3,})?")
var _narrow := RegEx.create_from_string(" {2,}(?:(?:-|—|/{1,2}|\\|) {2,})?")
var _token := RegEx.create_from_string("%%|%[-+ 0-9.]*[sdf]")
var _slot := RegEx.create_from_string("%%|%[-+ 0-9.]*[sdf]|\\{(\\d)(?::([a-z]+))?((?:\\|[^|{}]*)+)?\\}")


func _init() -> void:
	locale = "ru"
	for table in TABLES:
		var constants := table.get_script_constant_map()
		_exact.merge(constants.get("EXACT", {}) as Dictionary, true)
		var patterns: Dictionary = constants.get("PATTERNS", {})
		for source: String in patterns:
			_add_pattern(source, str(patterns[source]))
		var forms: Dictionary = constants.get("FORMS", {})
		for form: String in forms:
			if not _forms.has(form):
				_forms[form] = {}
			(_forms[form] as Dictionary).merge(forms[form] as Dictionary, true)
	# "LASSO ON DINING CHAIR": names are sometimes shouted.
	for source: String in _exact:
		var shouted := source.to_upper()
		if not _exact.has(shouted):
			_capitals[shouted] = str(_exact[source]).to_upper()
	_patterns.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["weight"]) > int(b["weight"]))


func _get_message(src_message: StringName, _context: StringName) -> StringName:
	var source := String(src_message)
	var result := lookup(source)
	return StringName(result) if result != source else &""


## `text` in Russian, or `text` itself when no table knows it.
func lookup(text: String, depth: int = 0) -> String:
	var known: Variant = _cache.get(text)
	if known != null:
		return known
	var result := _resolve(text, depth)
	if _cache.size() >= CACHE_LIMIT:
		_cache.clear()
	_cache[text] = result
	return result


## True when a table answers for `text` (in whole, by pattern or part by part).
func knows(text: String) -> bool:
	return lookup(text) != text


func get_entry_count() -> int:
	return _exact.size() + _patterns.size()


func _resolve(text: String, depth: int) -> String:
	if text.is_empty() or _letters.search(text) == null:
		return text
	var hit: Variant = _exact.get(text)
	if hit != null:
		return hit
	var core := text.strip_edges()
	if core.length() != text.length():
		var lead := text.find(core)
		return text.substr(0, lead) + lookup(core, depth) + text.substr(lead + core.length())
	hit = _capitals.get(text)
	if hit != null:
		return hit
	if depth >= MAX_DEPTH:
		return text
	for pattern in _patterns:
		# The longest literal piece has to be there at all: cheaper than running the expression.
		var anchor: String = pattern["anchor"]
		if not anchor.is_empty() and not text.contains(anchor):
			continue
		var found := (pattern["regex"] as RegEx).search(text)
		if found:
			return _fill(pattern, found, depth)
	if text.contains("\n"):
		var lines := text.split("\n")
		for i in lines.size():
			lines[i] = lookup(lines[i], depth + 1)
		return "\n".join(lines)
	# Widest gaps first: "NAME   DOWN  -  hold [E]" is a name and one phrase, not three.
	for separator: RegEx in [_wide, _narrow]:
		var gaps := separator.search_all(text)
		if gaps.is_empty():
			continue
		var out := ""
		var at := 0
		for gap in gaps:
			# Russian sets a dash between phrases, not a hyphen.
			out += lookup(text.substr(at, gap.get_start() - at), depth + 1) + gap.get_string().replace("-", "—")
			at = gap.get_end()
		return out + lookup(text.substr(at), depth + 1)
	return text


## Compiles an English format string into an anchored expression with one group per argument.
func _add_pattern(source: String, template: String) -> void:
	var expression := "^"
	var kinds := PackedByteArray()
	var anchor := ""
	var weight := 0
	var at := 0
	var pieces: Array[String] = []
	for token in _token.search_all(source):
		pieces.append(source.substr(at, token.get_start() - at))
		pieces.append(token.get_string())
		at = token.get_end()
	pieces.append(source.substr(at))
	for i in pieces.size():
		var piece := pieces[i]
		if i % 2 == 0:
			expression += _escape(piece)
			weight += piece.length()
			if piece.length() > anchor.length():
				anchor = piece
		elif piece == "%%":
			expression += "%"
		elif piece.ends_with("s"):
			# One phrase: a text argument never runs across a wide separator.
			expression += "((?:(?!  ).)+?)"
			kinds.append(1)
		elif piece.ends_with("d"):
			expression += "( *[-+]?\\d+)"
			kinds.append(0)
		else:
			expression += "( *[-+]?\\d+(?:\\.\\d+)?)"
			kinds.append(0)
	var regex := RegEx.new()
	if regex.compile(expression + "$") != OK:
		push_warning("Loc: pattern '%s' does not compile" % source)
		return
	_patterns.append({"regex": regex, "template": template, "kinds": kinds, "anchor": anchor, "weight": weight})


func _escape(text: String) -> String:
	var out := ""
	for i in text.length():
		var symbol := text[i]
		out += ("\\" + symbol) if REGEX_META.contains(symbol) else symbol
	return out


## Writes the Russian side of a pattern with the arguments `found` captured.
func _fill(pattern: Dictionary, found: RegExMatch, depth: int) -> String:
	var template: String = pattern["template"]
	var kinds: PackedByteArray = pattern["kinds"]
	var out := ""
	var at := 0
	var next := 0
	for slot in _slot.search_all(template):
		out += template.substr(at, slot.get_start() - at)
		at = slot.get_end()
		var spec := slot.get_string()
		if spec == "%%":
			out += "%"
			continue
		var index := next
		if spec.begins_with("{"):
			index = slot.get_string(1).to_int()
		else:
			next += 1
		if index >= kinds.size():
			continue
		var value := found.get_string(index + 1)
		var choices := slot.get_string(3)
		if not choices.is_empty():
			out += _plural(value.to_int(), choices.substr(1).split("|"))
		elif kinds[index] == 0:
			out += value
		elif not slot.get_string(2).is_empty():
			out += _inflect(value, slot.get_string(2), depth)
		else:
			out += lookup(value, depth + 1)
	return out + template.substr(at)


## `value` (an English name) in the grammatical `form`, keeping capitals when it is shouted.
func _inflect(value: String, form: String, depth: int) -> String:
	var hit: Variant = (_forms.get(form, {}) as Dictionary).get(value.to_lower())
	if hit == null:
		return lookup(value, depth + 1)
	return str(hit).to_upper() if value == value.to_upper() else str(hit)


## Russian plural: 1 виток, 2 витка, 5 витков (11-14 take the last form).
func _plural(count: int, forms: PackedStringArray) -> String:
	var index := 2
	var tail := absi(count) % 100
	if tail < 11 or tail > 14:
		match tail % 10:
			1:
				index = 0
			2, 3, 4:
				index = 1
	return forms[mini(index, forms.size() - 1)]
