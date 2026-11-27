extends CharacterBody3D
## Exorcist player controller.
##
## Movement: WASD, Shift sprint (stamina), Space jump, Ctrl crouch.
## Camera:   mouse look, V toggles first / third person, T toggles the headlamp.
## Knockdown: a fast flying prop or a demon swipe floors the player for a couple
##           of seconds: the view drops and rolls, they slide, drop what they hold.
## Hands:    hold LMB / E to grab a RigidBody3D with a spring-damped pull (the
##           body is never frozen, so it swings, snags on doorframes and feels
##           its weight), RMB to throw, F to use doors.

signal stamina_changed(current: float, maximum: float)
signal aim_changed(kind: int, prompt: String)
signal held_changed(body: RigidBody3D)
signal camera_mode_changed(first_person: bool)
signal flashlight_toggled(enabled: bool)
signal knocked_down(duration: float)
signal recovered

enum AimKind { NONE, GRABBABLE, INTERACTABLE, HOLDING }

const ExorcistModel := preload("res://scripts/ExorcistModel.gd")

const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.15
const STAND_EYE := 1.62
const CROUCH_EYE := 1.0
const COYOTE_TIME := 0.12
const JUMP_BUFFER := 0.12
const AIM_MASK := 1 | 4 | 8 | 16  # world occludes; props, interactables and demon limbs are targets
## Eye height while lying on the floor after a knockdown.
const KNOCK_EYE := 0.38
## Deceleration of a knocked-down player sliding across the floor.
const KNOCK_SLIDE := 6.0

@export_group("Movement")
@export var walk_speed := 4.4
@export var sprint_speed := 7.2
@export var crouch_speed := 2.3
@export var ground_acceleration := 34.0
@export var ground_deceleration := 28.0
@export var air_acceleration := 7.0
@export var jump_velocity := 5.6
@export var gravity_scale := 1.35
## Heaviest prop that takes on the player's full speed when walked into.
@export var push_mass_limit := 9.0
@export var push_strength := 0.9
## Newtons the body can lean into something that resists (furniture, door leaves).
@export var max_push_force := 450.0

@export_group("Stamina")
@export var max_stamina := 100.0
@export var sprint_drain := 24.0
@export var stamina_regen := 16.0
@export var regen_delay := 0.9
## After hitting zero, sprint stays locked until stamina climbs back to this.
@export var recover_threshold := 22.0

@export_group("Camera")
@export var mouse_sensitivity := 0.0023
@export var third_person_distance := 3.1
@export var shoulder_offset := Vector3(0.7, 0.1, 0.0)
@export var start_in_first_person := false

@export_group("Grab")
@export var grab_range := 3.2
@export var hold_distance_min := 1.15
@export var hold_distance_max := 2.3
## 1/s: how fast the grab point is asked to close the gap to the hands.
@export var pull_stiffness := 10.0
## 1/s: how hard velocity error is corrected (the damping half of the spring).
@export var pull_response := 12.0
@export var max_pull_speed := 9.0
## Newtons of pull available. Heavy props sag, lag and have to be dragged.
@export var max_pull_force := 420.0
## The grip breaks if the prop is wedged this far from the hands.
@export var break_distance := 2.6
@export var held_angular_damp := 5.0
## N*s cap: light props fly at `throw_speed`, furniture only gets a shove.
@export var throw_impulse := 62.0
@export var throw_speed := 13.0

@export_group("Flashlight")
@export var flashlight_energy := 9.0
@export var flashlight_range := 24.0

@export_group("Knockdown")
## A flying prop closing faster than this (m/s) floors the player.
@export var knock_impact_speed := 6.5
@export var knock_time_min := 1.6
@export var knock_time_max := 2.2
## Seconds after getting back up during which nothing can knock the player down again.
@export var knock_immunity := 2.0

var stamina := 100.0
var first_person := false
var flashlight_on := true

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _pitch := 0.0
var _crouch := 0.0
var _camera_blend := 1.0
var _sprinting := false
var _exhausted := false
var _regen_wait := 0.0
var _coyote := 0.0
var _jump_buffer := 0.0
var _capsule: CapsuleShape3D

