extends RefCounted
## Shared material library.
##
## Stage 1.5: every architectural surface now uses a real CC0 PBR texture set
## from `res://assets/textures/<set>/` (albedo + OpenGL normal + roughness + AO),
## mapped triplanar in world space so tiling stays continuous across walls,
## floors and trim without authored UVs. If a set is missing the matching
## procedural noise material from Stage 1 is used instead, so the game still runs.
## Results are cached by key, so repeated calls return the same resource.

const TEXTURE_ROOT := "res://assets/textures/"
const WALL_PEEL_SHADER := preload("res://shaders/wall_peel.gdshader")
const FLAME_SHADER := preload("res://shaders/candle_flame.gdshader")

static var _cache: Dictionary = {}
static var _textures: Dictionary = {}
static var _missing_sets: Dictionary = {}


# --- Building blocks --------------------------------------------------------

## Plain PBR colour.
static func solid(color: Color, roughness: float = 0.85, metallic: float = 0.0) -> StandardMaterial3D:
	var key := "solid:%s:%.2f:%.2f" % [color.to_html(), roughness, metallic]
	if _cache.has(key):
		return _cache[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metallic
	_cache[key] = mat
	return mat


## Self-lit surface (bulbs, lenses, embers). Not cached when `unique` so callers can animate it.
static func glow(color: Color, energy: float = 2.0, unique: bool = false) -> StandardMaterial3D:
	var key := "glow:%s:%.2f" % [color.to_html(), energy]
	if not unique and _cache.has(key):
		return _cache[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.4
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	if not unique:
		_cache[key] = mat
	return mat


## True when the named texture set was downloaded and imported.
static func has_set(set_name: String) -> bool:
	return _map(set_name, "albedo") != null


## One map of a texture set, or null if it is not available.
static func _map(set_name: String, map_name: String) -> Texture2D:
	var path := "%s%s/%s_%s.jpg" % [TEXTURE_ROOT, set_name, set_name.get_file(), map_name]
	if _textures.has(path):
		return _textures[path]
	var texture: Texture2D = null
	if ResourceLoader.exists(path, "Texture2D"):
		texture = ResourceLoader.load(path, "Texture2D") as Texture2D
	elif FileAccess.file_exists(path):
		# Not imported yet: decode the JPEG directly.
		var image := Image.load_from_file(path)
		if image:
			image.generate_mipmaps()
			texture = ImageTexture.create_from_image(image)
	_textures[path] = texture
	if texture == null and map_name == "albedo" and not _missing_sets.has(set_name):
		_missing_sets[set_name] = true
		push_warning("MaterialLibrary: texture set '%s' is missing, using a procedural stand-in" % set_name)
	return texture


## Real PBR material from a downloaded texture set.
##   scale      repeats per metre (0.5 = the texture covers 2 m)
##   tint       multiplied into the albedo, to pull a set into the house palette
##   world      world-space triplanar (static geometry) or object-space (moving bodies)
##   roughness  multiplier on the roughness map (below 1 reads as damp)
##   normal     normal map strength
## Returns null when the set is unavailable so callers can fall back.
static func pbr(set_name: String, scale: float = 0.5, tint: Color = Color.WHITE, world: bool = true,
		roughness: float = 1.0, normal: float = 1.0, metallic: float = 0.0) -> StandardMaterial3D:
	var key := "pbr:%s:%.3f:%s:%s:%.2f:%.2f:%.2f" % [set_name, scale, tint.to_html(), world, roughness, normal, metallic]
	if _cache.has(key):
		return _cache[key]
	var albedo := _map(set_name, "albedo")
	if albedo == null:
		return null
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = albedo
	mat.albedo_color = tint
	mat.roughness = roughness
	mat.metallic = metallic
	mat.metallic_specular = 0.4
	var roughness_map := _map(set_name, "roughness")
	if roughness_map:
		mat.roughness_texture = roughness_map
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	var normal_map := _map(set_name, "normal")
	if normal_map:
		mat.normal_enabled = true
		mat.normal_texture = normal_map
		mat.normal_scale = normal
	var ao_map := _map(set_name, "ao")
	if ao_map:
		mat.ao_enabled = true
		mat.ao_texture = ao_map
		mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		mat.ao_light_affect = 0.35
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = world
	mat.uv1_scale = Vector3.ONE * scale
	mat.uv1_triplanar_sharpness = 4.0
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_cache[key] = mat
	return mat


## `pbr()` with a procedural fallback, so call sites never have to branch.
static func surface(set_name: String, scale: float, tint: Color, fallback_light: Color, fallback_dark: Color,
		world: bool = true, roughness: float = 1.0, normal: float = 1.0, metallic: float = 0.0) -> StandardMaterial3D:
	var mat := pbr(set_name, scale, tint, world, roughness, normal, metallic)
	if mat:
		return mat
	return textured("fallback_" + set_name, fallback_light, fallback_dark, Vector3.ONE * scale, 0.9, world, 0.03, 0.4)


## Noise-tinted triplanar surface (Stage 1 look, kept as the offline fallback).
static func textured(key: String, light: Color, dark: Color, uv_scale: Vector3, roughness: float = 0.9,
		world: bool = true, frequency: float = 0.03, bump: float = 0.0) -> StandardMaterial3D:
	var cache_key := "tex:%s:%s" % [key, world]
	if _cache.has(cache_key):
		return _cache[cache_key]
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = absi(hash(key)) % 100000
	noise.frequency = frequency
	noise.fractal_octaves = 4
	var ramp := Gradient.new()
	ramp.set_color(0, dark)
	ramp.set_color(1, light)
	var albedo := NoiseTexture2D.new()
	albedo.width = 256
	albedo.height = 256
	albedo.seamless = true
	albedo.generate_mipmaps = true
	albedo.noise = noise
	albedo.color_ramp = ramp
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = albedo
	mat.roughness = roughness
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = world
	mat.uv1_scale = uv_scale
	if bump > 0.0:
		var normal := NoiseTexture2D.new()
		normal.width = 256
		normal.height = 256
		normal.seamless = true
		normal.generate_mipmaps = true
		normal.noise = noise
		normal.as_normal_map = true
		normal.bump_strength = 6.0
		mat.normal_enabled = true
		mat.normal_texture = normal
		mat.normal_scale = bump
	_cache[cache_key] = mat
	return mat


## Blotchy greyscale noise used as a wear mask by several materials.
static func grime_mask() -> NoiseTexture2D:
	if _cache.has("grime_mask"):
		return _cache["grime_mask"]
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.008
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.6
	noise.seed = 4107
	var mask := NoiseTexture2D.new()
	mask.width = 512
	mask.height = 512
	mask.seamless = true
	mask.generate_mipmaps = true
	mask.normalize = true
	mask.noise = noise
	_cache["grime_mask"] = mask
	return mask


## Wallpaper that peels back to damaged plaster, with damp stains under the ceiling.
static func peeling_wallpaper(key: String, paper_set: String, paper_tint: Color, peel: float, damp: float,
		floor_height: float, fallback_light: Color, fallback_dark: Color) -> Material:
	var cache_key := "peel:%s:%.2f" % [key, floor_height]
	if _cache.has(cache_key):
		return _cache[cache_key]
	if not has_set(paper_set) or not has_set("plaster_damaged"):
		var plain := surface(paper_set, 0.5, paper_tint, fallback_light, fallback_dark)
		_cache[cache_key] = plain
		return plain
	var mat := ShaderMaterial.new()
	mat.shader = WALL_PEEL_SHADER
	mat.set_shader_parameter(&"paper_albedo", _map(paper_set, "albedo"))
	mat.set_shader_parameter(&"paper_normal", _map(paper_set, "normal"))
	mat.set_shader_parameter(&"paper_roughness", _map(paper_set, "roughness"))
	mat.set_shader_parameter(&"under_albedo", _map("plaster_damaged", "albedo"))
	mat.set_shader_parameter(&"under_normal", _map("plaster_damaged", "normal"))
	mat.set_shader_parameter(&"under_roughness", _map("plaster_damaged", "roughness"))
	mat.set_shader_parameter(&"peel_mask", grime_mask())
	mat.set_shader_parameter(&"paper_tint", Vector3(paper_tint.r, paper_tint.g, paper_tint.b))
	mat.set_shader_parameter(&"under_tint", Vector3(0.62, 0.58, 0.52))
	mat.set_shader_parameter(&"paper_scale", 0.55)
	mat.set_shader_parameter(&"under_scale", 0.4)
	mat.set_shader_parameter(&"peel_amount", peel)
	mat.set_shader_parameter(&"damp", damp)
	mat.set_shader_parameter(&"floor_height", floor_height)
	_cache[cache_key] = mat
	return mat


# --- Architecture -----------------------------------------------------------

static func floor_wood() -> StandardMaterial3D:
	return surface("floor_dark_planks", 0.5, Color(0.80, 0.74, 0.68), Color(0.34, 0.22, 0.13), Color(0.13, 0.08, 0.05), true, 0.85)


static func floor_hall() -> StandardMaterial3D:
	return surface("floor_old_wood", 0.5, Color(0.72, 0.66, 0.60), Color(0.22, 0.15, 0.11), Color(0.08, 0.05, 0.04), true, 0.9)


static func floor_stone() -> StandardMaterial3D:
	return surface("stone_cobble_floor", 0.42, Color(0.62, 0.60, 0.62), Color(0.30, 0.30, 0.33), Color(0.10, 0.10, 0.12), true, 0.85, 1.3)


## Living room: dark green, mouldy and peeling.
static func wallpaper_green(floor_height: float = 0.45) -> Material:
	return peeling_wallpaper("green", "wallpaper_mouldy", Color(0.30, 0.44, 0.30), 0.24, 0.7, floor_height, Color(0.30, 0.36, 0.27), Color(0.15, 0.19, 0.14))


## Study: sickly ochre.
static func wallpaper_ochre(floor_height: float = 0.9) -> Material:
	return peeling_wallpaper("ochre", "wallpaper_decrepit", Color(0.86, 0.62, 0.30), 0.2, 0.6, floor_height, Color(0.42, 0.30, 0.16), Color(0.20, 0.13, 0.07))


## Hallway: nicotine-brown paper above dark wainscot.
static func wallpaper_hall(floor_height: float = 0.45) -> Material:
	return peeling_wallpaper("hall", "wallpaper_mouldy", Color(0.50, 0.38, 0.26), 0.3, 0.8, floor_height, Color(0.30, 0.22, 0.14), Color(0.14, 0.10, 0.07))


static func wallpaper_plum() -> Material:
	return wallpaper_ochre()


static func panel_wood() -> StandardMaterial3D:
	return surface("wood_worn", 0.6, Color(0.50, 0.40, 0.34), Color(0.28, 0.19, 0.12), Color(0.12, 0.08, 0.05), true, 0.9)


static func wall_stone() -> StandardMaterial3D:
	return surface("stone_blocks", 0.4, Color(0.50, 0.48, 0.50), Color(0.23, 0.22, 0.25), Color(0.07, 0.07, 0.09), true, 1.0, 1.4)


## Weathered clapboard, pulled toward a cold grey-blue.
static func siding() -> StandardMaterial3D:
	return surface("siding_clapboard", 0.42, Color(0.66, 0.72, 0.78), Color(0.36, 0.38, 0.40), Color(0.17, 0.19, 0.22), true, 1.0, 1.3)


static func plaster() -> StandardMaterial3D:
	return surface("plaster_stained", 0.36, Color(0.62, 0.60, 0.54), Color(0.42, 0.40, 0.36), Color(0.24, 0.23, 0.21))


static func shingles() -> StandardMaterial3D:
	return surface("roof_slates", 0.5, Color(0.52, 0.52, 0.58), Color(0.16, 0.14, 0.15), Color(0.06, 0.05, 0.06), true, 0.8, 1.2)


static func brick() -> StandardMaterial3D:
	return surface("brick_foundation", 0.45, Color(0.62, 0.56, 0.52), Color(0.36, 0.22, 0.18), Color(0.16, 0.10, 0.09), true, 1.0, 1.3)


## Dark stained timber for interior trim, doors and beams.
static func trim_wood(world: bool = true) -> StandardMaterial3D:
	return surface("wood_worn", 0.9, Color(0.42, 0.33, 0.28), Color(0.24, 0.15, 0.09), Color(0.09, 0.05, 0.03), world, 0.85)


## Flaking dark paint over old timber: exterior frames, porch and doors.
static func trim_painted(world: bool = true) -> StandardMaterial3D:
	return surface("wood_peeling_paint", 0.8, Color(0.70, 0.70, 0.68), Color(0.20, 0.20, 0.19), Color(0.08, 0.08, 0.08), world)


static func concrete() -> StandardMaterial3D:
	return surface("concrete_worn", 0.4, Color(0.60, 0.60, 0.60), Color(0.40, 0.40, 0.39), Color(0.22, 0.22, 0.22))


## Dead grass matted into dark soil.
static func grass() -> StandardMaterial3D:
	return surface("ground_dead_grass", 0.24, Color(0.62, 0.64, 0.56), Color(0.15, 0.22, 0.11), Color(0.05, 0.08, 0.05), true, 1.0, 1.4)


## Cracked asphalt, slick with rain.
static func asphalt() -> StandardMaterial3D:
	return surface("asphalt_cracked", 0.3, Color(0.50, 0.52, 0.56), Color(0.15, 0.15, 0.16), Color(0.06, 0.06, 0.07), true, 0.5, 1.3)


static func gravel() -> StandardMaterial3D:
	return surface("gravel_tarred", 0.42, Color(0.62, 0.62, 0.64), Color(0.26, 0.25, 0.24), Color(0.10, 0.10, 0.10), true, 0.75, 1.4)


static func bark(world: bool = true) -> StandardMaterial3D:
	return surface("bark", 0.5, Color(0.42, 0.38, 0.36), Color(0.17, 0.13, 0.10), Color(0.05, 0.04, 0.03), world, 1.0, 1.5)


## Flaking rusted iron for fences, chains and brackets.
static func iron(world: bool = true) -> StandardMaterial3D:
	return surface("iron_rusted", 1.2, Color(0.55, 0.50, 0.48), Color(0.20, 0.13, 0.10), Color(0.06, 0.05, 0.05), world, 0.9, 1.0, 0.6)


static func rug_red() -> StandardMaterial3D:
	return surface("rug_jacquard", 1.4, Color(0.46, 0.30, 0.28), Color(0.36, 0.12, 0.12), Color(0.14, 0.05, 0.07))


static func rug_green() -> StandardMaterial3D:
	return surface("rug_dirty_carpet", 0.8, Color(0.75, 0.80, 0.70), Color(0.16, 0.24, 0.18), Color(0.06, 0.09, 0.08))


# --- Vehicle and gear -------------------------------------------------------

## Chipped white panel paint bleeding rust. Object-space so it rides on moving doors.
static func van_paint() -> StandardMaterial3D:
	return surface("metal_painted_rusty", 0.55, Color(0.80, 0.80, 0.76), Color(0.80, 0.79, 0.72), Color(0.68, 0.67, 0.61), false, 0.75, 0.8, 0.25)


static func tread_plate(world: bool = false) -> StandardMaterial3D:
	return surface("metal_tread_plate", 1.6, Color(0.50, 0.50, 0.52), Color(0.20, 0.20, 0.21), Color(0.08, 0.08, 0.09), world, 0.8, 1.2, 0.85)


## Coated hazmat fabric in a team colour (object-space, so it does not swim on a moving body).
static func suit_fabric(color: Color) -> StandardMaterial3D:
	var mat := pbr("fabric_suit", 7.0, color, false, 0.8, 0.8)
	if mat:
		return mat
	var plain := StandardMaterial3D.new()
	plain.albedo_color = color
	plain.roughness = 0.62
	return plain


# --- Effects ----------------------------------------------------------------

## Grimy, mostly transparent window glass.
static func glass_dusty() -> StandardMaterial3D:
	if _cache.has("glass_dusty"):
		return _cache["glass_dusty"]
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 5
	noise.seed = 77
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.45, 0.52, 0.60, 0.05))
	ramp.set_color(1, Color(0.62, 0.62, 0.56, 0.40))
	var grime := NoiseTexture2D.new()
	grime.width = 256
	grime.height = 256
	grime.seamless = true
	grime.noise = noise
	grime.color_ramp = ramp
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = grime
	mat.roughness = 0.25
	mat.metallic = 0.1
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3(0.7, 0.7, 0.7)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cache["glass_dusty"] = mat
	return mat


