extends Node3D
## First-person sleeves and tactical gloves.
##
## The exorcist rig is a faceted low-poly figure, which is fine at third-person
## distance but reads as angular slabs when its arms fill the bottom of the
## screen. In first person ExorcistModel hides the rig's own arms and poses
## these instead: round tapered sleeves with a storm cuff, and a glove with a
## gauntlet, padded knuckles and jointed fingers that close when something is held.
## Every part is placed in world space from the rig's solved shoulder, elbow and
## wrist, so the arms still leave the body at the shoulders when you look down.

const SHOULDER_RADIUS := 0.056
const ELBOW_RADIUS := 0.047
const WRIST_RADIUS := 0.037
## The glove is modelled life-size, then enlarged a little: a padded glove close to the lens.
const HAND_SCALE := 1.22
## Phalanx lengths of the middle finger; the others are scaled from it, index first.
const FINGER_SEGMENTS: Array[float] = [0.035, 0.024, 0.021]
const FINGER_SCALE: Array[float] = [0.92, 1.0, 0.94, 0.76]
const FINGER_RADIUS := 0.0126
const THUMB_SEGMENTS: Array[float] = [0.036, 0.03]
## Knuckle curl in radians, relaxed and closed round a grip, for each joint down a finger.
const CURL_OPEN: Array[float] = [0.36, 0.55, 0.4]
const CURL_GRIP: Array[float] = [1.0, 1.25, 0.85]

var _upper: Array[MeshInstance3D] = []
var _fore: Array[MeshInstance3D] = []
var _shoulder: Array[MeshInstance3D] = []
var _elbow: Array[MeshInstance3D] = []
var _cuff: Array[MeshInstance3D] = []
var _hem: Array[MeshInstance3D] = []
var _hand: Array[Node3D] = []
## Per hand: one Array of joint nodes per finger, thumb last.
var _fingers: Array = []


## `sleeve` is the suit fabric, `band` the reflective cuff stripe, `glove` and `guard`
## the soft and the moulded parts of the glove.
func build(sleeve: Material, band: Material, glove: Material, guard: Material) -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	for side in 2:
		var sign := -1.0 if side == 0 else 1.0
		_upper.append(_add(self, _cylinder(ELBOW_RADIUS, SHOULDER_RADIUS, 1.0), sleeve))
		_fore.append(_add(self, _cylinder(WRIST_RADIUS, ELBOW_RADIUS, 1.0), sleeve))
		_shoulder.append(_add(self, _ball(SHOULDER_RADIUS * 1.04), sleeve))
		_elbow.append(_add(self, _ball(ELBOW_RADIUS * 1.03), sleeve))
		_cuff.append(_add(self, _cylinder(WRIST_RADIUS + 0.005, WRIST_RADIUS + 0.007, 0.03), band))
		_hem.append(_add(self, _cylinder(WRIST_RADIUS + 0.003, WRIST_RADIUS + 0.005, 0.022), guard))
		var hand := Node3D.new()
		hand.name = "HandL" if side == 0 else "HandR"
		add_child(hand)
		_hand.append(hand)
		_fingers.append(_build_hand(hand, sign, glove, guard))
	set_shown(false)


func set_shown(shown: bool) -> void:
	visible = shown


## Places one arm. Positions are world space; `hand` has -Z along the fingers and +Y out
## of the back of the hand; `grip` 0..1 closes the fingers.
func pose_arm(side: int, shoulder: Vector3, elbow: Vector3, wrist: Vector3, hand: Basis, grip: float) -> void:
	if _hand.is_empty():
		return
	_span(_upper[side], shoulder, elbow, true)
	_span(_fore[side], elbow, wrist, true)
	_shoulder[side].global_position = shoulder
	_elbow[side].global_position = elbow
	_span(_cuff[side], elbow.lerp(wrist, 0.74), elbow.lerp(wrist, 0.74) + (wrist - elbow).normalized() * 0.03, false)
	_span(_hem[side], elbow.lerp(wrist, 0.9), elbow.lerp(wrist, 0.9) + (wrist - elbow).normalized() * 0.022, false)
	_hand[side].global_transform = Transform3D(hand.orthonormalized().scaled(Vector3.ONE * HAND_SCALE), wrist)
	var fingers: Array = _fingers[side]
	for finger in fingers.size():
		var joints: Array = fingers[finger]
		var is_thumb := finger == fingers.size() - 1
		for joint in joints.size():
			# Each finger closes a touch later than the one before it, like a real fist.
			var close := clampf(grip * 1.15 - finger * 0.05, 0.0, 1.0)
			var curl := lerpf(CURL_OPEN[joint], CURL_GRIP[joint], close) + finger * 0.035
			if is_thumb:
				curl = lerpf(0.12, 0.55, grip)
			(joints[joint] as Node3D).rotation.x = -curl


