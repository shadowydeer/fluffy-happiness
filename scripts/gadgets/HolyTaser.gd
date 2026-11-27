extends "res://scripts/gadgets/Gadget.gd"
## Slot 2: the Holy Taser, an industrial-occult stun gun for close quarters.
##
## Holding LMB throws jagged arcs up to 3.8 m. Targeting is generous: a ray, then
## a fat ball swept down the same line, then anything of the demon inside a cone,
## because nobody aims well at a thrashing horror in the dark. A shocked demon
## gains 30 stun a second and convulses; loose props get a spark and a shove.
## A crewmate caught in the arc takes no damage at all, only two and a half seconds
## of helpless cartwheeling. A possessed one is being exorcised instead.
##
## The battery drains 25 %/s (four seconds of trigger: one charge is just enough to put a
## fresh demon down if every moment of it lands), recharges 24 %/s after 0.6 s of rest,
## and running it flat vents steam and locks the trigger for 2.8 s.

const RANGE := 3.8
const CAST_RADIUS := 0.38
const CONE_DEGREES := 24.0
const STUN_RATE := 30.0
const DRAIN := 25.0
const RECHARGE := 24.0
const RECHARGE_DELAY := 0.6
const OVERHEAT_TIME := 2.8
const BOLT_STEPS := 9
const ARC_BLUE := Color(0.6, 0.85, 1.0)
const ARC_GOLD := Color(1.0, 0.86, 0.5)
const LED_OK := Color(0.2, 0.95, 1.0)
const LED_LOW := Color(1.0, 0.16, 0.1)
const TARGET_MASK := 2 | 4 | 16
const SOLID_MASK := 1 | 2 | 4 | 8 | 16
## Wire size: hit point, battery, overheat / target, flags.
const NET_FLOATS := 5
const NET_INTS := 2

## 0..100.
var battery := 100.0
var overheat_left := 0.0
var firing := false
## Seconds of trigger time so far, and how many times it has cooked off.
var zap_time := 0.0
var overheats := 0

var _fired := false
var _rest := RECHARGE_DELAY
var _target: Node3D
var _hit := Vector3.ZERO
var _has_hit := false
var _shove_left := 0.0
var _time := 0.0
var _idle_wait := 0.6
var _idle_show := 0.0
var _muzzle: Node3D
var _prongs: Array[Node3D] = []
var _leds: Array[StandardMaterial3D] = []
var _bolts: MeshInstance3D
var _bolt_mesh: ImmediateMesh
var _light: OmniLight3D
var _sparks: GPUParticles3D
var _steam: GPUParticles3D


