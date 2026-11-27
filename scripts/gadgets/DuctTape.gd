extends "res://scripts/gadgets/Gadget.gd"
## Slot 3: the Giant Industrial Duct Tape Roll.
##
## Held in both gloves like a steering wheel. Holding LMB within 2.6 m of a demon
## that is stunned (or tied to an anchor by the lasso) winds a wrap round it:
## 1.8 s per level, cleanly cancelled if it wakes, moves out of reach or the
## trigger is let go. Each finished wrap raises the demon's bind level (which
## puts real tape bands on its skeleton, see DemonVisuals) and tops its stun up
## by 20 so there is time for the next one.

const RANGE := 2.6
const WRAP_TIME := 1.8
const STUN_BONUS := 20.0
const MAX_LEVEL := 3
const RADIUS := 0.152
const STRIP_STEPS := 8

## 0..1 of the wrap in progress.
var progress := 0.0
var wrapping := false
var wraps_done := 0

var _wrapped := false
var _demon: Node3D
var _stick := Vector3.ZERO
var _orbit := 0.0
var _orbit_amount := 0.0
var _roll: Node3D
var _strip: MeshInstance3D
var _strip_mesh: ImmediateMesh
var _glints: GPUParticles3D


func _build(root: Node3D) -> void:
	title = "DUCT TAPE"
	view_offset = Vector3(0.0, -0.235, -0.5)
	view_tilt = Vector3(-0.62, 0.0, 0.0)
	body_offset = Vector3(0.0, 1.12, -0.46)
	palm_right = Vector3(RADIUS + 0.004, 0.0, 0.0)
	palm_left = Vector3(-RADIUS - 0.004, 0.0, 0.0)
	two_handed = true
	grip = 0.75
	var silver := Parts.tape()
	var card := Parts.cardboard()
	var half := 0.052

	# The roll spins about its own axis, which points back at the holder.
	_roll = Node3D.new()
	_roll.name = "Roll"
	root.add_child(_roll)
	var wheel := Node3D.new()
	wheel.rotation.x = PI * 0.5
	_roll.add_child(wheel)
	# Wound tape: bevelled outer face, slightly dished sides showing the layers.
	Parts.part(wheel, Parts.lathe(PackedVector2Array([Vector2(0.09, -half + 0.002), Vector2(RADIUS - 0.006, -half), Vector2(RADIUS, -half + 0.005),
			Vector2(RADIUS, half - 0.005), Vector2(RADIUS - 0.006, half), Vector2(0.09, half - 0.002)]), 48), silver)
	for ring: float in [0.105, 0.122, 0.138]:
		for face: float in [-1.0, 1.0]:
			Parts.part(wheel, Parts.torus(ring, 0.0011), Parts.metal(Color(0.3, 0.31, 0.33), 0.6, 0.6, 0.0), Vector3(0.0, face * (half - 0.0005), 0.0))
	# Cardboard core, standing proud of the tape, with a printed seal band inside.
	Parts.part(wheel, Parts.lathe(PackedVector2Array([Vector2(0.09, -half - 0.004), Vector2(0.092, -half - 0.006), Vector2(0.092, half + 0.006),
			Vector2(0.09, half + 0.004), Vector2(0.079, half + 0.006), Vector2(0.077, half + 0.004), Vector2(0.077, -half - 0.004), Vector2(0.079, -half - 0.006),
			Vector2(0.09, -half - 0.004)]), 40), card)
	# The loose end: one last turn lifting off the roll, and a flap peeling away from it.
	var tail := Parts.part(wheel, Parts.band(RADIUS + 0.0025, RADIUS + 0.0025, half * 1.9, 1.5, 2.0, 16), silver)
	tail.rotation.y = -0.5
	var flap := Node3D.new()
	flap.position = Vector3(cos(1.25), 0.0, sin(1.25)) * (RADIUS + 0.004)
	flap.rotation.y = -1.25 - PI * 0.5 + 0.35
	wheel.add_child(flap)
	var flap_mesh := QuadMesh.new()
	flap_mesh.size = Vector2(0.075, half * 1.9)
	Parts.part(flap, flap_mesh, silver, Vector3(0.0375, 0.0, 0.0))

	_strip_mesh = ImmediateMesh.new()
	_strip = MeshInstance3D.new()
	_strip.name = "TapeStrip"
	_strip.mesh = _strip_mesh
	_strip.material_override = silver
	_strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_strip.top_level = true
	_strip.visible = false
	add_child(_strip)
	_glints = Parts.particles(Color(0.92, 0.96, 1.0), 26, 0.45, Vector2(0.3, 1.4), Vector2(0.008, 0.02), Vector3(0.0, -1.5, 0.0), 180.0, false)
	_glints.top_level = true
	add_child(_glints)


func get_hint() -> String:
	return "[LMB] Hold to wrap a stunned demon (2.6 m)   3 wraps = gift-wrapped   [E] Hand grab"


func get_progress() -> float:
	return progress if wrapping else 0.0