## Additive, unshaded material that reads its colour and fade from vertex colours.
static func light_shaft() -> StandardMaterial3D:
	if _cache.has("light_shaft"):
		return _cache["light_shaft"]
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1, 1, 1, 1)
	# Melt away near the lens and where the sheets cut into floors and furniture,
	# so the stack of planes reads as one soft volume.
	mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	mat.distance_fade_min_distance = 0.8
	mat.distance_fade_max_distance = 4.0
	mat.proximity_fade_enabled = true
	mat.proximity_fade_distance = 0.7
	_cache["light_shaft"] = mat
	return mat


## Billboarded soft speck used by the dust-mote particle systems.
static func dust_mote() -> StandardMaterial3D:
	if _cache.has("dust_mote"):
		return _cache["dust_mote"]
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.85, 0.9, 1.0, 0.7)
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
	mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	mat.distance_fade_min_distance = 0.3
	mat.distance_fade_max_distance = 1.6
	_cache["dust_mote"] = mat
	return mat


## Animated candle flame (see shaders/candle_flame.gdshader). Shared by every candle.
static func candle_flame() -> ShaderMaterial:
	if _cache.has("candle_flame"):
		return _cache["candle_flame"]
	var mat := ShaderMaterial.new()
	mat.shader = FLAME_SHADER
	_cache["candle_flame"] = mat
	return mat


