extends SceneTree
## Headless Stage 3 regression: boots the real game in the yard beside the van and
## works the exorcist's gadgets through the player's own input paths.
##   godot --headless --fixed-fps 60 --path . -s tools/stage3_test.gd
## Belt: slot keys, mouse wheel, E hand-grab lowering the tool, HUD slots, hints, bank.
## Holy Lasso: 11 m range, forgiving 0.22 m cast, collar, spring tension, reeling,
##             anchoring, R release, tug of war with a conscious demon, the anchor snapping.
## Holy Taser: props, 48 stun/s, convulsions and shock rim, battery, overheat lockout.
## Duct Tape:  1.8 s wraps, interruption, +20 stun, bands on BoneAttachment3D per level,
##             struggle scaling, hauling the bound demon on the rope, the open-doors hint.
## The seal / payout / next-contract half of the loop lives in tools/smoke_test.gd.
## Exits 0 when every check passes, 1 otherwise.

const IDLE := 0
const ATTACHED := 2
const ANCHORED := 3
const ENRAGED := 2
const STUNNED := 4
const TORSO := 1
## A straight, empty strip of yard west of the van; the player faces east along it.
const ARENA := Vector3(-13.0, 0.1, 9.0)
const EAST := Vector3.RIGHT
const SOUTH := Vector3.BACK
const MAIN_CHILDREN: Array[String] = ["WorldEnvironment", "Moonlight", "Moon", "Level", "Player", "HUD", "Demon", "Crew1", "Crew2", "Crew3", "InteriorAir", "Contracts"]

var _main: Node
var _state: Node
var _player: CharacterBody3D
var _hud: Node
var _gadgets: Node
var _lasso: Node
var _taser: Node
var _tape: Node
var _contracts: Node
var _van: Node3D
var _demon: Node3D
var _brain: Node
var _visuals: Node
var _crate: RigidBody3D
var _tick := 0
var _step := 0
var _step_tick := 0
var _failures := 0
var _held: Dictionary = {}
var _immune := false

var _all_finite := true
var _peak_demon_speed := 0.0
var _peak_demon_note := ""
var _peak_tension := 0.0
var _peak_crate_speed := 0.0
var _saw_bolts := false
var _saw_light := false
var _saw_sparks := false
var _peak_shock := 0.0
var _peak_shock_uniform := 0.0
var _peak_spin := 0.0
var _peak_trauma := 0.0
var _saw_strain := false
var _saw_wrapping_anchored := false
var _mark := 0.0
var _mark_tick := 0
var _mark_position := Vector3.ZERO
var _fire_tick := 0
var _stun_tick := 0
var _overheat_tick := 0
var _anchor_tick := 0
var _snap_tick := 0
var _last_meter := 0.0
var _last_label := ""
var _wraps: Array[Dictionary] = []
var _tuning: Array[Dictionary] = []


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
	for action: StringName in _held.keys():
		_hold(action, false)


