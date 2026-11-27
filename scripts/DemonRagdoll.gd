extends Node3D
## Active-ragdoll body of the demon.
##
## Eleven RigidBody3D segments joined by Generic6DOFJoint3D with anatomical
## angular limits. All segments sit on the `demon_limbs` physics layer and none
## of them masks it, so limbs can never collide with (or explode against) each
## other, while still hitting the world, props, doors and the player.
##
## The segments are invisible collider-only drivers. Their sizes, positions and
## joint anchors come from the rest pose of the skinned demon model (see
## DemonSkeletonDriver.gd), which is the only thing that renders.
##
## Conscious: a PD torque keeps pelvis and torso upright, a hover spring fed by
## ground rays under the hips and feet carries the weight (so it walks stairs),
## and every limb is steered toward a procedural pose.
## Stunned: all of that is switched off and the body drops as dead weight; while
## someone drags it, struggle pulses thrash the limbs, weaker at each bind level.
##
## The AI only sets intent (`pose`, `move_direction`, `move_speed`,
## `face_direction`, `look_target`); this script turns it into forces.

signal stun_changed(stunned: bool)
signal bind_changed(level: int)
signal grabbed(by: Node, part: int)
signal released(by: Node)
signal struggled(strength: float)
signal impacted(speed: float)
## Something a player did (a lasso, a shock) that a conscious demon will not let pass.
signal provoked(by: Node)
## A player shoved it, or something blew it back: it reels for a moment.
signal staggered(by: Node)
## It tore a layer of tape off mid-haul. `level_before` is the bind level it had.
signal broke_out(level_before: int)

enum Part { PELVIS, TORSO, HEAD, UPPER_ARM_L, LOWER_ARM_L, UPPER_ARM_R, LOWER_ARM_R, UPPER_LEG_L, LOWER_LEG_L, UPPER_LEG_R, LOWER_LEG_R }
enum Pose { LURK, STALK, CHASE, CAST, FREEZE }

const PART_NAMES: Array[String] = ["Pelvis", "Torso", "Head", "UpperArmL", "LowerArmL", "UpperArmR", "LowerArmR", "UpperLegL", "LowerLegL", "UpperLegR", "LowerLegR"]
## What the crosshair prompt calls each segment.
const PART_LABELS: Array[String] = ["HIPS", "TORSO", "HEAD", "ARM", "WRIST", "ARM", "WRIST", "LEG", "ANKLE", "LEG", "ANKLE"]
const PART_MASS: Array[float] = [10.0, 16.0, 4.0, 3.0, 2.6, 3.0, 2.6, 3.5, 3.0, 3.5, 3.0]
const PART_PARENT: Array[int] = [-1, Part.PELVIS, Part.TORSO, Part.TORSO, Part.UPPER_ARM_L, Part.TORSO, Part.UPPER_ARM_R, Part.PELVIS, Part.UPPER_LEG_L, Part.PELVIS, Part.UPPER_LEG_R]

# Hip height for each Pose as a share of the straight-legged height, and extra forward
# lean in radians. The model's rest pose is already hunched, so the lean stays modest
# and the demon keeps its full towering height.
const POSE_STANCE: Array[float] = [0.87, 0.94, 0.955, 0.995, 0.9]
const POSE_HUNCH: Array[float] = [0.30, 0.16, 0.10, -0.2, 0.26]
## N*m at 90 degrees of lean: cancels most of the droop from the head and arms hanging off the chest.
const CHEST_LIFT := 60.0
## It stoops this much further while something hangs low over its horns (a lintel, the van roof).
const DUCK_HUNCH := 0.22
const DUCK_STANCE := 0.06

const HOVER_STIFFNESS := 60.0
const HOVER_DAMPING := 12.0
const MOVE_RESPONSE := 7.0
const MAX_MOVE_ACCELERATION := 16.0
const RISE_TIME := 0.6
const MAX_SPEED := 22.0
const MAX_SPIN := 30.0
## A segment this many body heights from the hips means a joint has let go.
const MAX_STRETCH_RATIO := 1.3
## Seconds a collapsing body keeps its line (see `_topple`), and the m/s^2 that tip the
## chest over and fling the arms out ahead of it.
const FALL_TIME := 0.9
const FALL_TIP := 5.0
const FALL_FLING := 22.0

## Stun points lost per second at bind level 0..3.
const STUN_DECAY: Array[float] = [2.5, 2.0, 1.5, 1.0]
## Struggle strength at bind level 0..3.
const STRUGGLE: Array[float] = [1.0, 0.6, 0.3, 0.1]
## Pull available on a stunned segment, and the weight it adds to whoever drags it, at bind level 0..3.
const DRAG_FORCE: Array[float] = [540.0, 680.0, 840.0, 1000.0]
const DRAG_CARRY: Array[float] = [44.0, 34.0, 22.0, 9.0]
const AWAKE_DRAG_FORCE := 70.0
## How firmly tape holds wrapped limbs in place at bind level 0..3 (see `_bind_drive`).
const BIND_HOLD: Array[float] = [0.0, 0.45, 0.8, 1.2]
## Stun points a conscious demon shakes off per second once nothing is shocking it.
const STUN_BLEED := 14.0
## For this long after waking, current only does half its work: no stun-locking with slot 2.
const SHOCK_RESIST_TIME := 4.0
const SHOCK_RESIST := 0.5
## Seconds of being hauled before it rips free, at bind level 0..3. Level 3 holds.
const BREAKOUT_TIME: Array[float] = [6.5, 10.0, 28.0, INF]
## Stun points a breakout costs it: it is closer to waking every time.
const BREAKOUT_STUN_COST := 25.0

# --- Intent, written by the AI ------------------------------------------------
var pose: Pose = Pose.LURK
var move_direction := Vector3.ZERO
var move_speed := 0.0
var face_direction := Vector3.FORWARD
var look_target := Vector3.ZERO
var has_look_target := false
var turn_rate := 5.0

# --- State ----------------------------------------------------------------------
var stun_meter := 0.0
var is_stunned := false
## 0..3, raised by Stage 3 binding gadgets.
var bind_level := 0
## Set while the demon is caged: the stun meter stops draining.
var stun_locked := false
## Set once the van is sealed on it: no more struggling, it is cargo now.
var contained := false
## Multiplies stun dealt to a conscious demon; later contracts bring tougher ones.
var stun_scale := 1.0
## Crew scaling, set by the brain from the number of people on site (all 1.0 for one):
## how much stun it shrugs off, how hard it thrashes, and how heavy it is to haul.
var max_stun_resistance := 1.0
var struggle_force := 1.0
var drag_mass := 1.0
## Seconds of shock resistance left (see SHOCK_RESIST_TIME).
var shock_resist_left := 0.0
## 0..1: how close a hauled, badly taped demon is to ripping free.
var breakout_tension := 0.0
var breakouts := 0
## Out of the world altogether: it is riding inside a player (see PossessionSystem).
var is_dormant := false
## A client's mirror of the host's demon: no simulation, bodies posed from the wire.
var is_remote := false
## On a client: how many of the crew the host says are hauling it.
var net_haulers := 0
## Times the safety net had to rebuild the ragdoll (NaN, runaway speed, stretched joint). Should stay 0.
var fault_count := 0
var peak_speed := 0.0

