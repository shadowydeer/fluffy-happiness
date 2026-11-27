extends Node
## Universal auto-normalizing .glb loader (autoload: `ModelLoader`).
##
## Every third-party model arrives with its own scale, pivot and brightness.
## `instance()` returns a wrapper Node3D in which the model has been:
##   * measured (combined AABB of every MeshInstance3D, or the skeleton for rigged models),
##   * scaled to the requested size in metres (`fit_height`, `fit_box`, ...),
##   * centred on X/Z with its lowest point on Y = 0 (or hung from its top / centred),
##   * optionally rotated, tinted, grunged and set to cast shadows.
## The wrapper itself keeps scale 1, so it can be parented to physics bodies.
## `add_collision()` then fits a box or simplified convex collider to the result.
##
## If a .glb is missing (its download failed), a rounded stand-in block of the
## requested size is returned instead, so the game always runs.

enum Collision { NONE, BOX, CONVEX }

const MODEL_ROOT := "res://assets/models/"
const META_AABB := &"model_aabb"
const META_SOURCE := &"model_source"
const META_FALLBACK := &"model_fallback"

## Print one line per .glb the first time it is loaded.
var verbose := true

var _scenes: Dictionary = {}          # path -> PackedScene, or null when unavailable
var _materials: Dictionary = {}       # "<material id>|<tint>|<grunge>" -> Material
var _hull_points: Dictionary = {}     # "<path>|<part>" -> PackedVector3Array in source space
var _clipped: Dictionary = {}         # clip key -> Array[ArrayMesh], one per mesh node
var _loaded: Dictionary = {}          # path -> instance count
var _missing: Dictionary = {}         # path -> instance count
var _grunge_texture: NoiseTexture2D
var _fallback_material: StandardMaterial3D
var _hull_directions: PackedVector3Array


func _ready() -> void:
	_hull_directions = _build_hull_directions()


## Resolves "furniture/sofa" to "res://assets/models/furniture/sofa.glb".
func resolve(model: String) -> String:
	if model.begins_with("res://"):
		return model
	return MODEL_ROOT + model + ".glb"


func has_model(model: String) -> bool:
	return _get_scene(resolve(model)) != null


