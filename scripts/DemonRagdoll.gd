extends Node3D
## Active-ragdoll body of the demon.
##
## Eleven RigidBody3D segments joined by Generic6DOFJoint3D with anatomical
## angular limits. All segments sit on the `demon_limbs` physics layer and none
## of them masks it, so limbs can never collide with (or explode against) each
## other, while still hitting the world, props, doors and the player.
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

enum Part { PELVIS, TORSO, HEAD, UPPER_ARM_L, LOWER_ARM_L, UPPER_ARM_R, LOWER_ARM_R, UPPER_LEG_L, LOWER_LEG_L, UPPER_LEG_R, LOWER_LEG_R }
enum Pose { LURK, STALK, CHASE, CAST, FREEZE }

const PART_NAMES: Array[String] = ["Pelvis", "Torso", "Head", "UpperArmL", "LowerArmL", "UpperArmR", "LowerArmR", "UpperLegL", "LowerLegL", "UpperLegR", "LowerLegR"]
## What the crosshair prompt calls each segment.
const PART_LABELS: Array[String] = ["HIPS", "TORSO", "HEAD", "ARM", "WRIST", "ARM", "WRIST", "LEG", "ANKLE", "LEG", "ANKLE"]
const PART_MASS: Array[float] = [10.0, 16.0, 4.0, 3.0, 2.6, 3.0, 2.6, 3.5, 3.0, 3.5, 3.0]
const PART_PARENT: Array[int] = [-1, Part.PELVIS, Part.TORSO, Part.TORSO, Part.UPPER_ARM_L, Part.TORSO, Part.UPPER_ARM_R, Part.PELVIS, Part.UPPER_LEG_L, Part.PELVIS, Part.UPPER_LEG_R]

# Rest pose, in metres above the soles (the demon faces -Z, +X is its right).
const PELVIS_Y := 1.12
const WAIST_Y := 1.22
const TORSO_Y := 1.53
const NECK_Y := 1.86
const HEAD_Y := 2.0
const SHOULDER_X := 0.22
const SHOULDER_Y := 1.77
const UPPER_ARM := 0.56
const LOWER_ARM := 0.58
const HIP_X := 0.11
const HIP_Y := 1.08
const UPPER_LEG := 0.52
const LOWER_LEG := 0.50
const FOOT_CLEARANCE := 0.07

# Pelvis height and forward lean for each Pose.
const POSE_HEIGHT: Array[float] = [0.80, 0.94, 1.03, 1.10, 0.86]
const POSE_HUNCH: Array[float] = [0.72, 0.52, 0.34, -0.12, 0.6]
## N*m at 90 degrees of lean: cancels most of the droop from the head and arms hanging off the chest.
const CHEST_LIFT := 60.0

const HOVER_STIFFNESS := 60.0
const HOVER_DAMPING := 12.0
const MOVE_RESPONSE := 7.0
const MAX_MOVE_ACCELERATION := 16.0
const RISE_TIME := 0.6
const MAX_SPEED := 22.0
const MAX_SPIN := 30.0
const MAX_STRETCH := 2.6

## Stun points lost per second at bind level 0..3.
const STUN_DECAY: Array[float] = [2.5, 2.0, 1.5, 1.0]
## Struggle strength at bind level 0..3.
const STRUGGLE: Array[float] = [1.0, 0.6, 0.3, 0.1]
const DRAG_FORCE_BASE := 540.0
const DRAG_FORCE_PER_BIND := 120.0
const AWAKE_DRAG_FORCE := 70.0

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
## Times the safety net had to rebuild the ragdoll (NaN, runaway speed, stretched joint). Should stay 0.
var fault_count := 0
var peak_speed := 0.0

var _bodies: Array[RigidBody3D] = []
var _joints: Array[Generic6DOFJoint3D] = []
var _rest: Array[Vector3] = []
var _inertia: Array[float] = []
var _total_mass := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

var _time := 0.0
var _yaw := 0.0
var _height := 0.8
var _hunch := 0.6
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
var _safe := Transform3D.IDENTITY
var _safe_left := 0.0
var _core_speed := 0.0
var _thud_left := 0.0


func _ready() -> void:
	add_to_group(GameState.GROUP_DEMON)
	var spawn := global_transform
	global_transform = Transform3D.IDENTITY
	_build_bodies()
	_build_joints()
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


## Adds stun; the demon collapses when the meter fills.
func add_stun(amount: float) -> void:
	stun_meter = clampf(stun_meter + amount, 0.0, 100.0)
	if stun_meter >= 100.0 and not is_stunned:
		_collapse()


## Instant full stun.
func knock_out() -> void:
	stun_meter = 100.0
	if not is_stunned:
		_collapse()