var _bodies: Array[RigidBody3D] = []
var _joints: Array[Generic6DOFJoint3D] = []
var _rest: Array[Vector3] = []
var _inertia: Array[float] = []
var _total_mass := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _driver: Node

# Rest-pose measurements in metres above the soles (the demon faces -Z, +X is its right).
# Filled from the skinned model's skeleton; `_fallback_layout()` covers a missing model.
var _layout: Dictionary = {}
var _pelvis_y := 1.12
var _hip_y := 1.08
var _upper_leg := 0.52
var _lower_leg := 0.50
var _ankle := 0.07
var _standing_height := 2.1

var _time := 0.0
var _yaw := 0.0
var _height := 0.8
var _hunch := 0.3
var _duck := 0.0
var _duck_left := 0.0
var _fall_left := 0.0
var _fall_direction := Vector3.FORWARD
var _shock_left := 0.0
var _convulse_left := 0.0
var _gait := 0.0
var _support := 1.0
var _ground_y := 0.0
var _grounded := false
var _jitter: Array[float] = [0.0, 0.0]
var _jitter_left := 0.0
var _head_tilt := 0.0
var _tilt_left := 0.0
var _swipe_arm := -1
var _swipe_time := 0.0
var _struggle_left := 1.0
var _strain := 0.0
var _snag_time := 0.0
var _holders: Dictionary = {}
## Knocked off balance: for this long its legs do not fight whatever velocity it was given.
var _reel_left := 0.0
## Lasso -> true when that rope is pinned to an anchor, false while a player holds it.
var _ropes: Dictionary = {}
var _safe := Transform3D.IDENTITY
var _safe_left := 0.0
var _core_speed := 0.0
var _thud_left := 0.0


func _ready() -> void:
	add_to_group(GameState.GROUP_DEMON)
	var spawn := global_transform
	global_transform = Transform3D.IDENTITY
	# The skinned model is measured first: the physics is built to fit it.
	_driver = get_node_or_null("Driver")
	if _driver and _driver.has_method(&"prepare"):
		_layout = _driver.call(&"prepare", self)
	if _layout.is_empty():
		_layout = _fallback_layout()
	_build_bodies()
	_build_joints()
	if _driver and _driver.has_method(&"bind"):
		_driver.call(&"bind", _bodies)
	for helper_name: String in ["Visuals", "Audio"]:
		var helper := get_node_or_null(helper_name)
		if helper and helper.has_method(&"build"):
			helper.call(&"build", self)
	place(spawn)


# --- Public API -------------------------------------------------------------------

func get_body(part: int) -> RigidBody3D:
	return _bodies[part]


func get_bodies() -> Array[RigidBody3D]:
	return _bodies


func get_joint_count() -> int:
	return _joints.size()


func get_total_mass() -> float:
	return _total_mass


## Height of the horn tips when it stands straight, in metres.
func get_standing_height() -> float:
	return _standing_height


## Rest-pose measurements the bodies were built from (see DemonSkeletonDriver.prepare).
func get_layout() -> Dictionary:
	return _layout


## Chest position: what the AI, the audio and the HUD treat as "where the demon is".
func get_center() -> Vector3:
	return _bodies[Part.TORSO].global_position


func get_head_position() -> Vector3:
	return _bodies[Part.HEAD].global_position


## Point on the floor under the hips.
func get_ground_position() -> Vector3:
	var hips := _bodies[Part.PELVIS].global_position
	if is_stunned:
		return Vector3(hips.x, hips.y - 0.15, hips.z)
	return Vector3(hips.x, _ground_y if _grounded else hips.y - _height, hips.z)


func get_velocity() -> Vector3:
	return _bodies[Part.PELVIS].linear_velocity


func get_facing() -> Vector3:
	return Basis(Vector3.UP, _yaw) * Vector3.FORWARD


func is_grounded() -> bool:
	return _grounded


## Rebuilds the standing rest pose at `xf` with every velocity zeroed.
func place(xf: Transform3D) -> void:
	var clean := Transform3D(Basis(Vector3.UP, xf.basis.get_euler().y), xf.origin)
	for part in _bodies.size():
		var body := _bodies[part]
		var target := clean * Transform3D(Basis.IDENTITY, _rest[part])
		body.global_transform = target
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, target)
		PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
		PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	_yaw = clean.basis.get_euler().y
	face_direction = clean.basis * Vector3.FORWARD
	_ground_y = clean.origin.y
	_grounded = true
	_safe = clean
	_safe_left = 0.5
	if is_stunned:
		# Stood back up while out cold: it goes down full length again rather than crumpling on the spot.
		_begin_fall()
	if _driver and _driver.has_method(&"snap"):
		_driver.call(&"snap")


## Adds stun; the demon collapses when the meter fills.
func add_stun(amount: float) -> void:
	if not is_stunned and amount > 0.0:
		amount *= stun_scale / maxf(max_stun_resistance, 0.1)
		if shock_resist_left > 0.0:
			amount *= SHOCK_RESIST
	stun_meter = clampf(stun_meter + amount, 0.0, 100.0)
	if stun_meter >= 100.0 and not is_stunned:
		_collapse()


## A player did something to it. Awake, the brain answers; out cold, nobody is home.
func provoke(by: Node) -> void:
	if by and not is_stunned:
		provoked.emit(by)


## Current through `body`: every limb convulses for as long as this keeps being called.
func shock(body: RigidBody3D, by: Node = null) -> void:
	if _shock_left <= 0.0:
		_convulse_left = 0.0
	_shock_left = 0.25
	if _convulse_left <= 0.0:
		_convulse_left = 0.05
		for part in range(Part.UPPER_ARM_L, Part.size()):
			var axis := Vector3(randf_range(-1.0, 1.0), randf_range(-0.4, 0.4), randf_range(-1.0, 1.0)).normalized()
			_bodies[part].apply_torque_impulse(_bodies[part].global_transform.basis * axis * _inertia[part] * randf_range(3.5, 8.0))
		if is_instance_valid(body):
			body.apply_central_impulse(Vector3(randf_range(-1.0, 1.0), randf_range(0.0, 0.6), randf_range(-1.0, 1.0)) * body.mass * 0.35)
	var visuals := get_node_or_null("Visuals")
	if visuals and visuals.has_method(&"set_shock"):
		visuals.call(&"set_shock", 1.0)
	provoke(by)


## Instant full stun.
func knock_out() -> void:
	stun_meter = 100.0
	if not is_stunned:
		_collapse()


