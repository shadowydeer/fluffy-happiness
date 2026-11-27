extends Node
## Binds the demon's skinned .glb to the physics ragdoll.
##
## `prepare()` loads the model, scales it so its horn tips stand at
## `standing_height`, reads the rest pose of its Skeleton3D and returns the
## layout the ragdoll builds its bodies, colliders and joints from, so physics
## and mesh line up 1:1. `bind()` then stores, per bone, where it sits relative
## to the segment that drives it (`bone_local_offset`).
##
## Every physics frame the bones are posed from the bodies, parents first.
## Rotations are lightly smoothed and bone lengths are kept (a joint may give by
## at most `MAX_STRETCH`), so the skin cannot tear or turn inside out.
## While the demon is conscious a few procedural touches are layered on top:
## the head finishes its stare and twitches, the shoulders hunch, the claws flex
## and the feet stay flat. Stunned, they fade out and the mesh is the limp ragdoll.

const Ragdoll := preload("res://scripts/DemonRagdoll.gd")

const MODEL := "demon/demon"

## Bone that carries each ragdoll segment, in `Ragdoll.Part` order. These are the
## .glb's own names; tools/fetch_assets.py prints the hierarchy and refuses a file without them.
const PART_BONES: Array[String] = ["Hips", "Spine", "Head", "LeftArm", "LeftForeArm", "RightArm", "RightForeArm", "LeftUpLeg", "LeftLeg", "RightUpLeg", "RightLeg"]
## Joint at the far end of each limb segment.
const PART_TIPS: Array[String] = ["", "", "head_end", "LeftForeArm", "LeftHand", "RightForeArm", "RightHand", "LeftLeg", "LeftFoot", "RightLeg", "RightFoot"]

const WAIST := "Spine02"
const MID_SPINE := "Spine01"
const NECK := "neck"
const SKULL_TOP := "head_end"
const CLAVICLES: Array[String] = ["LeftShoulder", "RightShoulder"]
const HANDS: Array[String] = ["LeftHand", "RightHand"]
const FEET: Array[String] = ["LeftFoot", "RightFoot"]
const TOES: Array[String] = ["LeftToeBase", "RightToeBase"]

enum Extra { NONE, HEAD, NECK, CHEST, CLAVICLE_L, CLAVICLE_R, HAND_L, HAND_R, FOOT_L, FOOT_R }

## Metres a bone may be pulled off its parent to stay on its physics segment.
const MAX_STRETCH := 0.07
const SMOOTH_AWAKE := 38.0
const SMOOTH_LIMP := 70.0
const STARE_LIMIT := 0.5

## Height of the horn tips in the straight-legged rest pose, in metres.
@export_range(1.6, 3.0) var standing_height := 2.3

## Frames skipped because a body handed back a non-finite transform. Should stay 0.
var fault_frames := 0
## Largest gap this frame between a bone and the spot its segment wants it, in metres.
var alignment_error := 0.0

var _ragdoll: Ragdoll
var _model: Node3D
var _skeleton: Skeleton3D
var _mesh: MeshInstance3D
var _bodies: Array[RigidBody3D] = []
var _layout: Dictionary = {}
var _scale := 1.0

# Per bone, indexed by skeleton bone index.
var _order := PackedInt32Array()
var _parent := PackedInt32Array()
var _part_a := PackedInt32Array()
var _part_b := PackedInt32Array()
var _share_b := PackedFloat32Array()
var _anchored := PackedByteArray()
var _extra := PackedInt32Array()
var _canon_basis: Array[Basis] = []
var _canon_origin: Array[Vector3] = []
var _bind_basis: Array[Basis] = []
var _local_origin: Array[Vector3] = []
var _anchor_local: Array[Vector3] = []
var _smoothed: Array[Quaternion] = []
var _pose: Array[Transform3D] = []

var _body_basis: Array[Basis] = []
var _body_origin: Array[Vector3] = []
var _rest: Array = []
var _life := 1.0
var _time := 0.0
var _snap := true
var _twitch := Vector2.ZERO
var _twitch_target := Vector2.ZERO
var _twitch_left := 0.0
var _head_extra := Basis.IDENTITY


# --- Setup --------------------------------------------------------------------------

