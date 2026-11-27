extends Node3D
## The Bind & Deliver extraction van.
##
## The cab, bonnet, mirrors and wheels come from a CC0 box-truck model; its toy
## cargo box is cut away and replaced with a walk-in containment bay built to
## gameplay dimensions: tread-plate floor, lined walls with cage bars, wheel
## arches, a caged work light, a loading ramp and two physically hinged rear
## doors (interact with F). A rotating amber lightbar sits on the cab roof.
##
## Local frame: nose toward +Z, rear doors at -Z, wheels on y = 0.

signal cargo_loaded(body: RigidBody3D)
## The doors have been bolted on a captured demon.
signal sealed_shut
## Something inside hit the bodywork; `strength` is 0..1.
signal banged(strength: float)

const Mats := preload("res://scripts/MaterialLibrary.gd")
const Parts := preload("res://scripts/gadgets/GadgetParts.gd")
const HingedDoor := preload("res://scripts/HingedDoor.gd")
const FlickerLight := preload("res://scripts/FlickerLight.gd")
const CAB_SHADER := preload("res://shaders/van_cab.gdshader")

const TRUCK_MODEL := "vehicles/van_truck"
## Overall length the truck model is scaled to; the numbers below are measured at this size.
const MODEL_LENGTH := 5.4
const HALF_WIDTH := 1.31
const WALL := 0.07
const UNDERSIDE := 0.44
const FLOOR_TOP := 0.7
const ROOF_TOP := 2.82
const REAR_Z := -2.6
const PARTITION_Z := 0.85
const CAB_HALF_WIDTH := 1.2
const CAB_ROOF := 2.28
const HOOD_TOP := 1.45
const HOOD_Z := 2.0
const NOSE_Z := 2.7
const AXLE_Z := -1.77
const WHEEL_TOP := 0.9
const WHEEL_INNER_X := 0.95
const ARCH_HALF_LENGTH := 0.58
const RAMP_LENGTH := 2.4
const RAMP_HALF_WIDTH := 1.0
const DOOR_OPEN_DEGREES := 112.0
const BEACON_SPIN := 5.2
const PAINT_TINT := Color(0.80, 0.80, 0.76)
const LIVERY := Color(0.86, 0.34, 0.07)
## Seconds the van rocks on its springs after the doors are sealed on a demon.
const ROCK_TIME := 2.5
const SEAL_COLOR := Color(1.0, 0.72, 0.26)
## Emission of the seal at rest and the most the flash adds when it lands. Both sit near
## the bloom threshold on purpose: the rune must read as hot metal, not as a white disc.
const SEAL_GLOW := 1.15
const SEAL_FLASH := 1.5

var left_door: HingedDoor
var right_door: HingedDoor
var cargo_zone: Area3D
var is_sealed := false
var bangs := 0

var _rest := Transform3D.IDENTITY
var _rock_left := 0.0
var _bang_left := 0.0
## Roll and pitch of the body on its suspension (radians), and its ride height (metres).
var _lean := Vector2.ZERO
var _lean_velocity := Vector2.ZERO
var _bounce := 0.0
var _bounce_velocity := 0.0
var _seal: MeshInstance3D
var _seal_material: StandardMaterial3D
var _seal_light: OmniLight3D
var _seal_flash := 0.0
var _dust: Array[GPUParticles3D] = []

var _body: StaticBody3D
var _beacon_pivot: Node3D
var _beacon_glow: OmniLight3D
var _beacon_material: StandardMaterial3D
var _time := 0.0


func _ready() -> void:
	_body = StaticBody3D.new()
	_body.name = "Body"
	_body.collision_layer = GameState.LAYER_WORLD
	_body.collision_mask = 0
	add_child(_body)
	_build_cab()
	_build_cargo_body()
	_build_interior()
	_build_ramp()
	_build_rear_frame()
	_build_lights()
	_build_lightbar()
	_build_branding()
	_build_doors()
	_build_cargo_zone()
	_build_seal()


func _process(delta: float) -> void:
	_time += delta
	_beacon_pivot.rotate_y(delta * BEACON_SPIN)
	# The domes breathe as the reflectors sweep past.
	var pulse := 0.65 + 0.35 * sin(_time * BEACON_SPIN * 2.0)
	_beacon_material.emission_energy_multiplier = 1.2 + 2.2 * pulse
	_beacon_glow.light_energy = 0.5 + 0.7 * pulse
	_update_seal(delta)


## True when both rear doors are (being driven) open.
func are_doors_open() -> bool:
	return left_door.is_open and right_door.is_open


## True once both rear doors have physically swung home.
func are_doors_shut() -> bool:
	return not left_door.is_open and not right_door.is_open and absf(left_door.get_angle()) < 0.1 and absf(right_door.get_angle()) < 0.1


## Bolts the doors on a captured demon: a containment seal flares across them and the
## whole van rocks on its springs for `ROCK_TIME` while the cargo objects.
func seal() -> void:
	if is_sealed:
		return
	is_sealed = true
	left_door.lock()
	right_door.lock()
	_rest = transform
	_rock_left = ROCK_TIME
	_bang_left = 0.3
	_seal.visible = true
	_seal_light.visible = true
	_seal_flash = 1.0
	sealed_shut.emit()


## Breaks the seal and shuts the doors, ready for the next contract.
func release() -> void:
	if is_sealed:
		transform = _rest
	is_sealed = false
	_rock_left = 0.0
	_lean = Vector2.ZERO
	_lean_velocity = Vector2.ZERO
	_bounce = 0.0
	_bounce_velocity = 0.0
	_seal.visible = false
	_seal_light.visible = false
	left_door.unlock()
	right_door.unlock()
	left_door.set_open(false)


func is_rocking() -> bool:
	return _rock_left > 0.0


