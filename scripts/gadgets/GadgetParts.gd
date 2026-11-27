extends RefCounted
## Sculpting kit for the exorcist's gadgets: lathed, swept and wrapped meshes with clean
## normals and UVs, weathered PBR metals, and the textures and particle recipes they share.
## Everything is generated in code and cached, so the gadgets ship without asset files.

static var _cache: Dictionary = {}


# --- Meshes -------------------------------------------------------------------------

## Surface of revolution round +Y. `profile` holds (radius, height) pairs, walked with the
## outside on the right: up an outer wall, inward across a top, down an inner wall.
static func lathe(profile: PackedVector2Array, segments: int = 28) -> ArrayMesh:
	var points: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	var last := profile.size() - 1
	for i in profile.size():
		var tangent := profile[mini(i + 1, last)] - profile[maxi(i - 1, 0)]
		tangent = tangent.normalized() if tangent.length_squared() > 1e-12 else Vector2(0.0, 1.0)
		var out := Vector2(tangent.y, -tangent.x)
		var ring := PackedVector3Array()
		var ring_normals := PackedVector3Array()
		for s in segments:
			var angle := TAU * float(s) / float(segments)
			ring.append(Vector3(profile[i].x * cos(angle), profile[i].y, profile[i].x * sin(angle)))
			ring_normals.append(Vector3(out.x * cos(angle), out.y, out.x * sin(angle)))
		points.append(ring)
		normals.append(ring_normals)
	return _grid(points, normals, true)


## Round tube swept along `path`; `end_scale` tapers the radius toward the last point.
static func tube(path: PackedVector3Array, radius: float, sides: int = 8, end_scale: float = 1.0) -> ArrayMesh:
	var points: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	var last := path.size() - 1
	var normal := Vector3.UP
	for i in path.size():
		var tangent := path[mini(i + 1, last)] - path[maxi(i - 1, 0)]
		tangent = tangent.normalized() if tangent.length_squared() > 1e-12 else Vector3.FORWARD
		normal -= tangent * normal.dot(tangent)
		if normal.length_squared() < 1e-6:
			normal = tangent.cross(Vector3.RIGHT if absf(tangent.x) < 0.9 else Vector3.BACK)
		normal = normal.normalized()
		var binormal := tangent.cross(normal)
		var girth := radius * lerpf(1.0, end_scale, float(i) / float(maxi(1, last)))
		var ring := PackedVector3Array()
		var ring_normals := PackedVector3Array()
		for s in sides:
			var angle := TAU * float(s) / float(sides)
			var out := normal * cos(angle) + binormal * sin(angle)
			ring.append(path[i] + out * girth)
			ring_normals.append(out)
		points.append(ring)
		normals.append(ring_normals)
	return _grid(points, normals, true)


## A strip of tape wrapped round an ellipse about +Y (`rx`, `rz` half-extents, `width` along
## the axis, `arc` radians of wrap). `seed_value` crinkles each band differently.
static func band(rx: float, rz: float, width: float, arc: float = TAU, seed_value: float = 0.0, segments: int = 40) -> ArrayMesh:
	var closed := arc >= TAU - 0.001
	var columns := segments if closed else segments + 1
	var edge := minf(0.006, width * 0.15)
	var heights: Array[float] = [-width * 0.5, -width * 0.5 + edge, width * 0.5 - edge, width * 0.5]
	var tucks: Array[float] = [0.975, 1.0, 1.0, 0.975]
	var tilts: Array[float] = [-0.7, -0.08, 0.08, 0.7]
	var points: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	for row in 4:
		var ring := PackedVector3Array()
		var ring_normals := PackedVector3Array()
		for c in columns:
			var angle := arc * float(c) / float(segments) - (0.0 if closed else arc * 0.5)
			var crinkle := 1.0 + 0.016 * sin(angle * 9.0 + seed_value * 3.1) + 0.011 * sin(angle * 23.0 + seed_value * 7.7)
			var wander := 0.1 * width * sin(angle * 2.0 + seed_value * 1.3)
			ring.append(Vector3(rx * cos(angle) * crinkle * tucks[row], heights[row] + wander, rz * sin(angle) * crinkle * tucks[row]))
			ring_normals.append(Vector3(cos(angle) / rx, tilts[row] / maxf(rx, rz), sin(angle) / rz).normalized())
		points.append(ring)
		normals.append(ring_normals)
	return _grid(points, normals, closed)


