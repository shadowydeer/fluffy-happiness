extends Node
## Poltergeist brain of the demon.
##
## LURKING              hunched in and around the ritual room, peeking through doorways
## STALKING             creeps toward a player inside the house; a torch beam in the
##                      face makes it freeze, twitch, then snap
## ENRAGED              roars, charges, swipes at arm's length and, every few seconds,
##                      switches to...
## POLTERGEIST_THROW    ...levitating nearby props and hurling them at the player
## STUNNED              limp ragdoll (the body handles it) until the stun meter drains
## CAPTURED             stunned with its torso inside the van's cargo cage
## POSSESSING           out of the world, riding inside a player (see PossessionSystem)
##
## It hunts whoever is nearest and still on their feet: every exorcist on site is
## a person, and it scales itself to how many of them there are. It no longer
## stands in a taser's arc either: a third of a stun meter of current and it
## sidesteps, blows the lamps or answers with a snap throw.
##
## Navigation is a waypoint graph of rooms and doorways from the LevelBuilder,
## with whisker rays for local steering; this script only writes intent into
## the ragdoll. It also haunts nearby house lights and owns the debug hotkeys'
## behaviour.

signal state_changed(state: int)
signal discovered
## The van's doors have shut on it.
signal sealed
## It dodged the current: 0 sidestep, 1 lamps blown, 2 snap throw.
signal evaded(kind: int)
## It came round from a stun with `bind_level` wraps still on it.
signal woke(bind_level: int)

enum State { LURKING, STALKING, ENRAGED, POLTERGEIST_THROW, STUNNED, CAPTURED, POSSESSING }
enum Evasion { SIDESTEP, BLACKOUT, SNAP_THROW }

const Ragdoll := preload("res://scripts/DemonRagdoll.gd")
const LevelBuilder := preload("res://scripts/LevelBuilder.gd")
const Player := preload("res://scripts/Player.gd")
const FlickerLight := preload("res://scripts/FlickerLight.gd")
const Mats := preload("res://scripts/MaterialLibrary.gd")

const STATE_NAMES: Array[String] = ["LURKING", "STALKING", "ENRAGED", "POLTERGEIST", "STUNNED", "CAPTURED", "POSSESSING"]
## Per crew size (1-4 people): stun it shrugs off, how hard it thrashes, how heavy it hauls.
const CREW_RESISTANCE: Array[float] = [1.0, 1.45, 1.85, 2.2]
const CREW_STRUGGLE: Array[float] = [1.0, 1.25, 1.45, 1.6]
const CREW_DRAG: Array[float] = [1.0, 1.35, 1.65, 1.9]
const WALK_MASK := 1        # world
const SIGHT_MASK := 1 | 8   # world and doors
const CAST_COLOR := Color(1.0, 0.24, 0.06)

@export_group("Movement")
@export var lurk_speed := 1.0
@export var stalk_speed := 1.35
@export var charge_speed := 4.7
@export var feeler_length := 1.3

@export_group("Senses")
@export var notice_range := 8.0
@export var torch_range := 15.0
@export var torch_cone_degrees := 13.0
@export var freeze_time := 0.75
@export var enrage_distance := 3.0
@export var stalk_patience := 24.0

@export_group("Attacks")
@export var swipe_range := 1.8
@export var swipe_reach := 2.35
@export var swipe_cooldown := 1.7
@export var swipe_knockback := 7.5
@export var swipe_damage := 28.0
@export var throw_interval_min := 5.0
@export var throw_interval_max := 8.0
@export var throw_range := 10.0
@export var throw_reach := 7.5
@export var throw_mass_limit := 30.0
@export var telegraph_time := 0.65
@export var levitate_height := 1.2
@export var throw_spread := 0.045

@export_group("Evasion")
## Stun points of current it takes, awake, before it does something about it.
@export var evade_threshold := 35.0
@export var blackout_radius := 10.0
@export var blackout_time_min := 6.0
@export var blackout_time_max := 8.0

@export_group("Haunting")
@export var haunt_radius := 7.0

var state: State = State.LURKING
## Tests set this to keep the demon lurking no matter what the player does.
var passive := false
var is_in_van := false
var is_sealed := false
var is_discovered := false
var throws_launched := 0
var swipes_landed := 0
var peak_haunt := 0.0
var evasions := 0
## A client's mirror of the host's brain: it thinks nothing, only haunts the lamps.
var is_remote := false
## What the body's mood looks like, for the wire (see `_update_mood`).
var mood_rage := 0.0
var mood_casting := false

var _ragdoll: Ragdoll
var _visuals: Node
var _audio: Node
var _level: LevelBuilder
var _player: Player
var _points := PackedVector3Array()
var _neighbours: Array[Array] = []
var _doors: Array[RigidBody3D] = []
var _fx_root: Node3D
var _cast_overlay: StandardMaterial3D

var _state_time := 0.0
var _previous: State = State.LURKING
var _distance := 999.0
var _height_gap := 0.0
var _sees_player := false
var _lit := false
var _player_inside := false
var _sense_left := 0.0
var _haunt_left := 0.0
var _buzz_left := 0.0
var _rasp_left := 3.0
var _door_left := 0.0

var _route: Array[Vector3] = []
var _repath_left := 0.0
var _stuck_anchor := Vector3.ZERO
var _stuck_time := 0.0
var _stuck_side := 1.0

var _lurk_node := -1
var _lurk_left := 0.0
var _lurk_hold := 0.0
var _lit_time := 0.0
var _freeze_left := 0.0
var _windup_left := 0.0
var _calm_time := 0.0
var _swipe_left := 0.0
var _swipe_hit_in := 0.0
var _swipe_forced := false
var _throw_left := 6.0
var _casts: Array[Dictionary] = []
var _cast_left := 0.0
var _cast_launched := false
var _recover_left := 0.0
var _closing_time := 0.0
## False when nobody on site is standing: it goes back to lurking.
var _has_prey := true
var _base: Dictionary = {}
var _tier := 0
var _crew := 1
var _evade_next := 35.0
var _stagger_left := 0.0
var _hold_left := 0.0
var _lunge_left := 0.0
var _lunge_direction := Vector3.ZERO


