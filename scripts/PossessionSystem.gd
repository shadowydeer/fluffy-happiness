extends Node3D
## Demon possession and the salt circle (child of Main, named "Possession").
##
## A circle of ritual salt is laid on the driveway beside the extraction van. Once the
## demon has been found, every 35-45 seconds it gets one attempt to take a player it
## has caught within arm's reach:
##
##   Co-op (2-4 players). The victim has to be alone (no standing crewmate within
##   seven metres) or nearly out of stamina; waking with one wrap of tape or none on
##   it also sets it off. The demon vanishes into them in a burst of black-orange
##   smoke. The possessed player's visor burns, ash pours off the suit, their screen
##   pulses crimson, their controls twitch and invert, and their arms lunge at any
##   crewmate who comes close. The crew gets them back by holding a Holy Taser on
##   them for a second and a half, or by roping and dragging them into the salt
##   circle: either throws the demon out on the floor, STUNNED.
##
##   Solo. There is nobody to do the exorcising, so the attempt is a two and a half
##   second POSSESSION STRUGGLE instead: mash Space to break the grip. Failing costs
##   30 HP and everything in the player's hands.
##
## All of it is decided where the world is simulated (solo, or the host); clients only
## draw the circle and their own symptoms.

const Occult := preload("res://scripts/OccultMarkings.gd")
const Parts := preload("res://scripts/gadgets/GadgetParts.gd")
const Player := preload("res://scripts/Player.gd")

const CIRCLE_CENTER := Vector3(0.9, 0.0, 2.2)
const CIRCLE_RADIUS := 1.7
const COOLDOWN_MIN := 35.0
const COOLDOWN_MAX := 45.0
## How close the demon has to be to take somebody, and how alone they have to be.
const GRAB_RANGE := 2.8
const ISOLATION_RANGE := 7.0
const LOW_STAMINA := 0.3
## Seconds of taser current that drive it out.
const EXORCISE_TIME := 1.5
## Nobody came: after this long it climbs back out by itself, wide awake.
const POSSESSION_LIMIT := 40.0
const LUNGE_RANGE := 2.3
const LUNGE_INTERVAL := 1.6
const STRUGGLE_TIME := 2.5
const STRUGGLE_PRESSES := 10
const STRUGGLE_DAMAGE := 30.0
## AI states in which it is hunting (DemonAI.State.STALKING, ENRAGED).
const HUNTING: Array[int] = [1, 2]

## Seconds until the next attempt is allowed.
var cooldown_left := 40.0
## 0..EXORCISE_TIME of taser current on the possessed player.
var exorcise_progress := 0.0
## True while somebody is possessed: the circle wakes up.
var circle_active := false
var possessions := 0
var struggles := 0
var exorcisms := 0

var _main: Node
var _demon: Node3D
var _brain: Node
## The possessed player, while there is one.
var _vessel: Player
var _possessing := false
var _struggler: Player
var _inside_time := 0.0
var _lunge_left := 0.0
var _last_at := Vector3.ZERO
var _last_yaw := 0.0
## Fresh out of bad tape: for a few seconds it will take anyone nearby, alone or not.
var _hungry_left := 0.0

var _ring_material: StandardMaterial3D
var _salt_material: StandardMaterial3D
var _motes: GPUParticles3D
var _glow: OmniLight3D
var _clock := 0.0
var _wake := 0.0


func setup(main: Node) -> void:
	_main = main
	GameState.possession = self
	_build_circle()
	bind_demon(main.get(&"demon"))


func _exit_tree() -> void:
	if GameState.possession == self:
		GameState.possession = null


## Called for every new contract's demon: nothing carries over from the last one.
func bind_demon(demon: Node3D) -> void:
	_demon = demon
	_brain = demon.get_node("AI") if demon else null
	_release_vessel()
	_struggler = null
	exorcise_progress = 0.0
	_hungry_left = 0.0
	cooldown_left = randf_range(COOLDOWN_MIN, COOLDOWN_MAX)
	if _brain and GameState.is_authority() and not _brain.is_connected(&"woke", _on_demon_woke):
		_brain.connect(&"woke", _on_demon_woke)