## Loads, normalises and returns a model. Options (all optional):
##   fit_height / fit_width / fit_depth : float  uniform scale so that axis measures this many metres
##   fit_longest : float                 uniform scale so the longest axis measures this
##   fit_box : Vector3                   uniform scale to fit inside this box
##   stretch : Vector3                   exact non-uniform size (0 on an axis = follow the uniform scale)
##   scale : float                       extra multiplier applied after fitting
##   rotate_y : float                    degrees, applied before measuring
##   rotation : Vector3                  degrees, full pre-rotation (e.g. to lay a prop on its side)
##   part : String                       use only the named child node of a multi-object file
##   part_prefix : String                use every child node whose name starts with this
##   clip : AABB                         keep only triangles inside this box, given as 0..1 fractions of the
##                                       model's bounds (after the pre-rotation); `clip_remove` inverts it,
##                                       `clip_part` limits it to one mesh node, `clip_refit` re-measures after
##   anchor : String                     "bottom" (default), "center" or "top"
##   tint : Color                        multiplied into every albedo
##   grunge : float                      0..1 strength of a blotchy dirt layer
##   material : Material                 replace every surface material
##   shadows : bool                      cast shadows (default true)
##   visibility_range : float            hide beyond this distance
##   fallback_size : Vector3             size of the stand-in if the file is missing
func instance(model: String, options: Dictionary = {}) -> Node3D:
	var path := resolve(model)
	var wrapper := Node3D.new()
	wrapper.name = model.get_file().get_basename().to_pascal_case()
	wrapper.set_meta(META_SOURCE, path)

	var scene := _get_scene(path)
	var content: Node3D = null
	if scene:
		content = scene.instantiate() as Node3D
		var part: String = options.get("part", "")
		var prefix: String = options.get("part_prefix", "")
		if content and not (part.is_empty() and prefix.is_empty()):
			content = _extract_parts(content, part, prefix, path)
	if content == null:
		_missing[path] = int(_missing.get(path, 0)) + 1
		return _build_fallback(wrapper, options)
	_loaded[path] = int(_loaded.get(path, 0)) + 1

	var euler: Vector3 = options.get("rotation", Vector3.ZERO)
	euler.y += float(options.get("rotate_y", 0.0))
	var pre_rotation := Basis.from_euler(Vector3(deg_to_rad(euler.x), deg_to_rad(euler.y), deg_to_rad(euler.z)))

	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(content, meshes)
	var bounds := _measure(content, meshes, pre_rotation)
	if options.has("clip") and bounds.size.length() > 0.000001:
		var clip_part: String = options.get("clip_part", "")
		var clip_key := "%s|%s|%s|%s|%s|%s" % [path, options.get("part", ""), euler, options["clip"], options.get("clip_remove", false), clip_part]
		_clip(content, meshes, pre_rotation, bounds, options["clip"], options.get("clip_remove", false), clip_part, clip_key)
		# By default the model keeps the size and pivot it had before the cut.
		if options.get("clip_refit", false):
			bounds = _measure(content, meshes, pre_rotation)
	if bounds.size.length() < 0.000001:
		push_warning("ModelLoader: %s has no measurable geometry" % path)
		bounds = AABB(Vector3(-0.5, 0.0, -0.5), Vector3.ONE)

	var scale_vector := _solve_scale(bounds.size, options)
	var size := bounds.size * scale_vector
	var center := bounds.get_center() * scale_vector
	var rig := _find_skeleton(content)
	if rig and rig.get_bone_count() > 0:
		# Rigs stand on their root bone; helper bones (IK poles) must not shift the pivot.
		var root_at := (Transform3D(pre_rotation, Vector3.ZERO) * content.transform * _relative_transform(rig, content)) * rig.get_bone_global_rest(0).origin
		center.x = root_at.x * scale_vector.x
		center.z = root_at.z * scale_vector.z
	var anchor: String = options.get("anchor", "bottom")
	var offset := Vector3(-center.x, -bounds.position.y * scale_vector.y, -center.z)
	var normalized := AABB(Vector3(-size.x * 0.5, 0.0, -size.z * 0.5), size)
	if anchor == "center":
		offset.y = -center.y
		normalized.position.y = -size.y * 0.5
	elif anchor == "top":
		offset.y = -bounds.end.y * scale_vector.y
		normalized.position.y = -size.y

	content.transform = Transform3D(Basis.from_scale(scale_vector) * pre_rotation, offset) * content.transform
	wrapper.add_child(content)
	wrapper.set_meta(META_AABB, normalized)
	_style(meshes, options)
	return wrapper


## Normalised bounds of a model returned by `instance()`, in the wrapper's local space.
func get_aabb(model: Node3D) -> AABB:
	return model.get_meta(META_AABB, AABB(Vector3(-0.25, 0.0, -0.25), Vector3(0.5, 0.5, 0.5)))


func is_fallback(model: Node3D) -> bool:
	return model.get_meta(META_FALLBACK, false)


## Adds a CollisionShape3D to `body` that matches `model` (a child of `body`
## created by `instance()`). `inset` shrinks a box by that many metres per side.
func add_collision(body: CollisionObject3D, model: Node3D, mode: Collision = Collision.BOX, inset: float = 0.0) -> CollisionShape3D:
	if mode == Collision.NONE:
		return null
	var bounds := get_aabb(model)
	var collider := CollisionShape3D.new()
	collider.name = "Collider"
	var points := PackedVector3Array()
	if mode == Collision.CONVEX and not is_fallback(model):
		points = _convex_points(model)
	if points.size() >= 4:
		var hull := ConvexPolygonShape3D.new()
		hull.points = points
		collider.shape = hull
		collider.transform = model.transform
	else:
		var box := BoxShape3D.new()
		box.size = (bounds.size - Vector3.ONE * inset * 2.0).max(Vector3.ONE * 0.02)
		collider.shape = box
		collider.transform = model.transform * Transform3D(Basis.IDENTITY, bounds.get_center())
	body.add_child(collider)
	return collider