## Wires the brain to the level and its prey. Called by Main after everything exists.
func setup(level: Node, player: Node) -> void:
	_ragdoll = get_parent() as Ragdoll
	_visuals = _ragdoll.get_node_or_null("Visuals")
	_audio = _ragdoll.get_node_or_null("Audio")
	_level = level as LevelBuilder
	_player = player as Player
	_points = _level.nav_points
	_neighbours.clear()
	for i in _points.size():
		_neighbours.append([])
	for link in _level.nav_links:
		_neighbours[link.x].append(link.y)
		_neighbours[link.y].append(link.x)
	for door in _level.front_doors:
		_doors.append(door)
	for door in _level.interior_doors:
		_doors.append(door)
	# The cage has to notice demon limbs as well as props.
	_level.van.cargo_zone.collision_mask |= GameState.LAYER_DEMON
	_ragdoll.stun_changed.connect(_on_stun_changed)
	_ragdoll.grabbed.connect(_on_grabbed)
	_ragdoll.struggled.connect(_on_struggled)
	_ragdoll.provoked.connect(_on_provoked)
	_ragdoll.staggered.connect(_on_staggered)
	_ragdoll.broke_out.connect(_on_broke_out)
	_base = {"lurk": lurk_speed, "stalk": stalk_speed, "charge": charge_speed, "swipe": swipe_cooldown,
			"throw_min": throw_interval_min, "throw_max": throw_interval_max}
	_evade_next = evade_threshold
	_fx_root = Node3D.new()
	_fx_root.name = "PoltergeistFx"
	add_child(_fx_root)
	_cast_overlay = StandardMaterial3D.new()
	_cast_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cast_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cast_overlay.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_cast_overlay.albedo_color = Color(CAST_COLOR.r, CAST_COLOR.g, CAST_COLOR.b, 0.4)
	_throw_left = randf_range(throw_interval_min, throw_interval_max)
	_stuck_anchor = _ragdoll.get_ground_position()


func get_state_name() -> String:
	return STATE_NAMES[state]


## Each contract the crew survives, the next demon is a little quicker, meaner and harder
## to put down. `tier` is the number of contracts already paid out.
func apply_difficulty(tier: int) -> void:
	_tier = tier
	_retune()


## How many people are on site. One gets a hard, fair fight; two to four get a heavier,
## faster, angrier demon that takes teamwork. Called again whenever somebody leaves.
func set_player_count(count: int) -> void:
	_crew = clampi(count, 1, CREW_RESISTANCE.size())
	_retune()


func get_player_count() -> int:
	return _crew


## Who it is after right now.
func get_prey() -> Node3D:
	return _player if is_instance_valid(_player) else null


func _retune() -> void:
	if _base.is_empty():
		return
	var step := clampf(float(_tier), 0.0, 8.0)
	var extra := float(_crew - 1)
	var quick := (1.0 + 0.06 * step) * (1.0 + 0.05 * extra)
	lurk_speed = float(_base["lurk"]) * quick
	stalk_speed = float(_base["stalk"]) * quick
	charge_speed = float(_base["charge"]) * quick
	swipe_cooldown = float(_base["swipe"]) / ((1.0 + 0.05 * step) * (1.0 + 0.12 * extra))
	throw_interval_min = float(_base["throw_min"]) / ((1.0 + 0.07 * step) * (1.0 + 0.15 * extra))
	throw_interval_max = float(_base["throw_max"]) / ((1.0 + 0.07 * step) * (1.0 + 0.15 * extra))
	_ragdoll.stun_scale = 1.0 / (1.0 + 0.08 * step)
	_ragdoll.max_stun_resistance = CREW_RESISTANCE[_crew - 1]
	_ragdoll.struggle_force = CREW_STRUGGLE[_crew - 1]
	_ragdoll.drag_mass = CREW_DRAG[_crew - 1]


# --- Possession (driven by PossessionSystem) --------------------------------------------

## Vanishes into a player: the body leaves the world until `leave_possession`.
func enter_possession() -> void:
	_release_casts(true)
	_enter(State.POSSESSING)
	_ragdoll.set_dormant(true)


## Thrown back out at `at`: flat on the floor and stunned, or on its feet and furious.
func leave_possession(at: Transform3D, stunned: bool) -> void:
	_ragdoll.set_dormant(false)
	_ragdoll.place(at)
	_route.clear()
	_stuck_anchor = _ragdoll.get_ground_position()
	_evade_next = evade_threshold
	if stunned:
		_ragdoll.knock_out()
	else:
		_enter(State.ENRAGED)


## Stands over its prey with its hands on them for `seconds` (the solo possession struggle).
func hold_prey(seconds: float) -> void:
	_hold_left = seconds
	if _visuals:
		_visuals.call(&"flash")
	if _audio:
		_audio.call(&"play_roar")


## A client's copy of what the host's brain is doing.
func apply_net(next: int, found: bool, in_van: bool, sealed_in: bool, rage: float, casting: bool) -> void:
	is_in_van = in_van
	is_sealed = sealed_in
	mood_rage = rage
	mood_casting = casting
	next = clampi(next, 0, State.size() - 1)
	if next != state:
		state = next as State
		state_changed.emit(state)
	if found and not is_discovered:
		is_discovered = true
		discovered.emit()
	if _visuals:
		_visuals.call(&"set_mood", rage, _ragdoll.is_stunned, state == State.CAPTURED, casting)


# --- Debug hotkeys (K / J / L / P in Main) ---------------------------------------------

## K: instant stun, or wake if already stunned.
func debug_toggle_stun() -> void:
	_discover()
	if _ragdoll.is_stunned:
		_ragdoll.wake()
		GameState.post_notice("DEBUG  demon woken (stun 0)")
	else:
		_ragdoll.knock_out()
		GameState.post_notice("DEBUG  demon stunned (stun 100)")


## J: LURKING -> ENRAGED -> POLTERGEIST_THROW -> LURKING.
func debug_cycle_state() -> void:
	_discover()
	if _ragdoll.is_stunned:
		GameState.post_notice("DEBUG  demon is stunned - press K to wake it first")
		return
	match state:
		State.LURKING, State.STALKING:
			_enter(State.ENRAGED)
		State.ENRAGED:
			var props := _pick_throwables()
			if props.is_empty():
				GameState.post_notice("DEBUG  no loose props within %d m to throw" % int(throw_reach))
				return
			_begin_cast(props)
			_enter(State.POLTERGEIST_THROW)
		_:
			_lurk_hold = 6.0
			_enter(State.LURKING)
	GameState.post_notice("DEBUG  demon state: %s" % get_state_name())


