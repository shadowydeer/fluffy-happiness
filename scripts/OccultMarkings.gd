extends RefCounted
## Procedural occult chalk work. Every marking is a flat stroke mesh built in
## the XZ plane (normal +Y), so it can be laid on a floor as-is or rotated onto
## a wall. Strokes are jittered and double-passed to look hand drawn.

const SEGMENT_LENGTH := 0.22

# Rune glyphs as line-segment endpoint pairs inside a unit box (+Y is "up").
const GLYPHS: Array = [
	[Vector2(0.0, -0.5), Vector2(0.0, 0.5), Vector2(0.0, 0.15), Vector2(0.35, 0.5), Vector2(0.0, -0.1), Vector2(0.35, 0.25)],
	[Vector2(-0.25, -0.5), Vector2(-0.25, 0.5), Vector2(-0.25, 0.5), Vector2(0.25, 0.2), Vector2(0.25, 0.2), Vector2(0.25, -0.5)],
	[Vector2(-0.1, -0.5), Vector2(-0.1, 0.5), Vector2(-0.1, 0.3), Vector2(0.25, 0.0), Vector2(0.25, 0.0), Vector2(-0.1, -0.3)],
	[Vector2(-0.2, -0.5), Vector2(-0.2, 0.5), Vector2(-0.2, 0.5), Vector2(0.2, 0.25), Vector2(0.2, 0.25), Vector2(-0.2, 0.0), Vector2(-0.2, 0.0), Vector2(0.25, -0.5)],
	[Vector2(0.25, 0.4), Vector2(-0.2, 0.0), Vector2(-0.2, 0.0), Vector2(0.25, -0.4)],
	[Vector2(0.0, -0.5), Vector2(0.0, 0.5), Vector2(0.0, 0.1), Vector2(-0.3, 0.5), Vector2(0.0, 0.1), Vector2(0.3, 0.5)],
	[Vector2(0.0, -0.5), Vector2(0.0, 0.5), Vector2(0.0, 0.5), Vector2(-0.3, 0.2), Vector2(0.0, 0.5), Vector2(0.3, 0.2)],
	[Vector2(-0.3, -0.3), Vector2(0.3, 0.3), Vector2(-0.3, 0.3), Vector2(0.3, -0.3)],
	[Vector2(-0.35, -0.3), Vector2(0.35, -0.3), Vector2(0.35, -0.3), Vector2(0.0, 0.4), Vector2(0.0, 0.4), Vector2(-0.35, -0.3)],
	[Vector2(-0.2, -0.5), Vector2(-0.2, 0.5), Vector2(0.2, -0.5), Vector2(0.2, 0.5), Vector2(-0.2, 0.15), Vector2(0.2, -0.15)],
	[Vector2(-0.4, 0.0), Vector2(0.0, 0.25), Vector2(0.0, 0.25), Vector2(0.4, 0.0), Vector2(0.4, 0.0), Vector2(0.0, -0.25), Vector2(0.0, -0.25), Vector2(-0.4, 0.0), Vector2(0.0, -0.07), Vector2(0.0, 0.07)],
	[Vector2(0.0, -0.5), Vector2(0.0, 0.5), Vector2(-0.3, 0.2), Vector2(0.3, -0.2), Vector2(-0.3, -0.2), Vector2(0.3, 0.2)],
]


## Summoning circle: double ring, five-point star, rune band and inner eye ring.
static func pentagram(radius: float, material: Material, seed_value: int = 1) -> MeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var st := _begin()
	var width := radius * 0.02 + 0.012
	_ring(st, rng, radius, width)
	_ring(st, rng, radius * 0.8, width * 0.8)
	var star_radius := radius * 0.8
	var points: Array[Vector2] = []
	for i in 5:
		var angle := -PI * 0.5 + TAU * float(i) / 5.0
		points.append(Vector2(cos(angle), sin(angle)) * star_radius)
	for i in 5:
		_chalk_line(st, rng, points[i], points[(i + 2) % 5], width)
	var rune_count := 12
	for i in rune_count:
		var angle := TAU * (float(i) + 0.5) / float(rune_count)
		_glyph(st, rng, Vector2(cos(angle), sin(angle)) * radius * 0.9, angle, radius * 0.12, width * 0.65)
	_ring(st, rng, radius * 0.24, width * 0.7)
	_glyph(st, rng, Vector2.ZERO, rng.randf() * TAU, radius * 0.26, width * 0.7)
	return _finish(st, material, "Pentagram")


## Smaller warding circle: ring, rune band and one large central rune.
static func rune_circle(radius: float, material: Material, seed_value: int = 1) -> MeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var st := _begin()
	var width := radius * 0.03 + 0.01
	_ring(st, rng, radius, width)
	_ring(st, rng, radius * 0.68, width * 0.8)
	var rune_count := maxi(5, int(radius * 12.0))
	for i in rune_count:
		var angle := TAU * float(i) / float(rune_count)
		_glyph(st, rng, Vector2(cos(angle), sin(angle)) * radius * 0.84, angle, radius * 0.2, width * 0.7)
	_glyph(st, rng, Vector2.ZERO, rng.randf() * TAU, radius * 0.8, width)
	return _finish(st, material, "RuneCircle")


