extends "res://scripts/gadgets/Gadget.gd"
## Slot 1: the Holy Lasso.
##
## LMB throws a glowing rope up to 11 m. A ray picks the target and a 0.22 m ball
## swept down the same line forgives near misses, so a thrashing limb is easy to
## catch. The rope latches onto any demon segment or loose prop and cinches a
## golden collar round it.
##
## The rope is a one-way spring: slack does nothing, stretch past `rest_length`
## pulls the caught body toward the holder with a capped, damped force applied at
## the exact attachment point, so hauling on an arm swings the whole ragdoll. A
## conscious demon pulls back (it drags the holder and burns their stamina); a
## stunned one comes quietly. Holding LMB reels in, RMB hammers an anchor pin into
## a nearby surface and ties the rope off there, which frees the hands for the
## taser or the tape. An anchored demon thrashes and snaps the rope in 8-12 s.
##
## Crewmates can be roped too. The rope then works as a leash (see Player.set_leash):
## reel a friend out from under a flying couch, drag a possessed one to the salt
## circle, or pin one to a porch column with RMB. They get out by mashing Space, or
## with R once two seconds have passed.

enum Mode { IDLE, FLYING, ATTACHED, ANCHORED, RETURNING }

const RANGE := 11.0
const CAST_RADIUS := 0.22
const FLY_SPEED := 60.0
const RETURN_TIME := 0.16
const ANCHOR_RANGE := 3.5
const MIN_LENGTH := 1.3
const REEL_SPEED := 2.4
## A press shorter than this lets go of the rope; longer reels it in.
const TAP_TIME := 0.22
const STIFFNESS := 9.0
const RESPONSE := 11.0
const MAX_CLOSE_SPEED := 8.0
## Top closing speed of a stunned demon on the rope: a haul, not a slingshot.
const LIMP_CLOSE_SPEED := 5.5
const PROP_FORCE := 480.0
const AWAKE_FORCE := 190.0
const ANCHOR_FORCE := 760.0
## m/s the holder is dragged toward a conscious demon at full tension.
const COUNTER_PULL := 3.4
const STAMINA_DRAIN := 17.0
## Metres of stretch no rope survives.
const SNAP_STRETCH := 6.0
const ROPE_SEGMENTS := 20
const ROPE_SIDES := 6
const ROPE_RADIUS := 0.014
## Metres of rope per turn of its strands.
const ROPE_LAY := 0.06
const TARGET_MASK := 2 | 4 | 16
const SOLID_MASK := 1 | 2 | 4 | 8 | 16
## Wire size: local point, rope end or anchor, pin normal, tension, rest length / mode, target, flags.
const NET_FLOATS := 11
const NET_INTS := 3

var mode: Mode = Mode.IDLE
## 0..1: how hard the rope is pulling.
var tension := 0.0
var rest_length := 0.0
var shots_fired := 0
var snaps := 0

var _target: RigidBody3D
var _target_demon: Node3D
## A roped crewmate (then `_target` is null).
var _target_player: Node3D
var _local := Vector3.ZERO
var _pending: Node3D
## Puppets only: the wire id of what the rope was last seen tied to.
var _net_ref := 0
var _tip := Vector3.ZERO
var _fly_from := Vector3.ZERO
var _fly_to := Vector3.ZERO
var _fly_time := 0.1
var _fly_left := 0.0
var _anchor := Vector3.ZERO
var _anchor_life := 0.0
var _press_time := 0.0
var _press_is_shot := false
var _release_asked := false
var _thrash_left := 0.0
var _time := 0.0
var _muzzle: Node3D
var _noose: MeshInstance3D
var _rope: MeshInstance3D
var _rope_mesh: ImmediateMesh
var _rope_material: StandardMaterial3D
var _collar: MeshInstance3D
var _pin: Node3D
var _hit_sparks: GPUParticles3D
var _strain_sparks: GPUParticles3D


