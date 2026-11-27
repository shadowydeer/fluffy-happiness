extends SceneTree
## Headless gameplay regression: boots the real game and plays it through the
## player's own input paths and the demon's debug hooks.
##   godot --headless --fixed-fps 60 --path . -s tools/smoke_test.gd
## Stage 1 / 1.5: van doors, grab, ramp, throw, house trigger, camera, lamp, crouch, jump.
## Stage 2: ragdoll layout and stability, grab prompts, haunting, knockdown,
##          poltergeist throw, stun / bind, dragging the demon up the ramp, capture.
## Exits 0 when every check passes, 1 otherwise.

const ENRAGED := 2
const POLTERGEIST := 3
const STUNNED := 4
const CAPTURED := 5
const TORSO := 1

var _main: Node
var _player: CharacterBody3D
var _state: Node
var _hud: Node
var _van: Node3D
var _demon: Node3D
var _brain: Node
var _prop: RigidBody3D
var _tick := 0
var _step := 0
var _step_tick := 0
var _failures := 0
var _rear := Vector3.ZERO
var _outward := Vector3.ZERO
var _struggles: Array[float] = []
var _knockdowns := 0
var _swipes_before := 0
var _peak_cast_speed := 0.0
var _peak_lift := 0.0
var _peak_vignette := 0.0
var _lowest_eye := 9.0
var _drag_start := Vector3.ZERO


func _initialize() -> void:
	_main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	_state = root.get_node("GameState")


func _check(label: String, ok: bool, detail: String = "") -> void:
	print("%s  %s%s" % ["PASS" if ok else "FAIL", label, ("  (" + detail + ")") if not detail.is_empty() else ""])
	if not ok:
		_failures += 1


func _next() -> void:
	_step += 1
	_step_tick = 0


func _place(at: Vector3, look_at_point: Vector3, pitch: float = 0.0) -> void:
	_player.global_position = at
	_player.velocity = Vector3.ZERO
	var flat := look_at_point - at
	_player.rotation.y = atan2(-flat.x, -flat.z)
	_player.set("_pitch", pitch)


## A real key press through the viewport, so the Stage 2 test keys are checked end to end.
func _tap(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	root.push_input(event)


## First-person aim: turn and tilt the view straight at a world point.
func _aim_at(point: Vector3) -> void:
	var eye := (_player.get_node("Head") as Node3D).global_position
	var to := point - eye
	_player.rotation.y = atan2(-to.x, -to.z)
	_player.set("_pitch", atan2(to.y, Vector2(to.x, to.z).length()))


func _press(action: StringName) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)


func _done(step: StringName) -> bool:
	return _state.call("is_step_done", step)


func _torso() -> RigidBody3D:
	return _demon.call("get_body", TORSO)


func _demon_height() -> float:
	return _torso().global_position.y - (_demon.call("get_ground_position") as Vector3).y