## Loads and measures the model. Returns the ragdoll layout, or {} when the model is unusable.
func prepare(ragdoll: Node3D) -> Dictionary:
	_ragdoll = ragdoll as Ragdoll
	var holder := ragdoll.get_node_or_null("Visuals") as Node3D
	if holder == null:
		holder = ragdoll
	_model = ModelLoader.instance(MODEL)
	_model.name = "Model"
	holder.add_child(_model)
	_skeleton = _find(_model, "Skeleton3D") as Skeleton3D
	_mesh = _find(_model, "MeshInstance3D") as MeshInstance3D
	if _skeleton == null or _mesh == null or _mesh.skin == null:
		return _reject("%s has no skinned mesh. Run tools/fetch_assets.py." % ModelLoader.resolve(MODEL))
	for required in get_required_bones():
		if _skeleton.find_bone(required) < 0:
			return _reject("%s has no bone named '%s'." % [ModelLoader.resolve(MODEL), required])
	# The file's only clip is a static T-pose; the ragdoll owns every bone from here on.
	for player in _model.find_children("*", "AnimationPlayer", true, false):
		player.free()
	_mesh.extra_cull_margin = 0.6

	var measured := _measure_mesh(_root_from_skeleton())
	_normalise(measured)
	_layout = _build_layout(measured)
	return _layout


## Stores the rest-pose offset between every bone and the body that drives it.
func bind(bodies: Array[RigidBody3D]) -> void:
	if _skeleton == null or _layout.is_empty():
		return
	_bodies = bodies
	_body_basis.resize(bodies.size())
	_body_origin.resize(bodies.size())
	for bone in _skeleton.get_bone_count():
		# The driving body has an identity basis at rest, so the offset is the canonical pose itself.
		_anchor_local[bone] = _canon_origin[bone] - (_rest[_part_a[bone]] as Vector3)
	_snap = true


func is_ready() -> bool:
	return _skeleton != null and not _bodies.is_empty()


## Every bone this script looks up by name.
func get_required_bones() -> PackedStringArray:
	var names := PackedStringArray([WAIST, MID_SPINE, NECK])
	for group: Array[String] in [PART_BONES, PART_TIPS, CLAVICLES, HANDS, FEET, TOES]:
		for bone_name in group:
			if not bone_name.is_empty() and not names.has(bone_name):
				names.append(bone_name)
	return names


## A node that rides the named bone. In the rest pose it sits at the bone with the ragdoll root's
## axes and unit scale, so children are placed in plain metres (-Z ahead, +Y up).
func make_attachment(bone_name: String, node_name: String) -> Node3D:
	var attachment := BoneAttachment3D.new()
	attachment.name = node_name
	_skeleton.add_child(attachment)
	attachment.bone_name = bone_name
	var rest := _root_from_skeleton() * _skeleton.get_bone_global_rest(_skeleton.find_bone(bone_name))
	var mount := Node3D.new()
	mount.name = "Mount"
	mount.transform = rest.affine_inverse() * Transform3D(Basis.IDENTITY, rest.origin)
	attachment.add_child(mount)
	return mount


func get_skeleton() -> Skeleton3D:
	return _skeleton


func get_mesh_instance() -> MeshInstance3D:
	return _mesh


func get_model() -> Node3D:
	return _model


## World metres per skeleton unit (the rig is authored in centimetres).
func get_unit_scale() -> float:
	return _scale


func get_bone_names() -> PackedStringArray:
	var names := PackedStringArray()
	if _skeleton:
		for bone in _skeleton.get_bone_count():
			names.append(_skeleton.get_bone_name(bone))
	return names


## Offset of a segment's bone from its body in the rest pose (body space, metres).
func get_bone_local_offset(part: int) -> Transform3D:
	var bone := _skeleton.find_bone(PART_BONES[part])
	return Transform3D(_canon_basis[bone], _anchor_local[bone])


## World transform a bone would have if the rest pose stood at the ragdoll's root.
func get_bind_transform(bone_name: String) -> Transform3D:
	var bone := _skeleton.find_bone(bone_name)
	return Transform3D(_bind_basis[bone], (_root_from_skeleton() * _skeleton.get_bone_global_rest(bone)).origin)


## Mesh vertices to the ragdoll root's space in the rest pose.
func get_bind_mesh_transform() -> Transform3D:
	var skin := _mesh.skin
	var bone := skin.get_bind_bone(0)
	if bone < 0:
		bone = _skeleton.find_bone(skin.get_bind_name(0))
	return _root_from_skeleton() * _skeleton.get_bone_global_rest(bone) * skin.get_bind_pose(0)


