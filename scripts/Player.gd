extends CharacterBody3D
## Exorcist player controller.
##
## Movement: WASD, Shift sprint (stamina), Space jump, Ctrl crouch.
## Camera:   mouse look, V toggles first / third person, T toggles the headlamp.
## Health:   100 HP. Demon swipes and hurled furniture take it away; at zero the
##           player is DOWNED (crawling, no tools, a distress beacon overhead) until
##           a crewmate holds E on them for three seconds. Alone, one auto-injector
##           ("second wind") stands them back up once per contract.
## Knockdown: a fast flying prop or a demon swipe floors the player for a couple
##           of seconds: the view drops and rolls, they slide, drop what they hold.
## Hands:    hold LMB / E to grab a RigidBody3D with a spring-damped pull (the
##           body is never frozen, so it swings, snags on doorframes and feels
##           its weight), RMB to throw, F to use doors, Q to shove.
##
## One script, three jobs, chosen by `is_local` and `simulates`:
##   local + simulates   solo, or the host's own body: everything runs here
##   local only          a client's own body: movement and camera here, while the
##                       host runs its hands and gadgets and sends the results back
##   simulates only      someone else's body on the host: it follows their reported
##                       position and works their hands and gadgets from their inputs
##   neither             someone else's body on a client: a puppet
## Every person on site is one of these; there are no bots.

signal stamina_changed(current: float, maximum: float)
signal health_changed(current: float, maximum: float)
signal aim_changed(kind: int, prompt: String)
signal held_changed(body: RigidBody3D)
signal camera_mode_changed(first_person: bool)
signal flashlight_toggled(enabled: bool)
signal knocked_down(duration: float)
signal recovered
signal downed_changed(downed: bool)
## Solo: the auto-injector fired (true), and two and a half seconds later, the surge (false).
signal second_wind(active: bool)
## Down with nobody left who could help: the contract is lost.
signal died
signal struggle_finished(success: bool)

enum AimKind { NONE, GRABBABLE, INTERACTABLE, HOLDING }

const ExorcistModel := preload("res://scripts/ExorcistModel.gd")
const GadgetManager := preload("res://scripts/GadgetManager.gd")
const Parts := preload("res://scripts/gadgets/GadgetParts.gd")

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
## Eye height and speed of a downed player dragging themselves along.
const DOWNED_EYE := 0.46
const CRAWL_SPEED := 0.95
## A standing crewmate holding E this close for this long gets a downed player up.
const REVIVE_RANGE := 2.3
const REVIVE_TIME := 3.0
const REVIVE_HP := 55.0
const SECOND_WIND_TIME := 2.5
const SECOND_WIND_HP := 50.0
const SHOVE_COOLDOWN := 1.2
const SHOVE_RANGE := 2.1
## Seconds of helpless cartwheeling after a crewmate's taser finds you.
const TUMBLE_TIME := 2.5
## A lassoed player may press R once they have been held this long, or mash Space this often.
const LEASH_FREE_TIME := 2.0
const LEASH_MASH := 6
## Wire sizes (see `write_owner_state` and `write_sim_state`).
const OWNER_FLOATS := 17
const OWNER_INTS := 2
const SIM_FLOATS := 13 + GadgetManager.NET_FLOATS
const SIM_INTS := 4 + GadgetManager.NET_INTS

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

@export_group("Health")
@export var max_hp := 100.0

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

# --- Identity: set by Main before the body enters the tree ------------------------------
## Network peer that owns this body (1 in solo and for the host).
var peer_id := 1
## 0-3: spawn spot and wire id.
var seat := 0
var display_name := "EXORCIST"
## Driven by this machine's keyboard and mouse; owns the camera and the HUD.
var is_local := true
## The half that changes the world (hands, gadgets, shoves, impacts) runs here.
var simulates := true

var stamina := 100.0
var hp := 100.0
var is_downed := false
## Solo: the one auto-injector of this contract is still in its holster.
var second_wind_ready := true
var possessed := false
var first_person := false
var flashlight_on := true
## The tool belt (lasso, taser, tape). Built in `_ready`.
var gadgets: GadgetManager
## Set while a menu owns the mouse: no movement, grabbing or gadget use.
var controls_locked := false
## What the owner is holding down, read from Input here or reported over the wire.
var in_fire := false
var in_alt := false
var in_hand := false
var in_grab := false
## 0..1 of the revive this player is giving, and to whom (seat, -1 for nobody).
var revive_progress := 0.0
var revive_seat := -1

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
## Velocity something is hauling the player along with this tick (a taut lasso).
var _drag := Vector3.ZERO
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

# --- Stage 4 conditions -----------------------------------------------------------------
var _downed_blend := 0.0
var _hurt_flash := 0.0
var _wind_left := 0.0
var _tumble_left := 0.0
var _tumble_spin := 0.0
var _tumble_hop := 0.0
var _shove_left := 0.0
var _shove_anim := 0.0
## A shove taken this tick, and how long its slide still carries.
var _push := Vector3.ZERO
var _push_slide := 0.0
var _revive_target: Node3D
var _struggle_left := 0.0
var _struggle_need := 0
var _struggle_count := 0
var _twitch_wait := 3.0
var _twitch_left := 0.0
var _leash_left := 0.0
var _leash_time := 0.0
var _leash_mash := 0
var _leash_point := Vector3.ZERO
var _leash_length := 3.0
var _leash_by := -1
var _leash_anchored := false
var _zap_sparks: GPUParticles3D
var _beacon: Node3D
var _beacon_light: OmniLight3D
var _beacon_material: StandardMaterial3D
var _name_tag: Label3D
var _fx_clock := 0.0

