extends Node3D
## Rigged exorcist: the CC0 worker character re-dressed as a hazmat exorcist
## (team-coloured suit, gas mask with glowing lenses, hardhat lamp, utility belt
## and a backpack rig with holy-water canisters).
##
## Locomotion comes from the model's own skeletal clips (idle / walk / run);
## a SkeletonModifier3D layers the procedural parts on top: crouch, airborne
## tuck, sprint lean, head pitch, and two-bone IK for arms that reach for a
## grabbed prop or float in view as first-person hands.
## The model faces -Z with its feet on the node's origin.

## Emitted after the final (IK-adjusted) pose of the frame is known.
signal pose_updated

const Mats := preload("res://scripts/MaterialLibrary.gd")
const ViewArms := preload("res://scripts/FirstPersonArms.gd")

enum Suit { ORANGE, TEAL, OLIVE, PURPLE }

const SUIT_COLORS: Array[Color] = [Color(0.86, 0.34, 0.06), Color(0.05, 0.50, 0.50), Color(0.38, 0.42, 0.17), Color(0.40, 0.20, 0.58)]
const VISOR_COLORS: Array[Color] = [Color(0.25, 1.0, 0.85), Color(1.0, 0.72, 0.18), Color(1.0, 0.32, 0.16), Color(0.62, 1.0, 0.28)]

const MODEL := "characters/exorcist"
const MASK_MODEL := "characters/gas_mask"
const CANISTER_MODEL := "characters/gas_canister"
## Metres from the soles to the top of the skull bone; the hardhat adds a little.
const RIG_HEIGHT := 1.74
const CLIP_PREFIX := "CharacterArmature|"
const CLIP_IDLE := CLIP_PREFIX + "Idle"
const CLIP_WALK := CLIP_PREFIX + "Walk"
const CLIP_RUN := CLIP_PREFIX + "Run"
const CLIP_RUN_BACK := CLIP_PREFIX + "Run_Back"
const CLIP_WAVE := CLIP_PREFIX + "Wave"
const CLIP_INTERACT := CLIP_PREFIX + "Interact"
const CLIP_FALL := CLIP_PREFIX + "Death"
const CROUCH_DROP := 0.5
## The rig's arms are short; first-person hands borrow some length to sit in frame.
const FIRST_PERSON_ARM_STRETCH := 0.35
const SIDES: Array[String] = ["L", "R"]
## Centre of the palm in a first-person glove's own frame.
const PALM_OFFSET := Vector3(0.0, -0.02, -0.08)
const HAND_BONES: Array[String] = ["Wrist", "Index", "Middle", "Ring", "Pinky", "Thumb"]

## Glove-split copies of the shared body mesh, keyed by the imported mesh.
static var _glove_meshes: Dictionary = {}

@export var suit: Suit = Suit.ORANGE
## Idle crew member: plays idle loops with the odd wave instead of following a controller.
@export var showcase := false

var _rig: Node3D
var _skeleton: Skeleton3D
var _anim: AnimationPlayer
var _body_meshes: Array[MeshInstance3D] = []
var _head_parts: Array[GeometryInstance3D] = []
var _lamp_lens: Node3D
var _fallback_parts: Array[MeshInstance3D] = []

var _suit_material: StandardMaterial3D
var _pants_material: StandardMaterial3D
var _trim_material: StandardMaterial3D
var _visor_material := StandardMaterial3D.new()
var _lamp_material := StandardMaterial3D.new()
var _led_material := StandardMaterial3D.new()

var _bones: Dictionary = {}
var _speed := 0.0
var _on_floor := true
var _crouch := 0.0
var _sprinting := false
var _backward := false
var _pitch := 0.0
var _air := 0.0
var _lean := 0.0
var _clock := 0.0
var _reach_weight := 0.0
var _reaching := false
var _reach_target := Vector3.ZERO
var _first_person := false
var _arms_weight := 0.0
var _view := Transform3D.IDENTITY
var _sway := Vector2.ZERO
var _last_view_basis := Basis.IDENTITY
var _stride_phase := 0.0
var _hand_world: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _showcase_wait := 0.0
var _knocked := false

# First-person arms: smooth sleeves and gloves that stand in for the rig's faceted ones.
var _view_arms: ViewArms
var _sleeve_material: StandardMaterial3D
var _arms_swapped := false
## Harness and backpack: like the head, they only cast shadows in first person.
var _chest_gear: Array[GeometryInstance3D] = []
## A gadget in hand: where each palm grips it (world space, left then right).
var _tool_on := false
var _tool_weight := 0.0
var _tool_palm: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _tool_two_handed := false
var _tool_grip := 1.0
## 0..1: how heavy the held thing is, and how far the grip is from where it wants to be.
var _load := 0.0
var _load_target := 0.0
var _strain := 0.0


func _ready() -> void:
	_build()
	apply_suit(suit)
	set_headlamp(showcase)
	_showcase_wait = randf_range(4.0, 12.0)