func _build(root: Node3D) -> void:
	title = "HOLY LASSO"
	view_offset = Vector3(0.21, -0.2, -0.44)
	view_tilt = Vector3(-0.22, 0.1, 0.12)
	body_offset = Vector3(0.3, 1.12, -0.36)
	palm_right = Vector3(0.022, 0.0, 0.0)
	var brass := Parts.brass()
	var leather := Parts.leather()
	var fibre := Parts.rope(0.85)

	# Leather-wrapped grip, swelling under the fingers, bound with waxed cord.
	Parts.part(root, Parts.lathe(PackedVector2Array([Vector2(0.0, -0.062), Vector2(0.017, -0.06), Vector2(0.0205, -0.03),
			Vector2(0.0215, 0.0), Vector2(0.0195, 0.035), Vector2(0.017, 0.06), Vector2(0.0, 0.062)]), 20), leather)
	for i in 7:
		Parts.part(root, Parts.torus(0.0205 - absf(i - 3.0) * 0.0007, 0.0019), Parts.metal(Color(0.09, 0.05, 0.03), 0.8, 0.0, 0.4), Vector3(0.0, -0.045 + i * 0.015, 0.0))
	# Brass pommel with a ring, and the ferrule the rope guide grows out of.
	Parts.part(root, Parts.lathe(PackedVector2Array([Vector2(0.0, -0.094), Vector2(0.013, -0.092), Vector2(0.021, -0.08),
			Vector2(0.018, -0.069), Vector2(0.0235, -0.062), Vector2(0.0, -0.058)]), 20), brass)
	Parts.part(root, Parts.torus(0.012, 0.0028), brass, Vector3(0.0, -0.103, 0.0), Vector3(PI * 0.5, 0.0, 0.0))
	Parts.part(root, Parts.lathe(PackedVector2Array([Vector2(0.0, 0.058), Vector2(0.0235, 0.06), Vector2(0.0245, 0.07),
			Vector2(0.019, 0.078), Vector2(0.011, 0.094), Vector2(0.006, 0.1), Vector2(0.0, 0.101)]), 20), brass)
	Parts.part(root, Parts.torus(0.0245, 0.002), Parts.copper(), Vector3(0.0, 0.066, 0.0))
	# Guide eye: the rope runs out through it.
	Parts.part(root, Parts.torus(0.019, 0.0042), brass, Vector3(0.0, 0.118, -0.006), Vector3(PI * 0.5, 0.0, 0.0))
	Parts.part(root, Parts.torus(0.019, 0.0016), Parts.glow(Color(1.0, 0.78, 0.3), 2.2), Vector3(0.0, 0.118, -0.006), Vector3(PI * 0.5, 0.0, 0.0), Vector3(0.82, 1.0, 0.82))
	_muzzle = Node3D.new()
	_muzzle.position = Vector3(0.0, 0.118, -0.02)
	root.add_child(_muzzle)

	# The coil hangs from a brass hook in front of the knuckles.
	Parts.part(root, Parts.tube(PackedVector3Array([Vector3(0.0, 0.072, -0.02), Vector3(0.0, 0.074, -0.06), Vector3(0.0, 0.058, -0.094),
			Vector3(0.0, 0.034, -0.1), Vector3(0.0, 0.026, -0.086)]), 0.0038, 8, 0.7), brass)
	var coil := Node3D.new()
	coil.position = Vector3(0.0, -0.022, -0.108)
	root.add_child(coil)
	for i in 6:
		var loop := Parts.part(coil, Parts.torus(0.05 + 0.0025 * sin(i * 2.1), 0.0062), fibre,
				Vector3(0.004 * sin(i * 1.7), 0.003 * cos(i * 2.3), (i - 2.5) * 0.0105))
		loop.rotation = Vector3(PI * 0.5 + 0.07 * sin(i * 1.3), 0.0, 0.09 * cos(i * 1.9))
	# Brass binding that keeps the coil together, and the noose ready at the guide.
	Parts.part(coil, Parts.lathe(PackedVector2Array([Vector2(0.0085, -0.036), Vector2(0.0105, -0.034), Vector2(0.0105, 0.034), Vector2(0.0085, 0.036)]), 12),
			brass, Vector3(0.0, 0.05, 0.0), Vector3(PI * 0.5, 0.0, 0.0))
	_noose = Parts.part(root, Parts.torus(0.026, 0.0058), fibre, Vector3(0.0, 0.124, -0.05), Vector3(PI * 0.5 - 0.35, 0.0, 0.0))

	_build_effects()


