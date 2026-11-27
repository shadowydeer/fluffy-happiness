extends Node3D
## Entry point. Builds the night atmosphere (environment, fog, moon), asks the
## LevelBuilder for the site, then drops in the player, the HUD and the demon.
## Main.tscn contains only this script: everything else is constructed on run.

const LevelBuilder := preload("res://scripts/LevelBuilder.gd")
const PlayerScene := preload("res://scenes/Player.tscn")
const ExorcistModel := preload("res://scripts/ExorcistModel.gd")
const HudScene := preload("res://scenes/HUD.tscn")
const DemonScene := preload("res://scenes/Demon.tscn")

const FOG_COLOR := Color(0.16, 0.20, 0.27)
const KILL_PLANE_Y := -25.0
const DEBUG_KEYS := "Stage 2 test keys:  K stun / wake demon   J cycle AI (lurking > enraged > poltergeist throw)   L cycle bind level 0-3   F1 show on HUD"

## 0 orange, 1 teal, 2 olive, 3 purple.
@export var suit_variant := 0

var level: LevelBuilder
var player: CharacterBody3D
var hud: CanvasLayer
var demon: Node3D


func _ready() -> void:
	GameState.reset()
	_build_environment()
	_build_moon()
	level = LevelBuilder.new()
	level.name = "Level"
	add_child(level)

	player = PlayerScene.instantiate() as CharacterBody3D
	player.transform = level.player_spawn
	add_child(player)
	player.call(&"set_suit", suit_variant)

	hud = HudScene.instantiate() as CanvasLayer
	add_child(hud)
	hud.call(&"bind_player", player)

	demon = DemonScene.instantiate() as Node3D
	demon.transform = level.demon_spawn
	add_child(demon)
	demon.get_node("AI").call(&"setup", level, player)
	hud.call(&"bind_demon", demon)
	print(DEBUG_KEYS)

	_spawn_squad()
	_build_interior_air()
	_tune_lights(self)


## Stage 2 test keys. They act on the demon's brain, exactly as gameplay would.
func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var brain := demon.get_node("AI")
	match key.physical_keycode:
		KEY_K:
			brain.call(&"debug_toggle_stun")
		KEY_J:
			brain.call(&"debug_cycle_state")
		KEY_L:
			brain.call(&"debug_cycle_bind")


func _physics_process(_delta: float) -> void:
	# Safety net: anyone who escapes the map is put back beside the van.
	if player.global_position.y < KILL_PLANE_Y:
		player.velocity = Vector3.ZERO
		player.global_transform = level.player_spawn


func _build_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.012, 0.018, 0.035)
	sky_material.sky_horizon_color = Color(0.06, 0.08, 0.12)
	sky_material.ground_bottom_color = Color(0.008, 0.01, 0.015)
	sky_material.ground_horizon_color = Color(0.06, 0.08, 0.12)
	sky_material.sun_angle_max = 4.0
	sky_material.sun_curve = 0.05
	var sky := Sky.new()
	sky.sky_material = sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky

	# Filmic response keeps lamp hot-spots from clipping against the dark.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.tonemap_white = 6.0

	# Low, cold ambient: readable silhouettes, nothing more.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.20, 0.26, 0.38)
	env.ambient_light_energy = 0.38
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# Subtle contact shadowing under clutter and in room corners.
	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.5
	env.ssao_power = 1.4
	env.ssao_light_affect = 0.15
	env.ssao_horizon = 0.08

	# Screen-space bounce: the pentagram and warm lamps bleed colour onto nearby surfaces.
	env.ssil_enabled = true
	env.ssil_radius = 4.0
	env.ssil_intensity = 1.1
	env.ssil_sharpness = 0.98
	env.ssil_normal_rejection = 1.0

	# Distance fog: exponential, dark blue-grey.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = FOG_COLOR
	env.fog_light_energy = 0.55
	env.fog_density = 0.012
	env.fog_sky_affect = 0.85
	env.fog_sun_scatter = 0.1

	# Volumetric fog on top, so every lamp, headlight and torch carves a visible cone.
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.022
	env.volumetric_fog_albedo = Color(0.50, 0.58, 0.72)
	env.volumetric_fog_emission = FOG_COLOR
	env.volumetric_fog_emission_energy = 0.06
	env.volumetric_fog_anisotropy = 0.6
	env.volumetric_fog_length = 56.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_ambient_inject = 0.15
	env.volumetric_fog_sky_affect = 0.6
	env.volumetric_fog_temporal_reprojection_enabled = true

	# Restrained bloom: only genuinely emissive pixels (bulbs, lenses, sigils, beacons) clear the threshold.
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_strength = 0.9
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.35
	env.glow_hdr_scale = 1.6
	env.glow_hdr_luminance_cap = 10.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 0.92

	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = env
	add_child(world)


