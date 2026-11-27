extends Node3D
## Game feel (child of Main, named "Juice"; also `GameState.juice`).
##
## Turns events into things the player feels: distance-scaled camera trauma, a 30 ms
## FOV punch, dust where furniture lands, sparks, the red crack of torn tape and a
## small glowing seal over a stunned demon's head. Nothing here stops the clock, so
## co-op packets keep flowing through every effect.
##
## `emit_fx()` is for whoever simulates the world: it plays here and on every client.
## `play_fx()`, `shake_at()` and `punch()` are local. The demon's stun is watched on
## each machine's own copy of the demon, so that cue needs no traffic at all.

const Parts := preload("res://scripts/gadgets/GadgetParts.gd")

## Effect kinds, in wire order.
##   dust        a dusty puff (strength scales its size)
##   crash       furniture hitting something hard: dust and a jolt
##   sparks      a bright spark burst
##   stun_drop   the demon going down: sparks, punch, then dust where it lands
##   tape_crack  a layer of tape tearing: red flash and shards
##   salt_burst  a salt grenade going off: white-gold flash, punch and a big jolt
##   roar        the demon's roar: shake only
##   van_rock    something throwing itself at the inside of the van: shake only
const KINDS: Array[StringName] = [&"dust", &"crash", &"sparks", &"stun_drop", &"tape_crack", &"salt_burst", &"roar", &"van_rock"]

const PUNCH_HOLD := 0.03
const PUNCH_RELEASE := 0.14
const PUNCH_FOV := 3.2
## Bursts per second this machine will draw; the rest are dropped (a collapsing shelf is one puff, not twenty).
const BURST_BUDGET := 14.0
const DUST := Color(0.56, 0.5, 0.43, 0.5)
const SEAL_GOLD := Color(1.0, 0.84, 0.42)
const CRACK_RED := Color(1.0, 0.1, 0.06)
const SALT_WHITE := Color(1.0, 0.95, 0.78)

## How often each kind has played on this machine, for the test tools.
var played: Dictionary = {}
var punches := 0

var _main: Node
var _demon: Node3D
var _was_stunned := false
var _camera: Camera3D
var _base_fov := 80.0
var _punch := 0.0
var _punch_hold := 0.0
var _budget := BURST_BUDGET
var _seal: Node3D
var _seal_sparks: GPUParticles3D
var _seal_mark: MeshInstance3D
var _seal_glow := 0.0
var _seal_clock := 0.0


func setup(main: Node) -> void:
	_main = main
	GameState.juice = self
	var player: Variant = main.get(&"player")
	if is_instance_valid(player) and (player as Node).has_method(&"get_camera"):
		_camera = (player as Node).call(&"get_camera") as Camera3D
		if _camera:
			_base_fov = _camera.fov
	_build_seal()
	bind_demon(main.get(&"demon") as Node3D)


func _exit_tree() -> void:
	if GameState.juice == self:
		GameState.juice = null


## Main calls this whenever a new demon wakes on the dais.
func bind_demon(demon: Node3D) -> void:
	_demon = demon
	_was_stunned = is_instance_valid(demon) and bool(demon.get(&"is_stunned"))


# --- Public API ----------------------------------------------------------------------

## Solo or host: the effect plays here and on every client that has built its site.
func emit_fx(kind: StringName, at: Vector3, strength: float = 1.0) -> void:
	var index := KINDS.find(kind)
	if index < 0 or not NetworkManager.is_authority():
		return
	play_fx(kind, at, strength)
	if NetworkManager.is_networked():
		for id in NetworkManager.get_ready_clients():
			_fx.rpc_id(id, index, at, strength)


@rpc("authority", "call_remote", "unreliable")
func _fx(index: int, at: Vector3, strength: float) -> void:
	if index >= 0 and index < KINDS.size():
		play_fx(KINDS[index], at, strength)