func get_vessel() -> Node3D:
	return _vessel if is_instance_valid(_vessel) else null


func is_struggling() -> bool:
	return is_instance_valid(_struggler)


## A player has left the site. If the demon was inside them, it is back in the room.
func forget(body: Node) -> void:
	if _struggler == body:
		_struggler = null
	if _possessing and _vessel == body and GameState.is_authority():
		_eject(false)


## Holy Taser current through `target` (see HolyTaser._shock_crewmate).
func exorcise(target: Node, delta: float, _by: Node = null) -> void:
	if not GameState.is_authority() or target != get_vessel():
		return
	# The meter leaks a little, so a single stray spark never finishes the job.
	exorcise_progress += delta * 1.25
	if exorcise_progress >= EXORCISE_TIME:
		_exorcised("the current")


# --- The rules -----------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not GameState.is_authority() or not is_instance_valid(_demon) or _brain == null:
		return
	if _possessing:
		_tick_possession(delta)
		return
	if is_instance_valid(_struggler):
		return
	_hungry_left = maxf(0.0, _hungry_left - delta)
	if not _brain.get(&"is_discovered") or _demon.get(&"is_stunned"):
		return
	cooldown_left = maxf(0.0, cooldown_left - delta)
	if cooldown_left > 0.0 or not HUNTING.has(int(_brain.get(&"state"))):
		return
	var victim := _pick_victim()
	if victim == null:
		return
	if NetworkManager.get_player_count() <= 1:
		_begin_struggle(victim)
	else:
		_possess(victim)


## The nearest player the demon may take right now, or null.
func _pick_victim() -> Player:
	var chest: Vector3 = _demon.call(&"get_center")
	var crew: Array[Player] = []
	for node in GameState.get_players():
		var body := node as Player
		if body and body.is_standing() and not body.possessed:
			crew.append(body)
	var alone := NetworkManager.get_player_count() <= 1
	var best: Player = null
	var best_distance := GRAB_RANGE
	for body in crew:
		var distance := body.global_position.distance_to(chest)
		if distance >= best_distance or body.is_knockdown_immune():
			continue
		if not alone and _hungry_left <= 0.0:
			var isolated := true
			for other in crew:
				if other != body and other.global_position.distance_to(body.global_position) < ISOLATION_RANGE:
					isolated = false
					break
			if not isolated and body.stamina > LOW_STAMINA * body.max_stamina:
				continue
		best_distance = distance
		best = body
	return best


## Waking with no tape on it, or one wrap: if its cooldown is nearly up, it comes straight for somebody.
func _on_demon_woke(bind_level: int) -> void:
	if bind_level <= 1 and cooldown_left < 15.0 and randf() < 0.6:
		cooldown_left = 0.0
		_hungry_left = 4.0


# --- Co-op: possession ----------------------------------------------------------------

func _possess(victim: Player) -> void:
	_vessel = victim
	_possessing = true
	possessions += 1
	exorcise_progress = 0.0
	_inside_time = 0.0
	_lunge_left = LUNGE_INTERVAL
	_last_at = victim.global_position
	_last_yaw = victim.rotation.y
	_fx(&"smoke", _demon.call(&"get_center"))
	_fx(&"smoke", victim.global_position + Vector3.UP * 1.1)
	_brain.call(&"enter_possession")
	victim.set_possessed(true)
	circle_active = true
	GameState.set_alert("EXORCISE %s! Tase or drag to Salt Circle!" % victim.display_name)
	GameState.post_notice("%s IS POSSESSED!" % victim.display_name)