## Ends the stun: the demon scrambles back to its feet.
func wake() -> void:
	stun_meter = 0.0
	stun_locked = false
	contained = false
	breakout_tension = 0.0
	if not is_stunned:
		return
	is_stunned = false
	shock_resist_left = SHOCK_RESIST_TIME
	_support = 0.0
	_apply_damping()
	_bodies[Part.TORSO].apply_central_impulse(Vector3.UP * PART_MASS[Part.TORSO] * 2.4)
	_bodies[Part.PELVIS].apply_central_impulse(Vector3.UP * PART_MASS[Part.PELVIS] * 2.4)
	_thrash(0.9)
	stun_changed.emit(false)


func set_bind_level(level: int) -> void:
	level = clampi(level, 0, 3)
	if level == bind_level:
		return
	bind_level = level
	bind_changed.emit(bind_level)


## Starts an arm swipe (0 left, 1 right): wind-up, strike, recover.
func swipe(arm: int) -> void:
	_swipe_arm = clampi(arm, 0, 1)
	_swipe_time = 0.0


func is_swiping() -> bool:
	return _swipe_arm >= 0


## Velocity kick to the core, used to shake the body loose when it is stuck.
func nudge(velocity_change: Vector3) -> void:
	for part: int in [Part.PELVIS, Part.TORSO]:
		_bodies[part].apply_central_impulse(velocity_change * PART_MASS[part])


## A two-handed shove from a player. Awake it rocks back on its heels; limp it just slides.
func shove(direction: Vector3, by: Node = null) -> void:
	var push := Vector3(direction.x, 0.0, direction.z).normalized()
	if is_stunned:
		nudge(push * 1.6)
		return
	nudge(push * 2.6 + Vector3.UP * 0.6)
	_reel_left = 0.3
	staggered.emit(by)


## Thrown clear of `from` at `speed` m/s (a second wind, a broken possession grab).
func blast_away(from: Vector3, speed: float, stun: float = 0.0) -> void:
	var away := (get_center() - from) * Vector3(1.0, 0.0, 1.0)
	away = away.normalized() if away.length_squared() > 0.001 else get_facing()
	# The whole body goes, not just its core, and its legs do not get a say for a moment.
	for part in _bodies.size():
		_bodies[part].apply_central_impulse((away * speed + Vector3.UP * 1.6) * PART_MASS[part])
	_reel_left = 0.55
	if stun > 0.0:
		add_stun(stun)
	staggered.emit(null)


## Takes the demon out of the world (it is inside a player) or puts it back. Dormant, it
## has no colliders, casts nothing and drops out of every hand and rope.
func set_dormant(active: bool) -> void:
	if is_dormant == active:
		return
	is_dormant = active
	visible = not active
	for body in _bodies:
		body.collision_layer = 0 if active else GameState.LAYER_DEMON
		body.collision_mask = 0 if active else GameState.LAYER_WORLD | GameState.LAYER_PLAYER | GameState.LAYER_PROP | GameState.LAYER_INTERACT
		if not is_remote:
			body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			body.freeze = active
			body.linear_velocity = Vector3.ZERO
			body.angular_velocity = Vector3.ZERO
	if active:
		breakout_tension = 0.0
		_ropes.clear()


## Turns this ragdoll into a mirror of the host's: frozen bodies that NetSync moves.
func set_remote() -> void:
	is_remote = true
	for body in _bodies:
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.freeze = true
		body.set_meta(&"net_mirror", true)


## A client's copy of the numbers the host owns. Signals fire as they would on the host.
func apply_net(meter: float, stunned: bool, level: int, caged: bool, sealed_in: bool, resisting: bool, dormant: bool) -> void:
	stun_meter = meter
	stun_locked = caged
	contained = sealed_in
	shock_resist_left = 1.0 if resisting else 0.0
	if stunned != is_stunned:
		is_stunned = stunned
		stun_changed.emit(stunned)
	if level != bind_level:
		var before := bind_level
		bind_level = level
		bind_changed.emit(level)
		if level < before and stunned:
			broke_out.emit(before)
	set_dormant(dormant)


# --- Ropes --------------------------------------------------------------------------

## A Holy Lasso has caught this demon, tied it off (`anchored`) or let it go.
func notify_rope(rope: Node, attached: bool, anchored: bool) -> void:
	if attached:
		_ropes[rope] = anchored
	else:
		_ropes.erase(rope)


## True while anybody's rope ties it to an anchor pin: it can be taped where it stands.
func is_anchored() -> bool:
	for rope: Variant in _ropes:
		if is_instance_valid(rope) and _ropes[rope]:
			return true
	return false


## How many of the crew are hauling it right now, by hand or on a rope they hold.
func get_hauler_count() -> int:
	return net_haulers if is_remote else _haulers().size()


func _haulers() -> Array[Node]:
	var crew: Array[Node] = []
	for holder: Variant in _holders:
		if is_instance_valid(holder) and not crew.has(holder):
			crew.append(holder as Node)
	for rope: Variant in _ropes:
		if is_instance_valid(rope) and not _ropes[rope]:
			var holder: Variant = (rope as Node).get(&"player")
			if is_instance_valid(holder) and not crew.has(holder):
				crew.append(holder as Node)
	return crew


# --- Being grabbed ------------------------------------------------------------------

func notify_grab(body: RigidBody3D, by: Node) -> void:
	_holders[by] = body
	_snag_time = 0.0
	_struggle_left = minf(_struggle_left, 0.5)
	grabbed.emit(by, int(body.get_meta(&"demon_part", 0)))


func notify_release(by: Node) -> void:
	if _holders.erase(by):
		# The holder puts back the damping it saw when it grabbed; restore the current one.
		_apply_damping()
		released.emit(by)


func is_dragged() -> bool:
	return not _holders.is_empty()


## How hard a player may pull on `body` right now.
##   mass   effective mass the grab spring should assume
##   force  cap on the pull, in newtons
##   carry  weight that slows the carrier down
func get_grab_tuning(body: RigidBody3D) -> Dictionary:
	if is_stunned:
		# A heavier demon for a bigger crew, and a bonus for every extra pair of hands on it:
		# two people pulling together out-haul two people pulling in turn.
		var teamwork := 1.0 + 0.2 * float(maxi(get_hauler_count() - 1, 0))
		return {
			"mass": body.mass * 3.0,
			"force": DRAG_FORCE[bind_level] / maxf(drag_mass, 0.1) * teamwork,
			"carry": DRAG_CARRY[bind_level] * drag_mass / teamwork,
		}
	# Awake, it simply will not be hauled around.
	return {"mass": body.mass * 0.6, "force": AWAKE_DRAG_FORCE, "carry": 6.0}


## 0..1 from the holder each tick: how far the grip is from where it wants to be.
func report_strain(strain: float) -> void:
	_strain = strain


# --- Construction -------------------------------------------------------------------

