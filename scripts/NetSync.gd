extends Node
## Host-authoritative replication for one contract site (child of Main, named "Net").
##
## The host simulates the world and broadcasts a snapshot WORLD_RATE times a second:
##   - the demon: its 11 ragdoll bodies, AI state, stun, bind level, mood;
##   - loose props, but only the ones that moved since they were last sent;
##   - doors, the van's seal and the salt circle, as a handful of bits;
##   - every player: where their owner says they are, plus what the host has worked
##     out for them (what is in their hands, rope, arcs and tape, leash, possession).
## The snapshot travels as three small unreliable packets on their own channels (demon,
## props, players), each well inside one MTU even with four players, so losing one never
## costs the others. Each client reports its own body and held-down inputs OWNER_RATE times a second, and
## sends one-shot actions (use a door, throw, shove) as reliable commands. Clients ease
## everything toward the newest snapshot over one send interval, which hides the tick
## rate without adding more than that interval of latency.
##
## Solo games have this node too: nothing is sent, but the one-shot effects that the
## rest of the game asks for through it (`fx`, `blackout`) still play locally.

const Player := preload("res://scripts/Player.gd")
const GadgetAudio := preload("res://scripts/gadgets/GadgetAudio.gd")
const DemonAudio := preload("res://scripts/DemonAudio.gd")
const FlickerLight := preload("res://scripts/FlickerLight.gd")
const Parts := preload("res://scripts/gadgets/GadgetParts.gd")

const WORLD_RATE := 20.0
const OWNER_RATE := 30.0
## Most props carried by one snapshot; the rest wait their turn.
const PROPS_PER_TICK := 24
const DEMON_BODIES := 11
const DEMON_FLOATS := DEMON_BODIES * 7 + 3
## What a client may ask the host to do with its body, and what the host may do to a client's.
const COMMANDS: Array[StringName] = [&"interact", &"throw", &"shove", &"release", &"break_leash"]
const OWNER_CALLS: Array[StringName] = [&"knock_down", &"hurt", &"tumble", &"shoved", &"revive", &"shake", &"drain_stamina", &"set_possessed"]
## Sounds each machine makes for itself; passing them on would only double them.
const LOCAL_CUES: Array[StringName] = [&"equip", &"dry"]

## True while a co-op session is running (false in solo).
var active := false
var snapshots_sent := 0
var snapshots_received := 0

var _main: Node
var _level: Node
var _props: Array[RigidBody3D] = []
var _doors: Array = []
var _audio: GadgetAudio
var _world_clock := 0.0
var _owner_clock := 0.0
var _prop_sent: Array[Transform3D] = []
var _prop_cursor := 0
var _progress_dirty := true
var _demon_from: Array[Transform3D] = []
var _demon_to: Array[Transform3D] = []
var _demon_t := 1.0
var _demon_was_dormant := false
## Prop index -> [from, to, progress].
var _prop_lerps: Dictionary = {}


func setup(main: Node) -> void:
	_main = main
	_level = main.get(&"level")
	_props = GameState.net_props
	_doors = _level.call(&"get_doors")
	GameState.net = self
	_audio = GadgetAudio.new()
	_audio.name = "Audio"
	add_child(_audio)
	active = NetworkManager.is_networked()
	if not active:
		return
	if NetworkManager.is_authority():
		for i in _props.size():
			_prop_sent.append(_props[i].global_transform)
		GameState.objective_changed.connect(_on_progress_changed)
		GameState.bank_changed.connect(_on_progress_changed)
		NetworkManager.peer_ready.connect(_on_peer_ready)
		GadgetAudio.relay = _relay_cue
		DemonAudio.relay = _relay_demon_cue
	else:
		# Mirrors: the host moves these; here they only need to be seen and bumped into.
		for prop in _props:
			prop.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			prop.freeze = true
			prop.set_meta(&"net_mirror", true)


func _exit_tree() -> void:
	if GameState.net == self:
		GameState.net = null
	GadgetAudio.relay = Callable()
	DemonAudio.relay = Callable()