## Ends the stun: the demon scrambles back to its feet.
func wake() -> void:
	stun_meter = 0.0
	stun_locked = false
	if not is_stunned:
		return
	is_stunned = false
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
		return {
			"mass": body.mass * 3.0,
			"force": DRAG_FORCE_BASE + DRAG_FORCE_PER_BIND * bind_level,
			"carry": 44.0 - 9.0 * bind_level,
		}
	# Awake, it simply will not be hauled around.
	return {"mass": body.mass * 0.6, "force": AWAKE_DRAG_FORCE, "carry": 6.0}


## 0..1 from the holder each tick: how far the grip is from where it wants to be.
func report_strain(strain: float) -> void:
	_strain = strain


# --- Construction -------------------------------------------------------------------

func _build_bodies() -> void:
	_rest = [
		Vector3(0.0, PELVIS_Y, 0.0),
		Vector3(0.0, TORSO_Y, 0.0),
		Vector3(0.0, HEAD_Y, -0.02),
		Vector3(-SHOULDER_X, SHOULDER_Y - UPPER_ARM * 0.5, 0.0),
		Vector3(-SHOULDER_X, SHOULDER_Y - UPPER_ARM - LOWER_ARM * 0.5, 0.0),
		Vector3(SHOULDER_X, SHOULDER_Y - UPPER_ARM * 0.5, 0.0),
		Vector3(SHOULDER_X, SHOULDER_Y - UPPER_ARM - LOWER_ARM * 0.5, 0.0),
		Vector3(-HIP_X, HIP_Y - UPPER_LEG * 0.5, 0.0),
		Vector3(-HIP_X, HIP_Y - UPPER_LEG - LOWER_LEG * 0.5, 0.0),
		Vector3(HIP_X, HIP_Y - UPPER_LEG * 0.5, 0.0),
		Vector3(HIP_X, HIP_Y - UPPER_LEG - LOWER_LEG * 0.5, 0.0),
	]
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
		var length := 0.3
		match part:
			Part.PELVIS:
				_capsule(body, 0.12, 0.36, Vector3.ZERO, true)
				length = 0.36
			Part.TORSO:
				_capsule(body, 0.15, 0.64, Vector3.ZERO, false)
				length = 0.64
			Part.HEAD:
				_sphere(body, 0.135, Vector3(0.0, 0.01, 0.02))
				length = 0.3
			Part.UPPER_ARM_L, Part.UPPER_ARM_R:
				_capsule(body, 0.05, UPPER_ARM, Vector3.ZERO, false)
				length = UPPER_ARM
			Part.LOWER_ARM_L, Part.LOWER_ARM_R:
				_capsule(body, 0.045, LOWER_ARM, Vector3.ZERO, false)
				_sphere(body, 0.07, Vector3(0.0, -LOWER_ARM * 0.5 - 0.1, -0.01))
				length = LOWER_ARM
			Part.UPPER_LEG_L, Part.UPPER_LEG_R:
				_capsule(body, 0.065, UPPER_LEG, Vector3.ZERO, false)
				length = UPPER_LEG
			Part.LOWER_LEG_L, Part.LOWER_LEG_R:
				_capsule(body, 0.05, LOWER_LEG, Vector3.ZERO, false)
				_sphere(body, 0.06, Vector3(0.0, -LOWER_LEG * 0.5, 0.0))
				_sphere(body, 0.045, Vector3(0.0, -LOWER_LEG * 0.5 - 0.015, -0.12))
				length = LOWER_LEG
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


func _capsule(body: RigidBody3D, radius: float, height: float, at: Vector3, sideways: bool) -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = maxf(height, radius * 2.0)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = at
	if sideways:
		collider.rotation.z = PI * 0.5
	body.add_child(collider)


func _sphere(body: RigidBody3D, radius: float, at: Vector3) -> void:
	var shape := SphereShape3D.new()
	shape.radius = radius
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = at
	body.add_child(collider)