func _update_seal(delta: float) -> void:
	if not _seal.visible:
		return
	_seal_flash = maxf(0.0, _seal_flash - delta * 1.3)
	# Molten gold in the grooves: a slow breathing glow, a short flare when the seal lands.
	_seal_material.emission_energy_multiplier = SEAL_GLOW + 0.2 * sin(_time * 2.4) + _seal_flash * SEAL_FLASH
	_seal_light.light_energy = 0.22 + _seal_flash * 1.1
	if _rock_left <= 0.0:
		return
	_rock_left -= delta
	_bang_left -= delta
	if _bang_left <= 0.0 and _rock_left > 0.25:
		# The demon throws itself at a wall: the body kicks over and the springs take it up.
		_bang_left = randf_range(0.26, 0.5)
		var strength := randf_range(0.55, 1.0)
		_lean_velocity += Vector2((-1.0 if randf() < 0.5 else 1.0) * 0.85, randf_range(-0.22, 0.22)) * strength
		_bounce_velocity += 0.5 * strength
		for puff in _dust:
			puff.restart()
		bangs += 1
		banged.emit(strength)
	_lean_velocity += (-_lean * 115.0 - _lean_velocity * 8.0) * delta
	_lean += _lean_velocity * delta
	_bounce_velocity += (-_bounce * 170.0 - _bounce_velocity * 10.0) * delta
	_bounce += _bounce_velocity * delta
	if _rock_left <= 0.0:
		transform = _rest
	else:
		transform = _rest * Transform3D(Basis(Vector3.BACK, _lean.x) * Basis(Vector3.RIGHT, _lean.y), Vector3(0.0, maxf(_bounce, -0.02), 0.0))


func _build_seal() -> void:
	# Etched into the paint rather than projected onto it: an alpha-blended, lit decal whose
	# grooves glow from inside, so the rusted doors still show between the lines.
	var etching := _etched_sigil()
	_seal_material = StandardMaterial3D.new()
	_seal_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_seal_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_seal_material.albedo_color = Color(0.34, 0.2, 0.06)
	_seal_material.albedo_texture = etching
	_seal_material.roughness = 0.45
	_seal_material.metallic = 0.6
	_seal_material.emission_enabled = true
	_seal_material.emission = Color(1.0, 0.6, 0.14)
	_seal_material.emission_texture = etching
	_seal_material.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	_seal_material.emission_energy_multiplier = SEAL_GLOW
	var plate := QuadMesh.new()
	plate.size = Vector2(1.95, 1.95)
	_seal = MeshInstance3D.new()
	_seal.name = "ContainmentSeal"
	_seal.mesh = plate
	_seal.material_override = _seal_material
	_seal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_seal.position = Vector3(0.0, (ROOF_TOP + FLOOR_TOP) * 0.5, REAR_Z - 0.16)
	_seal.rotation.y = PI
	_seal.visible = false
	add_child(_seal)
	_seal_light = OmniLight3D.new()
	_seal_light.name = "SealGlow"
	_seal_light.light_color = SEAL_COLOR
	_seal_light.omni_range = 4.0
	_seal_light.shadow_enabled = false
	_seal_light.position = Vector3(0.0, 1.7, REAR_Z - 0.8)
	_seal_light.visible = false
	add_child(_seal_light)
	# Dust shaken off the chassis at each wheel when the van rocks.
	for corner: Vector3 in [Vector3(-1.2, 0.12, AXLE_Z), Vector3(1.2, 0.12, AXLE_Z), Vector3(-1.2, 0.12, 1.75), Vector3(1.2, 0.12, 1.75)]:
		var puff := Parts.particles(Color(0.42, 0.38, 0.33, 0.55), 14, 1.0, Vector2(0.3, 1.3), Vector2(0.08, 0.24), Vector3(0.0, 0.25, 0.0), 75.0, true, false)
		puff.position = corner
		add_child(puff)
		_dust.append(puff)


## The containment sigil as gritty etched lines: its strokes become alpha, broken up by a
## scratch noise so the rune looks cut into old paint. Built once and shared.
static var _etching: ImageTexture

func _etched_sigil() -> ImageTexture:
	if _etching:
		return _etching
	var source := Parts.sigil(512).get_image()
	source.clear_mipmaps()
	var size := source.get_size()
	var grit := FastNoiseLite.new()
	grit.noise_type = FastNoiseLite.TYPE_SIMPLEX
	grit.frequency = 0.11
	grit.seed = 4130
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 1.0, 1.0, 0.0))
	for y in size.y:
		for x in size.x:
			if source.get_pixel(x, y).r > 0.5:
				var wear := clampf(0.72 + 0.6 * grit.get_noise_2d(x, y) + 0.25 * grit.get_noise_2d(x * 4.0, y * 4.0), 0.18, 1.0)
				image.set_pixel(x, y, Color(wear, wear, wear, wear))
	image.generate_mipmaps()
	_etching = ImageTexture.create_from_image(image)
	return _etching


# --- Cab (from the truck model) -------------------------------------------------

func _build_cab() -> void:
	# Cut the model's own cargo box away, keeping cab, bonnet and wheels.
	var keep_from := (PARTITION_Z + 0.03 + MODEL_LENGTH * 0.5) / MODEL_LENGTH
	var truck := ModelLoader.instance(TRUCK_MODEL, {
		"fit_depth": MODEL_LENGTH,
		"clip": AABB(Vector3(-0.1, -0.1, -0.1), Vector3(1.2, 1.2, 0.1 + keep_from)),
		"clip_remove": true,
		"clip_part": "Truck",
		"tint": Color(0.62, 0.62, 0.62),
		"grunge": 0.5,
		"fallback_size": Vector3(CAB_HALF_WIDTH * 2.0, CAB_ROOF, MODEL_LENGTH),
	})
	truck.name = "TruckModel"
	add_child(truck)
	if not ModelLoader.is_fallback(truck):
		_repaint_cab(truck)

	# The model is a shell: these blocks are what players and props actually hit.
	_collider_span(-CAB_HALF_WIDTH, CAB_HALF_WIDTH, 0.0, CAB_ROOF, PARTITION_Z, HOOD_Z)
	_collider_span(-CAB_HALF_WIDTH, CAB_HALF_WIDTH, 0.0, HOOD_TOP, HOOD_Z, NOSE_Z)
	# Chassis block under the bay: keeps loose props from vanishing under the van.
	_collider_span(-HALF_WIDTH + 0.05, HALF_WIDTH - 0.05, 0.0, UNDERSIDE, REAR_Z + 0.04, PARTITION_Z)


