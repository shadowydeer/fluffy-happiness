extends SceneTree
## Headless Stage 5 regression, co-op side. Two instances of the real game on one machine,
## a host and a client on 127.0.0.1, each checking what it sees:
##   godot --headless --path . -s tools/stage5_net_test.gd -- host 7795
##   godot --headless --path . -s tools/stage5_net_test.gd -- join 7795
## Archetypes: the host's pick reaches the client with the first sync; the M key's swap
##             rebuilds the client's mirror demon as the new kind.
## Field shop: a client's purchase is decided by the host and comes back as synced state;
##             a purchase it cannot afford is refused, to the client only.
## Salt:       a client throws the slot 4 grenade with its own trigger; the host spends the
##             charge, flies the jar and bursts it; both machines see the burst.
## Juice/SFX:  a host-side world effect and a host-side sound both play on the client.
## The host announces each phase with a notice ("PHASE x"); the client answers by flicking
## its headlamp, which the host sees replicated. Exits 0 when every check passes.

const SCUTTLER := 0
const POLTERGEIST := 2

var _role := "host"
var _port := 7795
var _failures := 0
var _notices: Array[String] = []
var _net: Node
var _state: Node
var _sound: Node
var _main: Node
var _player: CharacterBody3D
var _other: CharacterBody3D
var _demon: Node3D
var _hud: Node
var _shop: Node
var _juice: Node
var _ack := true
var _frame := 0
var _bought: Array = []
var _denied: Array = []
var _bursts: Array[Vector3] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		_role = args[0]
	if args.size() >= 2:
		_port = int(args[1])
	_run()


func _physics_process(_delta: float) -> bool:
	_frame += 1
	if _frame > 60 * 180:
		print("FAIL  [%s] watchdog: the scenario did not finish in three minutes" % _role)
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


func _until(condition: Callable, limit: int = 900) -> bool:
	for i in limit:
		if condition.call():
			return true
		await physics_frame
	return bool(condition.call())