## L: bind level 0 -> 1 -> 2 -> 3 -> 0.
func debug_cycle_bind() -> void:
	_discover()
	_ragdoll.set_bind_level((_ragdoll.bind_level + 1) % 4)
	GameState.post_notice("DEBUG  bind level %d / 3" % _ragdoll.bind_level)


## P: stands the demon a few steps in front of the player, to try the gadgets without the walk.
func debug_summon() -> void:
	if is_sealed:
		GameState.post_notice("DEBUG  the demon is sealed in the van")
		return
	_discover()
	var summoner := GameState.local_player as Node3D if is_instance_valid(GameState.local_player) else _player as Node3D
	var ahead := -summoner.global_transform.basis.z
	_ragdoll.place(Transform3D(Basis.looking_at(-ahead), summoner.global_position + ahead * 3.2))
	_route.clear()
	_stuck_anchor = _ragdoll.get_ground_position()
	GameState.post_notice("DEBUG  demon summoned")


# --- Main loop ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _ragdoll == null:
		return
	if is_remote:
		_haunt_lights(delta)
		return
	if not is_instance_valid(_player):
		# Whoever it was after has left the site.
		_player = null
		_choose_prey()
		if _player == null:
			return
	_state_time += delta
	if state == State.POSSESSING:
		_haunt_lights(delta)
		_update_mood()
		return
	_sense(delta)
	_haunt_lights(delta)
	_update_van(delta)
	_tick_evasion()
	_stagger_left = maxf(0.0, _stagger_left - delta)
	if not _has_prey and (state == State.STALKING or state == State.ENRAGED):
		# Everyone is on the floor: nothing left to chase.
		_enter(State.LURKING)
	if _hold_left > 0.0 and not _ragdoll.is_stunned:
		# Hands on its prey: it stands there and squeezes.
		_hold_left -= delta
		_ragdoll.pose = Ragdoll.Pose.CAST
		_look_at_player(true)
		_halt()
		_face(_player.global_position)
	elif _lunge_left > 0.0 and not _ragdoll.is_stunned:
		# Mid shadow-lunge: flat out sideways, eyes still on whoever is holding the taser.
		_lunge_left -= delta
		_ragdoll.pose = Ragdoll.Pose.CHASE
		_ragdoll.move_direction = _lunge_direction
		_ragdoll.move_speed = 9.0
		_face(_player.global_position)
	elif _stagger_left > 0.0 and not _ragdoll.is_stunned and state != State.POLTERGEIST_THROW:
		_halt()
	else:
		match state:
			State.LURKING:
				_tick_lurking(delta)
			State.STALKING:
				_tick_stalking(delta)
			State.ENRAGED:
				_tick_enraged(delta)
			State.POLTERGEIST_THROW:
				_tick_throwing(delta)
			_:
				_halt()
	_tick_swipe(delta)
	_update_mood()


func _enter(next: State) -> void:
	if state == State.POLTERGEIST_THROW and next != State.POLTERGEIST_THROW:
		_release_casts(not _cast_launched)
	_previous = state
	state = next
	_state_time = 0.0
	_route.clear()
	_repath_left = 0.0
	match next:
		State.LURKING:
			_lurk_left = 0.0
			_calm_time = 0.0
		State.STALKING:
			_lit_time = 0.0
			_freeze_left = 0.0
		State.ENRAGED:
			_calm_time = 0.0
			if _previous != State.POLTERGEIST_THROW:
				# Rear up and roar before the charge.
				_windup_left = 0.55
				_swipe_left = 0.4
				_throw_left = randf_range(throw_interval_min, throw_interval_max)
				_discover_if_near()
				if _audio:
					_audio.call(&"play_roar")
				if _visuals:
					_visuals.call(&"flash")
				if _distance < 16.0:
					_player.add_trauma(0.2 + 0.4 * (1.0 - _distance / 16.0))
		State.STUNNED, State.CAPTURED, State.POSSESSING:
			_halt()
	state_changed.emit(state)


func _sense(delta: float) -> void:
	var chest := _ragdoll.get_center()
	var to_player := _player.global_position + Vector3.UP - chest
	_distance = Vector2(to_player.x, to_player.z).length()
	_height_gap = to_player.y
	_sense_left -= delta
	if _sense_left > 0.0:
		return
	_sense_left = 0.12
	_choose_prey()
	var eyes := _player.global_position + Vector3.UP * 1.4
	_sees_player = not _blocked(_ragdoll.get_head_position(), eyes, SIGHT_MASK)
	var at := _player.global_position
	_player_inside = at.x > LevelBuilder.HOUSE_WEST and at.x < LevelBuilder.HOUSE_EAST and at.z > LevelBuilder.HOUSE_NORTH and at.z < LevelBuilder.HOUSE_SOUTH
	var aim := (chest - _player.get_view_origin()).normalized()
	var facing := _player.get_view_forward().dot(aim)
	_lit = _player.flashlight_on and _sees_player and _distance < torch_range and facing > cos(deg_to_rad(torch_cone_degrees))
	if _sees_player and _distance < 14.0 and facing > 0.55:
		_discover()


## Picks who to hunt: the nearest player still on their feet, with a bias toward the one
## it is already after so it does not dither between two people the same distance away.
func _choose_prey() -> void:
	var chest := _ragdoll.get_center()
	var best: Player = null
	var best_score := INF
	var anyone: Player = null
	for node in GameState.get_players():
		var candidate := node as Player
		if candidate == null:
			continue
		if anyone == null:
			anyone = candidate
		if not candidate.is_standing() or candidate.possessed:
			continue
		var score := candidate.global_position.distance_to(chest)
		if candidate == _player:
			score *= 0.7
		if score < best_score:
			best_score = score
			best = candidate
	_has_prey = best != null
	if best:
		_player = best
	elif not is_instance_valid(_player):
		_player = anyone


