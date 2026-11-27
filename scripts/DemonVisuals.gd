extends Node3D
## Anatomy and presence of the demon.
##
## Sculpts organic meshes (lofted tubes and ellipsoids, never boxes) straight
## onto each ragdoll segment: a wasp-waisted chest with protruding ribs and a
## knobbed spine, an elongated horned skull with carved eye sockets and a
## hanging jaw, and over-long limbs ending in splayed claws. Skin is a real
## charred-bark PBR set with a Fresnel rim and ember cracks that pulse; claws,
## teeth, ribs and horns use a scratched ivory set.
## Also owns the eye glow, the chest ember light and the ash / spark particles,
## and blends all of them with the demon's mood.

const Ragdoll := preload("res://scripts/DemonRagdoll.gd")
const Mats := preload("res://scripts/MaterialLibrary.gd")

const SKIN_SET := "demon/charred_skin"
const BONE_SET := "demon/cracked_bone"
const EMBER := Color(1.0, 0.36, 0.06)
const EYE_COLOR := Color(1.0, 0.44, 0.06)

var _core: StandardMaterial3D
var _skin: StandardMaterial3D
var _bone: StandardMaterial3D
var _eye: StandardMaterial3D
var _void: StandardMaterial3D
var _eye_light: OmniLight3D
var _chest_light: OmniLight3D
var _ash: GPUParticles3D
var _sparks: GPUParticles3D
var _noise := FastNoiseLite.new()

var _time := 0.0
var _rage := 0.0
var _rage_target := 0.0
var _stunned := false
var _captured := false
var _flash := 0.0


## Lofted-mesh accumulator: every primitive is smooth-shaded and closed.
class Sculpt:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var noise: FastNoiseLite

	func _init(shared_noise: FastNoiseLite) -> void:
		noise = shared_noise

	## Skin a tube along `path`; `radii[i]` is the ring's half-width along `hint` and half-depth across it.
	func tube(path: PackedVector3Array, radii: PackedVector2Array, sides: int = 9, rough: float = 0.0,
			hint: Vector3 = Vector3.RIGHT, warp: Callable = Callable()) -> void:
		var count := path.size()
		if count < 2 or radii.size() != count:
			return
		var base := vertices.size()
		var side := hint
		for i in count:
			var tangent := (path[mini(i + 1, count - 1)] - path[maxi(i - 1, 0)]).normalized()
			side -= tangent * side.dot(tangent)
			if side.length_squared() < 0.0001:
				side = tangent.cross(Vector3.UP if absf(tangent.y) < 0.9 else Vector3.RIGHT)
			side = side.normalized()
			var other := tangent.cross(side)
			for s in sides:
				var angle := TAU * float(s) / float(sides)
				var offset := side * (cos(angle) * radii[i].x) + other * (sin(angle) * radii[i].y)
				var point := path[i] + offset
				if rough > 0.0:
					# Lumps scale with the local girth, so thin fingers stay thin.
					point += offset * noise.get_noise_3dv(point * 14.0) * rough
				if warp.is_valid():
					point = warp.call(point)
				vertices.append(point)
				normals.append(Vector3.ZERO)
		var cap_start := vertices.size()
		vertices.append(path[0])
		normals.append(Vector3.ZERO)
		var cap_end := vertices.size()
		vertices.append(path[count - 1])
		normals.append(Vector3.ZERO)
		for i in count - 1:
			var inside := (path[i] + path[i + 1]) * 0.5
			for s in sides:
				var next := (s + 1) % sides
				var a := base + i * sides + s
				var b := base + (i + 1) * sides + s
				var c := base + (i + 1) * sides + next
				var d := base + i * sides + next
				_face(a, b, c, inside)
				_face(a, c, d, inside)
		var last := base + (count - 1) * sides
		for s in sides:
			var next := (s + 1) % sides
			_face(cap_start, base + s, base + next, path[1])
			_face(cap_end, last + s, last + next, path[count - 2])
		for i in range(base, vertices.size()):
			normals[i] = normals[i].normalized() if normals[i].length_squared() > 1e-14 else Vector3.UP

	## Ellipsoid with semi-axes `radii` along the axes of `basis`.
	func blob(center: Vector3, radii: Vector3, basis: Basis = Basis.IDENTITY, rough: float = 0.0,
			rings: int = 7, sides: int = 9, warp: Callable = Callable()) -> void:
		var path := PackedVector3Array()
		var ring_radii := PackedVector2Array()
		for k in rings + 1:
			var angle := PI * float(k) / float(rings)
			path.append(center + basis.y * (-cos(angle) * radii.y))
			ring_radii.append(Vector2(radii.x, radii.z) * maxf(sin(angle), 0.03))
		tube(path, ring_radii, sides, rough, basis.x, warp)

	## Adds one triangle facing away from `inside` and feeds its normal to the corners.
	func _face(a: int, b: int, c: int, inside: Vector3) -> void:
		var pa := vertices[a]
		var pb := vertices[b]
		var pc := vertices[c]
		var normal := (pb - pa).cross(pc - pa)
		if normal.length_squared() < 1e-18:
			return
		if normal.dot((pa + pb + pc) / 3.0 - inside) < 0.0:
			normal = -normal
			var swap := b
			b = c
			c = swap
		# Front faces wind clockwise in Godot.
		indices.append(a)
		indices.append(c)
		indices.append(b)
		normals[a] += normal
		normals[b] += normal
		normals[c] += normal

	func add_to(mesh: ArrayMesh, material: Material) -> void:
		if indices.is_empty():
			return
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)