func _build_effects() -> void:
	_rope_material = Parts.rope(2.4, 1.0)
	_rope_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rope_mesh = ImmediateMesh.new()
	_rope = MeshInstance3D.new()
	_rope.name = "Rope"
	_rope.mesh = _rope_mesh
	_rope.material_override = _rope_material
	_rope.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rope.top_level = true
	_rope.visible = false
	add_child(_rope)

	# Anchor pin: +Y is the surface normal, the origin sits on the surface.
	_pin = Node3D.new()
	_pin.name = "AnchorPin"
	_pin.top_level = true
	_pin.visible = false
	add_child(_pin)
	var iron := Parts.iron()
	Parts.part(_pin, Parts.lathe(PackedVector2Array([Vector2(0.0, -0.09), Vector2(0.006, -0.06), Vector2(0.011, 0.0), Vector2(0.012, 0.1),
			Vector2(0.03, 0.104), Vector2(0.033, 0.114), Vector2(0.022, 0.124), Vector2(0.0, 0.126)]), 12), iron)
	Parts.part(_pin, Parts.torus(0.034, 0.0065), iron, Vector3(0.0, 0.15, 0.0), Vector3(PI * 0.5, 0.0, 0.0))
	Parts.part(_pin, Parts.torus(0.075, 0.004), Parts.glow(Color(1.0, 0.62, 0.16), 3.0), Vector3(0.0, 0.006, 0.0))
	var seal_material := Parts.additive(Parts.sigil(256))
	seal_material.albedo_color = Color(1.0, 0.66, 0.2, 0.85)
	seal_material.vertex_color_use_as_albedo = false
	var seal := QuadMesh.new()
	seal.size = Vector2(0.34, 0.34)
	Parts.part(_pin, seal, seal_material, Vector3(0.0, 0.004, 0.0), Vector3(-PI * 0.5, 0.0, 0.0))
	var pin_light := OmniLight3D.new()
	pin_light.position = Vector3(0.0, 0.14, 0.0)
	pin_light.light_color = Color(1.0, 0.68, 0.24)
	pin_light.light_energy = 0.6
	pin_light.omni_range = 1.8
	pin_light.shadow_enabled = false
	_pin.add_child(pin_light)

	_hit_sparks = Parts.particles(Color(1.0, 0.78, 0.3), 36, 0.5, Vector2(1.0, 3.6), Vector2(0.012, 0.03), Vector3(0.0, -5.0, 0.0))
	_hit_sparks.top_level = true
	add_child(_hit_sparks)
	_strain_sparks = Parts.particles(Color(1.0, 0.5, 0.15), 22, 0.4, Vector2(0.8, 2.6), Vector2(0.01, 0.024), Vector3(0.0, -6.0, 0.0), 120.0, false)
	_strain_sparks.top_level = true
	add_child(_strain_sparks)


func get_hint() -> String:
	match mode:
		Mode.ATTACHED:
			return "[LMB] Hold: reel in  /  tap: let go   [RMB] Anchor to wall   [R] Detach   [E] Hand grab"
		Mode.ANCHORED:
			return "[R] Release rope   [2] Taser   [3] Duct tape   [E] Hand grab"
	return "[LMB] Shoot lasso (demon, props, crewmates)   [RMB] Anchor to wall   [R] Detach   [E] Hand grab"


func get_badge() -> String:
	match mode:
		Mode.ATTACHED:
			return "ATTACHED"
		Mode.ANCHORED:
			return "ANCHORED"
	return ""


## True while the rope ties `demon` to an anchor pin.
func is_anchoring(demon: Node) -> bool:
	return mode == Mode.ANCHORED and demon != null and _target_demon == demon


func is_tethered() -> bool:
	return mode == Mode.ATTACHED or mode == Mode.ANCHORED


func get_target() -> RigidBody3D:
	return _target if is_tethered() and is_instance_valid(_target) else null


## The crewmate on the end of the rope, if that is what it caught.
func get_target_player() -> Node3D:
	return _target_player if is_tethered() and is_instance_valid(_target_player) else null


## True while this rope has hold of `demon`, pinned or in hand.
func is_roping(demon: Node) -> bool:
	return is_tethered() and demon != null and _target_demon == demon


## The demon has ripped itself off this rope.
func release_demon(demon: Node) -> void:
	if is_roping(demon):
		_snap()


## `who` has fought their way out of this rope.
func release_player(who: Node) -> void:
	if who != null and get_target_player() == who:
		notify("%s slipped your rope" % str(who.get(&"display_name")))
		_detach("")


## R: let go of whatever the rope holds, from any slot.
func request_release() -> void:
	_release_asked = true


func reset() -> void:
	super.reset()
	_release()
	mode = Mode.IDLE
	_rope.visible = false


func _exit_tree() -> void:
	# The collar rides the thing it caught, not this node: take it along.
	if is_instance_valid(_collar):
		_collar.queue_free()
	if _target_demon and is_instance_valid(_target_demon):
		_target_demon.call(&"notify_rope", self, false, false)


# --- Input -------------------------------------------------------------------------

func use(delta: float, input: Dictionary) -> void:
	if input["fire_released"]:
		var tapped := _press_time <= TAP_TIME and not _press_is_shot
		_press_is_shot = false
		if tapped and mode == Mode.ATTACHED:
			_detach("")
			return
	match mode:
		Mode.IDLE:
			if input["fire_pressed"]:
				_fire()
		Mode.ATTACHED:
			if input["fire_pressed"]:
				_press_time = 0.0
			if input["fire"]:
				_press_time += delta
				if _press_time > TAP_TIME:
					rest_length = maxf(MIN_LENGTH, rest_length - REEL_SPEED * delta)
			if input["alt_pressed"]:
				_try_anchor()
		Mode.ANCHORED:
			if input["fire_pressed"]:
				notify("Rope is anchored  -  [R] to release it")