func is_host() -> bool:
	return active and NetworkManager.is_authority()


# --- Ticking -------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not active:
		return
	if NetworkManager.is_authority():
		_world_clock += delta
		if _world_clock >= 1.0 / WORLD_RATE:
			_world_clock = fmod(_world_clock, 1.0 / WORLD_RATE)
			_send_world()
	else:
		_owner_clock += delta
		if _owner_clock >= 1.0 / OWNER_RATE:
			_owner_clock = fmod(_owner_clock, 1.0 / OWNER_RATE)
			_send_owner_state()


func _process(delta: float) -> void:
	if not active or NetworkManager.is_authority():
		return
	var step := delta * WORLD_RATE
	var demon := _demon()
	if demon and _demon_t < 1.0 and _demon_to.size() == DEMON_BODIES:
		_demon_t = minf(1.0, _demon_t + step)
		var bodies: Array[RigidBody3D] = demon.call(&"get_bodies")
		for i in mini(bodies.size(), DEMON_BODIES):
			bodies[i].global_transform = _demon_from[i].interpolate_with(_demon_to[i], _demon_t)
	for index: int in _prop_lerps.keys():
		var entry: Array = _prop_lerps[index]
		var t := minf(1.0, float(entry[2]) + step)
		entry[2] = t
		_props[index].global_transform = (entry[0] as Transform3D).interpolate_with(entry[1] as Transform3D, t)
		if t >= 1.0:
			_prop_lerps.erase(index)


func _clients() -> Array[int]:
	var ready: Array[int] = []
	for id: int in NetworkManager.players:
		if id != 1 and NetworkManager.is_peer_ready(id):
			ready.append(id)
	return ready


func _demon() -> Node3D:
	var demon: Variant = _main.get(&"demon")
	if is_instance_valid(demon) and not (demon as Node).is_queued_for_deletion():
		return demon as Node3D
	return null


# --- Host: the world snapshot ---------------------------------------------------------

func _send_world() -> void:
	var clients := _clients()
	if clients.is_empty():
		return
	if _progress_dirty:
		_progress_dirty = false
		var progress := GameState.get_sync()
		for id in clients:
			_progress.rpc_id(id, progress)
	var demon_floats := PackedFloat32Array()
	var demon_ints := PackedInt32Array()
	_write_demon(demon_floats, demon_ints)
	var prop_ids := PackedInt32Array()
	var prop_floats := PackedFloat32Array()
	_write_props(prop_ids, prop_floats)
	var ids := PackedInt32Array()
	var owner_floats := PackedFloat32Array()
	var owner_ints := PackedInt32Array()
	var sim_floats := PackedFloat32Array()
	var sim_ints := PackedInt32Array()
	var bodies: Dictionary = _main.get(&"players")
	for id: int in bodies:
		var body := bodies[id] as Player
		if not is_instance_valid(body):
			continue
		ids.append(id)
		body.write_owner_state(owner_floats, owner_ints)
		body.write_sim_state(sim_floats, sim_ints)
	var world := _write_world()
	for id in clients:
		if not demon_floats.is_empty():
			_world_demon.rpc_id(id, demon_floats, demon_ints)
		if not prop_ids.is_empty():
			_world_props.rpc_id(id, prop_ids, prop_floats)
		_world_players.rpc_id(id, ids, owner_floats, owner_ints, sim_floats, sim_ints, world)
	snapshots_sent += 1