func _build(root: Node3D) -> void:
	title = "HOLY TASER"
	view_offset = Vector3(0.19, -0.215, -0.45)
	view_tilt = Vector3(0.0, 0.07, 0.0)
	body_offset = Vector3(0.28, 1.2, -0.42)
	palm_right = Vector3(0.022, 0.0, 0.0)
	var steel := Parts.steel()
	var brass := Parts.brass()
	var copper := Parts.copper()
	var rubber := Parts.rubber()
	var along := Vector3(-PI * 0.5, 0.0, 0.0)  # stands a lathed part's +Y along the barrel (-Z)
	var bore := 0.078  # height of the barrel's centre line above the middle of the grip

	# Insulated grip, raked back, with finger ridges and a brass butt cap.
	var grip_node := Node3D.new()
	grip_node.rotation.x = -0.24
	root.add_child(grip_node)
	Parts.part(grip_node, Parts.lathe(PackedVector2Array([Vector2(0.0, -0.064), Vector2(0.019, -0.062), Vector2(0.0225, -0.03),
			Vector2(0.021, 0.0), Vector2(0.0225, 0.03), Vector2(0.02, 0.058), Vector2(0.0, 0.06)]), 20), rubber, Vector3.ZERO, Vector3.ZERO, Vector3(0.9, 1.0, 1.2))
	for i in 5:
		Parts.part(grip_node, Parts.torus(0.0215, 0.0026), rubber, Vector3(0.0, -0.044 + i * 0.02, 0.0), Vector3.ZERO, Vector3(0.9, 1.0, 1.2))
	Parts.part(grip_node, Parts.lathe(PackedVector2Array([Vector2(0.0, -0.08), Vector2(0.015, -0.078), Vector2(0.022, -0.07), Vector2(0.0215, -0.062), Vector2(0.0, -0.06)]), 20),
			brass, Vector3.ZERO, Vector3.ZERO, Vector3(0.9, 1.0, 1.2))

	# Weathered steel body: a fat breech stepping down to the coil housing, cooling fins behind.
	Parts.part(root, Parts.lathe(PackedVector2Array([Vector2(0.0, -0.072), Vector2(0.022, -0.068), Vector2(0.031, -0.05), Vector2(0.032, 0.03),
			Vector2(0.03, 0.045), Vector2(0.0235, 0.052), Vector2(0.0235, 0.115), Vector2(0.029, 0.122), Vector2(0.029, 0.14),
			Vector2(0.021, 0.146), Vector2(0.0, 0.147)]), 26), steel, Vector3(0.0, bore, 0.0), along)
	for i in 3:
		Parts.part(root, Parts.lathe(PackedVector2Array([Vector2(0.03, -0.0022), Vector2(0.038, -0.0016), Vector2(0.038, 0.0016), Vector2(0.03, 0.0022)]), 26),
				steel, Vector3(0.0, bore, 0.056 - i * 0.012), along)
	# Brass bands and the copper induction coil.
	for z: float in [-0.036, -0.126]:
		Parts.part(root, Parts.lathe(PackedVector2Array([Vector2(0.03, -0.006), Vector2(0.0335, -0.004), Vector2(0.0335, 0.004), Vector2(0.03, 0.006)]), 26),
				brass, Vector3(0.0, bore, z), along)
	for i in 7:
		Parts.part(root, Parts.torus(0.0245, 0.0034), copper, Vector3(0.0, bore, -0.058 - i * 0.0085), Vector3(PI * 0.5, 0.0, 0.0))
	# Ceramic insulator and twin copper prongs.
	Parts.part(root, Parts.lathe(PackedVector2Array([Vector2(0.0, -0.002), Vector2(0.021, 0.0), Vector2(0.022, 0.012), Vector2(0.018, 0.02), Vector2(0.0, 0.021)]), 22),
			Parts.ceramic(), Vector3(0.0, bore, -0.146), along)
	_muzzle = Node3D.new()
	_muzzle.position = Vector3(0.0, bore, -0.226)
	root.add_child(_muzzle)
	for side: float in [-1.0, 1.0]:
		Parts.part(root, Parts.lathe(PackedVector2Array([Vector2(0.0, 0.0), Vector2(0.0058, 0.002), Vector2(0.0048, 0.036), Vector2(0.0028, 0.052), Vector2(0.0, 0.06)]), 10),
				copper, Vector3(side * 0.0125, bore, -0.166), along)
		var tip := Node3D.new()
		tip.position = Vector3(side * 0.0125, bore, -0.226)
		root.add_child(tip)
		_prongs.append(tip)

	# Battery bar on top: five LEDs in a steel rail.
	Parts.part(root, Parts.capsule(0.0095, 0.118), steel, Vector3(0.0, bore + 0.034, -0.005), Vector3(PI * 0.5, 0.0, 0.0))
	for i in 5:
		var led := Parts.glow(LED_OK, 1.7)
		_leds.append(led)
		Parts.part(root, Parts.ball(0.0062), led, Vector3(0.0, bore + 0.042, 0.035 - i * 0.02), Vector3.ZERO, Vector3(1.0, 0.6, 1.25))
	# Battery cell slung under the barrel, wired to the insulator.
	Parts.part(root, Parts.lathe(PackedVector2Array([Vector2(0.0, -0.034), Vector2(0.0135, -0.032), Vector2(0.015, -0.026), Vector2(0.015, 0.026),
			Vector2(0.0135, 0.032), Vector2(0.0, 0.034)]), 16), brass, Vector3(0.0, bore - 0.042, -0.092), along)
	Parts.part(root, Parts.torus(0.0155, 0.0022), copper, Vector3(0.0, bore - 0.042, -0.092), Vector3(PI * 0.5, 0.0, 0.0))
	Parts.part(root, Parts.tube(PackedVector3Array([Vector3(0.0, bore - 0.042, -0.126), Vector3(0.0, bore - 0.05, -0.142), Vector3(0.0, bore - 0.036, -0.155),
			Vector3(0.0, bore - 0.02, -0.152)]), 0.0032, 6), Parts.metal(Color(0.45, 0.04, 0.03), 0.6, 0.0, 0.0))
	# Trigger and guard.
	Parts.part(root, Parts.torus(0.02, 0.003), steel, Vector3(0.0, bore - 0.052, -0.034), Vector3(0.0, 0.0, PI * 0.5), Vector3(1.0, 1.0, 1.25))
	Parts.part(root, Parts.capsule(0.0036, 0.026), brass, Vector3(0.0, bore - 0.05, -0.03), Vector3(0.35, 0.0, 0.0))

	_build_effects(root)