func simulate(delta: float) -> void:
	_time += delta
	if _release_asked:
		_release_asked = false
		if mode == Mode.ATTACHED or mode == Mode.ANCHORED or mode == Mode.FLYING:
			_detach("")
	match mode:
		Mode.FLYING:
			_fly(delta)
		Mode.RETURNING:
			_fly_left -= delta
			if _fly_left <= 0.0:
				mode = Mode.IDLE
		Mode.ATTACHED, Mode.ANCHORED:
			_pull(delta)
	if not is_tethered():
		tension = move_toward(tension, 0.0, delta * 4.0)


# --- Throwing ----------------------------------------------------------------------

func _fire() -> void:
	shots_fired += 1
	var found := _find_target()
	_pending = found["body"]
	_fly_to = found["point"]
	_local = _pending.global_transform.affine_inverse() * _fly_to if _pending else Vector3.ZERO
	if _pending and _pending.is_in_group(GameState.GROUP_PLAYER):
		# Round the waist, wherever on the body the throw landed.
		_local = Vector3(0.0, 1.05, 0.0)
	_fly_from = _muzzle.global_position
	_tip = _fly_from
	_fly_time = clampf(_fly_from.distance_to(_fly_to) / FLY_SPEED, 0.06, 0.22)
	_fly_left = _fly_time
	_press_time = 0.0
	_press_is_shot = true
	mode = Mode.FLYING
	kick = 1.0
	audio.call(&"play", &"whip", _fly_from, 1.0)


## A ray down the crosshair, then a forgiving ball swept down the same line.
func _find_target() -> Dictionary:
	var space := (player as Node3D).get_world_3d().direct_space_state
	var from: Vector3 = player.get_aim_origin()
	var aim: Vector3 = player.get_aim_forward()
	var exclude: Array[RID] = [player.get_rid()]
	var reach := RANGE
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + aim * RANGE, SOLID_MASK, exclude))
	if not hit.is_empty():
		var struck: Vector3 = hit["position"]
		if _latchable(hit["collider"]):
			return {"body": hit["collider"], "point": struck}
		reach = from.distance_to(struck)
	var ball := SphereShape3D.new()
	ball.radius = CAST_RADIUS
	var sweep := PhysicsShapeQueryParameters3D.new()
	sweep.shape = ball
	sweep.collision_mask = TARGET_MASK
	sweep.exclude = exclude
	sweep.transform = Transform3D(Basis.IDENTITY, from + aim * 0.4)
	sweep.motion = aim * maxf(0.0, reach - 0.4)
	var fractions := space.cast_motion(sweep)
	if fractions.size() == 2 and fractions[1] < 1.0:
		sweep.transform.origin += sweep.motion * fractions[1]
		sweep.motion = Vector3.ZERO
		var rest := space.get_rest_info(sweep)
		if not rest.is_empty():
			var body := instance_from_id(int(rest["collider_id"]))
			if _latchable(body):
				return {"body": body, "point": rest["point"]}
	return {"body": null, "point": from + aim * reach}


func _latchable(body: Object) -> bool:
	if body is Node and (body as Node).is_in_group(GameState.GROUP_PLAYER):
		return body != player
	var rigid := body as RigidBody3D
	return rigid != null and not rigid.freeze and (rigid.has_meta(&"demon") or rigid.is_in_group(GameState.GROUP_GRABBABLE))


func _fly(delta: float) -> void:
	_fly_left -= delta
	var caught := is_instance_valid(_pending)
	if caught:
		# Lead the target: it kept moving while the rope was in the air.
		_fly_to = _pending.global_transform * _local
	_tip = _fly_from.lerp(_fly_to, clampf(1.0 - _fly_left / _fly_time, 0.0, 1.0))
	if _fly_left > 0.0:
		return
	if caught:
		_latch(_pending)
	else:
		mode = Mode.RETURNING
		_fly_left = RETURN_TIME
	_pending = null


func _latch(body: Node3D) -> void:
	if body.is_in_group(GameState.GROUP_PLAYER):
		_latch_player(body)
		return
	_target = body as RigidBody3D
	_target_demon = demon_of(body)
	var attach := body.global_transform * _local
	rest_length = clampf(_hold_point().distance_to(attach), MIN_LENGTH, RANGE)
	tension = 0.0
	mode = Mode.ATTACHED
	_make_collar()
	_hit_sparks.global_position = attach
	_hit_sparks.restart()
	audio.call(&"play", &"clink", attach, -4.0, 1.5)
	var label := str(body.get_meta(&"demon_label", body.get_meta(&"display_name", body.name)))
	if _target_demon:
		_target_demon.call(&"notify_rope", self, true, false)
		_target_demon.call(&"provoke", player)
		notify("LASSO ON THE DEMON (%s)" % label)
	else:
		notify("LASSO ON %s" % label.to_upper())