## Recolours the suit and visor. Index wraps, so any player number is valid.
func apply_suit(index: int) -> void:
	suit = posmod(index, SUIT_COLORS.size()) as Suit
	var color := SUIT_COLORS[suit]
	_suit_material.albedo_color = color
	if _sleeve_material:
		_sleeve_material.albedo_color = color
	_pants_material.albedo_color = color.darkened(0.3)
	_trim_material.albedo_color = color.darkened(0.6)
	var visor := VISOR_COLORS[suit]
	_visor_material.albedo_color = visor.darkened(0.5)
	_visor_material.emission_enabled = true
	_visor_material.emission = visor
	_visor_material.emission_energy_multiplier = 1.1


## Fed by the player controller every frame.
func set_motion(horizontal_speed: float, on_floor: bool, crouch: float, sprinting: bool, backward: bool = false) -> void:
	_speed = horizontal_speed
	_on_floor = on_floor
	_crouch = crouch
	_sprinting = sprinting
	_backward = backward


func set_look_pitch(pitch: float) -> void:
	_pitch = pitch


## While `active`, the arms stretch toward `global_target` (the grab point).
## `load` (0..1) is how heavy the held thing is and `strain` (0..1) how hard the grip is
## being pulled: first-person arms sag, reach further and tremble with them.
func set_reach(active: bool, global_target: Vector3 = Vector3.ZERO, load: float = 0.0, strain: float = 0.0) -> void:
	_reaching = active
	_load_target = clampf(load, 0.0, 1.0) if active else 0.0
	_strain = clampf(strain, 0.0, 1.0) if active else 0.0
	if active:
		_reach_target = global_target


## Camera transform; in first person the gloved hands are posed relative to it.
func set_view(camera_transform: Transform3D) -> void:
	_view = camera_transform


## A gadget in hand. The palm frames are in world space (-Z along the fingers, +Y out of the
## back of the hand); the arms are solved onto them in first and third person alike.
func set_tool(active: bool, right_palm: Transform3D = Transform3D.IDENTITY, left_palm: Transform3D = Transform3D.IDENTITY,
		two_handed: bool = false, grip: float = 1.0) -> void:
	_tool_on = active
	if active:
		_tool_palm[0] = left_palm
		_tool_palm[1] = right_palm
		_tool_two_handed = two_handed
		_tool_grip = grip


## World position of a palm after IK (0 left, 1 right): where a held tool is hung.
func get_palm_position(side: int = 1) -> Vector3:
	return get_hand_position(side)


## In first person the head, the harness and their gear only cast shadows, so the camera
## never looks out through its own mask or past its own shoulder straps; the body stays visible.
func set_first_person(enabled: bool) -> void:
	_first_person = enabled
	var cast := GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for part in _head_parts:
		part.cast_shadow = cast
	for part in _chest_gear:
		part.cast_shadow = cast
	for part in _fallback_parts:
		part.visible = not enabled


## World position of the hardhat lamp lens; the player's torch shines from here.
func get_headlamp_position() -> Vector3:
	return _lamp_lens.global_position if _lamp_lens else global_transform * Vector3(0.0, 1.8, -0.2)


## World position of a glove after IK (0 left, 1 right); the grab tether starts at the right one.
func get_hand_position(side: int = 1) -> Vector3:
	if _skeleton == null:
		return global_transform * Vector3(0.3 if side == 1 else -0.3, 1.0, -0.3)
	return _hand_world[side]


## Tumble onto the floor (true) or get back up (false).
func set_knockdown(active: bool) -> void:
	if _knocked == active:
		return
	_knocked = active
	if _anim == null:
		return
	if active and _anim.has_animation(CLIP_FALL):
		_anim.speed_scale = 1.5
		_anim.play(CLIP_FALL, 0.1)
	elif not active:
		_anim.speed_scale = 1.0
		_anim.play(CLIP_IDLE, 0.45)


func set_headlamp(on: bool) -> void:
	_lamp_material.albedo_color = Color(1.0, 0.96, 0.85) if on else Color(0.2, 0.2, 0.19)
	_lamp_material.emission_enabled = true
	_lamp_material.emission = Color(1.0, 0.95, 0.8)
	_lamp_material.emission_energy_multiplier = 4.0 if on else 0.05


## One-shot gesture (showcase crew); returns to the idle loop afterwards.
func play_gesture(clip: String) -> void:
	if _anim and _anim.has_animation(clip):
		_anim.play(clip, 0.25)
		_anim.queue(CLIP_IDLE)


func _process(delta: float) -> void:
	_clock += delta
	if _skeleton == null:
		pose_updated.emit()
	_air = move_toward(_air, 0.0 if _on_floor else 1.0, delta * 6.0)
	_reach_weight = move_toward(_reach_weight, 1.0 if _reaching else 0.0, delta * 7.0)
	_arms_weight = move_toward(_arms_weight, 1.0 if _first_person and not _knocked else 0.0, delta * 5.0)
	_load = lerpf(_load, _load_target, minf(1.0, delta * 5.0))
	_tool_weight = move_toward(_tool_weight, 1.0 if _tool_on and not _knocked else 0.0, delta * 9.0)
	var swap := _view_arms != null and _arms_weight > 0.5
	if swap != _arms_swapped:
		_swap_arms(swap)
	var lean_target := 0.0 if _first_person else (0.16 if _sprinting else 0.0) + 0.3 * _crouch
	_lean = lerpf(_lean, lean_target, minf(1.0, delta * 9.0))
	if _speed > 0.3 and _on_floor:
		_stride_phase += delta * (5.0 + _speed * 1.6)

	# Hand sway: the view turning drags the hands a little behind it.
	var turn := _last_view_basis.inverse() * _view.basis
	_last_view_basis = _view.basis
	var turn_euler := turn.get_euler()
	_sway = _sway.lerp(Vector2(turn_euler.y, turn_euler.x) * 0.9, minf(1.0, delta * 10.0)).limit_length(0.08)

	# Backpack status LED: a slow green heartbeat.
	_led_material.emission_energy_multiplier = 3.0 if fmod(_clock, 1.4) < 0.12 else 0.15
	_update_clip(delta)