# --- Mirror of a body that is driven from another machine -------------------------------
var _net_position := Vector3.ZERO
var _net_velocity := Vector3.ZERO
var _net_yaw := 0.0
var _net_pitch := 0.0
var _net_on_floor := true
var _net_age := 0.0
var _net_seen := false
## A fall this machine started on a remote body is not un-done by an older report from its owner.
var _knock_hold := 0.0
## Camera shake, stamina drain and rope drag owed to a remote owner, sent in small batches.
var _owed_shake := 0.0
var _owed_drain := 0.0
var _owed_left := 0.0
var _drag_out := Vector3.ZERO
var _drag_out_left := 0.0
var _net_drag := Vector3.ZERO
var _net_drag_left := 0.0

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
	_build_status_fx()
	gadgets = GadgetManager.new()
	gadgets.name = "Gadgets"
	add_child(gadgets)
	gadgets.setup(self, _model, _camera)
	# The tether follows the hands, so it is redrawn once their final pose is known.
	_model.pose_updated.connect(_update_tether)
	stamina = max_stamina
	hp = max_hp
	first_person = start_in_first_person and is_local
	_camera_blend = 0.0 if first_person else 1.0
	_model_hidden = first_person
	_model.set_first_person(first_person)
	_net_position = global_position
	_net_yaw = rotation.y
	if is_local:
		GameState.local_player = self
		_model.set_local_body()
		_camera.set_cull_mask_value(13, not first_person)
		_camera.make_current()
		_update_camera_rig(1.0)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		# Somebody else's eyes: never this viewport's camera, and no second shadow-casting torch.
		_camera.current = false
		_flashlight.shadow_enabled = false
		set_process_unhandled_input(false)
		_update_remote_rig()
	stamina_changed.emit(stamina, max_stamina)
	health_changed.emit(hp, max_hp)


func _exit_tree() -> void:
	_release_held()
	if GameState.local_player == self:
		GameState.local_player = null


## Chooses the hazmat colourway (0 orange, 1 teal, 2 olive, 3 purple; wraps).
func set_suit(index: int) -> void:
	_model.apply_suit(index)


func get_held() -> RigidBody3D:
	return _held if _holding and is_instance_valid(_held) else null


func get_camera() -> Camera3D:
	return _camera


## Where the crosshair's ray starts and points, as of the last physics tick.
func get_aim_origin() -> Vector3:
	return _aim_origin


func get_aim_forward() -> Vector3:
	return _aim_forward


## Where this player is looking from and along, whoever's machine their camera is on.
func get_view_origin() -> Vector3:
	return _camera.global_position if is_local else _aim_origin


func get_view_forward() -> Vector3:
	return -_camera.global_transform.basis.z if is_local else _aim_forward


func get_look_pitch() -> float:
	return _pitch


## True once the camera is close enough in that the body is hidden and the gloves are shown.
func is_first_person_view() -> bool:
	return _model_hidden


## True while something is being carried or dragged by hand.
func is_hand_grabbing() -> bool:
	return _holding


## On their feet and in charge of their own hands.
func can_act() -> bool:
	return _knock_left <= 0.0 and not is_downed and not possessed and _wind_left <= 0.0 and _struggle_left <= 0.0


## Something the demon would bother with: not on the floor waiting for help.
func is_standing() -> bool:
	return not is_downed and _wind_left <= 0.0


func is_tumbling() -> bool:
	return _tumble_left > 0.0


## 0..1 of a possession struggle's presses, or -1 when there is none.
func get_struggle() -> float:
	if _struggle_left <= 0.0:
		return -1.0
	return clampf(float(_struggle_count) / float(maxi(_struggle_need, 1)), 0.0, 1.0)


## 0..1 through the second-wind blackout, or -1 when there is none.
func get_second_wind() -> float:
	return 1.0 - _wind_left / SECOND_WIND_TIME if _wind_left > 0.0 else -1.0


func get_hurt_flash() -> float:
	return _hurt_flash


func is_leashed() -> bool:
	return _leash_left > 0.0


## Who holds the rope round this player (seat), whether it is pinned, and for how long so far.
func get_leash() -> Dictionary:
	return {"by": _leash_by, "anchored": _leash_anchored, "time": _leash_time, "mash": _leash_mash}


## Hauls the player along at `pull` (m/s, horizontal) for this tick. Movement can fight it.
func apply_drag(pull: Vector3) -> void:
	var flat := Vector3(pull.x, 0.0, pull.z).limit_length(5.0)
	if is_local:
		_drag = flat
	else:
		_drag_out = flat
		_drag_out_left = 0.12


## Burns stamina outside of sprinting (a tug of war on the lasso).
func drain_stamina(amount: float) -> void:
	if amount <= 0.0:
		return
	stamina = maxf(0.0, stamina - amount)
	if not is_local:
		_owed_drain += amount
		return
	_regen_wait = regen_delay
	if stamina <= 0.0:
		_exhausted = true
	stamina_changed.emit(stamina, max_stamina)


## Camera shake of at least `amount` (0..1), without stacking the way `add_trauma` does.
func shake(amount: float) -> void:
	if not is_local:
		_owed_shake = maxf(_owed_shake, clampf(amount, 0.0, 1.0))
		return
	_trauma = maxf(_trauma, clampf(amount, 0.0, 1.0))


## Back beside the van with full health, stamina and fresh gadgets: a contract is starting.
func reset_for_contract(spawn: Transform3D) -> void:
	_release_held()
	for entry in _released:
		if is_instance_valid(entry["body"]):
			(entry["body"] as RigidBody3D).remove_collision_exception_with(self)
	_released.clear()
	var was_floored := _knock_left > 0.0 or is_downed
	_knock_left = 0.0
	_immune_left = 0.0
	_trauma = 0.0
	_drag = Vector3.ZERO
	_push = Vector3.ZERO
	_wind_left = 0.0
	_tumble_left = 0.0
	_struggle_left = 0.0
	_leash_left = 0.0
	_twitch_left = 0.0
	_revive_target = null
	revive_progress = 0.0
	revive_seat = -1
	second_wind_ready = true
	hp = max_hp
	_model.set_tumble(false)
	if possessed:
		possessed = false
		_model.set_possessed(false)
	if is_downed:
		is_downed = false
		downed_changed.emit(false)
	if was_floored:
		_model.set_knockdown(false)
		recovered.emit()
	velocity = Vector3.ZERO
	global_transform = spawn
	_net_position = spawn.origin
	_net_yaw = spawn.basis.get_euler().y
	_pitch = 0.0
	stamina = max_stamina
	_exhausted = false
	stamina_changed.emit(stamina, max_stamina)
	health_changed.emit(hp, max_hp)
	gadgets.reset()