## Adds one box collider covering a fraction of the model's bounds. `from` and
## `to` are 0..1 corners inside the normalised AABB (x: left-right, y: bottom-top,
## z: back-front). Used for compound colliders such as chair seat + backrest.
func add_box_fraction(body: CollisionObject3D, model: Node3D, from: Vector3, to: Vector3) -> CollisionShape3D:
	var bounds := get_aabb(model)
	var low := bounds.position + bounds.size * from
	var high := bounds.position + bounds.size * to
	var box := BoxShape3D.new()
	box.size = (high - low).abs().max(Vector3.ONE * 0.02)
	var collider := CollisionShape3D.new()
	collider.shape = box
	collider.transform = model.transform * Transform3D(Basis.IDENTITY, (low + high) * 0.5)
	body.add_child(collider)
	return collider


## Places many copies of one model with a single draw call per mesh (MultiMesh).
## Each transform positions a normalised copy: its origin is the model's bottom centre.
## Takes the same options as `instance()`.
func scatter(model: String, transforms: Array[Transform3D], options: Dictionary = {}) -> Node3D:
	var holder := Node3D.new()
	holder.name = model.get_file().get_basename().to_pascal_case() + "Scatter"
	if transforms.is_empty():
		return holder
	var template := instance(model, options)
	if is_fallback(template):
		template.free()
		return holder
	var content := template.get_child(0) as Node3D
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(content, meshes)
	var range_end := float(options.get("visibility_range", 0.0))
	for mesh_instance in meshes:
		var local := content.transform * _relative_transform(mesh_instance, content)
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = _bake_overrides(mesh_instance)
		multimesh.instance_count = transforms.size()
		for index in transforms.size():
			multimesh.set_instance_transform(index, transforms[index] * local)
		var field := MultiMeshInstance3D.new()
		field.multimesh = multimesh
		field.cast_shadow = mesh_instance.cast_shadow
		field.material_override = mesh_instance.material_override
		if range_end > 0.0:
			field.visibility_range_end = range_end
		holder.add_child(field)
	template.free()
	return holder


## A mesh whose own surface materials are the instance's per-surface overrides.
func _bake_overrides(mesh_instance: MeshInstance3D) -> Mesh:
	var source := mesh_instance.mesh
	var needs_copy := false
	for surface in source.get_surface_count():
		if mesh_instance.get_surface_override_material(surface) != null:
			needs_copy = true
	if not needs_copy:
		return source
	var copy := source.duplicate() as Mesh
	for surface in copy.get_surface_count():
		var override := mesh_instance.get_surface_override_material(surface)
		if override:
			copy.surface_set_material(surface, override)
	return copy


## Names of the direct mesh-bearing parts of a multi-object file (for `part`).
func list_parts(model: String) -> PackedStringArray:
	var names := PackedStringArray()
	var scene := _get_scene(resolve(model))
	if scene == null:
		return names
	var root := scene.instantiate()
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)
	for mesh in meshes:
		names.append(mesh.name)
	root.free()
	return names


## One-line-per-file summary of everything loaded so far.
func report() -> String:
	var instances := 0
	for path: String in _loaded:
		instances += int(_loaded[path])
	var text := "[ModelLoader] %d .glb files loaded, %d instances placed, %d fallback(s)" % [_loaded.size(), instances, _missing.size()]
	for path: String in _missing:
		text += "\n[ModelLoader]   MISSING %s (x%d) -> stand-in mesh" % [path, _missing[path]]
	return text


func get_loaded_count() -> int:
	return _loaded.size()


func get_missing_count() -> int:
	return _missing.size()