func _build_bodies() -> void:
	var rest: Array = _layout["rest"]
	var lengths: Array = _layout["length"]
	var radii: Array = _layout["radius"]
	var hands: Array = _layout["hands"]
	var feet: Array = _layout["feet"]
	_rest.clear()
	for part in Part.size():
		_rest.append(rest[part] as Vector3)
	_pelvis_y = _rest[Part.PELVIS].y
	_hip_y = 0.5 * (((_layout["anchor"] as Array)[Part.UPPER_LEG_L] as Vector3).y + ((_layout["anchor"] as Array)[Part.UPPER_LEG_R] as Vector3).y)
	_upper_leg = 0.5 * (float(lengths[Part.UPPER_LEG_L]) + float(lengths[Part.UPPER_LEG_R]))
	_lower_leg = 0.5 * (float(lengths[Part.LOWER_LEG_L]) + float(lengths[Part.LOWER_LEG_R]))
	_ankle = float(_layout["ankle"])
	_standing_height = float(_layout["height"])
	_height = _pelvis_y * POSE_STANCE[Pose.LURK]

	var surface := PhysicsMaterial.new()
	surface.friction = 0.5
	surface.bounce = 0.0
	for part in Part.size():
		var body := RigidBody3D.new()
		body.name = PART_NAMES[part]
		body.mass = PART_MASS[part]
		body.physics_material_override = surface
		body.collision_layer = GameState.LAYER_DEMON
		body.collision_mask = GameState.LAYER_WORLD | GameState.LAYER_PLAYER | GameState.LAYER_PROP | GameState.LAYER_INTERACT
		body.can_sleep = false
		body.position = _rest[part]
		body.set_meta(&"demon", self)
		body.set_meta(&"demon_part", part)
		body.set_meta(&"demon_label", PART_LABELS[part])
		body.set_meta(&"display_name", "Demon")
		var radius := float(radii[part])
		var length := float(lengths[part])
		var here := _rest[part]
		match part:
			Part.PELVIS:
				_capsule_between(body, Vector3.LEFT * length * 0.5, Vector3.RIGHT * length * 0.5, radius)
			Part.TORSO:
				var chest: Array = _layout["chest"]
				var shoulders: Array = _layout["shoulders"]
				_capsule_between(body, (chest[0] as Vector3) - here, (chest[1] as Vector3) - here, radius)
				_capsule_between(body, (shoulders[0] as Vector3) - here, (shoulders[1] as Vector3) - here, float(_layout["shoulder_radius"]))
			Part.HEAD:
				_sphere(body, radius, Vector3.ZERO)
			Part.UPPER_ARM_L, Part.UPPER_ARM_R, Part.UPPER_LEG_L, Part.UPPER_LEG_R:
				_capsule_between(body, Vector3.UP * (length * 0.5 - radius), Vector3.DOWN * (length * 0.5 - radius), radius)
			Part.LOWER_ARM_L, Part.LOWER_ARM_R:
				var hand: Dictionary = hands[0 if part == Part.LOWER_ARM_L else 1]
				_capsule_between(body, Vector3.UP * (length * 0.5 - radius), Vector3.DOWN * (length * 0.5 - radius), radius)
				_sphere(body, float(hand["palm_radius"]), (hand["palm"] as Vector3) - here)
				_sphere(body, float(hand["claw_radius"]), (hand["claws"] as Vector3) - here)
			Part.LOWER_LEG_L, Part.LOWER_LEG_R:
				var foot: Dictionary = feet[0 if part == Part.LOWER_LEG_L else 1]
				_capsule_between(body, Vector3.UP * (length * 0.5 - radius), Vector3.DOWN * (length * 0.5 - radius), radius)
				_sphere(body, float(foot["heel_radius"]), (foot["heel"] as Vector3) - here)
				_sphere(body, float(foot["toe_radius"]), (foot["toe"] as Vector3) - here)
		# Thin limbs have almost no inertia around their own axis, which is where
		# ragdolls start to buzz. A padded, isotropic inertia keeps them calm and
		# lets every pose drive use one known value.
		var inertia := maxf(0.1, PART_MASS[part] * length * length / 12.0 * 1.6)
		body.inertia = Vector3.ONE * inertia
		_inertia.append(inertia)
		# The core must never tunnel through a wall or the van floor.
		body.continuous_cd = part == Part.PELVIS or part == Part.TORSO
		if part <= Part.HEAD:
			body.contact_monitor = true
			body.max_contacts_reported = 3
			body.body_entered.connect(_on_core_contact)
		add_child(body)
		_bodies.append(body)
		_total_mass += PART_MASS[part]
	_apply_damping()


## Capsule whose round ends are centred on two points in the body's own space.
func _capsule_between(body: RigidBody3D, from: Vector3, to: Vector3, radius: float) -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = from.distance_to(to) + radius * 2.0
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = (from + to) * 0.5
	if from.distance_squared_to(to) > 0.000001:
		collider.basis = Basis(Quaternion(Vector3.UP, (to - from).normalized()))
	body.add_child(collider)


func _sphere(body: RigidBody3D, radius: float, at: Vector3) -> void:
	var shape := SphereShape3D.new()
	shape.radius = radius
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = at
	body.add_child(collider)


## Proportions used when the skinned model is missing, in the same form the driver returns.
func _fallback_layout() -> Dictionary:
	var shoulder := Vector3(0.22, 1.77, 0.0)
	var hip := Vector3(0.11, 1.08, 0.0)
	var upper_arm := 0.56
	var lower_arm := 0.58
	var upper_leg := 0.52
	var lower_leg := 0.50
	var rest: Array = [Vector3(0.0, 1.12, 0.0), Vector3(0.0, 1.53, 0.0), Vector3(0.0, 2.0, -0.02)]
	var anchor: Array = [Vector3(0.0, 1.12, 0.0), Vector3(0.0, 1.22, 0.0), Vector3(0.0, 1.86, 0.0)]
	var hands: Array = []
	var feet: Array = []
	for side: float in [-1.0, 1.0]:
		var top := Vector3(side * shoulder.x, shoulder.y, 0.0)
		rest.append(top + Vector3.DOWN * upper_arm * 0.5)
		rest.append(top + Vector3.DOWN * (upper_arm + lower_arm * 0.5))
		anchor.append(top)
		anchor.append(top + Vector3.DOWN * upper_arm)
		var wrist := top + Vector3.DOWN * (upper_arm + lower_arm)
		hands.append({"palm": wrist + Vector3.DOWN * 0.1, "palm_radius": 0.07, "claws": wrist + Vector3.DOWN * 0.2, "claw_radius": 0.04})
	for side: float in [-1.0, 1.0]:
		var top := Vector3(side * hip.x, hip.y, 0.0)
		rest.append(top + Vector3.DOWN * upper_leg * 0.5)
		rest.append(top + Vector3.DOWN * (upper_leg + lower_leg * 0.5))
		anchor.append(top)
		anchor.append(top + Vector3.DOWN * upper_leg)
		feet.append({"heel": Vector3(top.x, 0.09, 0.0), "heel_radius": 0.06, "toe": Vector3(top.x, 0.07, -0.12), "toe_radius": 0.045})
	return {
		"rest": rest,
		"anchor": anchor,
		"length": [0.22, 0.64, 0.3, upper_arm, lower_arm, upper_arm, lower_arm, upper_leg, lower_leg, upper_leg, lower_leg],
		"radius": [0.12, 0.15, 0.135, 0.05, 0.045, 0.05, 0.045, 0.065, 0.05, 0.065, 0.05],
		"chest": [Vector3(0.0, 1.22, 0.0), Vector3(0.0, 1.86, 0.0)],
		"shoulders": [Vector3(-shoulder.x, shoulder.y, 0.0), Vector3(shoulder.x, shoulder.y, 0.0)],
		"shoulder_radius": 0.09,
		"hands": hands,
		"feet": feet,
		"ankle": 0.07,
		"height": 2.15,
	}