func _unhandled_input(event: InputEvent) -> void:
	if not is_local or controls_locked:
		return
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			var motion := event as InputEventMouseMotion
			rotate_y(-motion.relative.x * mouse_sensitivity)
			_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -1.45, 1.45)
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# This click only recaptures the cursor; it must not also start a grab or fire a gadget.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_grab_locked = true
		gadgets.lock_fire()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"toggle_camera"):
		set_first_person(not first_person)
	elif event.is_action_pressed(&"toggle_flashlight"):
		set_flashlight(not flashlight_on)
	elif event.is_action_pressed(&"interact"):
		request(&"interact")
	elif event.is_action_pressed(&"throw"):
		request(&"throw")
	elif event.is_action_pressed(&"shove"):
		if _shove_left <= 0.0 and can_act():
			request(&"shove")
			if not simulates:
				_shove_left = SHOVE_COOLDOWN
				_shove_anim = 0.3
	elif event.is_action_pressed(&"jump"):
		_mash()


## A one-shot action. It runs here when this machine works the player's hands, otherwise
## it is sent to the host, which runs it on its copy of this body.
func request(action: StringName, arg: int = 0) -> void:
	if simulates:
		perform(action, arg)
	elif is_instance_valid(GameState.net):
		GameState.net.call(&"send_command", action, arg)


func perform(action: StringName, _arg: int = 0) -> void:
	match action:
		&"interact":
			_try_interact()
		&"throw":
			_throw_held()
		&"shove":
			_shove()
		&"release":
			gadgets.lasso.request_release()
		&"break_leash":
			_break_leash()


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
	_tick_timers(delta)
	if is_local:
		_read_input()
		_update_knockdown(delta)
		_update_condition(delta)
		# Flat on the floor, wrestling a demon or looking at a menu there is no steering.
		var input := Vector2.ZERO
		if _knock_left <= 0.0 and not controls_locked and _struggle_left <= 0.0:
			input = Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
			if _twitch_left > 0.0:
				input = -input
		if simulates:
			_refresh_grab_tuning()
		_update_crouch(delta)
		_update_stamina(delta, input)
		_move(delta, input)
		_probe_shoulder()
	else:
		_follow_owner(delta)
	if is_local or simulates:
		_update_aim()
	if simulates:
		if not is_local:
			_refresh_grab_tuning()
		_update_grab(delta)
		_update_revive(delta)
		_expire_released(delta)
		_check_prop_impacts()
	if is_local:
		_publish_aim()

	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var backward := velocity.dot(global_transform.basis.z) > 0.5
	_model.set_motion(horizontal_speed, is_on_floor() if is_local else _net_on_floor, _crouch, _sprinting, backward)
	_model.set_look_pitch(_pitch)
	if _shove_anim > 0.0:
		# Both palms punch out along the line of sight.
		_model.set_reach(true, _head.global_position + _aim_forward * 0.85 + Vector3.DOWN * 0.25, 0.0, 0.0)
	elif _holding and is_instance_valid(_held):
		# Arms sag and reach with the weight in hand, and shake as the grip nears breaking.
		_model.set_reach(true, _held.global_transform * _held_local_point, clampf((_carry_mass - 3.0) / 36.0, 0.0, 1.0), _held_strain)
	else:
		_model.set_reach(false)


func _process(delta: float) -> void:
	if is_local:
		_update_camera_rig(delta)
	else:
		_update_remote_rig()
	_update_status_fx(delta)


func _read_input() -> void:
	var free := not controls_locked
	in_fire = free and Input.is_action_pressed(&"gadget_fire")
	in_alt = free and Input.is_action_pressed(&"gadget_alt")
	in_hand = free and Input.is_action_pressed(&"hand_grab")
	in_grab = free and Input.is_action_pressed(&"grab")


func _tick_timers(delta: float) -> void:
	_shove_left = maxf(0.0, _shove_left - delta)
	_shove_anim = maxf(0.0, _shove_anim - delta)
	_knock_hold = maxf(0.0, _knock_hold - delta)
	_hurt_flash = maxf(0.0, _hurt_flash - delta * 1.4)
	_push_slide = maxf(0.0, _push_slide - delta)
	_drag_out_left = maxf(0.0, _drag_out_left - delta)
	_net_drag_left = maxf(0.0, _net_drag_left - delta)
	if _leash_left > 0.0:
		_leash_left -= delta
		_leash_time += delta
		if _leash_left <= 0.0:
			_leash_time = 0.0
			_leash_mash = 0
	if not is_local and simulates:
		# Settle up with the owner a few times a second rather than on every tick.
		_owed_left -= delta
		if _owed_left <= 0.0:
			_owed_left = 0.1
			if _owed_shake > 0.0:
				_send_owner(&"shake", [_owed_shake], false)
				_owed_shake = 0.0
			if _owed_drain > 0.0:
				_send_owner(&"drain_stamina", [_owed_drain], false)
				_owed_drain = 0.0


## Runs `method` on the machine that owns this body. Only the host has anything to say.
func _send_owner(method: StringName, args: Array, reliable: bool = true) -> void:
	if GameState.is_authority() and is_instance_valid(GameState.net):
		GameState.net.call(&"send_to_owner", peer_id, method, args, reliable)


# --- Locomotion -------------------------------------------------------------

