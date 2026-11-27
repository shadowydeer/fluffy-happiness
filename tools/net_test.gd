extends SceneTree
## Headless Stage 4 regression, co-op side. Two instances of the real game on one machine,
## a host and a client on 127.0.0.1, each checking what it sees:
##   tools/run_net_test.sh            (starts both and collects the results)
##   godot --headless --path . -s tools/net_test.gd -- host 7791
##   godot --headless --path . -s tools/net_test.gd -- join 7791
## Lobby:       hosting, joining, roster with names and suits, START CONTRACT.
## Site:        one body per human and nothing else; who simulates what; demon scaled x2.
## Replication: snapshots at 20 Hz, the demon ragdoll and its state, props, client movement,
##              a client's one-shot command executed by the host.
## Chaos:       a real Holy Taser shot at a crewmate (tumble, 0 damage), a real Holy Lasso
##              on a crewmate (leash, Space-mash escape).
## Health:      downed, the 3 s hold-E revive to 55 HP, CONTRACT FAILED when all are down, RETRY.
## Possession:  the demon vanishes into the isolated client; the salt circle throws it out stunned.
## Leaving:     the client disconnects; the host cleans up and re-scales and carries on.
## The host announces each phase with a notice ("PHASE x"); the client answers by flicking
## its headlamp, which the host sees replicated. Exits 0 when every check passes.

const FAILED := 4
const ENRAGED := 2
const STUNNED := 4
const POSSESSING := 6
const CIRCLE := Vector3(0.9, 0.1, 2.2)

var _role := "host"
var _port := 7791
var _failures := 0
var _notices: Array[String] = []
var _net: Node
var _state: Node
var _main: Node
var _player: CharacterBody3D
var _other: CharacterBody3D
var _demon: Node3D
var _brain: Node
var _hud: Node
var _contracts: Node
var _possession: Node
var _sync: Node
var _ack := true
var _frame := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		_role = args[0]
	if args.size() >= 2:
		_port = int(args[1])
	_run()


func _physics_process(_delta: float) -> bool:
	_frame += 1
	if _frame > 60 * 240:
		print("FAIL  [%s] watchdog: the scenario did not finish in four minutes" % _role)
		print("RESULT FAILED (watchdog)")
		quit(1)
	return false


func _check(label: String, ok: bool, detail: String = "") -> void:
	print("%s  [%s] %s%s" % ["PASS" if ok else "FAIL", _role, label, ("  (" + detail + ")") if not detail.is_empty() else ""])
	if not ok:
		_failures += 1


func _frames(count: int) -> void:
	for i in count:
		await physics_frame


## Waits until `condition` holds, for at most `limit` physics frames.
func _until(condition: Callable, limit: int = 900) -> bool:
	for i in limit:
		if condition.call():
			return true
		await physics_frame
	return bool(condition.call())


func _saw(fragment: String) -> bool:
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


func _aim_at(point: Vector3) -> void:
	var eye := (_player.get_node("Head") as Node3D).global_position
	var to := point - eye
	_player.rotation.y = atan2(-to.x, -to.z)
	_player.set("_pitch", atan2(to.y, Vector2(to.x, to.z).length()))


func _teleport(body: CharacterBody3D, at: Vector3) -> void:
	body.global_position = at
	body.velocity = Vector3.ZERO


func _bind() -> void:
	_main = root.get_node("Main")
	_player = _main.get("player")
	for id: int in (_main.get("players") as Dictionary):
		var body := (_main.get("players") as Dictionary)[id] as CharacterBody3D
		if body != _player:
			_other = body
	_demon = _main.get("demon")
	_brain = _demon.get_node("AI")
	_hud = _main.get("hud")
	_contracts = _main.get("contracts")
	_possession = _main.get("possession")
	_sync = _main.get("net")


func _site_ready() -> bool:
	var main := root.get_node_or_null("Main")
	return main != null and main.get("net") != null and (main.get("players") as Dictionary).size() == 2 and _net.call("is_peer_ready", 1) \
			and _net.call("is_peer_ready", _other_id())


