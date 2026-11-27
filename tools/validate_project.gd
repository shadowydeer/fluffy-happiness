extends SceneTree
## Headless static validation of the whole project. Run with:
##   godot --headless --path . -s tools/validate_project.gd
## Every script must compile, every scene must load and instantiate, every shader
## must load, and every `res://` path written in a script, scene or project.godot
## must exist. Exits 0 when clean, 1 otherwise.

const ROOTS: Array[String] = ["res://autoload", "res://scripts", "res://scenes", "res://shaders", "res://tools"]

var _failures: Array[String] = []
var _counts := {"scripts": 0, "scenes": 0, "shaders": 0, "paths": 0}


func _initialize() -> void:
	var files: Array[String] = []
	for root in ROOTS:
		_walk(root, files)
	files.append("res://project.godot")
	for path in files:
		match path.get_extension():
			"gd":
				_check_script(path)
			"tscn":
				_check_scene(path)
			"gdshader":
				_check_shader(path)
		_check_paths(path)
	print("validate_project: %d scripts, %d scenes, %d shaders, %d resource paths checked" % [
			_counts["scripts"], _counts["scenes"], _counts["shaders"], _counts["paths"]])
	for failure in _failures:
		printerr("  FAIL  %s" % failure)
	print("validate_project: %s (%d problems)" % ["OK" if _failures.is_empty() else "FAILED", _failures.size()])
	quit(0 if _failures.is_empty() else 1)


func _walk(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_walk(dir_path.path_join(sub), out)
	for file in dir.get_files():
		if file.get_extension() in ["gd", "tscn", "gdshader"]:
			out.append(dir_path.path_join(file))


func _check_script(path: String) -> void:
	_counts["scripts"] += 1
	var script := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE) as GDScript
	if script == null:
		_failures.append("%s: failed to load" % path)
	elif not script.can_instantiate() and path != get_script().resource_path:
		_failures.append("%s: does not compile" % path)


func _check_scene(path: String) -> void:
	_counts["scenes"] += 1
	var scene := ResourceLoader.load(path) as PackedScene
	if scene == null or not scene.can_instantiate():
		_failures.append("%s: failed to load" % path)
		return
	var state := scene.get_state()
	for node in state.get_node_count():
		for property in state.get_node_property_count(node):
			if state.get_node_property_name(node, property) == &"script" and state.get_node_property_value(node, property) == null:
				_failures.append("%s: node '%s' has a broken script reference" % [path, state.get_node_name(node)])


func _check_shader(path: String) -> void:
	_counts["shaders"] += 1
	var shader := ResourceLoader.load(path) as Shader
	if shader == null or shader.code.is_empty():
		_failures.append("%s: failed to load" % path)


## Every literal res:// path in the file has to point at something that exists.
func _check_paths(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var pattern := RegEx.create_from_string("res://[A-Za-z0-9_\\-./]+\\.[A-Za-z0-9]+")
	for found in pattern.search_all(text):
		var target := found.get_string()
		_counts["paths"] += 1
		if not ResourceLoader.exists(target) and not FileAccess.file_exists(target):
			_failures.append("%s: missing resource %s" % [path, target])