func _update_crouch(delta: float) -> void:
	var wants := Input.is_action_pressed(&"crouch") or _knock_left > 0.0 or is_downed
	if not wants and _crouch > 0.0:
		# Stay down while there is no headroom to stand back up.
		var headroom := STAND_HEIGHT - _capsule.height + 0.02
		if test_move(global_transform, Vector3.UP * headroom):
			wants = true
	_crouch = move_toward(_crouch, 1.0 if wants else 0.0, delta * 7.0)
	_apply_crouch(delta)


func _apply_crouch(delta: float) -> void:
	var height := lerpf(STAND_HEIGHT, CROUCH_HEIGHT, _crouch)
	_capsule.height = height
	_collision.position.y = height * 0.5
	_downed_blend = move_toward(_downed_blend, 1.0 if is_downed else 0.0, delta * 3.0)
	_eye_height = lerpf(lerpf(STAND_EYE, CROUCH_EYE, _crouch), DOWNED_EYE, _downed_blend)


func _update_stamina(delta: float, input: Vector2) -> void:
	var wants := Input.is_action_pressed(&"sprint") and input.length() > 0.1 and input.y < 0.3
	_sprinting = wants and not _exhausted and stamina > 0.0 and _crouch < 0.3 and is_on_floor() and not is_downed
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
	var may_jump := _knock_left <= 0.0 and not controls_locked and not is_downed and _struggle_left <= 0.0 and _leash_left <= 0.0
	_jump_buffer = JUMP_BUFFER if Input.is_action_just_pressed(&"jump") and may_jump else maxf(0.0, _jump_buffer - delta)

	var speed := walk_speed
	if is_downed:
		speed = CRAWL_SPEED
	elif _crouch > 0.5:
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
		if _knock_left > 0.0 or _push_slide > 0.0:
			rate = KNOCK_SLIDE
	if _net_drag_left > 0.0:
		_drag += _net_drag
	# A taut lasso on something that pulls back hauls the holder along with it.
	horizontal = horizontal.move_toward(wish * speed + _drag, rate * delta)
	_drag = Vector3.ZERO
	if _push != Vector3.ZERO:
		# Shoved: the kick lands on top of whatever the legs were doing.
		horizontal += Vector3(_push.x, 0.0, _push.z)
		velocity.y = maxf(velocity.y, _push.y)
		_push = Vector3.ZERO
		_push_slide = 0.45
	if _leash_left > 0.0:
		horizontal = _rein_in(horizontal)
	if _tumble_left > 0.0 and on_floor:
		# Cartwheeling: every landing kicks off another bounce.
		_tumble_hop -= delta
		if _tumble_hop <= 0.0:
			_tumble_hop = 0.42
			velocity.y = 2.8
			horizontal += Vector3(randf_range(-1.6, 1.6), 0.0, randf_range(-1.6, 1.6))
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
	if simulates:
		_shove_bodies(intended, delta)


## A rope round the waist: free inside its length, hauled back in beyond it.
func _rein_in(horizontal: Vector3) -> Vector3:
	var offset := global_position + Vector3.UP - _leash_point
	offset.y = 0.0
	var distance := offset.length()
	if distance <= _leash_length or distance < 0.01:
		return horizontal
	var outward := offset / distance
	var escaping := horizontal.dot(outward)
	if escaping > 0.0:
		horizontal -= outward * escaping
	return horizontal - outward * minf((distance - _leash_length) * 8.0, 7.5)


## Somebody else's body: follow where its owner says it is. On the host it walks there
## through the physics, so it still barges clutter aside; on a client it simply glides.
func _follow_owner(delta: float) -> void:
	if not _net_seen:
		return
	_net_age += delta
	var target := _net_position + _net_velocity * minf(_net_age, 0.12)
	var gap := target - global_position
	if gap.length() > 2.5:
		global_position = target
		velocity = _net_velocity
	elif simulates:
		velocity = (_net_velocity + gap * 12.0).limit_length(18.0)
		var intended := velocity
		move_and_slide()
		_shove_bodies(intended, delta)
		velocity = _net_velocity
	else:
		global_position += gap * (1.0 - exp(-16.0 * delta))
		velocity = _net_velocity
	var blend := 1.0 - exp(-18.0 * delta)
	rotation.y = lerp_angle(rotation.y, _net_yaw, blend)
	_pitch = lerpf(_pitch, _net_pitch, blend)
	_apply_crouch(delta)


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
	var roll := _knock_roll * 1.05
	if _tumble_left > 0.0:
		# Tased by a friend: the horizon goes round and round, slowing as the current fades.
		_tumble_spin += delta * (2.0 + 5.5 * _tumble_left / TUMBLE_TIME)
		roll = lerp_angle(roll, _tumble_spin, clampf(_tumble_left / 0.5, 0.0, 1.0))
	# Knocked down, the view drops to the floorboards and rolls onto its side.
	_head.position.y = lerpf(_eye_height, KNOCK_EYE, down)
	_head.rotation = Vector3(_pitch * (1.0 - 0.6 * down) + jolt.x * 0.05, jolt.y * 0.03, roll * down + jolt.z * 0.06)
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
	# The body would fill the lens up close, so stop drawing it before the boom is fully in:
	# the camera drops the own-body render layer and the gloves take over.
	var hide_model := _camera_blend < 0.3
	if hide_model != _model_hidden:
		_model_hidden = hide_model
		_model.set_first_person(hide_model)
		_camera.set_cull_mask_value(13, not hide_model)


## The head of a body whose camera is on another machine: enough for its torch and its arms.
func _update_remote_rig() -> void:
	_head.position.y = lerpf(_eye_height, KNOCK_EYE, 1.0 if _knock_left > 0.0 else 0.0)
	_head.rotation = Vector3(_pitch, 0.0, 0.0)
	_model.set_view(_head.global_transform)
	_flashlight.global_position = _model.get_headlamp_position() - _head.global_transform.basis.z * 0.08


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
	if is_local:
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
	elif GameState.is_loose(collider):
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
		var keys := "E" if gadgets.is_armed() else "LMB / E"
		var demon := _demon_of(_aim_body)
		if demon:
			# Awake it can only be grabbed at (and it hits back); stunned it can be dragged.
			prompt = "[%s] %s DEMON (%s)" % [keys, "DRAG" if demon.get(&"is_stunned") else "GRAB", str(_aim_body.get_meta(&"demon_label", "LIMB"))]
		else:
			prompt = "[%s] Grab %s" % [keys, str(_aim_body.get_meta(&"display_name", _aim_body.name))]
	if kind != _aim_kind or prompt != _aim_prompt:
		_aim_kind = kind
		_aim_prompt = prompt
		aim_changed.emit(kind, prompt)


