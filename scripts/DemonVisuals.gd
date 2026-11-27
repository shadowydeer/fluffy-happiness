extends Node3D
## Look and presence of the demon.
##
## The skinned model loaded by DemonSkeletonDriver is the only thing that renders.
## This script re-dresses it: a charred, wet hide shader that keeps the model's
## painted anatomy but drags it down to soot and ash, lays a real charred-bark
## PBR set over it for pore-level detail, and lights molten veins across the
## chest and back. Ember eyes, their glow, the chest light and the ash / spark
## particles ride the head and spine bones, and everything follows the demon's
## mood: flaring when enraged or casting, guttering to coals when stunned.

const Driver := preload("res://scripts/DemonSkeletonDriver.gd")
const Mats := preload("res://scripts/MaterialLibrary.gd")
const SKIN_SHADER := preload("res://shaders/demon_skin.gdshader")
const Parts := preload("res://scripts/gadgets/GadgetParts.gd")

const SKIN_SET := "demon/charred_skin"
const HEAD_BONE := "Head"
const CROWN_BONE := "head_end"
const CHEST_BONE := "Spine"
const WAIST_BONE := "Spine02"
const NECK_BONE := "neck"
const EMBER := Color(1.0, 0.36, 0.06)
const EYE_COLOR := Color(1.0, 0.44, 0.06)

var _driver: Driver
var _skeleton: Skeleton3D
var _mesh: MeshInstance3D
var _skin: ShaderMaterial
var _eye: StandardMaterial3D
var _eye_light: OmniLight3D
var _chest_light: OmniLight3D
var _ash: GPUParticles3D
var _sparks: GPUParticles3D
var _noise := FastNoiseLite.new()
var _chest_bone := -1
var _eyes: Array[Vector3] = []

var _time := 0.0
var _rage := 0.0
var _rage_target := 0.0
var _cast := 0.0
var _casting := false
var _stunned := false
var _captured := false
var _flash := 0.0
var _shock := 0.0
var _shade := 0.0
## Tape bands by bind level (1..3); built hidden, shown as the demon is wrapped.
var _tape: Array[Array] = [[], [], [], []]
var _tape_mounts: Dictionary = {}
var _tape_points := PackedVector3Array()
var _tape_bones := PackedInt32Array()
var _tape_settle := 0.0


func build(ragdoll: Node3D) -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 1.0
	_noise.seed = 1313
	var driver := ragdoll.get_node_or_null("Driver") as Driver
	if driver == null or not driver.is_ready():
		push_warning("DemonVisuals: no skinned model to dress")
		return
	_driver = driver
	_skeleton = driver.get_skeleton()
	_mesh = driver.get_mesh_instance()
	_chest_bone = _skeleton.find_bone(CHEST_BONE)
	_make_skin()
	var head := driver.make_attachment(HEAD_BONE, "HeadMount")
	var chest := driver.make_attachment(CHEST_BONE, "ChestMount")
	_build_eyes(head)
	_build_lights(head, chest)
	_build_particles(chest)
	_build_tape()
	ragdoll.connect(&"bind_changed", _on_bind_changed)
	_on_bind_changed(int(ragdoll.get(&"bind_level")))
	_apply_mood()


## rage 0..1 drives eyes, molten veins and sparks; stunned gutters them to coals; captured all
## but puts them out; casting flares everything for the length of a poltergeist throw.
func set_mood(rage: float, stunned: bool, captured: bool, casting: bool = false) -> void:
	_rage_target = clampf(rage, 0.0, 1.0)
	_stunned = stunned
	_captured = captured
	_casting = casting


## One bright flare of the eyes and veins (the moment it snaps into rage).
func flash() -> void:
	_flash = 1.0


## The hide drinks the light for a moment (the evasive shadow lunge) and sheds a cloud of ash.
func shadow_step() -> void:
	_shade = 1.0


func get_rage() -> float:
	return _rage


## Eye positions in the head mount's space (metres, rest pose), left then right.
func get_eye_offsets() -> Array[Vector3]:
	return _eyes


func _process(delta: float) -> void:
	if _skin == null:
		return
	_time += delta
	_rage = move_toward(_rage, _rage_target, delta * 2.5)
	_cast = move_toward(_cast, 1.0 if _casting else 0.0, delta * 5.0)
	_flash = maxf(0.0, _flash - delta * 1.6)
	_shock = maxf(0.0, _shock - delta * 5.0)
	_shade = maxf(0.0, _shade - delta * 2.2)
	_settle_tape(delta)
	_apply_mood()