func _discover() -> void:
	if is_discovered:
		return
	is_discovered = true
	GameState.complete_step(GameState.STEP_LOCATE_DEMON)
	discovered.emit()


func _discover_if_near() -> void:
	if _distance < 14.0:
		_discover()


func _update_mood() -> void:
	if _visuals == null:
		return
	var rage := 0.0
	match state:
		State.STALKING:
			rage = 0.7 if _freeze_left > 0.0 else 0.25
		State.ENRAGED, State.POLTERGEIST_THROW:
			rage = 1.0
	mood_rage = rage
	mood_casting = state == State.POLTERGEIST_THROW
	_visuals.call(&"set_mood", rage, _ragdoll.is_stunned, state == State.CAPTURED, mood_casting)


# --- States ------------------------------------------------------------------------------

func _tick_lurking(delta: float) -> void:
	_ragdoll.pose = Ragdoll.Pose.LURK
	_look_at_player(_sees_player and _distance < 12.0)
	_lurk_hold = maxf(0.0, _lurk_hold - delta)
	_lurk_left -= delta
	if (_lurk_left <= 0.0 or _lurk_node < 0) and not _level.lurk_nodes.is_empty():
		# Drift to another vantage point: the dais, a corner, or a doorway to peek through.
		var options := _level.lurk_nodes
		var pick := options[randi() % options.size()]
		if pick == _lurk_node:
			pick = options[(randi() + 1) % options.size()]
		_lurk_node = pick
		_lurk_left = randf_range(5.0, 10.0)
	_rasp_left -= delta
	if _rasp_left <= 0.0:
		_rasp_left = randf_range(4.0, 7.0)
		if _audio and _distance < 14.0:
			_audio.call(&"play_rasp", 0.6)
	if _lurk_node >= 0:
		var spot := _points[_lurk_node]
		if _ragdoll.get_ground_position().distance_to(spot) > 0.7:
			_go_to(spot, lurk_speed, delta)
		else:
			_halt()
			if _sees_player:
				_face(_player.global_position)
	if passive or _lurk_hold > 0.0 or not _has_prey:
		return
	if _player_inside or (_sees_player and _distance < notice_range):
		_enter(State.STALKING)


func _tick_stalking(delta: float) -> void:
	_look_at_player(true)
	if _freeze_left > 0.0:
		# Caught in the beam: lock up, shield its face, then snap.
		_ragdoll.pose = Ragdoll.Pose.FREEZE
		_halt()
		_face(_player.global_position)
		_freeze_left -= delta
		if _freeze_left <= 0.0:
			_enter(State.ENRAGED)
		return
	_ragdoll.pose = Ragdoll.Pose.STALK
	if _lit:
		_lit_time += delta
		if _lit_time > 0.15:
			_freeze_left = freeze_time
			_discover()
			if _audio:
				_audio.call(&"play_rasp", 1.2)
			return
	else:
		_lit_time = maxf(0.0, _lit_time - delta)
	_go_to(_player.global_position, stalk_speed, delta)
	if (_distance < enrage_distance and _sees_player) or _state_time > stalk_patience:
		_enter(State.ENRAGED)
	elif passive or (not _player_inside and _distance > 15.0):
		_enter(State.LURKING)


func _tick_enraged(delta: float) -> void:
	_look_at_player(true)
	if _windup_left > 0.0:
		_windup_left -= delta
		_ragdoll.pose = Ragdoll.Pose.CAST
		_halt()
		_face(_player.global_position)
		return
	_ragdoll.pose = Ragdoll.Pose.CHASE
	# No kicking a player who is down or just back up: loom over them instead.
	var mercy := _player.is_knocked_down() or _player.is_knockdown_immune()
	_swipe_left = maxf(0.0, _swipe_left - delta)
	if mercy:
		if _distance > 2.6:
			_go_to(_player.global_position, stalk_speed, delta)
		else:
			_halt()
			_face(_player.global_position)
	elif _distance > 1.25:
		_go_to(_player.global_position, charge_speed, delta)
	else:
		_halt()
		_face(_player.global_position)
	if not mercy and _distance < swipe_range and absf(_height_gap) < 1.5 and _swipe_left <= 0.0 and _swipe_hit_in <= 0.0:
		_begin_swipe(false)

	if _distance < throw_range:
		_throw_left -= delta
		if _throw_left <= 0.0 and not mercy:
			var props := _pick_throwables()
			if props.is_empty():
				_throw_left = 2.0
			else:
				_begin_cast(props)
				_enter(State.POLTERGEIST_THROW)
				return

	# Lose interest once the prey is long gone.
	if _distance > 22.0 or (not _player_inside and _distance > 13.0):
		_calm_time += delta
		if _calm_time > 6.0:
			_enter(State.LURKING)
	else:
		_calm_time = 0.0


func _tick_throwing(delta: float) -> void:
	_ragdoll.pose = Ragdoll.Pose.CAST
	_look_at_player(true)
	_halt()
	_face(_player.global_position)
	_cast_left -= delta
	var progress := 1.0 - clampf(_cast_left / telegraph_time, 0.0, 1.0)
	for cast in _casts:
		var prop: RigidBody3D = cast["prop"]
		var fx: Node3D = cast["fx"]
		if not is_instance_valid(prop):
			continue
		if not _cast_launched:
			# Float it up to the launch height, slowly turning.
			var target := (cast["start"] as Vector3) + Vector3.UP * levitate_height
			var rise := ((target - prop.global_position) * 7.0).limit_length(3.5)
			prop.linear_velocity = prop.linear_velocity.lerp(rise, 0.4)
			prop.angular_velocity = prop.angular_velocity.lerp(Vector3(0.6, 2.4, 0.4), 0.1)
		fx.global_position = prop.global_position
		fx.rotate_y(delta * 9.0)
		(fx.get_node("Glow") as OmniLight3D).light_energy = 0.4 + 2.8 * progress + 0.4 * sin(_state_time * 40.0)
	if not _cast_launched and _cast_left <= 0.0:
		_cast_launched = true
		for cast in _casts:
			_launch(cast)
		if _audio:
			_audio.call(&"play_whoosh", 1.25)
		_ragdoll.swipe(randi() % 2)
	if _cast_launched:
		_recover_left -= delta
		if _recover_left <= 0.0:
			_throw_left = randf_range(throw_interval_min, throw_interval_max)
			_enter(State.ENRAGED)