# --- Loading ----------------------------------------------------------------

func _get_scene(path: String) -> PackedScene:
	if _scenes.has(path):
		return _scenes[path]
	var scene: PackedScene = null
	if ResourceLoader.exists(path, "PackedScene"):
		scene = ResourceLoader.load(path, "PackedScene") as PackedScene
	if scene == null and FileAccess.file_exists(path):
		# Not imported by the editor yet: parse the binary glTF directly.
		scene = _load_raw_glb(path)
	_scenes[path] = scene
	if scene == null:
		push_warning("ModelLoader: %s is not available, using a stand-in mesh" % path)
	elif verbose:
		var probe := scene.instantiate()
		var meshes: Array[MeshInstance3D] = []
		_collect_meshes(probe, meshes)
		var bounds := _measure(probe as Node3D, meshes, Basis.IDENTITY) if probe is Node3D else AABB()
		print("[ModelLoader] loaded %s  (%d mesh nodes, source size %.2f x %.2f x %.2f)" % [path, meshes.size(), bounds.size.x, bounds.size.y, bounds.size.z])
		probe.free()
	return scene


func _load_raw_glb(path: String) -> PackedScene:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(path, state) != OK:
		return null
	var root := document.generate_scene(state)
	if root == null:
		return null
	_own_children(root, root)
	var packed := PackedScene.new()
	var result := packed.pack(root)
	root.free()
	return packed if result == OK else null


func _own_children(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own_children(child, owner_node)


## Keeps only the named sub-object(s) of a multi-object model.
func _extract_parts(content: Node3D, part: String, prefix: String, path: String) -> Node3D:
	var targets: Array[Node3D] = []
	_find_parts(content, part, prefix, targets)
	if targets.is_empty():
		push_warning("ModelLoader: %s has no part matching '%s%s'" % [path, part, prefix])
		return content
	if targets.size() == 1 and targets[0] == content:
		return content
	var holder := Node3D.new()
	holder.name = content.name
	for target in targets:
		var relative := _relative_transform(target, content)
		target.get_parent().remove_child(target)
		target.owner = null
		_clear_owner(target)
		target.transform = relative
		holder.add_child(target)
	content.free()
	return holder


func _find_parts(node: Node, part: String, prefix: String, out: Array[Node3D]) -> void:
	if node is Node3D:
		var node_name := String(node.name)
		if (not part.is_empty() and node_name == part) or (not prefix.is_empty() and node_name.begins_with(prefix)):
			out.append(node)
			return
	for child in node.get_children():
		_find_parts(child, part, prefix, out)


func _clear_owner(node: Node) -> void:
	for child in node.get_children():
		child.owner = null
		_clear_owner(child)


## Rebuilds every mesh keeping only the triangles whose centre lies inside (or,
## with `remove`, outside) `region`, a box in 0..1 fractions of `bounds`.
func _clip(content: Node3D, meshes: Array[MeshInstance3D], pre_rotation: Basis, bounds: AABB, region: AABB,
		remove: bool, only_part: String, cache_key: String) -> void:
	if _clipped.has(cache_key):
		var cached: Array = _clipped[cache_key]
		for index in mini(cached.size(), meshes.size()):
			meshes[index].mesh = cached[index]
		return
	var base := Transform3D(pre_rotation, Vector3.ZERO) * content.transform
	var safe_size := bounds.size.max(Vector3.ONE * 0.000001)
	var results: Array = []
	for mesh_instance in meshes:
		if not only_part.is_empty() and String(mesh_instance.name) != only_part:
			results.append(mesh_instance.mesh)
			continue
		var to_root := base * _relative_transform(mesh_instance, content)
		var source := mesh_instance.mesh
		var rebuilt := ArrayMesh.new()
		for surface in source.get_surface_count():
			var arrays := source.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices := PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] != null:
				indices = arrays[Mesh.ARRAY_INDEX]
			else:
				indices.resize(vertices.size())
				for i in vertices.size():
					indices[i] = i
			var remap := PackedInt32Array()
			remap.resize(vertices.size())
			remap.fill(-1)
			var order := PackedInt32Array()
			var kept := PackedInt32Array()
			for triangle in range(0, indices.size() - 2, 3):
				var centre := to_root * ((vertices[indices[triangle]] + vertices[indices[triangle + 1]] + vertices[indices[triangle + 2]]) / 3.0)
				var inside := region.has_point((centre - bounds.position) / safe_size)
				if inside == remove:
					continue
				for corner in 3:
					var old := indices[triangle + corner]
					if remap[old] < 0:
						remap[old] = order.size()
						order.append(old)
					kept.append(remap[old])
			if kept.is_empty():
				continue
			var compact := []
			compact.resize(Mesh.ARRAY_MAX)
			for channel in Mesh.ARRAY_MAX:
				if channel == Mesh.ARRAY_INDEX or arrays[channel] == null:
					continue
				compact[channel] = _pick(arrays[channel], order, vertices.size())
			compact[Mesh.ARRAY_INDEX] = kept
			rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, compact)
			rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, source.surface_get_material(surface))
		mesh_instance.mesh = rebuilt
		results.append(rebuilt)
	_clipped[cache_key] = results


