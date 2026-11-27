extends Node3D
## Procedural stylized exorcist: hazmat jacket, gas mask with glowing visor
## eyes, hardhat with headlamp, backpack rig and jointed arms and legs.
## Built entirely from primitive meshes and animated in code (walk cycle,
## sprint lean, crouch, airborne tuck and reaching for a grabbed prop).
## The model faces -Z with its feet on the node's origin.

const Mats := preload("res://scripts/MaterialLibrary.gd")

enum Suit { ORANGE, TEAL, OLIVE }

const SUIT_COLORS: Array[Color] = [Color(0.95, 0.40, 0.07), Color(0.04, 0.58, 0.56), Color(0.40, 0.45, 0.18)]
const VISOR_COLORS: Array[Color] = [Color(0.25, 1.0, 0.85), Color(1.0, 0.72, 0.18), Color(1.0, 0.32, 0.16)]

const HIP_HEIGHT := 0.9
const THIGH_LENGTH := 0.42
const SHIN_LENGTH := 0.42
const UPPER_ARM_LENGTH := 0.3
const FOREARM_LENGTH := 0.3
const SHOULDER_OFFSET := Vector3(0.3, 0.5, 0.0)

@export var suit: Suit = Suit.ORANGE

var _pelvis: Node3D
var _torso: Node3D
var _head: Node3D
var _shoulders: Array[Node3D] = []
var _elbows: Array[Node3D] = []
var _hips: Array[Node3D] = []
var _knees: Array[Node3D] = []
var _lamp_lens: MeshInstance3D
var _meshes: Array[MeshInstance3D] = []

var _suit_material := StandardMaterial3D.new()
var _suit_trim_material := StandardMaterial3D.new()
var _visor_material := StandardMaterial3D.new()
var _lamp_material := StandardMaterial3D.new()
var _led_material := StandardMaterial3D.new()

var _speed := 0.0
var _on_floor := true
var _crouch := 0.0
var _sprinting := false
var _pitch := 0.0
var _phase := 0.0
var _air := 0.0
var _clock := 0.0
var _reach_weight := 0.0
var _reaching := false
var _reach_target := Vector3.ZERO


func _ready() -> void:
	_build()
	apply_suit(suit)
	set_headlamp(false)


## Recolours the jacket and visor. Index wraps, so any player number is valid.
func apply_suit(index: int) -> void:
	suit = posmod(index, SUIT_COLORS.size()) as Suit
	var color := SUIT_COLORS[suit]
	_suit_material.albedo_color = color
	_suit_material.roughness = 0.62
	_suit_trim_material.albedo_color = color.darkened(0.45)
	_suit_trim_material.roughness = 0.7
	var visor := VISOR_COLORS[suit]
	_visor_material.albedo_color = visor
	_visor_material.emission_enabled = true
	_visor_material.emission = visor
	_visor_material.emission_energy_multiplier = 3.2


## Fed by the player controller every frame.
func set_motion(horizontal_speed: float, on_floor: bool, crouch: float, sprinting: bool) -> void:
	_speed = horizontal_speed
	_on_floor = on_floor
	_crouch = crouch
	_sprinting = sprinting


func set_look_pitch(pitch: float) -> void:
	_pitch = pitch


## While `active`, both arms stretch toward `global_target` (the grab point).
func set_reach(active: bool, global_target: Vector3 = Vector3.ZERO) -> void:
	_reaching = active
	if active:
		_reach_target = global_target


## In first person the whole body is hidden, so the camera never looks out
## through its own head and the headlamp casts no self-shadow.
func set_first_person(enabled: bool) -> void:
	for mesh in _meshes:
		mesh.visible = not enabled


## World position of the hardhat lamp lens; the player's torch shines from here.
func get_headlamp_position() -> Vector3:
	return _lamp_lens.global_position