# --- Stun, capture and being grabbed ------------------------------------------------------

func _on_stun_changed(stunned: bool) -> void:
	if is_remote:
		return
	_hold_left = 0.0
	if stunned:
		_discover()
		_enter(State.STUNNED)
		GameState.complete_step(GameState.STEP_SUBDUE_DEMON)
		return
	# Awake again: whatever progress depended on it being out cold is undone.
	is_in_van = false
	is_sealed = false
	GameState.revoke_step(GameState.STEP_SEAL_VAN)
	GameState.revoke_step(GameState.STEP_LOAD_DEMON)
	GameState.revoke_step(GameState.STEP_SUBDUE_DEMON)
	_evade_next = evade_threshold
	_enter(State.ENRAGED)
	woke.emit(_ragdoll.bind_level)


## Stunned with the torso in the cargo cage = captured. Shutting both doors on it seals it in.
func _update_van(delta: float) -> void:
	if not _ragdoll.is_stunned:
		return
	var van := _level.van
	var inside := van.cargo_zone.overlaps_body(_ragdoll.get_body(Ragdoll.Part.TORSO))
	if inside and state == State.STUNNED:
		is_in_van = true
		_ragdoll.stun_locked = true
		_enter(State.CAPTURED)
		GameState.complete_step(GameState.STEP_LOAD_DEMON)
	elif not inside and state == State.CAPTURED and not is_sealed:
		is_in_van = false
		_ragdoll.stun_locked = false
		_enter(State.STUNNED)
		GameState.revoke_step(GameState.STEP_LOAD_DEMON)
	if state != State.CAPTURED or is_sealed or van.left_door.is_open or van.right_door.is_open:
		_closing_time = 0.0
		return
	# The doors are swinging shut. Limbs hanging out over the sill are shoved back in; the
	# seal lands when both leaves are home, or after a moment if something still jams them.
	_closing_time += delta
	var inward := van.global_transform.basis.z
	for body in _ragdoll.get_bodies():
		if van.to_local(body.global_position).z < van.REAR_Z + 0.3:
			body.apply_central_force(inward * body.mass * 34.0)
	if van.are_doors_shut() or _closing_time > 1.4:
		is_sealed = true
		_ragdoll.contained = true
		sealed.emit()
		GameState.complete_step(GameState.STEP_SEAL_VAN)


## A rope round a limb or a jolt of current: whatever it was doing, it is angry now.
func _on_provoked(by: Node) -> void:
	if is_remote:
		return
	_discover()
	var attacker := by as Player
	if attacker == null:
		return
	if attacker.is_standing():
		_player = attacker
		_has_prey = true
	if state == State.LURKING or state == State.STALKING:
		_enter(State.ENRAGED)


## Laying hands on a conscious demon is answered at once.
func _on_grabbed(by: Node, _part: int) -> void:
	if is_remote:
		return
	_discover()
	var grabber := by as Player
	if _ragdoll.is_stunned or grabber == null:
		return
	_player = grabber
	_has_prey = true
	if state == State.LURKING or state == State.STALKING:
		_enter(State.ENRAGED)
		_windup_left = 0.0
	if _swipe_hit_in <= 0.0:
		_begin_swipe(true)


func _on_struggled(strength: float) -> void:
	if _audio and strength > 0.2 and _ragdoll.is_dragged():
		_audio.call(&"play_rasp", 0.5 + strength * 0.6)


## Shoved, or blown back by a second wind: it loses its footing for half a second.
func _on_staggered(by: Node) -> void:
	if is_remote or _ragdoll.is_stunned:
		return
	_stagger_left = 0.5
	_swipe_left = maxf(_swipe_left, 0.7)
	_hold_left = 0.0
	if by:
		_on_provoked(by)


## It ripped a layer of tape off mid-haul: a crack, a shower of sparks, and everyone knows.
func _on_broke_out(level_before: int) -> void:
	if is_remote:
		return
	if _visuals:
		_visuals.call(&"flash")
	if _audio:
		_audio.call(&"play_rasp", 1.4)
	if is_instance_valid(GameState.net):
		GameState.net.call(&"fx", &"snap", _ragdoll.get_center())
	if level_before > 0:
		GameState.post_notice("IT TORE THE TAPE OFF!  bind %d/3  -  tape it properly before you haul" % _ragdoll.bind_level)
	else:
		GameState.post_notice("IT WRENCHED FREE!  -  tape it [3] before you haul it")


# --- Evasion --------------------------------------------------------------------------------

## Awake and taking current, it does not just stand there. Every `evade_threshold` points
## of stun it answers with one of three things, whichever the room allows.
func _tick_evasion() -> void:
	if _ragdoll.is_stunned or state == State.CAPTURED:
		return
	var meter := _ragdoll.stun_meter
	if meter < 5.0:
		_evade_next = evade_threshold
		return
	if meter < _evade_next or state == State.POLTERGEIST_THROW:
		return
	_evade_next = meter + evade_threshold
	var options: Array[int] = [Evasion.SIDESTEP]
	var props := _pick_throwables()
	if not props.is_empty():
		options.append(Evasion.SNAP_THROW)
	if _lamps_near(_ragdoll.get_center()) > 0:
		options.append(Evasion.BLACKOUT)
		options.append(Evasion.BLACKOUT)
	var choice := options[randi() % options.size()]
	evasions += 1
	match choice:
		Evasion.SIDESTEP:
			_sidestep()
		Evasion.BLACKOUT:
			_blow_lamps()
		Evasion.SNAP_THROW:
			_begin_cast(props)
			# No long wind-up: this one is thrown from the hip.
			_cast_left = 0.3
			if state != State.ENRAGED:
				_enter(State.ENRAGED)
				_windup_left = 0.0
			_enter(State.POLTERGEIST_THROW)
			GameState.post_notice_for(_player, "IT ANSWERS WITH THE FURNITURE!")
	evaded.emit(choice)