func _try_interact() -> void:
	if can_act() and is_instance_valid(_aim_interactable):
		_aim_interactable.call(&"interact", self)


func _update_grab(delta: float) -> void:
	# E always grabs by hand. LMB does too, unless it is busy working a gadget.
	var asked := in_hand or (in_grab and not gadgets.is_armed())
	var wants := asked and can_act()
	if not wants:
		_grab_locked = false
	if _holding and (not is_instance_valid(_held) or _held.freeze):
		# The prop was freed out of our hands (or the demon stepped out of the world).
		_drop_lost()
	if _holding:
		if not wants:
			_release_held()
		else:
			_drive_held(delta)
	elif wants and not _grab_locked and _aim_body and not _aim_body.freeze and _find_downed_crewmate() == null:
		_begin_grab(_aim_body, _aim_point)


func _drop_lost() -> void:
	if is_instance_valid(_held):
		_release_held()
		return
	_held = null
	_held_demon = null
	_holding = false
	held_changed.emit(null)


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
	if not simulates:
		# A mirror of what the host is holding for us: nothing here to undo.
		held_changed.emit(null)
		return
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


## Arms thrown out in front for a moment, whoever (or whatever) is working them.
func play_shove() -> void:
	_shove_anim = 0.3


## Lets go of whatever is in hand; the demon calls this when it tears itself free.
func drop_held() -> void:
	_release_held()
	_grab_locked = true


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


# --- Reviving ---------------------------------------------------------------------

## The nearest crewmate lying within arm's reach, if any.
func _find_downed_crewmate() -> Node3D:
	var best: Node3D = null
	var best_distance := REVIVE_RANGE
	for other in GameState.get_players():
		if other == self or not other.get(&"is_downed"):
			continue
		var distance := other.global_position.distance_to(global_position)
		if distance < best_distance:
			best_distance = distance
			best = other
	return best


## Holding E beside a downed crewmate gets them back up in REVIVE_TIME seconds.
func _update_revive(delta: float) -> void:
	var target: Node3D = null
	if in_hand and not _holding and can_act():
		target = _find_downed_crewmate()
	if target != _revive_target:
		_revive_target = target
		revive_progress = 0.0
	revive_seat = int(target.get(&"seat")) if target else -1
	if target == null:
		return
	revive_progress += delta / REVIVE_TIME
	if revive_progress >= 1.0:
		revive_progress = 0.0
		_revive_target = null
		revive_seat = -1
		_grab_locked = true
		target.call(&"revive", REVIVE_HP)
		GameState.post_notice("%s IS BACK UP  -  revived by %s" % [str(target.get(&"display_name")), display_name])


## Back on their feet with `amount` HP.
func revive(amount: float) -> void:
	if not is_local:
		_send_owner(&"revive", [amount])
		return
	if not is_downed:
		return
	hp = clampf(amount, 1.0, max_hp)
	is_downed = false
	_knock_left = 0.0
	_immune_left = knock_immunity
	_model.set_knockdown(false)
	health_changed.emit(hp, max_hp)
	downed_changed.emit(false)
	recovered.emit()


# --- Health -----------------------------------------------------------------------

## Damage with no knockdown attached (a lost possession struggle).
func hurt(amount: float) -> void:
	if not is_local:
		_send_owner(&"hurt", [amount])
		return
	_take_damage(amount)
	add_trauma(0.5)


func _take_damage(amount: float) -> void:
	if amount <= 0.0 or is_downed or _wind_left > 0.0:
		return
	hp = maxf(0.0, hp - amount)
	_hurt_flash = 1.0
	health_changed.emit(hp, max_hp)
	if hp <= 0.0:
		_collapse()


## Out of health. With a crew that means waiting for a hand up; alone it means the
## auto-injector, once, and after that the contract is over.
func _collapse() -> void:
	_release_held()
	_tumble_left = 0.0
	_model.set_knockdown(true)
	if NetworkManager.get_player_count() <= 1 and second_wind_ready:
		second_wind_ready = false
		_wind_left = SECOND_WIND_TIME
		_knock_left = maxf(_knock_left, SECOND_WIND_TIME)
		second_wind.emit(true)
		return
	is_downed = true
	downed_changed.emit(true)
	if NetworkManager.get_player_count() <= 1:
		died.emit()


func _finish_second_wind() -> void:
	_wind_left = 0.0
	hp = SECOND_WIND_HP
	_knock_left = 0.0
	_immune_left = knock_immunity + 1.0
	_model.set_knockdown(false)
	health_changed.emit(hp, max_hp)
	recovered.emit()
	add_trauma(0.8)
	second_wind.emit(false)
	# The surge throws whatever was standing over the body clear of it.
	for demon in get_tree().get_nodes_in_group(GameState.GROUP_DEMON):
		if demon.has_method(&"blast_away"):
			demon.call(&"blast_away", global_position, 7.0, 6.0)
	GameState.post_notice_for(self, "SECOND WIND USED — NO MORE REVIVES")