## Copies the per-vertex entries listed in `order` out of one vertex-attribute array.
func _pick(channel: Variant, order: PackedInt32Array, vertex_count: int) -> Variant:
	var stride := 1
	match typeof(channel):
		TYPE_PACKED_VECTOR3_ARRAY:
			var source: PackedVector3Array = channel
			var out := PackedVector3Array()
			out.resize(order.size())
			for i in order.size():
				out[i] = source[order[i]]
			return out
		TYPE_PACKED_VECTOR2_ARRAY:
			var source: PackedVector2Array = channel
			var out := PackedVector2Array()
			out.resize(order.size())
			for i in order.size():
				out[i] = source[order[i]]
			return out
		TYPE_PACKED_COLOR_ARRAY:
			var source: PackedColorArray = channel
			var out := PackedColorArray()
			out.resize(order.size())
			for i in order.size():
				out[i] = source[order[i]]
			return out
		TYPE_PACKED_FLOAT32_ARRAY:
			var source: PackedFloat32Array = channel
			stride = maxi(1, source.size() / maxi(vertex_count, 1))
			var out := PackedFloat32Array()
			out.resize(order.size() * stride)
			for i in order.size():
				for k in stride:
					out[i * stride + k] = source[order[i] * stride + k]
			return out
		TYPE_PACKED_INT32_ARRAY:
			var source: PackedInt32Array = channel
			stride = maxi(1, source.size() / maxi(vertex_count, 1))
			var out := PackedInt32Array()
			out.resize(order.size() * stride)
			for i in order.size():
				for k in stride:
					out[i * stride + k] = source[order[i] * stride + k]
			return out
	return null


# --- Measuring --------------------------------------------------------------

func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for child in node.get_children():
		_collect_meshes(child, out)