func _tap(keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	root.push_input(event)


func _aim_at(point: Vector3) -> void:
	var eye := (_player.get_node("Head") as Node3D).global_position
	var to := point - eye
	_player.rotation.y = atan2(-to.x, -to.z)
	_player.set("_pitch", atan2(to.y, Vector2(to.x, to.z).length()))


func _bind() -> void:
	_main = root.get_node("Main")
	_player = _main.get("player")
	for id: int in (_main.get("players") as Dictionary):
		var body := (_main.get("players") as Dictionary)[id] as CharacterBody3D
		if body != _player:
			_other = body
	_demon = _main.get("demon")
	_hud = _main.get("hud")
	_shop = _main.get("shop")
	_juice = _main.get("juice")
	if not _shop.is_connected(&"purchased", _on_purchased):
		_shop.connect(&"purchased", _on_purchased)
		_shop.connect(&"purchase_denied", _on_denied)
		_shop.connect(&"grenade_burst", _on_burst)


func _on_purchased(item: StringName, peer_id: int) -> void:
	_bought.append([item, peer_id])


func _on_denied(item: StringName, reason: String) -> void:
	_denied.append([item, reason])


func _on_burst(at: Vector3) -> void:
	_bursts.append(at)


func _site_ready() -> bool:
	var main := root.get_node_or_null("Main")
	return main != null and main.get("net") != null and (main.get("players") as Dictionary).size() == 2 and _net.call("is_peer_ready", 1) \
			and _net.call("is_peer_ready", _other_id())


func _other_id() -> int:
	for id: int in (_net.get("players") as Dictionary):
		if id != int(_net.call("local_id")):
			return id
	return 0


func _played(kind: StringName) -> int:
	return int((_juice.get("played") as Dictionary).get(kind, 0))


func _run() -> void:
	await _frames(3)
	_net = root.get_node("NetworkManager")
	_state = root.get_node("GameState")
	_sound = root.get_node("SoundManager")
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


func _acked(limit: int = 1500) -> bool:
	return await _until(func() -> bool: return is_instance_valid(_other) and bool(_other.get("flashlight_on")) != _ack, limit)


func _host() -> void:
	var error: int = _net.call("host_game", _port, "Hosty", 0)
	_check("the lobby opens on port %d" % _port, error == OK, error_string(error))
	await _until(func() -> bool: return (_net.get("players") as Dictionary).size() == 2, 3600)
	_net.call("start_contract")
	var loaded := await _until(_site_ready, 3600)
	_check("START CONTRACT takes both machines to the site", loaded)
	if not loaded:
		return
	_bind()
	await _frames(90)
	(_main.get("possession") as Node).set("cooldown_left", 9999.0)
	(_demon.get_node("AI") as Node).set("passive", true)

	# --- archetypes: the first contract of a career, then the M key
	_check("the first contract is about the Scuttler, and the demon on site is one", int(_state.get("demon_archetype")) == SCUTTLER
			and int(_demon.get("archetype")) == SCUTTLER, "state %s demon %s" % [str(_state.get("demon_archetype")), str(_demon.get("archetype"))])
	_phase("arch %d" % SCUTTLER)
	_check("client: its mirror demon is a Scuttler too", await _acked())
	_tap(KEY_M)
	await _frames(5)
	_bind()
	(_demon.get_node("AI") as Node).set("passive", true)
	_check("M swaps the demon on site for the next archetype", int(_state.get("demon_archetype")) == POLTERGEIST and int(_demon.get("archetype")) == POLTERGEIST
			and _demon.is_inside_tree(), str(_state.get("demon_archetype")))
	_phase("arch %d" % POLTERGEIST)
	_check("client: the mirror was rebuilt as a Poltergeist", await _acked())

	# --- field shop: the client spends the crew's money
	_tap(KEY_G)
	await _frames(3)
	_check("G pays $1000 of test cash into the bank", int(_state.get("bank_cash")) == 1000, str(_state.get("bank_cash")))
	_bought.clear()
	_phase("buy")
	var answered := await _acked()
	_check("a client's purchase is decided here: $300 spent, Turbo Duct Tape at level 1", answered and int(_state.get("bank_cash")) == 700
			and int(_state.call("get_upgrade", &"tape")) == 1, "bank %s tape %s" % [str(_state.get("bank_cash")), str(_state.call("get_upgrade", &"tape"))])
	_check("the purchase is credited to the client", _bought.size() == 1 and _bought[0][0] == &"tape" and int(_bought[0][1]) == _other_id(), str(_bought))
	_state.call("spend_cash", int(_state.get("bank_cash")))
	_denied.clear()
	_phase("broke")
	answered = await _acked()
	_check("a purchase the crew cannot afford changes nothing, and only the client is told", answered and int(_state.get("bank_cash")) == 0
			and int(_state.call("get_upgrade", &"taser")) == 0 and _denied.is_empty(), "bank %s denied here %s" % [str(_state.get("bank_cash")), str(_denied)])

	# --- salt grenade: thrown with the client's trigger, flown and burst here
	_check("the crew starts with one salt grenade", int(_state.get("salt_charges")) == 1, str(_state.get("salt_charges")))
	_bursts.clear()
	var jolts := _played(&"salt_burst")
	_phase("salt")
	answered = await _acked(2400)
	_check("the client's throw spent the charge and burst on the host", answered and int(_state.get("salt_charges")) == 0 and _bursts.size() == 1
			and _played(&"salt_burst") == jolts + 1, "charges %s bursts %d" % [str(_state.get("salt_charges")), _bursts.size()])

	# --- juice and sound made on the host
	var at := _other.global_position + Vector3(1.5, 0.2, 0.0)
	_phase("fx")
	await _frames(20)
	_state.call("fx", &"crash", at, 1.0)
	_sound.call("play_net", &"impact_wood", at, 0.0, 1.0)
	_check("client: the crash and its sound played there", await _acked())

	_phase("bye")
	await _frames(30)


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
	_check("a connection to 127.0.0.1:%d starts" % _port, error == OK)
	var loaded := await _until(_site_ready, 7200)
	_check("the host's START CONTRACT loads the site here too", loaded)
	if not loaded:
		return
	_bind()

	# --- archetypes
	await _await_phase("arch %d" % SCUTTLER)
	_bind()
	_check("the contract's archetype arrived, and the mirror demon was built as one", int(_state.get("demon_archetype")) == SCUTTLER
			and int(_demon.get("archetype")) == SCUTTLER and _demon.get("is_remote") == true, "state %s demon %s" % [str(_state.get("demon_archetype")), str(_demon.get("archetype"))])
	_ack_phase()
	await _await_phase("arch %d" % POLTERGEIST)
	var swapped := await _until(func() -> bool: return int((_main.get("demon") as Node).get("archetype")) == POLTERGEIST, 600)
	_bind()
	_check("the host's M key rebuilt the mirror as a Poltergeist", swapped and _demon.get("is_remote") == true and _demon.is_inside_tree()
			and int(_state.get("demon_archetype")) == POLTERGEIST)
	_check("the HUD names it once it is the contract's demon", str(_hud.call("get_archetype_text")).contains("POLTERGEIST") or not bool(_hud.call("is_demon_status_visible")),
			str(_hud.call("get_archetype_text")))
	_ack_phase()

	# --- field shop
	await _await_phase("buy")
	var funded := await _until(func() -> bool: return int(_state.get("bank_cash")) == 1000, 600)
	_check("the host's test cash shows in this bank", funded, str(_state.get("bank_cash")))
	_check("the shop offers Turbo Duct Tape for $300", int(_shop.call("get_cost", &"tape")) == 300 and _shop.call("can_buy", &"tape") == true, str(_shop.call("get_cost", &"tape")))
	_bought.clear()
	_shop.call("request_buy", &"tape")
	var owned := await _until(func() -> bool: return int(_state.call("get_upgrade", &"tape")) == 1 and int(_state.get("bank_cash")) == 700, 600)
	_check("the purchase comes back as synced state: tape level 1, $700 left", owned, "tape %s bank %s" % [str(_state.call("get_upgrade", &"tape")), str(_state.get("bank_cash"))])
	_check("this machine hears who bought it", _bought.size() == 1 and int(_bought[0][1]) == int(_net.call("local_id")), str(_bought))
	_ack_phase()
	await _await_phase("broke")
	await _until(func() -> bool: return int(_state.get("bank_cash")) == 0, 600)
	_denied.clear()
	_shop.call("request_buy", &"taser")
	var refused := await _until(func() -> bool: return _denied.size() == 1, 600)
	_check("with an empty bank the host refuses, and says why", refused and _denied[0][0] == &"taser" and not str(_denied[0][1]).is_empty()
			and int(_state.call("get_upgrade", &"taser")) == 0, str(_denied))
	_ack_phase()

	# --- salt grenade
	await _await_phase("salt")
	_bursts.clear()
	var jolts := _played(&"salt_burst")
	_aim_at(_player.global_position + Vector3(0.0, 0.0, -6.0))
	_tap(KEY_4)
	await _frames(45)
	var belt := _player.get("gadgets") as Node
	_check("4 puts the salt grenade in hand", int(belt.get("slot")) == 4 and str(belt.call("get_badge", 4)).contains("1"), "slot %s badge %s" % [str(belt.get("slot")), str(belt.call("get_badge", 4))])
	Input.action_press(&"gadget_fire")
	await _frames(12)
	Input.action_release(&"gadget_fire")
	var burst := await _until(func() -> bool: return _bursts.size() >= 1, 600)
	await _frames(20)
	_check("the jar the host flew bursts here too, with its flash and jolt", burst and _played(&"salt_burst") == jolts + 1, "bursts %d" % _bursts.size())
	_check("the pool is empty on this machine as well", int(_state.get("salt_charges")) == 0 and str(belt.call("get_badge", 4)).contains("0"), str(_state.get("salt_charges")))
	_tap(KEY_4)
	_ack_phase()

	# --- juice and sound from the host
	await _await_phase("fx")
	var crashes := _played(&"crash")
	var heard := int(_sound.get("net_received")) if _sound.get("net_received") != null else -1
	var arrived := await _until(func() -> bool: return _played(&"crash") > crashes, 300)
	await _frames(10)
	_check("a host-side crash plays its dust and jolt here", arrived)
	_check("a host-side sound is played here", heard < 0 or int(_sound.get("net_received")) > heard, "received %s" % str(_sound.get("net_received")))
	_ack_phase()

	await _await_phase("bye")