func _build_joints() -> void:
	var anchor: Array = _layout["anchor"]
	# Limits are [min, max] per axis for the child's rotation relative to its
	# parent: X pitches a hanging limb forward, Z lifts a right limb out sideways.
	_joint(Part.TORSO, anchor[Part.TORSO], Vector2(-0.9, 0.35), Vector2(-0.6, 0.6), Vector2(-0.35, 0.35))
	_joint(Part.HEAD, anchor[Part.HEAD], Vector2(-0.7, 0.6), Vector2(-1.1, 1.1), Vector2(-0.45, 0.45))
	for i in 2:
		var out := Vector2(-0.25, 1.7) if i == 1 else Vector2(-1.7, 0.25)
		var upper_arm: int = Part.UPPER_ARM_L if i == 0 else Part.UPPER_ARM_R
		var lower_arm: int = Part.LOWER_ARM_L if i == 0 else Part.LOWER_ARM_R
		_joint(upper_arm, anchor[upper_arm], Vector2(-1.0, 2.9), Vector2(-0.7, 0.7), out)
		_joint(lower_arm, anchor[lower_arm], Vector2(0.0, 2.5), Vector2(-0.25, 0.25), Vector2(-0.05, 0.05))
		var splay := Vector2(-0.15, 0.7) if i == 1 else Vector2(-0.7, 0.15)
		var upper_leg: int = Part.UPPER_LEG_L if i == 0 else Part.UPPER_LEG_R
		var lower_leg: int = Part.LOWER_LEG_L if i == 0 else Part.LOWER_LEG_R
		_joint(upper_leg, anchor[upper_leg], Vector2(-0.6, 1.9), Vector2(-0.4, 0.4), splay)
		_joint(lower_leg, anchor[lower_leg], Vector2(-2.4, 0.0), Vector2(-0.1, 0.1), Vector2(-0.05, 0.05))


func _joint(child: int, anchor: Vector3, x: Vector2, y: Vector2, z: Vector2) -> void:
	var joint := Generic6DOFJoint3D.new()
	joint.name = "%sJoint" % PART_NAMES[child]
	joint.position = anchor
	add_child(joint)
	# Godot measures these angles the other way round from the child's rotation,
	# so a child range of [min, max] is entered as lower = -max, upper = -min.
	joint.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, -x.y)
	joint.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, -x.x)
	joint.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, -y.y)
	joint.set_param_y(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, -y.x)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, -z.y)
	joint.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, -z.x)
	joint.node_a = joint.get_path_to(_bodies[PART_PARENT[child]])
	joint.node_b = joint.get_path_to(_bodies[child])
	_joints.append(joint)


func _apply_damping() -> void:
	for body in _bodies:
		body.linear_damp = 0.3 if is_stunned else 0.1
		body.angular_damp = 2.2 if is_stunned else 1.2


# --- Simulation ---------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _bodies.is_empty() or is_remote or is_dormant:
		return
	_time += delta
	shock_resist_left = maxf(0.0, shock_resist_left - delta)
	_reel_left = maxf(0.0, _reel_left - delta)
	_thud_left = maxf(0.0, _thud_left - delta)
	_shock_left = maxf(0.0, _shock_left - delta)
	_convulse_left -= delta
	if is_stunned and not stun_locked:
		stun_meter = maxf(0.0, stun_meter - STUN_DECAY[bind_level] * delta)
		if stun_meter <= 0.0:
			wake()
	elif not is_stunned and _shock_left <= 0.0 and stun_meter > 0.0:
		stun_meter = maxf(0.0, stun_meter - STUN_BLEED * delta)
	if is_stunned:
		_tick_limp(delta)
	else:
		_tick_active(delta)
	_tick_safety(delta)


func _tick_active(delta: float) -> void:
	var pelvis := _bodies[Part.PELVIS]
	var torso := _bodies[Part.TORSO]
	_support = move_toward(_support, 1.0, delta / RISE_TIME)
	_probe_headroom(delta)
	_height = lerpf(_height, _pelvis_y * (POSE_STANCE[pose] - DUCK_STANCE * _duck), minf(1.0, delta * 4.0))
	_hunch = lerpf(_hunch, POSE_HUNCH[pose] + DUCK_HUNCH * _duck, minf(1.0, delta * 4.0))
	_probe_ground(delta)
	_roll_twitches(delta)

	if face_direction.length_squared() > 0.01:
		_yaw = lerp_angle(_yaw, atan2(-face_direction.x, -face_direction.z), minf(1.0, delta * turn_rate))
	var planar := Vector3(pelvis.linear_velocity.x, 0.0, pelvis.linear_velocity.z)
	var speed := planar.length()
	var stride := clampf(speed / 3.2, 0.0, 1.0)
	if speed > 0.25:
		_gait += delta * (2.2 + speed * 2.6)

	if _grounded:
		# Hover spring: carries the whole body at the pose's hip height.
		var bob := sin(_gait * 2.0) * 0.03 * stride + sin(_time * 1.3) * 0.012
		var error := _ground_y + _height + bob - pelvis.global_position.y
		var rise := clampf(error * HOVER_STIFFNESS - pelvis.linear_velocity.y * HOVER_DAMPING, -8.0, 26.0)
		var lift := _total_mass * (rise + _gravity) * _support
		if lift > 0.0:
			pelvis.apply_central_force(Vector3.UP * lift * 0.55)
			torso.apply_central_force(Vector3.UP * lift * 0.45)
		# Locomotion: the full body mass is behind it, so clutter in the way gets kicked aside.
		var wish := Vector3(move_direction.x, 0.0, move_direction.z).limit_length(1.0) * move_speed
		var push := ((wish - planar) * MOVE_RESPONSE).limit_length(MAX_MOVE_ACCELERATION) * _total_mass * _support
		if _reel_left > 0.0:
			push = Vector3.ZERO
		pelvis.apply_central_force(push * 0.55)
		torso.apply_central_force(push * 0.45)

	# Swipes wind the whole torso up and through.
	var twist := 0.0
	if _swipe_arm >= 0:
		_swipe_time += delta
		var away := -1.0 if _swipe_arm == 0 else 1.0
		twist = away * (-0.55 if _swipe_time < 0.2 else 0.65)
		if _swipe_time > 0.62:
			_swipe_arm = -1

	var frame := Basis(Vector3.UP, _yaw)
	var lean := Basis(Vector3.RIGHT, -_hunch) * Basis(Vector3.BACK, sin(_gait) * 0.07 * stride + _jitter[0] * 0.05)
	_steer(torso, Basis(Vector3.UP, _yaw + twist) * lean, Part.TORSO, 9.0, 0.9, 2.6 * _support, 900.0)
	torso.apply_torque(torso.global_transform.basis.y.cross(Vector3.UP) * CHEST_LIFT * _support)
	_steer(pelvis, frame * Basis(Vector3.RIGHT, -_hunch * 0.3), Part.PELVIS, 9.0, 0.9, 2.2 * _support, 600.0)
	_drive_legs(frame, stride)
	_drive_arms(torso.global_transform.basis.orthonormalized(), stride)
	_drive_head(torso.global_transform.basis.orthonormalized())