## Second wind, possession and the leash, on the machine that owns the body.
func _update_condition(delta: float) -> void:
	if _wind_left > 0.0:
		_wind_left -= delta
		# On the floor for the whole blackout, whatever the knockdown clock says.
		_knock_left = maxf(_knock_left, 0.2)
		if _wind_left <= 0.0:
			_finish_second_wind()
	if _struggle_left > 0.0:
		_struggle_left -= delta
		shake(0.45)
		if _struggle_left <= 0.0:
			_end_struggle(false)
	_twitch_left = maxf(0.0, _twitch_left - delta)
	if possessed and not is_downed:
		# The passenger keeps grabbing the wheel: the legs go the wrong way and the head snaps round.
		_twitch_wait -= delta
		if _twitch_wait <= 0.0:
			_twitch_wait = randf_range(2.6, 4.6)
			_twitch_left = randf_range(0.7, 1.2)
			rotate_y(randf_range(-0.7, 0.7))
			add_trauma(0.35)


# --- Possession -------------------------------------------------------------------

## The demon has stepped into (or been driven out of) this player.
func set_possessed(active: bool) -> void:
	if not is_local and GameState.is_authority() and possessed != active:
		_send_owner(&"set_possessed", [active])
	if possessed == active:
		return
	possessed = active
	_model.set_possessed(active)
	_twitch_wait = randf_range(1.5, 3.0)
	_twitch_left = 0.0
	if active:
		_release_held()
		add_trauma(0.7)


## Solo: the demon has hold of the player. `presses` of Space inside `duration` breaks it.
func begin_struggle(duration: float, presses: int) -> void:
	if _struggle_left > 0.0:
		return
	_release_held()
	_struggle_left = duration
	_struggle_need = presses
	_struggle_count = 0
	velocity = Vector3.ZERO
	add_trauma(0.6)


func _end_struggle(success: bool) -> void:
	_struggle_left = 0.0
	struggle_finished.emit(success)


## Space, pressed: one heave against whatever has hold of the player.
func _mash() -> void:
	if _struggle_left > 0.0:
		_struggle_count += 1
		add_trauma(0.12)
		if _struggle_count >= _struggle_need:
			_end_struggle(true)
	elif _leash_left > 0.0:
		_leash_mash += 1
		add_trauma(0.1)
		if _leash_mash >= LEASH_MASH:
			_leash_mash = 0
			request(&"break_leash")


## R, pressed: after two seconds on someone's rope, slip it.
func try_slip_leash() -> void:
	if _leash_left > 0.0 and _leash_time >= LEASH_FREE_TIME:
		request(&"break_leash")


# --- Friendly chaos -----------------------------------------------------------------

## Held on a rope: no further than `length` from `point`. Called every tick it stays true.
func set_leash(point: Vector3, length: float, by_seat: int, anchored: bool) -> void:
	if _leash_left <= 0.0:
		_leash_time = 0.0
		_leash_mash = 0
	_leash_point = point
	_leash_length = length
	_leash_by = by_seat
	_leash_anchored = anchored
	_leash_left = 0.3


## Throws off every rope a crewmate has on this player.
func _break_leash() -> void:
	for other in GameState.get_players():
		var belt: Variant = other.get(&"gadgets")
		if other != self and is_instance_valid(belt):
			(belt as GadgetManager).lasso.release_player(self)
	_leash_left = 0.0
	_leash_time = 0.0


## Q: a two-handed shove. Chairs go over, an enraged demon rocks back on its heels and a
## crewmate standing on the lip of the van ramp finds out what the ground is like.
func _shove() -> void:
	if _shove_left > 0.0 or not can_act():
		return
	_shove_left = SHOVE_COOLDOWN
	_shove_anim = 0.3
	var forward := Vector3(_aim_forward.x, 0.0, _aim_forward.z)
	forward = forward.normalized() if forward.length_squared() > 0.001 else -global_transform.basis.z
	var chest := global_position + Vector3.UP
	gadgets.audio.play(&"whip", chest, -5.0, 0.7)
	shake(0.2)
	for other in GameState.get_players():
		if other == self:
			continue
		var to := other.global_position - global_position
		to.y = 0.0
		if to.length() < SHOVE_RANGE and (to.length() < 0.4 or forward.dot(to.normalized()) > 0.35):
			other.call(&"shoved", forward * 6.5 + Vector3.UP * 2.8)
	var ball := SphereShape3D.new()
	ball.radius = 1.0
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = ball
	query.collision_mask = GameState.LAYER_PROP | GameState.LAYER_DEMON
	query.transform = Transform3D(Basis.IDENTITY, chest + forward * 1.1)
	query.exclude = [get_rid()]
	var demons: Array[Node] = []
	for hit in get_world_3d().direct_space_state.intersect_shape(query, 24):
		var body := hit["collider"] as RigidBody3D
		if body == null or body.freeze or body == _held:
			continue
		var demon := _demon_of(body)
		if demon:
			if not demons.has(demon):
				demons.append(demon)
		else:
			body.sleeping = false
			body.apply_central_impulse((forward + Vector3.UP * 0.3) * minf(body.mass, 14.0) * 5.2)
	for demon in demons:
		demon.call(&"shove", forward, self)


## Shoved by a crewmate (or by something possessing one): `impulse` is a velocity in m/s.
func shoved(impulse: Vector3) -> void:
	if not is_local:
		_send_owner(&"shoved", [impulse])
		return
	if is_downed or _knock_left > 0.0 or _wind_left > 0.0:
		return
	_push += impulse
	add_trauma(0.35)


## A crewmate's taser: no damage, but `duration` seconds of comedy cartwheeling.
func tumble(impulse: Vector3, duration: float = TUMBLE_TIME) -> void:
	if not is_local:
		if _tumble_left <= 0.0:
			_tumble_left = duration
			_send_owner(&"tumble", [impulse, duration])
		return
	if is_downed or _wind_left > 0.0 or _tumble_left > 0.0:
		return
	_tumble_left = duration
	_tumble_spin = 0.0
	_tumble_hop = 0.0
	_knock_left = maxf(_knock_left, duration)
	_knock_roll = -1.0 if impulse.dot(global_transform.basis.x) > 0.0 else 1.0
	_release_held()
	_grab_locked = true
	_sprinting = false
	velocity = Vector3(impulse.x, maxf(impulse.y, 3.4), impulse.z)
	add_trauma(0.65)
	_model.set_knockdown(true)
	knocked_down.emit(duration)