# --- Public API ----------------------------------------------------------------------

## Called by the ragdoll once its segments exist.
func build(ragdoll: Node3D) -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 1.0
	_noise.seed = 1313
	_make_materials()
	var body := ragdoll as Ragdoll
	for part in Ragdoll.Part.size():
		var skin := Sculpt.new(_noise)
		var bone := Sculpt.new(_noise)
		var glow := Sculpt.new(_noise)
		var dark := Sculpt.new(_noise)
		var skin_material := _skin
		match part:
			Ragdoll.Part.PELVIS:
				_sculpt_pelvis(skin, bone)
			Ragdoll.Part.TORSO:
				_sculpt_torso(skin, bone)
				skin_material = _core
			Ragdoll.Part.HEAD:
				_sculpt_head(skin, bone, glow, dark)
			Ragdoll.Part.UPPER_ARM_L, Ragdoll.Part.UPPER_ARM_R:
				_sculpt_upper_arm(skin, bone)
			Ragdoll.Part.LOWER_ARM_L:
				_sculpt_lower_arm(skin, bone, -1.0)
			Ragdoll.Part.LOWER_ARM_R:
				_sculpt_lower_arm(skin, bone, 1.0)
			Ragdoll.Part.UPPER_LEG_L, Ragdoll.Part.UPPER_LEG_R:
				_sculpt_upper_leg(skin, bone)
			Ragdoll.Part.LOWER_LEG_L, Ragdoll.Part.LOWER_LEG_R:
				_sculpt_lower_leg(skin, bone)
		var mesh := ArrayMesh.new()
		skin.add_to(mesh, skin_material)
		bone.add_to(mesh, _bone)
		dark.add_to(mesh, _void)
		glow.add_to(mesh, _eye)
		var instance := MeshInstance3D.new()
		instance.name = "Anatomy"
		instance.mesh = mesh
		instance.extra_cull_margin = 0.2
		body.get_body(part).add_child(instance)
	_build_lights(body.get_body(Ragdoll.Part.HEAD), body.get_body(Ragdoll.Part.TORSO))
	_build_particles(body.get_body(Ragdoll.Part.TORSO))
	_apply_mood(0.0)


## rage 0..1 drives eyes, ember cracks and sparks; stunned gutters them; captured all but puts them out.
func set_mood(rage: float, stunned: bool, captured: bool) -> void:
	_rage_target = clampf(rage, 0.0, 1.0)
	_stunned = stunned
	_captured = captured


## One bright flare of the eyes and cracks (the moment it snaps into rage).
func flash() -> void:
	_flash = 1.0