## Folds the legs to fit the gap between hips and floor, then swings them with the gait.
func _drive_legs(frame: Basis, stride: float) -> void:
	var hip_height := _bodies[Part.PELVIS].global_position.y - (_pelvis_y - _hip_y) - _ground_y - _ankle
	var fold := acos(clampf(hip_height / (_upper_leg + _lower_leg), 0.36, 1.0))
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var phase := _gait + (0.0 if i == 0 else PI)
		var swing := sin(phase) * 0.55 * stride
		var lift := maxf(0.0, cos(phase)) * 0.7 * stride
		var upper := frame * Basis(Vector3.BACK, side * 0.07) * Basis(Vector3.RIGHT, fold + swing)
		var lower := upper * Basis(Vector3.RIGHT, maxf(-2.3, -2.0 * fold - lift))
		var upper_part: int = Part.UPPER_LEG_L if i == 0 else Part.UPPER_LEG_R
		var lower_part: int = Part.LOWER_LEG_L if i == 0 else Part.LOWER_LEG_R
		_steer(_bodies[upper_part], upper, upper_part, 11.0, 0.9, 1.6 * _support, 160.0)
		_steer(_bodies[lower_part], lower, lower_part, 11.0, 0.9, 1.6 * _support, 120.0)


func _drive_arms(chest: Basis, stride: float) -> void:
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var offset := float(i) * 1.9
		# pitch swings the arm forward from hanging, spread opens it away from the body,
		# elbow folds the forearm up. The shoulders sit well back on the hunched frame,
		# so the arms are carried forward of the chest instead of out to the sides.
		var pitch := 0.45
		var spread := 0.3
		var elbow := 0.5
		var response := 9.0
		var gain := 1.4
		match pose:
			Pose.LURK:
				# Long arms hanging ahead of the knees, breathing slowly.
				pitch = 0.5 + sin(_time * 1.1 + offset) * 0.05 + _jitter[i] * 0.1
				spread = 0.26 + sin(_time * 0.7 + offset) * 0.04
				elbow = 0.55 + sin(_time * 0.9 + offset) * 0.07
			Pose.STALK:
				# Reaching hungrily ahead, elbows low, with small involuntary twitches.
				pitch = 1.05 + sin(_time * 1.3 + offset) * 0.14 + _jitter[i] * 0.3
				spread = 0.32 + sin(_time * 0.8 + offset) * 0.07
				elbow = 0.75 + sin(_time * 2.1 + offset) * 0.18 + _jitter[1 - i] * 0.22
			Pose.CHASE:
				# Both arms thrown forward, clawing alternately out of step with the legs.
				pitch = 1.3 + sin(_gait + (PI if i == 0 else 0.0)) * (0.4 + 0.45 * stride) + _jitter[i] * 0.4
				spread = 0.36 + sin(_time * 5.3 + offset) * 0.2
				elbow = 0.7 + sin(_gait * 1.7 + offset) * 0.5
				response = 11.0
			Pose.CAST:
				# Both arms thrown up and wide, trembling.
				pitch = 2.5 + sin(_time * 31.0 + offset) * 0.05
				spread = 0.75
				elbow = 0.5 + sin(_time * 27.0 + offset) * 0.06
				response = 13.0
			Pose.FREEZE:
				# Shielding its eyes from the torch beam.
				pitch = 2.0 + _jitter[i] * 0.3
				spread = 0.05
				elbow = 1.7 + _jitter[1 - i] * 0.3
				response = 14.0
		if i == _swipe_arm:
			response = 18.0
			gain = 3.0
			if _swipe_time < 0.2:
				# Wound back over the shoulder.
				pitch = 2.6
				spread = 0.9
				elbow = 1.3
			elif _swipe_time < 0.44:
				# Raked down and across the body.
				pitch = 1.25
				spread = -0.35
				elbow = 0.2
		var upper := chest * Basis(Vector3.BACK, side * spread) * Basis(Vector3.RIGHT, pitch)
		var lower := upper * Basis(Vector3.RIGHT, elbow)
		var upper_part: int = Part.UPPER_ARM_L if i == 0 else Part.UPPER_ARM_R
		var lower_part: int = Part.LOWER_ARM_L if i == 0 else Part.LOWER_ARM_R
		_steer(_bodies[upper_part], upper, upper_part, response, 0.85, gain * _support, 220.0)
		_steer(_bodies[lower_part], lower, lower_part, response, 0.85, gain * _support, 160.0)


func _drive_head(chest: Basis) -> void:
	var head := _bodies[Part.HEAD]
	# Lift the chin back out of the hunch so the face points ahead by default.
	var target := chest * Basis(Vector3.RIGHT, _hunch * 0.85)
	if has_look_target:
		var to := look_target - head.global_position
		if to.length_squared() > 0.04:
			var direction := to.normalized()
			if absf(direction.y) < 0.97:
				target = Basis.looking_at(direction, Vector3.UP)
	_steer(head, target * Basis(Vector3.BACK, _head_tilt), Part.HEAD, 12.0, 0.9, 2.0 * _support, 60.0)


## PD torque toward a world-space orientation, sized by the segment's inertia so
## the same frequency / damping ratio is stable on every part.
func _steer(body: RigidBody3D, target: Basis, part: int, frequency: float, damping_ratio: float, gain: float, max_torque: float) -> void:
	if gain <= 0.0:
		return
	var current := body.global_transform.basis.orthonormalized()
	var offset := (target.orthonormalized() * current.inverse()).get_rotation_quaternion()
	if offset.w < 0.0:
		offset = -offset
	var axis := Vector3(offset.x, offset.y, offset.z)
	var sine := axis.length()
	var error := Vector3.ZERO
	if sine > 0.0001:
		error = axis / sine * (2.0 * atan2(sine, offset.w))
	var acceleration := error * frequency * frequency - body.angular_velocity * (2.0 * damping_ratio * frequency)
	body.apply_torque((acceleration * _inertia[part] * gain).limit_length(max_torque))