## A real key press through the viewport, as the player's keyboard would send it.
func _tap(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	root.push_input(event)


func _wheel(button: MouseButton) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	root.push_input(event)


func _hold(action: StringName, down: bool) -> void:
	if down:
		Input.action_press(action)
		_held[action] = true
	else:
		Input.action_release(action)
		_held.erase(action)


## First-person aim: turn and tilt the view straight at a world point.
func _aim_at(point: Vector3) -> void:
	var eye := (_player.get_node("Head") as Node3D).global_position
	var to := point - eye
	_player.rotation.y = atan2(-to.x, -to.z)
	_player.set("_pitch", atan2(to.y, Vector2(to.x, to.z).length()))


func _stand(at: Vector3, look: Vector3) -> void:
	_player.global_position = at
	_player.velocity = Vector3.ZERO
	_aim_at(look)


func _torso() -> RigidBody3D:
	return _demon.call("get_body", TORSO)


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _slot(index: int) -> Control:
	return _hud.call("get_gadget_slot", index)


func _cues() -> Dictionary:
	return (_gadgets.get("audio") as Node).get("cue_counts")


func _mesh_count(node: Node) -> int:
	var count := 1 if node is MeshInstance3D else 0
	for child in node.get_children():
		count += _mesh_count(child)
	return count


## Sculpted parts (lathed, swept or ribboned ArrayMeshes), as opposed to stock primitives.
func _sculpted_count(node: Node) -> int:
	var count := 1 if node is MeshInstance3D and (node as MeshInstance3D).mesh is ArrayMesh else 0
	for child in node.get_children():
		count += _sculpted_count(child)
	return count


func _box_count(node: Node) -> int:
	var count := 1 if node is MeshInstance3D and (node as MeshInstance3D).mesh is BoxMesh else 0
	for child in node.get_children():
		count += _box_count(child)
	return count


func _debug_nodes(node: Node, found: Array[String]) -> void:
	var pattern := RegEx.create_from_string("(?i)(ruler|height|measure|gizmo|marker|debug|reference)")
	if node is Node3D and pattern.search(String(node.name)) != null:
		found.append(String(node.get_path()))
	for child in node.get_children():
		_debug_nodes(child, found)


func _visible_bands() -> Array[MeshInstance3D]:
	var bands: Array[MeshInstance3D] = []
	for tier: Array in _visuals.get("_tape"):
		for band: MeshInstance3D in tier:
			if band.visible:
				bands.append(band)
	return bands


func _make_crate() -> void:
	_crate = RigidBody3D.new()
	_crate.name = "TestCrate"
	_crate.mass = 3.0
	_crate.collision_layer = 4
	_crate.collision_mask = 1 | 2 | 4 | 8 | 16
	_crate.add_to_group(&"grabbable")
	_crate.set_meta(&"display_name", "Test crate")
	var box := BoxShape3D.new()
	box.size = Vector3.ONE * 0.3
	var shape := CollisionShape3D.new()
	shape.shape = box
	_crate.add_child(shape)
	_main.add_child(_crate)


func _put_crate(at: Vector3) -> void:
	var xf := Transform3D(Basis.IDENTITY, at)
	_crate.linear_velocity = Vector3.ZERO
	_crate.angular_velocity = Vector3.ZERO
	_crate.global_transform = xf
	PhysicsServer3D.body_set_state(_crate.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	PhysicsServer3D.body_set_state(_crate.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(_crate.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	_crate.sleeping = false


## Invariants and peaks, sampled on every tick of the whole run.
func _watch() -> void:
	if _immune:
		_player.set("_immune_left", 5.0)
	if not (_player.global_position.is_finite() and _player.velocity.is_finite()):
		_all_finite = false
	if is_instance_valid(_demon):
		for body: RigidBody3D in _demon.call("get_bodies"):
			if not (body.global_position.is_finite() and body.linear_velocity.is_finite() and body.angular_velocity.is_finite()):
				_all_finite = false
			if body.linear_velocity.length() > _peak_demon_speed:
				_peak_demon_speed = body.linear_velocity.length()
				_peak_demon_note = "%s at tick %d" % [str(body.get_meta(&"demon_label", body.name)), _step_tick]
			if bool(_taser.get("firing")):
				_peak_spin = maxf(_peak_spin, body.angular_velocity.length())
	if is_instance_valid(_crate):
		if not (_crate.global_position.is_finite() and _crate.linear_velocity.is_finite()):
			_all_finite = false
		_peak_crate_speed = maxf(_peak_crate_speed, _crate.linear_velocity.length())
	var tension := float(_lasso.get("tension"))
	if not is_finite(tension) or not is_finite(float(_lasso.get("rest_length"))):
		_all_finite = false
	_peak_tension = maxf(_peak_tension, tension)
	if bool(_taser.get("firing")):
		_saw_bolts = _saw_bolts or (_taser.get("_bolts") as Node3D).visible
		_saw_light = _saw_light or (_taser.get("_light") as Node3D).visible
		_saw_sparks = _saw_sparks or (_taser.get("_sparks") as GPUParticles3D).emitting
		_peak_trauma = maxf(_peak_trauma, float(_player.get("_trauma")))
	if _visuals:
		_peak_shock = maxf(_peak_shock, float(_visuals.get("_shock")))
		var skin := _visuals.get("_skin") as ShaderMaterial
		if skin:
			_peak_shock_uniform = maxf(_peak_shock_uniform, float(skin.get_shader_parameter(&"shock")))
	_saw_strain = _saw_strain or (_lasso.get("_strain_sparks") as GPUParticles3D).emitting


func _physics_process(_delta: float) -> bool:
	_tick += 1
	_step_tick += 1
	if _player == null:
		_player = _main.get("player")
		_hud = _main.get("hud")
		_contracts = _main.get("contracts")
		_van = (_main.get("level") as Node).get("van")
		_gadgets = _player.get("gadgets")
		_lasso = _gadgets.get("lasso")
		_taser = _gadgets.get("taser")
		_tape = _gadgets.get("tape")
		_demon = _main.get("demon")
		_brain = _demon.get_node("AI")
		_visuals = _demon.get_node("Visuals")
		# The demon keeps to its dais until it is summoned.
		_brain.set("passive", true)
		_player.call("set_first_person", true)
		_stand(ARENA, ARENA + EAST * 6.0 + Vector3.UP * 1.6)
		return false
	_watch()
	match _step:
		0:
			_step_settle()
		1:
			_step_belt()
		2:
			_step_hand_grab()
		3:
			_step_taser_prop()
		4:
			_step_lasso_prop()
		5:
			_step_lasso_demon()
		6:
			_step_taser_demon()
		7:
			_step_tape()
		8:
			_step_haul()
		9:
			_step_wrap_up()
			return true
	if _tick > 9000:
		print("RESULT TIMEOUT at step %d tick %d" % [_step, _step_tick])
		quit(1)
		return true
	return false


# --- 0: the site as the player finds it ---------------------------------------------------

func _step_settle() -> void:
	if _step_tick == 60:
		var space := _player.get_world_3d().direct_space_state
		var blocked := ""
		for height: float in [0.3, 1.3]:
			var from := Vector3(ARENA.x + 0.6, height, ARENA.z)
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + EAST * 13.0, 1 | 4 | 8 | 16, [_player.get_rid()]))
			if not hit.is_empty():
				blocked = "%s at %s" % [(hit["collider"] as Node).name, hit["position"]]
		_check("test strip of yard is empty", blocked.is_empty() and _player.is_on_floor(), blocked)
		var strays: Array[String] = []
		for child in _main.get_children():
			if not MAIN_CHILDREN.has(String(child.name)):
				strays.append(String(child.name))
		_debug_nodes(_main, strays)
		_check("no debug height pole or stray marker anywhere in the live scene", strays.is_empty(), str(strays))
		var slots_ok := true
		for i in 3:
			var slot := _slot(i)
			if slot == null or int(slot.get("kind")) != i + 1 or (slot.get_script() as Script).resource_path != "res://scripts/GadgetSlotIcon.gd":
				slots_ok = false
		_check("HUD belt has three drawn slots keyed 1-3", slots_ok and float(_slot(1).get("battery")) > 0.99 and float(_slot(0).get("battery")) < 0.0)
		_check("HUD shows the bank at $0 under the contract header", _hud.call("get_bank_text") == "$0" and int(_state.get("bank_cash")) == 0
				and str(_hud.get("_title").text) == "CONTRACT #0413 // 13 HOLLOW LANE", str(_hud.get("_title").text))
		_check("objective chain opens on finding the demon", str(_hud.get("_task").text) == "> Enter the cursed house & locate the demon"
				and (_state.get("STEPS") as Array).size() == 4, str(_hud.get("_task").text))
		_check("empty hands: classic grab hint", int(_gadgets.get("slot")) == 0 and str(_hud.call("get_gadget_hint")).contains("[LMB / E] Grab"), str(_hud.call("get_gadget_hint")))
		_check("nothing counts as damaged while the house settles", int(_contracts.get("damaged_props")) == 0)
		_tap(KEY_F1)
	if _step_tick == 62:
		var keys := str(_hud.get("_debug_hint").text)
		_check("F1 unfolds the test keys K / J / L / P", keys.contains("K   stun") and keys.contains("J   cycle") and keys.contains("L   cycle") and keys.contains("P   summon"))
		_tap(KEY_F1)
	if _step_tick == 64:
		_check("F1 folds them away again", str(_hud.get("_debug_hint").text) == "F1  test keys")
		_next()


# --- 1: the belt ---------------------------------------------------------------------------

func _step_belt() -> void:
	match _step_tick:
		1:
			_tap(KEY_1)
		30:
			var view: Node3D = _lasso.get("view")
			_check("1 draws the Holy Lasso", int(_gadgets.get("slot")) == 1 and _gadgets.call("get_title") == "HOLY LASSO" and float(_gadgets.call("get_raise")) > 0.95 and view.visible)
			_check("lasso is a sculpted multi-part model", _mesh_count(view) >= 8 and _sculpted_count(view) >= 4 and _box_count(view) == 0,
					"%d parts, %d sculpted, %d boxes" % [_mesh_count(view), _sculpted_count(view), _box_count(view)])
			_check("slot 1 lights up and the hint follows the tool", _slot(0).get("active") == true and _slot(1).get("active") == false
					and str(_hud.call("get_gadget_hint")).contains("[LMB] Shoot lasso") and str(_hud.call("get_gadget_hint")).contains("[RMB] Anchor"), str(_hud.call("get_gadget_hint")))
			_check("the gloves close on the grip", _view_hand_gap(_lasso) < 0.12, "%.3f m from palm to grip" % _view_hand_gap(_lasso))
			_tap(KEY_1)
		60:
			_check("pressing the active slot again empties the hands", int(_gadgets.get("slot")) == 0 and not (_lasso.get("view") as Node3D).visible and float(_gadgets.call("get_raise")) < 0.05)
			_tap(KEY_2)
		90:
			var view: Node3D = _taser.get("view")
			_check("2 draws the Holy Taser", int(_gadgets.get("slot")) == 2 and view.visible and _slot(1).get("active") == true)
			_check("taser is a sculpted multi-part model with five battery LEDs", _mesh_count(view) >= 12 and _sculpted_count(view) >= 4 and _box_count(view) == 0
					and (_taser.get("_leds") as Array).size() == 5 and (_taser.get("_prongs") as Array).size() == 2,
					"%d parts, %d sculpted, %d boxes" % [_mesh_count(view), _sculpted_count(view), _box_count(view)])
			_tap(KEY_3)
		120:
			var view: Node3D = _tape.get("view")
			_check("3 draws the Duct Tape, held in both gloves", int(_gadgets.get("slot")) == 3 and view.visible and _tape.get("two_handed") == true and _slot(2).get("active") == true)
			_check("tape roll is a sculpted multi-part model", _mesh_count(view) >= 8 and _sculpted_count(view) >= 3 and _box_count(view) == 0,
					"%d parts, %d sculpted, %d boxes" % [_mesh_count(view), _sculpted_count(view), _box_count(view)])
			_tap(KEY_0)
		150:
			_check("0 puts everything away", int(_gadgets.get("slot")) == 0 and not (_tape.get("view") as Node3D).visible)
			_wheel(MOUSE_BUTTON_WHEEL_DOWN)
		152:
			_check("mouse wheel down cycles to slot 1", int(_gadgets.get("slot")) == 1)
			_wheel(MOUSE_BUTTON_WHEEL_UP)
		154:
			_check("mouse wheel up cycles back to the hands", int(_gadgets.get("slot")) == 0)
			_wheel(MOUSE_BUTTON_WHEEL_UP)
		156:
			_check("the wheel wraps round to slot 3", int(_gadgets.get("slot")) == 3)
			_tap(KEY_0)
		160:
			_check("each swap makes a sound", int(_cues().get(&"equip", 0)) >= 7, str(_cues()))
			_next()


## Distance from the right glove's palm to the held model's grip point.
func _view_hand_gap(gadget: Node) -> float:
	var view: Node3D = gadget.get("view")
	var palm: Vector3 = _gadgets.call("get_hand_position")
	return palm.distance_to(view.global_transform * (gadget.get("palm_right") as Vector3))


# --- 2: E always grabs by hand -------------------------------------------------------------

func _step_hand_grab() -> void:
	if _step_tick == 1:
		_make_crate()
		_put_crate(ARENA + EAST * 1.7 + Vector3.UP * 0.16)
		_tap(KEY_2)
	if _step_tick > 1 and _step_tick < 150 and not _player.call("is_hand_grabbing"):
		_aim_at(_crate.global_position)
	match _step_tick:
		40:
			_check("armed: the grab prompt names E only", str(_player.get("_aim_prompt")).begins_with("[E] Grab"), str(_player.get("_aim_prompt")))
			# LMB is both actions on a real mouse.
			_hold(&"grab", true)
			_hold(&"gadget_fire", true)
		52:
			_check("armed: LMB works the gadget, not the hands", not _player.call("is_hand_grabbing") and _taser.get("firing") == true and float(_taser.get("battery")) < 99.0)
			_hold(&"grab", false)
			_hold(&"gadget_fire", false)
		60:
			_mark = float(_taser.get("battery"))
			_hold(&"hand_grab", true)
		85:
			_check("armed: E still grabs by hand", _player.call("is_hand_grabbing") == true and _player.call("get_held") == _crate)
			_check("the gadget drops out of the way but stays selected", float(_gadgets.call("get_raise")) < 0.05 and int(_gadgets.get("slot")) == 2 and not (_taser.get("view") as Node3D).visible)
			_hold(&"gadget_fire", true)
		95:
			_check("a lowered gadget cannot fire", _taser.get("firing") == false and float(_taser.get("battery")) >= _mark)
			_hold(&"gadget_fire", false)
			_hold(&"hand_grab", false)
		125:
			_check("letting go brings the gadget back up", not _player.call("is_hand_grabbing") and float(_gadgets.call("get_raise")) > 0.95 and (_taser.get("view") as Node3D).visible)
			_tap(KEY_0)
		150:
			_hold(&"grab", true)
		165:
			_check("empty hands: LMB grabs as before", _player.call("is_hand_grabbing") == true)
			_hold(&"grab", false)
		170:
			_next()


# --- 3: taser on furniture -----------------------------------------------------------------

func _step_taser_prop() -> void:
	if _step_tick == 1:
		_put_crate(ARENA + EAST * 2.2 + Vector3.UP * 0.16)
		_tap(KEY_2)
		_peak_crate_speed = 0.0
	if _step_tick < 70:
		_aim_at(_crate.global_position)
	match _step_tick:
		40:
			_mark = float(_taser.get("battery"))
			_mark_position = _crate.global_position
			_saw_bolts = false
			_saw_light = false
			_hold(&"gadget_fire", true)
		70:
			var battery := float(_taser.get("battery"))
			_check("taser arcs to a prop inside 3.8 m", _taser.get("firing") == true and _taser.get("_target") == _crate and _saw_bolts and _saw_light)
			_check("the prop is knocked back", _peak_crate_speed > 0.4 and _crate.global_position.distance_to(_mark_position) > 0.05,
					"%.2f m/s, moved %.2f m" % [_peak_crate_speed, _crate.global_position.distance_to(_mark_position)])
			_check("battery drains at 32 %/s", absf((_mark - battery) - 16.0) < 1.5, "%.1f %% in 0.5 s" % (_mark - battery))
			_check("HUD slot 2 shows the live battery", absf(float(_slot(1).get("battery")) - battery / 100.0) < 0.02)
			_check("electric buzz is playing", int(_cues().get(&"buzz", 0)) >= 1, str(_cues()))
			_hold(&"gadget_fire", false)
			_mark = battery
		100:
			_check("no recharge during the 0.6 s pause", absf(float(_taser.get("battery")) - _mark) < 0.01, "%.1f" % float(_taser.get("battery")))
		136:
			# 66 ticks after release: 0.6 s pause, then 0.5 s at 24 %/s.
			_check("then it recharges at 24 %/s", absf(float(_taser.get("battery")) - _mark - 12.0) < 1.0, "+%.1f %%" % (float(_taser.get("battery")) - _mark))
			_next()


# --- 4: lasso on a loose prop --------------------------------------------------------------

func _step_lasso_prop() -> void:
	var target := ARENA + EAST * 6.0 + Vector3.UP * 0.16
	match _step_tick:
		1:
			_put_crate(target)
			_stand(ARENA, target)
			_tap(KEY_1)
		40:
			_aim_at(target + SOUTH * 0.62)
		44:
			_hold(&"gadget_fire", true)
		46:
			_hold(&"gadget_fire", false)
		75:
			_check("a throw 0.47 m wide of the prop is a miss", int(_lasso.get("mode")) == IDLE and int(_lasso.get("shots_fired")) == 1 and _lasso.call("get_target") == null)
			_aim_at(target + SOUTH * 0.28)
		79:
			_hold(&"gadget_fire", true)
		81:
			_hold(&"gadget_fire", false)
		105:
			var collar := _crate.get_node_or_null("LassoCollar") as MeshInstance3D
			_check("the 0.22 m cast forgives a throw 0.13 m wide", int(_lasso.get("mode")) == ATTACHED and _lasso.call("get_target") == _crate)
			_check("a glowing collar is cinched round the prop", collar != null and collar.visible and collar.mesh is TorusMesh
					and (collar.material_override as StandardMaterial3D).emission_enabled)
			_check("the rope is drawn from hand to prop", (_lasso.get("_rope") as MeshInstance3D).visible and (_lasso.get("_rope_mesh") as ImmediateMesh).get_surface_count() == 1)
			_check("HUD slot 1 reads ATTACHED", str(_slot(0).get("badge")) == "ATTACHED" and str(_hud.call("get_gadget_hint")).contains("reel in"), str(_hud.call("get_gadget_hint")))
			_check("rest length is the throw's length", absf(float(_lasso.get("rest_length")) - 6.0) < 0.6, "%.2f m" % float(_lasso.get("rest_length")))
			_check("whip crack and clink", int(_cues().get(&"whip", 0)) == 2 and int(_cues().get(&"clink", 0)) == 1, str(_cues()))
			_mark_position = _crate.global_position
			_peak_tension = 0.0
			_peak_crate_speed = 0.0
			_aim_at(_crate.global_position)
			_hold(&"move_back", true)
		150:
			_hold(&"move_back", false)
			var dragged := _mark_position.x - _crate.global_position.x
			_check("backing up pulls the rope taut and drags the prop", dragged > 1.0 and _peak_tension > 0.05, "%.2f m, tension %.2f" % [dragged, _peak_tension])
			_check("the spring is clamped: no slingshot", _peak_crate_speed < 12.0, "%.1f m/s" % _peak_crate_speed)
			_mark = float(_lasso.get("rest_length"))
			_hold(&"gadget_fire", true)
		235:
			_hold(&"gadget_fire", false)
			_check("holding LMB reels the rope in", _mark - float(_lasso.get("rest_length")) > 2.2, "%.2f -> %.2f m" % [_mark, float(_lasso.get("rest_length"))])
		240:
			_check("a long hold is not a tap: still attached", int(_lasso.get("mode")) == ATTACHED)
			_aim_at(_player.global_position + EAST * 8.0 + Vector3.UP * 1.6)
		244:
			_hold(&"gadget_alt", true)
		246:
			_hold(&"gadget_alt", false)
		250:
			_check("no anchor without a surface inside 3.5 m", int(_lasso.get("mode")) == ATTACHED and not (_lasso.get("_pin") as Node3D).visible)
			_aim_at(Vector3(_player.global_position.x + 1.4, 0.0, _player.global_position.z - 1.0))
		254:
			_hold(&"gadget_alt", true)
		256:
			_hold(&"gadget_alt", false)
		262:
			var pin: Node3D = _lasso.get("_pin")
			_check("RMB hammers an anchor pin into the ground", int(_lasso.get("mode")) == ANCHORED and pin.visible and absf(pin.global_position.y) < 0.15
					and _flat_distance(pin.global_position, _player.global_position) < 3.5, str(pin.global_position))
			_check("the pin is an iron spike with a glowing seal", _mesh_count(pin) >= 4 and _sculpted_count(pin) >= 1)
			_check("HUD slot 1 reads ANCHORED", str(_slot(0).get("badge")) == "ANCHORED" and str(_hud.call("get_gadget_hint")).contains("[R] Release"), str(_hud.call("get_gadget_hint")))
			_tap(KEY_2)
		290:
			_check("hands free: the anchored rope holds while the taser is out", int(_gadgets.get("slot")) == 2 and int(_lasso.get("mode")) == ANCHORED
					and (_lasso.get("_rope") as MeshInstance3D).visible and str(_slot(0).get("badge")) == "ANCHORED")
			_crate.linear_velocity = EAST * 7.0 + Vector3.UP * 1.5
		350:
			var anchor: Vector3 = _lasso.get("_anchor")
			var leash := anchor.distance_to(_crate.global_position)
			_check("the anchored prop cannot leave its leash", leash < float(_lasso.get("rest_length")) + 0.9, "%.2f m on a %.2f m rope" % [leash, float(_lasso.get("rest_length"))])
			_tap(KEY_R)
		380:
			_check("R reels the rope in from any slot", int(_lasso.get("mode")) == IDLE and _crate.get_node_or_null("LassoCollar") == null
					and not (_lasso.get("_pin") as Node3D).visible and not (_lasso.get("_rope") as MeshInstance3D).visible and str(_slot(0).get("badge")) == "")
			_tap(KEY_1)
			_put_crate(ARENA + EAST * 12.6 + Vector3.UP * 0.16)
			_stand(ARENA, ARENA + EAST * 12.6 + Vector3.UP * 0.16)
		420:
			_hold(&"gadget_fire", true)
		422:
			_hold(&"gadget_fire", false)
		450:
			_check("12.7 m is out of range", int(_lasso.get("mode")) == IDLE and _lasso.call("get_target") == null)
			_put_crate(ARENA + EAST * 10.2 + Vector3.UP * 0.16)
			_aim_at(ARENA + EAST * 10.2 + Vector3.UP * 0.16)
		470:
			_hold(&"gadget_fire", true)
		472:
			_hold(&"gadget_fire", false)
		500:
			_check("10.3 m is in range", int(_lasso.get("mode")) == ATTACHED and _lasso.call("get_target") == _crate)
			_hold(&"gadget_fire", true)
		503:
			_hold(&"gadget_fire", false)
		530:
			_check("a quick tap of LMB lets go", int(_lasso.get("mode")) == IDLE and _crate.get_node_or_null("LassoCollar") == null)
			_next()


# --- 5: lasso on a conscious demon ---------------------------------------------------------

func _step_lasso_demon() -> void:
	var chest := _torso().global_position
	if _step_tick == 1:
		_put_crate(ARENA + Vector3(-2.5, 0.16, 3.0))
		_stand(ARENA, ARENA + EAST * 4.0 + Vector3.UP * 1.4)
		_brain.set("passive", false)
		_immune = true
		_tap(KEY_P)
		return
	if _step_tick < 106 or _step_tick > 112:
		_aim_at(chest)
	match _step_tick:
		30:
			_check("P stands the demon in front of the player", _flat_distance(chest, _player.global_position) < 4.5 and _brain.get("is_discovered") == true
					and _state.call("is_step_done", &"locate_demon"), "%.1f m away" % _flat_distance(chest, _player.global_position))
			_check("HUD moves on to subduing it", str(_hud.get("_task").text) == "> Subdue the demon! [2: Holy Taser]" and _hud.call("is_demon_status_visible"), str(_hud.get("_task").text))
		40:
			_hold(&"gadget_fire", true)
		42:
			_hold(&"gadget_fire", false)
		60:
			var target: RigidBody3D = _lasso.call("get_target")
			_check("the lasso latches onto a ragdoll segment", int(_lasso.get("mode")) == ATTACHED and target != null and target.get_meta(&"demon") == _demon,
					str(target.get_meta(&"demon_label", "?")) if target else "nothing")
			_check("a collar rides the limb it caught", target != null and target.get_node_or_null("LassoCollar") != null)
			_check("roping it makes it ENRAGED", int(_brain.get("state")) == ENRAGED and not _demon.get("is_stunned"), str(_brain.call("get_state_name")))
			# Yank the rope tight: three metres more than it has.
			_mark = float(_player.get("stamina"))
			_peak_tension = 0.0
			_peak_demon_speed = 0.0
			_player.global_position += Vector3(-3.0, 0.0, 0.0)
			_mark_position = _player.global_position
		100:
			var hauled := _player.global_position.x - _mark_position.x
			_check("tug of war: holding it solo drains stamina", _mark - float(_player.get("stamina")) > 2.0 and _peak_tension > 0.3,
					"-%.1f stamina, tension %.2f" % [_mark - float(_player.get("stamina")), _peak_tension])
			_check("tug of war: it hauls the holder in", hauled > 0.25, "%.2f m with no input" % hauled)
			_check("no exploding tether", _peak_demon_speed < 20.0 and int(_demon.get("fault_count")) == 0 and _all_finite, "peak %.1f m/s" % _peak_demon_speed)
		106:
			_aim_at(Vector3(_player.global_position.x + 0.9, 0.0, _player.global_position.z - 1.1))
		109:
			_hold(&"gadget_alt", true)
		111:
			_hold(&"gadget_alt", false)
		116:
			_check("the roped demon is tied to the anchor", int(_lasso.get("mode")) == ANCHORED and _gadgets.call("is_demon_anchored", _demon) == true)
			_anchor_tick = _tick
			_tap(KEY_3)
	if _step_tick < 150:
		return
	# Tape it while the anchor holds: keep on it, keep the trigger down.
	if int(_lasso.get("mode")) == ANCHORED:
		_hold(&"gadget_fire", true)
		_hold(&"move_forward", _flat_distance(chest, _player.global_position) > 1.9)
		if bool(_tape.get("wrapping")):
			_saw_wrapping_anchored = true
	if _snap_tick == 0 and int(_lasso.get("snaps")) >= 1:
		_snap_tick = _tick
		_hold(&"gadget_fire", false)
		_hold(&"move_forward", false)
	if _snap_tick > 0 and _tick == _snap_tick + 40:
		var life := (_snap_tick - _anchor_tick) / 60.0
		_check("an enraged demon snaps the anchored rope after 8-12 s", life > 7.9 and life < 12.2, "%.1f s" % life)
		_check("sparks and creaking warn before it goes", _saw_strain and int(_cues().get(&"creak", 0)) >= 1 and int(_cues().get(&"snap", 0)) == 1, str(_cues()))
		_check("the snapped rope comes back to the hand", int(_lasso.get("mode")) == IDLE and not (_lasso.get("_pin") as Node3D).visible)
		_check("an anchored demon can be taped while still awake", _saw_wrapping_anchored and int(_demon.get("bind_level")) >= 1, "bind %d" % int(_demon.get("bind_level")))
		_check("thrashing on the anchor stayed stable", int(_demon.get("fault_count")) == 0 and _all_finite and _peak_demon_speed < 25.0, "peak %.1f m/s" % _peak_demon_speed)
		_next()
	elif _step_tick > 1100:
		_check("an enraged demon snaps the anchored rope after 8-12 s", false, "still %d after %.1f s" % [int(_lasso.get("mode")), (_tick - _anchor_tick) / 60.0])
		_next()


# --- 6: taser on the demon -----------------------------------------------------------------

func _step_taser_demon() -> void:
	var chest := _torso().global_position
	_aim_at(chest)
	if _step_tick == 1:
		_demon.call("set_bind_level", 0)
		_demon.set("stun_meter", 0.0)
		_tap(KEY_2)
		_peak_shock = 0.0
		_peak_shock_uniform = 0.0
		_peak_spin = 0.0
		_peak_trauma = 0.0
		_saw_bolts = false
		_saw_sparks = false
		return
	if _fire_tick == 0:
		# Close in first, so the whole burst lands.
		_hold(&"move_forward", _flat_distance(chest, _player.global_position) > 2.4)
		if _step_tick >= 40 and _flat_distance(chest, _player.global_position) < 3.0 and not _demon.get("is_stunned"):
			_check("the taser starts on a full battery", float(_taser.get("battery")) > 99.9, "%.1f" % float(_taser.get("battery")))
			_fire_tick = _tick
			_hold(&"gadget_fire", true)
		return
	if _stun_tick == 0:
		_hold(&"move_forward", _flat_distance(chest, _player.global_position) > 2.6)
		if _demon.get("is_stunned"):
			_stun_tick = _tick
			_hold(&"move_forward", false)
			var took := (_stun_tick - _fire_tick) / 60.0
			_check("about two seconds of current drops a fresh demon", took > 1.9 and took < 2.8, "%.2f s" % took)
			_check("it goes limp: STUNNED", int(_brain.get("state")) == STUNNED and _state.call("is_step_done", &"subdue_demon"), str(_brain.call("get_state_name")))
			_check("jagged arcs, sparks and a flickering light reach it", _saw_bolts and _saw_sparks and _saw_light)
			_check("its limbs convulse under the current", _peak_spin > 6.0, "%.1f rad/s" % _peak_spin)
			_check("the skin flares with an electric rim", _peak_shock > 0.9 and _peak_shock_uniform > 0.5, "shock %.2f, uniform %.2f" % [_peak_shock, _peak_shock_uniform])
			_check("the camera shakes with it", _peak_trauma > 0.05, "%.2f" % _peak_trauma)
			_check("HUD moves on to binding it", str(_hud.get("_task").text) == "> Bind with Duct Tape [3] & haul to the van", str(_hud.get("_task").text))
		elif _tick - _fire_tick > 400:
			_stun_tick = _tick
			_check("about two seconds of current drops a fresh demon", false, "stun %.0f after %.1f s" % [float(_demon.get("stun_meter")), (_tick - _fire_tick) / 60.0])
		return
	if _overheat_tick == 0:
		if int(_taser.get("overheats")) >= 1:
			_overheat_tick = _tick
			var took := (_overheat_tick - _fire_tick) / 60.0
			_check("a full battery lasts just over three seconds", took > 3.0 and took < 3.3, "%.2f s" % took)
			_check("running flat overheats it: 2.8 s lockout", float(_taser.get("battery")) <= 0.0 and absf(float(_taser.get("overheat_left")) - 2.8) < 0.05
					and (_taser.get("_steam") as GPUParticles3D).emitting, "%.2f s" % float(_taser.get("overheat_left")))
			_check("hiss and warning beep", int(_cues().get(&"hiss", 0)) == 1 and int(_cues().get(&"beep", 0)) == 1, str(_cues()))
		elif _tick - _fire_tick > 400:
			_overheat_tick = _tick
			_check("running flat overheats it: 2.8 s lockout", false, "battery %.1f" % float(_taser.get("battery")))
		return
	var since := _tick - _overheat_tick
	match since:
		30:
			_check("locked out: the trigger does nothing", _taser.get("firing") == false and float(_taser.get("battery")) <= 0.0 and str(_slot(1).get("badge")) == "OVERHEAT")
			_hold(&"gadget_fire", false)
		160:
			_check("still venting just before 2.8 s", float(_taser.get("overheat_left")) > 0.0 and float(_taser.get("battery")) <= 0.0)
		300:
			# 2.8 s lockout + 0.6 s pause, then 1.6 s at 24 %/s.
			var battery := float(_taser.get("battery"))
			_check("then it cools and recharges", float(_taser.get("overheat_left")) <= 0.0 and battery > 30.0 and battery < 46.0 and str(_slot(1).get("badge")) == "", "%.1f %%" % battery)
			_check("the demon is still out cold", _demon.get("is_stunned") == true and float(_demon.get("stun_meter")) > 60.0, "%.0f" % float(_demon.get("stun_meter")))
			_next()


# --- 7: duct tape --------------------------------------------------------------------------

func _step_tape() -> void:
	var chest := _torso().global_position
	if _step_tick == 1:
		_tap(KEY_3)
		_demon.set("stun_meter", 60.0)
		var away := (_player.global_position - chest) * Vector3(1.0, 0.0, 1.0)
		away = away.normalized() if away.length() > 0.1 else -EAST
		_player.global_position = Vector3(chest.x, 0.1, chest.z) + away * 1.9
		_player.velocity = Vector3.ZERO
		_tuning.append(_demon.call("get_grab_tuning", _torso()))
	_aim_at(chest)
	var level := int(_demon.get("bind_level"))
	var meter := float(_demon.get("stun_meter"))
	if _step_tick > 115 and level > _wraps.size():
		_wraps.append({"tick": _tick, "gain": meter - _last_meter, "bands": _visible_bands().size(), "label": _last_label})
		_tuning.append(_demon.call("get_grab_tuning", _torso()))
	_last_meter = meter
	if not str(_hud.call("get_progress_text")).is_empty():
		_last_label = str(_hud.call("get_progress_text"))
	match _step_tick:
		40:
			_hold(&"gadget_fire", true)
		94:
			var ring := float((_hud.call("get_crosshair") as Control).call("get_progress"))
			_check("holding LMB on a stunned demon starts a wrap", _tape.get("wrapping") == true and absf(float(_tape.get("progress")) - 0.5) < 0.06, "%.2f" % float(_tape.get("progress")))
			_check("crosshair ring and BINDING DEMON... 1/3", str(_hud.call("get_progress_text")) == "BINDING DEMON... 1/3" and absf(ring - 0.5) < 0.06, "%s, ring %.2f" % [_hud.call("get_progress_text"), ring])
			_check("tape pays off the roll with a sparkle", (_tape.get("_strip") as MeshInstance3D).visible and (_tape.get("_glints") as GPUParticles3D).emitting)
			_hold(&"gadget_fire", false)
		98:
			var ring := float((_hud.call("get_crosshair") as Control).call("get_progress"))
			_check("letting go throws the half-made wrap away", _tape.get("wrapping") == false and is_zero_approx(float(_tape.get("progress"))) and level == 0
					and str(_hud.call("get_progress_text")) == "" and is_zero_approx(ring))
			_check("an unbound demon wears no tape", _visible_bands().is_empty() and int(_visuals.call("get_tape_count")) == 0)
			_demon.set("stun_meter", 60.0)
		116:
			_mark_tick = _tick
			_hold(&"gadget_fire", true)
	if _step_tick > 116 and _wraps.size() == 3 and _mark_tick > 0:
		_hold(&"gadget_fire", false)
		_check_wraps()
		_mark_tick = 0
		_mark = meter
		_step_tick = 2000
	if _step_tick == 2010:
		_hold(&"gadget_fire", true)
	if _step_tick == 2040:
		_check("a gift-wrapped demon takes no more tape", level == 3 and _tape.get("wrapping") == false and int(_tape.get("wraps_done")) >= 3)
		_hold(&"gadget_fire", false)
		_mark = meter
	if _step_tick == 2160:
		_check("bind 3: stun drains at 1 per second instead of 2.5", absf((_mark - meter) - 2.0) < 0.3, "-%.2f in 2 s" % (_mark - meter))
		_next()
	elif _step_tick > 600 and _step_tick < 2000:
		_check("three wraps finish", false, "bind %d after %.1f s" % [level, (_tick - _mark_tick) / 60.0])
		_step_tick = 2150


func _check_wraps() -> void:
	var times := "%.2f / %.2f / %.2f s" % [(_wraps[0]["tick"] - _mark_tick) / 60.0, (_wraps[1]["tick"] - _wraps[0]["tick"]) / 60.0, (_wraps[2]["tick"] - _wraps[1]["tick"]) / 60.0]
	var on_time := true
	var previous := _mark_tick
	for wrap in _wraps:
		if absi(int(wrap["tick"]) - previous - 108) > 4:
			on_time = false
		previous = wrap["tick"]
	_check("each wrap takes 1.8 s", on_time, times)
	_check("each wrap adds 20 stun", float(_wraps[0]["gain"]) > 19.5 and float(_wraps[1]["gain"]) > 19.5, "+%.1f, +%.1f" % [float(_wraps[0]["gain"]), float(_wraps[1]["gain"])])
	_check("the ring counts 1/3, 2/3, 3/3", str(_wraps[0]["label"]).ends_with("1/3") and str(_wraps[1]["label"]).ends_with("2/3") and str(_wraps[2]["label"]).ends_with("3/3"), "%s | %s | %s" % [_wraps[0]["label"], _wraps[1]["label"], _wraps[2]["label"]])
	var counts := "%d / %d / %d bands" % [int(_wraps[0]["bands"]), int(_wraps[1]["bands"]), int(_wraps[2]["bands"])]
	_check("level 1 tapes the chest and upper arms", int(_wraps[0]["bands"]) >= 4, counts)
	_check("level 2 adds forearms, wrists and legs", int(_wraps[1]["bands"]) >= int(_wraps[0]["bands"]) + 6, counts)
	_check("level 3 cocoons it", int(_wraps[2]["bands"]) >= int(_wraps[1]["bands"]) + 6 and int(_visuals.call("get_tape_count")) == int(_wraps[2]["bands"]), counts)
	var skeleton: Skeleton3D = _visuals.get("_skeleton")
	var attached := true
	var jaw := false
	var bones: Dictionary = {}
	var loose := ""
	for band in _visible_bands():
		var mount := band.get_parent().get_parent() as BoneAttachment3D
		if mount == null or mount.bone_idx < 0 or mount.get_parent() != skeleton or skeleton.get_bone_name(mount.bone_idx) != mount.bone_name:
			attached = false
			loose = band.name
			continue
		bones[mount.bone_name] = true
		if mount.bone_name == "Head":
			jaw = true
		# The band has to sit on the bone it is hung from, wherever the ragdoll has ended up.
		var bone_at := skeleton.global_transform * skeleton.get_bone_global_pose(mount.bone_idx).origin
		if not band.global_position.is_finite() or band.global_position.distance_to(bone_at) > 0.6 or not (band.mesh is ArrayMesh):
			attached = false
			loose = band.name
	_check("every band hangs on a BoneAttachment3D of the real skeleton", attached and bones.size() >= 9, "%d bones%s" % [bones.size(), ("; loose: " + loose) if not loose.is_empty() else ""])
	_check("one strip is slapped across the jaw", jaw)
	_check("bands are metallic silver tape", (_visible_bands()[0].material_override as StandardMaterial3D).metallic > 0.5)
	var forces := "%d / %d / %d / %d N" % [int(_tuning[0]["force"]), int(_tuning[1]["force"]), int(_tuning[2]["force"]), int(_tuning[3]["force"])]
	var easier := true
	for i in 3:
		if float(_tuning[i + 1]["force"]) <= float(_tuning[i]["force"]) or float(_tuning[i + 1]["carry"]) >= float(_tuning[i]["carry"]):
			easier = false
	_check("each level makes it easier to drag and lighter to carry", easier, forces)
	_check("HUD bind pips read 3/3", str(_hud.get("_bind_count").text) == "3/3")
	_check("tearing and snap sounds", int(_cues().get(&"rip", 0)) >= 1 and int(_cues().get(&"tape_done", 0)) == int(_tape.get("wraps_done")), str(_cues()))


# --- 8: hauling the parcel on the rope -----------------------------------------------------

func _step_haul() -> void:
	var chest := _torso().global_position
	if _step_tick == 1:
		_tap(KEY_1)
		_stand(Vector3(chest.x + 4.0, 0.1, ARENA.z), chest)
		_immune = false
	if _step_tick < 400:
		_aim_at(chest)
	match _step_tick:
		40:
			_hold(&"gadget_fire", true)
		42:
			_hold(&"gadget_fire", false)
		70:
			_check("the lasso takes a bound, stunned demon", int(_lasso.get("mode")) == ATTACHED and _demon.get("is_stunned") == true and int(_brain.get("state")) == STUNNED)
			_hold(&"gadget_fire", true)
		130:
			_hold(&"gadget_fire", false)
			_mark = float(_player.get("stamina"))
			_mark_position = chest
			_peak_demon_speed = 0.0
			_peak_tension = 0.0
			_hold(&"move_back", true)
	if _step_tick > 130 and _step_tick < 400 and (_player.global_position.x > 1.0 or chest.distance_to(_van.global_position) < 7.5 or _step_tick == 399):
		_hold(&"move_back", false)
		_step_tick = 400
	match _step_tick:
		440:
			var dragged := chest.x - _mark_position.x
			_check("a bound demon drags smoothly behind the rope", dragged > 4.0 and _peak_tension > 0.2 and _peak_demon_speed < 10.0,
					"%.1f m, peak %.1f m/s (%s), chest %s, player %s" % [dragged, _peak_demon_speed, _peak_demon_note, chest, _player.global_position])
			_check("a limp demon does not fight the rope", is_equal_approx(float(_player.get("stamina")), _mark) and _demon.get("is_stunned") == true)
			_check("the tape rode along on its bones", int(_visuals.call("get_tape_count")) == int(_wraps[2]["bands"]) if _wraps.size() == 3 else false)
			_check("a subdued demon at a shut van: Open van doors [F] first", str(_state.call("get_current_task")) == "Open van doors [F] first"
					and str(_hud.get("_task").text) == "> Open van doors [F] first", "%s, %.1f m from the van" % [_state.call("get_current_task"), chest.distance_to(_van.global_position)])
			(_van.get("left_door") as Node).call("set_open", true)
		480:
			_check("with the doors open the banner goes back to hauling", str(_state.call("get_current_task")) == "Bind with Duct Tape [3] & haul to the van", str(_state.call("get_current_task")))
			_tap(KEY_R)
		510:
			_check("the rope lets go cleanly", int(_lasso.get("mode")) == IDLE)
			_next()


# --- 9: the bill ---------------------------------------------------------------------------

func _step_wrap_up() -> void:
	var payout: Dictionary = _contracts.call("compute_payout")
	_check("gift-wrapped: $150 binding bonus on the bill", int(payout["bind"]) == 150 and int(payout["bind_level"]) == 3 and int(payout["base"]) == 500, str(payout))
	_check("a tidy job earns the intact property bonus", int(payout["damaged"]) == 0 and int(payout["care"]) == 100 and str(payout["care_note"]) == "INTACT PROPERTY BONUS", str(payout["care_note"]))
	_check("no forces went NaN anywhere", _all_finite and int(_demon.get("fault_count")) == 0, "%d ragdoll rebuilds" % int(_demon.get("fault_count")))
	var loader := root.get_node("ModelLoader")
	_check("no missing models", int(loader.call("get_missing_count")) == 0, "%d loaded" % int(loader.call("get_loaded_count")))
	print("RESULT %s (%d failed)" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(0 if _failures == 0 else 1)