## A crewmate on the end of the rope: reel them in, walk them about, or pin them with RMB.
func _latch_player(body: Node3D) -> void:
	_target = null
	_target_demon = null
	_target_player = body
	var attach := _attach_point()
	rest_length = clampf(_hold_point().distance_to(attach), MIN_LENGTH, RANGE)
	tension = 0.0
	mode = Mode.ATTACHED
	_make_collar()
	_hit_sparks.global_position = attach
	_hit_sparks.restart()
	audio.call(&"play", &"clink", attach, -4.0, 1.5)
	var friend := str(body.get(&"display_name"))
	notify("LASSO ON %s  -  [LMB] reel in   [RMB] pin to a wall or post" % friend)
	GameState.post_notice_for(body, "%s HAS A ROPE ON YOU  -  mash [SPACE], or [R] after 2 s" % str(player.display_name))


## Where the rope bites, in world space.
func _attach_point() -> Vector3:
	if is_instance_valid(_target_player):
		return _target_player.global_transform * _local
	if is_instance_valid(_target):
		return _target.global_transform * _local
	return _tip


## The golden noose cinched round whatever was caught. It rides the body.
func _make_collar() -> void:
	var radius := clampf(Vector2(_local.x, _local.z).length() + 0.04, 0.1, 0.42)
	var at := Vector3(0.0, _local.y, 0.0)
	var wearer: Node3D = _target
	if is_instance_valid(_target_player):
		wearer = _target_player
		radius = 0.3
	if _target_demon:
		var part := int(_target.get_meta(&"demon_part", 0))
		var layout: Dictionary = _target_demon.call(&"get_layout")
		var girth := float((layout["radius"] as Array)[part])
		var length := float((layout["length"] as Array)[part])
		radius = girth * 1.32 + 0.014
		at = Vector3(0.0, clampf(_local.y, -length * 0.4, length * 0.4), 0.0)
		match part:
			0:
				radius = length * 0.5 + girth * 1.1
				at = Vector3.ZERO
			1:
				radius = girth * 1.5
			2:
				# Round the neck, not the skull.
				radius = girth * 0.85
				at = Vector3(0.0, -girth * 0.85, 0.0)
	_collar = MeshInstance3D.new()
	_collar.name = "LassoCollar"
	_collar.mesh = Parts.torus(radius, 0.0115)
	_collar.material_override = Parts.rope(3.4)
	_collar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_collar.position = at
	var halo := OmniLight3D.new()
	halo.light_color = Color(1.0, 0.72, 0.26)
	halo.light_energy = 0.9
	halo.omni_range = 2.4
	halo.shadow_enabled = false
	_collar.add_child(halo)
	wearer.add_child(_collar)


# --- Tension -----------------------------------------------------------------------

## Where the rope is held, for the physics: the holder's chest, or the anchor pin.
func _hold_point() -> Vector3:
	if mode == Mode.ANCHORED:
		return _anchor
	return (player as Node3D).global_position + Vector3.UP * 1.2


func _pull(delta: float) -> void:
	if _target_player:
		_pull_player(delta)
		return
	if not is_instance_valid(_target) or _target.is_queued_for_deletion() or _target.freeze:
		_detach("")
		return
	if mode == Mode.ATTACHED and (int(manager.get(&"slot")) != 1 or not player.can_act()):
		_detach("Lasso dropped")
		return
	var hold := _hold_point()
	var attach := _target.global_transform * _local
	var span := attach - hold
	var distance := span.length()
	if not is_finite(distance) or distance < 0.05:
		return
	var direction := span / distance
	var stretch := distance - rest_length
	tension = lerpf(tension, clampf(stretch, 0.0, 1.0), minf(1.0, delta * 10.0))
	if stretch > SNAP_STRETCH:
		_snap()
		return
	var awake: bool = _target_demon != null and not _target_demon.get(&"is_stunned")
	if stretch > 0.0:
		var lever := attach - _target.global_position
		var state := PhysicsServer3D.body_get_direct_state(_target.get_rid())
		var point_velocity := state.get_velocity_at_local_position(lever) if state else _target.linear_velocity
		var holder_velocity := Vector3.ZERO
		if mode == Mode.ATTACHED:
			holder_velocity = player.get_real_velocity()
		# The stretch asks for a closing speed; the shortfall becomes a capped pull. Never a push.
		var closing := (holder_velocity - point_velocity).dot(direction)
		var want := minf(stretch * STIFFNESS, MAX_CLOSE_SPEED)
		var mass := _target.mass
		var cap := PROP_FORCE
		if _target_demon:
			# The rope has done its work once the body follows, not just the roped limb.
			var chest: RigidBody3D = _target_demon.call(&"get_body", 1)
			closing = minf(closing, (holder_velocity - chest.linear_velocity).dot(direction))
			if awake:
				mass = float(_target_demon.call(&"get_total_mass")) * 0.5
				cap = ANCHOR_FORCE if mode == Mode.ANCHORED else AWAKE_FORCE
			else:
				# Limp, the whole parcel comes along; how briskly depends on how well it is taped.
				var tuning: Dictionary = _target_demon.call(&"get_grab_tuning", _target)
				mass = float(_target_demon.call(&"get_total_mass")) * 0.6
				cap = float(tuning["force"])
				want = minf(want, LIMP_CLOSE_SPEED)
		var force := -direction * clampf((want - closing) * RESPONSE * mass, 0.0, cap)
		if _target_demon:
			# A limb takes what a limb can take; the rest of the load goes into the core,
			# so a hard pull turns and drags the body instead of stretching its joints.
			var limb := force.limit_length(_target.mass * 70.0)
			_target.apply_force(limb, lever)
			var core := (force - limb) * 0.5
			(_target_demon.call(&"get_body", 0) as RigidBody3D).apply_central_force(core)
			(_target_demon.call(&"get_body", 1) as RigidBody3D).apply_central_force(core)
		else:
			_target.apply_force(force, lever)
		if mode == Mode.ATTACHED:
			if awake:
				# Tug of war: it hauls the holder in and wears them out.
				player.apply_drag(direction * COUNTER_PULL * tension)
				player.drain_stamina(STAMINA_DRAIN * delta)
				if float(player.get(&"stamina")) <= 0.0:
					_detach("The demon tore the lasso out of your hands!")
					return
			elif _target_demon and int(_target_demon.call(&"get_hauler_count")) >= 2:
				# More than one of the crew on it: the load is shared and the rope stays quiet.
				tension *= 0.85
			elif _target_demon == null:
				player.apply_drag(direction * clampf(_target.mass / 60.0, 0.0, 1.0) * 1.2 * tension)
	if mode == Mode.ANCHORED:
		_strain(delta, awake, hold, attach)
	else:
		audio.call(&"set_loop", &"creak", tension > 0.55, hold, -8.0, 0.9 + tension * 0.3)