var _aim_origin := Vector3.ZERO
var _aim_forward := Vector3.FORWARD
var _aim_kind := AimKind.NONE
var _aim_prompt := ""
var _aim_body: RigidBody3D
var _aim_point := Vector3.ZERO
var _aim_interactable: Node

var _held: RigidBody3D
var _holding := false
var _held_local_point := Vector3.ZERO
var _held_angular_damp := 0.0
var _hold_distance := 1.6
var _grab_locked := false
var _released: Array[Dictionary] = []
var _shoulder_clearance := INF
var _model_hidden := false
var _tether: MeshInstance3D
var _tether_mesh: ImmediateMesh
var _tether_ring: MeshInstance3D
var _tether_material: StandardMaterial3D
var _held_strain := 0.0
var _held_demon: Node
var _carry_mass := 0.0
var _pull_mass := 0.0
var _pull_cap := 0.0
var _eye_height := STAND_EYE
var _knock_left := 0.0
var _knock_blend := 0.0
var _knock_roll := 1.0
var _immune_left := 0.0
var _trauma := 0.0
var _shake_clock := 0.0
var _hit_sensor: Area3D

@onready var _collision: CollisionShape3D = $CollisionShape3D
@onready var _model: ExorcistModel = $Model
@onready var _head: Node3D = $Head
@onready var _arm: SpringArm3D = $Head/SpringArm3D
@onready var _camera: Camera3D = $Head/SpringArm3D/Camera3D
@onready var _flashlight: SpotLight3D = $Head/Flashlight


func _ready() -> void:
	add_to_group(GameState.GROUP_PLAYER)
	collision_layer = GameState.LAYER_PLAYER
	collision_mask = GameState.LAYER_WORLD | GameState.LAYER_PROP | GameState.LAYER_INTERACT | GameState.LAYER_DEMON
	floor_snap_length = 0.35
	floor_max_angle = deg_to_rad(46.0)
	floor_constant_speed = true
	# Each player crouches independently, so never share the scene's capsule.
	_capsule = _collision.shape.duplicate() as CapsuleShape3D
	_collision.shape = _capsule
	_arm.add_excluded_object(get_rid())
	_configure_flashlight()
	_add_suit_glow()
	_build_tether()
	_build_hit_sensor()
	# The tether follows the hands, so it is redrawn once their final pose is known.
	_model.pose_updated.connect(_update_tether)
	stamina = max_stamina
	first_person = start_in_first_person
	_camera_blend = 0.0 if first_person else 1.0
	_model_hidden = first_person
	_model.set_first_person(first_person)
	_update_camera_rig(1.0)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	stamina_changed.emit(stamina, max_stamina)


func _exit_tree() -> void:
	_release_held()


## Chooses the hazmat colourway (0 orange, 1 teal, 2 olive, 3 purple; wraps).
func set_suit(index: int) -> void:
	_model.apply_suit(index)


func get_held() -> RigidBody3D:
	return _held if _holding and is_instance_valid(_held) else null


func get_camera() -> Camera3D:
	return _camera


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			var motion := event as InputEventMouseMotion
			rotate_y(-motion.relative.x * mouse_sensitivity)
			_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -1.45, 1.45)
		return
	if event.is_action_pressed(&"ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# This click only recaptures the cursor; it must not also start a grab.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_grab_locked = true
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"toggle_camera"):
		set_first_person(not first_person)
	elif event.is_action_pressed(&"toggle_flashlight"):
		set_flashlight(not flashlight_on)
	elif event.is_action_pressed(&"interact"):
		_try_interact()
	elif event.is_action_pressed(&"throw"):
		_throw_held()


func set_first_person(enabled: bool) -> void:
	if first_person == enabled:
		return
	first_person = enabled
	camera_mode_changed.emit(first_person)


func set_flashlight(enabled: bool) -> void:
	flashlight_on = enabled
	_flashlight.visible = enabled
	_model.set_headlamp(enabled)
	flashlight_toggled.emit(enabled)


