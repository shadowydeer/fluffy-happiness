extends RigidBody3D
## A physically simulated door leaf.
##
## The body's origin sits on the hinge line; the panel extends along local +X.
## A HingeJoint3D pins it to its frame, while a critically damped torque drives
## it toward the open or closed angle. Nothing is frozen or animated, so a
## swinging leaf still reacts to shoves, thrown props and anything wedged in the
## gap. Once shut it latches and stays shut until someone opens it.

signal toggled(open: bool)

const LATCH_ANGLE := 0.05        # rad: a closing leaf latches once it is this near shut
const LATCH_SPIN := 0.8          # rad/s: ...and moving this slowly
const LATCH_HOLD_RATE := 45.0    # 1/s: how firmly the latch pulls the leaf back to shut
const LIMIT_SLOP := 0.03         # rad of give past either end of the swing arc
const LIMIT_RETURN_RATE := 9.0   # 1/s: how hard an over-swung leaf is steered back

## Signed swing angle around local +Y. Positive carries local +X toward local -Z.
@export var open_angle := deg_to_rad(110.0)
## Natural frequency of the drive (rad/s). Higher = snappier door.
@export var drive_frequency := 3.4
@export var drive_damping_ratio := 0.95
@export var max_angular_acceleration := 30.0
## Shown in the interaction prompt: "Open <noun>" / "Close <noun>".
@export var noun := "door"

var is_open := false
## A locked leaf ignores F and stays shut (the sealed extraction van).
var locked := false
## Optional second leaf that opens and closes together with this one.
var partner: RigidBody3D

var _closed_local: Basis
var _hinge_inertia := 1.0
# A shut leaf is latched: it cannot be barged open, only opened by interaction.
var _latched := true
var _joint: HingeJoint3D


## Builds the leaf's collider and base panel. Call before adding to the tree.
func configure(width: float, height: float, thickness: float, door_mass: float, material: Material) -> void:
	mass = door_mass
	_hinge_inertia = door_mass * width * width / 3.0
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, height, thickness)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = Vector3(width * 0.5, 0.0, 0.0)
	add_child(collider)
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = shape.size
	var panel := MeshInstance3D.new()
	panel.name = "Panel"
	panel.mesh = panel_mesh
	panel.material_override = material
	panel.position = collider.position
	add_child(panel)


func _ready() -> void:
	collision_layer = GameState.LAYER_INTERACT
	# Deliberately blind to the world layer: the hinge keeps the leaf in its frame.
	collision_mask = GameState.LAYER_PLAYER | GameState.LAYER_PROP | GameState.LAYER_DEMON
	can_sleep = false
	angular_damp = 0.4
	_closed_local = transform.basis.orthonormalized()


## Pins the leaf to `anchor` (or to the world when null). Call once both are in the tree.
func hinge_to(anchor: PhysicsBody3D) -> void:
	_joint = HingeJoint3D.new()
	_joint.name = "%sHinge" % name
	get_parent().add_child(_joint)
	# HingeJoint3D turns around its local Z, so stand that axis up along the leaf's +Y.
	_joint.global_transform = Transform3D(global_transform.basis.orthonormalized() * Basis(Vector3.RIGHT, -PI * 0.5), global_position)
	# Swing limits are enforced in _integrate_forces so they behave the same on every physics backend.
	_joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, false)
	if anchor:
		_joint.node_a = _joint.get_path_to(anchor)
	_joint.node_b = _joint.get_path_to(self)


func interact(_by: Node = null) -> void:
	if locked:
		GameState.post_notice("Sealed for transport")
		return
	set_open(not is_open)


func get_prompt() -> String:
	if locked:
		return "Sealed %s" % noun
	return ("Close %s" if is_open else "Open %s") % noun


## Bolts the leaf shut: it stops being a swinging body and rides its parent rigidly.
func lock() -> void:
	locked = true
	is_open = false
	_latched = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	transform = Transform3D(_closed_local, position)


func unlock() -> void:
	locked = false
	freeze = false
	sleeping = false


func set_open(open: bool, sync_partner: bool = true) -> void:
	if is_open == open or locked:
		return
	is_open = open
	if open:
		_latched = false
	sleeping = false
	toggled.emit(is_open)
	if sync_partner and partner and partner.has_method("set_open"):
		partner.call("set_open", open, false)


## Current swing angle in radians (0 = closed).
func get_angle() -> float:
	return _angle_of(global_transform.basis)


func _closed_global() -> Basis:
	var parent := get_parent() as Node3D
	if parent:
		return (parent.global_transform.basis * _closed_local).orthonormalized()
	return _closed_local


func _angle_of(current: Basis) -> float:
	var relative := _closed_global().inverse() * current.orthonormalized()
	return atan2(relative.z.x, relative.z.z)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var axis := _closed_global().y
	var angle := _angle_of(state.transform.basis)
	var spin := state.angular_velocity.dot(axis)
	var target := open_angle if is_open else 0.0

	if not is_open and not _latched and absf(angle) < LATCH_ANGLE and absf(spin) < LATCH_SPIN:
		_latched = true
	if _latched:
		# Pin the leaf shut: overwrite the hinge-axis spin instead of fighting it with torque.
		state.angular_velocity += axis * (-angle * LATCH_HOLD_RATE - spin)
		return

	var stiffness := _hinge_inertia * drive_frequency * drive_frequency
	var damping := 2.0 * drive_damping_ratio * _hinge_inertia * drive_frequency
	var limit := _hinge_inertia * max_angular_acceleration
	var torque := clampf((target - angle) * stiffness - spin * damping, -limit, limit)
	state.apply_torque(axis * torque)

	# Hard stops at both ends of the arc: cancel outward spin and ease back inside.
	var low := minf(0.0, open_angle) - LIMIT_SLOP
	var high := maxf(0.0, open_angle) + LIMIT_SLOP
	var overshoot := 0.0
	if angle > high:
		overshoot = angle - high
	elif angle < low:
		overshoot = angle - low
	if overshoot != 0.0:
		var corrected := -overshoot * LIMIT_RETURN_RATE
		if signf(spin) == signf(overshoot) or absf(spin) < absf(corrected):
			state.angular_velocity += axis * (corrected - spin)
