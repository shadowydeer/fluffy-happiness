extends Node3D
## Entry point of a contract. Builds the night atmosphere (environment, fog, moon), asks
## the LevelBuilder for the site, then drops in one exorcist per person in the session,
## the HUD, the demon, and the systems that run the job: ContractManager (capture to
## payout, or failure), PossessionSystem, NetSync and the pause menu.
## Main.tscn contains only this script: everything else is constructed on run.
##
## Solo is one body. Co-op is one body per connected player, and nothing else: there
## are no bots and no bystanders anywhere on the site. With `backdrop` set, only the
## site and its weather are built, for the title screen to film.

const LevelBuilder := preload("res://scripts/LevelBuilder.gd")
const PlayerScene := preload("res://scenes/Player.tscn")
const HudScene := preload("res://scenes/HUD.tscn")
const DemonScene := preload("res://scenes/Demon.tscn")
const ContractManager := preload("res://scripts/ContractManager.gd")
const PossessionSystem := preload("res://scripts/PossessionSystem.gd")
const NetSync := preload("res://scripts/NetSync.gd")
const PauseMenu := preload("res://scripts/PauseMenu.gd")

const FOG_COLOR := Color(0.16, 0.20, 0.27)
const KILL_PLANE_Y := -25.0
const DEBUG_KEYS := "Test keys:  K stun / wake demon   J cycle AI (lurking > enraged > poltergeist throw)   L cycle bind level 0-3   P summon demon   F1 show on HUD"

## Solo suit colour: 0 orange, 1 teal, 2 olive, 3 purple. Co-op players pick theirs in the lobby.
@export var suit_variant := 0
## Title screen: build the site and its weather, and nothing that plays.
@export var backdrop := false

var level: LevelBuilder
## The body this machine controls.
var player: CharacterBody3D
## Peer id -> body, for everyone on site (one entry in solo).
var players: Dictionary = {}
var hud: CanvasLayer
var demon: Node3D
var contracts: ContractManager
var possession: PossessionSystem
var net: NetSync
var pause_menu: PauseMenu


func _ready() -> void:
	GameState.reset()
	_build_environment()
	_build_moon()
	level = LevelBuilder.new()
	level.name = "Level"
	add_child(level)
	if backdrop:
		_build_interior_air()
		_tune_lights(self)
		return

	# A prop's place in this list is its id on the wire: identical on every machine.
	GameState.net_props = level.get_props()
	for i in GameState.net_props.size():
		GameState.net_props[i].set_meta(&"net_id", i)

	_spawn_crew()
	hud = HudScene.instantiate() as CanvasLayer
	add_child(hud)
	hud.call(&"bind_player", player)

	_spawn_demon(0)
	print(DEBUG_KEYS)
	_build_interior_air()
	_tune_lights(self)

	contracts = ContractManager.new()
	contracts.name = "Contracts"
	add_child(contracts)
	contracts.setup(self)

	possession = PossessionSystem.new()
	possession.name = "Possession"
	add_child(possession)
	possession.setup(self)

	net = NetSync.new()
	net.name = "Net"
	add_child(net)
	net.setup(self)

	pause_menu = PauseMenu.new()
	pause_menu.name = "PauseMenu"
	add_child(pause_menu)
	pause_menu.setup(self)

	NetworkManager.player_left.connect(_on_player_left)
	NetworkManager.announce_ready()


func _exit_tree() -> void:
	if NetworkManager.player_left.is_connected(_on_player_left):
		NetworkManager.player_left.disconnect(_on_player_left)
	GameState.net_props = []


## One body per person in the session. This machine's own goes in first, so its camera
## is the one the viewport uses.
func _spawn_crew() -> void:
	var local_id := NetworkManager.local_id()
	_spawn_player(local_id)
	for id in NetworkManager.get_ids():
		if id != local_id:
			_spawn_player(id)