func _physics_process(delta: float) -> void:
	_update_knockdown(delta)
	# Flat on the floor there is no steering.
	var input := Vector2.ZERO if _knock_left > 0.0 else Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	_refresh_grab_tuning()
	_update_crouch(delta)
	_update_stamina(delta, input)
	_move(delta, input)
	_probe_shoulder()
	_update_aim()
	_update_grab(delta)
	_expire_released(delta)
	_check_prop_impacts()
	_publish_aim()

	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var backward := velocity.dot(global_transform.basis.z) > 0.5
	_model.set_motion(horizontal_speed, is_on_floor(), _crouch, _sprinting, backward)
	_model.set_look_pitch(_pitch)
	if _holding and is_instance_valid(_held):
		_model.set_reach(true, _held.global_transform * _held_local_point)
	else:
		_model.set_reach(false)


func _process(delta: float) -> void:
	_update_camera_rig(delta)


# --- Locomotion -------------------------------------------------------------

func _update_crouch(delta: float) -> void:
	var wants := Input.is_action_pressed(&"crouch") or _knock_left > 0.0
	if not wants and _crouch > 0.0:
		# Stay down while there is no headroom to stand back up.
		var headroom := STAND_HEIGHT - _capsule.height + 0.02
		if test_move(global_transform, Vector3.UP * headroom):
			wants = true
	_crouch = move_toward(_crouch, 1.0 if wants else 0.0, delta * 7.0)
	var height := lerpf(STAND_HEIGHT, CROUCH_HEIGHT, _crouch)
	_capsule.height = height
	_collision.position.y = height * 0.5
	_eye_height = lerpf(STAND_EYE, CROUCH_EYE, _crouch)


func _update_stamina(delta: float, input: Vector2) -> void:
	var wants := Input.is_action_pressed(&"sprint") and input.length() > 0.1 and input.y < 0.3
	_sprinting = wants and not _exhausted and stamina > 0.0 and _crouch < 0.3 and is_on_floor()
	var before := stamina
	if _sprinting:
		stamina = maxf(0.0, stamina - sprint_drain * delta)
		_regen_wait = regen_delay
		if stamina <= 0.0:
			_exhausted = true
	else:
		_regen_wait = maxf(0.0, _regen_wait - delta)
		if _regen_wait <= 0.0:
			stamina = minf(max_stamina, stamina + stamina_regen * delta)
		if _exhausted and stamina >= recover_threshold:
			_exhausted = false
	if not is_equal_approx(before, stamina):
		stamina_changed.emit(stamina, max_stamina)