## Swaps the cab's palette paint for the weathered body paint and lights the headlamp lenses.
func _repaint_cab(truck: Node3D) -> void:
	var paint := Mats.van_paint()
	for node in truck.find_children("*", "MeshInstance3D", true, false):
		var instance := node as MeshInstance3D
		if String(instance.name) != "Truck":
			continue
		for surface in instance.mesh.get_surface_count():
			var source := instance.mesh.surface_get_material(surface) as BaseMaterial3D
			if source == null:
				continue
			if source.resource_name == "Headlights":
				instance.set_surface_override_material(surface, Mats.glow(Color(1.0, 0.94, 0.78), 5.0))
			elif source.albedo_texture != null and paint.albedo_texture != null:
				var cab := ShaderMaterial.new()
				cab.shader = CAB_SHADER
				cab.set_shader_parameter(&"atlas", source.albedo_texture)
				cab.set_shader_parameter(&"paint_albedo", paint.albedo_texture)
				cab.set_shader_parameter(&"paint_roughness", paint.roughness_texture)
				cab.set_shader_parameter(&"grime", Mats.grime_mask())
				cab.set_shader_parameter(&"paint_tint", Vector3(PAINT_TINT.r, PAINT_TINT.g, PAINT_TINT.b))
				instance.set_surface_override_material(surface, cab)


# --- Cargo body -------------------------------------------------------------------

func _build_cargo_body() -> void:
	var paint := Mats.van_paint()
	var liner := Mats.surface("metal_painted_rusty", 0.5, Color(0.42, 0.46, 0.46), Color(0.35, 0.38, 0.38), Color(0.18, 0.20, 0.20), false, 0.9)
	var steel := Mats.iron(false)
	var rubber := Mats.rubber()
	var skin := WALL * 0.5

	# Floor: structural slab with a tread-plate deck and a hazard strip at the loading edge.
	_collider_span(-HALF_WIDTH, HALF_WIDTH, UNDERSIDE, FLOOR_TOP, REAR_Z, PARTITION_Z)
	_span(-HALF_WIDTH + WALL, HALF_WIDTH - WALL, FLOOR_TOP - 0.03, FLOOR_TOP, REAR_Z, PARTITION_Z, Mats.tread_plate(), false)
	_span(-HALF_WIDTH + WALL, HALF_WIDTH - WALL, FLOOR_TOP, FLOOR_TOP + 0.004, REAR_Z, REAR_Z + 0.12, Mats.solid(Color(0.80, 0.62, 0.05), 0.6), false)
	# Chassis rails, cross-members and a spare slung underneath.
	for rail_x: float in [-0.48, 0.48]:
		_span(rail_x - 0.05, rail_x + 0.05, UNDERSIDE - 0.02, FLOOR_TOP - 0.03, REAR_Z + 0.05, PARTITION_Z + 0.1, steel, false)
	for member_z: float in [-2.4, -1.1, -0.4, 0.4]:
		_span(-HALF_WIDTH + 0.06, HALF_WIDTH - 0.06, FLOOR_TOP - 0.12, FLOOR_TOP - 0.03, member_z - 0.04, member_z + 0.04, steel, false)

	for side: float in [-1.0, 1.0]:
		var outer := side * HALF_WIDTH
		var inner := side * (HALF_WIDTH - WALL)
		var mid := side * (HALF_WIDTH - skin)
		# Wall: painted skin outside, scuffed liner inside, one collider.
		_collider_span(minf(inner, outer), maxf(inner, outer), FLOOR_TOP, ROOF_TOP - WALL, REAR_Z, PARTITION_Z)
		_span(minf(mid, outer), maxf(mid, outer), WHEEL_TOP + 0.06, ROOF_TOP - WALL, REAR_Z, PARTITION_Z, paint, false)
		_span(minf(inner, mid), maxf(inner, mid), FLOOR_TOP, ROOF_TOP - WALL, REAR_Z, PARTITION_Z, liner, false)
		# Side skirts either side of the wheel arch, with a rubber flare over the tyre.
		_span(minf(mid, outer), maxf(mid, outer), UNDERSIDE, WHEEL_TOP + 0.06, REAR_Z, AXLE_Z - ARCH_HALF_LENGTH, paint, false)
		_span(minf(mid, outer), maxf(mid, outer), UNDERSIDE, WHEEL_TOP + 0.06, AXLE_Z + ARCH_HALF_LENGTH, PARTITION_Z, paint, false)
		var lip := side * (HALF_WIDTH + 0.05)
		_span(minf(mid, lip), maxf(mid, lip), WHEEL_TOP + 0.02, WHEEL_TOP + 0.07, AXLE_Z - ARCH_HALF_LENGTH - 0.04, AXLE_Z + ARCH_HALF_LENGTH + 0.04, rubber, false)
		# Mud flap behind the wheel.
		_span(side * (WHEEL_INNER_X + 0.02) if side > 0.0 else outer + 0.03, outer - 0.03 if side > 0.0 else side * (WHEEL_INNER_X + 0.02),
				0.14, UNDERSIDE + 0.05, AXLE_Z - ARCH_HALF_LENGTH - 0.03, AXLE_Z - ARCH_HALF_LENGTH - 0.01, rubber, false)
		# Aluminium edge rails top and bottom.
		_span(minf(side * (HALF_WIDTH - 0.01), side * (HALF_WIDTH + 0.02)), maxf(side * (HALF_WIDTH - 0.01), side * (HALF_WIDTH + 0.02)),
				ROOF_TOP - 0.09, ROOF_TOP + 0.01, REAR_Z - 0.01, PARTITION_Z + 0.01, steel, false)
		# Wheel arch boxed in inside the bay, chamfered so dragged things ride over it.
		var arch_inner := side * (WHEEL_INNER_X - 0.05)
		_chamfered_box(
				Vector3(minf(arch_inner, inner), FLOOR_TOP, AXLE_Z - ARCH_HALF_LENGTH - 0.06),
				Vector3(maxf(arch_inner, inner), FLOOR_TOP, AXLE_Z + ARCH_HALF_LENGTH + 0.06),
				Vector3(minf(side * (WHEEL_INNER_X + 0.07), inner), WHEEL_TOP + 0.07, AXLE_Z - ARCH_HALF_LENGTH + 0.16),
				Vector3(maxf(side * (WHEEL_INNER_X + 0.07), inner), WHEEL_TOP + 0.07, AXLE_Z + ARCH_HALF_LENGTH - 0.16),
				liner)

	# Roof, overhanging the cab as a wind fairing.
	_collider_span(-HALF_WIDTH, HALF_WIDTH, ROOF_TOP - WALL, ROOF_TOP, REAR_Z, PARTITION_Z)
	_span(-HALF_WIDTH, HALF_WIDTH, ROOF_TOP - skin, ROOF_TOP, REAR_Z, PARTITION_Z, paint, false)
	_span(-HALF_WIDTH + WALL, HALF_WIDTH - WALL, ROOF_TOP - WALL, ROOF_TOP - skin, REAR_Z, PARTITION_Z, liner, false)
	# Front wall: bulkhead behind the cab below, painted fairing above it.
	_collider_span(-HALF_WIDTH, HALF_WIDTH, FLOOR_TOP, ROOF_TOP, PARTITION_Z - WALL, PARTITION_Z)
	_span(-HALF_WIDTH, HALF_WIDTH, UNDERSIDE, ROOF_TOP, PARTITION_Z - skin, PARTITION_Z, paint, false)
	_span(-HALF_WIDTH + WALL, HALF_WIDTH - WALL, FLOOR_TOP, ROOF_TOP - WALL, PARTITION_Z - WALL, PARTITION_Z - skin, liner, false)
	var fairing := PrismMesh.new()
	fairing.size = Vector3(HALF_WIDTH * 2.0, ROOF_TOP - CAB_ROOF - 0.04, 0.5)
	fairing.left_to_right = 0.0
	var wedge := _mesh(fairing, Vector3(0.0, (ROOF_TOP + CAB_ROOF + 0.04) * 0.5, PARTITION_Z + 0.25), paint)
	wedge.basis = Basis(Vector3.UP, -PI * 0.5) * Basis.from_scale(Vector3(0.5 / (HALF_WIDTH * 2.0), 1.0, HALF_WIDTH * 2.0 / 0.5))
	# Amber marker lamps along the top of the fairing.
	for marker_x: float in [-0.9, -0.3, 0.3, 0.9]:
		_span(marker_x - 0.05, marker_x + 0.05, ROOF_TOP - 0.02, ROOF_TOP + 0.03, PARTITION_Z - 0.04, PARTITION_Z + 0.04, Mats.glow(Color(1.0, 0.55, 0.08), 2.0), false)