## A shadow lunge out of the arc: hard sideways, to whichever side has room.
func _sidestep() -> void:
	var chest := _ragdoll.get_center()
	var from_player := (chest - _player.global_position) * Vector3(1.0, 0.0, 1.0)
	from_player = from_player.normalized() if from_player.length_squared() > 0.001 else _ragdoll.get_facing()
	var side := from_player.cross(Vector3.UP)
	if randf() < 0.5:
		side = -side
	if _blocked(chest, chest + side * 2.6, WALK_MASK):
		side = -side
	_ragdoll.nudge(side * 6.0 + Vector3.UP * 1.1)
	_lunge_direction = side
	_lunge_left = 0.42
	_stagger_left = 0.0
	_swipe_left = minf(_swipe_left, 0.25)
	_route.clear()
	_repath_left = 0.0
	if _visuals:
		_visuals.call(&"shadow_step")
	if _audio:
		_audio.call(&"play_whoosh", 0.7)
	if is_instance_valid(GameState.net):
		GameState.net.call(&"fx", &"shadow", chest)
	GameState.post_notice_for(_player, "IT SLIPS THE CURRENT  -  rope it [1] to hold it still")


## Every lamp and candle near it goes out for six to eight seconds. Headlamps still work.
func _blow_lamps() -> void:
	var chest := _ragdoll.get_center()
	var seconds := randf_range(blackout_time_min, blackout_time_max)
	if is_instance_valid(GameState.net):
		GameState.net.call(&"blackout", chest, blackout_radius, seconds)
	if _audio:
		_audio.call(&"play_buzz", 1.4)
		_audio.call(&"play_roar")
	if _visuals:
		_visuals.call(&"flash")
	GameState.post_notice("THE LAMPS BLOW OUT  -  headlamps on [T]")


func _lamps_near(chest: Vector3) -> int:
	var count := 0
	for node in get_tree().get_nodes_in_group(FlickerLight.GROUP):
		var light := node.get_parent() as Node3D
		if light and light.global_position.distance_to(chest) < blackout_radius and not (node as FlickerLight).is_blacked_out():
			var at := light.global_position
			if at.x > LevelBuilder.HOUSE_WEST and at.x < LevelBuilder.HOUSE_EAST and at.z > LevelBuilder.HOUSE_NORTH and at.z < LevelBuilder.HOUSE_SOUTH:
				count += 1
	return count


# --- Swipe ---------------------------------------------------------------------------------

func _begin_swipe(forced: bool) -> void:
	_swipe_left = swipe_cooldown
	_swipe_hit_in = 0.24
	_swipe_forced = forced
	# Lead with the arm on the player's side.
	var across := (_player.global_position - _ragdoll.get_center()).dot(_ragdoll.get_facing().cross(Vector3.UP))
	_ragdoll.swipe(1 if across > 0.0 else 0)
	if _audio:
		_audio.call(&"play_whoosh", 1.5)


func _tick_swipe(delta: float) -> void:
	if _swipe_hit_in <= 0.0:
		return
	_swipe_hit_in -= delta
	if _swipe_hit_in > 0.0 or _ragdoll.is_stunned:
		return
	var chest := _ragdoll.get_center()
	var to_player := _player.global_position + Vector3.UP * 0.9 - chest
	var flat := Vector3(to_player.x, 0.0, to_player.z)
	var reach := 3.5 if _swipe_forced else swipe_reach
	if flat.length() < reach and absf(to_player.y) < 1.7:
		var away := flat.normalized() if flat.length_squared() > 0.001 else _ragdoll.get_facing()
		if _player.knock_down(away * swipe_knockback + Vector3.UP * 2.6, _ragdoll, swipe_damage):
			swipes_landed += 1
			if _audio:
				_audio.call(&"play_thud", 1.4)
	# Whatever clutter was inside the arc gets batted across the room too.
	var facing := _ragdoll.get_facing()
	for node in get_tree().get_nodes_in_group(GameState.GROUP_GRABBABLE):
		var prop := node as RigidBody3D
		if prop == null or prop.freeze:
			continue
		var offset := prop.global_position - chest
		if offset.length() < 1.9 and offset.dot(facing) > 0.0:
			prop.apply_central_impulse((offset.normalized() + Vector3.UP * 0.35) * minf(prop.mass, 12.0) * 5.0)


# --- Poltergeist throw ---------------------------------------------------------------------

## Up to two loose props near the demon, preferring ones with a clear line to the player.
func _pick_throwables() -> Array[RigidBody3D]:
	var origin := _ragdoll.get_center()
	var target := _player.global_position + Vector3.UP
	var held := _player.get_held()
	var scored: Array[Dictionary] = []
	for node in get_tree().get_nodes_in_group(GameState.GROUP_GRABBABLE):
		var prop := node as RigidBody3D
		if prop == null or prop.freeze or prop == held or prop.mass < 0.8 or prop.mass > throw_mass_limit:
			continue
		var distance := prop.global_position.distance_to(origin)
		if distance > throw_reach:
			continue
		var blocked := _blocked(prop.global_position + Vector3.UP * levitate_height, target, WALK_MASK)
		scored.append({"prop": prop, "score": distance + (6.0 if blocked else 0.0)})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) < float(b["score"]))
	var picked: Array[RigidBody3D] = []
	for i in mini(scored.size(), 2 if randf() < 0.55 else 1):
		picked.append(scored[i]["prop"])
	return picked


func _begin_cast(props: Array[RigidBody3D]) -> void:
	_release_casts(true)
	for prop in props:
		var fx := _make_cast_fx()
		_fx_root.add_child(fx)
		fx.global_position = prop.global_position
		var meshes: Array[MeshInstance3D] = []
		for child in prop.find_children("*", "MeshInstance3D", true, false):
			var mesh := child as MeshInstance3D
			if mesh.material_overlay == null:
				mesh.material_overlay = _cast_overlay
				meshes.append(mesh)
		# The demon must not swat its own missiles out of the air.
		for body in _ragdoll.get_bodies():
			prop.add_collision_exception_with(body)
		_casts.append({"prop": prop, "start": prop.global_position, "gravity": prop.gravity_scale, "fx": fx, "meshes": meshes})
		prop.gravity_scale = 0.0
		prop.sleeping = false
	_cast_left = telegraph_time
	_cast_launched = false
	_recover_left = 0.45
	if _audio:
		_audio.call(&"play_whoosh", 0.8)