## Transform of `node` expressed in the space of `ancestor` (neither needs to be in the tree).
func _relative_transform(node: Node3D, ancestor: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var cursor: Node = node
	while cursor != null and cursor != ancestor:
		if cursor is Node3D:
			result = (cursor as Node3D).transform * result
		cursor = cursor.get_parent()
	return result


## Combined bounds of the model in the space of `content`'s parent, after `pre_rotation`.
func _measure(content: Node3D, meshes: Array[MeshInstance3D], pre_rotation: Basis) -> AABB:
	var base := Transform3D(pre_rotation, Vector3.ZERO) * content.transform
	var skeleton := _find_skeleton(content)
	var points := PackedVector3Array()
	if skeleton:
		# Skinned vertices follow the bones, not the mesh node, so measure the rig.
		var to_root := base * _relative_transform(skeleton, content)
		for bone in skeleton.get_bone_count():
			points.append(to_root * skeleton.get_bone_global_rest(bone).origin)
	else:
		for mesh in meshes:
			var local := mesh.get_aabb()
			var to_root := base * _relative_transform(mesh, content)
			for corner in 8:
				points.append(to_root * local.get_endpoint(corner))
	if points.is_empty():
		return AABB()
	var bounds := AABB(points[0], Vector3.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	return bounds


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found
	return null


func _solve_scale(size: Vector3, options: Dictionary) -> Vector3:
	var safe := size.max(Vector3.ONE * 0.000001)
	var uniform := INF
	if options.has("fit_height"):
		uniform = minf(uniform, float(options["fit_height"]) / safe.y)
	if options.has("fit_width"):
		uniform = minf(uniform, float(options["fit_width"]) / safe.x)
	if options.has("fit_depth"):
		uniform = minf(uniform, float(options["fit_depth"]) / safe.z)
	if options.has("fit_longest"):
		uniform = minf(uniform, float(options["fit_longest"]) / maxf(safe.x, maxf(safe.y, safe.z)))
	if options.has("fit_box"):
		var box: Vector3 = options["fit_box"]
		uniform = minf(uniform, minf(box.x / safe.x, minf(box.y / safe.y, box.z / safe.z)))
	var result := Vector3.ONE
	if options.has("stretch"):
		var target: Vector3 = options["stretch"]
		var ratios := Vector3(target.x / safe.x, target.y / safe.y, target.z / safe.z)
		if uniform == INF:
			# Follow the average of the axes that were given.
			var total := 0.0
			var count := 0
			for axis in 3:
				if target[axis] > 0.0:
					total += ratios[axis]
					count += 1
			uniform = total / float(maxi(count, 1))
		for axis in 3:
			result[axis] = ratios[axis] if target[axis] > 0.0 else uniform
	else:
		if uniform == INF:
			uniform = 1.0
		result = Vector3.ONE * uniform
	return result * float(options.get("scale", 1.0))


# --- Look -------------------------------------------------------------------

func _style(meshes: Array[MeshInstance3D], options: Dictionary) -> void:
	var cast := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if options.get("shadows", true) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tint: Color = options.get("tint", Color.WHITE)
	var grunge := float(options.get("grunge", 0.0))
	var replacement: Material = options.get("material", null)
	var range_end := float(options.get("visibility_range", 0.0))
	for mesh in meshes:
		mesh.cast_shadow = cast
		if range_end > 0.0:
			mesh.visibility_range_end = range_end
			mesh.visibility_range_end_margin = range_end * 0.1
			mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		if replacement:
			mesh.material_override = replacement
			continue
		if tint == Color.WHITE and grunge <= 0.0:
			continue
		for surface in mesh.mesh.get_surface_count():
			var source := mesh.get_active_material(surface) as BaseMaterial3D
			if source:
				mesh.set_surface_override_material(surface, _styled_material(source, tint, grunge))


## Darkened / dirtied copy of a material, shared between all instances that ask for the same look.
func _styled_material(source: BaseMaterial3D, tint: Color, grunge: float) -> Material:
	var key := "%d|%s|%.2f" % [source.get_instance_id(), tint.to_html(), grunge]
	if _materials.has(key):
		return _materials[key]
	var styled := source.duplicate() as BaseMaterial3D
	styled.albedo_color = source.albedo_color * tint
	if grunge > 0.0:
		# Blotchy grime multiplied over the surface. Sampled triplanar through UV2 so it
		# also works on models whose own UVs are collapsed onto a colour palette.
		styled.detail_enabled = true
		styled.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
		styled.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
		styled.detail_albedo = _get_grunge_texture()
		styled.uv2_triplanar = true
		styled.uv2_scale = Vector3.ONE * 0.45
		styled.roughness = lerpf(source.roughness, 1.0, grunge * 0.5)
		styled.albedo_color = styled.albedo_color.lerp(styled.albedo_color * Color(0.62, 0.58, 0.52), grunge)
	_materials[key] = styled
	return styled


func _get_grunge_texture() -> NoiseTexture2D:
	if _grunge_texture:
		return _grunge_texture
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.62
	noise.seed = 1313
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	ramp.colors = PackedColorArray([Color(0.30, 0.27, 0.24), Color(0.78, 0.75, 0.70), Color(1.0, 1.0, 1.0)])
	_grunge_texture = NoiseTexture2D.new()
	_grunge_texture.width = 256
	_grunge_texture.height = 256
	_grunge_texture.seamless = true
	_grunge_texture.generate_mipmaps = true
	_grunge_texture.noise = noise
	_grunge_texture.color_ramp = ramp
	return _grunge_texture


# --- Collision --------------------------------------------------------------

## A handful of extreme points of the model: a tight, cheap convex hull.
func _convex_points(model: Node3D) -> PackedVector3Array:
	var content := model.get_child(0) as Node3D
	var key := "%s|%s" % [model.get_meta(META_SOURCE, ""), content.get_child(0).name if content.get_child_count() > 0 else &""]
	var source: PackedVector3Array
	if _hull_points.has(key):
		source = _hull_points[key]
	else:
		source = _sample_vertices(content)
		_hull_points[key] = source
	if source.size() < 4:
		return PackedVector3Array()
	# Source points are stored relative to `content`; bring them into the wrapper's space.
	var to_wrapper := content.transform
	var moved := PackedVector3Array()
	moved.resize(source.size())
	for i in source.size():
		moved[i] = to_wrapper * source[i]
	var hull := PackedVector3Array()
	for direction in _hull_directions:
		var best := moved[0]
		var best_dot := -INF
		for point in moved:
			var dot := point.dot(direction)
			if dot > best_dot:
				best_dot = dot
				best = point
		var duplicate := false
		for existing in hull:
			if existing.distance_squared_to(best) < 0.000004:
				duplicate = true
				break
		if not duplicate:
			hull.append(best)
	return hull


## Up to ~1500 vertices of the model, expressed in `content`'s local space.
func _sample_vertices(content: Node3D) -> PackedVector3Array:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(content, meshes)
	var total := 0
	var faces: Array[PackedVector3Array] = []
	for mesh in meshes:
		var triangles := mesh.mesh.get_faces()
		faces.append(triangles)
		total += triangles.size()
	var stride := maxi(1, int(ceil(float(total) / 1500.0)))
	var points := PackedVector3Array()
	for index in meshes.size():
		var to_content := _relative_transform(meshes[index], content)
		var triangles := faces[index]
		var cursor := 0
		while cursor < triangles.size():
			points.append(to_content * triangles[cursor])
			cursor += stride
		# Strided sampling can miss the outermost vertices, so always add the bounds corners'
		# nearest real extremes along each axis.
		var extremes := _axis_extremes(triangles)
		for point in extremes:
			points.append(to_content * point)
	return points


func _axis_extremes(points: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	if points.is_empty():
		return result
	var low := [points[0], points[0], points[0]]
	var high := [points[0], points[0], points[0]]
	for point in points:
		for axis in 3:
			if point[axis] < (low[axis] as Vector3)[axis]:
				low[axis] = point
			if point[axis] > (high[axis] as Vector3)[axis]:
				high[axis] = point
	for axis in 3:
		result.append(low[axis])
		result.append(high[axis])
	return result


func _build_hull_directions() -> PackedVector3Array:
	var directions := PackedVector3Array([Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK])
	# Fibonacci sphere: evenly spread directions for the rounded parts of a hull.
	var count := 34
	var golden := PI * (3.0 - sqrt(5.0))
	for i in count:
		var y := 1.0 - 2.0 * (float(i) + 0.5) / float(count)
		var radius := sqrt(maxf(0.0, 1.0 - y * y))
		var angle := golden * float(i)
		directions.append(Vector3(cos(angle) * radius, y, sin(angle) * radius))
	return directions


# --- Fallback ---------------------------------------------------------------

## Rounded, textured stand-in used only when a .glb could not be loaded.
func _build_fallback(wrapper: Node3D, options: Dictionary) -> Node3D:
	var size: Vector3 = options.get("fallback_size", Vector3.ZERO)
	if size == Vector3.ZERO:
		if options.has("fit_box"):
			size = options["fit_box"]
		elif options.has("stretch"):
			size = options["stretch"]
		else:
			var height := float(options.get("fit_height", options.get("fit_longest", 0.6)))
			var width := float(options.get("fit_width", height * 0.6))
			size = Vector3(width, height, float(options.get("fit_depth", width)))
	size = size.max(Vector3.ONE * 0.05) * float(options.get("scale", 1.0))
	var anchor: String = options.get("anchor", "bottom")
	var base_y := 0.0
	if anchor == "center":
		base_y = -size.y * 0.5
	elif anchor == "top":
		base_y = -size.y
	var holder := Node3D.new()
	holder.name = "StandIn"
	holder.position.y = base_y + size.y * 0.5
	wrapper.add_child(holder)
	var bevel := minf(0.06, minf(size.x, minf(size.y, size.z)) * 0.25)
	var material := _get_fallback_material()
	var cast := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if options.get("shadows", true) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# A rounded box: three overlapping slabs, twelve edge rods and eight corner balls.
	for axis in 3:
		var slab := BoxMesh.new()
		var slab_size := size - Vector3.ONE * bevel * 2.0
		slab_size[axis] = size[axis]
		slab.size = slab_size
		_fallback_part(holder, slab, Transform3D.IDENTITY, material, cast)
	var inner := size * 0.5 - Vector3.ONE * bevel
	for axis in 3:
		var rod := CylinderMesh.new()
		rod.top_radius = bevel
		rod.bottom_radius = bevel
		rod.height = inner[axis] * 2.0
		rod.radial_segments = 10
		rod.rings = 1
		var basis := Basis.IDENTITY
		if axis == 0:
			basis = Basis(Vector3.BACK, PI * 0.5)
		elif axis == 2:
			basis = Basis(Vector3.RIGHT, PI * 0.5)
		var a := (axis + 1) % 3
		var b := (axis + 2) % 3
		for sign_a: float in [-1.0, 1.0]:
			for sign_b: float in [-1.0, 1.0]:
				var at := Vector3.ZERO
				at[a] = inner[a] * sign_a
				at[b] = inner[b] * sign_b
				_fallback_part(holder, rod, Transform3D(basis, at), material, cast)
	var ball := SphereMesh.new()
	ball.radius = bevel
	ball.height = bevel * 2.0
	ball.radial_segments = 10
	ball.rings = 5
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				_fallback_part(holder, ball, Transform3D(Basis.IDENTITY, inner * Vector3(sx, sy, sz)), material, cast)
	wrapper.set_meta(META_AABB, AABB(Vector3(-size.x * 0.5, base_y, -size.z * 0.5), size))
	wrapper.set_meta(META_FALLBACK, true)
	return wrapper


func _fallback_part(holder: Node3D, mesh: Mesh, at: Transform3D, material: Material, cast: GeometryInstance3D.ShadowCastingSetting) -> void:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.transform = at
	part.material_override = material
	part.cast_shadow = cast
	holder.add_child(part)


func _get_fallback_material() -> StandardMaterial3D:
	if _fallback_material:
		return _fallback_material
	_fallback_material = StandardMaterial3D.new()
	_fallback_material.albedo_color = Color(0.30, 0.22, 0.16)
	_fallback_material.roughness = 0.85
	_fallback_material.detail_enabled = true
	_fallback_material.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	_fallback_material.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
	_fallback_material.detail_albedo = _get_grunge_texture()
	_fallback_material.uv2_triplanar = true
	_fallback_material.uv2_scale = Vector3.ONE * 0.8
	return _fallback_material