func _apply_mood() -> void:
	# A slow heartbeat that quickens with rage.
	var beat := pow(0.5 + 0.5 * sin(_time * (2.2 + _rage * 6.0)), 3.0)
	var core := 0.3 + 0.5 * beat + _rage * (1.3 + 1.2 * beat) + _cast * 2.2 + _flash * 3.0
	var limbs := 0.45 * _rage * _rage + _cast * 0.7 + _flash * 0.8
	var paint := 0.55 + _rage * 1.7 + _cast * 1.6 + _flash * 4.0
	var eyes := 4.5 + _rage * 5.0 + beat * (0.5 + _rage * 2.0) + _cast * 3.0 + _flash * 12.0
	if _stunned:
		# Dying coals: mostly dark, with weak, irregular flares.
		var gutter := maxf(0.0, _noise.get_noise_1d(_time * 3.0)) * 2.0
		core = 0.05 + 0.22 * gutter
		limbs = 0.0
		paint = 0.12 + 0.35 * gutter
		eyes = 0.5 + 2.2 * gutter
	if _captured:
		core *= 0.4
		paint *= 0.4
		eyes *= 0.4
	_skin.set_shader_parameter(&"core_energy", core * 1.5)
	_skin.set_shader_parameter(&"limb_energy", limbs)
	_skin.set_shader_parameter(&"paint_energy", paint)
	_skin.set_shader_parameter(&"pulse", beat)
	# The taser draws a hard cyan rim and crackling veins; the hide itself stays dark and readable.
	_skin.set_shader_parameter(&"shock", _shock * (0.75 + 0.25 * sin(_time * 71.0)))
	_skin.set_shader_parameter(&"shock_time", _time)
	_skin.set_shader_parameter(&"shade", _shade)
	_skin.set_shader_parameter(&"rim_energy", 0.3 + 0.35 * _rage + 0.4 * _cast)
	# The vein mask is anchored to the ribcage, so it has to follow the chest bone.
	var chest := _skeleton.get_bone_global_pose(_chest_bone)
	_skin.set_shader_parameter(&"chest_from_model", Transform3D(Basis.from_scale(Vector3.ONE * _driver.get_unit_scale())) * chest.affine_inverse())
	_eye.emission_energy_multiplier = eyes
	_eye_light.light_energy = eyes * 0.03
	_chest_light.light_energy = (core + paint) * 0.07
	_ash.amount_ratio = clampf(0.4 + 0.6 * _rage + _shade, 0.0, 1.0)
	_sparks.amount_ratio = clampf(0.04 + _rage * 0.96 + (0.45 if _stunned else 0.0) + _flash + _cast, 0.0, 1.0)


# --- Hide ------------------------------------------------------------------------------

func _make_skin() -> void:
	_skin = ShaderMaterial.new()
	_skin.shader = SKIN_SHADER
	var painted := _mesh.mesh.surface_get_material(0) as BaseMaterial3D
	if painted and painted.albedo_texture:
		_skin.set_shader_parameter(&"paint_map", painted.albedo_texture)
	var charred := Mats.pbr(SKIN_SET, 2.6, Color.WHITE, false)
	if charred:
		_skin.set_shader_parameter(&"detail_albedo", charred.albedo_texture)
		_skin.set_shader_parameter(&"detail_normal", charred.normal_texture)
		_skin.set_shader_parameter(&"detail_roughness", charred.roughness_texture)
	_skin.set_shader_parameter(&"vein_map", _vein_texture())
	_skin.set_shader_parameter(&"ember_color", EMBER)
	# Centre of the ribcage, in the chest bone's own axes.
	var chest := _driver.get_bind_transform(CHEST_BONE)
	var middle := (_driver.get_bind_transform(WAIST_BONE).origin + _driver.get_bind_transform(NECK_BONE).origin) * 0.5
	_skin.set_shader_parameter(&"chest_center", chest.basis.inverse() * (middle - chest.origin))
	_skin.set_shader_parameter(&"chest_radius", _driver.get_bind_transform(WAIST_BONE).origin.distance_to(_driver.get_bind_transform(NECK_BONE).origin) * 1.25)
	for surface in _mesh.mesh.get_surface_count():
		_mesh.set_surface_override_material(surface, _skin)
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