# --- Fallback prop finishes (used only when a .glb is missing) ---------------

static func prop_wood() -> StandardMaterial3D:
	return surface("wood_worn", 1.4, Color(0.75, 0.62, 0.50), Color(0.46, 0.30, 0.17), Color(0.22, 0.13, 0.07), false, 0.85)


static func prop_wood_dark() -> StandardMaterial3D:
	return surface("wood_worn", 1.4, Color(0.42, 0.33, 0.28), Color(0.26, 0.16, 0.10), Color(0.10, 0.06, 0.04), false, 0.8)


static func cardboard() -> StandardMaterial3D:
	return textured("cardboard", Color(0.62, 0.47, 0.30), Color(0.44, 0.32, 0.20), Vector3(1.2, 1.2, 1.2), 0.95, false, 0.05)


static func upholstery() -> StandardMaterial3D:
	return surface("rug_jacquard", 2.0, Color(0.40, 0.22, 0.20), Color(0.33, 0.14, 0.13), Color(0.16, 0.06, 0.06), false)


static func metal_dark() -> StandardMaterial3D:
	return solid(Color(0.10, 0.11, 0.12), 0.45, 0.8)


static func metal_bare() -> StandardMaterial3D:
	return solid(Color(0.55, 0.57, 0.60), 0.35, 0.9)


static func rubber() -> StandardMaterial3D:
	return solid(Color(0.035, 0.035, 0.04), 0.95, 0.0)


static func glass_dark() -> StandardMaterial3D:
	return solid(Color(0.02, 0.03, 0.04), 0.08, 0.6)