func _tick_possession(delta: float) -> void:
	if not is_instance_valid(_vessel) or _vessel.is_queued_for_deletion():
		_eject(false)
		return
	_inside_time += delta
	exorcise_progress = maxf(0.0, exorcise_progress - delta * 0.25)
	_last_at = _vessel.global_position
	_last_yaw = _vessel.rotation.y
	if Vector2(_last_at.x - CIRCLE_CENTER.x, _last_at.z - CIRCLE_CENTER.z).length() < CIRCLE_RADIUS:
		_exorcised("the salt")
		return
	if _vessel.is_downed or _inside_time > POSSESSION_LIMIT:
		# Nothing left to ride, or nobody came: it steps back out on its own terms.
		var spent := _vessel
		_eject(false)
		spent.hurt(15.0)
		GameState.post_notice("THE DEMON CLIMBS BACK OUT OF %s" % spent.display_name)
		return
	# The passenger swings at anyone who gets close.
	_lunge_left -= delta
	if _lunge_left > 0.0 or not _vessel.is_standing() or _vessel.is_knocked_down():
		return
	for node in GameState.get_players():
		var other := node as Player
		if other == null or other == _vessel or not other.is_standing():
			continue
		var to := (other.global_position - _vessel.global_position) * Vector3(1.0, 0.0, 1.0)
		if to.length() < LUNGE_RANGE:
			_lunge_left = LUNGE_INTERVAL
			_vessel.play_shove()
			other.shoved((to.normalized() if to.length_squared() > 0.001 else Vector3.FORWARD) * 5.5 + Vector3.UP * 2.4)
			return


func _exorcised(how: String) -> void:
	var saved := _vessel.display_name if is_instance_valid(_vessel) else "THE VESSEL"
	exorcisms += 1
	_eject(true)
	GameState.post_notice("%s IS CLEAN  -  %s drove it out. It is down: tape it!" % [saved, how])


## Puts the demon back in the world beside whoever it was riding: laid out and stunned
## after an exorcism, on its feet and enraged otherwise.
func _eject(stunned: bool) -> void:
	var vessel := _vessel
	_vessel = null
	_possessing = false
	circle_active = false
	exorcise_progress = 0.0
	cooldown_left = randf_range(COOLDOWN_MIN, COOLDOWN_MAX)
	GameState.set_alert("")
	var forward := Basis(Vector3.UP, _last_yaw) * Vector3.FORWARD
	var spot := _last_at + forward * 1.4
	# Never through a wall: if there is no room in front, it lands where the player stands.
	var space := get_world_3d().direct_space_state
	var blocked := space.intersect_ray(PhysicsRayQueryParameters3D.create(_last_at + Vector3.UP, spot + Vector3.UP, GameState.LAYER_WORLD))
	if not blocked.is_empty():
		spot = _last_at
	if is_instance_valid(_demon) and _brain:
		_brain.call(&"leave_possession", Transform3D(Basis(Vector3.UP, _last_yaw), spot), stunned)
	_fx(&"smoke", spot + Vector3.UP)
	_fx(&"sparks", spot + Vector3.UP * 0.8)
	if is_instance_valid(vessel):
		vessel.set_possessed(false)
		vessel.shoved(-forward * 4.0 + Vector3.UP * 2.2)


func _release_vessel() -> void:
	if is_instance_valid(_vessel) and GameState.is_authority():
		_vessel.set_possessed(false)
		GameState.set_alert("")
	_vessel = null
	_possessing = false
	circle_active = false


# --- Solo: the struggle ----------------------------------------------------------------

func _begin_struggle(victim: Player) -> void:
	_struggler = victim
	struggles += 1
	if not victim.struggle_finished.is_connected(_on_struggle_finished):
		victim.struggle_finished.connect(_on_struggle_finished)
	_brain.call(&"hold_prey", STRUGGLE_TIME)
	victim.begin_struggle(STRUGGLE_TIME, STRUGGLE_PRESSES)
	_fx(&"shadow", victim.global_position + Vector3.UP * 1.2)
	GameState.post_notice_for(victim, "POSSESSION STRUGGLE  -  MASH [SPACE]!")


func _on_struggle_finished(success: bool) -> void:
	var victim := _struggler
	_struggler = null
	cooldown_left = randf_range(COOLDOWN_MIN, COOLDOWN_MAX)
	if not is_instance_valid(victim):
		return
	if is_instance_valid(_demon):
		_demon.call(&"blast_away", victim.global_position, 6.5 if success else 3.5, 12.0 if success else 0.0)
	if success:
		_fx(&"sparks", victim.global_position + Vector3.UP * 1.2)
		GameState.post_notice_for(victim, "YOU THREW IT OFF!")
		return
	# It got in for a moment: that hurts, and whatever was in hand is on the floor.
	victim.drop_held()
	victim.gadgets.holster()
	victim.hurt(STRUGGLE_DAMAGE)
	_fx(&"smoke", victim.global_position + Vector3.UP * 1.2)
	GameState.post_notice_for(victim, "IT GOT INSIDE YOUR HEAD  -  %d HP, gear dropped: re-equip!" % int(STRUGGLE_DAMAGE))