func _write_demon(floats: PackedFloat32Array, ints: PackedInt32Array) -> void:
	var demon := _demon()
	if demon == null:
		return
	var brain := demon.get_node("AI")
	for body: RigidBody3D in demon.call(&"get_bodies"):
		var at := body.global_position
		var turn := body.global_transform.basis.orthonormalized().get_rotation_quaternion()
		floats.append_array(PackedFloat32Array([at.x, at.y, at.z, turn.x, turn.y, turn.z, turn.w]))
	floats.append(float(demon.get(&"stun_meter")))
	floats.append(float(brain.get(&"mood_rage")))
	floats.append(float(demon.get(&"breakout_tension")))
	var bits := 0
	for flag: bool in [demon.get(&"is_stunned"), demon.get(&"stun_locked"), demon.get(&"contained"), float(demon.get(&"shock_resist_left")) > 0.0,
			demon.get(&"is_dormant"), brain.get(&"is_discovered"), brain.get(&"is_in_van"), brain.get(&"is_sealed"), brain.get(&"mood_casting")]:
		bits = (bits << 1) | (1 if flag else 0)
	ints.append_array(PackedInt32Array([int(brain.get(&"state")), bits, int(demon.get(&"bind_level")), int(demon.call(&"get_hauler_count")),
			int(brain.call(&"get_player_count"))]))


## Props that have moved since they were last sent, a bounded number per snapshot.
func _write_props(ids: PackedInt32Array, floats: PackedFloat32Array) -> void:
	var count := _props.size()
	for n in count:
		if ids.size() >= PROPS_PER_TICK:
			break
		var index := (_prop_cursor + n) % count
		var prop := _props[index]
		if not is_instance_valid(prop):
			continue
		var now := prop.global_transform
		var sent := _prop_sent[index]
		if now.origin.distance_squared_to(sent.origin) < 0.0004 and now.basis.x.dot(sent.basis.x) > 0.9995 and now.basis.y.dot(sent.basis.y) > 0.9995:
			continue
		_prop_sent[index] = now
		var turn := now.basis.orthonormalized().get_rotation_quaternion()
		ids.append(index)
		floats.append_array(PackedFloat32Array([now.origin.x, now.origin.y, now.origin.z, turn.x, turn.y, turn.z, turn.w]))
	_prop_cursor = (_prop_cursor + PROPS_PER_TICK) % maxi(count, 1)


func _write_world() -> PackedInt32Array:
	var doors := 0
	for i in _doors.size():
		if (_doors[i] as Node).get(&"is_open"):
			doors |= 1 << i
	var flags := 0
	if (_level.get(&"van") as Node).get(&"is_sealed"):
		flags |= 1
	var possession: Variant = _main.get(&"possession")
	if is_instance_valid(possession) and (possession as Node).get(&"circle_active"):
		flags |= 2
	return PackedInt32Array([doors, flags])


## Everything is re-sent to a machine that has just finished loading the site.
func _on_peer_ready(_id: int) -> void:
	_progress_dirty = true
	for i in _prop_sent.size():
		_prop_sent[i] = Transform3D(Basis.IDENTITY, Vector3(0.0, -9999.0, 0.0))


func _on_progress_changed(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null, _e: Variant = null) -> void:
	_progress_dirty = true


# --- Client: reading the snapshot -----------------------------------------------------

func _send_owner_state() -> void:
	var body: Variant = _main.get(&"player")
	if not is_instance_valid(body) or not NetworkManager.is_peer_ready(1):
		return
	var floats := PackedFloat32Array()
	var ints := PackedInt32Array()
	(body as Player).write_owner_state(floats, ints)
	_owner_state.rpc_id(1, floats, ints)


@rpc("any_peer", "call_remote", "unreliable_ordered", 4)
func _owner_state(floats: PackedFloat32Array, ints: PackedInt32Array) -> void:
	if not is_host():
		return
	var body := (_main.get(&"players") as Dictionary).get(multiplayer.get_remote_sender_id()) as Player
	if is_instance_valid(body):
		body.read_owner_state(floats, 0, ints, 0)


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _world_demon(floats: PackedFloat32Array, ints: PackedInt32Array) -> void:
	if active and not NetworkManager.is_authority():
		_read_demon(floats, ints)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _world_props(ids: PackedInt32Array, floats: PackedFloat32Array) -> void:
	if active and not NetworkManager.is_authority():
		_read_props(ids, floats)