## Cage bars, tie rails, bulkhead hatch, ceiling ribs and the caged work light.
func _build_interior() -> void:
	var bar := Mats.iron(false)
	var steel := Mats.metal_dark()
	var ceiling := ROOF_TOP - WALL
	var upright := CylinderMesh.new()
	upright.top_radius = 0.016
	upright.bottom_radius = 0.016
	upright.height = ceiling - WHEEL_TOP - 0.12
	upright.radial_segments = 8
	upright.rings = 1
	var bay_length := PARTITION_Z - REAR_Z
	for side: float in [-1.0, 1.0]:
		var bar_x := side * (HALF_WIDTH - WALL - 0.045)
		var z := REAR_Z + 0.22
		while z < PARTITION_Z - 0.15:
			_mesh(upright, Vector3(bar_x, (ceiling + WHEEL_TOP + 0.12) * 0.5, z), bar)
			z += 0.3
		# Tie rails the bars are welded to, plus a heavier binding rail at waist height.
		for rail_y: float in [WHEEL_TOP + 0.14, ceiling - 0.1]:
			_rod(Vector3(bar_x - side * 0.01, rail_y, REAR_Z + 0.1), Vector3(bar_x - side * 0.01, rail_y, PARTITION_Z - 0.1), 0.02, bar)
		_rod(Vector3(bar_x - side * 0.05, 1.55, REAR_Z + 0.2), Vector3(bar_x - side * 0.05, 1.55, PARTITION_Z - 0.2), 0.026, steel)
		for bracket_z: float in [REAR_Z + 0.25, REAR_Z + bay_length * 0.5, PARTITION_Z - 0.25]:
			_rod(Vector3(bar_x, 1.55, bracket_z), Vector3(bar_x - side * 0.05, 1.55, bracket_z), 0.014, steel)
		# Shackle rings for whatever needs chaining down.
		var ring := TorusMesh.new()
		ring.inner_radius = 0.045
		ring.outer_radius = 0.065
		ring.rings = 14
		ring.ring_segments = 6
		for ring_z: float in [-0.6, 0.3]:
			var shackle := _mesh(ring, Vector3(bar_x - side * 0.06, 1.47, ring_z), bar)
			shackle.rotation = Vector3(PI * 0.5, 0.0, 0.25 * side)
	# Ceiling ribs.
	for rib_z: float in [-2.2, -1.5, -0.8, -0.1, 0.55]:
		_span(-HALF_WIDTH + WALL, HALF_WIDTH - WALL, ceiling - 0.045, ceiling, rib_z - 0.025, rib_z + 0.025, steel, false)
	# Bulkhead: a barred observation hatch through to the cab, and a warning plate.
	var hatch_z := PARTITION_Z - WALL - 0.004
	_span(-0.42, 0.42, 1.55, 2.05, hatch_z - 0.006, hatch_z, Mats.solid(Color(0.01, 0.012, 0.015), 0.3), false)
	_span(-0.46, 0.46, 1.51, 2.09, hatch_z - 0.02, hatch_z - 0.006, steel, false).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_span(-0.42, 0.42, 1.55, 2.05, hatch_z - 0.021, hatch_z - 0.007, Mats.solid(Color(0.01, 0.012, 0.015), 0.3), false)
	var hatch_bar_x := -0.36
	while hatch_bar_x < 0.4:
		_rod(Vector3(hatch_bar_x, 1.53, hatch_z - 0.03), Vector3(hatch_bar_x, 2.07, hatch_z - 0.03), 0.012, bar)
		hatch_bar_x += 0.09
	_span(-0.3, 0.3, 1.16, 1.4, hatch_z - 0.008, hatch_z, Mats.solid(Color(0.80, 0.62, 0.05), 0.6), false)
	_label("CAUTION: LIVE CARGO", 26, Vector3(0.0, 1.31, hatch_z - 0.011), PI, Color(0.06, 0.06, 0.06))
	_label("DO NOT FEED. DO NOT BARGAIN.", 15, Vector3(0.0, 1.22, hatch_z - 0.011), PI, Color(0.06, 0.06, 0.06))
	# Anchor ring bolted to the deck for the star passenger.
	var anchor := TorusMesh.new()
	anchor.inner_radius = 0.07
	anchor.outer_radius = 0.1
	anchor.rings = 16
	anchor.ring_segments = 6
	_mesh(anchor, Vector3(0.0, FLOOR_TOP + 0.016, 0.1), bar)
	var plate := CylinderMesh.new()
	plate.top_radius = 0.16
	plate.bottom_radius = 0.16
	plate.height = 0.012
	plate.radial_segments = 16
	_mesh(plate, Vector3(0.0, FLOOR_TOP + 0.006, 0.1), steel)

	# Caged work light on the ceiling.
	var fitting := ModelLoader.instance("lighting/caged_light", {"fit_width": 0.62, "anchor": "top", "tint": Color(0.7, 0.7, 0.7), "shadows": false})
	fitting.position = Vector3(0.0, ceiling - 0.04, -0.9)
	fitting.rotation.y = PI * 0.5
	add_child(fitting)
	var tube_material := Mats.glow(Color(0.60, 0.95, 0.90), 3.0, true)
	var bay := OmniLight3D.new()
	bay.name = "BayLight"
	bay.position = Vector3(0.0, ceiling - 0.4, -0.9)
	bay.light_color = Color(0.62, 0.95, 0.90)
	bay.omni_range = 5.0
	bay.omni_attenuation = 1.2
	bay.light_volumetric_fog_energy = 0.6
	bay.shadow_enabled = true
	bay.shadow_bias = 0.1
	bay.shadow_normal_bias = 1.5
	add_child(bay)
	var bay_flicker := FlickerLight.new()
	bay_flicker.base_energy = 1.6
	bay_flicker.flicker_amount = 0.2
	bay_flicker.speed = 9.0
	bay_flicker.dropout_rate = 0.05
	bay_flicker.glow_material = tube_material
	bay_flicker.glow_energy = 3.0
	bay.add_child(bay_flicker)
	var tube := CapsuleMesh.new()
	tube.radius = 0.022
	tube.height = 0.34
	var tube_instance := _mesh(tube, Vector3(0.0, ceiling - 0.2, -0.9), tube_material)
	tube_instance.rotation.x = PI * 0.5
	tube_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_ramp() -> void:
	# One solid wedge is both the visible ramp and its collider, so nothing can roll underneath.
	var plate := Mats.tread_plate()
	var wedge := PrismMesh.new()
	wedge.size = Vector3(RAMP_LENGTH, FLOOR_TOP, RAMP_HALF_WIDTH * 2.0)
	wedge.left_to_right = 1.0
	var ramp_position := Vector3(0.0, FLOOR_TOP * 0.5, REAR_Z - RAMP_LENGTH * 0.5)
	# Turn the prism so its tall edge meets the cargo floor.
	var ramp_basis := Basis(Vector3.UP, -PI * 0.5)
	var ramp := _mesh(wedge, ramp_position, plate)
	ramp.basis = ramp_basis
	var collider := CollisionShape3D.new()
	collider.shape = wedge.create_convex_shape()
	collider.transform = Transform3D(ramp_basis, ramp_position)
	_body.add_child(collider)
	# Hazard-yellow kerbs and anti-slip rungs laid along the slope.
	var slope := atan2(FLOOR_TOP, RAMP_LENGTH)
	var slope_length := Vector2(RAMP_LENGTH, FLOOR_TOP).length()
	var kerb := BoxMesh.new()
	kerb.size = Vector3(0.06, 0.03, slope_length)
	for side: float in [-1.0, 1.0]:
		var strip := _mesh(kerb, ramp_position + Vector3(side * (RAMP_HALF_WIDTH - 0.03), 0.016, 0.0), Mats.solid(Color(0.80, 0.62, 0.05), 0.6))
		strip.rotation.x = -slope
	var rung := BoxMesh.new()
	rung.size = Vector3(RAMP_HALF_WIDTH * 2.0 - 0.14, 0.012, 0.03)
	var steps := 8
	for i in range(1, steps):
		var t := float(i) / float(steps)
		var cleat := _mesh(rung, Vector3(0.0, FLOOR_TOP * (1.0 - t) + 0.005, REAR_Z - RAMP_LENGTH * t), Mats.iron(false))
		cleat.rotation.x = -slope
		cleat.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Door frame at the back: corner posts with tail lamps, header with marker lamps, bumper stubs.