func _other_id() -> int:
	for id: int in (_net.get("players") as Dictionary):
		if id != int(_net.call("local_id")):
			return id
	return 0


func _run() -> void:
	await _frames(3)
	_net = root.get_node("NetworkManager")
	_state = root.get_node("GameState")
	_state.connect(&"notice_posted", func(text: String) -> void: _notices.append(text))
	if _role == "host":
		await _host()
	else:
		await _client()
	print("RESULT %s (%d failed)" % ["OK" if _failures == 0 else "FAILED", _failures])
	_net.call("leave")
	await _frames(10)
	quit(0 if _failures == 0 else 1)


# =============================================================================================
# Host
# =============================================================================================

func _phase(tag: String) -> void:
	_ack = bool(_other.get("flashlight_on")) if is_instance_valid(_other) else true
	_state.call("post_notice", "PHASE %s" % tag)


## The client flicks its headlamp when it has finished checking a phase.
func _acked(limit: int = 1500) -> bool:
	return await _until(func() -> bool: return is_instance_valid(_other) and bool(_other.get("flashlight_on")) != _ack, limit)


func _host() -> void:
	var error: int = _net.call("host_game", _port, "Hosty", 0)
	_check("the lobby opens on port %d" % _port, error == OK and int(_net.get("mode")) == 1 and _net.call("is_authority") == true, error_string(error))
	var joined := await _until(func() -> bool: return (_net.get("players") as Dictionary).size() == 2, 3600)
	var roster: Dictionary = _net.get("players")
	_check("the client is in the roster with its name and suit", joined and _net.call("get_player_name", _other_id()) == "JOINY" and int(_net.call("get_player_suit", _other_id())) == 1
			and _net.call("get_player_name", 1) == "HOSTY", str(roster))
	_check("seats: the host first, then the joiner", int(_net.call("get_seat", 1)) == 0 and int(_net.call("get_seat", _other_id())) == 1)
	_net.call("start_contract")
	var loaded := await _until(_site_ready, 3600)
	_check("START CONTRACT takes both machines to the site", loaded)
	if not loaded:
		return
	_bind()
	await _frames(90)

	# --- who is on site, and who simulates what
	var crew_nodes := 0
	for child in _main.get_children():
		if String(child.name).begins_with("Crew"):
			crew_nodes += 1
	_check("two humans, two bodies, zero NPCs", get_nodes_in_group(&"player").size() == 2 and crew_nodes == 0 and (_main.get("players") as Dictionary).size() == 2)
	_check("the host simulates both bodies; only its own reads the keyboard", _player.get("is_local") == true and _player.get("simulates") == true
			and _other.get("is_local") == false and _other.get("simulates") == true)
	_check("the other body has its owner's name, seat and suit", str(_other.get("display_name")) == "JOINY" and int(_other.get("seat")) == 1 and int(_other.get_node("Model").get("suit")) == 1)
	_check("only the local camera is current", (_player.call("get_camera") as Camera3D).current and not (_other.call("get_camera") as Camera3D).current)
	_check("the demon is scaled for two", int(_brain.call("get_player_count")) == 2 and float(_demon.get("max_stun_resistance")) == 1.45 and float(_demon.get("drag_mass")) == 1.35)
	var sent := int(_sync.get("snapshots_sent"))
	await _frames(120)
	var rate := (int(_sync.get("snapshots_sent")) - sent) / 2.0
	_check("world snapshots go out at about 20 Hz", rate > 17.0 and rate < 23.0, "%.1f Hz" % rate)
	var spawn := (_main.get("level").call("get_spawn", 1) as Transform3D).origin
	_check("the client's body stands where its owner says (seat 1's spawn)", _other.global_position.distance_to(spawn) < 0.4, str(_other.global_position))
	_possession.set("cooldown_left", 9999.0)

	# --- world: a prop kicked and the demon laid out with two wraps on it
	var prop := (_state.get("net_props") as Array)[0] as RigidBody3D
	for candidate: RigidBody3D in _state.get("net_props"):
		if candidate.mass < 8.0 and candidate.global_position.y < 1.0 and candidate.global_position.z > -4.0:
			prop = candidate
			break
	_brain.set("passive", true)
	_demon.call("place", Transform3D(Basis.IDENTITY, Vector3(-8.0, 0.0, 9.0)))
	_demon.call("knock_out")
	_demon.set("stun_locked", true)
	_demon.call("set_bind_level", 2)
	await _frames(60)
	prop.sleeping = false
	prop.apply_central_impulse(Vector3.UP * prop.mass * 7.0)
	_phase("world %d" % int(prop.get_meta(&"net_id")))
	_check("client: demon, props and state arrive", await _acked())

	# --- the client walks, then shoves: movement is theirs, the shove runs here
	var before := _other.global_position
	_phase("move")
	var answered := await _acked()
	_check("the client's movement shows up on the host", answered and _other.global_position.distance_to(before) > 2.0, "moved %.2f m" % _other.global_position.distance_to(before))
	_check("a client's one-shot command (shove) is executed by the host", float(_other.get("_shove_left")) > 0.0, "cooldown %.2f" % float(_other.get("_shove_left")))
	_phase("gadget")
	answered = await _acked()
	var their_taser := _other.get("gadgets").get("taser") as Node
	_check("a client's held trigger works its gadget on the host", answered and float(their_taser.get("zap_time")) > 0.3 and float(their_taser.get("battery")) < 100.0,
			"%.2f s of trigger, battery %.0f" % [float(their_taser.get("zap_time")), float(their_taser.get("battery"))])
	_phase("home")
	await _acked()
	await _frames(20)
	_check("a teleport snaps rather than slides", _other.global_position.distance_to(spawn) < 0.5, str(_other.global_position))

	# --- friendly fire: a real taser shot at the crewmate
	# First person from here on, so the crosshair is not offset by the shoulder camera.
	_player.call("set_first_person", true)
	_teleport(_player, spawn + Vector3(1.6, 0.0, 0.0))
	await _frames(45)
	_tap(KEY_2)
	await _frames(40)
	_aim_at(_other.global_position + Vector3.UP * 1.0)
	await _frames(3)
	var health := float(_other.get("hp"))
	_phase("taser")
	Input.action_press(&"gadget_fire")
	var tumbling := await _until(func() -> bool: return bool(_other.call("is_tumbling")), 240)
	# Keep the arc on them a little longer so the client sees the gadget working.
	await _frames(40)
	Input.action_release(&"gadget_fire")
	_tap(KEY_2)
	_check("Holy Taser on a crewmate: they tumble", tumbling and int(_player.get("gadgets").get("taser").get("zap_time") > 0.0) == 1)
	_check("...everyone is told, and nobody is hurt", _saw("TASED JOINY") and float(_other.get("hp")) == health, "hp %.0f" % float(_other.get("hp")))
	_check("client: tumbled for 2.5 s with full health", await _acked())
	_phase("home")
	await _acked()
	await _frames(20)

	# --- the lasso on a crewmate
	_tap(KEY_1)
	await _frames(40)
	_aim_at(_other.global_position + Vector3.UP * 1.0)
	await _frames(3)
	Input.action_press(&"gadget_fire")
	await _frames(3)
	Input.action_release(&"gadget_fire")
	var lasso := _player.get("gadgets").get("lasso") as Node
	var roped := await _until(func() -> bool: return lasso.call("get_target_player") == _other, 120)
	_check("Holy Lasso latches onto a crewmate", roped and int(lasso.get("mode")) == 2)
	await _frames(10)
	_check("...which leashes them to the holder", _other.call("is_leashed") == true)
	_phase("lasso")
	answered = await _acked()
	_check("mashing Space (six presses) throws the rope off", answered and lasso.call("get_target_player") == null, "mode %d" % int(lasso.get("mode")))
	_tap(KEY_1)
	await _frames(20)

	# --- downed and revived
	_other.call("hurt", 150.0)
	_phase("down")
	var downed := await _until(func() -> bool: return bool(_other.get("is_downed")), 300)
	_check("0 HP in co-op: DOWNED, not dead, and no second wind", downed and float(_other.get("hp")) == 0.0 and int(_contracts.get("phase")) == 0)
	await _acked()
	_teleport(_player, _other.global_position + Vector3(1.3, 0.0, 0.0))
	await _frames(10)
	var started := _frame
	Input.action_press(&"hand_grab")
	await _frames(60)
	_check("holding E beside them starts a revive", int(_player.get("revive_seat")) == 1 and float(_player.get("revive_progress")) > 0.2 and float(_player.get("revive_progress")) < 0.5,
			"%.2f" % float(_player.get("revive_progress")))
	var revived := await _until(func() -> bool: return not bool(_other.get("is_downed")), 400)
	Input.action_release(&"hand_grab")
	var took := (_frame - started) / 60.0
	await _frames(20)
	_check("three seconds later they are up on 55 HP", revived and took > 2.9 and took < 3.6 and float(_other.get("hp")) == 55.0, "%.2f s, hp %.0f" % [took, float(_other.get("hp"))])
	_phase("revived")
	await _acked()

	# --- possession: the client alone with the demon, the host far away
	_teleport(_player, Vector3(-13.0, 0.1, 9.0))
	_phase("home")
	await _acked()
	await _frames(30)
	_demon.set("stun_locked", false)
	_demon.call("wake")
	_demon.call("set_bind_level", 0)
	_demon.call("place", Transform3D(Basis(Vector3.UP, -PI * 0.5), _other.global_position + Vector3(1.7, -0.1, 0.0)))
	_brain.call("_discover")
	_brain.set("passive", false)
	_brain.call("_enter", ENRAGED)
	_brain.set("_swipe_left", 5.0)
	_possession.set("cooldown_left", 0.0)
	var taken := await _until(func() -> bool: return _possession.call("get_vessel") == _other, 300)
	_check("the demon vanishes into the isolated player", taken and _demon.get("is_dormant") == true and int(_brain.get("state")) == POSSESSING and not _demon.visible)
	_check("EXORCISE [NAME]! Tase or drag to Salt Circle!", str(_state.call("get_current_task")) == "EXORCISE JOINY! Tase or drag to Salt Circle!" and _possession.get("circle_active") == true,
			str(_state.call("get_current_task")))
	_phase("possessed")
	answered = await _acked(2400)
	await _frames(20)
	_check("dragged into the salt circle: the demon is thrown out, STUNNED", answered and _possession.call("get_vessel") == null and int(_possession.get("exorcisms")) == 1
			and _demon.get("is_dormant") == false and _demon.get("is_stunned") == true and int(_brain.get("state")) == STUNNED and _demon.visible,
			"state %s" % str(_brain.call("get_state_name")))
	_check("it lands beside the circle, and the alert clears", (_demon.call("get_center") as Vector3).distance_to(CIRCLE) < 4.5 and str(_state.call("get_alert")) == ""
			and _possession.get("circle_active") == false, str(_demon.call("get_center")))
	_possession.set("cooldown_left", 9999.0)
	_demon.set("stun_locked", true)

	# --- everybody down: CONTRACT FAILED, then RETRY
	_player.call("hurt", 500.0)
	_other.call("hurt", 500.0)
	_phase("wipe")
	var lost := await _until(func() -> bool: return int(_contracts.get("phase")) == FAILED, 600)
	var summary := _contracts.get("summary") as Node
	_check("all players down at once: CONTRACT FAILED, $0", lost and summary.call("is_failure") == true and (summary.call("get_next_button") as Button).text == "RETRY CONTRACT"
			and int(_state.get("bank_cash")) == 0)
	await _acked()
	var old_demon := _demon
	_contracts.call("retry_contract")
	_phase("retry")
	answered = await _acked()
	_bind()
	await _frames(30)
	_check("RETRY CONTRACT puts everyone back on their feet at the kerb", answered and int(_contracts.get("phase")) == 0 and float(_player.get("hp")) == 100.0
			and float(_other.get("hp")) == 100.0 and not _other.get("is_downed") and _other.global_position.distance_to(spawn) < 0.6 and _demon != old_demon,
			"client hp %.0f at %s" % [float(_other.get("hp")), str(_other.global_position)])

	# --- the client leaves
	_phase("bye")
	var gone := await _until(func() -> bool: return (_net.get("players") as Dictionary).size() == 1, 1200)
	await _frames(30)
	_check("a disconnect removes that player's body and nothing else", gone and get_nodes_in_group(&"player").size() == 1 and (_main.get("players") as Dictionary).size() == 1
			and not is_instance_valid(_other) and is_instance_valid(_player))
	_check("the demon is re-scaled for one", int(_brain.call("get_player_count")) == 1 and float(_demon.get("max_stun_resistance")) == 1.0)
	_check("the host's contract carries on", int(_contracts.get("phase")) == 0 and _saw("JOINY LEFT THE SITE") and int(_demon.get("fault_count")) == 0)