func _update_clip(delta: float) -> void:
	if _anim == null or _knocked:
		return
	if showcase:
		_showcase_wait -= delta
		if _showcase_wait <= 0.0:
			_showcase_wait = randf_range(9.0, 20.0)
			play_gesture(CLIP_WAVE if randf() < 0.5 else CLIP_INTERACT)
		return
	var clip := CLIP_IDLE
	var rate := 1.0
	if _on_floor and _speed > 0.3:
		if _speed < 3.2:
			clip = CLIP_WALK
			rate = clampf(_speed / 1.7, 0.6, 1.9) * (-1.0 if _backward else 1.0)
		else:
			clip = CLIP_RUN_BACK if _backward else CLIP_RUN
			rate = clampf(_speed / 5.6, 0.75, 1.35)
	if _anim.current_animation != clip:
		_anim.play(clip, 0.22)
	_anim.speed_scale = rate


# --- Procedural pose layer ----------------------------------------------------

## Runs after the animation clip has been applied, inside the skeleton update.
func _apply_pose(skeleton: Skeleton3D) -> void:
	if _knocked:
		# The fall clip owns the whole body.
		for i in 2:
			_hand_world[i] = skeleton.global_transform * skeleton.get_bone_global_pose(_bone("Wrist.%s" % SIDES[i])).origin
		pose_updated.emit()
		return
	var to_skeleton := skeleton.global_transform.affine_inverse()
	var up := (to_skeleton.basis * Vector3.UP)
	var unit := up.length()  # skeleton units per metre
	up /= unit
	var forward := (to_skeleton.basis * -global_transform.basis.z).normalized()
	var right := forward.cross(up).normalized()

	# Crouch / airborne: drop the body and re-solve the legs onto their feet.
	var drop := _crouch * CROUCH_DROP
	var tuck := _air * 0.14
	if drop > 0.001 or tuck > 0.001:
		var ankles: Array[Vector3] = []
		for side in SIDES:
			ankles.append(skeleton.get_bone_global_pose(_bone("LowerLeg.%s_end" % side)).origin)
			if tuck > 0.001:
				_shift_bone(skeleton, _bone("Foot.%s" % side), up * tuck * unit)
		_shift_bone(skeleton, _bone("Body"), -up * drop * unit)
		for i in 2:
			var side := SIDES[i]
			_solve_limb(skeleton, _bone("UpperLeg.%s" % side), _bone("LowerLeg.%s" % side), _bone("LowerLeg.%s_end" % side),
					ankles[i] + up * tuck * unit, forward)

	if absf(_lean) > 0.001:
		_rotate_bone(skeleton, _bone("Abdomen"), right, -_lean * 0.5)
		_rotate_bone(skeleton, _bone("Chest"), right, -_lean * 0.5)
	# The mask follows the line of sight (and cancels the lean).
	var look := clampf(_pitch, -1.0, 1.0) + _lean
	_rotate_bone(skeleton, _bone("Neck"), right, look * 0.45)
	_rotate_bone(skeleton, _bone("Head"), right, look * 0.45)

	for i in 2:
		var side := SIDES[i]
		var wrist := _bone("Wrist.%s" % side)
		var sign := -1.0 if i == 0 else 1.0
		# A tool in hand overrides the resting pose, but never a reach for something grabbed.
		var held := _tool_weight * (1.0 if i == 1 or _tool_two_handed else 0.0) * (1.0 - _reach_weight)
		var weight := maxf(maxf(_arms_weight, _reach_weight), held)
		if weight > 0.001:
			var upper := _bone("UpperArm.%s" % side)
			if _arms_weight > 0.001 and upper >= 0:
				var arm_pose := skeleton.get_bone_global_pose(upper)
				arm_pose.basis = arm_pose.basis.scaled(Vector3.ONE * (1.0 + FIRST_PERSON_ARM_STRETCH * _arms_weight))
				skeleton.set_bone_global_pose(upper, arm_pose)
			var current := skeleton.get_bone_global_pose(wrist).origin
			var shoulder_world := skeleton.global_transform * skeleton.get_bone_global_pose(_bone("UpperArm.%s" % side)).origin
			var goal_world := _hand_goal(sign, shoulder_world)
			if held > 0.001:
				# The wrist sits behind the palm that grips the tool.
				var palm := _tool_palm[i]
				var grip_point := palm.origin - palm.basis * (PALM_OFFSET if _arms_swapped else Vector3(0.0, 0.0, -0.07))
				var resting := goal_world if maxf(_arms_weight, _reach_weight) > 0.001 else grip_point
				goal_world = shoulder_world + (resting.lerp(grip_point, held) - shoulder_world).limit_length(0.6)
			var goal := current.lerp(to_skeleton * goal_world, smoothstep(0.0, 1.0, weight))
			var pole := (-up * 0.8 + right * sign * 0.7 - forward * 0.35).normalized()
			_solve_limb(skeleton, _bone("UpperArm.%s" % side), _bone("LowerArm.%s" % side), wrist, goal, pole)
		_hand_world[i] = skeleton.global_transform * skeleton.get_bone_global_pose(wrist).origin
		if _arms_swapped:
			var upper_arm := _bone("UpperArm.%s" % side)
			var shoulder := skeleton.global_transform * skeleton.get_bone_global_pose(upper_arm).origin
			var elbow := skeleton.global_transform * skeleton.get_bone_global_pose(_bone("LowerArm.%s" % side)).origin
			var hand := _hand_basis(sign, elbow, _hand_world[i])
			if held > 0.001:
				hand = Basis(hand.get_rotation_quaternion().slerp(_tool_palm[i].basis.get_rotation_quaternion(), held))
			_view_arms.pose_arm(i, shoulder, elbow, _hand_world[i], hand, maxf(_reach_weight, _tool_grip * held))
			# The tether (and any tool) leaves the palm, not the wrist.
			_hand_world[i] += hand * PALM_OFFSET
			# The rig's own faceted arm (and its cuff bands) folds away into the shoulder, under the sleeve.
			var tucked := skeleton.get_bone_global_pose(upper_arm)
			tucked.basis = tucked.basis.scaled(Vector3.ONE * 0.001)
			skeleton.set_bone_global_pose(upper_arm, tucked)
		elif held > 0.001:
			# Third person: the rig's own palm is a little way down the line of the forearm.
			var elbow_world := skeleton.global_transform * skeleton.get_bone_global_pose(_bone("LowerArm.%s" % side)).origin
			_hand_world[i] += (_hand_world[i] - elbow_world).normalized() * 0.07 * held
	pose_updated.emit()