## World position of the right glove; the grab tether starts here in third person.
func get_hand_position() -> Vector3:
	return _elbows[1].global_transform * Vector3(0.0, -FOREARM_LENGTH - 0.08, 0.0)


func set_headlamp(on: bool) -> void:
	_lamp_material.albedo_color = Color(1.0, 0.96, 0.85)
	_lamp_material.emission_enabled = true
	_lamp_material.emission = Color(1.0, 0.95, 0.8)
	_lamp_material.emission_energy_multiplier = 5.0 if on else 0.05


func _process(delta: float) -> void:
	_clock += delta
	var stride := clampf(_speed / 4.4, 0.0, 1.5)
	var moving := _speed > 0.2 and _on_floor
	if moving:
		_phase += delta * (4.2 + _speed * 1.9)
	else:
		# Ease back to a neutral stance instead of freezing mid-step.
		_phase = lerp_angle(_phase, roundf(_phase / PI) * PI, minf(1.0, delta * 8.0))
	_air = move_toward(_air, 0.0 if _on_floor else 1.0, delta * 6.0)
	_reach_weight = move_toward(_reach_weight, 1.0 if _reaching else 0.0, delta * 7.0)
	var gait := stride if moving else 0.0

	# Crouch folds the legs so the feet stay planted under the hips.
	var hip_bend := _crouch * 0.96
	var bob := absf(cos(_phase)) * 0.035 * gait
	_pelvis.position.y = HIP_HEIGHT - (THIGH_LENGTH + SHIN_LENGTH) * (1.0 - cos(hip_bend)) + bob

	var breathing := sin(_clock * 1.7) * 0.012
	var lean := 0.05 * gait + (0.2 if _sprinting else 0.0) + 0.32 * _crouch
	_torso.rotation.x = lerpf(_torso.rotation.x, -lean, minf(1.0, delta * 10.0))
	_torso.rotation.y = sin(_phase) * 0.09 * gait
	_torso.scale = Vector3(1.0, 1.0 + breathing, 1.0)
	# Cancel the torso lean so the mask points wherever the camera is looking.
	_head.rotation.x = clampf(_pitch, -1.0, 1.0) - _torso.rotation.x

	for i in 2:
		var cycle := _phase + (0.0 if i == 0 else PI)
		var swing := sin(cycle) * 0.62 * minf(gait, 1.25)
		_hips[i].rotation.x = hip_bend + swing + _air * 0.45
		_knees[i].rotation.x = -2.0 * hip_bend - maxf(0.0, cos(cycle)) * 0.85 * minf(gait, 1.25) - _air * 0.9

		var side := -1.0 if i == 0 else 1.0
		var rest := Quaternion.from_euler(Vector3(-swing * 0.75 - _air * 0.5, 0.0, side * (0.07 + _air * 0.35)))
		var pose := rest
		if _reach_weight > 0.001:
			var local_target := _torso.global_transform.affine_inverse() * _reach_target
			var direction := (local_target - _shoulders[i].position).normalized()
			if direction.dot(Vector3.DOWN) > -0.98:
				pose = rest.slerp(Quaternion(Vector3.DOWN, direction), _reach_weight)
		_shoulders[i].quaternion = pose
		_elbows[i].rotation.x = lerpf(0.22 + 0.4 * minf(gait, 1.0) + _air * 0.6, 0.1, _reach_weight)

	# Backpack status LED: a slow green heartbeat.
	_led_material.emission_energy_multiplier = 4.0 if fmod(_clock, 1.4) < 0.12 else 0.15