func get_bone_world_position(bone_name: String) -> Vector3:
	var bone := _skeleton.find_bone(bone_name)
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(bone).origin


## True when every bone pose is finite and no bone is mirrored or collapsed.
func is_pose_valid() -> bool:
	if _skeleton == null:
		return false
	for bone in _skeleton.get_bone_count():
		var pose := _skeleton.get_bone_global_pose(bone)
		if not (pose.origin.is_finite() and pose.basis.x.is_finite() and pose.basis.y.is_finite() and pose.basis.z.is_finite()):
			return false
		if pose.basis.determinant() < 0.5:
			return false
	return true


## Drops the smoothing history; call after the ragdoll is teleported.
func snap() -> void:
	_snap = true


func _reject(reason: String) -> Dictionary:
	push_error("DemonSkeletonDriver: " + reason)
	if _model:
		_model.queue_free()
	_model = null
	_skeleton = null
	_mesh = null
	return {}


func _root_from_skeleton() -> Transform3D:
	return _ragdoll.global_transform.affine_inverse() * _skeleton.global_transform


func _bone_position(space: Transform3D, bone_name: String) -> Vector3:
	return (space * _skeleton.get_bone_global_rest(_skeleton.find_bone(bone_name))).origin


## One pass over the skin: bounds of the bind pose, and how thick each limb is around its bone.
func _measure_mesh(space: Transform3D) -> Dictionary:
	var skin := _mesh.skin
	var bind_bone := PackedInt32Array()
	for bind in skin.get_bind_count():
		var bone := skin.get_bind_bone(bind)
		if bone < 0:
			bone = _skeleton.find_bone(skin.get_bind_name(bind))
		bind_bone.append(bone)
	var to_space := space * _skeleton.get_bone_global_rest(bind_bone[0]) * skin.get_bind_pose(0)

	# Axis of every bone whose thickness matters: bone index -> [from, direction, length].
	var axes: Dictionary = {}
	for part in range(Ragdoll.Part.UPPER_ARM_L, Ragdoll.Part.size()):
		var from := _bone_position(space, PART_BONES[part])
		var along := _bone_position(space, PART_TIPS[part]) - from
		axes[_skeleton.find_bone(PART_BONES[part])] = [from, along.normalized(), along.length()]
	var waist := _bone_position(space, WAIST)
	var chest_axis := _bone_position(space, NECK) - waist
	for spine: String in [WAIST, MID_SPINE, PART_BONES[Ragdoll.Part.TORSO]]:
		axes[_skeleton.find_bone(spine)] = [waist, chest_axis.normalized(), chest_axis.length()]
	var hand_bones := [_skeleton.find_bone(HANDS[0]), _skeleton.find_bone(HANDS[1])]
	for i in 2:
		var wrist := _bone_position(space, HANDS[i])
		var forearm := wrist - _bone_position(space, PART_BONES[Ragdoll.Part.LOWER_ARM_L + i * 2])
		axes[hand_bones[i]] = [wrist, forearm.normalized(), 0.0]

	var samples: Dictionary = {}
	for bone: int in axes:
		samples[bone] = PackedFloat32Array()
	var low := Vector3.ONE * INF
	var high := Vector3.ONE * -INF
	var vertex_count := 0
	for surface in _mesh.mesh.get_surface_count():
		var arrays := _mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if vertices.is_empty() or joints.is_empty():
			continue
		@warning_ignore("integer_division")
		var per := joints.size() / vertices.size()
		vertex_count += vertices.size()
		for v in vertices.size():
			var at := to_space * vertices[v]
			low = low.min(at)
			high = high.max(at)
			var best := 0
			for k in range(1, per):
				if weights[v * per + k] > weights[v * per + best]:
					best = k
			var bone := bind_bone[joints[v * per + best]]
			if not samples.has(bone):
				continue
			var axis: Array = axes[bone]
			var offset := at - (axis[0] as Vector3)
			var along := offset.dot(axis[1])
			if bone in hand_bones:
				# Hands are measured by how far they reach past the wrist.
				(samples[bone] as PackedFloat32Array).append(along)
			else:
				(samples[bone] as PackedFloat32Array).append((offset - (axis[1] as Vector3) * along).length())
	var typical: Dictionary = {}
	for bone: int in samples:
		var values: PackedFloat32Array = samples[bone]
		values.sort()
		var pick := 0.9 if bone in hand_bones else 0.5
		typical[_skeleton.get_bone_name(bone)] = values[int((values.size() - 1) * pick)] if not values.is_empty() else 0.0
	return {"low": low, "high": high, "vertices": vertex_count, "typical": typical}