## A crewmate on the rope. They are leashed to the holder's chest (or the pin): free to
## move inside the rope's length, hauled back in beyond it. Their weight tugs at the
## holder too, so two friends on one rope really are tied together.
func _pull_player(delta: float) -> void:
	if not is_instance_valid(_target_player) or _target_player.is_queued_for_deletion():
		_detach("")
		return
	if mode == Mode.ATTACHED and (int(manager.get(&"slot")) != 1 or not player.can_act()):
		_detach("Lasso dropped")
		return
	var hold := _hold_point()
	var attach := _attach_point()
	var span := attach - hold
	var distance := span.length()
	if not is_finite(distance):
		return
	var stretch := distance - rest_length
	tension = lerpf(tension, clampf(stretch, 0.0, 1.0), minf(1.0, delta * 10.0))
	if stretch > SNAP_STRETCH:
		_snap()
		return
	_target_player.call(&"set_leash", hold, rest_length, int(player.seat), mode == Mode.ANCHORED)
	if mode == Mode.ATTACHED:
		if stretch > 0.0 and distance > 0.05:
			player.apply_drag(span / distance * minf(stretch * 2.2, 2.2))
		audio.call(&"set_loop", &"creak", tension > 0.55, hold, -8.0, 0.9 + tension * 0.3)
		return
	# Pinned: the rope frays twice as slowly as it does under a demon, but it does fray.
	_anchor_life -= delta * 0.5
	var failing := _anchor_life < 2.5
	_strain_sparks.global_position = hold
	_strain_sparks.emitting = failing
	audio.call(&"set_loop", &"creak", failing or tension > 0.55, hold, -6.0, 1.1)
	if _anchor_life <= 0.0:
		_snap()


## An anchored rope wears out: fast under a conscious demon, hardly at all under a limp one.
func _strain(delta: float, awake: bool, hold: Vector3, attach: Vector3) -> void:
	if _target_demon:
		var wear := 1.0 if awake else 0.1 / (1.0 + float(_target_demon.get(&"bind_level")))
		_anchor_life -= delta * wear
	if awake:
		_thrash_left -= delta
		if _thrash_left <= 0.0:
			_thrash_left = randf_range(0.45, 0.9)
			var away := ((attach - hold) * Vector3(1.0, 0.0, 1.0)).normalized().rotated(Vector3.UP, randf_range(-1.2, 1.2))
			_target_demon.call(&"nudge", away * randf_range(1.4, 2.4) + Vector3.UP * 0.5)
	var failing := awake and _anchor_life < 2.5
	_strain_sparks.global_position = hold
	_strain_sparks.emitting = failing
	audio.call(&"set_loop", &"creak", failing or tension > 0.55, hold, -3.0 if failing else -8.0, 1.25 if failing else 0.95)
	if _anchor_life <= 0.0:
		_snap()