func _build_moon() -> void:
	var moon := DirectionalLight3D.new()
	moon.name = "Moonlight"
	moon.basis = Basis.looking_at(LevelBuilder.MOON_DIRECTION, Vector3.UP)
	moon.light_color = LevelBuilder.MOON_COLOR
	moon.light_energy = 0.7
	moon.light_volumetric_fog_energy = 1.4
	moon.light_angular_distance = 1.2
	moon.shadow_enabled = true
	moon.shadow_bias = 0.035
	moon.shadow_normal_bias = 1.1
	moon.shadow_blur = 1.4
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	moon.directional_shadow_blend_splits = true
	moon.directional_shadow_pancake_size = 30.0
	moon.directional_shadow_max_distance = 70.0
	add_child(moon)

	# A visible moon disc, far enough out to sit behind the fog.
	var disc_mesh := SphereMesh.new()
	disc_mesh.radius = 7.0
	disc_mesh.height = 14.0
	var disc_material := StandardMaterial3D.new()
	disc_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disc_material.albedo_color = Color(0.78, 0.86, 1.0)
	disc_material.disable_fog = true
	var disc := MeshInstance3D.new()
	disc.name = "Moon"
	disc.mesh = disc_mesh
	disc.material_override = disc_material
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	disc.position = -LevelBuilder.MOON_DIRECTION * 230.0
	add_child(disc)


## The rest of the crew, idling around the van in the other suit colours.
func _spawn_squad() -> void:
	for i in level.squad_spots.size():
		var body := StaticBody3D.new()
		body.name = "Crew%d" % (i + 1)
		body.collision_layer = GameState.LAYER_WORLD
		body.collision_mask = 0
		body.transform = level.squad_spots[i]
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.34
		capsule.height = 1.8
		var shape := CollisionShape3D.new()
		shape.shape = capsule
		shape.position.y = 0.9
		body.add_child(shape)
		var model := ExorcistModel.new()
		model.name = "Model"
		model.showcase = true
		model.suit = posmod(suit_variant + 1 + i, ExorcistModel.SUIT_COLORS.size()) as ExorcistModel.Suit
		body.add_child(model)
		add_child(body)


## Warm, dusty air inside the house so lamps and torch beams scatter amber
## indoors against the cold slate fog outside.
func _build_interior_air() -> void:
	var air := FogVolume.new()
	air.name = "InteriorAir"
	var width := LevelBuilder.HOUSE_EAST - LevelBuilder.HOUSE_WEST
	var depth := LevelBuilder.HOUSE_SOUTH - LevelBuilder.HOUSE_NORTH
	air.size = Vector3(width - 0.6, 2.8, depth - 0.6)
	air.position = Vector3((LevelBuilder.HOUSE_EAST + LevelBuilder.HOUSE_WEST) * 0.5, LevelBuilder.FLOOR_Y + 1.4,
			(LevelBuilder.HOUSE_SOUTH + LevelBuilder.HOUSE_NORTH) * 0.5)
	var material := FogMaterial.new()
	material.density = 0.025
	material.albedo = Color(0.95, 0.74, 0.50)
	material.emission = Color(0.010, 0.007, 0.004)
	material.edge_fade = 0.05
	air.material = material
	add_child(air)


## One place for shadow quality: tight biases (no acne, no floating shadows),
## no shadow maps for candle-sized lights, and distance fades to protect the frame rate.
func _tune_lights(node: Node) -> void:
	for child in node.get_children():
		_tune_lights(child)
	if node is OmniLight3D or node is SpotLight3D:
		var light := node as Light3D
		var reach: float = (light as OmniLight3D).omni_range if light is OmniLight3D else (light as SpotLight3D).spot_range
		if reach <= 2.5:
			light.shadow_enabled = false
		if light.shadow_enabled:
			light.shadow_bias = 0.05
			light.shadow_normal_bias = 1.2
			light.shadow_blur = 1.2
		if not player.is_ancestor_of(light):
			light.distance_fade_enabled = true
			light.distance_fade_begin = 42.0
			light.distance_fade_length = 10.0
			light.distance_fade_shadow = 26.0