func get_rage() -> float:
	return _rage


func _process(delta: float) -> void:
	if _core == null:
		return
	_time += delta
	_rage = move_toward(_rage, _rage_target, delta * 2.5)
	_flash = maxf(0.0, _flash - delta * 1.6)
	_apply_mood(delta)


func _apply_mood(_delta: float) -> void:
	# A slow heartbeat that quickens with rage.
	var beat := pow(0.5 + 0.5 * sin(_time * (2.2 + _rage * 6.0)), 3.0)
	var ember := 0.35 + 0.55 * beat + _rage * (0.9 + 0.9 * beat) + _flash * 2.5
	var eyes := 4.5 + _rage * 5.0 + beat * (0.5 + _rage * 2.0) + _flash * 12.0
	if _stunned:
		# Guttering: mostly dark, with weak, irregular flares.
		var gutter := maxf(0.0, _noise.get_noise_1d(_time * 3.0)) * 2.0
		ember = 0.08 + 0.35 * gutter
		eyes = 0.5 + 2.2 * gutter
	if _captured:
		ember *= 0.4
		eyes *= 0.4
	_core.emission_energy_multiplier = ember * 1.6
	# Limbs and skull only crack open as the rage builds.
	_skin.emission_energy_multiplier = ember * 0.45 * _rage * _rage
	_eye.emission_energy_multiplier = eyes
	if _eye_light:
		_eye_light.light_energy = eyes * 0.028
		_chest_light.light_energy = ember * 0.1
	if _ash:
		_ash.amount_ratio = clampf(0.4 + 0.6 * _rage, 0.0, 1.0)
		_sparks.amount_ratio = clampf(0.04 + _rage * 0.96 + (0.45 if _stunned else 0.0) + _flash, 0.0, 1.0)


# --- Materials -----------------------------------------------------------------------

func _make_materials() -> void:
	var cracks := _crack_texture()
	_core = _skin_material(Color(0.34, 0.30, 0.28), cracks)
	_skin = _skin_material(Color(0.30, 0.27, 0.25), cracks)
	var ivory := Mats.pbr(BONE_SET, 3.0, Color(0.40, 0.40, 0.43), false, 0.9, 1.2)
	if ivory:
		_bone = ivory.duplicate() as StandardMaterial3D
	else:
		_bone = StandardMaterial3D.new()
		_bone.albedo_color = Color(0.33, 0.31, 0.27)
		_bone.roughness = 0.55
	_bone.rim_enabled = true
	_bone.rim = 0.3
	_eye = StandardMaterial3D.new()
	_eye.albedo_color = EYE_COLOR
	_eye.emission_enabled = true
	_eye.emission = EYE_COLOR
	_eye.emission_energy_multiplier = 5.0
	_void = StandardMaterial3D.new()
	_void.albedo_color = Color(0.004, 0.003, 0.003)
	_void.roughness = 1.0
	_void.metallic_specular = 0.0


func _skin_material(tint: Color, cracks: Texture2D) -> StandardMaterial3D:
	var base := Mats.pbr(SKIN_SET, 2.6, tint, false, 0.85, 1.6)
	var mat: StandardMaterial3D
	if base:
		mat = base.duplicate() as StandardMaterial3D
	else:
		mat = StandardMaterial3D.new()
		mat.albedo_color = tint * 0.5
		mat.roughness = 0.8
		mat.uv1_triplanar = true
		mat.uv1_scale = Vector3.ONE * 2.6
	# Grazing-angle sheen keeps the silhouette readable against a dark room.
	mat.rim_enabled = true
	mat.rim = 0.65
	mat.rim_tint = 0.3
	mat.emission_enabled = true
	mat.emission = Color.WHITE
	mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	mat.emission_texture = cracks
	mat.emission_energy_multiplier = 0.0
	return mat


## Ember emission mask: hairline fractures along cell edges, broken up into
## irregular patches so the glow reads as wounds rather than a net.
func _crack_texture() -> ImageTexture:
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


# --- Lights and particles --------------------------------------------------------------