func _spawn_player(id: int) -> void:
	var local := id == NetworkManager.local_id()
	var seat := NetworkManager.get_seat(id)
	var body := PlayerScene.instantiate() as CharacterBody3D
	body.name = "Player" if local else "Player%d" % id
	body.set(&"peer_id", id)
	body.set(&"seat", seat)
	body.set(&"display_name", NetworkManager.get_player_name(id))
	body.set(&"is_local", local)
	# Hands, gadgets and impacts are worked out where the world is: here in solo and on the host.
	body.set(&"simulates", NetworkManager.is_authority())
	body.transform = level.get_spawn(seat)
	if not local:
		(body.get_node("Head/SpringArm3D/Camera3D") as Camera3D).current = false
	add_child(body)
	body.call(&"set_suit", NetworkManager.get_player_suit(id) if NetworkManager.is_networked() else suit_variant)
	players[id] = body
	if local:
		player = body


## Somebody dropped out mid-contract: their body goes, anything they held is let go, and
## the demon is re-scaled for the crew that is left.
func _on_player_left(id: int) -> void:
	var body := players.get(id) as CharacterBody3D
	if body == null:
		return
	players.erase(id)
	var who := str(body.get(&"display_name"))
	if is_instance_valid(possession):
		possession.forget(body)
	for other: Node in players.values():
		var belt: Variant = other.get(&"gadgets")
		if is_instance_valid(belt):
			(belt as Node).get(&"lasso").call(&"release_player", body)
	remove_child(body)
	body.queue_free()
	if is_instance_valid(demon):
		demon.get_node("AI").call(&"set_player_count", NetworkManager.get_player_count())
	GameState.notice_posted.emit("%s LEFT THE SITE" % who)


## Clears out the last demon (sealed in the van or not) and wakes a new one on the dais.
## `tier` is the number of contracts already paid out: each one makes the next demon worse.
func respawn_demon(tier: int) -> Node3D:
	if is_instance_valid(demon):
		# Out of the tree at once, so it cannot report progress on the new contract.
		remove_child(demon)
		demon.queue_free()
	_spawn_demon(tier)
	_tune_lights(demon)
	if is_instance_valid(possession):
		possession.bind_demon(demon)
	return demon


func _spawn_demon(tier: int) -> void:
	demon = DemonScene.instantiate() as Node3D
	demon.name = "Demon"
	demon.transform = level.demon_spawn
	add_child(demon)
	var brain := demon.get_node("AI")
	brain.call(&"setup", level, player)
	brain.call(&"apply_difficulty", tier)
	brain.call(&"set_player_count", NetworkManager.get_player_count())
	if not NetworkManager.is_authority():
		# The host's demon is the real one; this is its mirror.
		demon.call(&"set_remote")
		brain.set(&"is_remote", true)
	hud.call(&"bind_demon", demon)


## Where this machine's player starts a contract.
func get_local_spawn() -> Transform3D:
	return level.get_spawn(int(player.get(&"seat")))


## Test keys (listed on the HUD under F1). They act on the demon's brain, exactly as gameplay
## would, so in co-op only the host (who owns that brain) has them.
func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or backdrop or not is_instance_valid(demon) or player.get(&"controls_locked"):
		return
	if not NetworkManager.is_authority():
		return
	var brain := demon.get_node("AI")
	match key.physical_keycode:
		KEY_K:
			brain.call(&"debug_toggle_stun")
		KEY_J:
			brain.call(&"debug_cycle_state")
		KEY_L:
			brain.call(&"debug_cycle_bind")
		KEY_P:
			brain.call(&"debug_summon")


func _physics_process(_delta: float) -> void:
	# Safety net: anyone who escapes the map is put back beside the van.
	if is_instance_valid(player) and player.global_position.y < KILL_PLANE_Y:
		player.velocity = Vector3.ZERO
		player.global_transform = get_local_spawn()


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
		if not _worn_by_player(light):
			light.distance_fade_enabled = true
			light.distance_fade_begin = 42.0
			light.distance_fade_length = 10.0
			light.distance_fade_shadow = 26.0


## True for a light that travels with an exorcist (headlamp, suit glow, hand lamp).
func _worn_by_player(light: Node) -> bool:
	for body: Node in players.values():
		if is_instance_valid(body) and body.is_ancestor_of(light):
			return true
	return false