## Scales, turns and seats the model so it faces -Z with its soles on y = 0 and its hips over the origin.
func _normalise(measured: Dictionary) -> void:
	var space := _root_from_skeleton()
	var ground: float = (measured["low"] as Vector3).y
	var top: float = (measured["high"] as Vector3).y
	# Straightening the bent rest-pose legs raises the hips a little.
	var lift := 0.0
	for i in 2:
		var hip := _bone_position(space, PART_BONES[Ragdoll.Part.UPPER_LEG_L + i * 2])
		var knee := _bone_position(space, PART_BONES[Ragdoll.Part.LOWER_LEG_L + i * 2])
		var ankle := _bone_position(space, FEET[i])
		lift += 0.5 * ((ankle.y - ground) + hip.distance_to(knee) + knee.distance_to(ankle) - (hip.y - ground))
	var facing := _bone_position(space, TOES[0]) + _bone_position(space, TOES[1]) - _bone_position(space, FEET[0]) - _bone_position(space, FEET[1])
	var turn := Basis(Vector3.UP, PI) if facing.z > 0.0 else Basis.IDENTITY
	var ratio := standing_height / maxf(0.1, top - ground + lift)
	var hips := turn * _bone_position(space, PART_BONES[Ragdoll.Part.PELVIS]) * ratio
	_model.transform = Transform3D(turn.scaled(Vector3.ONE * ratio), Vector3(-hips.x, (lift - ground) * ratio, -hips.z)) * _model.transform
	_scale = _root_from_skeleton().basis.get_scale().x
	measured["ratio"] = ratio