func _build_lights(head: RigidBody3D, torso: RigidBody3D) -> void:
	_eye_light = OmniLight3D.new()
	_eye_light.name = "EyeGlow"
	_eye_light.position = Vector3(0.0, 0.02, -0.15)
	_eye_light.light_color = EYE_COLOR
	_eye_light.omni_range = 1.9
	_eye_light.omni_attenuation = 1.5
	_eye_light.light_volumetric_fog_energy = 1.6
	_eye_light.shadow_enabled = false
	head.add_child(_eye_light)
	_chest_light = OmniLight3D.new()
	_chest_light.name = "EmberGlow"
	_chest_light.position = Vector3(0.0, 0.05, -0.24)
	_chest_light.light_color = EMBER
	_chest_light.omni_range = 1.9
	_chest_light.omni_attenuation = 1.6
	_chest_light.light_volumetric_fog_energy = 0.6
	_chest_light.shadow_enabled = false
	torso.add_child(_chest_light)


func _build_particles(torso: RigidBody3D) -> void:
	var drift := ParticleProcessMaterial.new()
	drift.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	drift.emission_sphere_radius = 0.3
	drift.direction = Vector3.UP
	drift.spread = 70.0
	drift.gravity = Vector3(0.0, 0.22, 0.0)
	drift.initial_velocity_min = 0.05
	drift.initial_velocity_max = 0.3
	drift.scale_min = 0.014
	drift.scale_max = 0.04
	drift.turbulence_enabled = true
	drift.turbulence_noise_strength = 0.35
	drift.turbulence_noise_scale = 2.0
	drift.turbulence_influence_min = 0.05
	drift.turbulence_influence_max = 0.2
	drift.color_ramp = _ramp([0.0, 0.2, 0.7, 1.0], [Color(0.05, 0.045, 0.04, 0.0), Color(0.07, 0.06, 0.055, 0.85), Color(0.06, 0.05, 0.05, 0.6), Color(0.05, 0.04, 0.04, 0.0)])
	_ash = _particles("Ash", drift, _speck_material(false), 54, 2.6)
	torso.add_child(_ash)

	var burst := ParticleProcessMaterial.new()
	burst.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	burst.emission_sphere_radius = 0.22
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
	torso.add_child(_sparks)


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


func _ramp(offsets: Array, colors: Array) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array(offsets)
	gradient.colors = PackedColorArray(colors)
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture


# --- Sculpting helpers -------------------------------------------------------------------

## Catmull-Rom smoothed tube through control points. `radii` entries are a float
## (round) or a Vector2 (width, depth).
func _limb(sculpt: Sculpt, points: Array, radii: Array, sides: int = 9, rough: float = 0.1, steps: int = 3,
		warp: Callable = Callable(), hint: Vector3 = Vector3.RIGHT) -> void:
	var path := PackedVector3Array()
	var widths := PackedVector2Array()
	var last := points.size() - 1
	for i in last:
		var p0: Vector3 = points[maxi(i - 1, 0)]
		var p1: Vector3 = points[i]
		var p2: Vector3 = points[i + 1]
		var p3: Vector3 = points[mini(i + 2, last)]
		var r1 := _radius(radii[i])
		var r2 := _radius(radii[i + 1])
		for step in steps:
			var t := float(step) / float(steps)
			path.append(0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t))
			widths.append(r1.lerp(r2, smoothstep(0.0, 1.0, t)))
	path.append(points[last])
	widths.append(_radius(radii[last]))
	sculpt.tube(path, widths, sides, rough, hint, warp)