## Orientation of a first-person glove: -Z along the fingers, +Y out of the back of the hand.
## Relaxed, the hands point ahead and a little inward with the knuckles rolled outward;
## gripping, they turn toward the grab point and roll further, palms closing on the load.
func _hand_basis(sign: float, elbow: Vector3, wrist: Vector3) -> Basis:
	var view := _view.basis.orthonormalized()
	var forward := ((wrist - elbow).normalized() * 0.55 - view.z * 0.45 - view.x * sign * 0.14).normalized()
	var to_grab := _reach_target - wrist
	if _reach_weight > 0.001 and to_grab.length_squared() > 0.0004:
		forward = forward.lerp(to_grab.normalized(), 0.55 * _reach_weight).normalized()
	# The right hand is carried a touch flatter than the left: no two hands rest alike.
	var roll := 0.62 - sign * 0.07 + (0.42 + 0.22 * _load) * _reach_weight + sin(_clock * 0.7 + sign * 1.3) * 0.03
	var back := view.y * cos(roll) + view.x * sign * sin(roll)
	back = (back - forward * back.dot(forward)).normalized()
	return Basis(back.cross(-forward), back, -forward)


## Where a hand wants to be this frame, in world space.
func _hand_goal(sign: float, shoulder_world: Vector3) -> Vector3:
	var goal: Vector3
	if _arms_weight > 0.5:
		# First-person hands: low in the frame, bobbing with the stride and trailing the view.
		# The two rest spots differ (the right hand rides higher and further out, ready to
		# grab) and each drifts on its own slow rhythm, so they never look mirrored.
		var bob := Vector3(sin(_stride_phase * 0.5) * 0.012, absf(cos(_stride_phase * 0.5)) * 0.016, 0.0) * clampf(_speed / 4.4, 0.0, 1.4)
		var drift := Vector3(sin(_clock * 0.9 + sign * 0.8) * 0.005, sin(_clock * 1.6 + sign) * 0.005, cos(_clock * 0.6 + sign * 2.1) * 0.006)
		var home := Vector3(0.215, -0.3, -0.5) if sign > 0.0 else Vector3(-0.24, -0.33, -0.465)
		var rest := home + Vector3(-_sway.x * 0.6, _sway.y * 0.5, 0.0) + bob * Vector3(sign, 1.0, 1.0) + drift
		goal = _view * rest
		if _reach_weight > 0.001:
			# A heavy load drags the arms out and down toward it, and a grip near breaking shakes them.
			var toward := (_reach_target - goal).limit_length(0.16 + 0.12 * _load)
			var tremble := Vector3(sin(_clock * 31.0 + sign * 2.0), cos(_clock * 27.0 + sign), 0.0) * 0.005 * _strain
			goal += toward * _reach_weight + _view.basis * (Vector3(-sign * 0.05, 0.05 - 0.07 * _load, 0.0) + tremble) * _reach_weight
	else:
		# Third person: both gloves go for the grab point, slightly apart.
		goal = _reach_target + global_transform.basis.x * sign * 0.1
	# Never ask for more than the arm can reach.
	return shoulder_world + (goal - shoulder_world).limit_length(0.56 + 0.05 * _load * _arms_weight)


func _bone(bone_name: String) -> int:
	if not _bones.has(bone_name):
		_bones[bone_name] = _skeleton.find_bone(bone_name)
	return _bones[bone_name]