## Wall sigil: a watching eye inside a triangle with radiating tally strokes.
static func sigil(size: float, material: Material, seed_value: int = 1) -> MeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var st := _begin()
	var width := size * 0.025 + 0.01
	var half := size * 0.5
	var corners: Array[Vector2] = []
	for i in 3:
		var angle := PI * 0.5 + TAU * float(i) / 3.0
		corners.append(Vector2(cos(angle), sin(angle)) * half)
	for i in 3:
		_chalk_line(st, rng, corners[i], corners[(i + 1) % 3], width)
	# Eye: two arcs approximated by a diamond, plus a pupil ring.
	var eye := half * 0.42
	_chalk_line(st, rng, Vector2(-eye, 0), Vector2(0, eye * 0.5), width * 0.8)
	_chalk_line(st, rng, Vector2(0, eye * 0.5), Vector2(eye, 0), width * 0.8)
	_chalk_line(st, rng, Vector2(eye, 0), Vector2(0, -eye * 0.5), width * 0.8)
	_chalk_line(st, rng, Vector2(0, -eye * 0.5), Vector2(-eye, 0), width * 0.8)
	_ring(st, rng, eye * 0.2, width * 0.7)
	for i in 9:
		var angle := TAU * float(i) / 9.0 + rng.randf_range(-0.1, 0.1)
		var dir := Vector2(cos(angle), sin(angle))
		_chalk_line(st, rng, dir * half * 1.12, dir * half * rng.randf_range(1.25, 1.5), width * 0.7)
	return _finish(st, material, "Sigil")


## A row of runes, e.g. scrawled along a wall or as a trail down a corridor.
static func rune_row(count: int, glyph_size: float, material: Material, seed_value: int = 1) -> MeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var st := _begin()
	var spacing := glyph_size * 1.15
	var start := -spacing * float(count - 1) * 0.5
	for i in count:
		var center := Vector2(start + spacing * float(i), rng.randf_range(-0.04, 0.04) * glyph_size)
		_glyph(st, rng, center, PI * 0.5 + rng.randf_range(-0.12, 0.12), glyph_size, glyph_size * 0.06 + 0.008)
	return _finish(st, material, "RuneRow")


## Soft chalk material: lit by lamps and torches, with a faint glow so it reads in the dark.
## A world-space noise breaks the strokes up, as if they had been scuffed and redrawn.
static func chalk_material(color: Color, emission_energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = emission_energy
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _scuff_texture()
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3.ONE * 1.7
	return mat


static var _scuff: NoiseTexture2D


## Speckled alpha: mostly solid, with worn patches and gritty edges.
static func _scuff_texture() -> NoiseTexture2D:
	if _scuff:
		return _scuff
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.045
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.7
	noise.seed = 666
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.28, 0.5, 1.0])
	ramp.colors = PackedColorArray([Color(0.7, 0.7, 0.7, 0.12), Color(0.85, 0.85, 0.85, 0.55), Color(1, 1, 1, 0.95), Color(1, 1, 1, 1)])
	_scuff = NoiseTexture2D.new()
	_scuff.width = 256
	_scuff.height = 256
	_scuff.seamless = true
	_scuff.generate_mipmaps = true
	_scuff.noise = noise
	_scuff.color_ramp = ramp
	return _scuff


static func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


static func _finish(st: SurfaceTool, material: Material, node_name: String) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = st.commit()
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


static func _quad(st: SurfaceTool, a: Vector2, b: Vector2, width: float) -> void:
	var along := b - a
	if along.length_squared() < 0.000001:
		return
	var side := along.orthogonal().normalized() * width * 0.5
	var corners := [a + side, b + side, b - side, a - side]
	for index: int in [0, 1, 2, 0, 2, 3]:
		var p: Vector2 = corners[index]
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(p.x, 0.0, p.y))


## A straight stroke broken into wobbly segments, sometimes gone over twice.
static func _chalk_line(st: SurfaceTool, rng: RandomNumberGenerator, a: Vector2, b: Vector2, width: float) -> void:
	var passes := 2 if rng.randf() < 0.45 else 1
	for stroke in passes:
		var length := a.distance_to(b)
		var steps := maxi(1, int(ceil(length / SEGMENT_LENGTH)))
		var normal := (b - a).orthogonal().normalized()
		var previous := a + normal * rng.randf_range(-1.0, 1.0) * width * 0.4 * float(stroke)
		for i in range(1, steps + 1):
			var point := a.lerp(b, float(i) / float(steps)) + normal * rng.randf_range(-1.0, 1.0) * width * 0.35
			_quad(st, previous, point, width * rng.randf_range(0.7, 1.15))
			previous = point


static func _ring(st: SurfaceTool, rng: RandomNumberGenerator, radius: float, width: float) -> void:
	var segments := maxi(20, int(radius * 26.0))
	var wobble_phase := rng.randf() * TAU
	var previous := Vector2.ZERO
	for i in segments + 1:
		var angle := TAU * float(i % segments) / float(segments)
		var r := radius * (1.0 + 0.012 * sin(angle * 3.0 + wobble_phase))
		var point := Vector2(cos(angle), sin(angle)) * r
		if i > 0:
			_quad(st, previous, point, width * rng.randf_range(0.8, 1.15))
		previous = point


## Draws a random glyph whose "up" points along `facing` (radians).
static func _glyph(st: SurfaceTool, rng: RandomNumberGenerator, center: Vector2, facing: float, size: float, width: float) -> void:
	var strokes: Array = GLYPHS[rng.randi() % GLYPHS.size()]
	var up := Vector2(cos(facing), sin(facing))
	var right := Vector2(up.y, -up.x)
	for i in range(0, strokes.size(), 2):
		var from: Vector2 = strokes[i]
		var to: Vector2 = strokes[i + 1]
		_quad(st, center + (right * from.x + up * from.y) * size, center + (right * to.x + up * to.y) * size, width)
