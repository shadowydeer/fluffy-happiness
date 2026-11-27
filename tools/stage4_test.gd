extends SceneTree
## Headless Stage 4 regression, solo side: boots the real game with one player and works
## the new systems through the player's own input paths and the demon's own brain.
##   godot --headless --fixed-fps 60 --path . -s tools/stage4_test.gd
## Site:       exactly one exorcist, no NPC crew, the salt circle, NetworkManager autoload.
## Visuals:    own-body render layer + first-person cull mask + shadow twins; the van seal
##             as an alpha-blended etched decal with capped emission.
## Health:     28 HP swipes, 18-25 HP hurled props, harmless friendly props, the HUD bar,
##             SECOND WIND (2.5 s, 50 HP, demon thrown clear), then CONTRACT FAILED and RETRY.
## Demon:      30 stun/s taser, evasion at 35 stun, lamps blown, 4 s shock resistance,
##             mid-haul tape breakout, crew-size scaling.
## Chaos:      the Q shove (props, demon stagger, cooldown), the pause menu.
## Possession: the solo POSSESSION STRUGGLE, won by mashing Space and lost by not.
## The co-op half (replication, revive, possession, friendly fire) is tools/net_test.gd.
## Exits 0 when every check passes, 1 otherwise.

const ARENA := Vector3(-13.0, 0.1, 9.0)
const EAST := Vector3.RIGHT
const ENRAGED := 2
const STUNNED := 4
const FAILED := 4

var _main: Node
var _player: CharacterBody3D
var _demon: Node3D
var _brain: Node
var _hud: Node
var _contracts: Node
var _possession: Node
var _failures := 0
var _notices: Array[String] = []
var _evasions: Array[int] = []


func _initialize() -> void:
	_run()


func _check(label: String, ok: bool, detail: String = "") -> void:
	print("%s  %s%s" % ["PASS" if ok else "FAIL", label, ("  (" + detail + ")") if not detail.is_empty() else ""])
	if not ok:
		_failures += 1


func _frames(count: int) -> void:
	for i in count:
		await physics_frame


func _bind() -> void:
	_player = _main.get("player")
	_demon = _main.get("demon")
	_brain = _demon.get_node("AI")
	_hud = _main.get("hud")
	_contracts = _main.get("contracts")
	_possession = _main.get("possession")
	if not _brain.is_connected(&"evaded", _on_evaded):
		_brain.connect(&"evaded", _on_evaded)


func _on_evaded(kind: int) -> void:
	_evasions.append(kind)


func _noticed(fragment: String) -> bool:
	for line in _notices:
		if line.contains(fragment):
			return true
	return false