func _shift_bone(skeleton: Skeleton3D, bone: int, offset: Vector3) -> void:
	if bone < 0:
		return
	var pose := skeleton.get_bone_global_pose(bone)
	pose.origin += offset
	skeleton.set_bone_global_pose(bone, pose)


func _rotate_bone(skeleton: Skeleton3D, bone: int, axis: Vector3, angle: float) -> void:
	if bone < 0 or absf(angle) < 0.0005:
		return
	var pose := skeleton.get_bone_global_pose(bone)
	pose.basis = Basis(axis, angle) * pose.basis
	skeleton.set_bone_global_pose(bone, pose)


func _aim_bone(skeleton: Skeleton3D, bone: int, from: Vector3, to: Vector3) -> void:
	if from.length_squared() < 1e-12 or to.length_squared() < 1e-12:
		return
	var pose := skeleton.get_bone_global_pose(bone)
	pose.basis = Basis(Quaternion(from.normalized(), to.normalized())) * pose.basis
	skeleton.set_bone_global_pose(bone, pose)


## Two-bone IK in skeleton space: puts `tip` on `target`, bending toward `pole`.
func _solve_limb(skeleton: Skeleton3D, upper: int, lower: int, tip: int, target: Vector3, pole: Vector3) -> void:
	if upper < 0 or lower < 0 or tip < 0:
		return
	var a := skeleton.get_bone_global_pose(upper).origin
	var b := skeleton.get_bone_global_pose(lower).origin
	var c := skeleton.get_bone_global_pose(tip).origin
	var upper_length := a.distance_to(b)
	var lower_length := b.distance_to(c)
	var span := target - a
	if span.length_squared() < 1e-12:
		return
	var distance := clampf(span.length(), absf(upper_length - lower_length) * 1.02, (upper_length + lower_length) * 0.998)
	var direction := span.normalized()
	var along := (upper_length * upper_length + distance * distance - lower_length * lower_length) / (2.0 * distance)
	var out := sqrt(maxf(0.0, upper_length * upper_length - along * along))
	var bend := pole - direction * pole.dot(direction)
	if bend.length_squared() < 1e-8:
		bend = direction.cross(Vector3.RIGHT)
	var joint := a + direction * along + bend.normalized() * out
	_aim_bone(skeleton, upper, b - a, joint - a)
	b = skeleton.get_bone_global_pose(lower).origin
	c = skeleton.get_bone_global_pose(tip).origin
	_aim_bone(skeleton, lower, c - b, a + direction * distance - b)


class PoseModifier extends SkeletonModifier3D:
	var model: Node3D

	func _process_modification() -> void:
		model.call(&"_apply_pose", get_skeleton())


# --- Construction ---------------------------------------------------------------

func _build() -> void:
	_suit_material = Mats.suit_fabric(Color.WHITE).duplicate() as StandardMaterial3D
	# The rig has no usable UVs: project the weave in mesh space (mesh units are centimetres).
	_suit_material.albedo_texture = null
	_suit_material.uv1_triplanar = true
	_suit_material.uv1_scale = Vector3.ONE * 260.0
	_pants_material = _suit_material.duplicate() as StandardMaterial3D
	_trim_material = _suit_material.duplicate() as StandardMaterial3D
	_led_material.albedo_color = Color(0.2, 1.0, 0.3)
	_led_material.emission_enabled = true
	_led_material.emission = Color(0.2, 1.0, 0.3)

	_rig = ModelLoader.instance(MODEL, {"fit_height": RIG_HEIGHT, "rotate_y": 180.0, "fallback_size": Vector3(0.6, 1.8, 0.4)})
	add_child(_rig)
	_skeleton = _find(_rig, "Skeleton3D") as Skeleton3D
	_anim = _find(_rig, "AnimationPlayer") as AnimationPlayer
	if _skeleton == null:
		# Stand-in mesh from the loader: nothing to rig or dress.
		for child in _rig.find_children("*", "MeshInstance3D", true, false):
			_fallback_parts.append(child as MeshInstance3D)
		return

	_dress_rig()
	_build_gear()
	# Only a player-driven exorcist is ever seen through its own eyes.
	if not showcase:
		_build_view_arms()

	var modifier := PoseModifier.new()
	modifier.name = "PoseModifier"
	modifier.model = self
	_skeleton.add_child(modifier)

	if _anim:
		for clip: String in [CLIP_IDLE, CLIP_WALK, CLIP_RUN, CLIP_RUN_BACK]:
			if _anim.has_animation(clip):
				_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		_anim.play(CLIP_IDLE)
		if showcase:
			_anim.seek(randf() * 1.6, true)
	for i in 2:
		_hand_world[i] = _skeleton.global_transform * _skeleton.get_bone_global_rest(_bone("Wrist.%s" % SIDES[i])).origin