func _fx(kind: StringName, at: Vector3) -> void:
	if is_instance_valid(GameState.net):
		GameState.net.call(&"fx", kind, at)


# --- The salt circle -------------------------------------------------------------------

## A gritty ring of salt with warding runes inside it: a faint cold glow at rest, and
## flickering motes lifting off it while somebody needs exorcising.
func _build_circle() -> void:
	var circle := Node3D.new()
	circle.name = "SaltCircle"
	circle.position = CIRCLE_CENTER + Vector3.UP * 0.016
	add_child(circle)
	_ring_material = Occult.chalk_material(Color(0.86, 0.9, 0.96), 0.3)
	var runes := Occult.rune_circle(CIRCLE_RADIUS * 0.86, _ring_material, 413)
	circle.add_child(runes)
	# The poured salt itself: a low, lumpy band, white and matt.
	_salt_material = StandardMaterial3D.new()
	_salt_material.albedo_color = Color(0.9, 0.92, 0.95)
	_salt_material.roughness = 1.0
	_salt_material.emission_enabled = true
	_salt_material.emission = Color(0.8, 0.88, 1.0)
	_salt_material.emission_energy_multiplier = 0.12
	var grain := NoiseTexture2D.new()
	var noise := FastNoiseLite.new()
	noise.frequency = 0.35
	grain.noise = noise
	grain.width = 128
	grain.height = 128
	grain.as_normal_map = true
	grain.bump_strength = 6.0
	_salt_material.normal_enabled = true
	_salt_material.normal_texture = grain
	_salt_material.uv1_scale = Vector3(24.0, 2.0, 1.0)
	var band := TorusMesh.new()
	band.inner_radius = CIRCLE_RADIUS - 0.075
	band.outer_radius = CIRCLE_RADIUS + 0.075
	band.rings = 72
	band.ring_segments = 8
	var salt := MeshInstance3D.new()
	salt.name = "Salt"
	salt.mesh = band
	salt.material_override = _salt_material
	salt.scale = Vector3(1.0, 0.16, 1.0)
	salt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	circle.add_child(salt)

	_motes = Parts.particles(Color(0.85, 0.92, 1.0), 70, 1.5, Vector2(0.15, 0.7), Vector2(0.008, 0.022), Vector3(0.0, 0.35, 0.0), 14.0, false)
	_motes.name = "SaltMotes"
	var process := _motes.process_material as ParticleProcessMaterial
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	process.emission_ring_axis = Vector3.UP
	process.emission_ring_radius = CIRCLE_RADIUS + 0.05
	process.emission_ring_inner_radius = CIRCLE_RADIUS - 0.08
	process.emission_ring_height = 0.03
	circle.add_child(_motes)
	_glow = OmniLight3D.new()
	_glow.name = "SaltGlow"
	_glow.light_color = Color(0.78, 0.88, 1.0)
	_glow.omni_range = 4.2
	_glow.omni_attenuation = 1.5
	_glow.light_energy = 0.0
	_glow.shadow_enabled = false
	_glow.position = Vector3(0.0, 0.5, 0.0)
	circle.add_child(_glow)


func _process(delta: float) -> void:
	_clock += delta
	_wake = move_toward(_wake, 1.0 if circle_active else 0.0, delta * 2.5)
	_motes.emitting = circle_active
	var flicker := 0.75 + 0.25 * sin(_clock * 11.0) * sin(_clock * 3.7)
	_ring_material.emission_energy_multiplier = 0.3 + 1.3 * _wake * flicker
	_salt_material.emission_energy_multiplier = 0.12 + 0.9 * _wake * flicker
	_glow.light_energy = 0.9 * _wake * flicker