func _build_layout(measured: Dictionary) -> Dictionary:
	var space := _root_from_skeleton()
	var count := _skeleton.get_bone_count()
	_parent.resize(count)
	_part_a.resize(count)
	_part_b.resize(count)
	_share_b.resize(count)
	_anchored.resize(count)
	_extra.resize(count)
	_canon_basis.resize(count)
	_canon_origin.resize(count)
	_bind_basis.resize(count)
	_local_origin.resize(count)
	_anchor_local.resize(count)
	_smoothed.resize(count)
	_pose.resize(count)
	_order.clear()
	for bone in count:
		_parent[bone] = _skeleton.get_bone_parent(bone)
		_part_a[bone] = Ragdoll.Part.PELVIS
		_part_b[bone] = Ragdoll.Part.PELVIS
		_share_b[bone] = 0.0
		_anchored[bone] = 0
		_extra[bone] = Extra.NONE
		var rest := space * _skeleton.get_bone_global_rest(bone)
		_bind_basis[bone] = rest.basis.orthonormalized()
		_canon_basis[bone] = _bind_basis[bone]
		_canon_origin[bone] = rest.origin
		_local_origin[bone] = _skeleton.get_bone_rest(bone).origin
		_smoothed[bone] = Quaternion.IDENTITY
		_pose[bone] = _skeleton.get_bone_global_rest(bone)
	# Parents before children, whatever order the file lists them in.
	var placed := PackedByteArray()
	placed.resize(count)
	while _order.size() < count:
		for bone in count:
			if placed[bone] == 0 and (_parent[bone] < 0 or placed[_parent[bone]] == 1):
				placed[bone] = 1
				_order.append(bone)

	var ratio: float = measured["ratio"]
	var typical: Dictionary = measured["typical"]
	var rest_positions: Array = []
	var anchors: Array = []
	var lengths: Array = []
	var radii: Array = []
	rest_positions.resize(Ragdoll.Part.size())
	anchors.resize(Ragdoll.Part.size())
	lengths.resize(Ragdoll.Part.size())
	radii.resize(Ragdoll.Part.size())

	# Core: pelvis, chest and head keep the rest pose, hunch and all.
	var hips := _skeleton.find_bone(PART_BONES[Ragdoll.Part.PELVIS])
	var waist := _canon_origin[_skeleton.find_bone(WAIST)]
	var neck := _canon_origin[_skeleton.find_bone(NECK)]
	var skull := _canon_origin[_skeleton.find_bone(PART_BONES[Ragdoll.Part.HEAD])]
	var crown := _canon_origin[_skeleton.find_bone(SKULL_TOP)]
	var hip_l := _canon_origin[_skeleton.find_bone(PART_BONES[Ragdoll.Part.UPPER_LEG_L])]
	var hip_r := _canon_origin[_skeleton.find_bone(PART_BONES[Ragdoll.Part.UPPER_LEG_R])]
	rest_positions[Ragdoll.Part.PELVIS] = _canon_origin[hips]
	anchors[Ragdoll.Part.PELVIS] = _canon_origin[hips]
	lengths[Ragdoll.Part.PELVIS] = hip_l.distance_to(hip_r)
	radii[Ragdoll.Part.PELVIS] = clampf(0.5 * hip_l.distance_to(hip_r), 0.11, 0.17)
	rest_positions[Ragdoll.Part.TORSO] = (waist + neck) * 0.5
	anchors[Ragdoll.Part.TORSO] = waist
	lengths[Ragdoll.Part.TORSO] = waist.distance_to(neck)
	var girth := maxf(float(typical.get(WAIST, 0.0)), maxf(float(typical.get(MID_SPINE, 0.0)), float(typical.get(PART_BONES[Ragdoll.Part.TORSO], 0.0))))
	radii[Ragdoll.Part.TORSO] = clampf(girth * ratio * 0.9, 0.15, 0.21)
	rest_positions[Ragdoll.Part.HEAD] = (skull + crown) * 0.5
	anchors[Ragdoll.Part.HEAD] = neck
	radii[Ragdoll.Part.HEAD] = clampf(skull.distance_to(crown) * 0.5, 0.12, 0.18)
	lengths[Ragdoll.Part.HEAD] = float(radii[Ragdoll.Part.HEAD]) * 2.0
	_assign(hips, Ragdoll.Part.PELVIS, Ragdoll.Part.PELVIS, 0.0, true, Extra.NONE)
	_assign(_skeleton.find_bone(WAIST), Ragdoll.Part.PELVIS, Ragdoll.Part.TORSO, 0.5, false, Extra.NONE)
	_assign(_skeleton.find_bone(MID_SPINE), Ragdoll.Part.PELVIS, Ragdoll.Part.TORSO, 0.85, false, Extra.NONE)
	_assign(_skeleton.find_bone(PART_BONES[Ragdoll.Part.TORSO]), Ragdoll.Part.TORSO, Ragdoll.Part.TORSO, 0.0, true, Extra.CHEST)
	_assign(_skeleton.find_bone(NECK), Ragdoll.Part.TORSO, Ragdoll.Part.HEAD, 0.5, false, Extra.NECK)
	_assign(_skeleton.find_bone(PART_BONES[Ragdoll.Part.HEAD]), Ragdoll.Part.HEAD, Ragdoll.Part.HEAD, 0.0, true, Extra.HEAD)
	for bone in count:
		if _parent[bone] == _skeleton.find_bone(PART_BONES[Ragdoll.Part.HEAD]):
			_assign(bone, Ragdoll.Part.HEAD, Ragdoll.Part.HEAD, 0.0, false, Extra.NONE)

	# Limbs: re-posed to hang straight down, which is the pose the ragdoll's joint limits are written for.
	var hands: Array = []
	var feet: Array = []
	for i in 2:
		_assign(_skeleton.find_bone(CLAVICLES[i]), Ragdoll.Part.TORSO, Ragdoll.Part.TORSO, 0.0, false, Extra.CLAVICLE_L + i)
		var upper: int = Ragdoll.Part.UPPER_ARM_L + i * 2
		var lower: int = Ragdoll.Part.LOWER_ARM_L + i * 2
		var hand := _skeleton.find_bone(HANDS[i])
		var arm := _hang(upper, lower, hand)
		rest_positions[upper] = arm[0] + Vector3.DOWN * arm[1] * 0.5
		rest_positions[lower] = arm[0] + Vector3.DOWN * (arm[1] + arm[2] * 0.5)
		anchors[upper] = arm[0]
		anchors[lower] = arm[0] + Vector3.DOWN * arm[1]
		lengths[upper] = arm[1]
		lengths[lower] = arm[2]
		radii[upper] = clampf(float(typical.get(PART_BONES[upper], 0.06)) * ratio, 0.05, 0.085)
		radii[lower] = clampf(float(typical.get(PART_BONES[lower], 0.05)) * ratio, 0.045, 0.07)
		_assign(hand, lower, lower, 0.0, false, Extra.HAND_L + i)
		var reach := clampf(float(typical.get(HANDS[i], 0.2)) * ratio, 0.16, 0.36)
		var wrist := _canon_origin[hand]
		hands.append({"palm": wrist + Vector3.DOWN * reach * 0.4, "palm_radius": clampf(reach * 0.3, 0.055, 0.08),
				"claws": wrist + Vector3.DOWN * reach * 0.85, "claw_radius": 0.04})

		upper = Ragdoll.Part.UPPER_LEG_L + i * 2
		lower = Ragdoll.Part.LOWER_LEG_L + i * 2
		var foot := _skeleton.find_bone(FEET[i])
		var toe := _skeleton.find_bone(TOES[i])
		var toe_offset := _canon_origin[toe] - _canon_origin[foot]
		var leg := _hang(upper, lower, foot)
		rest_positions[upper] = leg[0] + Vector3.DOWN * leg[1] * 0.5
		rest_positions[lower] = leg[0] + Vector3.DOWN * (leg[1] + leg[2] * 0.5)
		anchors[upper] = leg[0]
		anchors[lower] = leg[0] + Vector3.DOWN * leg[1]
		lengths[upper] = leg[1]
		lengths[lower] = leg[2]
		radii[upper] = clampf(float(typical.get(PART_BONES[upper], 0.08)) * ratio, 0.065, 0.11)
		radii[lower] = clampf(float(typical.get(PART_BONES[lower], 0.06)) * ratio, 0.05, 0.085)
		_assign(foot, lower, lower, 0.0, false, Extra.FOOT_L + i)
		_canon_basis[toe] = _canon_basis[foot] * _bind_basis[foot].inverse() * _bind_basis[toe]
		_canon_origin[toe] = _canon_origin[foot] + _canon_basis[foot] * _bind_basis[foot].inverse() * toe_offset
		_assign(toe, lower, lower, 0.0, false, Extra.NONE)
		var ankle := _canon_origin[foot]
		# Kept just clear of the floor: the hover spring carries the weight, not the feet.
		feet.append({"heel": Vector3(ankle.x, 0.1, ankle.z), "heel_radius": 0.07,
				"toe": Vector3(_canon_origin[toe].x, 0.08, _canon_origin[toe].z), "toe_radius": 0.05})

	_rest = rest_positions
	var shoulder_l := _canon_origin[_skeleton.find_bone(PART_BONES[Ragdoll.Part.UPPER_ARM_L])]
	var shoulder_r := _canon_origin[_skeleton.find_bone(PART_BONES[Ragdoll.Part.UPPER_ARM_R])]
	var ankle_height := 0.5 * (_canon_origin[_skeleton.find_bone(FEET[0])].y + _canon_origin[_skeleton.find_bone(FEET[1])].y)
	return {
		"rest": rest_positions,
		"anchor": anchors,
		"length": lengths,
		"radius": radii,
		"chest": [waist, neck],
		"shoulders": [shoulder_l, shoulder_r],
		"shoulder_radius": clampf(float(radii[Ragdoll.Part.UPPER_ARM_L]) * 1.5, 0.09, 0.13),
		"hands": hands,
		"feet": feet,
		"ankle": ankle_height,
		"height": standing_height,
		"eye_height": skull.y + (crown.y - skull.y) * 0.35,
		"scale": ratio,
		"bones": count,
		"vertices": int(measured["vertices"]),
	}