## Molten vein mask: hairline fractures along cell edges, broken up into
## irregular patches so the glow reads as wounds rather than a net.
func _vein_texture() -> ImageTexture:
	var cells := FastNoiseLite.new()
	cells.noise_type = FastNoiseLite.TYPE_CELLULAR
	cells.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	cells.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	cells.cellular_jitter = 1.0
	cells.frequency = 0.02
	cells.fractal_type = FastNoiseLite.FRACTAL_NONE
	cells.domain_warp_enabled = true
	cells.domain_warp_amplitude = 22.0
	cells.domain_warp_frequency = 0.03
	cells.seed = 666
	var patches := FastNoiseLite.new()
	patches.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	patches.frequency = 0.011
	patches.fractal_octaves = 2
	patches.seed = 413
	var size := 256
	var edges := cells.get_seamless_image(size, size, false, false, 0.1, true)
	var cover := patches.get_seamless_image(size, size, false, false, 0.1, true)
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var line := 1.0 - smoothstep(0.0, 0.05, edges.get_pixel(x, y).r)
			var glow := line * smoothstep(0.46, 0.7, cover.get_pixel(x, y).r)
			# White-hot in the middle of a fissure, deep orange at its lips.
			image.set_pixel(x, y, Color(1.0, 0.42 + 0.5 * line * line, 0.1 + 0.5 * line * line * line) * glow)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


# --- Eyes --------------------------------------------------------------------------------

func _build_eyes(head: Node3D) -> void:
	_eye = StandardMaterial3D.new()
	_eye.albedo_color = EYE_COLOR
	_eye.emission_enabled = true
	_eye.emission = EYE_COLOR
	_eye.emission_energy_multiplier = 5.0
	_eye.roughness = 0.2
	_eyes = _find_eyes()
	var skull := _driver.get_bind_transform(HEAD_BONE).origin.distance_to(_driver.get_bind_transform(CROWN_BONE).origin)
	var orb := SphereMesh.new()
	orb.radius = skull * 0.055
	orb.height = orb.radius * 2.0
	orb.radial_segments = 16
	orb.rings = 8
	orb.material = _eye
	for i in _eyes.size():
		var eye := MeshInstance3D.new()
		eye.name = "EyeL" if i == 0 else "EyeR"
		eye.mesh = orb
		# Sunk into the socket so only a hot crescent shows under the brow.
		eye.position = _eyes[i] + Vector3(0.0, 0.0, orb.radius * 0.55)
		eye.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		head.add_child(eye)


## Finds the painted eye sockets on the face: the hottest texels of the skull's front, one per side.
## Returned in the head mount's space; falls back to a measured guess if the paint cannot be read.
func _find_eyes() -> Array[Vector3]:
	var head := _driver.get_bind_transform(HEAD_BONE).origin
	var crown := _driver.get_bind_transform(CROWN_BONE).origin
	var skull := head.distance_to(crown)
	var guess: Array[Vector3] = [Vector3(-skull * 0.16, skull * 0.3, -skull * 0.62), Vector3(skull * 0.16, skull * 0.3, -skull * 0.62)]
	var painted := _mesh.mesh.surface_get_material(0) as BaseMaterial3D
	var image: Image = painted.albedo_texture.get_image() if painted and painted.albedo_texture else null
	if image == null or image.is_empty():
		return guess
	if image.is_compressed() and image.decompress() != OK:
		return guess
	var to_root := _driver.get_bind_mesh_transform()
	var arrays := _mesh.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if uvs.size() != vertices.size():
		return guess
	var size := image.get_size()
	var sum: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	var weight: Array[float] = [0.0, 0.0]
	for v in vertices.size():
		var at := to_root * vertices[v] - head
		# Only the front of the face, between jaw and brow.
		if absf(at.x) > skull * 0.42 or absf(at.x) < skull * 0.04 or at.y < -skull * 0.05 or at.y > skull * 0.75 or at.z > -skull * 0.25:
			continue
		var texel := image.get_pixel(clampi(int(uvs[v].x * size.x), 0, size.x - 1), clampi(int(uvs[v].y * size.y), 0, size.y - 1))
		var hot := texel.r - maxf(texel.g, texel.b) * 1.15
		if hot < 0.25 or texel.r < 0.55:
			continue
		var side := 0 if at.x < 0.0 else 1
		sum[side] += at * hot
		weight[side] += hot
	if weight[0] <= 0.0 or weight[1] <= 0.0:
		return guess
	return [sum[0] / weight[0], sum[1] / weight[1]]


# --- Lights and particles --------------------------------------------------------------