func _build_rear_frame() -> void:
	var paint := Mats.van_paint()
	var steel := Mats.metal_dark()
	var tail := Mats.glow(Color(1.0, 0.08, 0.04), 3.5)
	var amber := Mats.glow(Color(1.0, 0.5, 0.06), 1.6)
	for side: float in [-1.0, 1.0]:
		# Bumper stub and step either side of the ramp.
		var inner := side * (RAMP_HALF_WIDTH + 0.02)
		var outer := side * HALF_WIDTH
		_span(minf(inner, outer), maxf(inner, outer), UNDERSIDE - 0.06, UNDERSIDE + 0.14, REAR_Z - 0.14, REAR_Z, steel)
		# Tail lamp cluster let into the lower corner of the body, below the door.
		var lamp_x := side * (HALF_WIDTH - 0.15)
		_span(lamp_x - 0.12, lamp_x + 0.12, UNDERSIDE + 0.15, FLOOR_TOP - 0.03, REAR_Z - 0.012, REAR_Z, steel, false)
		_span(lamp_x - 0.1, lamp_x + 0.02, UNDERSIDE + 0.165, FLOOR_TOP - 0.045, REAR_Z - 0.03, REAR_Z - 0.012, tail, false)
		_span(lamp_x + 0.035, lamp_x + 0.1, UNDERSIDE + 0.165, FLOOR_TOP - 0.045, REAR_Z - 0.03, REAR_Z - 0.012, amber, false)
	# Header above the doors with three red marker lamps.
	_span(-HALF_WIDTH, HALF_WIDTH, ROOF_TOP - 0.03, ROOF_TOP + 0.02, REAR_Z - 0.09, REAR_Z, paint, false)
	for marker_x: float in [-0.25, 0.0, 0.25]:
		_span(marker_x - 0.05, marker_x + 0.05, ROOF_TOP - 0.02, ROOF_TOP + 0.01, REAR_Z - 0.1, REAR_Z - 0.09, tail, false)