func _assign(bone: int, part_a: int, part_b: int, share_b: float, anchored: bool, extra: int) -> void:
	_part_a[bone] = part_a
	_part_b[bone] = part_b
	_share_b[bone] = share_b
	_anchored[bone] = 1 if anchored else 0
	_extra[bone] = extra


## Re-poses a two-bone limb to hang straight down from its root joint.
## Returns [root joint, upper length, lower length] and fills the canonical pose of the three bones.
func _hang(upper_part: int, lower_part: int, tip: int) -> Array:
	var upper := _skeleton.find_bone(PART_BONES[upper_part])
	var lower := _skeleton.find_bone(PART_BONES[lower_part])
	var root := _canon_origin[upper]
	var joint := _canon_origin[lower]
	var end := _canon_origin[tip]
	var upper_length := root.distance_to(joint)
	var lower_length := joint.distance_to(end)
	# Shortest arcs keep each bone's natural roll, so the elbow and knee still fold the way the skin expects.
	var first := Basis(Quaternion((joint - root).normalized(), Vector3.DOWN))
	var second := Basis(Quaternion((first * (end - joint)).normalized(), Vector3.DOWN)) * first
	_canon_basis[upper] = first * _bind_basis[upper]
	_canon_basis[lower] = second * _bind_basis[lower]
	_canon_basis[tip] = second * _bind_basis[tip]
	_canon_origin[lower] = root + Vector3.DOWN * upper_length
	_canon_origin[tip] = _canon_origin[lower] + Vector3.DOWN * lower_length
	_assign(upper, upper_part, upper_part, 0.0, true, Extra.NONE)
	_assign(lower, lower_part, lower_part, 0.0, true, Extra.NONE)
	return [root, upper_length, lower_length]