func get_progress_label() -> String:
	if not wrapping or not is_instance_valid(_demon) or int(_demon.get(&"bind_level")) >= MAX_LEVEL:
		return ""
	return "BINDING DEMON... %d/%d" % [int(_demon.get(&"bind_level")) + 1, MAX_LEVEL]


func reset() -> void:
	super.reset()
	progress = 0.0
	wrapping = false
	_wrapped = false
	_demon = null


# --- Wrapping ----------------------------------------------------------------------

func use(delta: float, input: Dictionary) -> void:
	if not input["fire"]:
		return
	var check := _candidate()
	if not check["ok"]:
		if input["fire_pressed"]:
			GameState.post_notice(str(check["reason"]))
			audio.call(&"play", &"dry", view.global_position)
		return
	_wrapped = true
	_demon = check["demon"]
	_stick = check["point"]
	progress += delta / WRAP_TIME
	if progress >= 1.0:
		_complete()


func simulate(_delta: float) -> void:
	wrapping = _wrapped
	_wrapped = false
	audio.call(&"set_loop", &"rip", wrapping, view.global_position, -3.0, 1.0 + progress * 0.25)
	if not wrapping:
		# Letting go, losing reach or a waking demon all throw the half-made wrap away.
		progress = 0.0


## Whether there is a demon here that can be taped right now, and if not, why not.
func _candidate() -> Dictionary:
	var demon := find_demon()
	if demon == null:
		return {"ok": false, "reason": "No demon to tape"}
	var eye: Vector3 = player.get_aim_origin()
	var aim: Vector3 = player.get_aim_forward()
	var nearest := INF
	var point := Vector3.ZERO
	for body: RigidBody3D in demon.call(&"get_bodies"):
		var to := body.global_position - eye
		var distance := to.length()
		if distance < nearest and (distance < 0.6 or aim.dot(to / distance) > 0.25):
			nearest = distance
			point = body.global_position
	if nearest > RANGE:
		return {"ok": false, "reason": "Get within %.1f m of the demon to tape it" % RANGE}
	if int(demon.get(&"bind_level")) >= MAX_LEVEL:
		return {"ok": false, "reason": "Fully bound  -  haul it to the van"}
	if not demon.get(&"is_stunned") and not manager.call(&"is_demon_anchored", demon):
		return {"ok": false, "reason": "Stun it [2] or anchor it with the lasso [1] first"}
	return {"ok": true, "demon": demon, "point": point}


func _complete() -> void:
	var level := int(_demon.get(&"bind_level")) + 1
	_demon.call(&"set_bind_level", level)
	_demon.call(&"add_stun", STUN_BONUS)
	wraps_done += 1
	progress = 0.0
	kick = 1.0
	_glints.global_position = _stick
	_glints.restart()
	audio.call(&"play", &"tape_done", _stick, 3.0)
	GameState.post_notice("BIND %d/%d%s" % [level, MAX_LEVEL, "  -  GIFT-WRAPPED!" if level >= MAX_LEVEL else "  -  keep wrapping"])


# --- Animation ---------------------------------------------------------------------

func animate(delta: float) -> void:
	_orbit_amount = move_toward(_orbit_amount, 1.0 if wrapping else 0.0, delta * 7.0)
	_orbit += delta * 12.0 * _orbit_amount
	_roll.rotation.z += delta * (0.4 + 17.0 * _orbit_amount)


## While wrapping, the roll (and the gloves on it) circle out in front as the tape pays off.
func get_view_shift() -> Transform3D:
	var swing := Vector3(cos(_orbit) * 0.075, sin(_orbit) * 0.055, -0.07 - 0.03 * sin(_orbit * 2.0)) * _orbit_amount
	return Transform3D(Basis(Vector3.BACK, sin(_orbit) * 0.22 * _orbit_amount), swing)


func _process(_delta: float) -> void:
	var paying := wrapping and view.visible and is_instance_valid(_demon)
	_strip.visible = paying
	_glints.emitting = paying
	if not paying:
		return
	# A ribbon of tape from the roll to the demon, fluttering as it is pulled off.
	var from := _roll.global_transform * Vector3(0.0, RADIUS, 0.0)
	var span := _stick - from
	var across := span.cross(Vector3.UP)
	across = across.normalized() * 0.05 if across.length_squared() > 1e-8 else Vector3.RIGHT * 0.05
	var normal := across.cross(span).normalized()
	_glints.global_position = _stick
	_strip.global_transform = Transform3D.IDENTITY
	_strip_mesh.clear_surfaces()
	_strip_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in STRIP_STEPS + 1:
		var t := float(i) / STRIP_STEPS
		var centre := from + span * t + Vector3.DOWN * sin(t * PI) * 0.06 + normal * sin(t * 9.0 + _orbit * 3.0) * 0.012
		for edge: float in [-1.0, 1.0]:
			_strip_mesh.surface_set_normal(normal)
			_strip_mesh.surface_set_uv(Vector2(t * 3.0, edge * 0.5 + 0.5))
			_strip_mesh.surface_add_vertex(centre + across * edge)
	_strip_mesh.surface_end()