func _build_effects(root: Node3D) -> void:
	_bolt_mesh = ImmediateMesh.new()
	_bolts = MeshInstance3D.new()
	_bolts.name = "Arcs"
	_bolts.mesh = _bolt_mesh
	_bolts.material_override = Parts.additive()
	_bolts.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bolts.top_level = true
	_bolts.visible = false
	add_child(_bolts)
	_light = OmniLight3D.new()
	_light.name = "ArcLight"
	_light.light_color = Color(0.68, 0.86, 1.0)
	_light.omni_range = 4.5
	_light.omni_attenuation = 1.3
	_light.shadow_enabled = false
	_light.top_level = true
	_light.visible = false
	add_child(_light)
	_sparks = Parts.particles(Color(0.7, 0.88, 1.0), 40, 0.35, Vector2(1.2, 4.5), Vector2(0.01, 0.026), Vector3(0.0, -7.0, 0.0), 180.0, false)
	_sparks.top_level = true
	add_child(_sparks)
	_steam = Parts.particles(Color(0.82, 0.86, 0.9, 0.5), 28, 1.1, Vector2(0.25, 0.7), Vector2(0.03, 0.09), Vector3(0.0, 0.5, 0.0), 35.0, false, false)
	_steam.position = Vector3(0.0, 0.1, 0.05)
	root.add_child(_steam)


func get_hint() -> String:
	if overheat_left > 0.0:
		return "TASER OVERHEATED  -  venting   [1] Lasso   [3] Duct tape   [E] Hand grab"
	return "[LMB] Hold to shock (3.8 m)   battery drains - let it rest   [E] Hand grab"


func get_badge() -> String:
	return "OVERHEAT" if overheat_left > 0.0 else ""


func reset() -> void:
	super.reset()
	battery = 100.0
	overheat_left = 0.0
	firing = false
	_fired = false
	_rest = RECHARGE_DELAY
	_steam.emitting = false


# --- Firing ------------------------------------------------------------------------

func use(delta: float, input: Dictionary) -> void:
	if input["fire_pressed"] and overheat_left > 0.0:
		audio.call(&"play", &"dry", _muzzle.global_position)
		notify("TASER OVERHEATED  -  %.1f s" % overheat_left)
	if not input["fire"] or overheat_left > 0.0 or battery <= 0.0:
		return
	_fired = true
	_rest = 0.0
	battery = maxf(0.0, battery - DRAIN * delta)
	_acquire()
	_shock(delta)
	kick = maxf(kick, 0.4)
	player.shake(0.15)
	if battery <= 0.0:
		_overheat()


func simulate(delta: float) -> void:
	_time += delta
	firing = _fired
	_fired = false
	audio.call(&"set_loop", &"buzz", firing, _muzzle.global_position, -2.0, 1.0)
	if firing:
		zap_time += delta
		return
	_target = null
	_has_hit = false
	if overheat_left > 0.0:
		overheat_left -= delta
		if overheat_left <= 0.0:
			overheat_left = 0.0
			_steam.emitting = false
			audio.call(&"play", &"equip", _muzzle.global_position)
		return
	_rest += delta
	if _rest >= RECHARGE_DELAY:
		battery = minf(100.0, battery + RECHARGE * delta)


func _overheat() -> void:
	overheats += 1
	overheat_left = OVERHEAT_TIME
	_steam.emitting = true
	audio.call(&"play", &"hiss", _muzzle.global_position, 2.0)
	audio.call(&"play", &"beep", _muzzle.global_position, -2.0)
	notify("TASER OVERHEATED!")