func _move(delta: float, input: Vector2) -> void:
	var on_floor := is_on_floor()
	_coyote = COYOTE_TIME if on_floor else maxf(0.0, _coyote - delta)
	_jump_buffer = JUMP_BUFFER if Input.is_action_just_pressed(&"jump") and _knock_left <= 0.0 else maxf(0.0, _jump_buffer - delta)

	var speed := walk_speed
	if _crouch > 0.5:
		speed = crouch_speed
	elif _sprinting:
		speed = sprint_speed
	if _holding and is_instance_valid(_held):
		# Hauling something heavy slows the carrier down.
		speed *= clampf(1.0 - (_carry_mass - 6.0) / 70.0, 0.55, 1.0)

	var wish := (global_transform.basis * Vector3(input.x, 0.0, input.y))
	wish.y = 0.0
	wish = wish.limit_length(1.0)
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var rate := air_acceleration
	if on_floor:
		rate = ground_acceleration if wish.length_squared() > 0.001 else ground_deceleration
		if _knock_left > 0.0:
			rate = KNOCK_SLIDE
	horizontal = horizontal.move_toward(wish * speed, rate * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	if not on_floor:
		velocity.y -= _gravity * gravity_scale * delta
	if _jump_buffer > 0.0 and _coyote > 0.0:
		velocity.y = jump_velocity
		_jump_buffer = 0.0
		_coyote = 0.0

	var intended := velocity
	move_and_slide()
	_shove_bodies(intended, delta)


## CharacterBody3D does not push rigid bodies by itself: hand each one we ran
## into an impulse so clutter can be kicked, barged and knocked over.
func _shove_bodies(intended: Vector3, delta: float) -> void:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var body := collision.get_collider() as RigidBody3D
		if body == null or body.freeze or (_holding and body == _held) or (_held_demon and _demon_of(body) == _held_demon):
			continue
		var normal := collision.get_normal()
		if normal.y > 0.7:
			continue  # standing on it, not shoving it
		var direction := -normal
		var closing := intended.dot(direction) - body.linear_velocity.dot(direction)
		if closing <= 0.05:
			continue
		# Light clutter picks up our speed at once; anything that resists only
		# ever feels a bounded shove per tick, so it has to be leaned on.
		var size := minf(closing * minf(body.mass, push_mass_limit) * push_strength, max_push_force * delta)
		body.apply_impulse(direction * size, collision.get_position() - body.global_position)


# --- Camera -----------------------------------------------------------------

func _update_camera_rig(delta: float) -> void:
	_knock_blend = move_toward(_knock_blend, 1.0 if _knock_left > 0.0 else 0.0, delta * (5.0 if _knock_left > 0.0 else 2.4))
	var down := smoothstep(0.0, 1.0, _knock_blend)
	_trauma = maxf(0.0, _trauma - delta * 1.3)
	_shake_clock += delta * 34.0
	var jolt := Vector3(sin(_shake_clock * 1.13), sin(_shake_clock * 0.87 + 1.7), sin(_shake_clock * 1.41 + 0.6)) * _trauma * _trauma
	# Knocked down, the view drops to the floorboards and rolls onto its side.
	_head.position.y = lerpf(_eye_height, KNOCK_EYE, down)
	_head.rotation = Vector3(_pitch * (1.0 - 0.6 * down) + jolt.x * 0.05, jolt.y * 0.03, _knock_roll * 1.05 * down + jolt.z * 0.06)
	_camera.h_offset = jolt.y * 0.04
	_camera.v_offset = jolt.x * 0.04
	_camera_blend = move_toward(_camera_blend, 0.0 if first_person else 1.0, delta * 4.5)
	var eased := smoothstep(0.0, 1.0, _camera_blend)
	# Slide the boom out over the right shoulder, but never through a wall.
	_arm.position = (shoulder_offset * eased).limit_length(_shoulder_clearance)
	_arm.spring_length = third_person_distance * eased
	_model.set_view(_camera.global_transform)
	# The torch shines from the hardhat lamp, along the line of sight.
	_flashlight.global_position = _model.get_headlamp_position() - _head.global_transform.basis.z * 0.08
	# The body would fill the lens up close, so hide it before the boom is fully in.
	var hide_model := _camera_blend < 0.3
	if hide_model != _model_hidden:
		_model_hidden = hide_model
		_model.set_first_person(hide_model)


## Measures how far the camera boom can sit off the shoulder before hitting a wall.
func _probe_shoulder() -> void:
	_shoulder_clearance = INF
	if _camera_blend <= 0.0:
		return
	var from := _head.global_position
	var to := _head.global_transform * shoulder_offset
	var query := PhysicsRayQueryParameters3D.create(from, to, GameState.LAYER_WORLD, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		var hit_position: Vector3 = hit["position"]
		_shoulder_clearance = maxf(0.0, from.distance_to(hit_position) - 0.2)


func _configure_flashlight() -> void:
	_flashlight.light_color = Color(1.0, 0.96, 0.86)
	_flashlight.light_energy = flashlight_energy
	_flashlight.light_volumetric_fog_energy = 2.6
	_flashlight.light_specular = 0.6
	_flashlight.spot_range = flashlight_range
	_flashlight.spot_angle = 26.0
	_flashlight.spot_attenuation = 0.9
	_flashlight.spot_angle_attenuation = 0.45
	_flashlight.shadow_enabled = true
	_flashlight.shadow_bias = 0.05
	set_flashlight(flashlight_on)


## Faint backpack beacon: keeps the exorcist readable in third person and
## lets crewmates spot each other in the dark.
func _add_suit_glow() -> void:
	var glow := OmniLight3D.new()
	glow.name = "SuitGlow"
	glow.position = Vector3(0.0, 1.45, 0.6)
	glow.light_color = Color(0.78, 0.90, 1.0)
	glow.light_energy = 0.45
	glow.light_volumetric_fog_energy = 0.0
	glow.omni_range = 3.2
	glow.omni_attenuation = 1.4
	add_child(glow)


# --- Aiming, interaction and the physics grab ---------------------------------

func _update_aim() -> void:
	var view := _camera.global_transform
	_aim_forward = -view.basis.z
	# Start the ray level with the eyes so the third-person boom adds no reach.
	var eye := _head.global_position
	_aim_origin = view.origin + _aim_forward * maxf(0.0, (eye - view.origin).dot(_aim_forward))
	var exclude: Array[RID] = [get_rid()]
	if _holding and is_instance_valid(_held):
		exclude.append(_held.get_rid())
	var query := PhysicsRayQueryParameters3D.create(_aim_origin, _aim_origin + _aim_forward * grab_range, AIM_MASK, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)

	_aim_body = null
	_aim_interactable = null
	if hit.is_empty():
		return
	var collider: Object = hit["collider"]
	_aim_point = hit["position"]
	if collider is Node and collider.has_method(&"interact"):
		_aim_interactable = collider as Node
	elif collider is RigidBody3D and not (collider as RigidBody3D).freeze:
		_aim_body = collider as RigidBody3D


func _publish_aim() -> void:
	var kind := AimKind.NONE
	var prompt := ""
	if _holding:
		kind = AimKind.HOLDING
		if is_instance_valid(_held_demon) and is_instance_valid(_held):
			prompt = "DRAGGING DEMON (%s)   -   [RMB] Shove   -   release to drop" % str(_held.get_meta(&"demon_label", "LIMB"))
		else:
			prompt = "[RMB] Throw   -   release to drop"
	elif _aim_interactable:
		kind = AimKind.INTERACTABLE
		var action := "Use"
		if _aim_interactable.has_method(&"get_prompt"):
			action = str(_aim_interactable.call(&"get_prompt"))
		prompt = "[F] %s" % action
	elif _aim_body:
		kind = AimKind.GRABBABLE
		var demon := _demon_of(_aim_body)
		if demon:
			# Awake it can only be grabbed at (and it hits back); stunned it can be dragged.
			prompt = "[LMB / E] %s DEMON (%s)" % ["DRAG" if demon.get(&"is_stunned") else "GRAB", str(_aim_body.get_meta(&"demon_label", "LIMB"))]
		else:
			prompt = "[LMB / E] Grab %s" % str(_aim_body.get_meta(&"display_name", _aim_body.name))
	if kind != _aim_kind or prompt != _aim_prompt:
		_aim_kind = kind
		_aim_prompt = prompt
		aim_changed.emit(kind, prompt)


func _try_interact() -> void:
	if _knock_left <= 0.0 and is_instance_valid(_aim_interactable):
		_aim_interactable.call(&"interact", self)


func _update_grab(delta: float) -> void:
	var wants := Input.is_action_pressed(&"grab") and _knock_left <= 0.0
	if not wants:
		_grab_locked = false
	if _holding and not is_instance_valid(_held):
		# The prop was freed out of our hands.
		_held = null
		_holding = false
		held_changed.emit(null)
	if _holding:
		if not wants:
			_release_held()
		else:
			_drive_held(delta)
	elif wants and not _grab_locked and _aim_body:
		_begin_grab(_aim_body, _aim_point)


func _begin_grab(body: RigidBody3D, world_point: Vector3) -> void:
	_held = body
	_holding = true
	_held_local_point = body.global_transform.affine_inverse() * world_point
	_hold_distance = clampf(_aim_origin.distance_to(world_point), hold_distance_min, hold_distance_max)
	_held_angular_damp = body.angular_damp
	body.angular_damp = held_angular_damp
	body.sleeping = false
	# A carried prop must not shove (or launch) the person carrying it.
	body.add_collision_exception_with(self)
	_held_demon = _demon_of(body)
	if _held_demon:
		# The whole ragdoll passes through its handler, or the trailing limbs would trip them up.
		for part: RigidBody3D in _held_demon.call(&"get_bodies"):
			part.add_collision_exception_with(self)
		for i in range(_released.size() - 1, -1, -1):
			var loose: Variant = _released[i]["body"]
			if is_instance_valid(loose) and _demon_of(loose as RigidBody3D) == _held_demon:
				_released.remove_at(i)
		_held_demon.call(&"notify_grab", body, self)
	for entry in _released:
		if entry["body"] == body:
			_released.erase(entry)
			break
	held_changed.emit(body)


## Spring-damped pull: the distance error becomes a target velocity for the
## grab point, and the velocity error becomes a capped force applied at that
## point. The prop stays a live rigid body the whole time.
func _drive_held(_delta: float) -> void:
	var grab_point := _held.global_transform * _held_local_point
	var lever := grab_point - _held.global_position
	var target := _aim_origin + _aim_forward * _hold_distance
	var error := target - grab_point
	_held_strain = clampf(error.length() / break_distance, 0.0, 1.0)
	if error.length() > break_distance:
		_release_held()
		return
	var state := PhysicsServer3D.body_get_direct_state(_held.get_rid())
	var point_velocity := _held.linear_velocity
	if state:
		point_velocity = state.get_velocity_at_local_position(lever)
	var desired := (error * pull_stiffness).limit_length(max_pull_speed) + get_real_velocity() * 0.6
	var force := ((desired - point_velocity) * pull_response * _pull_mass).limit_length(_pull_cap)
	_held.apply_force(force, lever)
	if is_instance_valid(_held_demon):
		_held_demon.call(&"report_strain", _held_strain)


func _release_held() -> void:
	if not _holding:
		return
	var body := _held
	var demon := _held_demon
	_held = null
	_held_demon = null
	_holding = false
	if is_instance_valid(body):
		body.angular_damp = _held_angular_damp
		# Keep ignoring it for a beat so it clears the capsule before colliding again.
		_released.append({"body": body, "time": 0.35})
	if is_instance_valid(demon):
		for part: RigidBody3D in demon.call(&"get_bodies"):
			if part != body:
				_released.append({"body": part, "time": 0.35})
		demon.call(&"notify_release", self)
	held_changed.emit(null)


func _throw_held() -> void:
	if not _holding or not is_instance_valid(_held):
		return
	var body := _held
	_release_held()
	_grab_locked = true
	var direction := (_aim_forward + Vector3.UP * 0.12).normalized()
	body.apply_central_impulse(direction * minf(throw_impulse, body.mass * throw_speed))


func _expire_released(delta: float) -> void:
	for i in range(_released.size() - 1, -1, -1):
		var entry := _released[i]
		entry["time"] = float(entry["time"]) - delta
		var body: Variant = entry["body"]
		if not is_instance_valid(body):
			_released.remove_at(i)
		elif float(entry["time"]) <= 0.0:
			(body as RigidBody3D).remove_collision_exception_with(self)
			_released.remove_at(i)


## Weight and pull limits of whatever is in hand; a demon limb supplies its own.
func _refresh_grab_tuning() -> void:
	if not (_holding and is_instance_valid(_held)):
		_carry_mass = 0.0
		return
	_pull_mass = _held.mass
	_pull_cap = max_pull_force
	_carry_mass = _held.mass
	if is_instance_valid(_held_demon):
		var tuning: Dictionary = _held_demon.call(&"get_grab_tuning", _held)
		_pull_mass = float(tuning["mass"])
		_pull_cap = float(tuning["force"])
		_carry_mass = float(tuning["carry"])


func _demon_of(body: RigidBody3D) -> Node:
	if body and body.has_meta(&"demon"):
		return body.get_meta(&"demon") as Node
	return null


# --- Knockdown ----------------------------------------------------------------

## Floors the player and sends them sliding along `impulse` (a velocity, m/s).
## Returns false while already down or still immune from the last one.
func knock_down(impulse: Vector3, _source: Node = null) -> bool:
	if _knock_left > 0.0 or _immune_left > 0.0:
		return false
	_knock_left = randf_range(knock_time_min, knock_time_max)
	# Roll away from the blow.
	_knock_roll = -1.0 if impulse.dot(global_transform.basis.x) > 0.0 else 1.0
	_release_held()
	_grab_locked = true
	_sprinting = false
	velocity = Vector3(impulse.x, maxf(impulse.y, 1.5), impulse.z)
	add_trauma(0.75)
	_model.set_knockdown(true)
	knocked_down.emit(_knock_left)
	return true


func is_knocked_down() -> bool:
	return _knock_left > 0.0


func is_knockdown_immune() -> bool:
	return _immune_left > 0.0


## Camera shake, 0..1. Decays by itself.
func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


func _update_knockdown(delta: float) -> void:
	if _knock_left > 0.0:
		_knock_left -= delta
		if _knock_left <= 0.0:
			_knock_left = 0.0
			_immune_left = knock_immunity
			_model.set_knockdown(false)
			recovered.emit()
	elif _immune_left > 0.0:
		_immune_left = maxf(0.0, _immune_left - delta)


## A prop flying into the player fast enough knocks them over, whoever threw it.
func _check_prop_impacts() -> void:
	if _knock_left > 0.0 or _immune_left > 0.0:
		return
	var center := global_position + Vector3.UP * (_capsule.height * 0.5)
	for node in _hit_sensor.get_overlapping_bodies():
		var body := node as RigidBody3D
		if body == null or body.freeze or body == _held or body.mass < 0.5 or _is_released(body):
			continue
		var speed := body.linear_velocity.length()
		if speed <= knock_impact_speed:
			continue
		var heading := body.linear_velocity / speed
		var gap := center - GameState.mass_center(body)
		var closing := gap.dot(heading)
		# It has to be coming at the body, on a line that actually connects: anywhere
		# from shins to just over the head, not only dead centre.
		var miss := gap - heading * closing
		if closing <= 0.0 or speed * closing / maxf(gap.length(), 0.001) <= knock_impact_speed:
			continue
		if Vector2(miss.x, miss.z).length() > 0.7 or absf(miss.y) > _capsule.height * 0.5 + 0.25:
			continue
		knock_down(heading * clampf(body.mass * speed * 0.09, 3.5, 8.0) + Vector3.UP * 2.0, body)
		return


func _is_released(body: RigidBody3D) -> bool:
	for entry in _released:
		if entry["body"] == body:
			return true
	return false


## Wider than the body, so a fast prop is seen a tick or two before it lands.
func _build_hit_sensor() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.9
	shape.height = 2.4
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position.y = 0.9
	_hit_sensor = Area3D.new()
	_hit_sensor.name = "HitSensor"
	_hit_sensor.collision_layer = 0
	_hit_sensor.collision_mask = GameState.LAYER_PROP
	_hit_sensor.monitorable = false
	_hit_sensor.add_child(collider)
	add_child(_hit_sensor)


# --- Grab tether --------------------------------------------------------------

const TETHER_SEGMENTS := 18
const TETHER_CALM := Color(0.45, 0.95, 0.85)
const TETHER_STRAINED := Color(1.0, 0.55, 0.2)

## A thin, soft binding thread from the glove to the grab point, with a small
## ring where it bites. It sags when the prop hangs easy, pulls taut and warms
## toward amber as the grip nears breaking, so the invisible spring is readable.
func _build_tether() -> void:
	_tether_material = StandardMaterial3D.new()
	_tether_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_tether_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_tether_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_tether_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_tether_material.vertex_color_use_as_albedo = true
	_tether_material.disable_fog = true
	_tether_mesh = ImmediateMesh.new()
	_tether = MeshInstance3D.new()
	_tether.name = "GrabTether"
	_tether.mesh = _tether_mesh
	_tether.material_override = _tether_material
	_tether.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tether.top_level = true
	_tether.visible = false
	add_child(_tether)

	var ring := TorusMesh.new()
	ring.inner_radius = 0.03
	ring.outer_radius = 0.037
	ring.rings = 24
	ring.ring_segments = 6
	_tether_ring = MeshInstance3D.new()
	_tether_ring.name = "GrabRing"
	_tether_ring.mesh = ring
	var ring_material := _tether_material.duplicate() as StandardMaterial3D
	ring_material.vertex_color_use_as_albedo = false
	_tether_ring.material_override = ring_material
	_tether_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tether_ring.top_level = true
	_tether_ring.visible = false
	add_child(_tether_ring)


func _update_tether() -> void:
	var active := _holding and is_instance_valid(_held)
	_tether.visible = active
	_tether_ring.visible = active
	if not active:
		return
	var from := _model.get_hand_position(1)
	var to := _held.global_transform * _held_local_point
	var span := to - from
	var length := span.length()
	if length < 0.02:
		_tether.visible = false
		return
	var color := TETHER_CALM.lerp(TETHER_STRAINED, smoothstep(0.35, 0.95, _held_strain))
	# Slack hangs under the chord and trails behind a moving prop.
	var slack := 1.0 - smoothstep(0.1, 0.7, _held_strain)
	var control := from + span * 0.5 + Vector3.DOWN * (0.04 + 0.16 * slack) * clampf(length, 0.3, 1.4)
	control -= (_held.linear_velocity * 0.035).limit_length(0.25)

	# Camera-facing ribbon: bright core, edges fading to nothing.
	var eye := _camera.global_position
	var points: Array[Vector3] = []
	for i in TETHER_SEGMENTS + 1:
		var t := float(i) / TETHER_SEGMENTS
		points.append(from.lerp(control, t).lerp(control.lerp(to, t), t))
	_tether.global_transform = Transform3D.IDENTITY
	_tether_mesh.clear_surfaces()
	_tether_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var edge := Color(color.r, color.g, color.b, 0.0)
	for i in TETHER_SEGMENTS:
		var corners: Array[Vector3] = []
		var alphas: Array[float] = []
		for end in 2:
			var index := i + end
			var point := points[index]
			var tangent := (points[mini(index + 1, TETHER_SEGMENTS)] - points[maxi(index - 1, 0)]).normalized()
			var side := tangent.cross(eye - point).normalized() * 0.011
			corners.append_array([point - side, point, point + side])
			# Fade in from the glove so the thread seems to leave the palm.
			alphas.append(0.85 * smoothstep(0.0, 0.12, float(index) / TETHER_SEGMENTS))
		for strip in 2:
			var core_first := strip == 1
			var quad := [corners[strip], corners[strip + 1], corners[strip + 4], corners[strip], corners[strip + 4], corners[strip + 3]]
			var is_core := [core_first, not core_first, not core_first, core_first, not core_first, core_first]
			var ends := [0, 0, 1, 0, 1, 1]
			for corner in 6:
				_tether_mesh.surface_set_color(Color(color.r, color.g, color.b, alphas[ends[corner]]) if is_core[corner] else edge)
				_tether_mesh.surface_add_vertex(quad[corner])
	_tether_mesh.surface_end()

	# The contact ring faces back along the thread and breathes slightly.
	var normal := (control - to).normalized()
	var pulse := 1.0 + sin(Time.get_ticks_msec() * 0.006) * 0.08 + _held_strain * 0.35
	var ring_basis := Basis(Quaternion(Vector3.UP, normal)).scaled(Vector3.ONE * pulse)
	_tether_ring.global_transform = Transform3D(ring_basis, to + normal * 0.012)
	(_tether_ring.material_override as StandardMaterial3D).albedo_color = Color(color.r, color.g, color.b, 0.7)
