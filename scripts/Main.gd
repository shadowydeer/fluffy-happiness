extends Node3D
## Entry point. Builds the night atmosphere (environment, fog, moon), asks the
## LevelBuilder for the site, then drops in the player and the HUD.
## Main.tscn contains only this script: everything else is constructed on run.

const LevelBuilder := preload("res://scripts/LevelBuilder.gd")
const PlayerScene := preload("res://scenes/Player.tscn")
const HudScene := preload("res://scenes/HUD.tscn")

const FOG_COLOR := Color(0.16, 0.20, 0.27)
const KILL_PLANE_Y := -25.0

## 0 orange, 1 teal, 2 olive.
@export var suit_variant := 0

var level: LevelBuilder
var player: CharacterBody3D
var hud: CanvasLayer


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
	env.ambient_light_energy = 0.3
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# Subtle contact shadowing under clutter and in room corners.
	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.5
	env.ssao_power = 1.4
	env.ssao_light_affect = 0.15

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
	env.volumetric_fog_density = 0.028
	env.volumetric_fog_albedo = Color(0.62, 0.70, 0.84)
	env.volumetric_fog_emission = FOG_COLOR
	env.volumetric_fog_emission_energy = 0.06
	env.volumetric_fog_anisotropy = 0.6
	env.volumetric_fog_length = 56.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_ambient_inject = 0.25
	env.volumetric_fog_sky_affect = 0.6
	env.volumetric_fog_temporal_reprojection_enabled = true

	# Soft bloom on bulbs, visor lenses and glowing sigils.
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_strength = 1.0
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 1.1
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
	moon.light_energy = 0.55
	moon.light_volumetric_fog_energy = 2.4
	moon.light_angular_distance = 1.2
	moon.shadow_enabled = true
	moon.shadow_bias = 0.06
	moon.shadow_normal_bias = 1.5
	moon.shadow_blur = 1.4
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
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