@rpc("authority", "call_remote", "unreliable_ordered", 3)
func _world_players(ids: PackedInt32Array, owner_floats: PackedFloat32Array, owner_ints: PackedInt32Array,
		sim_floats: PackedFloat32Array, sim_ints: PackedInt32Array, world: PackedInt32Array) -> void:
	if not active or NetworkManager.is_authority():
		return
	snapshots_received += 1
	var bodies: Dictionary = _main.get(&"players")
	for n in ids.size():
		var body := bodies.get(ids[n]) as Player
		if not is_instance_valid(body):
			continue
		body.read_owner_state(owner_floats, n * Player.OWNER_FLOATS, owner_ints, n * Player.OWNER_INTS)
		body.read_sim_state(sim_floats, n * Player.SIM_FLOATS, sim_ints, n * Player.SIM_INTS)
	_read_world(world)


func _read_demon(floats: PackedFloat32Array, ints: PackedInt32Array) -> void:
	var demon := _demon()
	if demon == null or floats.size() < DEMON_FLOATS or ints.size() < 5:
		return
	var bits := ints[1]
	var dormant := bits & 16 != 0
	demon.call(&"apply_net", floats[DEMON_BODIES * 7], bits & 256 != 0, ints[2], bits & 128 != 0, bits & 64 != 0, bits & 32 != 0, dormant)
	demon.set(&"breakout_tension", floats[DEMON_BODIES * 7 + 2])
	demon.set(&"net_haulers", ints[3])
	var brain := demon.get_node("AI")
	brain.call(&"apply_net", ints[0], bits & 8 != 0, bits & 4 != 0, bits & 2 != 0, floats[DEMON_BODIES * 7 + 1], bits & 1 != 0)
	brain.call(&"set_player_count", ints[4])
	var bodies: Array[RigidBody3D] = demon.call(&"get_bodies")
	if bodies.size() < DEMON_BODIES:
		return
	_demon_from.resize(DEMON_BODIES)
	_demon_to.resize(DEMON_BODIES)
	# A demon stepping back into the world (or teleported) appears where it is, not on the way there.
	var snap := _demon_was_dormant or dormant
	_demon_was_dormant = dormant
	for i in DEMON_BODIES:
		var o := i * 7
		var turn := Quaternion(floats[o + 3], floats[o + 4], floats[o + 5], floats[o + 6])
		var target := Transform3D(Basis(turn.normalized()) if turn.length_squared() > 0.5 else Basis.IDENTITY, Vector3(floats[o], floats[o + 1], floats[o + 2]))
		if not target.origin.is_finite():
			return
		var current := bodies[i].global_transform
		if snap or current.origin.distance_squared_to(target.origin) > 9.0:
			current = target
			bodies[i].global_transform = target
		_demon_from[i] = current
		_demon_to[i] = target
	_demon_t = 0.0


func _read_props(ids: PackedInt32Array, floats: PackedFloat32Array) -> void:
	if floats.size() < ids.size() * 7:
		return
	for n in ids.size():
		var index := ids[n]
		if index < 0 or index >= _props.size() or not is_instance_valid(_props[index]):
			continue
		var o := n * 7
		var turn := Quaternion(floats[o + 3], floats[o + 4], floats[o + 5], floats[o + 6])
		var at := Vector3(floats[o], floats[o + 1], floats[o + 2])
		if not at.is_finite() or turn.length_squared() < 0.5:
			continue
		var target := Transform3D(Basis(turn.normalized()), at)
		var current := _props[index].global_transform
		if current.origin.distance_squared_to(at) > 16.0:
			# Reset to its shelf between contracts: no slow flight across the house.
			_props[index].global_transform = target
			_prop_lerps.erase(index)
		else:
			_prop_lerps[index] = [current, target, 0.0]


func _read_world(world: PackedInt32Array) -> void:
	if world.size() < 2:
		return
	for i in _doors.size():
		var door := _doors[i] as Node
		var open := world[0] & (1 << i) != 0
		if bool(door.get(&"is_open")) != open:
			door.call(&"set_open", open, false)
	var van := _level.get(&"van") as Node
	var sealed := world[1] & 1 != 0
	if bool(van.get(&"is_sealed")) != sealed:
		van.call(&"seal" if sealed else &"release")
	var possession: Variant = _main.get(&"possession")
	if is_instance_valid(possession):
		(possession as Node).set(&"circle_active", world[1] & 2 != 0)