func _build_lights() -> void:
	# Headlights: the model's lenses glow; these spots cut the fog.
	for side: float in [-1.0, 1.0]:
		var beam := SpotLight3D.new()
		beam.name = "Headlight"
		beam.position = Vector3(side * 1.02, 0.98, NOSE_Z + 0.08)
		beam.rotation = Vector3(deg_to_rad(-5.0), PI, 0.0)
		beam.light_color = Color(1.0, 0.93, 0.80)
		beam.light_energy = 6.0
		beam.light_volumetric_fog_energy = 1.0
		beam.spot_range = 30.0
		beam.spot_angle = 30.0
		beam.spot_attenuation = 1.1
		beam.spot_angle_attenuation = 0.7
		# One shadow-casting beam is enough; the pair overlap almost completely.
		beam.shadow_enabled = side < 0.0
		beam.shadow_bias = 0.1
		beam.shadow_normal_bias = 1.5
		add_child(beam)
	# Tail lamps wash the loading area in red.
	var tail_glow := OmniLight3D.new()
	tail_glow.name = "TailGlow"
	tail_glow.position = Vector3(0.0, 0.55, REAR_Z - 0.5)
	tail_glow.light_color = Color(1.0, 0.12, 0.06)
	tail_glow.light_energy = 0.6
	tail_glow.omni_range = 5.0
	add_child(tail_glow)
	# Work light above the doors, aimed down the ramp.
	_span(-0.2, 0.2, ROOF_TOP + 0.02, ROOF_TOP + 0.11, REAR_Z - 0.02, REAR_Z + 0.16, Mats.metal_dark(), false)
	_span(-0.15, 0.15, ROOF_TOP + 0.03, ROOF_TOP + 0.1, REAR_Z - 0.035, REAR_Z - 0.02, Mats.glow(Color(0.82, 0.92, 1.0), 4.0), false)
	var work := SpotLight3D.new()
	work.name = "WorkLight"
	work.position = Vector3(0.0, ROOF_TOP + 0.08, REAR_Z - 0.2)
	work.rotation.x = deg_to_rad(-52.0)
	work.light_color = Color(0.80, 0.90, 1.0)
	work.light_energy = 4.0
	work.light_volumetric_fog_energy = 1.2
	work.spot_range = 11.0
	work.spot_angle = 52.0
	work.spot_angle_attenuation = 0.8
	work.shadow_enabled = true
	work.shadow_bias = 0.1
	work.shadow_normal_bias = 1.5
	add_child(work)


## Rotating amber lightbar on the cab roof.
func _build_lightbar() -> void:
	var base_y := CAB_ROOF + 0.02
	var bar_z := 1.45
	_span(-0.62, 0.62, base_y, base_y + 0.06, bar_z - 0.12, bar_z + 0.12, Mats.metal_dark(), false)
	for foot_x: float in [-0.5, 0.5]:
		_span(foot_x - 0.04, foot_x + 0.04, base_y - 0.05, base_y, bar_z - 0.1, bar_z + 0.1, Mats.metal_dark(), false)
	_beacon_material = Mats.glow(Color(1.0, 0.55, 0.05), 2.0, true)
	_beacon_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beacon_material.albedo_color = Color(1.0, 0.55, 0.05, 0.72)
	_beacon_material.roughness = 0.15
	var dome := CapsuleMesh.new()
	dome.radius = 0.085
	dome.height = 0.5
	dome.radial_segments = 16
	dome.rings = 6
	for dome_x: float in [-0.32, 0.32]:
		var lens := _mesh(dome, Vector3(dome_x, base_y + 0.13, bar_z), _beacon_material)
		lens.rotation.z = PI * 0.5
		lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_span(-0.06, 0.06, base_y + 0.06, base_y + 0.2, bar_z - 0.1, bar_z + 0.1, Mats.metal_bare(), false)

	_beacon_pivot = Node3D.new()
	_beacon_pivot.name = "BeaconPivot"
	_beacon_pivot.position = Vector3(0.0, base_y + 0.13, bar_z)
	add_child(_beacon_pivot)
	var reflector := BoxMesh.new()
	reflector.size = Vector3(0.1, 0.09, 0.012)
	for i in 2:
		var facing := PI * float(i)
		var sweep := SpotLight3D.new()
		sweep.name = "BeaconSweep"
		sweep.rotation = Vector3(deg_to_rad(-4.0), facing, 0.0)
		sweep.position = Vector3(sin(facing), 0.0, cos(facing)) * -0.05
		sweep.light_color = Color(1.0, 0.52, 0.06)
		sweep.light_energy = 5.0
		sweep.light_volumetric_fog_energy = 2.2
		sweep.spot_range = 17.0
		sweep.spot_angle = 24.0
		sweep.spot_attenuation = 1.2
		sweep.spot_angle_attenuation = 0.6
		_beacon_pivot.add_child(sweep)
		# The spinning mirrors, visible through the domes.
		for dome_x: float in [-0.32, 0.32]:
			var mirror := MeshInstance3D.new()
			mirror.mesh = reflector
			mirror.material_override = Mats.glow(Color(1.0, 0.8, 0.4), 6.0)
			mirror.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mirror.position = Vector3(dome_x, 0.0, 0.0) + Vector3(sin(facing), 0.0, cos(facing)) * 0.02
			mirror.rotation.y = facing
			_beacon_pivot.add_child(mirror)
	_beacon_glow = OmniLight3D.new()
	_beacon_glow.name = "BeaconGlow"
	_beacon_glow.position = Vector3(0.0, base_y + 0.45, bar_z)
	_beacon_glow.light_color = Color(1.0, 0.55, 0.08)
	_beacon_glow.light_energy = 0.8
	_beacon_glow.omni_range = 6.0
	_beacon_glow.light_volumetric_fog_energy = 1.2
	add_child(_beacon_glow)