## Floor height under the hips, both feet and a step ahead; the highest one wins,
## which is what lets the hover climb stairs and thresholds.
func _probe_ground(delta: float) -> void:
	var space := get_world_3d().direct_space_state
	var hips := _bodies[Part.PELVIS].global_position
	var ahead := Vector3(_bodies[Part.PELVIS].linear_velocity.x, 0.0, _bodies[Part.PELVIS].linear_velocity.z).limit_length(2.0) * 0.22
	var probes: Array[Vector3] = [hips, hips + ahead, _bodies[Part.LOWER_LEG_L].global_position, _bodies[Part.LOWER_LEG_R].global_position]
	var best := -INF
	for probe in probes:
		var from := Vector3(probe.x, hips.y + 0.25, probe.z)
		var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 2.4, GameState.LAYER_WORLD)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			best = maxf(best, (hit["position"] as Vector3).y)
	if best > -INF and hips.y - best < _height + 0.8:
		_ground_y = best if not _grounded else lerpf(_ground_y, best, minf(1.0, delta * 12.0))
		_grounded = true
	else:
		_grounded = false


## Looks for a lintel or low ceiling over the horns (and just ahead when moving) and stoops under it.
func _probe_headroom(delta: float) -> void:
	_duck_left -= delta
	if _duck_left <= 0.0:
		_duck_left = 0.1
		var space := get_world_3d().direct_space_state
		var hips := _bodies[Part.PELVIS].global_position
		var floor_y := _ground_y if _grounded else hips.y - _height
		var crown := floor_y + _standing_height
		var ahead := Vector3(_bodies[Part.PELVIS].linear_velocity.x, 0.0, _bodies[Part.PELVIS].linear_velocity.z).limit_length(1.0) * 0.9
		var low := false
		for probe: Vector3 in [hips, hips + ahead, _bodies[Part.HEAD].global_position]:
			var from := Vector3(probe.x, hips.y, probe.z)
			var query := PhysicsRayQueryParameters3D.create(from, Vector3(probe.x, crown + 0.35, probe.z), GameState.LAYER_WORLD)
			if not space.intersect_ray(query).is_empty():
				low = true
				break
		_duck = 1.0 if low else 0.0


## Sample-and-hold noise for the involuntary jerks of arms and head.
func _roll_twitches(delta: float) -> void:
	var busy := pose == Pose.CHASE or pose == Pose.FREEZE
	_jitter_left -= delta
	if _jitter_left <= 0.0:
		_jitter_left = randf_range(0.05, 0.16) if busy else randf_range(0.25, 1.4)
		for i in 2:
			# Mostly still, occasionally a sharp jerk.
			_jitter[i] = randf_range(-1.0, 1.0) if randf() < (0.8 if busy else 0.35) else 0.0
	_tilt_left -= delta
	if _tilt_left <= 0.0:
		_tilt_left = randf_range(0.15, 0.5) if busy else randf_range(0.8, 2.6)
		_head_tilt = randf_range(-0.42, 0.42)


func _tick_limp(delta: float) -> void:
	_support = 0.0
	_swipe_arm = -1
	_grounded = false
	var dragged := is_dragged()
	if _fall_left > 0.0:
		_fall_left -= delta
		# A hand on it ends the fall: from then on the body belongs to whoever is hauling it.
		if dragged:
			_fall_left = 0.0
		else:
			_topple(clampf(_fall_left / FALL_TIME, 0.0, 1.0))
	if bind_level > 0:
		_bind_drive()
	_tick_breakout(delta, dragged)
	_struggle_left -= delta
	if _struggle_left <= 0.0 and not contained:
		var strength := STRUGGLE[bind_level] * struggle_force * (1.0 if dragged else 0.25)
		_struggle_left = randf_range(0.7, 1.5) * (1.0 + bind_level * 0.35) * (1.0 if dragged else 2.4)
		_thrash(strength)
		struggled.emit(strength)
	# A body wedged in a doorway or on the ramp lip pops loose instead of staying stuck.
	if dragged and _strain > 0.72:
		_snag_time += delta
		if _snag_time > 1.1:
			_snag_time = 0.0
			var toward := (_holder_position() - get_center()) * Vector3(1.0, 0.0, 1.0)
			var hop := Vector3.UP * 1.9 + toward.limit_length(1.0) * 1.1
			for part in _bodies.size():
				_bodies[part].apply_central_impulse(hop * PART_MASS[part])
	else:
		_snag_time = maxf(0.0, _snag_time - delta * 2.0)


## Hauled about with no tape on it, or only a wrap or two, it works itself loose: tension
## builds unseen while anyone drags it, and when it tops out the demon rips a layer of tape
## off (if it has one), throws whoever had hold of it backwards and loses a chunk of its
## stun. Two wraps hold far longer; three hold for good. Left alone, the tension eases.
func _tick_breakout(delta: float, dragged: bool) -> void:
	var hauled := dragged or not _haulers().is_empty()
	if not hauled or contained or stun_locked or bind_level >= 3:
		breakout_tension = maxf(0.0, breakout_tension - delta * 0.12)
		return
	breakout_tension += delta / BREAKOUT_TIME[bind_level] * struggle_force
	if breakout_tension >= 1.0:
		_break_out()


func _break_out() -> void:
	var before := bind_level
	breakout_tension = 0.0
	breakouts += 1
	var crew := _haulers()
	var centre := get_center()
	if bind_level > 0:
		set_bind_level(bind_level - 1)
	stun_meter = maxf(1.0, stun_meter - BREAKOUT_STUN_COST)
	_thrash(1.7)
	for rope: Variant in _ropes.keys():
		if is_instance_valid(rope) and not _ropes[rope]:
			(rope as Node).call(&"release_demon", self)
	for hauler in crew:
		var away := ((hauler as Node3D).global_position - centre) * Vector3(1.0, 0.0, 1.0)
		away = away.normalized() if away.length_squared() > 0.001 else Vector3.BACK
		if hauler.has_method(&"drop_held"):
			hauler.call(&"drop_held")
		if hauler.has_method(&"shoved"):
			hauler.call(&"shoved", away * 6.0 + Vector3.UP * 2.6)
	broke_out.emit(before)