## Swaps the worker's flat palette for suit fabric, rubber and hood materials.
func _dress_rig() -> void:
	var rubber := Mats.rubber()
	var glove := Mats.solid(Color(0.05, 0.055, 0.05), 0.55)
	# The mask replaces the face: the head mesh only keeps its hardhat.
	var hood := StandardMaterial3D.new()
	hood.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hood.albedo_color = Color(0.0, 0.0, 0.0, 0.0)
	var hat := Mats.solid(Color(0.82, 0.66, 0.08), 0.42)
	var by_name := {
		"Worker_Vest": _suit_material, "LightBrown": _trim_material, "Skin": _suit_material, "Glove": glove,
		"Brown": _pants_material, "Brown2": _trim_material, "Black": rubber, "Grey": Mats.metal_dark(),
	}
	for child in _skeleton.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		var is_head := mesh.name.contains("Head")
		_body_meshes.append(mesh)
		if is_head:
			_head_parts.append(mesh)
		else:
			# The bare arms and hands share one surface: sleeves take the suit, hands become gloves.
			for surface in mesh.mesh.get_surface_count():
				var skin_material := mesh.mesh.surface_get_material(surface)
				if skin_material and skin_material.resource_name == "Skin":
					_split_gloves(mesh, surface)
					break
		# Skinned bounds lag behind IK-posed limbs; pad them so the body is never culled.
		mesh.extra_cull_margin = 1.0
		for surface in mesh.mesh.get_surface_count():
			var source := mesh.mesh.surface_get_material(surface)
			var key := source.resource_name if source else ""
			var replacement: Material = by_name.get(key, null)
			if key == "Worker_Yellow":
				replacement = hat if is_head else _suit_material
			elif is_head:
				replacement = hood
			if replacement:
				mesh.set_surface_override_material(surface, replacement)


## Smooth sleeves and gloves for the first-person view (see FirstPersonArms.gd).
func _build_view_arms() -> void:
	_sleeve_material = _suit_material.duplicate() as StandardMaterial3D
	# These meshes are built in metres, unlike the rig's.
	_sleeve_material.uv1_scale = Vector3.ONE * 3.0
	var glove := Mats.solid(Color(0.105, 0.108, 0.115), 0.82)
	var guard := Mats.solid(Color(0.02, 0.021, 0.024), 0.32)
	_view_arms = ViewArms.new()
	_view_arms.name = "FirstPersonArms"
	add_child(_view_arms)
	_view_arms.build(_sleeve_material, Mats.glow(Color(0.5, 0.53, 0.5), 0.12), glove, guard)


## Shows the first-person arms in place of the rig's own (or puts the rig's back).
func _swap_arms(first_person_arms: bool) -> void:
	_arms_swapped = first_person_arms
	_view_arms.set_shown(first_person_arms)


## Rebuilds a skinned mesh so the triangles of `surface` that follow the wrist
## and finger bones become their own "Glove" surface.
func _split_gloves(mesh_instance: MeshInstance3D, surface: int) -> void:
	var source := mesh_instance.mesh as ArrayMesh
	if source == null or mesh_instance.skin == null:
		return
	if _glove_meshes.has(source):
		mesh_instance.mesh = _glove_meshes[source]
		return
	var arrays := source.surface_get_arrays(surface)
	var vertex_count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if vertex_count == 0 or bones.is_empty() or indices.is_empty():
		return
	var skin := mesh_instance.skin
	var hand_bind := PackedByteArray()
	hand_bind.resize(skin.get_bind_count())
	for bind in skin.get_bind_count():
		var bone_name := String(skin.get_bind_name(bind))
		if bone_name.is_empty() and skin.get_bind_bone(bind) >= 0:
			bone_name = _skeleton.get_bone_name(skin.get_bind_bone(bind))
		for prefix in HAND_BONES:
			if bone_name.begins_with(prefix):
				hand_bind[bind] = 1
	var per_vertex := bones.size() / vertex_count
	var is_hand := PackedByteArray()
	is_hand.resize(vertex_count)
	for vertex in vertex_count:
		var best := 0
		for slot in per_vertex:
			if weights[vertex * per_vertex + slot] > weights[vertex * per_vertex + best]:
				best = slot
		var bind := bones[vertex * per_vertex + best]
		is_hand[vertex] = hand_bind[bind] if bind < hand_bind.size() else 0
	var arm_indices := PackedInt32Array()
	var hand_indices := PackedInt32Array()
	for triangle in range(0, indices.size(), 3):
		var votes := is_hand[indices[triangle]] + is_hand[indices[triangle + 1]] + is_hand[indices[triangle + 2]]
		for corner in 3:
			if votes >= 2:
				hand_indices.append(indices[triangle + corner])
			else:
				arm_indices.append(indices[triangle + corner])

	var rebuilt := ArrayMesh.new()
	var glove := StandardMaterial3D.new()
	glove.resource_name = "Glove"
	for s in source.get_surface_count():
		var flags := source.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		if s != surface:
			rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, source.surface_get_arrays(s), [], {}, flags)
			rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, source.surface_get_material(s))
			continue
		for part: Array in [[arm_indices, source.surface_get_material(s)], [hand_indices, glove]]:
			if (part[0] as PackedInt32Array).is_empty():
				continue
			var part_arrays := arrays.duplicate()
			part_arrays[Mesh.ARRAY_INDEX] = part[0]
			rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, part_arrays, [], {}, flags)
			rebuilt.surface_set_material(rebuilt.get_surface_count() - 1, part[1])
	_glove_meshes[source] = rebuilt
	mesh_instance.mesh = rebuilt