static func torus(major: float, minor: float) -> TorusMesh:
	var mesh := TorusMesh.new()
	mesh.inner_radius = major - minor
	mesh.outer_radius = major + minor
	mesh.rings = 36
	mesh.ring_segments = 10
	return mesh


static func ball(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 20
	mesh.rings = 10
	return mesh


static func capsule(radius: float, height: float) -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = maxf(height, radius * 2.0)
	mesh.radial_segments = 16
	mesh.rings = 6
	return mesh


## Adds a shadowless mesh under `parent`. Hand-held models must not shadow the headlamp beam.
static func part(parent: Node3D, mesh: Mesh, material: Material, at: Vector3 = Vector3.ZERO, euler: Vector3 = Vector3.ZERO, size: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	instance.rotation = euler
	instance.scale = size
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
	return instance


## Indexed mesh from a grid of points (`rows[r][c]`); `wrap` joins the last column to the first.
## Each triangle is wound to face along its vertex normals, whatever order the grid was built in.
static func _grid(points: Array[PackedVector3Array], normals: Array[PackedVector3Array], wrap: bool) -> ArrayMesh:
	var rows := points.size()
	var columns := points[0].size()
	var span := columns + (1 if wrap else 0)
	var vertices := PackedVector3Array()
	var vertex_normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	for r in rows:
		for c in span:
			vertices.append(points[r][c % columns])
			vertex_normals.append(normals[r][c % columns])
			uvs.append(Vector2(float(c) / float(maxi(1, span - 1)), float(r) / float(maxi(1, rows - 1))))
	var indices := PackedInt32Array()
	for r in rows - 1:
		for c in span - 1:
			var a := r * span + c
			var d := a + span
			_triangle(indices, vertices, vertex_normals, a, d, d + 1)
			_triangle(indices, vertices, vertex_normals, a, d + 1, a + 1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = vertex_normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _triangle(indices: PackedInt32Array, vertices: PackedVector3Array, normals: PackedVector3Array, a: int, b: int, c: int) -> void:
	var face := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
	if face.length_squared() < 1e-16:
		return
	# Front faces are clockwise, so the right-hand normal has to point into the surface.
	if face.dot(normals[a] + normals[b] + normals[c]) > 0.0:
		indices.append_array([a, c, b])
	else:
		indices.append_array([a, b, c])


# --- Materials -----------------------------------------------------------------------

## Worn metal (or, with `metallic` 0, a worn hard surface): mottled roughness and fine pitting.
static func metal(color: Color, roughness: float, metallic: float = 1.0, bump: float = 0.3) -> StandardMaterial3D:
	var key := "metal:%s:%.2f:%.2f:%.2f" % [color.to_html(), roughness, metallic, bump]
	if _cache.has(key):
		return _cache[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = metallic
	mat.metallic_specular = 0.6
	mat.roughness = roughness
	mat.roughness_texture = _wear()
	mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE
	if bump > 0.0:
		mat.normal_enabled = true
		mat.normal_texture = _bumps()
		mat.normal_scale = bump
	mat.uv1_scale = Vector3(2.0, 2.0, 1.0)
	_cache[key] = mat
	return mat


static func steel() -> StandardMaterial3D:
	return metal(Color(0.15, 0.16, 0.18), 0.62, 0.9, 0.45)


static func iron() -> StandardMaterial3D:
	return metal(Color(0.075, 0.075, 0.085), 0.85, 0.8, 0.7)


static func brass() -> StandardMaterial3D:
	return metal(Color(0.74, 0.54, 0.2), 0.48, 1.0, 0.3)


static func copper() -> StandardMaterial3D:
	return metal(Color(0.8, 0.4, 0.22), 0.42, 1.0, 0.2)


static func rubber() -> StandardMaterial3D:
	return metal(Color(0.03, 0.03, 0.035), 0.95, 0.0, 0.5)


static func leather() -> StandardMaterial3D:
	return metal(Color(0.19, 0.1, 0.055), 0.9, 0.0, 0.8)


static func ceramic() -> StandardMaterial3D:
	return metal(Color(0.8, 0.77, 0.69), 0.5, 0.0, 0.15)


static func cardboard() -> StandardMaterial3D:
	return metal(Color(0.47, 0.34, 0.2), 1.0, 0.0, 0.5)


## Glossy crinkled silver duct tape with faint sacred seals glowing through it.
static func tape() -> StandardMaterial3D:
	if _cache.has("tape"):
		return _cache["tape"]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.8, 0.85)
	mat.metallic = 0.6
	mat.metallic_specular = 0.8
	mat.roughness = 0.34
	mat.roughness_texture = _wear()
	mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE
	mat.normal_enabled = true
	mat.normal_texture = _bumps()
	mat.normal_scale = 1.4
	# A cold sheen so the silver still reads in a dark house; the seals are printed brighter on top
	# (the emission texture is added to the colour, not multiplied by it).
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.215, 0.25)
	mat.emission_energy_multiplier = 0.5
	mat.emission_texture = sigil(256, Color(0.5, 0.4, 0.18))
	mat.uv1_scale = Vector3(4.0, 1.0, 1.0)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cache["tape"] = mat
	return mat


## The lasso's luminous fibre: strands laid up into a rope, glowing brightest along their crowns.
## `turns` is how often the lay repeats along U. Not cached: each rope pulses on its own.
static func rope(energy: float = 2.0, turns: float = 12.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.8, 0.36)
	mat.albedo_texture = twist()
	mat.metallic = 0.25
	mat.roughness = 0.5
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.7, 0.2)
	mat.emission_energy_multiplier = energy
	mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	mat.emission_texture = twist()
	mat.uv1_scale = Vector3(turns, 1.0, 1.0)
	return mat


## Diagonal strand pattern of a laid rope: bright crowns, dark grooves. Tiles in U and V.
static func twist() -> ImageTexture:
	if _cache.has("twist"):
		return _cache["twist"]
	var size := 64
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var strand := 0.5 + 0.5 * sin(TAU * (float(x) / size + 3.0 * float(y) / size))
			var shade := 0.2 + 0.8 * pow(strand, 0.7)
			image.set_pixel(x, y, Color(shade, shade, shade))
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	_cache["twist"] = texture
	return texture


## Unique emissive material for lamps, LEDs and sparks of light.
static func glow(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color.darkened(0.3)
	mat.roughness = 0.3
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat


## Unshaded additive material that takes its colour from the vertices (bolts, halos, seals).
static func additive(texture: Texture2D = null) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.disable_fog = true
	mat.albedo_texture = texture
	return mat


# --- Textures ------------------------------------------------------------------------

static func _wear() -> NoiseTexture2D:
	if _cache.has("wear"):
		return _cache["wear"]
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.045
	noise.fractal_octaves = 4
	noise.seed = 31
	var ramp := Gradient.new()
	ramp.colors = PackedColorArray([Color(0.55, 0.55, 0.55), Color(1.0, 1.0, 1.0)])
	var texture := NoiseTexture2D.new()
	texture.width = 128
	texture.height = 128
	texture.seamless = true
	texture.noise = noise
	texture.color_ramp = ramp
	_cache["wear"] = texture
	return texture


static func _bumps() -> NoiseTexture2D:
	if _cache.has("bumps"):
		return _cache["bumps"]
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.frequency = 0.07
	noise.fractal_octaves = 3
	noise.seed = 77
	var texture := NoiseTexture2D.new()
	texture.width = 128
	texture.height = 128
	texture.seamless = true
	texture.as_normal_map = true
	texture.bump_strength = 5.0
	texture.noise = noise
	_cache["bumps"] = texture
	return texture


## Occult containment seal: twin rings, a pentagram and rune ticks, drawn in `ink` on black.
static func sigil(size: int = 256, ink: Color = Color.WHITE) -> ImageTexture:
	var key := "sigil:%d:%s" % [size, ink.to_html()]
	if _cache.has(key):
		return _cache[key]
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 1.0))
	var centre := Vector2(size, size) * 0.5
	var stroke := maxi(1, size / 96)
	for ring: float in [0.46, 0.39]:
		var steps := size * 5
		for i in steps:
			_dab(image, centre + Vector2.RIGHT.rotated(TAU * float(i) / float(steps)) * ring * size, stroke, ink)
	var star: Array[Vector2] = []
	for i in 5:
		star.append(centre + Vector2.UP.rotated(TAU * float(i) / 5.0) * 0.39 * size)
	for i in 5:
		_stroke(image, star[i], star[(i + 2) % 5], stroke, ink)
	# Rune ticks between the rings.
	for i in 20:
		var direction := Vector2.RIGHT.rotated(TAU * (float(i) + 0.5) / 20.0)
		var across := direction.orthogonal() * 0.02 * size * (1.0 if i % 3 == 0 else -1.0)
		_stroke(image, centre + direction * 0.405 * size - across, centre + direction * 0.445 * size + across, stroke, ink)
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	_cache[key] = texture
	return texture