func _build_lights(head: Node3D, chest: Node3D) -> void:
	_eye_light = OmniLight3D.new()
	_eye_light.name = "EyeGlow"
	_eye_light.position = (_eyes[0] + _eyes[1]) * 0.5 + Vector3(0.0, 0.0, -0.12)
	_eye_light.light_color = EYE_COLOR
	_eye_light.omni_range = 2.2
	_eye_light.omni_attenuation = 1.5
	_eye_light.light_volumetric_fog_energy = 1.6
	_eye_light.shadow_enabled = false
	head.add_child(_eye_light)
	_chest_light = OmniLight3D.new()
	_chest_light.name = "EmberGlow"
	_chest_light.position = Vector3(0.0, -0.1, -0.34)
	_chest_light.light_color = EMBER
	_chest_light.omni_range = 2.1
	_chest_light.omni_attenuation = 1.6
	_chest_light.light_volumetric_fog_energy = 0.6
	_chest_light.shadow_enabled = false
	chest.add_child(_chest_light)


func _build_particles(chest: Node3D) -> void:
	var drift := ParticleProcessMaterial.new()
	drift.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	drift.emission_sphere_radius = 0.36
	drift.direction = Vector3.UP
	drift.spread = 70.0
	drift.gravity = Vector3(0.0, 0.22, 0.0)
	drift.initial_velocity_min = 0.05
	drift.initial_velocity_max = 0.3
	drift.scale_min = 0.014
	drift.scale_max = 0.045
	drift.turbulence_enabled = true
	drift.turbulence_noise_strength = 0.35
	drift.turbulence_noise_scale = 2.0
	drift.turbulence_influence_min = 0.05
	drift.turbulence_influence_max = 0.2
	drift.color_ramp = _ramp([0.0, 0.2, 0.7, 1.0], [Color(0.05, 0.045, 0.04, 0.0), Color(0.07, 0.06, 0.055, 0.85), Color(0.06, 0.05, 0.05, 0.6), Color(0.05, 0.04, 0.04, 0.0)])
	_ash = _particles("Ash", drift, _speck_material(false), 60, 2.6)
	_ash.position = Vector3(0.0, -0.1, 0.0)
	chest.add_child(_ash)

	var burst := ParticleProcessMaterial.new()
	burst.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	burst.emission_sphere_radius = 0.26
	burst.direction = Vector3.UP
	burst.spread = 80.0
	burst.gravity = Vector3(0.0, -1.6, 0.0)
	burst.initial_velocity_min = 0.6
	burst.initial_velocity_max = 2.4
	burst.scale_min = 0.008
	burst.scale_max = 0.022
	# Over-bright so sparks clear the bloom threshold.
	burst.color = Color(2.6, 1.3, 0.45)
	burst.color_ramp = _ramp([0.0, 0.5, 1.0], [Color(1.0, 0.95, 0.8, 1.0), Color(1.0, 0.5, 0.15, 0.9), Color(0.5, 0.05, 0.0, 0.0)])
	_sparks = _particles("Sparks", burst, _speck_material(true), 64, 0.9)
	_sparks.position = Vector3(0.0, -0.1, 0.0)
	chest.add_child(_sparks)


func _particles(node_name: String, process: ParticleProcessMaterial, material: Material, amount: int, lifetime: float) -> GPUParticles3D:
	var speck := QuadMesh.new()
	speck.size = Vector2.ONE
	speck.material = material
	var particles := GPUParticles3D.new()
	particles.name = node_name
	particles.amount = amount
	particles.lifetime = lifetime
	particles.randomness = 1.0
	particles.local_coords = false
	particles.process_material = process
	particles.draw_pass_1 = speck
	particles.visibility_aabb = AABB(Vector3.ONE * -4.0, Vector3.ONE * 8.0)
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return particles