## Tape does what tape does: wrapped arms stay by the ribs and (from the second wrap)
## wrapped legs stay together, firmer with every level, so a bound demon drags like a
## parcel instead of a spilled bag and the bands on its skin stay where they were put.
func _bind_drive() -> void:
	var hold := BIND_HOLD[bind_level]
	var chest := _bodies[Part.TORSO].global_transform.basis
	var hips := _bodies[Part.PELVIS].global_transform.basis
	for i in 2:
		var upper_arm: int = Part.UPPER_ARM_L if i == 0 else Part.UPPER_ARM_R
		_steer(_bodies[upper_arm], chest, upper_arm, 6.0, 1.0, hold, 70.0)
		if bind_level < 2:
			continue
		var lower_arm: int = Part.LOWER_ARM_L if i == 0 else Part.LOWER_ARM_R
		var upper_leg: int = Part.UPPER_LEG_L if i == 0 else Part.UPPER_LEG_R
		var lower_leg: int = Part.LOWER_LEG_L if i == 0 else Part.LOWER_LEG_R
		# Forearms folded up across the belly.
		_steer(_bodies[lower_arm], _bodies[upper_arm].global_transform.basis * Basis(Vector3.RIGHT, 0.6), lower_arm, 6.0, 1.0, hold, 50.0)
		_steer(_bodies[upper_leg], hips, upper_leg, 6.0, 1.0, hold, 110.0)
		_steer(_bodies[lower_leg], _bodies[upper_leg].global_transform.basis, lower_leg, 6.0, 1.0, hold, 80.0)


## One burst of flailing: kicked legs, thrown arms and a sideways tug on the core.
func _thrash(strength: float) -> void:
	if strength <= 0.0:
		return
	for part in range(Part.UPPER_ARM_L, Part.size()):
		var axis := Vector3(randf_range(-1.0, 1.0), randf_range(-0.3, 0.3), randf_range(-0.6, 0.6)).normalized()
		var body := _bodies[part]
		body.apply_torque_impulse(body.global_transform.basis * axis * _inertia[part] * randf_range(7.0, 13.0) * strength)
	var tug := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	if is_dragged():
		# Yank across the direction it is being hauled in.
		var haul := (_holder_position() - get_center()) * Vector3(1.0, 0.0, 1.0)
		if haul.length_squared() > 0.01:
			tug = haul.normalized().cross(Vector3.UP) * (-1.0 if randf() < 0.5 else 1.0)
	tug = (tug.normalized() + Vector3.UP * 0.3) if tug.length_squared() > 0.001 else Vector3.UP
	_bodies[Part.PELVIS].apply_central_impulse(tug * PART_MASS[Part.PELVIS] * 2.4 * strength)
	_bodies[Part.TORSO].apply_central_impulse(tug.rotated(Vector3.UP, randf_range(-0.8, 0.8)) * PART_MASS[Part.TORSO] * 1.6 * strength)


func _holder_position() -> Vector3:
	for holder: Variant in _holders:
		if is_instance_valid(holder) and holder is Node3D:
			return (holder as Node3D).global_position
	return get_center()


func _collapse() -> void:
	is_stunned = true
	breakout_tension = 0.0
	_support = 0.0
	_struggle_left = randf_range(0.8, 1.4)
	_apply_damping()
	_begin_fall()
	stun_changed.emit(true)


## Starts the felled-tree fall (see `_topple`). Always the way it faces: its weight hangs
## forward of its hips, so any other way it only sits down and folds over its own legs.
func _begin_fall() -> void:
	_fall_left = FALL_TIME
	_fall_direction = get_facing()
	# A shove off balance so it pitches over instead of sinking straight down.
	_bodies[Part.TORSO].apply_central_impulse(_fall_direction * PART_MASS[Part.TORSO] * 1.1)


## The first moments of a collapse: hips, spine and knees keep some of their line while
## the chest is tipped over sliding feet, so the demon goes down like a felled
## tree and measures its whole length on the floor instead of folding into a heap.
## `weight` fades 1 -> 0 over FALL_TIME; after that the body is dead weight.
func _topple(weight: float) -> void:
	var pelvis := _bodies[Part.PELVIS]
	var torso := _bodies[Part.TORSO]
	_steer(pelvis, torso.global_transform.basis, Part.PELVIS, 8.0, 1.0, 1.4 * weight, 500.0)
	var hips := pelvis.global_transform.basis
	var tip := _fall_direction * _total_mass * FALL_TIP * weight
	torso.apply_central_force(tip)
	for i in 2:
		var upper: int = Part.UPPER_LEG_L if i == 0 else Part.UPPER_LEG_R
		var lower: int = Part.LOWER_LEG_L if i == 0 else Part.LOWER_LEG_R
		_steer(_bodies[upper], hips, upper, 8.0, 1.0, 1.2 * weight, 160.0)
		_steer(_bodies[lower], _bodies[upper].global_transform.basis, lower, 8.0, 1.0, 0.7 * weight, 100.0)
		# Equal and opposite to the push on the chest: it lays the body out without sliding it away.
		_bodies[lower].apply_central_force(tip * -0.5)
		# The arms are flung out ahead of the fall rather than trapped under the ribs.
		var wrist: int = Part.LOWER_ARM_L if i == 0 else Part.LOWER_ARM_R
		var fling := (_fall_direction + Vector3.UP * 0.25) * PART_MASS[wrist] * FALL_FLING * weight
		_bodies[wrist].apply_central_force(fling)
		pelvis.apply_central_force(-fling)


## Last line of defence: velocities are capped every tick, and a body that still
## goes non-finite, falls out of the world or stretches a joint is rebuilt in
## its last good spot. `fault_count` records every time that happens.
func _tick_safety(delta: float) -> void:
	var hips := _bodies[Part.PELVIS].global_position
	var broken := not hips.is_finite() or hips.y < -30.0
	if not broken:
		for body in _bodies:
			var at := body.global_position
			var velocity := body.linear_velocity
			var spin := body.angular_velocity
			if not (at.is_finite() and velocity.is_finite() and spin.is_finite()) or at.distance_to(hips) > _standing_height * MAX_STRETCH_RATIO:
				broken = true
				break
			var speed := velocity.length()
			peak_speed = maxf(peak_speed, speed)
			if speed > MAX_SPEED:
				body.linear_velocity = velocity * (MAX_SPEED / speed)
			if spin.length() > MAX_SPIN:
				body.angular_velocity = spin.limit_length(MAX_SPIN)
	if broken:
		fault_count += 1
		push_warning("DemonRagdoll: ragdoll rebuilt by the safety net (%d)" % fault_count)
		place(_safe)
		return
	_core_speed = _bodies[Part.TORSO].linear_velocity.length()
	_safe_left -= delta
	if _safe_left <= 0.0:
		_safe_left = 0.5
		var floor_y := _ground_y if _grounded else hips.y - 0.2
		_safe = Transform3D(Basis(Vector3.UP, _yaw), Vector3(hips.x, floor_y, hips.z))


func _on_core_contact(_other: Node) -> void:
	if _thud_left > 0.0 or _core_speed < 2.2:
		return
	_thud_left = 0.3
	impacted.emit(_core_speed)