static func _stroke(image: Image, from: Vector2, to: Vector2, radius: int, ink: Color = Color.WHITE) -> void:
	var steps := int(from.distance_to(to)) + 1
	for i in steps + 1:
		_dab(image, from.lerp(to, float(i) / float(steps)), radius, ink)


static func _dab(image: Image, at: Vector2, radius: int, ink: Color = Color.WHITE) -> void:
	var size := image.get_size()
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			var px := int(at.x) + x
			var py := int(at.y) + y
			if px >= 0 and py >= 0 and px < size.x and py < size.y:
				image.set_pixel(px, py, ink)


## Soft round speck for particles.
static func dot() -> GradientTexture2D:
	if _cache.has("dot"):
		return _cache["dot"]
	var falloff := Gradient.new()
	falloff.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	falloff.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var texture := GradientTexture2D.new()
	texture.width = 32
	texture.height = 32
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.gradient = falloff
	_cache["dot"] = texture
	return texture


# --- Particles -----------------------------------------------------------------------

## World-space speck emitter, off until told otherwise. `speed` and `size` are (min, max).
## Additive specks are over-bright so they clear the bloom threshold.
static func particles(color: Color, amount: int, lifetime: float, speed: Vector2, size: Vector2, gravity: Vector3,
		spread: float = 180.0, one_shot: bool = true, is_additive: bool = true) -> GPUParticles3D:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.03
	process.direction = Vector3.UP
	process.spread = spread
	process.initial_velocity_min = speed.x
	process.initial_velocity_max = speed.y
	process.scale_min = size.x
	process.scale_max = size.y
	process.gravity = gravity
	process.color = Color(color.r * 2.6, color.g * 2.6, color.b * 2.6, color.a) if is_additive else color
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.6, 1.0])
	fade.colors = PackedColorArray([Color(1.0, 1.0, 1.0, 1.0), Color(1.0, 1.0, 1.0, 0.8), Color(1.0, 1.0, 1.0, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	process.color_ramp = ramp
	var speck_material := StandardMaterial3D.new()
	speck_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	speck_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if is_additive:
		speck_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	speck_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	speck_material.billboard_keep_scale = true
	speck_material.vertex_color_use_as_albedo = true
	speck_material.albedo_texture = dot()
	var speck := QuadMesh.new()
	speck.size = Vector2.ONE
	speck.material = speck_material
	var emitter := GPUParticles3D.new()
	emitter.amount = amount
	emitter.lifetime = lifetime
	emitter.one_shot = one_shot
	emitter.explosiveness = 0.92 if one_shot else 0.0
	emitter.randomness = 1.0
	emitter.local_coords = false
	emitter.emitting = false
	emitter.process_material = process
	emitter.draw_pass_1 = speck
	emitter.visibility_aabb = AABB(Vector3.ONE * -4.0, Vector3.ONE * 8.0)
	emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return emitter