func _find(node: Node, type: String) -> Node:
	if node.is_class(type):
		return node
	for child in node.get_children():
		var found := _find(child, type)
		if found:
			return found
	return null


# --- Driving --------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not is_ready():
		return
	for part in _bodies.size():
		var xf := _bodies[part].global_transform
		if not (xf.origin.is_finite() and xf.basis.x.is_finite() and xf.basis.y.is_finite() and xf.basis.z.is_finite()):
			# Keep the last good pose; the ragdoll's safety net rebuilds the bodies.
			fault_frames += 1
			return
		_body_origin[part] = xf.origin
		_body_basis[part] = xf.basis.orthonormalized()
	_time += delta
	var stunned := _ragdoll.is_stunned
	_life = move_toward(_life, 0.0 if stunned else 1.0, delta * (8.0 if stunned else 1.5))
	_roll_twitch(delta)
	_head_extra = _stare()

	var skeleton_xf := _skeleton.global_transform
	var to_skeleton := skeleton_xf.affine_inverse()
	var unturn := skeleton_xf.basis.orthonormalized().inverse()
	var blend := 1.0 if _snap else 1.0 - exp(-delta * lerpf(SMOOTH_LIMP, SMOOTH_AWAKE, _life))
	var stretch := MAX_STRETCH / _scale
	var worst := 0.0
	for bone in _order:
		var target := _target_basis(bone)
		var wanted := (unturn * target).get_rotation_quaternion()
		var rotation := wanted if _snap else _smoothed[bone].slerp(wanted, blend)
		_smoothed[bone] = rotation
		var parent := _parent[bone]
		var origin := _local_origin[bone] if parent < 0 else _pose[parent] * _local_origin[bone]
		if _anchored[bone] == 1:
			var pinned := to_skeleton * (_body_origin[_part_a[bone]] + _body_basis[_part_a[bone]] * _anchor_local[bone])
			var gap := pinned - origin
			# The hips carry the whole figure; every other joint may only give a little.
			if parent < 0:
				origin = pinned
			else:
				worst = maxf(worst, gap.length() * _scale)
				origin += gap.limit_length(stretch)
		var pose := Transform3D(Basis(rotation), origin)
		_pose[bone] = pose
		var local := pose if parent < 0 else _pose[parent].affine_inverse() * pose
		_skeleton.set_bone_pose_position(bone, local.origin)
		_skeleton.set_bone_pose_rotation(bone, local.basis.get_rotation_quaternion())
	alignment_error = worst
	_snap = false


## World-space orientation a bone should have this frame.
func _target_basis(bone: int) -> Basis:
	var basis := _body_basis[_part_a[bone]] * _canon_basis[bone]
	if _share_b[bone] > 0.0:
		var other := _body_basis[_part_b[bone]] * _canon_basis[bone]
		basis = Basis(basis.get_rotation_quaternion().slerp(other.get_rotation_quaternion(), _share_b[bone]))
	if _life <= 0.001:
		return basis
	match _extra[bone]:
		Extra.HEAD:
			basis = _head_extra * basis
		Extra.NECK:
			basis = Basis(Quaternion.IDENTITY.slerp(_head_extra.get_rotation_quaternion(), 0.5)) * basis
		Extra.CHEST:
			# Slow, shallow breathing that quickens with the chase.
			var rate := 5.0 if _ragdoll.pose == Ragdoll.Pose.CHASE else 1.7
			basis = Basis(_body_basis[Ragdoll.Part.TORSO].x, sin(_time * rate) * 0.03 * _life) * basis
		Extra.CLAVICLE_L, Extra.CLAVICLE_R:
			basis = _shrug(-1.0 if _extra[bone] == Extra.CLAVICLE_L else 1.0) * basis
		Extra.HAND_L, Extra.HAND_R:
			basis = _claw(_extra[bone] - Extra.HAND_L) * basis
		Extra.FOOT_L, Extra.FOOT_R:
			if _ragdoll.is_grounded():
				# Soles stay level with the floor instead of rocking with the shin.
				var flat := Basis(Vector3.UP, _body_basis[Ragdoll.Part.PELVIS].get_euler().y) * _bind_basis[bone]
				basis = Basis(basis.get_rotation_quaternion().slerp(flat.get_rotation_quaternion(), 0.8 * _life))
	return basis