# --- Knockdown ----------------------------------------------------------------

## Floors the player and sends them sliding along `impulse` (a velocity, m/s), taking
## `damage` HP with it. Returns false while already down or still immune from the last one.
func knock_down(impulse: Vector3, _source: Node = null, damage: float = 0.0) -> bool:
	if _knock_left > 0.0 or _immune_left > 0.0 or is_downed or _wind_left > 0.0:
		return false
	if not is_local:
		# The fall happens on the owner's machine; mirror it here at once so nothing lands twice.
		_knock_left = knock_time_max
		_knock_hold = 0.5
		_model.set_knockdown(true)
		_release_held()
		_send_owner(&"knock_down", [impulse, null, damage])
		return true
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
	_take_damage(damage)
	return true


func is_knocked_down() -> bool:
	return _knock_left > 0.0


func is_knockdown_immune() -> bool:
	return _immune_left > 0.0


## Camera shake, 0..1. Decays by itself.
func add_trauma(amount: float) -> void:
	if not is_local:
		_owed_shake = maxf(_owed_shake, clampf(amount, 0.0, 1.0))
		return
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


func _update_knockdown(delta: float) -> void:
	if _tumble_left > 0.0:
		_tumble_left = maxf(0.0, _tumble_left - delta)
	if _knock_left > 0.0:
		_knock_left -= delta
		if _knock_left <= 0.0:
			_knock_left = 0.0
			_immune_left = knock_immunity
			# A downed player stays on the floor; everyone else gets up.
			_model.set_knockdown(is_downed)
			recovered.emit()
	elif _immune_left > 0.0:
		_immune_left = maxf(0.0, _immune_left - delta)


## A prop flying into the player fast enough knocks them over, whoever threw it. One the
## demon hurled also hurts: 18 HP at the slowest speed that floors, 25 at full pelt.
func _check_prop_impacts() -> void:
	if _knock_left > 0.0 or _immune_left > 0.0 or is_downed or _wind_left > 0.0:
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
		var damage := 0.0
		if Time.get_ticks_msec() < int(body.get_meta(&"hurled_until", 0)):
			damage = clampf(remap(speed, knock_impact_speed, 15.0, 18.0, 25.0), 18.0, 25.0)
		knock_down(heading * clampf(body.mass * speed * 0.09, 3.5, 8.0) + Vector3.UP * 2.0, body, damage)
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


# --- Status effects every machine draws ------------------------------------------------

## Taser sparks, the distress beacon over a downed player and a name over a crewmate.
func _build_status_fx() -> void:
	_zap_sparks = Parts.particles(Color(0.5, 0.78, 1.0), 40, 0.4, Vector2(1.0, 4.2), Vector2(0.012, 0.03), Vector3(0.0, -6.0, 0.0), 180.0, false)
	_zap_sparks.name = "ZapSparks"
	_zap_sparks.position = Vector3(0.0, 1.0, 0.0)
	add_child(_zap_sparks)

	_beacon = Node3D.new()
	_beacon.name = "DistressBeacon"
	_beacon.position = Vector3(0.0, 1.25, 0.0)
	_beacon.visible = false
	add_child(_beacon)
	_beacon_material = Parts.glow(Color(1.0, 0.12, 0.08), 4.0)
	var bulb := MeshInstance3D.new()
	bulb.mesh = Parts.ball(0.07)
	bulb.material_override = _beacon_material
	bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beacon.add_child(bulb)
	var ring := MeshInstance3D.new()
	ring.mesh = Parts.torus(0.2, 0.012)
	ring.material_override = _beacon_material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beacon.add_child(ring)
	_beacon_light = OmniLight3D.new()
	_beacon_light.light_color = Color(1.0, 0.16, 0.1)
	_beacon_light.omni_range = 5.5
	_beacon_light.omni_attenuation = 1.3
	_beacon_light.shadow_enabled = false
	_beacon.add_child(_beacon_light)
	var call_out := Label3D.new()
	call_out.name = "CallOut"
	call_out.text = "DOWN  -  HOLD [E]"
	call_out.font_size = 40
	call_out.pixel_size = 0.004
	call_out.position = Vector3(0.0, 0.3, 0.0)
	call_out.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	call_out.no_depth_test = true
	call_out.modulate = Color(1.0, 0.32, 0.22)
	call_out.outline_size = 10
	call_out.visible = not is_local
	_beacon.add_child(call_out)

	if not is_local:
		_name_tag = Label3D.new()
		_name_tag.name = "NameTag"
		_name_tag.text = display_name
		_name_tag.font_size = 36
		_name_tag.pixel_size = 0.0035
		_name_tag.position = Vector3(0.0, 2.08, 0.0)
		_name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_name_tag.modulate = Color(0.9, 0.94, 0.92, 0.85)
		_name_tag.outline_size = 8
		add_child(_name_tag)


func _update_status_fx(delta: float) -> void:
	_fx_clock += delta
	var tumbling := _tumble_left > 0.0
	_zap_sparks.emitting = tumbling
	_model.set_tumble(tumbling)
	if _beacon.visible != is_downed:
		_beacon.visible = is_downed
	if is_downed:
		var pulse := 0.5 + 0.5 * sin(_fx_clock * 7.0)
		_beacon_material.emission_energy_multiplier = 1.5 + 5.0 * pulse
		_beacon_light.light_energy = 0.4 + 1.8 * pulse
		_beacon.rotation.y = _fx_clock * 2.0
	if _name_tag:
		_name_tag.position.y = 0.95 if is_downed else lerpf(2.08, 1.6, _crouch)


# --- Replication ----------------------------------------------------------------------