func _tap(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	root.push_input(event)


func _action(action: StringName) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	root.push_input(event)


## Stands the player in the empty strip of yard, facing east, as good as new.
func _fresh_player() -> void:
	_player.call("reset_for_contract", Transform3D(Basis(Vector3.UP, -PI * 0.5), ARENA))
	_player.set("_immune_left", 0.0)
	Input.action_release(&"hand_grab")
	Input.action_release(&"gadget_fire")


func _aim_at(point: Vector3) -> void:
	var eye := (_player.get_node("Head") as Node3D).global_position
	var to := point - eye
	_player.rotation.y = atan2(-to.x, -to.z)
	_player.set("_pitch", atan2(to.y, Vector2(to.x, to.z).length()))


## Stands the demon `distance` metres east of the arena, facing the player, wide awake.
func _stand_demon(distance: float, enraged: bool) -> void:
	_demon.set("stun_locked", false)
	_demon.call("wake")
	_demon.call("set_bind_level", 0)
	_demon.set("stun_meter", 0.0)
	_demon.set("shock_resist_left", 0.0)
	_demon.call("place", Transform3D(Basis(Vector3.UP, PI * 0.5), ARENA + EAST * distance - Vector3.UP * 0.1))
	_brain.call("_discover")
	_brain.set("passive", not enraged)
	_brain.set("_lurk_hold", 0.0 if enraged else 999.0)
	_brain.call("_enter", ENRAGED if enraged else 0)
	if enraged:
		_brain.set("_windup_left", 0.0)
		_brain.set("_swipe_left", 0.0)
		_brain.set("_throw_left", 999.0)


## Lays the demon out cold in the far corner of the yard, where it bothers nobody.
func _park_demon() -> void:
	_brain.set("passive", true)
	_demon.call("place", Transform3D(Basis.IDENTITY, Vector3(-14.0, 0.0, -2.0)))
	_demon.call("knock_out")
	_demon.set("stun_locked", true)
	_demon.set("breakout_tension", 0.0)


func _make_crate() -> RigidBody3D:
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * 0.5
	var collider := CollisionShape3D.new()
	collider.shape = shape
	var crate := RigidBody3D.new()
	crate.name = "TestCrate"
	crate.mass = 6.0
	crate.collision_layer = 4
	crate.collision_mask = 1 | 2 | 4 | 8 | 16
	crate.add_child(collider)
	crate.add_to_group(&"grabbable")
	_main.add_child(crate)
	return crate


func _put(crate: RigidBody3D, at: Vector3, velocity: Vector3 = Vector3.ZERO) -> void:
	var xf := Transform3D(Basis.IDENTITY, at)
	crate.global_transform = xf
	PhysicsServer3D.body_set_state(crate.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	PhysicsServer3D.body_set_state(crate.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, velocity)
	PhysicsServer3D.body_set_state(crate.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	crate.linear_velocity = velocity
	crate.sleeping = false


func _run() -> void:
	_main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	root.get_node("GameState").connect(&"notice_posted", func(text: String) -> void: _notices.append(text))
	# The site builds itself on the first frame after it enters the tree.
	await _frames(3)
	_bind()
	await _frames(90)
	_possession.set("cooldown_left", 9999.0)
	_park_demon()

	await _test_site()
	await _test_first_person_layers()
	await _test_seal()
	await _test_swipe_damage()
	await _test_prop_damage()
	await _test_second_wind_and_failure()
	await _test_shove()
	await _test_evasion_and_resistance()
	await _test_breakout()
	_test_scaling()
	await _test_struggle()
	await _test_pause_menu()

	_check("no forces went NaN anywhere", int(_demon.get("fault_count")) == 0, "%d ragdoll rebuilds" % int(_demon.get("fault_count")))
	print("RESULT %s (%d failed)" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(0 if _failures == 0 else 1)


# --- 1: the site ---------------------------------------------------------------------------

func _test_site() -> void:
	var npcs := 0
	for child in _main.get_children():
		if String(child.name).begins_with("Crew"):
			npcs += 1
	var models := 0
	for node in _main.find_children("*", "Node3D", true, false):
		if node.get_script() == load("res://scripts/ExorcistModel.gd"):
			models += 1
	_check("solo: one exorcist, one exorcist model, zero NPC crew", npcs == 0 and models == 1 and get_nodes_in_group(&"player").size() == 1,
			"%d NPC nodes, %d models, %d players" % [npcs, models, get_nodes_in_group(&"player").size()])
	_check("NetworkManager autoload is registered and solo", root.get_node_or_null("NetworkManager") != null and root.get_node("NetworkManager").call("get_player_count") == 1
			and root.get_node("NetworkManager").call("is_authority") == true)
	_check("the site has its Net, Possession and PauseMenu nodes", _main.get_node_or_null("Net") != null and _possession != null and _main.get_node_or_null("PauseMenu") != null)
	var circle := _possession.get_node_or_null("SaltCircle") as Node3D
	_check("a salt circle lies on the driveway by the van", circle != null and circle.global_position.distance_to((_main.get("level").get("van") as Node3D).global_position) < 6.0,
			str(circle.global_position) if circle else "missing")
	_check("its motes are still until somebody needs exorcising", (circle.get_node("SaltMotes") as GPUParticles3D).emitting == false)
	var bar := _hud.call("get_health_bar") as ProgressBar
	var stamina := _hud.get("_stamina") as ProgressBar
	_check("HUD: crimson health bar, full, right above stamina", bar != null and bar.value > 0.99 and bar.get_index() < stamina.get_index() and bar.get_parent() == stamina.get_parent()
			and (bar.get_theme_stylebox(&"fill") as StyleBoxFlat).bg_color.r > 0.5 and (bar.get_theme_stylebox(&"fill") as StyleBoxFlat).bg_color.g < 0.2)
	_check("HUD: the solo auto-injector reads READY", str((_hud.get("_wind_pip") as Label).text) == "SECOND WIND  READY", str((_hud.get("_wind_pip") as Label).text))
	_check("health starts at 100 / 100", float(_player.get("hp")) == 100.0 and float(_player.get("max_hp")) == 100.0)
	await _frames(1)


# --- 2: first-person body clipping fix --------------------------------------------------------

func _test_first_person_layers() -> void:
	var model := _player.get_node("Model")
	var camera := _player.call("get_camera") as Camera3D
	var own := int(root.get_node("GameState").get("RENDER_OWN_BODY"))
	var body: MeshInstance3D = null
	var legs: MeshInstance3D = null
	var feet: MeshInstance3D = null
	for mesh: MeshInstance3D in model.get("_body_meshes"):
		if String(mesh.name) == "Worker_Body":
			body = mesh
		elif String(mesh.name) == "Worker_Legs":
			legs = mesh
		elif String(mesh.name) == "Worker_Feet":
			feet = mesh
	var head_ok := true
	for part: GeometryInstance3D in model.get("_head_parts"):
		if part.layers != own:
			head_ok = false
	_check("torso and head meshes sit on the own-body render layer", body != null and body.layers == own and head_ok, "body layers %d" % (body.layers if body else -1))
	_check("so do the legs and boots, each with a shadow twin", legs != null and legs.layers == own and feet != null and feet.layers == own
			and legs.get_parent().has_node("Worker_LegsShadow") and feet.get_parent().has_node("Worker_FeetShadow"))
	var twin := body.get_parent().get_node_or_null("Worker_BodyShadow") as MeshInstance3D
	_check("a shadow-only twin on the normal layer keeps the torso's shadow", twin != null and twin.layers == 1
			and twin.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY and twin.mesh == body.mesh and twin.skin == body.skin)
	_check("third person: the camera draws the own-body layer", camera.get_cull_mask_value(13) == true)
	_player.call("set_first_person", true)
	await _frames(40)
	_check("first person: the camera culls the own-body layer", camera.get_cull_mask_value(13) == false and _player.call("is_first_person_view") == true)
	_check("...but still draws the world and the held-gadget layer", camera.get_cull_mask_value(1) and camera.get_cull_mask_value(12))
	var arms := model.get_node_or_null("FirstPersonArms") as Node3D
	var arms_ok := arms != null and arms.visible
	if arms_ok:
		for part in arms.find_children("*", "MeshInstance3D", true, false):
			if (part as MeshInstance3D).layers & own != 0:
				arms_ok = false
	_check("the first-person arms are shown and are not on the culled layer", arms_ok)
	# Straight down, as when taping a demon at your feet: nothing of the body can be in view,
	# and the sleeves swing down with the lens rather than filling it with shoulders.
	_tap(KEY_3)
	_player.set("_pitch", -1.4)
	await _frames(45)
	_check("looking straight down leaves the cull in place", camera.get_cull_mask_value(13) == false)
	var crowding: Array[String] = []
	for joint: String in ["_shoulder", "_elbow"]:
		for ball: MeshInstance3D in arms.get(joint):
			if camera.is_position_in_frustum(ball.global_position):
				crowding.append("%s %.2f m" % [joint, ball.global_position.distance_to(camera.global_position)])
	_check("...and no sleeve shoulder or elbow is in frame, only forearms and gloves", crowding.is_empty(), str(crowding))
	_tap(KEY_0)
	_player.set("_pitch", 0.0)
	_player.call("set_first_person", false)
	await _frames(40)
	_check("back in third person the body is drawn again", camera.get_cull_mask_value(13) == true)


# --- 3: van seal over-bloom fix ---------------------------------------------------------------

func _test_seal() -> void:
	var van := _main.get("level").get("van") as Node3D
	van.call("seal")
	await _frames(2)
	var material := van.get("_seal_material") as StandardMaterial3D
	var light := van.get("_seal_light") as OmniLight3D
	_check("the seal is an alpha-blended, lit decal (not additive)", material.blend_mode == BaseMaterial3D.BLEND_MODE_MIX
			and material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and material.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED)
	_check("its flash is capped near the bloom threshold", material.emission_energy_multiplier < 3.0 and light.light_energy < 1.5,
			"emission %.2f, light %.2f" % [material.emission_energy_multiplier, light.light_energy])
	await _frames(120)
	_check("at rest it glows like hot metal, not a white disc", material.emission_energy_multiplier > 0.8 and material.emission_energy_multiplier < 1.5
			and light.light_energy < 0.4 and material.emission.g < 0.75, "emission %.2f, light %.2f" % [material.emission_energy_multiplier, light.light_energy])
	van.call("release")
	await _frames(2)


# --- 4: demon swipes hurt -----------------------------------------------------------------------

func _test_swipe_damage() -> void:
	_fresh_player()
	_stand_demon(1.5, true)
	var before := int(_brain.get("swipes_landed"))
	var waited := 0
	while int(_brain.get("swipes_landed")) == before and waited < 240:
		await _frames(1)
		waited += 1
	_check("a swipe takes 28 HP and floors the player", float(_player.get("hp")) == 72.0 and _player.call("is_knocked_down") == true,
			"hp %.0f after %d ticks" % [float(_player.get("hp")), waited])
	await _frames(12)
	var bar := _hud.call("get_health_bar") as ProgressBar
	_check("HUD bar follows, and the edge of the screen flashes red", bar.value < 0.85 and float(_hud.call("get_vignette_alpha")) > 0.2,
			"bar %.2f, vignette %.2f" % [bar.value, float(_hud.call("get_vignette_alpha"))])
	_park_demon()


# --- 5: hurled furniture hurts; a friend's does not ---------------------------------------------

func _test_prop_damage() -> void:
	_fresh_player()
	await _frames(5)
	var crate := _make_crate()
	crate.set_meta(&"hurled_until", Time.get_ticks_msec() + 4000)
	_put(crate, ARENA + EAST * 2.6 + Vector3.UP * 1.0, -EAST * 13.0 + Vector3.UP * 1.0)
	var waited := 0
	while not _player.call("is_knocked_down") and waited < 60:
		await _frames(1)
		waited += 1
	var lost := 100.0 - float(_player.get("hp"))
	_check("a prop the demon hurled floors the player for 18-25 HP", _player.call("is_knocked_down") == true and lost >= 18.0 and lost <= 25.0, "%.1f HP" % lost)
	_fresh_player()
	crate.remove_meta(&"hurled_until")
	_put(crate, ARENA + EAST * 2.6 + Vector3.UP * 1.0, -EAST * 13.0 + Vector3.UP * 1.0)
	waited = 0
	while not _player.call("is_knocked_down") and waited < 60:
		await _frames(1)
		waited += 1
	_check("a prop anyone else threw still floors them, for no damage", _player.call("is_knocked_down") == true and float(_player.get("hp")) == 100.0, "hp %.0f" % float(_player.get("hp")))
	crate.queue_free()
	await _frames(2)


# --- 6: second wind, then CONTRACT FAILED and RETRY ----------------------------------------------

func _test_second_wind_and_failure() -> void:
	_fresh_player()
	_stand_demon(1.8, false)
	await _frames(20)
	_notices.clear()
	_player.call("knock_down", Vector3(-2.0, 2.0, 0.0), null, 150.0)
	await _frames(2)
	_check("0 HP alone: the auto-injector fires instead of going down", float(_player.get("hp")) == 0.0 and float(_player.call("get_second_wind")) >= 0.0
			and _player.get("is_downed") == false and _player.get("second_wind_ready") == false)
	await _frames(60)
	var blackout := _hud.get("_blackout") as ColorRect
	_check("the screen blacks out; HUD shows the adrenaline surge", blackout.color.a > 0.6 and str(_hud.call("get_status_text")).contains("AUTO-INJECTOR"),
			"alpha %.2f, '%s'" % [blackout.color.a, str(_hud.call("get_status_text")).replace("\n", " / ")])
	_check("nothing can hurt them during it", _player.call("knock_down", Vector3(1, 2, 0), null, 50.0) == false and float(_player.get("hp")) == 0.0)
	var gap_before := (_demon.call("get_center") as Vector3).distance_to(_player.global_position)
	await _frames(100)
	var gap_after := (_demon.call("get_center") as Vector3).distance_to(_player.global_position)
	_check("2.5 s later: back up on 50 HP", float(_player.get("hp")) == 50.0 and _player.call("is_knocked_down") == false and float(_player.call("get_second_wind")) < 0.0,
			"hp %.0f" % float(_player.get("hp")))
	await _frames(30)
	gap_after = maxf(gap_after, (_demon.call("get_center") as Vector3).distance_to(_player.global_position))
	_check("the surge throws the demon clear", gap_after > gap_before + 0.8, "%.2f m -> %.2f m" % [gap_before, gap_after])
	_check("SECOND WIND USED - NO MORE REVIVES", _noticed("SECOND WIND USED") and _noticed("NO MORE REVIVES") and str((_hud.get("_wind_pip") as Label).text) == "SECOND WIND  USED")
	_park_demon()

	# The second time there is nothing left in the holster.
	_player.set("_immune_left", 0.0)
	await _frames(2)
	var old_demon := _demon
	_player.call("knock_down", Vector3(-2.0, 2.0, 0.0), null, 150.0)
	await _frames(3)
	_check("0 HP again: down for good", _player.get("is_downed") == true and float(_player.call("get_second_wind")) < 0.0)
	_check("a distress beacon lights over a downed player", (_player.get_node("DistressBeacon") as Node3D).visible)
	await _frames(150)
	var summary := _contracts.get("summary") as Node
	_check("CONTRACT FAILED: the incident report is up", int(_contracts.get("phase")) == FAILED and summary.call("is_failure") == true and _player.get("controls_locked") == true)
	var report: Dictionary = _contracts.get("last_report")
	_check("$0 payout and a few words from head office", str((summary.get("_total") as Label).text) == "$0" and str((summary.get("_header") as Label).text).contains("FAILED")
			and (report.get("lines", []) as Array).size() >= 3 and int(root.get_node("GameState").get("bank_cash")) == 0, str(report.get("lines", [])))
	var retry := summary.call("get_next_button") as Button
	_check("the button reads RETRY CONTRACT", retry.text == "RETRY CONTRACT" and not retry.disabled, retry.text)
	retry.pressed.emit()
	await _frames(30)
	_bind()
	_possession.set("cooldown_left", 9999.0)
	_check("RETRY: same contract, running again", int(_contracts.get("phase")) == 0 and int(root.get_node("GameState").get("contract_number")) == 413 and summary.call("is_showing") == false)
	_check("the player is back at the kerb, whole, with a fresh auto-injector", float(_player.get("hp")) == 100.0 and _player.get("is_downed") == false
			and _player.get("second_wind_ready") == true and _player.get("controls_locked") == false
			and _player.global_position.distance_to((_main.call("get_local_spawn") as Transform3D).origin) < 0.5)
	_check("a fresh demon of the same tier is on the dais", _demon != old_demon and float(_demon.get("stun_scale")) == 1.0 and int(_brain.get("state")) == 0)
	_park_demon()


# --- 7: the shove ------------------------------------------------------------------------------

func _test_shove() -> void:
	_fresh_player()
	var crate := _make_crate()
	_put(crate, ARENA + EAST * 1.3 + Vector3.UP * 0.3)
	await _frames(40)
	_aim_at(ARENA + EAST * 5.0 + Vector3.UP * 1.5)
	await _frames(3)
	_action(&"shove")
	await _frames(3)
	_check("Q shoves a prop away", crate.linear_velocity.x > 1.5, "%.2f m/s" % crate.linear_velocity.x)
	_check("the arms punch out and the cooldown starts", float(_player.get("_shove_anim")) > 0.0 and float(_player.get("_shove_left")) > 1.0, "%.2f s" % float(_player.get("_shove_left")))
	_put(crate, ARENA + EAST * 1.3 + Vector3.UP * 0.3)
	await _frames(2)
	_action(&"shove")
	await _frames(3)
	_check("nothing happens again inside 1.2 s", absf(crate.linear_velocity.x) < 0.5, "%.2f m/s" % crate.linear_velocity.x)
	crate.queue_free()
	await _frames(80)
	_stand_demon(1.5, false)
	await _frames(6)
	_action(&"shove")
	await _frames(3)
	_check("a shove staggers a conscious demon (and gets its attention)", float(_brain.get("_stagger_left")) > 0.0 and int(_brain.get("state")) == ENRAGED,
			"stagger %.2f, state %s" % [float(_brain.get("_stagger_left")), str(_brain.call("get_state_name"))])
	_park_demon()


# --- 8: taser evasion, lamps and shock resistance -------------------------------------------------

func _test_evasion_and_resistance() -> void:
	_fresh_player()
	var taser := _player.get("gadgets").get("taser") as Node
	_check("the taser builds 30 stun a second", float(taser.get("STUN_RATE")) == 30.0)
	_stand_demon(2.2, false)
	await _frames(30)
	_evasions.clear()
	_notices.clear()
	var before := _demon.call("get_center") as Vector3
	_demon.call("add_stun", 30.0)
	await _frames(3)
	_check("under 35 stun it stands its ground", _evasions.is_empty() and int(_brain.get("evasions")) == 0)
	_demon.call("add_stun", 8.0)
	await _frames(3)
	_check("past 35 stun, awake, it evades", _evasions.size() == 1 and int(_brain.get("evasions")) == 1, str(_evasions))
	await _frames(25)
	var moved := ((_demon.call("get_center") as Vector3) - before) * Vector3(1.0, 0.0, 1.0)
	_check("in the open yard that is a sidestep out of the arc", _evasions == [0] and moved.length() > 0.6, "moved %.2f m" % moved.length())
	_demon.call("add_stun", 10.0)
	await _frames(3)
	_check("it does not evade again until another 35 has built up", _evasions.size() == 1)

	# Indoors there are lamps to blow.
	_demon.call("place", Transform3D(Basis.IDENTITY, Vector3(-5.0, 0.45, -10.0)))
	await _frames(5)
	var near := int(_brain.call("_lamps_near", _demon.call("get_center")))
	_brain.call("_blow_lamps")
	await _frames(3)
	var dark := 0
	var longest := 0.0
	for node in get_nodes_in_group(&"haunt_lights"):
		if node.call("is_blacked_out"):
			dark += 1
			longest = maxf(longest, float(node.get("_blackout_left")))
			if float((node.get_parent() as Light3D).light_energy) > 0.01:
				dark = -999
	_check("blowing the lamps kills every one near it for 6-8 s", near > 0 and dark >= near and longest > 5.5 and longest < 8.6, "%d lamps near, %d dark, %.1f s" % [near, dark, longest])

	# Shock resistance after a stun.
	_stand_demon(2.2, false)
	_brain.set("evade_threshold", 100000.0)
	_brain.set("_evade_next", 100000.0)
	_demon.call("knock_out")
	await _frames(5)
	_demon.call("wake")
	await _frames(2)
	var resist := float(_demon.get("shock_resist_left"))
	_demon.set("stun_meter", 0.0)
	_demon.call("add_stun", 20.0)
	_check("waking gives 4 s of shock resistance: stun builds at half rate", resist > 3.8 and resist <= 4.0 and absf(float(_demon.get("stun_meter")) - 10.0) < 0.01,
			"%.2f s, +%.1f stun" % [resist, float(_demon.get("stun_meter"))])
	_brain.call("_enter", 0)
	_brain.set("passive", true)
	await _frames(250)
	_demon.set("stun_meter", 0.0)
	_demon.call("add_stun", 20.0)
	_check("after that it takes the full dose again", float(_demon.get("shock_resist_left")) == 0.0 and absf(float(_demon.get("stun_meter")) - 20.0) < 0.01, "+%.1f" % float(_demon.get("stun_meter")))
	_brain.set("evade_threshold", 35.0)
	_park_demon()


# --- 9: mid-haul tape breakout ------------------------------------------------------------------

func _test_breakout() -> void:
	_fresh_player()
	# Hands need a true line of sight: aim down the barrel of the eyes, not over the shoulder.
	_player.call("set_first_person", true)
	await _frames(40)
	_stand_demon(1.7, false)
	_demon.call("knock_out")
	_demon.call("set_bind_level", 1)
	await _frames(70)
	var torso := _demon.call("get_body", 1) as RigidBody3D
	_aim_at(torso.global_position)
	await _frames(3)
	Input.action_press(&"hand_grab")
	await _frames(10)
	_check("the stunned demon can be grabbed and hauled", _player.call("is_hand_grabbing") == true and int(_demon.call("get_hauler_count")) == 1)
	await _frames(30)
	var tension := float(_demon.get("breakout_tension"))
	_check("hauled on one wrap, breakout tension builds", tension > 0.02, "%.3f" % tension)
	_notices.clear()
	_demon.set("breakout_tension", 0.985)
	var meter := float(_demon.get("stun_meter"))
	var waited := 0
	var peak_push := 0.0
	while waited < 120:
		await _frames(1)
		waited += 1
		if int(_demon.get("breakouts")) > 0:
			peak_push = maxf(peak_push, Vector2(_player.velocity.x, _player.velocity.z).length())
			if waited > 100 or peak_push > 2.0:
				break
	_check("it rips one layer of tape off", int(_demon.get("breakouts")) == 1 and int(_demon.get("bind_level")) == 0, "bind %d" % int(_demon.get("bind_level")))
	_check("the hauler is thrown back and loses their grip", _player.call("is_hand_grabbing") == false and peak_push > 2.0, "%.1f m/s" % peak_push)
	_check("it costs the demon stun, and everyone is told", float(_demon.get("stun_meter")) < meter - 20.0 and _noticed("TORE THE TAPE OFF"), "%.0f -> %.0f" % [meter, float(_demon.get("stun_meter"))])
	Input.action_release(&"hand_grab")

	# Three wraps hold.
	_fresh_player()
	_stand_demon(1.7, false)
	_demon.call("knock_out")
	_demon.call("set_bind_level", 3)
	await _frames(70)
	_aim_at((_demon.call("get_body", 1) as RigidBody3D).global_position)
	await _frames(3)
	Input.action_press(&"hand_grab")
	await _frames(150)
	_check("gift-wrapped (3/3) it never builds tension", _player.call("is_hand_grabbing") == true and float(_demon.get("breakout_tension")) == 0.0 and int(_demon.get("breakouts")) == 1,
			"%.3f" % float(_demon.get("breakout_tension")))
	Input.action_release(&"hand_grab")
	_player.call("set_first_person", false)
	await _frames(40)
	_park_demon()


# --- 10: crew scaling ---------------------------------------------------------------------------

func _test_scaling() -> void:
	var solo := [float(_demon.get("max_stun_resistance")), float(_demon.get("struggle_force")), float(_demon.get("drag_mass")), float(_brain.get("charge_speed")), float(_brain.get("swipe_cooldown"))]
	_check("one player: no scaling", solo[0] == 1.0 and solo[1] == 1.0 and solo[2] == 1.0)
	_brain.call("set_player_count", 3)
	_check("three players: tougher, stronger, heavier, faster, angrier", float(_demon.get("max_stun_resistance")) == 1.85 and float(_demon.get("struggle_force")) == 1.45
			and float(_demon.get("drag_mass")) == 1.65 and float(_brain.get("charge_speed")) > solo[3] and float(_brain.get("swipe_cooldown")) < solo[4],
			"resist x%.2f, charge %.2f -> %.2f" % [float(_demon.get("max_stun_resistance")), solo[3], float(_brain.get("charge_speed"))])
	_demon.set("stun_locked", false)
	_demon.call("wake")
	_demon.set("shock_resist_left", 0.0)
	_demon.set("stun_meter", 0.0)
	_demon.call("add_stun", 18.5)
	_check("the same current does 1/1.85 of the work", absf(float(_demon.get("stun_meter")) - 10.0) < 0.01, "%.2f" % float(_demon.get("stun_meter")))
	_brain.call("set_player_count", 1)
	_check("when the others leave it scales straight back", float(_demon.get("max_stun_resistance")) == 1.0 and absf(float(_brain.get("charge_speed")) - solo[3]) < 0.0001)
	_park_demon()


# --- 11: the solo possession struggle --------------------------------------------------------------

func _test_struggle() -> void:
	_fresh_player()
	_stand_demon(1.9, true)
	_brain.set("_swipe_left", 5.0)
	_notices.clear()
	_possession.set("cooldown_left", 0.0)
	await _frames(6)
	_check("alone, a possession attempt is a POSSESSION STRUGGLE", _possession.call("is_struggling") == true and float(_player.call("get_struggle")) >= 0.0
			and _possession.call("get_vessel") == null and _demon.get("is_dormant") == false)
	await _frames(4)
	_check("HUD: demon eyes, red edge, MASH [SPACE]", str(_hud.call("get_status_text")).contains("POSSESSION STRUGGLE") and (_hud.get("_eyes") as Control).visible
			and float(_hud.call("get_vignette_alpha")) > 0.3, str(_hud.call("get_status_text")).replace("\n", " / "))
	var gap := (_demon.call("get_center") as Vector3).distance_to(_player.global_position)
	for i in 10:
		_action(&"jump")
		await _frames(3)
	var thrown := 0.0
	for i in 40:
		await _frames(1)
		thrown = maxf(thrown, (_demon.call("get_center") as Vector3).distance_to(_player.global_position))
	_check("ten presses of Space break the grip: no damage", _possession.call("is_struggling") == false and float(_player.get("hp")) == 100.0 and _noticed("YOU THREW IT OFF"),
			"hp %.0f" % float(_player.get("hp")))
	_check("and the demon is thrown back", thrown > gap + 0.8, "%.2f m -> %.2f m" % [gap, thrown])
	var cooldown := float(_possession.get("cooldown_left"))
	_check("its next attempt is 35-45 s away", cooldown >= 34.0 and cooldown <= 45.0, "%.1f s" % cooldown)

	# Losing it.
	_fresh_player()
	_tap(KEY_2)
	await _frames(30)
	_stand_demon(1.9, true)
	_brain.set("_swipe_left", 5.0)
	_notices.clear()
	_possession.set("cooldown_left", 0.0)
	await _frames(6)
	var armed := int(_player.get("gadgets").get("slot"))
	await _frames(165)
	_check("doing nothing for 2.5 s loses it: 30 HP", _possession.call("is_struggling") == false and float(_player.get("hp")) == 70.0 and _noticed("GOT INSIDE YOUR HEAD"),
			"hp %.0f" % float(_player.get("hp")))
	_check("and the gadget in hand is dropped", armed == 2 and int(_player.get("gadgets").get("slot")) == 0, "slot %d -> %d" % [armed, int(_player.get("gadgets").get("slot"))])
	_possession.set("cooldown_left", 9999.0)
	_park_demon()


# --- 12: pause menu -------------------------------------------------------------------------------

func _test_pause_menu() -> void:
	_fresh_player()
	var menu := _main.get("pause_menu") as Node
	_action(&"ui_cancel")
	await _frames(3)
	_check("Esc opens the pause menu and freezes a solo site", menu.call("is_open") == true and paused == true and _player.get("controls_locked") == true)
	_check("it offers the way back to the main menu", (menu.call("get_leave_button") as Button).text == "MAIN MENU")
	_action(&"ui_cancel")
	await _frames(3)
	_check("Esc again resumes", menu.call("is_open") == false and paused == false and _player.get("controls_locked") == false)