# =============================================================================================
# Client
# =============================================================================================

func _await_phase(tag: String, limit: int = 3600) -> String:
	var found := ""
	for i in limit:
		for n in _notices.size():
			if _notices[n].begins_with("PHASE %s" % tag):
				found = _notices[n]
				_notices.remove_at(n)
				return found
		await physics_frame
	_check("phase '%s' arrived" % tag, false)
	return found


func _ack_phase() -> void:
	_player.call("set_flashlight", not bool(_player.get("flashlight_on")))


func _client() -> void:
	var error: int = _net.call("join_game", "127.0.0.1", _port, "Joiny", 1)
	_check("a connection to 127.0.0.1:%d starts" % _port, error == OK and int(_net.get("mode")) == 2)
	var listed := await _until(func() -> bool: return (_net.get("players") as Dictionary).size() == 2, 3600)
	_check("joined: the roster lists the host and this player", listed and _net.call("get_player_name", 1) == "HOSTY" and _net.call("get_player_name", _net.call("local_id")) == "JOINY"
			and _net.call("is_authority") == false, str(_net.get("players")))
	var loaded := await _until(_site_ready, 3600)
	_check("the host's START CONTRACT loads the site here too", loaded)
	if not loaded:
		return
	_bind()
	await _frames(90)
	_check("two bodies: this one is local, the host's is a puppet", get_nodes_in_group(&"player").size() == 2 and _player.get("is_local") == true
			and _player.get("simulates") == false and _other.get("is_local") == false and _other.get("simulates") == false)
	_check("this player has seat 1, the teal suit and the second spawn", int(_player.get("seat")) == 1 and int(_player.get_node("Model").get("suit")) == 1
			and _player.global_position.distance_to((_main.get("level").call("get_spawn", 1) as Transform3D).origin) < 0.5)
	_check("the demon and the props are mirrors of the host's", _demon.get("is_remote") == true and _brain.get("is_remote") == true
			and ((_state.get("net_props") as Array)[0] as RigidBody3D).freeze and ((_state.get("net_props") as Array)[0] as RigidBody3D).has_meta(&"net_mirror"))
	var received := int(_sync.get("snapshots_received"))
	await _frames(120)
	var rate := (int(_sync.get("snapshots_received")) - received) / 2.0
	_check("world snapshots arrive at about 20 Hz", rate > 15.0 and rate < 25.0, "%.1f Hz" % rate)
	_check("the host's body is where the host stands (seat 0's spawn)", _other.global_position.distance_to((_main.get("level").call("get_spawn", 0) as Transform3D).origin) < 0.5,
			str(_other.global_position))
	_check("the demon is scaled for two here as well", int(_brain.call("get_player_count")) == 2)
	var spawn := (_main.get("level").call("get_spawn", 1) as Transform3D).origin

	# --- world
	var tag := await _await_phase("world")
	var prop := (_state.get("net_props") as Array)[int(tag.get_slice(" ", 2))] as RigidBody3D
	var rest_y := prop.global_position.y
	var peak := rest_y
	for i in 90:
		await physics_frame
		peak = maxf(peak, prop.global_position.y)
	_check("a prop the host kicked moves here", peak > rest_y + 0.05 or absf(prop.global_position.y - rest_y) > 0.05, "rose %.2f m" % (peak - rest_y))
	_check("the demon's ragdoll is where the host put it, out cold", (_demon.call("get_center") as Vector3).distance_to(Vector3(-8.0, 0.4, 9.0)) < 2.2 and _demon.get("is_stunned") == true
			and int(_brain.get("state")) == STUNNED, str(_demon.call("get_center")))
	_check("its bind level and tape came across", int(_demon.get("bind_level")) == 2 and int(_demon.get_node("Visuals").call("get_tape_count")) > 0
			and _hud.call("is_demon_status_visible") == true)
	_check("the objective banner follows the host", str(_hud.get("_task").text) == "> Bind with Duct Tape [3] & haul to the van", str(_hud.get("_task").text))
	_ack_phase()

	# --- move, then shove
	await _await_phase("move")
	Input.action_press(&"move_forward")
	await _frames(70)
	Input.action_release(&"move_forward")
	_action(&"shove")
	await _frames(15)
	_check("walking is local and immediate", _player.global_position.distance_to(spawn) > 2.5, "%.2f m" % _player.global_position.distance_to(spawn))
	_ack_phase()
	# --- this player's own gadget: the trigger is held here, the taser is worked on the host
	await _await_phase("gadget")
	_tap(KEY_2)
	await _frames(40)
	Input.action_press(&"gadget_fire")
	await _frames(45)
	var own_taser := _player.get("gadgets").get("taser") as Node
	_check("own taser: firing, arcs drawn and the battery draining, all via the host", own_taser.get("firing") == true and float(own_taser.get("battery")) < 95.0
			and (own_taser.get("_bolts") as MeshInstance3D).visible and float(_player.get("gadgets").call("get_battery")) < 0.95, "battery %.0f" % float(own_taser.get("battery")))
	Input.action_release(&"gadget_fire")
	_tap(KEY_2)
	await _frames(10)
	_ack_phase()
	await _await_phase("home")
	_teleport(_player, spawn)
	await _frames(15)
	_ack_phase()

	# --- tased by the host
	await _await_phase("taser")
	var tumbled := await _until(func() -> bool: return bool(_player.call("is_tumbling")), 600)
	_check("tased by a crewmate: tumbling, tool lowered", tumbled and _player.call("is_knocked_down") == true and _player.call("can_act") == false)
	var started := _frame
	var host_taser := _other.get("gadgets").get("taser") as Node
	var drawn := await _until(func() -> bool: return int(_other.get("gadgets").get("slot")) == 2 and host_taser.get("firing") == true and float(host_taser.get("battery")) < 100.0, 30)
	_check("the host's taser is drawn firing in its puppet's hands", drawn, "slot %d, battery %.0f" % [int(_other.get("gadgets").get("slot")), float(host_taser.get("battery"))])
	await _until(func() -> bool: return not bool(_player.call("is_tumbling")), 600)
	var took := (_frame - started) / 60.0
	_check("2.5 seconds of it, and not a scratch", took > 2.2 and took < 2.9 and float(_player.get("hp")) == 100.0, "%.2f s, hp %.0f" % [took, float(_player.get("hp"))])
	await _until(func() -> bool: return not bool(_player.call("is_knocked_down")), 300)
	_ack_phase()
	await _await_phase("home")
	_teleport(_player, spawn)
	await _frames(15)
	_ack_phase()

	# --- roped by the host
	await _await_phase("lasso")
	var leashed := await _until(func() -> bool: return bool(_player.call("is_leashed")), 300)
	await _frames(10)
	var host_lasso := _other.get("gadgets").get("lasso") as Node
	_check("roped by a crewmate: leashed, and the HUD says by whom", leashed and str(_hud.call("get_status_text")).contains("ROPED BY HOSTY"), str(_hud.call("get_status_text")).replace("\n", " / "))
	_check("the rope and its collar are drawn from the host's puppet to this player", int(host_lasso.get("mode")) == 2 and host_lasso.call("get_target_player") == _player
			and is_instance_valid(host_lasso.get("_collar")))
	for i in 6:
		_action(&"jump")
		await _frames(4)
	var freed := await _until(func() -> bool: return not bool(_player.call("is_leashed")), 300)
	_check("six presses of Space and the rope is off", freed)
	_ack_phase()

	# --- downed, then revived by the host
	await _await_phase("down")
	var downed := await _until(func() -> bool: return bool(_player.get("is_downed")), 300)
	await _frames(10)
	_check("0 HP: DOWNED, beacon lit, HUD says crawl to a crewmate", downed and float(_player.get("hp")) == 0.0 and (_player.get_node("DistressBeacon") as Node3D).visible
			and str(_hud.call("get_status_text")).contains("DOWNED"), str(_hud.call("get_status_text")).replace("\n", " / "))
	_check("no second wind with a crew", float(_player.call("get_second_wind")) < 0.0 and str((_hud.get("_wind_pip") as Label).text) == "")
	_ack_phase()
	var helped := await _until(func() -> bool: return str(_hud.call("get_status_text")).contains("HOSTY IS GETTING YOU UP"), 600)
	_check("the HUD shows who is reviving you", helped)
	await _await_phase("revived")
	_check("revived: 55 HP and back on your feet", float(_player.get("hp")) == 55.0 and not _player.get("is_downed") and not (_player.get_node("DistressBeacon") as Node3D).visible,
			"hp %.0f" % float(_player.get("hp")))
	_ack_phase()
	await _await_phase("home")
	_teleport(_player, spawn)
	await _frames(15)
	_ack_phase()

	# --- possessed, then walked into the salt
	await _await_phase("possessed")
	var taken := await _until(func() -> bool: return bool(_player.get("possessed")), 300)
	await _frames(20)
	_check("POSSESSED: the demon is gone from the room and inside this player", taken and _demon.get("is_dormant") == true and not _demon.visible)
	_check("HUD: > EXORCISE JOINY! Tase or drag to Salt Circle!", str(_hud.get("_task").text) == "> EXORCISE JOINY! Tase or drag to Salt Circle!", str(_hud.get("_task").text))
	_check("crimson vignette and the POSSESSED warning", str(_hud.call("get_status_text")).contains("YOU ARE POSSESSED") and float(_hud.call("get_vignette_alpha")) > 0.15,
			"vignette %.2f" % float(_hud.call("get_vignette_alpha")))
	_check("the salt circle wakes up", (_possession.get_node("SaltCircle/SaltMotes") as GPUParticles3D).emitting)
	_teleport(_player, CIRCLE)
	var clean := await _until(func() -> bool: return not bool(_player.get("possessed")), 600)
	await _frames(30)
	_check("in the salt circle the demon is driven out", clean and _demon.get("is_dormant") == false and _demon.visible and _demon.get("is_stunned") == true,
			"stunned %s" % str(_demon.get("is_stunned")))
	_ack_phase()

	# --- wipe and retry
	await _await_phase("wipe")
	var lost := await _until(func() -> bool: return int(_contracts.get("phase")) == FAILED, 900)
	var summary := _contracts.get("summary") as Node
	var first := summary.call("get_next_button") as Button
	_check("CONTRACT FAILED reaches the client, which waits for the host", lost and summary.call("is_failure") == true and first.disabled and first.text == "WAITING FOR HOST..."
			and _player.get("controls_locked") == true, first.text)
	_ack_phase()
	await _await_phase("retry")
	var again := await _until(func() -> bool: return int(_contracts.get("phase")) == 0 and float(_player.get("hp")) == 100.0, 600)
	_bind()
	_check("the host's RETRY resets this player too", again and not _player.get("is_downed") and _player.get("controls_locked") == false
			and _player.global_position.distance_to(spawn) < 0.6 and summary.call("is_showing") == false and _demon.get("is_remote") == true)
	_ack_phase()

	await _await_phase("bye")