func _try_anchor() -> void:
	var from: Vector3 = player.get_aim_origin()
	var aim: Vector3 = player.get_aim_forward()
	var query := PhysicsRayQueryParameters3D.create(from, from + aim * ANCHOR_RANGE, GameState.LAYER_WORLD, [player.get_rid()])
	var hit := (player as Node3D).get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not (hit["collider"] is StaticBody3D):
		notify("Aim at a wall, post or floor within 3.5 m to anchor")
		audio.call(&"play", &"dry", from)
		return
	var surface: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	_pin.global_transform = Transform3D(Basis(Quaternion(Vector3.UP, normal)), surface)
	_pin.visible = true
	_anchor = surface + normal * 0.15
	mode = Mode.ANCHORED
	var attach := _attach_point()
	rest_length = clampf(_anchor.distance_to(attach) * 0.95, MIN_LENGTH * 0.6, RANGE)
	_anchor_life = randf_range(8.0, 12.0)
	if _target_demon:
		_target_demon.call(&"notify_rope", self, true, true)
	_thrash_left = 0.4
	kick = 0.7
	player.shake(0.2)
	_hit_sparks.global_position = surface
	_hit_sparks.restart()
	audio.call(&"play", &"clink", surface, 2.0)
	if is_instance_valid(_target_player):
		notify("%s IS PINNED  -  [R] lets them go" % str(_target_player.get(&"display_name")))
		GameState.post_notice_for(_target_player, "PINNED BY %s  -  mash [SPACE], or [R] after 2 s" % str(player.display_name))
	else:
		notify("ROPE ANCHORED  -  hands free" if _target_demon else "ROPE ANCHORED")


func _snap() -> void:
	snaps += 1
	var at := _hold_point()
	_hit_sparks.global_position = at
	_hit_sparks.restart()
	audio.call(&"play", &"snap", at, 3.0)
	_detach("THE ROPE SNAPPED!")


## Lets go and whips the rope back to the hand.
func _detach(message: String) -> void:
	if not message.is_empty():
		notify(message)
	if is_tethered():
		_tip = _attach_point()
	mode = Mode.RETURNING
	_fly_left = RETURN_TIME
	_release()


func _release() -> void:
	if is_instance_valid(_collar):
		_collar.queue_free()
	if _target_demon and is_instance_valid(_target_demon):
		_target_demon.call(&"notify_rope", self, false, false)
	_collar = null
	_target = null
	_target_demon = null
	_target_player = null
	_pending = null
	_pin.visible = false
	_strain_sparks.emitting = false
	tension = 0.0
	if audio:
		audio.call(&"set_loop", &"creak", false)


# --- Drawing -----------------------------------------------------------------------

func _process(delta: float) -> void:
	if is_puppet():
		_time += delta
		audio.call(&"set_loop", &"creak", is_tethered() and tension > 0.55, _hold_point(), -8.0, 0.9 + tension * 0.3)
	var out := mode != Mode.IDLE
	_rope.visible = out
	_noose.visible = not out
	if not out:
		return
	var start: Vector3 = _muzzle.global_position if view.visible else manager.call(&"get_hand_position")
	var end := _tip
	var slack := 0.0
	match mode:
		Mode.ANCHORED:
			start = _anchor
		Mode.RETURNING:
			end = _tip.lerp(start, clampf(1.0 - _fly_left / RETURN_TIME, 0.0, 1.0))
	if is_tethered() and (is_instance_valid(_target) or is_instance_valid(_target_player)):
		end = _attach_point()
		slack = maxf(0.0, rest_length - start.distance_to(end))
	# Slack hangs under the chord; a loaded rope is a straight line.
	var span := end - start
	var sag := minf(slack * 0.55 + span.length() * 0.012, 1.4) * (1.0 - tension)
	var control := start + span * 0.5 + Vector3.DOWN * sag
	var points := PackedVector3Array()
	for i in ROPE_SEGMENTS + 1:
		var t := float(i) / ROPE_SEGMENTS
		points.append(start.lerp(control, t).lerp(control.lerp(end, t), t))
	_draw_rope(points)
	# Warm gold breathing with holy energy; white-hot under load, red when about to fail.
	var failing := mode == Mode.ANCHORED and _anchor_life < 2.5 and _strain_sparks.emitting
	_rope_material.emission = Color(1.0, 0.3, 0.1) if failing and fmod(_time, 0.2) < 0.1 else Color(1.0, 0.7, 0.2).lerp(Color(1.0, 0.92, 0.7), tension)
	_rope_material.emission_energy_multiplier = 2.2 + 0.5 * sin(_time * 6.0) + tension * 2.0
	if is_instance_valid(_collar):
		(_collar.material_override as StandardMaterial3D).emission_energy_multiplier = 3.0 + 0.8 * sin(_time * 7.0) + tension * 2.0