func _launch(cast: Dictionary) -> void:
	var prop: RigidBody3D = cast["prop"]
	if not is_instance_valid(prop):
		return
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var speed := clampf(17.0 - prop.mass * 0.2, 11.0, 16.0)
	# Aim the centre of mass, not the origin at the prop's base, or tall props sail high.
	var origin := GameState.mass_center(prop)
	var target := _player.global_position + Vector3.UP
	var flight := origin.distance_to(target) / speed
	# Lead a moving target a little, then lob just enough to cancel the drop.
	target += _player.velocity * flight * 0.55
	var aim := (target - origin).normalized()
	aim = (aim + Vector3(randf_range(-1.0, 1.0), randf_range(-0.6, 0.6), randf_range(-1.0, 1.0)) * throw_spread).normalized()
	prop.gravity_scale = float(cast["gravity"])
	prop.linear_velocity = aim * speed + Vector3.UP * (0.5 * gravity * prop.gravity_scale * flight)
	prop.angular_velocity = Vector3(randf_range(-6.0, 6.0), randf_range(-6.0, 6.0), randf_range(-6.0, 6.0))
	prop.sleeping = false
	# For the next couple of seconds this prop is a weapon: it hurts whoever it hits.
	prop.set_meta(&"hurled_until", Time.get_ticks_msec() + 2500)
	throws_launched += 1
	get_tree().create_timer(0.8).timeout.connect(_end_cast.bind(cast))


## Drops any props still being held aloft (the demon was stunned mid-cast) and clears the glow.
func _release_casts(drop: bool) -> void:
	for cast in _casts:
		var prop: Variant = cast["prop"]
		if drop:
			if is_instance_valid(prop):
				(prop as RigidBody3D).gravity_scale = float(cast["gravity"])
			_end_cast(cast)
	_casts.clear()


func _end_cast(cast: Dictionary) -> void:
	var fx: Variant = cast["fx"]
	if is_instance_valid(fx):
		(fx as Node).queue_free()
	for mesh: Variant in cast["meshes"]:
		if is_instance_valid(mesh) and (mesh as MeshInstance3D).material_overlay == _cast_overlay:
			(mesh as MeshInstance3D).material_overlay = null
	var prop: Variant = cast["prop"]
	if is_instance_valid(prop) and is_instance_valid(_ragdoll):
		for body in _ragdoll.get_bodies():
			(prop as RigidBody3D).remove_collision_exception_with(body)