func _radius(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	return Vector2.ONE * float(value)


## A curved talon: from `base` along `direction`, hooking toward `hook`.
func _claw(bone: Sculpt, base: Vector3, direction: Vector3, hook: Vector3, length: float, radius: float) -> void:
	_limb(bone, [base, base + direction * length * 0.5 + hook * length * 0.12, base + direction * length + hook * length * 0.55],
			[radius, radius * 0.62, radius * 0.06], 6, 0.0, 3)


# --- Anatomy -----------------------------------------------------------------------------
# Each part is modelled in its rigid body's space: origin at the segment centre,
# +Y up the bone, -Z forward, +X the demon's right.

func _sculpt_torso(skin: Sculpt, bone: Sculpt) -> void:
	# Barrel chest pinching to a starved waist; the sternum is sunk between the ribs.
	var sunken := func(v: Vector3) -> Vector3:
		if v.z < 0.0 and v.y > -0.12 and v.y < 0.25:
			var centre := 1.0 - clampf(absf(v.x) / 0.1, 0.0, 1.0)
			v.z += 0.04 * centre * centre
		return v
	_limb(skin, [Vector3(0.0, -0.37, 0.012), Vector3(0.0, -0.27, 0.02), Vector3(0.0, -0.16, 0.034), Vector3(0.0, -0.04, 0.045),
			Vector3(0.0, 0.08, 0.04), Vector3(0.0, 0.19, 0.022), Vector3(0.0, 0.27, 0.004), Vector3(0.0, 0.33, -0.008), Vector3(0.0, 0.43, -0.03)],
			[Vector2(0.07, 0.055), Vector2(0.064, 0.047), Vector2(0.085, 0.062), Vector2(0.135, 0.098), Vector2(0.158, 0.112),
			Vector2(0.165, 0.105), Vector2(0.14, 0.085), Vector2(0.062, 0.056), Vector2(0.036, 0.036)], 16, 0.1, 3, sunken)

	# Seven pairs of ribs standing proud of the skin; the lowest stop short of the sternum.
	for k in 7:
		var t := float(k) / 6.0
		var y := 0.2 - float(k) * 0.048
		var rx := lerpf(0.166, 0.12, t * t) + 0.008
		var rz := lerpf(0.11, 0.084, t * t) + 0.01
		var reach := lerpf(2.8, 2.05, t)
		for side: float in [-1.0, 1.0]:
			var points: Array = []
			var radii: Array = []
			for j in 8:
				var along := float(j) / 7.0
				var angle := lerpf(0.32, reach, along)
				points.append(Vector3(side * rx * sin(angle), y - 0.06 * (angle / PI), 0.036 + rz * cos(angle)))
				radii.append(lerpf(0.0125, 0.0075, absf(along - 0.35) * 1.5))
			_limb(bone, points, radii, 6, 0.0, 2)
	# Sternum blade and collar bones.
	_limb(bone, [Vector3(0.0, 0.235, -0.07), Vector3(0.0, 0.12, -0.066), Vector3(0.0, -0.02, -0.058)], [Vector2(0.02, 0.009), Vector2(0.016, 0.008), Vector2(0.006, 0.004)], 6, 0.0, 2)
	for side: float in [-1.0, 1.0]:
		_limb(bone, [Vector3(side * 0.012, 0.25, -0.072), Vector3(side * 0.11, 0.285, -0.062), Vector3(side * 0.205, 0.262, -0.012)], [0.013, 0.011, 0.014], 6, 0.0, 3)
		# Shoulder knob and a shoulder blade pushing out of the back.
		skin.blob(Vector3(side * 0.215, 0.245, 0.0), Vector3(0.062, 0.058, 0.058), Basis.IDENTITY, 0.12)
		skin.blob(Vector3(side * 0.095, 0.15, 0.108), Vector3(0.055, 0.09, 0.024), Basis(Vector3.UP, -side * 0.35), 0.1)
	# Spine: a ridge of knuckled vertebrae, each with a short barb.
	for k in 10:
		var t := float(k) / 9.0
		var y := lerpf(-0.31, 0.29, t)
		var back := 0.036 + lerpf(0.058, 0.108, sin(t * PI)) - (0.02 if t > 0.85 else 0.0)
		skin.blob(Vector3(0.0, y, back), Vector3(0.021, 0.026, 0.022), Basis.IDENTITY, 0.1, 5, 7)
		_claw(bone, Vector3(0.0, y + 0.004, back + 0.012), Vector3(0.0, 0.25, 1.0).normalized(), Vector3.DOWN, 0.035 + 0.03 * sin(t * PI), 0.009)


func _sculpt_pelvis(skin: Sculpt, bone: Sculpt) -> void:
	# Withered belly rising into the waist.
	_limb(skin, [Vector3(0.0, -0.07, 0.006), Vector3(0.0, 0.02, 0.012), Vector3(0.0, 0.1, 0.016), Vector3(0.0, 0.17, 0.018)],
			[Vector2(0.06, 0.05), Vector2(0.082, 0.06), Vector2(0.068, 0.052), Vector2(0.07, 0.054)], 12, 0.1)
	# Hip bones showing through, with a sacrum between them.
	for side: float in [-1.0, 1.0]:
		bone.blob(Vector3(side * 0.088, 0.015, -0.004), Vector3(0.05, 0.078, 0.058), Basis(Vector3.BACK, -side * 0.42), 0.14, 8, 10)
		skin.blob(Vector3(side * 0.11, -0.045, 0.0), Vector3(0.062, 0.064, 0.062), Basis.IDENTITY, 0.12)
		_claw(bone, Vector3(side * 0.118, 0.06, -0.03), Vector3(side * 0.5, 0.35, -0.8).normalized(), Vector3.DOWN, 0.05, 0.012)
	bone.blob(Vector3(0.0, -0.02, 0.046), Vector3(0.05, 0.07, 0.036), Basis.IDENTITY, 0.12)
	for k in 3:
		_claw(bone, Vector3(0.0, 0.03 - float(k) * 0.035, 0.07), Vector3(0.0, -0.2, 1.0).normalized(), Vector3.DOWN, 0.04, 0.009)


func _sculpt_head(skin: Sculpt, bone: Sculpt, glow: Sculpt, dark: Sculpt) -> void:
	var sockets: Array[Vector3] = [Vector3(-0.043, 0.012, -0.098), Vector3(0.043, 0.012, -0.098)]
	var skull_center := Vector3(0.0, 0.045, 0.055)
	# Deep eye sockets and hollow temples carved into the skull.
	var carve := func(v: Vector3) -> Vector3:
		for socket in sockets:
			var distance := v.distance_to(socket)
			if distance < 0.044:
				var depth := 1.0 - distance / 0.044
				v += (skull_center - v).normalized() * 0.032 * depth * depth * (3.0 - 2.0 * depth)
		var temple := v.distance_to(Vector3(signf(v.x) * 0.095, 0.02, -0.02))
		if temple < 0.05:
			v.x -= signf(v.x) * 0.014 * (1.0 - temple / 0.05)
		return v
	# The cranium sweeps up and back like a blade.
	skin.blob(skull_center, Vector3(0.092, 0.105, 0.175), Basis(Vector3.RIGHT, -0.4), 0.07, 18, 28, carve)
	# Muzzle and a jaw hanging open on stretched sinew.
	_limb(skin, [Vector3(0.0, 0.0, -0.06), Vector3(0.0, -0.034, -0.122), Vector3(0.0, -0.058, -0.168)], [Vector2(0.06, 0.05), Vector2(0.05, 0.034), Vector2(0.032, 0.02)], 10, 0.08)
	_limb(skin, [Vector3(0.0, -0.07, -0.01), Vector3(0.0, -0.118, -0.078), Vector3(0.0, -0.152, -0.148)], [Vector2(0.058, 0.022), Vector2(0.046, 0.018), Vector2(0.024, 0.011)], 10, 0.08)
	for side: float in [-1.0, 1.0]:
		_limb(skin, [Vector3(side * 0.058, -0.02, -0.03), Vector3(side * 0.056, -0.07, -0.055), Vector3(side * 0.044, -0.115, -0.078)], [0.009, 0.006, 0.008], 5, 0.0, 2)
		# Horns raked back from the temples.
		_limb(bone, [Vector3(side * 0.068, 0.1, 0.0), Vector3(side * 0.108, 0.17, 0.07), Vector3(side * 0.122, 0.25, 0.17), Vector3(side * 0.1, 0.31, 0.3)],
				[0.025, 0.019, 0.011, 0.0015], 7, 0.1)
	# Heavy brows slanting down to the bridge of the muzzle, one over each socket.
	for side: float in [-1.0, 1.0]:
		skin.blob(Vector3(side * 0.046, 0.046, -0.086), Vector3(0.04, 0.013, 0.022), Basis(Vector3.BACK, -side * 0.42) * Basis(Vector3.UP, -side * 0.5), 0.12, 6, 8)
	for k in 4:
		var across := lerpf(-0.062, 0.062, float(k) / 3.0)
		var forward := -0.106 + absf(across) * 0.6
		_claw(bone, Vector3(across, 0.078 + absf(across) * 0.1, forward + 0.035), Vector3(across * 2.0, 0.8, 0.8).normalized(), Vector3.BACK, 0.02 + 0.02 * (1.0 - absf(across) / 0.07), 0.007)
	# Crest of barbs down the back of the skull.
	for k in 4:
		var t := float(k) / 3.0
		_claw(bone, Vector3(0.0, 0.14 + t * 0.03, 0.02 + t * 0.15), Vector3(0.0, 0.8, 0.6).normalized(), Vector3.BACK, 0.06 - t * 0.015, 0.011)
	# Needle teeth, uneven, top and bottom.
	for k in 8:
		var angle := lerpf(-1.15, 1.15, float(k) / 7.0)
		var base := Vector3(sin(angle) * 0.03, -0.07, -0.142 - cos(angle) * 0.022)
		_claw(bone, base, Vector3(0.0, -1.0, -0.12).normalized(), Vector3.BACK, 0.02 + 0.02 * absf(_noise.get_noise_1d(float(k) * 7.3)), 0.0062)
	for k in 7:
		var angle := lerpf(-1.1, 1.1, float(k) / 6.0)
		var base := Vector3(sin(angle) * 0.026, -0.132, -0.118 - cos(angle) * 0.022)
		_claw(bone, base, Vector3(0.0, 1.0, -0.1).normalized(), Vector3.BACK, 0.018 + 0.02 * absf(_noise.get_noise_1d(float(k) * 5.1 + 40.0)), 0.0058)
	# Eyes: slanted slits burning at the back of each socket.
	for socket in sockets:
		var slant := Basis(Vector3.BACK, -signf(socket.x) * 0.38)
		dark.blob(socket + Vector3(0.0, 0.0, 0.03), Vector3(0.026, 0.02, 0.012), slant, 0.0, 6, 8)
		glow.blob(socket + Vector3(0.0, -0.002, 0.016), Vector3(0.017, 0.0065, 0.007), slant, 0.0, 6, 8)


func _sculpt_upper_arm(skin: Sculpt, bone: Sculpt) -> void:
	_limb(skin, [Vector3(0.0, 0.29, 0.0), Vector3(0.0, 0.2, 0.004), Vector3(0.0, 0.05, 0.008), Vector3(0.0, -0.12, 0.004), Vector3(0.0, -0.24, 0.0), Vector3(0.0, -0.3, 0.0)],
			[0.05, Vector2(0.036, 0.04), Vector2(0.032, 0.038), Vector2(0.028, 0.031), 0.037, 0.03], 9, 0.14)
	_claw(bone, Vector3(0.0, -0.27, 0.03), Vector3(0.0, -0.45, 1.0).normalized(), Vector3.DOWN, 0.055, 0.012)


func _sculpt_lower_arm(skin: Sculpt, bone: Sculpt, side: float) -> void:
	_limb(skin, [Vector3(0.0, 0.3, 0.0), Vector3(0.0, 0.22, 0.0), Vector3(0.0, 0.0, -0.004), Vector3(0.0, -0.2, 0.0), Vector3(0.0, -0.29, 0.0)],
			[0.036, Vector2(0.03, 0.034), Vector2(0.024, 0.028), Vector2(0.021, 0.022), Vector2(0.028, 0.024)], 9, 0.12)
	# Flat, spread palm.
	_limb(skin, [Vector3(0.0, -0.275, 0.0), Vector3(0.0, -0.33, -0.006), Vector3(0.0, -0.39, -0.012)], [Vector2(0.028, 0.02), Vector2(0.047, 0.015), Vector2(0.05, 0.011)], 8, 0.08)
	var lengths: Array[float] = [0.15, 0.185, 0.175, 0.135]
	for f in 4:
		var across := lerpf(-0.042, 0.042, float(f) / 3.0)
		var direction := Vector3(sin(across * 7.5), -1.0, -0.1).normalized()
		var root := Vector3(across, -0.385, -0.012)
		var knuckle := root + direction * lengths[f] * 0.45 + Vector3(0.0, 0.0, -0.012)
		var joint := root + direction * lengths[f] * 0.8 + Vector3(0.0, 0.0, -0.036)
		var tip := root + direction * lengths[f] + Vector3(0.0, 0.0, -0.07)
		_limb(skin, [root, knuckle, joint, tip], [0.0115, 0.0105, 0.0085, 0.0065], 6, 0.1, 2)
		_claw(bone, tip, (tip - joint).normalized(), Vector3.FORWARD, 0.075, 0.0075)
	# Thumb on the inner edge.
	var thumb_root := Vector3(-side * 0.042, -0.31, -0.012)
	var thumb_direction := Vector3(-side * 0.72, -0.6, -0.36).normalized()
	var thumb_tip := thumb_root + thumb_direction * 0.11
	_limb(skin, [thumb_root, thumb_root + thumb_direction * 0.055 + Vector3(0.0, 0.0, -0.008), thumb_tip], [0.012, 0.01, 0.007], 6, 0.1, 2)
	_claw(bone, thumb_tip, thumb_direction, Vector3.FORWARD, 0.06, 0.0075)


func _sculpt_upper_leg(skin: Sculpt, bone: Sculpt) -> void:
	_limb(skin, [Vector3(0.0, 0.27, 0.0), Vector3(0.0, 0.18, -0.006), Vector3(0.0, 0.0, -0.01), Vector3(0.0, -0.17, -0.004), Vector3(0.0, -0.26, 0.0)],
			[0.058, Vector2(0.046, 0.052), Vector2(0.04, 0.047), Vector2(0.034, 0.038), Vector2(0.044, 0.046)], 10, 0.12)
	bone.blob(Vector3(0.0, -0.255, -0.036), Vector3(0.027, 0.034, 0.018), Basis.IDENTITY, 0.1, 6, 8)


func _sculpt_lower_leg(skin: Sculpt, bone: Sculpt) -> void:
	_limb(skin, [Vector3(0.0, 0.26, 0.0), Vector3(0.0, 0.17, 0.006), Vector3(0.0, 0.0, 0.008), Vector3(0.0, -0.17, 0.002), Vector3(0.0, -0.25, 0.0)],
			[Vector2(0.04, 0.044), Vector2(0.03, 0.04), Vector2(0.024, 0.034), Vector2(0.02, 0.024), Vector2(0.028, 0.03)], 9, 0.12)
	# Long, flat foot with a heel spur and three hooked toes.
	_limb(skin, [Vector3(0.0, -0.235, 0.012), Vector3(0.0, -0.282, -0.05), Vector3(0.0, -0.298, -0.13)], [0.03, Vector2(0.036, 0.022), Vector2(0.044, 0.014)], 8, 0.08)
	_claw(bone, Vector3(0.0, -0.25, 0.03), Vector3(0.0, -0.35, 1.0).normalized(), Vector3.DOWN, 0.085, 0.014)
	for k in 3:
		var across := lerpf(-0.03, 0.03, float(k) / 2.0)
		var direction := Vector3(sin(across * 9.0), 0.0, -1.0).normalized()
		var root := Vector3(across, -0.298, -0.128)
		var tip := root + direction * 0.095 + Vector3(0.0, -0.002, 0.0)
		_limb(skin, [root, root + direction * 0.05 + Vector3(0.0, 0.006, 0.0), tip], [0.0125, 0.011, 0.0085], 6, 0.1, 2)
		_claw(bone, tip, direction, Vector3.DOWN, 0.06, 0.0085)