func _draw_rope(points: PackedVector3Array) -> void:
	_rope_mesh.clear_surfaces()
	var last := points.size() - 1
	if last < 1 or points[0].distance_squared_to(points[last]) < 0.0004:
		return
	var lengths := PackedFloat32Array([0.0])
	for i in range(1, points.size()):
		lengths.append(lengths[i - 1] + points[i].distance_to(points[i - 1]))
	var rings: Array[PackedVector3Array] = []
	var outs: Array[PackedVector3Array] = []
	var normal := Vector3.UP
	for i in points.size():
		var tangent := points[mini(i + 1, last)] - points[maxi(i - 1, 0)]
		tangent = tangent.normalized() if tangent.length_squared() > 1e-10 else Vector3.FORWARD
		normal -= tangent * normal.dot(tangent)
		if normal.length_squared() < 1e-6:
			normal = tangent.cross(Vector3.RIGHT if absf(tangent.x) < 0.9 else Vector3.BACK)
		normal = normal.normalized()
		var binormal := tangent.cross(normal)
		var ring := PackedVector3Array()
		var ring_out := PackedVector3Array()
		for s in ROPE_SIDES:
			var angle := TAU * float(s) / ROPE_SIDES
			var out := normal * cos(angle) + binormal * sin(angle)
			ring.append(points[i] + out * ROPE_RADIUS)
			ring_out.append(out)
		rings.append(ring)
		outs.append(ring_out)
	_rope.global_transform = Transform3D.IDENTITY
	_rope_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in last:
		for s in ROPE_SIDES:
			var t := (s + 1) % ROPE_SIDES
			# Ring, side, and the side's place round the rope (the seam must not wrap back to 0).
			for corner: Vector3i in [Vector3i(i, s, s), Vector3i(i + 1, s, s), Vector3i(i + 1, t, s + 1), Vector3i(i, s, s), Vector3i(i + 1, t, s + 1), Vector3i(i, t, s + 1)]:
				_rope_mesh.surface_set_normal(outs[corner.x][corner.y])
				_rope_mesh.surface_set_uv(Vector2(lengths[corner.x] / ROPE_LAY, float(corner.z) / ROPE_SIDES))
				_rope_mesh.surface_add_vertex(rings[corner.x][corner.y])
	_rope_mesh.surface_end()


# --- Replication -------------------------------------------------------------------------

func write_net(floats: PackedFloat32Array, ints: PackedInt32Array) -> void:
	# The far end of the rope while it is in the air, the pin while it is tied off.
	var point := _tip
	match mode:
		Mode.ANCHORED:
			point = _anchor
		Mode.RETURNING:
			point = _tip.lerp(_hold_point(), clampf(1.0 - _fly_left / RETURN_TIME, 0.0, 1.0))
	var normal := _pin.global_transform.basis.y
	floats.append_array(PackedFloat32Array([_local.x, _local.y, _local.z, point.x, point.y, point.z,
			normal.x, normal.y, normal.z, tension, rest_length]))
	var caught: Node3D = get_target_player() if _target_player else get_target()
	var failing := mode == Mode.ANCHORED and _anchor_life < 2.5 and _strain_sparks.emitting
	ints.append_array(PackedInt32Array([mode, GameState.body_ref(caught), 1 if failing else 0]))


func read_net(floats: PackedFloat32Array, f: int, ints: PackedInt32Array, i: int) -> void:
	var next := clampi(ints[i], 0, Mode.size() - 1) as Mode
	var ref := ints[i + 1]
	var point := Vector3(floats[f + 3], floats[f + 4], floats[f + 5])
	var normal := Vector3(floats[f + 6], floats[f + 7], floats[f + 8])
	_local = Vector3(floats[f], floats[f + 1], floats[f + 2])
	tension = floats[f + 9]
	rest_length = floats[f + 10]
	var tied := next == Mode.ATTACHED or next == Mode.ANCHORED
	if ref != _net_ref or tied != is_tethered():
		# Caught something new, or let go: move the collar.
		if is_instance_valid(_collar):
			_collar.queue_free()
		_collar = null
		_target = null
		_target_demon = null
		_target_player = null
		_net_ref = ref
		var caught := GameState.ref_body(ref) if tied else null
		if caught:
			if caught.is_in_group(GameState.GROUP_PLAYER):
				_target_player = caught
			else:
				_target = caught as RigidBody3D
				_target_demon = demon_of(caught)
			mode = next
			_make_collar()
			_hit_sparks.global_position = _attach_point()
			_hit_sparks.restart()
	mode = next
	match mode:
		Mode.FLYING, Mode.RETURNING:
			_tip = point
			_fly_left = RETURN_TIME
		Mode.ANCHORED:
			_anchor = point
			if normal.is_finite() and normal.length_squared() > 0.25:
				normal = normal.normalized()
				_pin.global_transform = Transform3D(Basis(Quaternion(Vector3.UP, normal)), point - normal * 0.15)
	_pin.visible = mode == Mode.ANCHORED
	var failing := ints[i + 2] != 0
	_anchor_life = 1.0 if failing else 10.0
	_strain_sparks.global_position = _anchor
	_strain_sparks.emitting = failing and mode == Mode.ANCHORED