## Weathered livery on both flanks: stripe, logotype, strapline and a film of road dirt.
func _build_branding() -> void:
	var stripe := Mats.surface("metal_painted_rusty", 0.5, LIVERY, LIVERY, LIVERY.darkened(0.3), false, 0.8)
	var centre_z := (REAR_Z + PARTITION_Z) * 0.5
	for side: float in [-1.0, 1.0]:
		var facing := side * PI * 0.5
		var face := side * (HALF_WIDTH + 0.003)
		_span(minf(face, face - side * 0.004), maxf(face, face - side * 0.004), 1.12, 1.4, REAR_Z + 0.03, PARTITION_Z - 0.03, stripe, false)
		_span(minf(face, face - side * 0.004), maxf(face, face - side * 0.004), 1.44, 1.47, REAR_Z + 0.03, PARTITION_Z - 0.03, stripe, false)
		var text_x := side * (HALF_WIDTH + 0.006)
		_label("BIND & DELIVER", 100, Vector3(text_x, 2.14, centre_z), facing, Color(0.09, 0.17, 0.20, 0.9))
		_label("LICENSED DEMON REMOVAL", 34, Vector3(text_x, 1.75, centre_z), facing, Color(0.13, 0.13, 0.13, 0.85))
		_label("NO SOUL TOO SMALL", 26, Vector3(text_x, 1.26, centre_z), facing, Color(0.92, 0.89, 0.80, 0.85))
		_label("EST. 1697", 20, Vector3(text_x, 1.59, centre_z + side * 0.9), facing, Color(0.13, 0.13, 0.13, 0.7))
		# Road film sprayed up over the lettering.
		var film := QuadMesh.new()
		film.size = Vector2(PARTITION_Z - REAR_Z - 0.04, ROOF_TOP - UNDERSIDE - 0.2)
		var dirt := _mesh(film, Vector3(side * (HALF_WIDTH + 0.009), (ROOF_TOP + UNDERSIDE) * 0.5, centre_z), _dirt_film())
		dirt.rotation.y = facing
		dirt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Transparent brown blotches, heaviest toward the bottom of the panel.
func _dirt_film() -> StandardMaterial3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.014
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.65
	noise.seed = 2291
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.5, 0.75, 1.0])
	ramp.colors = PackedColorArray([Color(0.10, 0.07, 0.05, 0.0), Color(0.12, 0.08, 0.05, 0.05), Color(0.16, 0.10, 0.06, 0.45), Color(0.20, 0.12, 0.07, 0.8)])
	var streaks := NoiseTexture2D.new()
	streaks.width = 512
	streaks.height = 256
	streaks.seamless = true
	streaks.generate_mipmaps = true
	streaks.noise = noise
	streaks.color_ramp = ramp
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = streaks
	material.roughness = 1.0
	material.uv1_scale = Vector3(1.6, 0.9, 1.0)
	return material


func _build_doors() -> void:
	var angle := deg_to_rad(DOOR_OPEN_DEGREES)
	left_door = _make_door("RearDoorLeft", -(HALF_WIDTH - 0.02), false, angle)
	right_door = _make_door("RearDoorRight", HALF_WIDTH - 0.02, true, -angle)
	left_door.partner = right_door
	right_door.partner = left_door
	left_door.toggled.connect(_on_doors_toggled)


func _make_door(door_name: String, hinge_x: float, mirrored: bool, open_angle: float) -> HingedDoor:
	var width := HALF_WIDTH - 0.035
	var bottom := FLOOR_TOP - 0.02
	var top := ROOF_TOP - 0.04
	var height := top - bottom
	var thickness := 0.06
	var door: HingedDoor = HingedDoor.new()
	door.name = door_name
	door.noun = "rear doors"
	door.open_angle = open_angle
	door.configure(width, height, thickness, 16.0, Mats.van_paint())
	door.position = Vector3(hinge_x, (top + bottom) * 0.5, REAR_Z - thickness * 0.5 - 0.012)
	door.rotation.y = PI if mirrored else 0.0
	# The outside of the leaf is the face pointing away from the bay.
	var outside := 1.0 if mirrored else -1.0
	var steel := Mats.metal_bare()
	var dark := Mats.metal_dark()
	# Pressed ribs, inside and out.
	for rib_y: float in [-0.32, -0.08, 0.16, 0.38]:
		_door_box(door, Vector3(width - 0.2, 0.05, thickness + 0.02), Vector3(width * 0.5, rib_y * height, 0.0), Mats.van_paint())
	# Reflective chevron tape along the bottom edge.
	_door_box(door, Vector3(width - 0.06, 0.09, 0.004), Vector3(width * 0.5, -height * 0.5 + 0.1, outside * (thickness * 0.5 + 0.002)), Mats.glow(Color(0.85, 0.12, 0.08), 0.5))
	# Two full-height lock rods with cam keepers and a swing handle each.
	for rod_u: float in [0.3, 0.72]:
		var rod_x := width * rod_u
		_door_rod(door, Vector3(rod_x, -height * 0.5 + 0.04, outside * (thickness * 0.5 + 0.03)), Vector3(rod_x, height * 0.5 - 0.04, outside * (thickness * 0.5 + 0.03)), 0.014, steel)
		for keeper_y: float in [-0.44, 0.0, 0.44]:
			_door_box(door, Vector3(0.07, 0.05, 0.03), Vector3(rod_x, keeper_y * height, outside * (thickness * 0.5 + 0.015)), dark)
		_door_box(door, Vector3(0.22, 0.035, 0.02), Vector3(rod_x - 0.08, -height * 0.12, outside * (thickness * 0.5 + 0.05)), steel)
	# Hinge knuckles down the hinge edge.
	for hinge_y: float in [-0.38, -0.13, 0.13, 0.38]:
		_door_box(door, Vector3(0.12, 0.08, 0.025), Vector3(0.05, hinge_y * height, outside * (thickness * 0.5 + 0.012)), dark)
		_door_rod(door, Vector3(0.0, hinge_y * height - 0.06, outside * (thickness * 0.5 + 0.02)), Vector3(0.0, hinge_y * height + 0.06, outside * (thickness * 0.5 + 0.02)), 0.018, dark)
	# Rubber seal round the inner face.
	_door_box(door, Vector3(width - 0.04, height - 0.04, 0.008), Vector3(width * 0.5, 0.0, -outside * (thickness * 0.5 + 0.004)), Mats.surface("metal_painted_rusty", 0.5, Color(0.42, 0.46, 0.46), Color(0.35, 0.38, 0.38), Color(0.18, 0.20, 0.20), false, 0.9))
	add_child(door)
	door.hinge_to(_body)
	return door