## Finishes the turn of the head toward whatever the demon is watching, plus a nervous tilt.
func _stare() -> Basis:
	var head := _body_basis[Ragdoll.Part.HEAD]
	var extra := Basis.IDENTITY
	if _ragdoll.has_look_target:
		var to := _ragdoll.look_target - _body_origin[Ragdoll.Part.HEAD]
		if to.length_squared() > 0.04:
			var arc := Quaternion(head * Vector3.FORWARD, to.normalized())
			var angle := arc.get_angle()
			if angle > 0.002 and arc.get_axis().is_finite():
				extra = Basis(arc.get_axis().normalized(), minf(angle, STARE_LIMIT) * _life)
	return extra * Basis(head.z, _twitch.x * 0.24 * _life) * Basis(head.y, _twitch.y * 0.12 * _life)


## Shoulders roll forward and up into a predatory hunch; `side` is -1 left, +1 right.
func _shrug(side: float) -> Basis:
	var forward := 0.06
	var raise := 0.03
	match _ragdoll.pose:
		Ragdoll.Pose.STALK:
			forward = 0.16 + sin(_time * 1.3 + side) * 0.03
			raise = 0.08
		Ragdoll.Pose.CHASE:
			forward = 0.22 + sin(_time * 7.0 + side * 1.6) * 0.06
			raise = 0.12
		Ragdoll.Pose.CAST:
			forward = -0.08
			raise = 0.2
		Ragdoll.Pose.FREEZE:
			forward = 0.2
			raise = 0.16
	var chest := _body_basis[Ragdoll.Part.TORSO]
	return Basis(chest.y, side * forward * _life) * Basis(chest.x, -raise * _life)


## Wrist flex: claws dangle while it lurks, splay open as it reaches, and rake through a swipe.
func _claw(arm: int) -> Basis:
	var flex := 0.25 + sin(_time * 0.9 + arm * 2.0) * 0.06
	var splay := 0.0
	match _ragdoll.pose:
		Ragdoll.Pose.STALK:
			flex = -0.22 + sin(_time * 9.0 + arm * 1.7) * 0.05 + _twitch.y * 0.12
			splay = 0.1
		Ragdoll.Pose.CHASE:
			flex = -0.4 + sin(_time * 13.0 + arm * 2.3) * 0.12
			splay = 0.18
		Ragdoll.Pose.CAST:
			flex = -0.6 + sin(_time * 29.0 + arm) * 0.04
			splay = 0.25
		Ragdoll.Pose.FREEZE:
			flex = 0.35
	if _ragdoll.is_swiping():
		flex = 0.55
	var forearm := _body_basis[Ragdoll.Part.LOWER_ARM_L + arm * 2]
	var side := -1.0 if arm == 0 else 1.0
	return Basis(forearm.x, flex * _life) * Basis(forearm.z, side * splay * _life)


## Sample-and-hold jerks: rare while it lurks, constant while it hunts.
func _roll_twitch(delta: float) -> void:
	var busy := _ragdoll.pose == Ragdoll.Pose.CHASE or _ragdoll.pose == Ragdoll.Pose.FREEZE or _ragdoll.pose == Ragdoll.Pose.CAST
	_twitch_left -= delta
	if _twitch_left <= 0.0:
		_twitch_left = randf_range(0.07, 0.3) if busy else randf_range(0.5, 2.4)
		var sharp := 1.0 if randf() < (0.75 if busy else 0.4) else 0.15
		_twitch_target = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * sharp
	_twitch = _twitch.lerp(_twitch_target, 1.0 - exp(-delta * 26.0))