func _build() -> void:
	var rubber := Mats.rubber()
	var overalls := Mats.solid(Color(0.16, 0.18, 0.21), 0.85)
	var reflective := Mats.glow(Color(0.85, 0.88, 0.80), 0.35)
	var steel := Mats.metal_bare()
	var dark := Mats.metal_dark()
	var hat := Mats.solid(Color(0.95, 0.78, 0.08), 0.45)
	_led_material.albedo_color = Color(0.2, 1.0, 0.3)
	_led_material.emission_enabled = true
	_led_material.emission = Color(0.2, 1.0, 0.3)

	_pelvis = _joint(self, Vector3(0.0, HIP_HEIGHT, 0.0), "Pelvis")
	_torso = _joint(_pelvis, Vector3.ZERO, "Torso")

	# Hazmat jacket with hi-vis bands, zip, belt and collar.
	_box(_torso, Vector3(0.5, 0.54, 0.3), Vector3(0.0, 0.29, 0.0), _suit_material)
	_box(_torso, Vector3(0.53, 0.16, 0.33), Vector3(0.0, 0.05, 0.0), _suit_trim_material)
	_box(_torso, Vector3(0.54, 0.07, 0.34), Vector3(0.0, 0.1, 0.0), rubber)
	_box(_torso, Vector3(0.09, 0.05, 0.02), Vector3(0.0, 0.1, -0.17), steel)
	for band_y: float in [0.24, 0.4]:
		_box(_torso, Vector3(0.508, 0.04, 0.308), Vector3(0.0, band_y, 0.0), reflective)
	_box(_torso, Vector3(0.025, 0.42, 0.01), Vector3(0.0, 0.33, -0.152), dark)
	_box(_torso, Vector3(0.32, 0.09, 0.28), Vector3(0.0, 0.58, 0.0), _suit_trim_material)
	_box(_torso, Vector3(0.1, 0.07, 0.03), Vector3(0.14, 0.42, -0.16), dark)
	_box(_torso, Vector3(0.02, 0.02, 0.01), Vector3(0.17, 0.44, -0.176), _led_material)

	# Backpack rig: pack, twin holy-water tanks, hose and whip antenna.
	_box(_torso, Vector3(0.38, 0.46, 0.18), Vector3(0.0, 0.32, 0.24), overalls)
	_box(_torso, Vector3(0.3, 0.1, 0.2), Vector3(0.0, 0.58, 0.24), dark)
	for tank_x: float in [-0.1, 0.1]:
		_cylinder(_torso, 0.07, 0.07, 0.42, Vector3(tank_x, 0.33, 0.37), Mats.solid(Color(0.78, 0.68, 0.14), 0.4, 0.5))
		_cylinder(_torso, 0.03, 0.05, 0.05, Vector3(tank_x, 0.565, 0.37), steel)
	_box(_torso, Vector3(0.03, 0.03, 0.22), Vector3(0.21, 0.5, 0.14), rubber)
	_cylinder(_torso, 0.006, 0.008, 0.5, Vector3(-0.16, 0.86, 0.26), dark)
	_box(_torso, Vector3(0.03, 0.03, 0.012), Vector3(0.12, 0.6, 0.345), _led_material)

	# Head: hood, gas mask with glowing lenses and filter cans, hardhat with lamp.
	_head = _joint(_torso, Vector3(0.0, 0.62, 0.0), "Head")
	_sphere(_head, 0.17, Vector3(0.0, 0.1, 0.0), _suit_material)
	_box(_head, Vector3(0.24, 0.2, 0.12), Vector3(0.0, 0.07, -0.12), rubber)
	for eye_x: float in [-0.062, 0.062]:
		var rim := _cylinder(_head, 0.055, 0.055, 0.04, Vector3(eye_x, 0.115, -0.175), dark)
		rim.rotation.x = PI * 0.5
		var lens := _cylinder(_head, 0.043, 0.043, 0.045, Vector3(eye_x, 0.115, -0.18), _visor_material)
		lens.rotation.x = PI * 0.5
	var snout := _cylinder(_head, 0.05, 0.06, 0.09, Vector3(0.0, 0.0, -0.21), dark)
	snout.rotation.x = PI * 0.5
	for can_x: float in [-0.14, 0.14]:
		var can := _cylinder(_head, 0.05, 0.05, 0.07, Vector3(can_x, 0.0, -0.13), steel)
		can.rotation.z = PI * 0.5
	var dome := SphereMesh.new()
	dome.radius = 0.2
	dome.height = 0.2
	dome.is_hemisphere = true
	dome.radial_segments = 20
	dome.rings = 8
	_part(_head, dome, Vector3(0.0, 0.19, 0.0), hat)
	_cylinder(_head, 0.24, 0.24, 0.02, Vector3(0.0, 0.2, -0.02), hat)
	_box(_head, Vector3(0.04, 0.03, 0.36), Vector3(0.0, 0.39, 0.0), hat)
	_box(_head, Vector3(0.09, 0.07, 0.1), Vector3(0.0, 0.29, -0.2), dark)
	_lamp_lens = _box(_head, Vector3(0.06, 0.045, 0.01), Vector3(0.0, 0.29, -0.252), _lamp_material)

	# Arms: shoulder -> upper arm -> elbow -> forearm -> glove.
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var shoulder := _joint(_torso, Vector3(side * SHOULDER_OFFSET.x, SHOULDER_OFFSET.y, 0.0), "ShoulderL" if i == 0 else "ShoulderR")
		_sphere(shoulder, 0.09, Vector3.ZERO, _suit_material)
		_box(shoulder, Vector3(0.13, UPPER_ARM_LENGTH, 0.14), Vector3(0.0, -UPPER_ARM_LENGTH * 0.5, 0.0), _suit_material)
		var elbow := _joint(shoulder, Vector3(0.0, -UPPER_ARM_LENGTH, 0.0), "Elbow")
		_sphere(elbow, 0.07, Vector3.ZERO, _suit_trim_material)
		_box(elbow, Vector3(0.115, FOREARM_LENGTH, 0.125), Vector3(0.0, -FOREARM_LENGTH * 0.5, 0.0), _suit_material)
		_box(elbow, Vector3(0.12, 0.035, 0.13), Vector3(0.0, -FOREARM_LENGTH + 0.07, 0.0), reflective)
		_box(elbow, Vector3(0.11, 0.13, 0.12), Vector3(0.0, -FOREARM_LENGTH - 0.04, 0.0), rubber)
		_shoulders.append(shoulder)
		_elbows.append(elbow)

	# Legs: hip -> thigh -> knee -> shin -> boot.
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hip := _joint(_pelvis, Vector3(side * 0.125, 0.0, 0.0), "HipL" if i == 0 else "HipR")
		_box(hip, Vector3(0.18, THIGH_LENGTH, 0.2), Vector3(0.0, -THIGH_LENGTH * 0.5, 0.0), overalls)
		var knee := _joint(hip, Vector3(0.0, -THIGH_LENGTH, 0.0), "Knee")
		_box(knee, Vector3(0.16, 0.08, 0.2), Vector3(0.0, 0.0, -0.02), rubber)
		_box(knee, Vector3(0.155, SHIN_LENGTH - 0.1, 0.17), Vector3(0.0, -(SHIN_LENGTH - 0.1) * 0.5, 0.0), overalls)
		_box(knee, Vector3(0.18, 0.14, 0.3), Vector3(0.0, -SHIN_LENGTH + 0.07, -0.05), rubber)
		_box(knee, Vector3(0.182, 0.03, 0.302), Vector3(0.0, -SHIN_LENGTH + 0.125, -0.05), hat)
		_hips.append(hip)
		_knees.append(knee)


func _joint(parent: Node3D, at: Vector3, joint_name: String) -> Node3D:
	var joint := Node3D.new()
	joint.name = joint_name
	joint.position = at
	parent.add_child(joint)
	return joint


func _part(parent: Node3D, mesh: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	parent.add_child(instance)
	_meshes.append(instance)
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
	mesh.radial_segments = 12
	mesh.rings = 1
	return _part(parent, mesh, at, material)