## The effect on this machine only.
func play_fx(kind: StringName, at: Vector3, strength: float = 1.0) -> void:
	strength = clampf(strength, 0.0, 2.0)
	played[kind] = int(played.get(kind, 0)) + 1
	match kind:
		&"dust":
			_dust(at, strength)
		&"crash":
			_dust(at, strength)
			shake_at(at, 0.1 + 0.28 * strength, 12.0)
		&"sparks":
			_sparks(at, Color(1.0, 0.8, 0.45), int(18 + 26 * strength))
		&"stun_drop":
			_sparks(at, Color(0.75, 0.9, 1.0), 44)
			shake_at(at, 0.5 * strength, 16.0)
			punch(strength)
			# The body takes a moment to reach the floor; the dust waits for it.
			get_tree().create_timer(0.45, false).timeout.connect(_dust_under_demon.bind(strength))
		&"tape_crack":
			_sparks(at, CRACK_RED, 38)
			_flash(at, CRACK_RED, 7.0, 3.6, 0.2)
			shake_at(at, 0.3 * strength, 12.0)
		&"salt_burst":
			_sparks(at + Vector3.UP * 0.2, SALT_WHITE, 70)
			_flash(at + Vector3.UP * 0.5, SALT_WHITE, 9.0, 7.0, 0.3)
			_dust(at, 1.2)
			shake_at(at, 0.6 * strength, 14.0)
			if _near(at, 9.0):
				punch(strength)
		&"roar":
			shake_at(at, 0.34 * strength, 18.0)
		&"van_rock":
			shake_at(at, 0.22 * strength, 9.0)


## Shakes this machine's camera by up to `amount` (0..1), fading to nothing `radius` metres from `at`.
func shake_at(at: Vector3, amount: float, radius: float = 14.0) -> void:
	var player := _local_player()
	if player == null or radius <= 0.0:
		return
	var falloff := 1.0 - clampf(player.global_position.distance_to(at) / radius, 0.0, 1.0)
	if falloff > 0.0:
		# Smooth roll-off: full strength up close, a tremor at the edge.
		player.call(&"shake", amount * falloff * (2.0 - falloff))


## A 30 ms FOV kick that eases straight back out. Purely visual: time never stops.
func punch(amount: float = 1.0) -> void:
	punches += 1
	_punch = maxf(_punch, clampf(amount, 0.0, 1.5))
	_punch_hold = PUNCH_HOLD


## How hard the punch is biting right now, 0..1.5.
func get_punch() -> float:
	return _punch


func is_seal_showing() -> bool:
	return _seal.visible


# --- Ticking -------------------------------------------------------------------------

func _process(delta: float) -> void:
	_budget = minf(BURST_BUDGET, _budget + BURST_BUDGET * delta)
	_tick_punch(delta)
	_tick_demon(delta)


func _tick_punch(delta: float) -> void:
	if _punch <= 0.0 and _punch_hold <= 0.0:
		return
	if _punch_hold > 0.0:
		_punch_hold -= delta
	else:
		_punch = maxf(0.0, _punch - delta / PUNCH_RELEASE)
	if is_instance_valid(_camera):
		_camera.fov = _base_fov - PUNCH_FOV * _punch


func _tick_demon(delta: float) -> void:
	var live := is_instance_valid(_demon) and not _demon.is_queued_for_deletion()
	var stunned := live and bool(_demon.get(&"is_stunned"))
	if stunned and not _was_stunned and not bool(_demon.get(&"is_dormant")):
		play_fx(&"stun_drop", _demon.call(&"get_center"), 1.0)
	_was_stunned = stunned
	# The seal: a faint sigil and a few rising sparks over the head of a demon that is out cold.
	var show := stunned and not bool(_demon.get(&"contained")) and not bool(_demon.get(&"is_dormant"))
	_seal_glow = move_toward(_seal_glow, 1.0 if show else 0.0, delta * (2.5 if show else 5.0))
	_seal.visible = _seal_glow > 0.01
	_seal_sparks.emitting = show
	if not _seal.visible:
		return
	_seal_clock += delta
	if live:
		_seal.global_position = (_demon.call(&"get_head_position") as Vector3) + Vector3.UP * 0.42
	var pulse := 0.75 + 0.25 * sin(_seal_clock * 5.0)
	var material := _seal_mark.material_override as StandardMaterial3D
	material.albedo_color = Color(SEAL_GOLD.r, SEAL_GOLD.g, SEAL_GOLD.b, 1.0) * (0.55 * _seal_glow * pulse)
	_seal_mark.rotation.z = _seal_clock * 0.9