@rpc("authority", "call_remote", "reliable")
func _progress(data: Array) -> void:
	GameState.apply_sync(data)


# --- One-shot traffic -----------------------------------------------------------------

## Client: ask the host to do `action` with this machine's body.
func send_command(action: StringName, arg: int = 0) -> void:
	if active and not NetworkManager.is_authority() and NetworkManager.is_peer_ready(1):
		_command.rpc_id(1, action, arg)


@rpc("any_peer", "call_remote", "reliable")
func _command(action: StringName, arg: int) -> void:
	if not is_host() or not COMMANDS.has(action):
		return
	var body := (_main.get(&"players") as Dictionary).get(multiplayer.get_remote_sender_id()) as Player
	if is_instance_valid(body):
		body.perform(action, arg)


## Host: run `method` on the machine that owns the body of `peer_id`.
func send_to_owner(peer_id: int, method: StringName, args: Array, reliable: bool = true) -> void:
	if not is_host() or peer_id == 1 or not NetworkManager.is_peer_ready(peer_id):
		return
	if reliable:
		_owner_call.rpc_id(peer_id, method, args)
	else:
		_owner_call_soft.rpc_id(peer_id, method, args)


@rpc("authority", "call_remote", "reliable")
func _owner_call(method: StringName, args: Array) -> void:
	var body: Variant = _main.get(&"player")
	if OWNER_CALLS.has(method) and is_instance_valid(body):
		(body as Node).callv(method, args)


@rpc("authority", "call_remote", "unreliable")
func _owner_call_soft(method: StringName, args: Array) -> void:
	_owner_call(method, args)


## Host: a line for the notice strip of one peer, or of every client (`peer_id` 0).
func send_notice(text: String, peer_id: int = 0) -> void:
	if not is_host():
		return
	if peer_id == 0:
		for id in _clients():
			_notice.rpc_id(id, text)
	elif peer_id != 1 and NetworkManager.is_peer_ready(peer_id):
		_notice.rpc_id(peer_id, text)


@rpc("authority", "call_remote", "reliable")
func _notice(text: String) -> void:
	GameState.notice_posted.emit(text)


## Host: the contract has paid out / been lost / been reset. The clients follow suit.
func show_summary(payout: Dictionary) -> void:
	for id in _host_clients():
		_summary.rpc_id(id, payout)


func show_failure(report: Dictionary) -> void:
	for id in _host_clients():
		_failure.rpc_id(id, report)


func site_reset(tier: int) -> void:
	_on_peer_ready(0)
	for id in _host_clients():
		_site_reset.rpc_id(id, tier)


func _host_clients() -> Array[int]:
	var nobody: Array[int] = []
	return _clients() if is_host() else nobody


@rpc("authority", "call_remote", "reliable")
func _summary(payout: Dictionary) -> void:
	_main.get(&"contracts").call(&"remote_summary", payout)


@rpc("authority", "call_remote", "reliable")
func _failure(report: Dictionary) -> void:
	_main.get(&"contracts").call(&"remote_failure", report)


@rpc("authority", "call_remote", "reliable")
func _site_reset(tier: int) -> void:
	_prop_lerps.clear()
	_main.get(&"contracts").call(&"remote_reset", tier)


# --- Effects ---------------------------------------------------------------------------

## A one-shot effect at `at`, here and on every client:
##   snap    tape tearing: orange sparks and a crack
##   smoke   the demon entering or leaving a player: black smoke shot with embers
##   sparks  an exorcism landing: a white-blue burst
##   shadow  the evasive lunge: a puff of dark ash where it stood
func fx(kind: StringName, at: Vector3) -> void:
	_play_fx(kind, at)
	for id in _host_clients():
		_fx.rpc_id(id, kind, at)


@rpc("authority", "call_remote", "reliable")
func _fx(kind: StringName, at: Vector3) -> void:
	_play_fx(kind, at)