## A ray, then a fat ball down the same line, then anything of the demon inside the cone.
func _acquire() -> void:
	_target = null
	_has_hit = false
	var space := (player as Node3D).get_world_3d().direct_space_state
	var from: Vector3 = player.get_aim_origin()
	var aim: Vector3 = player.get_aim_forward()
	var exclude: Array[RID] = [player.get_rid()]
	var reach := RANGE
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + aim * RANGE, SOLID_MASK, exclude))
	if not hit.is_empty():
		_hit = hit["position"]
		_has_hit = true
		reach = from.distance_to(_hit)
		if _shockable(hit["collider"]):
			_target = hit["collider"]
			return
	var ball := SphereShape3D.new()
	ball.radius = CAST_RADIUS
	var sweep := PhysicsShapeQueryParameters3D.new()
	sweep.shape = ball
	sweep.collision_mask = TARGET_MASK
	sweep.exclude = exclude
	sweep.transform = Transform3D(Basis.IDENTITY, from + aim * 0.45)
	sweep.motion = aim * maxf(0.0, reach - 0.45)
	var fractions := space.cast_motion(sweep)
	if fractions.size() == 2 and fractions[1] < 1.0:
		sweep.transform.origin += sweep.motion * fractions[1]
		sweep.motion = Vector3.ZERO
		var rest := space.get_rest_info(sweep)
		if not rest.is_empty() and _shockable(instance_from_id(int(rest["collider_id"]))):
			_target = instance_from_id(int(rest["collider_id"]))
			_hit = rest["point"]
			_has_hit = true
			return
	var demon := find_demon()
	if demon == null:
		return
	var best := cos(deg_to_rad(CONE_DEGREES))
	for body: RigidBody3D in demon.call(&"get_bodies"):
		var to := body.global_position - from
		var distance := to.length()
		if distance > RANGE or distance < 0.01:
			continue
		var facing := aim.dot(to / distance)
		if facing > best and space.intersect_ray(PhysicsRayQueryParameters3D.create(from, body.global_position, GameState.LAYER_WORLD, exclude)).is_empty():
			best = facing
			_target = body
			_hit = body.global_position
			_has_hit = true


func _shockable(body: Object) -> bool:
	if _is_crewmate(body):
		return true
	var rigid := body as RigidBody3D
	return rigid != null and not rigid.freeze and (rigid.has_meta(&"demon") or rigid.is_in_group(GameState.GROUP_GRABBABLE))


func _is_crewmate(body: Object) -> bool:
	return body is Node and body != player and (body as Node).is_in_group(GameState.GROUP_PLAYER)


func _shock(delta: float) -> void:
	if not is_instance_valid(_target):
		return
	if _is_crewmate(_target):
		_shock_crewmate(delta)
		return
	var demon := demon_of(_target)
	if demon:
		demon.call(&"add_stun", STUN_RATE * delta)
		demon.call(&"shock", _target, player)
		return
	# Furniture: a crack, a spark and a shove.
	_shove_left -= delta
	if _shove_left <= 0.0:
		_shove_left = 0.22
		var push: Vector3 = (player.get_aim_forward() + Vector3.UP * 0.5).normalized()
		var prop := _target as RigidBody3D
		prop.apply_impulse(push * minf(prop.mass * 1.4, 4.5), _hit - prop.global_position)


## Friendly fire. Nobody is hurt: a clean crewmate cartwheels across the room, and a
## possessed one has the demon burned out of them (a second and a half of current).
func _shock_crewmate(delta: float) -> void:
	var possession: Variant = GameState.possession
	if _target.get(&"possessed"):
		if is_instance_valid(possession):
			(possession as Node).call(&"exorcise", _target, delta, player)
		return
	var away: Vector3 = player.get_aim_forward()
	away.y = 0.0
	away = away.normalized() if away.length_squared() > 0.001 else Vector3.FORWARD
	if not _target.call(&"is_tumbling"):
		GameState.post_notice("%s TASED %s  -  no harm done" % [str(player.display_name), str(_target.get(&"display_name"))])
	_target.call(&"tumble", away * 5.5 + Vector3.UP * 3.6)


# --- Arcs, light and the battery bar ----------------------------------------------------

func animate(delta: float) -> void:
	# A live tool spits a little arc between its prongs now and then.
	if firing or battery < 5.0 or overheat_left > 0.0:
		_idle_show = 0.0
		return
	_idle_show -= delta
	_idle_wait -= delta
	if _idle_wait <= 0.0:
		_idle_wait = randf_range(0.25, 1.1)
		_idle_show = 0.06