func _dust_under_demon(strength: float) -> void:
	if is_instance_valid(_demon) and not _demon.is_queued_for_deletion() and bool(_demon.get(&"is_stunned")):
		var at: Vector3 = _demon.call(&"get_ground_position")
		_dust(at, 1.3 * strength)
		shake_at(at, 0.22 * strength, 10.0)


# --- Pieces --------------------------------------------------------------------------

func _build_seal() -> void:
	_seal = Node3D.new()
	_seal.name = "StunSeal"
	_seal.top_level = true
	_seal.visible = false
	add_child(_seal)
	var material := Parts.additive(Parts.sigil(128))
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.billboard_keep_scale = true
	material.no_depth_test = false
	var quad := QuadMesh.new()
	quad.size = Vector2(0.3, 0.3)
	_seal_mark = MeshInstance3D.new()
	_seal_mark.name = "Mark"
	_seal_mark.mesh = quad
	_seal_mark.material_override = material
	_seal_mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_seal.add_child(_seal_mark)
	_seal_sparks = Parts.particles(SEAL_GOLD, 9, 1.1, Vector2(0.1, 0.45), Vector2(0.01, 0.024), Vector3(0.0, 0.35, 0.0), 180.0, false)
	_seal_sparks.name = "Sparks"
	_seal.add_child(_seal_sparks)


func _local_player() -> Node3D:
	var player: Variant = _main.get(&"player") if _main else null
	return player as Node3D if is_instance_valid(player) else null


func _near(at: Vector3, radius: float) -> bool:
	var player := _local_player()
	return player != null and player.global_position.distance_to(at) < radius


func _spend() -> bool:
	if _budget < 1.0:
		return false
	_budget -= 1.0
	return true


func _dust(at: Vector3, strength: float) -> void:
	if not _spend():
		return
	var size := clampf(strength, 0.3, 2.0)
	var puff := Parts.particles(DUST, int(10 + 12 * size), 0.9 + 0.3 * size, Vector2(0.4, 1.4 + 0.8 * size),
			Vector2(0.14 * size, 0.42 * size), Vector3(0.0, 0.5, 0.0), 78.0, true, false)
	_burst(puff, at + Vector3.UP * 0.05)


func _sparks(at: Vector3, color: Color, amount: int) -> void:
	if not _spend():
		return
	_burst(Parts.particles(color, amount, 0.5, Vector2(1.8, 6.5), Vector2(0.01, 0.03), Vector3(0.0, -8.0, 0.0)), at)


func _burst(emitter: GPUParticles3D, at: Vector3) -> void:
	add_child(emitter)
	emitter.global_position = at
	emitter.restart()
	get_tree().create_timer(emitter.lifetime + 0.6, false).timeout.connect(emitter.queue_free)


## A light that is gone again almost before it is seen.
func _flash(at: Vector3, color: Color, energy: float, reach: float, seconds: float) -> void:
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = energy
	light.omni_range = reach
	light.omni_attenuation = 1.4
	light.shadow_enabled = false
	light.light_volumetric_fog_energy = 0.4
	add_child(light)
	light.global_position = at
	var tween := create_tween()
	tween.tween_property(light, ^"light_energy", 0.0, seconds).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tween.tween_callback(light.queue_free)