## Every haunted lamp within `radius` of `center` goes dark for `seconds`, on every machine.
func blackout(center: Vector3, radius: float, seconds: float) -> void:
	_do_blackout(center, radius, seconds)
	for id in _host_clients():
		_blackout.rpc_id(id, center, radius, seconds)


@rpc("authority", "call_remote", "reliable")
func _blackout(center: Vector3, radius: float, seconds: float) -> void:
	_do_blackout(center, radius, seconds)


func _do_blackout(center: Vector3, radius: float, seconds: float) -> void:
	for node in get_tree().get_nodes_in_group(FlickerLight.GROUP):
		var light := node.get_parent() as Node3D
		if light and light.global_position.distance_to(center) < radius:
			(node as FlickerLight).blackout(seconds + randf_range(0.0, 0.5))
	_audio.play(&"snap", center, 3.0, 0.6)


func _play_fx(kind: StringName, at: Vector3) -> void:
	match kind:
		&"snap":
			_burst(at, Parts.particles(Color(1.0, 0.62, 0.22), 46, 0.6, Vector2(1.5, 5.5), Vector2(0.012, 0.032), Vector3(0.0, -7.0, 0.0)))
			_audio.play(&"snap", at, 4.0, 0.85)
			_audio.play(&"rip", at, 2.0, 0.7)
		&"smoke":
			_burst(at, Parts.particles(Color(0.05, 0.04, 0.04, 0.75), 60, 1.4, Vector2(0.6, 3.2), Vector2(0.22, 0.6), Vector3(0.0, 0.9, 0.0), 180.0, true, false))
			_burst(at, Parts.particles(Color(1.0, 0.42, 0.08), 44, 0.9, Vector2(1.2, 4.6), Vector2(0.014, 0.04), Vector3(0.0, -2.5, 0.0)))
			_audio.play(&"hiss", at, 3.0, 0.55)
			_audio.play(&"growl", at, 2.0, 1.1)
		&"sparks":
			_burst(at, Parts.particles(Color(0.7, 0.9, 1.0), 60, 0.6, Vector2(2.0, 7.0), Vector2(0.012, 0.034), Vector3(0.0, -8.0, 0.0)))
			_audio.play(&"snap", at, 4.0, 1.2)
		&"shadow":
			_burst(at, Parts.particles(Color(0.03, 0.03, 0.04, 0.8), 40, 0.8, Vector2(0.4, 2.2), Vector2(0.2, 0.5), Vector3(0.0, 0.5, 0.0), 180.0, true, false))


## Fires a one-shot emitter at `at` and sweeps it up afterwards.
func _burst(at: Vector3, emitter: GPUParticles3D) -> void:
	add_child(emitter)
	emitter.global_position = at
	emitter.restart()
	get_tree().create_timer(emitter.lifetime + 0.6).timeout.connect(emitter.queue_free)


# --- Sound relays (host) -----------------------------------------------------------------

func _relay_cue(cue: StringName, at: Vector3, volume_db: float, pitch: float) -> void:
	if LOCAL_CUES.has(cue):
		return
	for id in _host_clients():
		_cue.rpc_id(id, cue, at, volume_db, pitch)


@rpc("authority", "call_remote", "unreliable")
func _cue(cue: StringName, at: Vector3, volume_db: float, pitch: float) -> void:
	_audio.play(cue, at, volume_db, pitch)


func _relay_demon_cue(cue: StringName, amount: float) -> void:
	for id in _host_clients():
		_demon_cue.rpc_id(id, cue, amount)


@rpc("authority", "call_remote", "unreliable")
func _demon_cue(cue: StringName, amount: float) -> void:
	var demon := _demon()
	var voice := demon.get_node_or_null("Audio") if demon else null
	if voice == null:
		return
	match cue:
		&"roar":
			voice.call(&"play_roar")
		&"rasp":
			voice.call(&"play_rasp", amount)
		&"buzz":
			voice.call(&"play_buzz", amount)
		&"thud":
			voice.call(&"play_thud", amount)
		&"whoosh":
			voice.call(&"play_whoosh", amount)