## Mask, lamp, backpack rig, belt and hi-vis bands, each riding the bone it belongs to.
func _build_gear() -> void:
	var dark := Mats.metal_dark()
	var steel := Mats.metal_bare()
	var rubber := Mats.rubber()
	var webbing := Mats.solid(Color(0.09, 0.095, 0.1), 0.92)
	var reflective := Mats.glow(Color(0.5, 0.53, 0.5), 0.12)

	# Head: full-face gas mask (the model's hose is cut off below the collar),
	# glowing lenses, and a lamp clipped to the hardhat.
	var head := _bone_mount("Head")
	var mask: Node3D = ModelLoader.instance(MASK_MODEL, {
		"clip": AABB(Vector3(0.0, 0.725, 0.0), Vector3(1.0, 0.275, 1.0)), "clip_refit": true,
		"fit_height": 0.36, "rotate_y": 180.0, "tint": Color(0.72, 0.72, 0.7), "fallback_size": Vector3(0.24, 0.34, 0.3)})
	mask.position = Vector3(0.0, -0.11, -0.03)
	head.add_child(mask)
	for sign: float in [-1.0, 1.0]:
		var lens := _sphere(mask, 0.027, Vector3(sign * 0.048, 0.205, -0.1), _visor_material)
		lens.scale = Vector3(1.0, 1.25, 0.22)
		lens.rotation.y = -sign * 0.42
		lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_box(head, Vector3(0.06, 0.05, 0.05), Vector3(0.0, 0.2, -0.15), dark)
	_lamp_lens = _cylinder(head, 0.02, 0.02, 0.01, Vector3(0.0, 0.2, -0.178), _lamp_material)
	_lamp_lens.rotation.x = PI * 0.5
	(_lamp_lens as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for part in head.find_children("*", "GeometryInstance3D", true, false):
		_head_parts.append(part as GeometryInstance3D)

	# Chest: harness, backpack frame, twin holy-water canisters, antenna and status LED.
	var chest := _bone_mount("Chest")
	_box(chest, Vector3(0.3, 0.42, 0.08), Vector3(0.0, -0.02, 0.13), webbing)
	_box(chest, Vector3(0.34, 0.035, 0.11), Vector3(0.0, 0.2, 0.14), dark)
	_box(chest, Vector3(0.34, 0.035, 0.11), Vector3(0.0, -0.24, 0.14), dark)
	for sign: float in [-1.0, 1.0]:
		var tank: Node3D = ModelLoader.instance(CANISTER_MODEL, {"fit_height": 0.38, "tint": Color(0.75, 0.72, 0.6), "grunge": 0.5, "fallback_size": Vector3(0.14, 0.43, 0.14)})
		tank.position = Vector3(sign * 0.09, -0.2, 0.235)
		chest.add_child(tank)
		_box(chest, Vector3(0.05, 0.3, 0.012), Vector3(sign * 0.105, 0.0, -0.118), webbing)
		_box(chest, Vector3(0.052, 0.035, 0.014), Vector3(sign * 0.105, 0.04, -0.119), reflective)
		_box(chest, Vector3(0.05, 0.012, 0.25), Vector3(sign * 0.105, 0.135, 0.005), webbing)
	_box(chest, Vector3(0.34, 0.03, 0.012), Vector3(0.0, -0.1, -0.121), reflective)
	_box(chest, Vector3(0.05, 0.05, 0.02), Vector3(0.0, -0.1, -0.128), steel)
	_cylinder(chest, 0.004, 0.006, 0.46, Vector3(-0.15, 0.42, 0.15), dark)
	_box(chest, Vector3(0.03, 0.03, 0.012), Vector3(0.12, 0.225, 0.16), _led_material)
	# Breathing hose: canister manifold, over the right shoulder, to the mask collar.
	var hose := _tube(chest, [Vector3(0.09, 0.2, 0.235), Vector3(0.15, 0.26, 0.15), Vector3(0.17, 0.24, 0.02),
			Vector3(0.12, 0.21, -0.1), Vector3(0.03, 0.17, -0.15)], 0.014, rubber)
	_head_parts.append(hose)
	_tube(chest, [Vector3(-0.09, 0.2, 0.235), Vector3(-0.045, 0.27, 0.235), Vector3(0.045, 0.27, 0.235), Vector3(0.09, 0.2, 0.235)], 0.012, rubber)

	# Hips: utility belt with pouches, a holy-water flask and the mask's filter can.
	var hips := _bone_mount("Hips")
	var belt := _cylinder(hips, 0.21, 0.21, 0.06, Vector3(0.0, 0.07, 0.0), webbing)
	belt.scale = Vector3(1.0, 1.0, 0.72)
	_box(hips, Vector3(0.07, 0.05, 0.02), Vector3(0.0, 0.07, -0.152), steel)
	_box(hips, Vector3(0.09, 0.12, 0.07), Vector3(0.2, 0.02, -0.03), webbing)
	_box(hips, Vector3(0.09, 0.1, 0.06), Vector3(0.12, 0.02, 0.14), webbing)
	_cylinder(hips, 0.022, 0.022, 0.11, Vector3(-0.2, 0.01, -0.06), Mats.glow(Color(0.35, 0.55, 0.7), 0.15))
	_cylinder(hips, 0.018, 0.022, 0.03, Vector3(-0.2, 0.08, -0.06), steel)
	var filter: Node3D = ModelLoader.instance(MASK_MODEL, {
		"clip": AABB(Vector3(0.0, 0.0, 0.0), Vector3(1.0, 0.19, 1.0)), "clip_refit": true,
		"fit_height": 0.17, "fallback_size": Vector3(0.09, 0.17, 0.09)})
	filter.position = Vector3(-0.17, -0.08, 0.11)
	hips.add_child(filter)

	# Hi-vis cuffs and rubber seals on wrists and ankles.
	for side in SIDES:
		_limb_band("LowerArm.%s" % side, "Wrist.%s" % side, 0.78, 0.043, 0.02, reflective)
		_limb_band("LowerArm.%s" % side, "Wrist.%s" % side, 0.95, 0.042, 0.025, rubber)
		_limb_band("LowerLeg.%s" % side, "LowerLeg.%s_end" % side, 0.66, 0.07, 0.025, reflective)
	for part in chest.find_children("*", "GeometryInstance3D", true, false):
		var gear := part as GeometryInstance3D
		if not _head_parts.has(gear) and gear.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
			_chest_gear.append(gear)


## Bone rest position in this node's space (metres).
func _rest_in_model(bone_name: String) -> Vector3:
	return (_skeleton_to_model() * _skeleton.get_bone_global_rest(_skeleton.find_bone(bone_name))).origin


func _skeleton_to_model() -> Transform3D:
	var to_model := Transform3D.IDENTITY
	var node: Node3D = _skeleton
	while node != self:
		to_model = node.transform * to_model
		node = node.get_parent() as Node3D
	return to_model


## A ring around a limb, `along` (0..1) of the way from `bone_name` to `tip_name`.
func _limb_band(bone_name: String, tip_name: String, along: float, radius: float, height: float, material: Material) -> void:
	var from := _rest_in_model(bone_name)
	var to := _rest_in_model(tip_name)
	var mount := _bone_mount(bone_name)
	var band := _cylinder(mount, radius, radius, height, (to - from) * along, material)
	band.quaternion = Quaternion(Vector3.UP, (to - from).normalized())


func _part(parent: Node3D, mesh: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	parent.add_child(instance)
	return instance


func _box(parent: Node3D, size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return _part(parent, mesh, at, material)


func _sphere(parent: Node3D, radius: float, at: Vector3, material: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	return _part(parent, mesh, at, material)


func _cylinder(parent: Node3D, top_radius: float, bottom_radius: float, height: float, at: Vector3, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = 14
	mesh.rings = 1
	return _part(parent, mesh, at, material)


## A smooth hose through `points` (Catmull-Rom), built once as a tube mesh.
func _tube(parent: Node3D, points: Array, radius: float, material: Material) -> MeshInstance3D:
	var path := PackedVector3Array()
	for i in points.size() - 1:
		var p0: Vector3 = points[maxi(i - 1, 0)]
		var p1: Vector3 = points[i]
		var p2: Vector3 = points[i + 1]
		var p3: Vector3 = points[mini(i + 2, points.size() - 1)]
		for step in 6:
			var t := step / 6.0
			path.append(0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t))
	path.append(points[points.size() - 1])
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides := 8
	var rings: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	var side_axis := Vector3.RIGHT
	for i in path.size():
		var tangent := (path[mini(i + 1, path.size() - 1)] - path[maxi(i - 1, 0)]).normalized()
		side_axis = (side_axis - tangent * side_axis.dot(tangent)).normalized()
		if side_axis.length_squared() < 0.5:
			side_axis = tangent.cross(Vector3.UP).normalized()
		var other := tangent.cross(side_axis)
		var ring := PackedVector3Array()
		var ring_normals := PackedVector3Array()
		for s in sides:
			var angle := TAU * s / sides
			var normal := side_axis * cos(angle) + other * sin(angle)
			ring.append(path[i] + normal * radius)
			ring_normals.append(normal)
		rings.append(ring)
		normals.append(ring_normals)
	for i in path.size() - 1:
		for s in sides:
			var n := (s + 1) % sides
			for corner: Array in [[i, s], [i + 1, s], [i + 1, n], [i, s], [i + 1, n], [i, n]]:
				tool.set_normal(normals[corner[0]][corner[1]])
				tool.add_vertex(rings[corner[0]][corner[1]])
	return _part(parent, tool.commit(), Vector3.ZERO, material)


## A node riding `bone_name` whose local axes match the model's (metres, -Z forward,
## +Y up) with its origin on the bone, so gear can be laid out in plain model space.
func _bone_mount(bone_name: String) -> Node3D:
	var attachment := BoneAttachment3D.new()
	attachment.name = bone_name.replace(".", "") + "Mount"
	_skeleton.add_child(attachment)
	attachment.bone_name = bone_name
	var to_model := Transform3D.IDENTITY
	var node: Node3D = _skeleton
	while node != self:
		to_model = node.transform * to_model
		node = node.get_parent() as Node3D
	var rest := to_model * _skeleton.get_bone_global_rest(_skeleton.find_bone(bone_name))
	var mount := Node3D.new()
	mount.name = "Gear"
	mount.transform = rest.affine_inverse() * Transform3D(Basis.IDENTITY, rest.origin)
	attachment.add_child(mount)
	return mount


func _find(node: Node, type_name: String) -> Node:
	if node.is_class(type_name):
		return node
	for child in node.get_children():
		var found := _find(child, type_name)
		if found:
			return found
	return null