## What the body's owner reports about itself: where it is, where it looks, what it holds down.
func write_owner_state(floats: PackedFloat32Array, ints: PackedInt32Array) -> void:
	var at := global_position
	floats.append_array(PackedFloat32Array([
		at.x, at.y, at.z, rotation.y, _pitch, velocity.x, velocity.y, velocity.z, _crouch,
		_aim_origin.x, _aim_origin.y, _aim_origin.z, _aim_forward.x, _aim_forward.y, _aim_forward.z,
		hp, stamina,
	]))
	var bits := 0
	for flag: bool in [is_on_floor() if is_local else _net_on_floor, _sprinting, flashlight_on, _knock_left > 0.0, _immune_left > 0.0, is_downed,
			in_fire, in_alt, in_hand, in_grab, _tumble_left > 0.0, _struggle_left > 0.0, _wind_left > 0.0, second_wind_ready]:
		bits = (bits << 1) | (1 if flag else 0)
	ints.append(bits)
	ints.append(gadgets.slot)


## The other end of `write_owner_state`, for a body whose owner is another machine.
func read_owner_state(floats: PackedFloat32Array, f: int, ints: PackedInt32Array, i: int) -> void:
	if is_local or f + OWNER_FLOATS > floats.size() or i + OWNER_INTS > ints.size():
		return
	var at := Vector3(floats[f], floats[f + 1], floats[f + 2])
	var speed := Vector3(floats[f + 5], floats[f + 6], floats[f + 7])
	var aim := Vector3(floats[f + 12], floats[f + 13], floats[f + 14])
	if not (at.is_finite() and speed.is_finite() and aim.is_finite()):
		return
	_net_position = at
	_net_velocity = speed.limit_length(30.0)
	_net_yaw = floats[f + 3]
	_net_pitch = clampf(floats[f + 4], -1.5, 1.5)
	_net_age = 0.0
	if not _net_seen:
		_net_seen = true
		global_position = at
		rotation.y = _net_yaw
	_crouch = clampf(floats[f + 8], 0.0, 1.0)
	_aim_origin = Vector3(floats[f + 9], floats[f + 10], floats[f + 11])
	_aim_forward = aim.normalized() if aim.length_squared() > 0.01 else Vector3.FORWARD
	var health := clampf(floats[f + 15], 0.0, max_hp)
	if not is_equal_approx(health, hp):
		hp = health
		health_changed.emit(hp, max_hp)
	stamina = clampf(floats[f + 16], 0.0, max_stamina)

	var bits := ints[i]
	second_wind_ready = bits & 1 != 0
	_wind_left = 1.0 if bits & 2 != 0 else 0.0
	_struggle_left = 1.0 if bits & 4 != 0 else 0.0
	var tumbling := bits & 8 != 0
	in_grab = bits & 16 != 0
	in_hand = bits & 32 != 0
	in_alt = bits & 64 != 0
	in_fire = bits & 128 != 0
	var downed := bits & 256 != 0
	_immune_left = 1.0 if bits & 512 != 0 else 0.0
	var floored := bits & 1024 != 0
	var torch := bits & 2048 != 0
	_sprinting = bits & 4096 != 0
	_net_on_floor = bits & 8192 != 0
	if torch != flashlight_on:
		set_flashlight(torch)
	if tumbling or _knock_hold <= 0.0:
		_tumble_left = 1.0 if tumbling else 0.0
	if downed != is_downed:
		is_downed = downed
		if downed:
			_release_held()
		downed_changed.emit(downed)
	if floored or _knock_hold <= 0.0:
		_knock_left = 1.0 if floored else 0.0
	_model.set_knockdown(_knock_left > 0.0 or is_downed)
	gadgets.follow_slot(ints[i + 1])


## What the host has worked out for this body: what is in its hands, what its gadgets
## are doing, and what has been done to it (rope, possession).
func write_sim_state(floats: PackedFloat32Array, ints: PackedInt32Array) -> void:
	var drag := _drag_out if _drag_out_left > 0.0 else Vector3.ZERO
	floats.append_array(PackedFloat32Array([
		_held_local_point.x, _held_local_point.y, _held_local_point.z, _held_strain, _carry_mass,
		_leash_point.x, _leash_point.y, _leash_point.z, _leash_length,
		revive_progress, drag.x, drag.y, drag.z,
	]))
	var bits := 0
	for flag: bool in [_leash_left > 0.0, _leash_anchored, possessed, _shove_anim > 0.0]:
		bits = (bits << 1) | (1 if flag else 0)
	ints.append_array(PackedInt32Array([GameState.body_ref(get_held()), bits, _leash_by, revive_seat]))
	gadgets.write_net(floats, ints)


func read_sim_state(floats: PackedFloat32Array, f: int, ints: PackedInt32Array, i: int) -> void:
	if simulates or f + SIM_FLOATS > floats.size() or i + SIM_INTS > ints.size():
		return
	var body := GameState.ref_body(ints[i]) as RigidBody3D
	if body != _held or (body != null) != _holding:
		_held = body
		_holding = body != null
		_held_demon = _demon_of(body)
		held_changed.emit(body)
	_held_local_point = Vector3(floats[f], floats[f + 1], floats[f + 2])
	_held_strain = floats[f + 3]
	_carry_mass = floats[f + 4]
	revive_progress = floats[f + 9]
	revive_seat = ints[i + 3]
	var bits := ints[i + 1]
	if bits & 1 != 0 and _shove_anim <= 0.0:
		_shove_anim = 0.25
	var taken := bits & 2 != 0
	if taken != possessed:
		possessed = taken
		_model.set_possessed(taken)
	if bits & 8 != 0:
		set_leash(Vector3(floats[f + 5], floats[f + 6], floats[f + 7]), floats[f + 8], ints[i + 2], bits & 4 != 0)
	if is_local:
		var drag := Vector3(floats[f + 10], floats[f + 11], floats[f + 12])
		if drag.is_finite() and drag.length_squared() > 0.0001:
			_net_drag = drag.limit_length(5.0)
			_net_drag_left = 0.12
	gadgets.read_net(floats, f + 13, ints, i + 4)


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
	var viewer := get_viewport().get_camera_3d()
	var eye := viewer.global_position if viewer else _camera.global_position
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