## Crimson light plus a ring of dust that the caller spins around the prop.
func _make_cast_fx() -> Node3D:
	var fx := Node3D.new()
	fx.name = "Cast"
	var glow := OmniLight3D.new()
	glow.name = "Glow"
	glow.light_color = CAST_COLOR
	glow.light_energy = 0.4
	glow.omni_range = 2.6
	glow.omni_attenuation = 1.4
	glow.light_volumetric_fog_energy = 2.0
	glow.shadow_enabled = false
	fx.add_child(glow)
	var swirl := ParticleProcessMaterial.new()
	swirl.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	swirl.emission_ring_axis = Vector3.UP
	swirl.emission_ring_radius = 0.6
	swirl.emission_ring_inner_radius = 0.42
	swirl.emission_ring_height = 0.5
	swirl.direction = Vector3.UP
	swirl.spread = 25.0
	swirl.gravity = Vector3(0.0, 0.9, 0.0)
	swirl.initial_velocity_min = 0.1
	swirl.initial_velocity_max = 0.5
	swirl.scale_min = 0.03
	swirl.scale_max = 0.07
	swirl.color = Color(2.2, 0.7, 0.25)
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	fade.colors = PackedColorArray([Color(1.0, 0.6, 0.3, 0.0), Color(1.0, 0.35, 0.12, 0.9), Color(0.6, 0.05, 0.02, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	swirl.color_ramp = ramp
	var speck := QuadMesh.new()
	speck.size = Vector2.ONE
	speck.material = Mats.dust_mote()
	var dust := GPUParticles3D.new()
	dust.name = "Swirl"
	dust.amount = 30
	dust.lifetime = 0.6
	dust.local_coords = true
	dust.process_material = swirl
	dust.draw_pass_1 = speck
	dust.visibility_aabb = AABB(Vector3.ONE * -1.5, Vector3.ONE * 3.0)
	dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fx.add_child(dust)
	return fx


# --- Haunting --------------------------------------------------------------------------------

## Lamps and candles inside the house stutter while the demon is within `haunt_radius`.
func _haunt_lights(delta: float) -> void:
	_haunt_left -= delta
	_buzz_left -= delta
	if _haunt_left > 0.0:
		return
	_haunt_left = 0.1
	var chest := _ragdoll.get_center()
	var presence := 0.0 if state == State.CAPTURED or state == State.POSSESSING else (0.35 if _ragdoll.is_stunned else 1.0)
	var strongest := 0.0
	for node in get_tree().get_nodes_in_group(FlickerLight.GROUP):
		var flicker := node as FlickerLight
		var light := flicker.get_parent() as Node3D
		if light == null:
			continue
		var at := light.global_position
		var amount := 0.0
		if at.x > LevelBuilder.HOUSE_WEST and at.x < LevelBuilder.HOUSE_EAST and at.z > LevelBuilder.HOUSE_NORTH and at.z < LevelBuilder.HOUSE_SOUTH:
			var distance := at.distance_to(chest)
			if distance < haunt_radius:
				amount = clampf(1.15 - distance / haunt_radius, 0.0, 1.0) * presence
		flicker.haunt_target = amount
		strongest = maxf(strongest, amount)
	peak_haunt = strongest
	if strongest > 0.35 and _buzz_left <= 0.0 and _audio:
		_buzz_left = randf_range(0.5, 1.4)
		_audio.call(&"play_buzz", strongest)


# --- Movement --------------------------------------------------------------------------------

func _halt() -> void:
	_ragdoll.move_speed = 0.0
	_ragdoll.move_direction = Vector3.ZERO
	_stuck_time = 0.0


func _face(point: Vector3) -> void:
	var to := point - _ragdoll.get_center()
	to.y = 0.0
	if to.length_squared() > 0.01:
		_ragdoll.face_direction = to.normalized()


func _look_at_player(active: bool) -> void:
	_ragdoll.has_look_target = active
	if active:
		_ragdoll.look_target = _player.global_position + Vector3.UP * 1.5


## Walks toward `target`: straight if the way is clear, otherwise along the waypoint graph.
func _go_to(target: Vector3, speed: float, delta: float) -> void:
	var from := _ragdoll.get_ground_position()
	_repath_left -= delta
	if _repath_left <= 0.0:
		_repath_left = 0.4
		_plan(from, target)
	while not _route.is_empty() and Vector2(_route[0].x - from.x, _route[0].z - from.z).length() < 0.75:
		_route.remove_at(0)
	var aim := target if _route.is_empty() else _route[0]
	var heading := Vector3(aim.x - from.x, 0.0, aim.z - from.z)
	var remaining := heading.length()
	if remaining < 0.08:
		_halt()
		return
	heading = _avoid(from, heading / remaining)
	_ragdoll.move_direction = heading
	# Ease in on the final approach so it does not overshoot its spot.
	_ragdoll.move_speed = speed * (clampf(remaining / 0.8, 0.35, 1.0) if _route.is_empty() else 1.0)
	_ragdoll.face_direction = heading
	_open_doors(from, delta)
	_watch_for_stuck(from, heading, speed, delta)


func _plan(from: Vector3, target: Vector3) -> void:
	_route.clear()
	if _clear_walk(from, target):
		return
	var start := _nearest_node(from)
	var goal := _nearest_node(target)
	if start < 0 or goal < 0:
		return
	for index in _shortest_path(start, goal):
		_route.append(_points[index])
	# Skip waypoints that can already be walked past.
	while _route.size() >= 2 and _clear_walk(from, _route[1]):
		_route.remove_at(0)


## True when a body-wide corridor between two floor points is free of walls.
func _clear_walk(a: Vector3, b: Vector3) -> bool:
	if absf(a.y - b.y) > 0.7:
		return false
	var flat := Vector3(b.x - a.x, 0.0, b.z - a.z)
	var length := flat.length()
	if length > 16.0:
		return false
	if length < 0.05:
		return true
	for lift: float in [0.4, 1.25]:
		if _blocked(a + Vector3.UP * lift, b + Vector3.UP * lift, WALK_MASK):
			return false
	var side := flat.normalized().cross(Vector3.UP) * 0.32
	for offset: Vector3 in [side, -side]:
		if _blocked(a + Vector3.UP * 0.8 + offset, b + Vector3.UP * 0.8 + offset, WALK_MASK):
			return false
	return true


func _nearest_node(from: Vector3) -> int:
	var best := -1
	var best_distance := INF
	var fallback := -1
	var fallback_distance := INF
	for i in _points.size():
		var distance := from.distance_to(_points[i])
		if absf(from.y - _points[i].y) < 1.2 and distance < fallback_distance:
			fallback_distance = distance
			fallback = i
		if distance < best_distance and distance < 12.0 and _clear_walk(from, _points[i]):
			best_distance = distance
			best = i
	return best if best >= 0 else fallback


## Dijkstra over the (tiny) waypoint graph.
func _shortest_path(start: int, goal: int) -> PackedInt32Array:
	var count := _points.size()
	var cost: Array[float] = []
	var parent: Array[int] = []
	var done: Array[bool] = []
	for i in count:
		cost.append(INF)
		parent.append(-1)
		done.append(false)
	cost[start] = 0.0
	for step in count:
		var current := -1
		for i in count:
			if not done[i] and cost[i] < INF and (current < 0 or cost[i] < cost[current]):
				current = i
		if current < 0 or current == goal:
			break
		done[current] = true
		for next: int in _neighbours[current]:
			var through := cost[current] + _points[current].distance_to(_points[next])
			if through < cost[next]:
				cost[next] = through
				parent[next] = current
	var path := PackedInt32Array()
	if cost[goal] == INF:
		return path
	var node := goal
	while node >= 0:
		path.append(node)
		node = parent[node]
	path.reverse()
	return path


## Whisker rays: walls ahead and to either side push the heading away from them.
func _avoid(from: Vector3, heading: Vector3) -> Vector3:
	var space := _ragdoll.get_world_3d().direct_space_state
	var origin := from + Vector3.UP * 0.8
	var push := Vector3.ZERO
	for angle: float in [0.0, 0.6, -0.6]:
		var probe := heading.rotated(Vector3.UP, angle)
		var query := PhysicsRayQueryParameters3D.create(origin, origin + probe * feeler_length, WALK_MASK)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit["normal"]
		normal.y = 0.0
		if normal.length_squared() < 0.01:
			continue
		var closeness := 1.0 - origin.distance_to(hit["position"]) / feeler_length
		push += normal.normalized() * closeness * (1.0 if angle == 0.0 else 0.6)
	if push == Vector3.ZERO:
		return heading
	var steered := heading + push * 1.3
	steered.y = 0.0
	return steered.normalized() if steered.length_squared() > 0.01 else heading.cross(Vector3.UP)


## Shut doors in its way swing open by themselves.
func _open_doors(from: Vector3, delta: float) -> void:
	_door_left -= delta
	if _door_left > 0.0:
		return
	_door_left = 0.3
	for door in _doors:
		if is_instance_valid(door) and not door.get(&"is_open") and door.global_position.distance_to(from + Vector3.UP) < 2.4:
			door.call(&"set_open", true)


## Not getting anywhere: sidestep, hop and re-plan.
func _watch_for_stuck(from: Vector3, heading: Vector3, speed: float, delta: float) -> void:
	if from.distance_to(_stuck_anchor) > 0.45:
		_stuck_anchor = from
		_stuck_time = 0.0
		return
	if speed < 0.5:
		return
	_stuck_time += delta
	if _stuck_time > 1.2:
		_stuck_time = 0.5
		_stuck_side = -_stuck_side
		_ragdoll.nudge(heading.cross(Vector3.UP) * _stuck_side * 2.0 + Vector3.UP * 1.2)
		_repath_left = 0.0


func _blocked(from: Vector3, to: Vector3, mask: int) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from, to, mask)
	return not _ragdoll.get_world_3d().direct_space_state.intersect_ray(query).is_empty()