func _build_joints() -> void:
	# Limits are [min, max] per axis for the child's rotation relative to its
	# parent: X pitches a hanging limb forward, Z lifts a right limb out sideways.
	_joint(Part.TORSO, Vector3(0.0, WAIST_Y, 0.0), Vector2(-0.9, 0.35), Vector2(-0.6, 0.6), Vector2(-0.35, 0.35))
	_joint(Part.HEAD, Vector3(0.0, NECK_Y, 0.0), Vector2(-0.7, 0.6), Vector2(-1.1, 1.1), Vector2(-0.45, 0.45))
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var out := Vector2(-0.25, 1.7) if i == 1 else Vector2(-1.7, 0.25)
		var upper_arm: int = Part.UPPER_ARM_L if i == 0 else Part.UPPER_ARM_R
		var lower_arm: int = Part.LOWER_ARM_L if i == 0 else Part.LOWER_ARM_R
		_joint(upper_arm, Vector3(side * SHOULDER_X, SHOULDER_Y, 0.0), Vector2(-1.0, 2.9), Vector2(-0.7, 0.7), out)
		_joint(lower_arm, Vector3(side * SHOULDER_X, SHOULDER_Y - UPPER_ARM, 0.0), Vector2(0.0, 2.5), Vector2(-0.25, 0.25), Vector2(-0.05, 0.05))
		var splay := Vector2(-0.15, 0.7) if i == 1 else Vector2(-0.7, 0.15)
		var upper_leg: int = Part.UPPER_LEG_L if i == 0 else Part.UPPER_LEG_R
		var lower_leg: int = Part.LOWER_LEG_L if i == 0 else Part.LOWER_LEG_R
		_joint(upper_leg, Vector3(side * HIP_X, HIP_Y, 0.0), Vector2(-0.6, 1.9), Vector2(-0.4, 0.4), splay)
		_joint(lower_leg, Vector3(side * HIP_X, HIP_Y - UPPER_LEG, 0.0), Vector2(-2.4, 0.0), Vector2(-0.1, 0.1), Vector2(-0.05, 0.05))


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
	if _bodies.is_empty():
		return
	_time += delta
	_thud_left = maxf(0.0, _thud_left - delta)
	if is_stunned and not stun_locked:
		stun_meter = maxf(0.0, stun_meter - STUN_DECAY[bind_level] * delta)
		if stun_meter <= 0.0:
			wake()
	if is_stunned:
		_tick_limp(delta)
	else:
		_tick_active(delta)
	_tick_safety(delta)


func _tick_active(delta: float) -> void:
	var pelvis := _bodies[Part.PELVIS]
	var torso := _bodies[Part.TORSO]
	_support = move_toward(_support, 1.0, delta / RISE_TIME)
	_height = lerpf(_height, POSE_HEIGHT[pose], minf(1.0, delta * 4.0))
	_hunch = lerpf(_hunch, POSE_HUNCH[pose], minf(1.0, delta * 4.0))
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
	var hip_height := _bodies[Part.PELVIS].global_position.y - (PELVIS_Y - HIP_Y) - _ground_y - FOOT_CLEARANCE
	var fold := acos(clampf(hip_height / (UPPER_LEG + LOWER_LEG), 0.36, 1.0))
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
		var pitch := 0.3
		var spread := 0.12
		var elbow := 0.45
		var response := 9.0
		var gain := 1.4
		match pose:
			Pose.LURK:
				# Knuckles nearly on the floor, breathing slowly.
				pitch = 0.32 + sin(_time * 1.1 + offset) * 0.05 + _jitter[i] * 0.12
				elbow = 0.45 + sin(_time * 0.9 + offset) * 0.06
			Pose.STALK:
				# Reaching, hunched, with small involuntary twitches.
				pitch = 0.75 + sin(_time * 1.3 + offset) * 0.18 + _jitter[i] * 0.35
				spread = 0.22 + sin(_time * 0.8 + offset) * 0.08
				elbow = 0.75 + sin(_time * 2.1 + offset) * 0.2 + _jitter[1 - i] * 0.25
			Pose.CHASE:
				# Long arms windmilling out of step with the legs.
				pitch = 0.95 + sin(_gait + (PI if i == 0 else 0.0)) * (0.5 + 0.5 * stride) + _jitter[i] * 0.5
				spread = 0.45 + sin(_time * 5.3 + offset) * 0.28
				elbow = 0.9 + sin(_gait * 1.7 + offset) * 0.55
				response = 11.0
			Pose.CAST:
				# Both arms thrown up and wide, trembling.
				pitch = 2.5 + sin(_time * 31.0 + offset) * 0.05
				spread = 0.75
				elbow = 0.5 + sin(_time * 27.0 + offset) * 0.06
				response = 13.0
			Pose.FREEZE:
				# Shielding its eyes from the torch beam.
				pitch = 1.95 + _jitter[i] * 0.3
				spread = -0.15
				elbow = 1.7 + _jitter[1 - i] * 0.3
				response = 14.0
		if i == _swipe_arm:
			response = 18.0
			gain = 3.0
			if _swipe_time < 0.2:
				pitch = -0.7
				spread = 1.35
				elbow = 0.9
			elif _swipe_time < 0.44:
				pitch = 1.7
				spread = -0.2
				elbow = 0.15
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
	_struggle_left -= delta
	if _struggle_left <= 0.0:
		var strength := STRUGGLE[bind_level] * (1.0 if dragged else 0.25)
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
	_support = 0.0
	_struggle_left = randf_range(0.8, 1.4)
	_apply_damping()
	# A shove off balance so it folds forward instead of sinking straight down.
	_bodies[Part.TORSO].apply_central_impulse(get_facing() * PART_MASS[Part.TORSO] * 1.1)
	stun_changed.emit(true)


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
			if not (at.is_finite() and velocity.is_finite() and spin.is_finite()) or at.distance_to(hips) > MAX_STRETCH:
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