func _speck_material(additive: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	var falloff := Gradient.new()
	falloff.set_color(0, Color(1, 1, 1, 1))
	falloff.set_color(1, Color(1, 1, 1, 0))
	var dot := GradientTexture2D.new()
	dot.width = 32
	dot.height = 32
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(1.0, 0.5)
	dot.gradient = falloff
	mat.albedo_texture = dot
	return mat


func _ramp(offsets: Array, colors: Array) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array(offsets)
	gradient.colors = PackedColorArray(colors)
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture


## The taser's electric rim and vein crackle: `amount` 0..1. It fades by itself.
func set_shock(amount: float) -> void:
	_shock = maxf(_shock, clampf(amount, 0.0, 1.0))


## How many tape bands are showing right now.
func get_tape_count() -> int:
	var count := 0
	for tier in _tape:
		for band: MeshInstance3D in tier:
			if band.visible:
				count += 1
	return count


# --- Duct tape ---------------------------------------------------------------------------

const TAPE_CORE: Array[String] = ["Hips", "Spine02", "Spine01", "Spine", "neck", "LeftShoulder", "RightShoulder"]

## Builds every band the three bind levels can show and hides them. Each band is fitted to
## the skin round its slice of the body and hung on that bone with a BoneAttachment3D, so it
## stays put however the ragdoll is dragged.
##   level 1  chest and upper arms
##   level 2  forearms, wrists, knees and shins
##   level 3  crossed straps over the torso, the waist, more leg wraps, a strip across the jaw
func _build_tape() -> void:
	_scan_skin()
	if _tape_points.is_empty():
		return
	_torso_band(1, 0.44, 0.075, 0.0)
	_torso_band(1, 0.74, 0.07, 0.0)
	_torso_band(3, 0.58, 0.085, 0.5)
	_torso_band(3, 0.58, 0.085, -0.5)
	_torso_band(3, 0.12, 0.08, 0.0)
	for side: String in ["Left", "Right"]:
		_limb_band(1, side + "Arm", side + "ForeArm", 0.5, 0.062, side + "Shoulder")
		_limb_band(2, side + "ForeArm", side + "Hand", 0.4, 0.055)
		_limb_band(2, side + "ForeArm", side + "Hand", 0.88, 0.045)
		_limb_band(2, side + "UpLeg", side + "Leg", 0.82, 0.07)
		_limb_band(2, side + "Leg", side + "Foot", 0.22, 0.065)
		_limb_band(3, side + "Arm", side + "ForeArm", 0.86, 0.055)
		_limb_band(3, side + "UpLeg", side + "Leg", 0.42, 0.075)
		_limb_band(3, side + "Leg", side + "Foot", 0.68, 0.065)
	_jaw_strip()
	# Only needed for the fitting.
	_tape_points.clear()
	_tape_bones.clear()


## Rest-pose position (ragdoll space) and dominant bone of every skin vertex.
func _scan_skin() -> void:
	var skin := _mesh.skin
	var bind_bone := PackedInt32Array()
	for bind in skin.get_bind_count():
		var bone := skin.get_bind_bone(bind)
		if bone < 0:
			bone = _skeleton.find_bone(skin.get_bind_name(bind))
		bind_bone.append(bone)
	var to_root := _driver.get_bind_mesh_transform()
	for surface in _mesh.mesh.get_surface_count():
		var arrays := _mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if vertices.is_empty() or joints.is_empty():
			continue
		@warning_ignore("integer_division")
		var per := joints.size() / vertices.size()
		for v in vertices.size():
			var best := 0
			for k in range(1, per):
				if weights[v * per + k] > weights[v * per + best]:
					best = k
			_tape_points.append(to_root * vertices[v])
			_tape_bones.append(bind_bone[joints[v * per + best]])


## A band round a limb, `along` (0..1) of the way from `bone` to `tip`. `also` names a
## neighbouring bone whose skin counts too (this rig hangs most of the upper arm on the shoulder).
func _limb_band(level: int, bone: String, tip: String, along: float, width: float, also: String = "") -> void:
	var from := _driver.get_bind_transform(bone).origin
	var to := _driver.get_bind_transform(tip).origin
	var axis := (to - from).normalized()
	var bones := PackedInt32Array([_skeleton.find_bone(bone), _skeleton.find_bone(tip)])
	if not also.is_empty():
		bones.append(_skeleton.find_bone(also))
	# Only this limb's own flesh: nothing further from the bone than about half its length.
	var reach := clampf(from.distance_to(to) * 0.55, 0.14, 0.3)
	_add_band(level, bone, bones, from.lerp(to, along), axis, Vector3.RIGHT if absf(axis.x) < 0.8 else Vector3.BACK, width, TAU, 0.0, reach)


## A band round the trunk, `along` (0..1) of the way from waist to neck; `slant` tips it into a diagonal strap.
func _torso_band(level: int, along: float, width: float, slant: float) -> void:
	var waist := _driver.get_bind_transform(WAIST_BONE).origin
	var neck := _driver.get_bind_transform(NECK_BONE).origin
	var bones := PackedInt32Array()
	for bone_name in TAPE_CORE:
		bones.append(_skeleton.find_bone(bone_name))
	var bone := WAIST_BONE if along < 0.3 else ("Spine01" if along < 0.6 else CHEST_BONE)
	_add_band(level, bone, bones, waist.lerp(neck, along), (neck - waist).normalized(), Vector3.RIGHT, width, TAU, slant)


## One strip slapped across the snout, open at the back of the head.
func _jaw_strip() -> void:
	var head := _driver.get_bind_transform(HEAD_BONE).origin
	var crown := _driver.get_bind_transform(CROWN_BONE).origin
	var front := Vector3.FORWARD
	var bones := PackedInt32Array([_skeleton.find_bone(HEAD_BONE), _skeleton.find_bone(CROWN_BONE)])
	if _skeleton.find_bone("headfront") >= 0:
		front = (_driver.get_bind_transform("headfront").origin - head).normalized()
		bones.append(_skeleton.find_bone("headfront"))
	_add_band(3, HEAD_BONE, bones, head + (crown - head) * 0.12, (crown - head).normalized(), front, 0.055, 3.5, 0.0)


## Measures the skin of `bones` in a slice round `centre` and wraps a band of tape to fit.
## `side` is the direction the band's first half-axis runs in (and where an open arc faces);
## skin further than `reach` from the slice's centre line is somebody else's.
## A limb's band is hung on whichever of `bones` carries most of that skin (`bone` if in doubt),
## so it moves exactly as the flesh under it does.
func _add_band(level: int, bone: String, bones: PackedInt32Array, centre: Vector3, axis: Vector3, side: Vector3,
		width: float, arc: float, slant: float, reach: float = INF) -> void:
	side = (side - axis * side.dot(axis)).normalized()
	var depth := side.cross(axis)
	var across := PackedFloat32Array()
	var through := PackedFloat32Array()
	var carried: Dictionary = {}
	for v in _tape_points.size():
		if not bones.has(_tape_bones[v]):
			continue
		var offset := _tape_points[v] - centre
		var lift := offset.dot(axis)
		if absf(lift) > width * 0.6 or (offset - axis * lift).length() > reach:
			continue
		across.append(offset.dot(side))
		through.append(offset.dot(depth))
		carried[_tape_bones[v]] = int(carried.get(_tape_bones[v], 0)) + 1
	if across.size() < 8:
		return
	var most := 0
	for carrier: int in carried:
		# Limbs only: the trunk's bands stay on the spine however much shoulder they cross.
		if is_finite(reach) and int(carried[carrier]) > most:
			most = carried[carrier]
			bone = _skeleton.get_bone_name(carrier)
	across.sort()
	through.sort()
	var last := across.size() - 1
	var low := Vector2(across[int(last * 0.03)], through[int(last * 0.03)])
	var high := Vector2(across[int(last * 0.97)], through[int(last * 0.97)])
	# The bone rarely runs down the middle of the flesh: centre the band on the skin itself.
	var middle := centre + side * (low.x + high.x) * 0.5 + depth * (low.y + high.y) * 0.5
	var rx := (high.x - low.x) * 0.5 * 1.07 + 0.008
	var rz := (high.y - low.y) * 0.5 * 1.07 + 0.008
	var frame := Basis(side, axis, depth)
	if slant != 0.0:
		frame = Basis(depth, slant) * frame
		rx /= cos(slant)
	var bands: Array = _tape[level]
	var band := MeshInstance3D.new()
	band.name = "Tape%d_%d" % [level, bands.size()]
	band.mesh = Parts.band(rx, rz, width, arc, float(bands.size()) + level * 5.0)
	band.material_override = Parts.tape()
	band.transform = Transform3D(frame, middle - _driver.get_bind_transform(bone).origin)
	band.visible = false
	if not _tape_mounts.has(bone):
		_tape_mounts[bone] = _driver.make_attachment(bone, "Tape_%s" % bone)
	(_tape_mounts[bone] as Node3D).add_child(band)
	bands.append(band)


func _on_bind_changed(level: int) -> void:
	for tier in range(1, _tape.size()):
		for band: MeshInstance3D in _tape[tier]:
			var wrapped := tier <= level
			if wrapped and not band.visible:
				# Slapped on loose, then cinched tight.
				band.scale = Vector3.ONE * 1.35
				_tape_settle = 0.5
			band.visible = wrapped


func _settle_tape(delta: float) -> void:
	if _tape_settle <= 0.0:
		return
	_tape_settle -= delta
	for tier in _tape:
		for band: MeshInstance3D in tier:
			band.scale = band.scale.lerp(Vector3.ONE, minf(1.0, delta * 16.0)) if _tape_settle > 0.0 else Vector3.ONE