# --- Construction ---------------------------------------------------------------

## Gauntlet, palm, knuckle guard, four fingers and a thumb under `hand`. Returns the joint nodes.
func _build_hand(hand: Node3D, sign: float, glove: Material, guard: Material) -> Array:
	# The thumb sits on the side of the hand that faces the other hand.
	var inner := -sign
	var gauntlet := _add(hand, _cylinder(0.029, 0.036, 0.046), glove)
	gauntlet.rotation.x = -PI * 0.5
	gauntlet.position = Vector3(0.0, 0.0, 0.0)
	var strap := _add(hand, _cylinder(0.033, 0.034, 0.014), guard)
	strap.rotation.x = -PI * 0.5
	strap.position = Vector3(0.0, 0.0, -0.014)
	var palm := _add(hand, _ball(0.5), glove)
	palm.scale = Vector3(0.094, 0.042, 0.112)
	palm.position = Vector3(0.0, -0.002, -0.064)
	var plate := _add(hand, _ball(0.5), guard)
	plate.scale = Vector3(0.066, 0.02, 0.058)
	plate.position = Vector3(0.0, 0.016, -0.056)
	var knuckles := _add(hand, _ball(0.5), guard)
	knuckles.scale = Vector3(0.09, 0.026, 0.036)
	knuckles.position = Vector3(0.0, 0.012, -0.106)

	var fingers: Array = []
	for finger in 4:
		var across := inner * (0.0325 - finger * 0.0217)
		var root := Node3D.new()
		root.position = Vector3(across, -0.003, -0.11 + absf(finger - 1.0) * 0.004)
		# Fanned a little, so the fingers do not read as four parallel pegs.
		root.rotation.y = -inner * (0.05 - finger * 0.035)
		hand.add_child(root)
		fingers.append(_build_finger(root, FINGER_SEGMENTS, FINGER_SCALE[finger], FINGER_RADIUS - finger * 0.0004, glove, guard))
	var thumb := Node3D.new()
	thumb.position = Vector3(inner * 0.036, -0.012, -0.04)
	thumb.rotation = Vector3(0.0, -inner * 0.85, inner * 0.5)
	hand.add_child(thumb)
	fingers.append(_build_finger(thumb, THUMB_SEGMENTS, 1.0, 0.0125, glove, guard))
	return fingers


## A chain of capsules along -Z, each on its own joint node. Returns those joints, knuckle first.
func _build_finger(root: Node3D, segments: Array[float], length_scale: float, radius: float, glove: Material, guard: Material) -> Array:
	var joints: Array = []
	var parent := root
	for index in segments.size():
		var length := segments[index] * length_scale
		var joint := Node3D.new()
		parent.add_child(joint)
		var girth := radius * (1.0 - index * 0.07)
		var bone := CapsuleMesh.new()
		bone.radius = girth
		bone.height = length + girth * 2.0
		bone.radial_segments = 12
		bone.rings = 4
		var segment := _add(joint, bone, glove)
		segment.rotation.x = -PI * 0.5
		segment.position = Vector3(0.0, 0.0, -length * 0.5)
		if index == 0:
			# Moulded pad over the first knuckle.
			var pad := _add(joint, _ball(0.5), guard)
			pad.scale = Vector3(girth * 1.9, girth * 1.3, length * 0.7)
			pad.position = Vector3(0.0, girth * 0.55, -length * 0.45)
		joints.append(joint)
		var next := Node3D.new()
		next.position = Vector3(0.0, 0.0, -length)
		joint.add_child(next)
		parent = next
	return joints


func _cylinder(top_radius: float, bottom_radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = 24
	mesh.rings = 3
	return mesh


func _ball(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 20
	mesh.rings = 10
	return mesh


func _add(parent: Node3D, mesh: Mesh, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	# Also on the held-tool layer, so the hand lamp picks the gloves out of the dark.
	instance.layers = 1 | (1 << 11)
	# Posed after the skeleton each frame; generous bounds keep the arms from being culled.
	instance.extra_cull_margin = 0.5
	parent.add_child(instance)
	return instance


## Lays a cylinder from `from` to `to`. With `fit`, its mesh is resized to the gap rather
## than the node being scaled, so the fabric weave keeps its size.
func _span(node: MeshInstance3D, from: Vector3, to: Vector3, fit: bool) -> void:
	var along := to - from
	var length := along.length()
	if length < 0.001:
		return
	var y := along / length
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 0.01:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	if fit:
		var mesh := node.mesh as CylinderMesh
		if absf(mesh.height - length) > 0.002:
			mesh.height = length
	node.global_transform = Transform3D(Basis(x, y, x.cross(y)), (from + to) * 0.5)