func _physics_process(_delta: float) -> bool:
	_tick += 1
	_step_tick += 1
	if _player == null:
		_player = _main.get("player")
		_hud = _main.get("hud")
		_demon = _main.get("demon")
		_brain = _demon.get_node("AI")
		_van = (_main.get("level") as Node).get("van")
		# Keep the demon lurking until the Stage 2 half of the run.
		_brain.set("passive", true)
		# Pin it to the dais: its random peeking spots can be in view of the front hall,
		# which would (correctly) discover it before the "locate" step is exercised.
		_brain.set("_lurk_node", ((_main.get("level") as Node).get("lurk_nodes") as PackedInt32Array)[0])
		_brain.set("_lurk_left", 999.0)
		_demon.connect("struggled", func(strength: float) -> void: _struggles.append(strength))
		_player.connect("knocked_down", func(_duration: float) -> void: _knockdowns += 1)
		return false
	_peak_vignette = maxf(_peak_vignette, (_hud.get("_vignette") as Control).modulate.a)
	match _step:
		0:  # settle
			if _step_tick == 40:
				_check("player stands at spawn", _player.is_on_floor(), str(_player.global_position))
				_check("contract starts empty", not _done(&"open_van") and not _done(&"locate_demon"))
				# Going in before opening the van must not leave the tracker stuck on the doors.
				_state.call("complete_step", &"enter_house")
				_check("tracker follows the demon if the van was skipped", str(_state.call("get_current_task")).begins_with("Locate the demon"), str(_state.call("get_current_task")))
				_state.call("revoke_step", &"enter_house")
				_check("tracker starts on the van", str(_state.call("get_current_task")).begins_with("Open the van"))
				_check_demon_layout()
				var left: Node3D = _van.get("left_door")
				var right: Node3D = _van.get("right_door")
				_rear = (left.global_position + right.global_position) * 0.5
				_outward = ((_rear - _van.global_position) * Vector3(1, 0, 1)).normalized()
				_place(Vector3(_rear.x, 0.1, _rear.z) + _outward * 3.4, left.global_position)
				_next()
		1:  # open the rear doors with F
			if _step_tick == 20:
				var left: Node3D = _van.get("left_door")
				var target := left.global_position.lerp(_rear, 0.5)
				# The third-person camera sits over the right shoulder; line that up with the door.
				var shoulder := (-_outward).cross(Vector3.UP) * 0.7
				_player.global_position = Vector3(target.x, _player.global_position.y, target.z) + _outward * 2.2 - shoulder
				var eye := _player.global_position + Vector3.UP * 1.62
				_player.rotation.y = atan2(_outward.x, _outward.z)
				_player.set("_pitch", atan2(target.y - eye.y - 0.1, 2.2))
			if _step_tick == 30:
				_check("rear door is targetable", _player.get("_aim_interactable") != null, str(_player.get("_aim_prompt")))
				_press(&"interact")
			if _step_tick == 150:
				_check("F opens both rear doors", _van.get("left_door").get("is_open") and _van.get("right_door").get("is_open"))
				_check("objective: open van", _done(&"open_van"))
				var swing: float = absf((_van.get("left_door") as Node3D).rotation.y)
				_check("door leaf physically swung", swing > 0.8, "%.2f rad" % swing)
				_next()
		2:  # pick a light prop, set it at the ramp foot and grab it
			if _step_tick == 1:
				for node in get_nodes_in_group(&"grabbable"):
					var body := node as RigidBody3D
					if body and not body.freeze and body.mass <= 6.0 and body.mass >= 1.0:
						_prop = body
						break
				_check("found a grabbable prop", _prop != null, str(_prop.get_meta(&"display_name", _prop.name)) if _prop else "")
				_place(Vector3(_rear.x, 0.1, _rear.z) + _outward * 4.6, _rear)
				_prop.global_position = _player.global_position - _outward * 1.4 + (-_outward).cross(Vector3.UP) * 0.7 + Vector3.UP * 0.6
				_prop.linear_velocity = Vector3.ZERO
				_prop.angular_velocity = Vector3.ZERO
			if _step_tick == 50:
				var eye := _player.global_position + Vector3.UP * 1.62
				var to := _prop.global_position - eye - (-_outward).cross(Vector3.UP) * 0.7
				_player.set("_pitch", atan2(to.y, Vector2(to.x, to.z).length()))
			if _step_tick == 60:
				Input.action_press(&"grab")
			if _step_tick == 75:
				_check("LMB grabs the prop", _player.call("get_held") == _prop, str(_player.get("_aim_prompt")))
				_player.set("_pitch", -0.15)
			if _step_tick == 110:
				_check("grab tether is drawn", (_player.get_node("GrabTether") as Node3D).visible)
				_check("prop is carried, not frozen", not _prop.freeze and _prop.global_position.y > 0.7, str(_prop.global_position))
				_next()
		3:  # haul it up the ramp into the cargo bay
			if _step_tick == 1:
				Input.action_press(&"move_forward")
			if _step_tick == 200:
				Input.action_release(&"move_forward")
				_check("walked up the ramp into the bay without snagging", _player.global_position.y > 0.5 and (_player.global_position - _rear).dot(-_outward) > 0.3,
						"player %s rear %s" % [_player.global_position, _rear])
				_check("cage sensor sees the carried prop", (_van.get("cargo_zone") as Area3D).overlaps_body(_prop))
				_check("still holding after the haul", _player.call("get_held") == _prop)
				_next()
		4:  # throw
			if _step_tick == 5:
				_press(&"throw")
			if _step_tick == 9:
				Input.action_release(&"grab")
				_check("RMB throws the prop", _player.call("get_held") == null and _prop.linear_velocity.length() > 3.0, "%.1f m/s" % _prop.linear_velocity.length())
				_check("own throw does not floor the thrower", not _player.call("is_knocked_down"))
				_next()
		5:  # house
			if _step_tick == 1:
				_place(Vector3(-5.0, 0.6, -9.0), Vector3(-5.0, 0.6, -20.0))
			if _step_tick == 30:
				_check("objective: enter house", _done(&"enter_house"))
				_check("floor holds inside the house", _player.is_on_floor(), str(_player.global_position))
				_next()
		6:  # camera, lamp, crouch, jump
			if _step_tick == 1:
				_press(&"toggle_camera")
				_press(&"toggle_flashlight")
			if _step_tick == 5:
				Input.action_press(&"crouch")
			if _step_tick == 40:
				_check("V switches to first person", _player.get("first_person") == true)
				_check("T switches the headlamp off", _player.get("flashlight_on") == false and not (_player.get_node("Head/Flashlight") as Node3D).visible)
				var capsule := (_player.get_node("CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
				_check("Ctrl crouches", capsule.height < 1.25, "%.2f m" % capsule.height)
				Input.action_release(&"crouch")
			if _step_tick == 80:
				Input.action_press(&"jump")
			if _step_tick == 84:
				Input.action_release(&"jump")
				_check("Space jumps", _player.velocity.y > 2.0, "%.1f m/s" % _player.velocity.y)
			if _step_tick == 100:
				var crew := 0
				for child in _main.get_children():
					if String(child.name).begins_with("Crew"):
						crew += 1
				_check("squad of three is on site", crew == 3)
				_next()
		7:  # the demon, lurking: stands, haunts the candles, can be targeted
			if _step_tick == 1:
				_check("demon lurks on its feet", _demon_height() > 0.75 and _torso().global_transform.basis.y.y > 0.5,
						"chest %.2f m up, upright %.2f" % [_demon_height(), _torso().global_transform.basis.y.y])
				_check("demon has not been found yet", not _done(&"locate_demon") and not _hud.call("is_demon_status_visible"))
				_demon.call("place", Transform3D(Basis(Vector3.UP, PI), Vector3(-6.2, 0.45, -18.6)))
				_brain.set("_lurk_node", 1)
				_brain.set("_lurk_left", 999.0)
				_place(Vector3(-6.2, 0.6, -16.3), Vector3(-6.2, 0.6, -18.6))
			if _step_tick > 1 and _step_tick < 90:
				_aim_at(_torso().global_position)
			if _step_tick == 90:
				var prompt := str(_player.get("_aim_prompt"))
				_check("crosshair names the demon part", prompt.contains("GRAB DEMON ("), prompt)
				_check("objective: locate the demon", _done(&"locate_demon"))
				_check("HUD demon status appears", _hud.call("is_demon_status_visible"))
				_check("candles and lamps near it are haunted", float(_brain.get("peak_haunt")) > 0.3, "%.2f" % float(_brain.get("peak_haunt")))
				Input.action_press(&"grab")
				_next()
		8:  # laying hands on it while it is awake gets you floored
			_lowest_eye = minf(_lowest_eye, (_player.get_node("Head") as Node3D).position.y)
			if _step_tick == 50:
				Input.action_release(&"grab")
				_check("grabbing a conscious demon enrages it", int(_brain.get("state")) == ENRAGED, str(_brain.call("get_state_name")))
				_check("its swipe knocks the player down", _knockdowns == 1 and _player.call("is_knocked_down"))
				_check("knockdown drops whatever was held", _player.call("get_held") == null)
				_check("red vignette flashes", _peak_vignette > 0.4, "%.2f" % _peak_vignette)
				_check("knockback sends the player sliding", Vector2(_player.velocity.x, _player.velocity.z).length() > 1.0 or _player.global_position.distance_to(Vector3(-6.2, 0.45, -16.3)) > 1.0)
				# Park the demon while the player recovers.
				_tap(KEY_K)
			if _step_tick == 110:
				_check("camera drops to the floor", _lowest_eye < 0.7, "%.2f m" % _lowest_eye)
				_check("K stuns: demon state", _demon.get("is_stunned") and int(_brain.get("state")) == STUNNED and float(_demon.get("stun_meter")) > 90.0)
				_check("objective: subdue the demon", _done(&"subdue_demon"))
				_tap(KEY_F1)
				_check("F1 expands the test-key hint", str((_hud.get("_debug_hint") as Label).text).contains("stun / wake"))
				_tap(KEY_F1)
			if _step_tick == 170:
				# Limp means on the floor, or slumped over whatever it fell on (now and then, the player).
				var chest_up := _torso().global_position.y - 0.45
				var torso_upright := _torso().global_transform.basis.y.y
				_check("stunned demon collapses", chest_up < 0.6 or torso_upright < 0.5, "chest %.2f m above the floor, upright %.2f" % [chest_up, torso_upright])
				_check("stun meter drains", float(_demon.get("stun_meter")) < 99.0, "%.1f" % float(_demon.get("stun_meter")))
				_check("player gets back up", not _player.call("is_knocked_down"))
				_check("knockdown immunity holds", _player.call("is_knockdown_immune") and not _player.call("knock_down", Vector3(3, 2, 0)))
				_tap(KEY_L)
				_check("L raises the bind level", int(_demon.get("bind_level")) == 1 and str((_hud.get("_bind_count") as Label).text) == "1/3")
				var loose: Dictionary = _demon.call("get_grab_tuning", _torso())
				for i in 3:
					_tap(KEY_L)
				var tight: Dictionary = _demon.call("get_grab_tuning", _torso())
				_check("bind level wraps back to 0 and eases the drag", int(_demon.get("bind_level")) == 0 and float(loose["force"]) > float(tight["force"]))
			if _step_tick == 300:
				_check("immunity expires", not _player.call("is_knockdown_immune"))
				_next()
		9:  # wake it, then make it throw furniture
			if _step_tick == 1:
				_tap(KEY_K)
			if _step_tick == 100:
				_check("K wakes: demon scrambles upright, enraged", not _demon.get("is_stunned") and int(_brain.get("state")) == ENRAGED and _demon_height() > 0.8,
						"%s, chest %.2f m up" % [_brain.call("get_state_name"), _demon_height()])
				_check("waking re-opens the subdue objective", not _done(&"subdue_demon"))
				_demon.call("place", Transform3D(Basis.IDENTITY, Vector3(-6.2, 0.45, -13.3)))
				_place(Vector3(-4.6, 0.6, -6.6), Vector3(-6.2, 0.6, -13.3))
				_brain.set("_throw_left", 99.0)
				_brain.set("_windup_left", 0.0)
			if _step_tick == 110:
				_swipes_before = int(_brain.get("swipes_landed"))
				_knockdowns = 0
				_tap(KEY_J)
				_check("J forces a poltergeist throw", int(_brain.get("state")) == POLTERGEIST, str(_brain.call("get_state_name")))
			if _step_tick > 110 and _step_tick <= 220:
				for cast: Dictionary in _brain.get("_casts"):
					var prop: Variant = cast["prop"]
					if is_instance_valid(prop):
						_peak_lift = maxf(_peak_lift, (prop as RigidBody3D).global_position.y - (cast["start"] as Vector3).y)
				for node in get_nodes_in_group(&"grabbable"):
					var body := node as RigidBody3D
					if body and body.linear_velocity.length() > _peak_cast_speed and body.global_position.distance_to(_player.global_position) < 12.0:
						_peak_cast_speed = body.linear_velocity.length()
			if _step_tick == 220:
				_check("props levitate before launch", _peak_lift > 0.8, "%.2f m" % _peak_lift)
				_check("props are hurled", int(_brain.get("throws_launched")) >= 1 and _peak_cast_speed > 9.0, "%d launched, %.1f m/s" % [int(_brain.get("throws_launched")), _peak_cast_speed])
				_check("a thrown prop floors the player", _knockdowns >= 1 and int(_brain.get("swipes_landed")) == _swipes_before,
						"%d knockdowns, %d swipes" % [_knockdowns, int(_brain.get("swipes_landed")) - _swipes_before])
			# Aiming is skewed while the camera is still on the floor: let the player get up first.
			if _step_tick >= 220 and not _player.call("is_knocked_down") and float(_player.get("_knock_blend")) < 0.02:
				_next()
		10:  # stun it again and drag it up the ramp into the cage
			if _step_tick == 1:
				_tap(KEY_K)
				_demon.call("place", Transform3D(Basis.IDENTITY, Vector3(_rear.x, 0.0, _rear.z) + _outward * 4.6))
				_place(Vector3(_rear.x, 0.1, _rear.z) + _outward * 2.7, _rear + _outward * 6.0)
				_struggles.clear()
			if _step_tick > 80 and _step_tick < 100:
				_aim_at(_torso().global_position)
			if _step_tick == 100:
				var prompt := str(_player.get("_aim_prompt"))
				_check("stunned demon offers a drag prompt", prompt.contains("DRAG DEMON ("), prompt)
				Input.action_press(&"grab")
			if _step_tick == 115:
				var held: RigidBody3D = _player.call("get_held")
				_check("LMB grabs a demon segment", held != null and held.has_meta(&"demon"), str(_player.get("_aim_prompt")))
				_check("prompt switches to dragging", str(_player.get("_aim_prompt")).begins_with("DRAGGING DEMON"))
				_drag_start = _torso().global_position
				# Haul like a player would: back straight up the middle of the ramp. Backing away
				# along the line to wherever the body fell can park the player in a corner of the bay.
				_player.rotation.y = atan2(-_outward.x, -_outward.z)
				_player.set("_pitch", -0.35)
				Input.action_press(&"move_back")
			if _step_tick == 520 or (_step_tick > 115 and int(_brain.get("state")) == CAPTURED):
				Input.action_release(&"move_back")
				_check("the ragdoll follows the grab", _torso().global_position.distance_to(_drag_start) > 2.0, "%.1f m" % _torso().global_position.distance_to(_drag_start))
				_check("dragged up the ramp into the cage: CAPTURED", int(_brain.get("state")) == CAPTURED and _brain.get("is_in_van") == true,
						"%s, torso %s" % [_brain.call("get_state_name"), _torso().global_position])
				_check("objective: demon in the van", _done(&"load_demon"))
				_check("it thrashed while being dragged", not _struggles.is_empty() and _struggles.max() >= 0.99, str(_struggles))
				Input.action_release(&"grab")
				_next()
		11:  # shut the doors on it
			if _step_tick == 20:
				(_van.get("left_door") as Node).call("set_open", false)
			if _step_tick == 60:
				_check("closing the doors seals the capture", _brain.get("is_sealed") == true and _done(&"seal_van"))
				_check("contract complete", _state.call("is_contract_complete"))
				_check("caged demon stays stunned", _demon.get("is_stunned") and float(_demon.get("stun_meter")) > 50.0)
				_finish()
				return true
	if _tick > 6000:
		print("RESULT TIMEOUT at step ", _step)
		quit(1)
		return true
	return false


func _check_demon_layout() -> void:
	var bodies: Array = _demon.call("get_bodies")
	var layers_ok := true
	var core_mass := 0.0
	for index in bodies.size():
		var body: RigidBody3D = bodies[index]
		if body.collision_layer != 16 or body.collision_mask & 16 != 0 or body.collision_mask & 7 != 7:
			layers_ok = false
		if index <= 1:
			core_mass += body.mass
	_check("ragdoll: 11 segments on 10 joints", bodies.size() == 11 and int(_demon.call("get_joint_count")) == 10)
	_check("ragdoll: demon_limbs layer never masks itself", layers_ok)
	_check("ragdoll: mass distribution", absf(core_mass - 26.0) < 2.1 and is_equal_approx((bodies[2] as RigidBody3D).mass, 4.0), "core %.0f kg, total %.0f kg" % [core_mass, float(_demon.call("get_total_mass"))])
	_check("ragdoll: continuous collision on the core", (bodies[0] as RigidBody3D).continuous_cd and (bodies[1] as RigidBody3D).continuous_cd)
	var textured := true
	for set_name: String in ["charred_skin", "cracked_bone"]:
		for map: String in ["albedo", "normal", "roughness"]:
			if not ResourceLoader.exists("res://assets/textures/demon/%s/%s_%s.jpg" % [set_name, set_name, map]):
				textured = false
	_check("demon PBR texture sets are local", textured)


func _finish() -> void:
	var finite := true
	for body: RigidBody3D in _demon.call("get_bodies"):
		if not (body.global_position.is_finite() and body.linear_velocity.is_finite() and body.angular_velocity.is_finite()):
			finite = false
	_check("ragdoll stayed finite and never needed rebuilding", finite and int(_demon.get("fault_count")) == 0,
			"%d rebuilds, peak segment speed %.1f m/s" % [int(_demon.get("fault_count")), float(_demon.get("peak_speed"))])
	var cues: Dictionary = _demon.get_node("Audio").get("cue_counts")
	_check("audio cues fired", int(cues["roar"]) > 0 and int(cues["whoosh"]) > 0 and int(cues["buzz"]) > 0, str(cues))
	var loader := root.get_node("ModelLoader")
	_check("no missing models", int(loader.call("get_missing_count")) == 0, "%d loaded" % int(loader.call("get_loaded_count")))
	print("RESULT %s (%d failed)" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(0 if _failures == 0 else 1)