func _process(delta: float) -> void:
	if is_puppet():
		_time += delta
		audio.call(&"set_loop", &"buzz", firing, _muzzle.global_position, -2.0, 1.0)
		_steam.emitting = overheat_left > 0.0
		if firing and is_instance_valid(_target):
			# The host convulses the limbs; the electric rim is drawn here.
			var demon := demon_of(_target)
			var visuals := demon.get_node_or_null("Visuals") if demon else null
			if visuals:
				visuals.call(&"set_shock", 1.0)
	_update_leds()
	var idle_arc := _idle_show > 0.0 and view.visible and not firing
	_bolts.visible = firing or idle_arc
	_light.visible = firing or idle_arc
	_sparks.emitting = firing and _has_hit
	if not _bolts.visible:
		return
	var camera := get_viewport().get_camera_3d()
	var eye := camera.global_position if camera else global_position
	var left := _prongs[0].global_position
	var right := _prongs[1].global_position
	_bolts.global_transform = Transform3D.IDENTITY
	_bolt_mesh.clear_surfaces()
	_bolt_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	if idle_arc:
		_bolt(left, right, 0.0022, ARC_BLUE, 0.3, eye, false)
		_light.global_position = _muzzle.global_position
		_light.light_energy = 0.35
	else:
		var end := _hit
		if not _has_hit:
			# Nothing in reach: the arcs gutter out into the air.
			end = _muzzle.global_position - _muzzle.global_transform.basis.z * 0.9 + Vector3(randf_range(-0.25, 0.25), randf_range(-0.25, 0.25), randf_range(-0.25, 0.25))
		_bolt(left, end, 0.011, ARC_BLUE, 0.16, eye, true)
		_bolt(right, end, 0.009, ARC_GOLD, 0.2, eye, true)
		_bolt(_muzzle.global_position, end, 0.006, Color.WHITE, 0.1, eye, false)
		# Kept well back from the target and dim: the arc lights the room, it must not bleach the demon.
		_light.global_position = end.lerp(_muzzle.global_position, 0.6)
		_light.light_energy = randf_range(0.5, 1.5)
		_sparks.global_position = end
	_bolt_mesh.surface_end()


## One jagged bolt, re-rolled every frame. `forked` adds side branches that die in the air.
func _bolt(from: Vector3, to: Vector3, width: float, color: Color, jag: float, eye: Vector3, forked: bool) -> void:
	var span := to - from
	var length := span.length()
	if length < 0.004:
		return
	var axis := span / length
	var side := axis.cross(Vector3.UP if absf(axis.y) < 0.95 else Vector3.RIGHT).normalized()
	var up := axis.cross(side)
	var previous := from
	for i in range(1, BOLT_STEPS + 1):
		var t := float(i) / BOLT_STEPS
		var point := from + span * t
		if i < BOLT_STEPS:
			var swell := sin(t * PI) * jag * minf(length, 1.6)
			point += side * randf_range(-1.0, 1.0) * swell + up * randf_range(-1.0, 1.0) * swell
		_ribbon(previous, point, width, color, eye)
		if forked and i < BOLT_STEPS and randf() < 0.3:
			var stray := point + (side * randf_range(-1.0, 1.0) + up * randf_range(-1.0, 1.0) + axis * 0.6).normalized() * randf_range(0.12, 0.4)
			_ribbon(point, point.lerp(stray, 0.5) + up * randf_range(-0.05, 0.05), width * 0.6, color, eye)
			_ribbon(point.lerp(stray, 0.5), stray, width * 0.35, color, eye)
		previous = point


## Camera-facing strip: a hot core inside a wide, faint sheath.
func _ribbon(a: Vector3, b: Vector3, width: float, color: Color, eye: Vector3) -> void:
	var across := (b - a).cross(eye - a)
	if across.length_squared() < 1e-12:
		return
	across = across.normalized()
	for layer: Vector2 in [Vector2(3.2, 0.22), Vector2(1.0, 1.0)]:
		var half := across * width * layer.x
		var tint := Color(color.r, color.g, color.b, layer.y)
		for corner: Vector3 in [a - half, a + half, b + half, a - half, b + half, b - half]:
			_bolt_mesh.surface_set_color(tint)
			_bolt_mesh.surface_add_vertex(corner)


func _update_leds() -> void:
	var lit := int(ceil(battery / 20.0))
	var low := battery < 25.0 or overheat_left > 0.0
	var blink := overheat_left > 0.0 and fmod(_time, 0.3) < 0.15
	for i in _leds.size():
		var on := (i < lit and not overheat_left > 0.0) or blink
		_leds[i].emission = LED_LOW if low else LED_OK
		_leds[i].emission_energy_multiplier = 1.7 if on else 0.05


# --- Replication -------------------------------------------------------------------------

func write_net(floats: PackedFloat32Array, ints: PackedInt32Array) -> void:
	floats.append_array(PackedFloat32Array([_hit.x, _hit.y, _hit.z, battery, overheat_left]))
	ints.append(GameState.body_ref(_target) if firing else 0)
	ints.append((1 if firing else 0) | (2 if _has_hit else 0))


func read_net(floats: PackedFloat32Array, f: int, ints: PackedInt32Array, i: int) -> void:
	_hit = Vector3(floats[f], floats[f + 1], floats[f + 2])
	battery = floats[f + 3]
	overheat_left = floats[f + 4]
	_target = GameState.ref_body(ints[i])
	firing = ints[i + 1] & 1 != 0
	_has_hit = ints[i + 1] & 2 != 0