func _door_box(door: Node3D, size: Vector3, at: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	door.add_child(instance)


func _door_rod(door: Node3D, from: Vector3, to: Vector3, radius: float, material: Material) -> void:
	var bar := CylinderMesh.new()
	bar.top_radius = radius
	bar.bottom_radius = radius
	bar.height = from.distance_to(to)
	bar.radial_segments = 8
	bar.rings = 1
	var instance := MeshInstance3D.new()
	instance.mesh = bar
	instance.material_override = material
	instance.position = (from + to) * 0.5
	door.add_child(instance)


func _build_cargo_zone() -> void:
	cargo_zone = Area3D.new()
	cargo_zone.name = "CargoZone"
	cargo_zone.collision_layer = 0
	cargo_zone.collision_mask = GameState.LAYER_PROP
	cargo_zone.monitorable = false
	var shape := BoxShape3D.new()
	shape.size = Vector3((HALF_WIDTH - WALL) * 2.0 - 0.1, ROOF_TOP - WALL - FLOOR_TOP - 0.1, PARTITION_Z - REAR_Z - 0.4)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = Vector3(0.0, (ROOF_TOP - WALL + FLOOR_TOP) * 0.5, (PARTITION_Z + REAR_Z) * 0.5 + 0.1)
	cargo_zone.add_child(collider)
	add_child(cargo_zone)
	cargo_zone.body_entered.connect(_on_cargo_entered)


func _on_doors_toggled(open: bool) -> void:
	if open:
		GameState.complete_step(GameState.STEP_OPEN_VAN)


func _on_cargo_entered(body: Node3D) -> void:
	var prop := body as RigidBody3D
	if prop and prop.is_in_group(GameState.GROUP_GRABBABLE):
		cargo_loaded.emit(prop)
		GameState.post_notice("Cage test: %s secured" % str(prop.get_meta(&"display_name", prop.name)))


# --- Assembly helpers -------------------------------------------------------

func _mesh(mesh: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	_body.add_child(instance)
	return instance


## Axis-aligned box given by its min/max corners, optionally with a matching collider.
func _span(x0: float, x1: float, y0: float, y1: float, z0: float, z1: float, material: Material, solid: bool = true) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(x1 - x0, y1 - y0, z1 - z0)
	if solid:
		_collider_span(x0, x1, y0, y1, z0, z1)
	return _mesh(mesh, Vector3(x0 + x1, y0 + y1, z0 + z1) * 0.5, material)


func _collider_span(x0: float, x1: float, y0: float, y1: float, z0: float, z1: float) -> void:
	var shape := BoxShape3D.new()
	shape.size = Vector3(x1 - x0, y1 - y0, z1 - z0)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = Vector3(x0 + x1, y0 + y1, z0 + z1) * 0.5
	_body.add_child(collider)


## Round bar between two points.
func _rod(from: Vector3, to: Vector3, radius: float, material: Material) -> MeshInstance3D:
	var span := to - from
	var length := span.length()
	var bar := CylinderMesh.new()
	bar.top_radius = radius
	bar.bottom_radius = radius
	bar.height = length
	bar.radial_segments = 8
	bar.rings = 1
	var instance := _mesh(bar, (from + to) * 0.5, material)
	if length > 0.0001:
		var up := span / length
		var side := up.cross(Vector3.UP)
		if side.length_squared() < 0.0001:
			side = Vector3.RIGHT
		side = side.normalized()
		instance.basis = Basis(side, up, side.cross(up))
	return instance


## Box whose top is smaller than its base (a truncated pyramid), with a matching convex collider.
func _chamfered_box(base_min: Vector3, base_max: Vector3, top_min: Vector3, top_max: Vector3, material: Material) -> void:
	var corners := PackedVector3Array([
		Vector3(base_min.x, base_min.y, base_min.z), Vector3(base_max.x, base_min.y, base_min.z),
		Vector3(base_max.x, base_min.y, base_max.z), Vector3(base_min.x, base_min.y, base_max.z),
		Vector3(top_min.x, top_min.y, top_min.z), Vector3(top_max.x, top_min.y, top_min.z),
		Vector3(top_max.x, top_min.y, top_max.z), Vector3(top_min.x, top_min.y, top_max.z),
	])
	var quads := [[4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for quad: Array in quads:
		for index: int in [0, 1, 2, 0, 2, 3]:
			tool.add_vertex(corners[quad[index]])
	tool.generate_normals()
	var two_sided := material.duplicate() as BaseMaterial3D
	if two_sided:
		two_sided.cull_mode = BaseMaterial3D.CULL_DISABLED
	var instance := MeshInstance3D.new()
	instance.mesh = tool.commit()
	instance.material_override = two_sided if two_sided else material
	_body.add_child(instance)
	var hull := ConvexPolygonShape3D.new()
	hull.points = corners
	var collider := CollisionShape3D.new()
	collider.shape = hull
	_body.add_child(collider)


func _label(text: String, font_size: int, at: Vector3, yaw: float, color: Color) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = font_size
	label.pixel_size = 0.004
	label.outline_size = 0
	label.modulate = color
	label.shaded = true
	label.double_sided = false
	label.alpha_cut = Label3D.ALPHA_CUT_DISABLED if color.a < 0.99 else Label3D.ALPHA_CUT_DISCARD
	label.position = at
	label.rotation.y = yaw
	add_child(label)
