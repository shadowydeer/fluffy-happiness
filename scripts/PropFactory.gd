extends RefCounted
## Builds the interactive clutter and furniture.
##
## Every prop is a RigidBody3D whose visual is a real .glb model normalised by
## `ModelLoader` (origin on the floor, centred, facing -Z) and whose collider is
## fitted to that model: a box for boxy things, a simplified convex hull for
## round or irregular ones, and a seat + backrest pair for seating.
## Mass, friction and bounce are tuned per object so paint cans clatter, books
## slide, and a sofa has to be shouldered across the room.

const Mats := preload("res://scripts/MaterialLibrary.gd")
const FlickerLight := preload("res://scripts/FlickerLight.gd")

const BOX := &"box"
const CONVEX := &"convex"
const SEAT := &"seat"

## Slight overall darkening so bright scanned assets sit in the house palette.
const HOUSE_TINT := Color(0.80, 0.78, 0.76)
const BOOK_COLORS: Array[Color] = [
	Color(0.45, 0.10, 0.10), Color(0.10, 0.22, 0.36), Color(0.14, 0.30, 0.16),
	Color(0.36, 0.26, 0.10), Color(0.24, 0.12, 0.30), Color(0.12, 0.12, 0.13),
]

# kind -> recipe. Keys:
#   label                      shown in the grab prompt
#   model                      path under res://assets/models (without .glb)
#   fit                        ModelLoader options (size, rotation, part ...)
#   mass, friction, bounce     physics
#   shape                      BOX, CONVEX or SEAT
#   seat / back                SEAT only: seat height and backrest depth as fractions of the bounds
#   damp                       angular damping (default 0.35)
#   size                       stand-in size if the .glb is missing
const RECIPES := {
	# --- Seating ---------------------------------------------------------
	&"chair": {"label": "Dining Chair", "model": "furniture/dining_chair", "fit": {"fit_height": 1.08, "rotate_y": 180.0},
			"mass": 5.5, "friction": 0.7, "bounce": 0.1, "shape": SEAT, "seat": 0.44, "back": 0.2, "size": Vector3(0.5, 1.05, 0.5)},
	&"gothic_chair": {"label": "Gothic Chair", "model": "furniture/gothic_chair", "fit": {"fit_height": 1.75, "rotate_y": 180.0},
			"mass": 11.0, "friction": 0.75, "bounce": 0.05, "shape": SEAT, "seat": 0.3, "back": 0.22, "size": Vector3(0.55, 1.75, 0.5)},
	&"armchair": {"label": "Armchair", "model": "furniture/armchair", "fit": {"fit_height": 1.05, "rotate_y": 180.0},
			"mass": 24.0, "friction": 0.85, "bounce": 0.0, "shape": SEAT, "seat": 0.5, "back": 0.3, "damp": 0.7, "size": Vector3(0.85, 1.05, 0.8)},
	&"green_chair": {"label": "Velvet Chair", "model": "furniture/green_chair", "fit": {"fit_height": 1.04, "rotate_y": 180.0},
			"mass": 12.0, "friction": 0.8, "bounce": 0.05, "shape": SEAT, "seat": 0.46, "back": 0.25, "size": Vector3(0.66, 1.04, 0.66)},
	&"rocking_chair": {"label": "Rocking Chair", "model": "furniture/rocking_chair", "fit": {"fit_height": 1.0, "rotate_y": 180.0},
			"mass": 8.5, "friction": 0.6, "bounce": 0.1, "shape": SEAT, "seat": 0.45, "back": 0.25, "size": Vector3(0.7, 1.0, 0.8)},
	&"sofa": {"label": "Moth-Eaten Sofa", "model": "furniture/sofa", "fit": {"fit_width": 1.95, "rotate_y": 180.0},
			"mass": 46.0, "friction": 0.7, "bounce": 0.0, "shape": SEAT, "seat": 0.58, "back": 0.3, "damp": 0.8, "size": Vector3(1.95, 0.78, 0.88)},
	&"wheelchair": {"label": "Wheelchair", "model": "props/wheelchair", "fit": {"fit_height": 1.0, "rotate_y": 180.0},
			"mass": 15.0, "friction": 0.35, "bounce": 0.05, "shape": SEAT, "seat": 0.55, "back": 0.25, "size": Vector3(0.7, 1.0, 1.0)},
	# --- Tables and case goods -------------------------------------------
	&"table": {"label": "Dining Table", "model": "furniture/dining_table", "fit": {"stretch": Vector3(1.7, 0.76, 0.8)},
			"mass": 24.0, "friction": 0.8, "bounce": 0.05, "shape": CONVEX, "size": Vector3(1.7, 0.76, 0.8)},
	&"coffee_table": {"label": "Coffee Table", "model": "furniture/coffee_table", "fit": {"stretch": Vector3(1.1, 0.46, 0.8)},
			"mass": 14.0, "friction": 0.8, "bounce": 0.05, "shape": CONVEX, "size": Vector3(1.1, 0.46, 0.8)},
	&"round_table": {"label": "Round Table", "model": "furniture/round_table", "fit": {"fit_height": 0.78},
			"mass": 19.0, "friction": 0.75, "bounce": 0.05, "shape": CONVEX, "size": Vector3(1.1, 0.78, 1.1)},
	&"console_table": {"label": "Console Table", "model": "furniture/console_table", "fit": {"fit_width": 1.4, "rotate_y": 180.0},
			"mass": 17.0, "friction": 0.75, "bounce": 0.05, "shape": CONVEX, "size": Vector3(1.4, 0.86, 0.55)},
	&"desk": {"label": "Steel Desk", "model": "furniture/desk", "fit": {"fit_width": 1.75, "rotate_y": 180.0},
			"mass": 58.0, "friction": 0.75, "bounce": 0.0, "shape": BOX, "damp": 0.8, "size": Vector3(1.75, 0.7, 0.83)},
	&"bookshelf": {"label": "Bookshelf", "model": "furniture/bookshelf", "fit": {"fit_height": 2.1, "rotate_y": 180.0},
			"mass": 62.0, "friction": 0.85, "bounce": 0.0, "shape": BOX, "damp": 0.8, "size": Vector3(1.4, 2.1, 0.58)},
	&"cabinet": {"label": "Gothic Cabinet", "model": "furniture/gothic_cabinet", "fit": {"fit_height": 2.15, "rotate_y": 180.0},
			"mass": 85.0, "friction": 0.9, "bounce": 0.0, "shape": BOX, "damp": 0.9, "size": Vector3(1.55, 2.15, 0.95)},
	&"commode": {"label": "Commode", "model": "furniture/commode", "fit": {"fit_height": 1.1, "rotate_y": 180.0},
			"mass": 42.0, "friction": 0.85, "bounce": 0.0, "shape": BOX, "damp": 0.8, "size": Vector3(1.1, 1.1, 0.53)},
	&"painted_cabinet": {"label": "Flaking Cabinet", "model": "furniture/painted_cabinet", "fit": {"fit_height": 1.1, "rotate_y": 180.0},
			"mass": 34.0, "friction": 0.85, "bounce": 0.0, "shape": BOX, "damp": 0.8, "size": Vector3(1.1, 1.1, 0.58)},
	&"sideboard": {"label": "Sideboard", "model": "furniture/sideboard", "fit": {"fit_height": 0.86, "rotate_y": 180.0},
			"mass": 36.0, "friction": 0.85, "bounce": 0.0, "shape": BOX, "damp": 0.8, "size": Vector3(1.38, 0.86, 0.6)},
	&"nightstand": {"label": "Nightstand", "model": "furniture/nightstand", "fit": {"fit_height": 0.68, "rotate_y": 180.0},
			"mass": 9.0, "friction": 0.75, "bounce": 0.05, "shape": BOX, "size": Vector3(0.55, 0.68, 0.41)},
	&"grandfather_clock": {"label": "Grandfather Clock", "model": "furniture/grandfather_clock", "fit": {"fit_height": 2.15, "rotate_y": 180.0},
			"mass": 44.0, "friction": 0.85, "bounce": 0.0, "shape": BOX, "damp": 0.8, "size": Vector3(0.62, 2.15, 0.42)},
	# --- Lamps -----------------------------------------------------------
	&"lamp": {"label": "Floor Lamp", "model": "lighting/floor_lamp", "fit": {"fit_height": 1.72},
			"mass": 4.2, "friction": 0.75, "bounce": 0.1, "shape": CONVEX, "damp": 0.5, "size": Vector3(0.42, 1.72, 0.42)},
	&"lantern": {"label": "Wooden Lantern", "model": "lighting/wooden_lantern", "fit": {"fit_height": 0.5},
			"mass": 1.8, "friction": 0.7, "bounce": 0.15, "shape": BOX, "size": Vector3(0.21, 0.5, 0.22)},
	&"oil_lantern": {"label": "Kerosene Lantern", "model": "lighting/kerosene_lantern", "fit": {"fit_height": 0.36},
			"mass": 1.1, "friction": 0.6, "bounce": 0.2, "shape": CONVEX, "size": Vector3(0.15, 0.36, 0.13)},
	# --- Throwable clutter -----------------------------------------------
	&"box": {"label": "Cardboard Box", "model": "props/cardboard_box", "fit": {},
			"mass": 2.4, "friction": 0.62, "bounce": 0.05, "shape": BOX, "damp": 0.6, "size": Vector3(0.5, 0.4, 0.5)},
	&"crate": {"label": "Wooden Crate", "model": "props/wooden_crate", "fit": {"stretch": Vector3(0.78, 0.5, 0.52)},
			"mass": 11.0, "friction": 0.75, "bounce": 0.05, "shape": BOX, "size": Vector3(0.78, 0.5, 0.52)},
	&"book": {"label": "Occult Tome", "model": "props/book_set", "fit": {"rotation": Vector3(0.0, 0.0, 90.0), "stretch": Vector3(0.26, 0.05, 0.19)},
			"mass": 0.6, "friction": 0.55, "bounce": 0.05, "shape": BOX, "damp": 0.8, "size": Vector3(0.26, 0.05, 0.19)},
	&"tv": {"label": "Old Television", "model": "props/television", "fit": {"fit_width": 0.66, "rotate_y": 180.0},
			"mass": 13.0, "friction": 0.7, "bounce": 0.05, "shape": BOX, "size": Vector3(0.66, 0.5, 0.52)},
	&"radio": {"label": "Boombox", "model": "props/boombox", "fit": {"fit_width": 0.66, "rotate_y": 180.0},
			"mass": 3.6, "friction": 0.65, "bounce": 0.1, "shape": BOX, "size": Vector3(0.66, 0.43, 0.18)},
	&"bottle": {"label": "Wine Bottle", "model": "props/wine_bottles", "fit": {"fit_height": 0.32},
			"mass": 1.2, "friction": 0.45, "bounce": 0.25, "shape": CONVEX, "damp": 0.2, "size": Vector3(0.08, 0.32, 0.08)},
	&"paint_can": {"label": "Paint Can", "model": "props/paint_can", "fit": {"fit_height": 0.2},
			"mass": 3.4, "friction": 0.5, "bounce": 0.2, "shape": CONVEX, "damp": 0.15, "size": Vector3(0.17, 0.2, 0.17)},
	&"spray_can": {"label": "Spray Can", "model": "props/spray_cans", "fit": {"fit_height": 0.22},
			"mass": 0.45, "friction": 0.45, "bounce": 0.3, "shape": CONVEX, "damp": 0.15, "size": Vector3(0.07, 0.22, 0.07)},
	&"bucket": {"label": "Wooden Bucket", "model": "props/bucket", "fit": {"fit_height": 0.46},
			"mass": 2.6, "friction": 0.65, "bounce": 0.15, "shape": CONVEX, "size": Vector3(0.32, 0.46, 0.3)},
	&"toolbox": {"label": "Toolbox", "model": "props/toolbox", "fit": {"fit_width": 0.46, "rotate_y": 180.0},
			"mass": 7.0, "friction": 0.6, "bounce": 0.1, "shape": BOX, "size": Vector3(0.46, 0.4, 0.33)},
	&"tool_chest": {"label": "Tool Chest", "model": "props/tool_chest", "fit": {"fit_width": 0.66, "rotate_y": 180.0},
			"mass": 16.0, "friction": 0.6, "bounce": 0.05, "shape": BOX, "size": Vector3(0.66, 0.62, 0.4)},
	&"picture": {"label": "Framed Painting", "model": "props/picture_landscape", "fit": {"fit_width": 0.72, "rotate_y": 180.0},
			"mass": 2.2, "friction": 0.6, "bounce": 0.1, "shape": BOX, "size": Vector3(0.72, 0.55, 0.05)},
	&"skull": {"label": "Skull", "model": "props/skull", "fit": {"fit_height": 0.21, "rotate_y": 180.0},
			"mass": 0.9, "friction": 0.5, "bounce": 0.25, "shape": CONVEX, "damp": 0.2, "size": Vector3(0.2, 0.21, 0.22)},
	&"goblet": {"label": "Brass Goblet", "model": "props/goblets", "fit": {"fit_height": 0.2},
			"mass": 0.5, "friction": 0.45, "bounce": 0.3, "shape": CONVEX, "damp": 0.2, "size": Vector3(0.1, 0.2, 0.1)},
	&"bust": {"label": "Marble Bust", "model": "props/marble_bust", "fit": {"fit_height": 0.52, "rotate_y": 180.0},
			"mass": 14.0, "friction": 0.6, "bounce": 0.05, "shape": CONVEX, "size": Vector3(0.28, 0.52, 0.3)},
	# --- Yard ------------------------------------------------------------
	&"cone": {"label": "Traffic Cone", "model": "yard/traffic_cone", "fit": {"fit_height": 0.62},
			"mass": 1.3, "friction": 0.8, "bounce": 0.25, "shape": CONVEX, "damp": 0.4, "size": Vector3(0.36, 0.62, 0.36)},
	&"tyre": {"label": "Bald Tyre", "model": "yard/old_tyre", "fit": {"rotation": Vector3(90.0, 0.0, 0.0), "fit_width": 0.62},
			"mass": 8.5, "friction": 0.9, "bounce": 0.4, "shape": CONVEX, "size": Vector3(0.62, 0.17, 0.62)},
	&"trash_can": {"label": "Dustbin", "model": "yard/trash_can", "fit": {"part_prefix": "metal_trash_can_rust", "fit_height": 0.86},
			"mass": 6.0, "friction": 0.55, "bounce": 0.2, "shape": CONVEX, "size": Vector3(0.55, 0.86, 0.55)},
	&"generator": {"label": "Generator", "model": "yard/generator", "fit": {"fit_width": 0.8, "rotate_y": 180.0},
			"mass": 44.0, "friction": 0.8, "bounce": 0.0, "shape": BOX, "damp": 0.8, "size": Vector3(0.8, 0.57, 0.55)},
	&"hand_truck": {"label": "Hand Truck", "model": "yard/hand_truck", "fit": {"fit_height": 1.3, "rotate_y": 180.0},
			"mass": 9.0, "friction": 0.5, "bounce": 0.1, "shape": CONVEX, "size": Vector3(0.55, 1.3, 0.64)},
}

const BOOK_PARTS := 20
const BOTTLE_PARTS: Array[String] = ["wine_bottles_01_bordeaux", "wine_bottles_01_alsace", "wine_bottles_01_burgundy", "wine_bottles_01_champagne"]
const SPRAY_PARTS: Array[String] = ["spray_paint_bottles", "spray_paint_bottles_dirty"]
const GOBLET_PARTS: Array[String] = ["brass_goblet_01", "brass_goblet_02", "brass_goblet_03"]


static func has_kind(kind: StringName) -> bool:
	return RECIPES.has(kind)


## Creates a prop by kind name. `lit` switches on the light of lamps, lanterns and TVs.
static func create(kind: StringName, rng: RandomNumberGenerator, lit: bool = false) -> RigidBody3D:
	if not RECIPES.has(kind):
		push_error("PropFactory: unknown prop kind '%s'" % kind)
		return null
	var recipe: Dictionary = RECIPES[kind]
	var fit: Dictionary = (recipe["fit"] as Dictionary).duplicate()
	fit["fallback_size"] = recipe["size"]
	if not fit.has("tint"):
		fit["tint"] = HOUSE_TINT
	var mass: float = recipe["mass"]

	# Per-kind variation.
	match kind:
		&"box":
			var size := Vector3(rng.randf_range(0.38, 0.7), rng.randf_range(0.3, 0.55), rng.randf_range(0.38, 0.6))
			fit["stretch"] = size
			fit["fallback_size"] = size
			fit["rotate_y"] = 90.0 * float(rng.randi() % 4)
			mass = clampf(size.x * size.y * size.z * 26.0, 1.4, 5.0)
		&"book":
			fit["part"] = "book_encyclopedia_set_01_book%02d" % (1 + rng.randi() % BOOK_PARTS)
			fit["tint"] = BOOK_COLORS[rng.randi() % BOOK_COLORS.size()].lerp(Color.WHITE, 0.45)
		&"bottle":
			fit["part"] = BOTTLE_PARTS[rng.randi() % BOTTLE_PARTS.size()]
		&"spray_can":
			fit["part"] = SPRAY_PARTS[rng.randi() % SPRAY_PARTS.size()]
		&"goblet":
			fit["part"] = GOBLET_PARTS[rng.randi() % GOBLET_PARTS.size()]

	var body := _body(recipe["label"], mass, recipe["friction"], recipe["bounce"], recipe.get("damp", 0.35))
	var model := ModelLoader.instance(recipe["model"], fit)
	model.name = "Model"
	body.add_child(model)
	_fit_collider(body, model, recipe)

	match kind:
		&"lamp":
			_dress_floor_lamp(body, model, lit)
		&"lantern", &"oil_lantern":
			if lit:
				_add_lantern_light(body, model)
		&"tv":
			if lit:
				_add_tv_glow(body, model)
		&"bookshelf":
			_fill_bookshelf(body, model, rng)
	return body


# --- Colliders ---------------------------------------------------------------

static func _fit_collider(body: RigidBody3D, model: Node3D, recipe: Dictionary) -> void:
	var shape: StringName = recipe["shape"]
	if shape == SEAT:
		# Seat block plus backrest slab, so things can rest on the cushion and
		# the chair still snags on door frames by its back.
		var seat: float = recipe["seat"]
		var back: float = recipe["back"]
		ModelLoader.add_box_fraction(body, model, Vector3(0.02, 0.0, 0.0), Vector3(0.98, seat, 1.0))
		ModelLoader.add_box_fraction(body, model, Vector3(0.04, seat, 1.0 - back), Vector3(0.96, 1.0, 1.0))
	elif shape == CONVEX:
		ModelLoader.add_collision(body, model, ModelLoader.Collision.CONVEX)
	else:
		var collider := ModelLoader.add_collision(body, model, ModelLoader.Collision.BOX, 0.004)
		# Paper-thin things (picture frames) still need something to stand on.
		var box := collider.shape as BoxShape3D
		if box:
			box.size = box.size.max(Vector3.ONE * 0.045)


static func _body(display_name: String, body_mass: float, friction: float, bounce: float, angular_damping: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = display_name.replace(" ", "").replace("-", "")
	body.mass = body_mass
	var surface := PhysicsMaterial.new()
	surface.friction = friction
	surface.bounce = bounce
	body.physics_material_override = surface
	body.collision_layer = GameState.LAYER_PROP
	body.collision_mask = GameState.LAYER_WORLD | GameState.LAYER_PLAYER | GameState.LAYER_PROP | GameState.LAYER_INTERACT | GameState.LAYER_DEMON
	body.linear_damp = 0.05
	body.angular_damp = angular_damping
	# Small, fast things are the ones that would tunnel through a wall when thrown.
	body.continuous_cd = body_mass < 4.0
	body.add_to_group(GameState.GROUP_GRABBABLE)
	body.set_meta(&"display_name", display_name)
	return body


# --- Dressing ----------------------------------------------------------------

## Weighted base so the lamp stands on its own but topples when clipped, plus its bulb.
static func _dress_floor_lamp(body: RigidBody3D, model: Node3D, lit: bool) -> void:
	var bounds := ModelLoader.get_aabb(model)
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = Vector3(0.0, bounds.size.y * 0.16, 0.0)
	if not lit:
		return
	var glow_material := Mats.glow(Color(1.0, 0.72, 0.42), 2.2, true)
	var bulb := SphereMesh.new()
	bulb.radius = 0.05
	bulb.height = 0.1
	var bulb_instance := MeshInstance3D.new()
	bulb_instance.mesh = bulb
	bulb_instance.material_override = glow_material
	bulb_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bulb_instance.position = Vector3(0.0, bounds.size.y * 0.86, 0.0)
	body.add_child(bulb_instance)
	var light := OmniLight3D.new()
	light.name = "Bulb"
	light.position = Vector3(0.0, bounds.size.y * 0.84, 0.0)
	light.light_color = Color(1.0, 0.70, 0.40)
	light.omni_range = 7.5
	light.omni_attenuation = 1.4
	light.shadow_enabled = true
	light.shadow_bias = 0.08
	light.shadow_normal_bias = 1.5
	light.light_volumetric_fog_energy = 1.2
	body.add_child(light)
	_add_flicker(light, 2.4, 0.35, 5.0, 0.12, glow_material, 2.2)


static func _add_lantern_light(body: RigidBody3D, model: Node3D) -> void:
	var bounds := ModelLoader.get_aabb(model)
	var flame := Mats.glow(Color(1.0, 0.62, 0.22), 4.0, true)
	var wick := SphereMesh.new()
	wick.radius = 0.018
	wick.height = 0.06
	var wick_instance := MeshInstance3D.new()
	wick_instance.mesh = wick
	wick_instance.material_override = flame
	wick_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wick_instance.position = Vector3(0.0, bounds.size.y * 0.45, 0.0)
	body.add_child(wick_instance)
	var light := OmniLight3D.new()
	light.name = "Flame"
	light.position = Vector3(0.0, bounds.size.y * 0.5, 0.0)
	light.light_color = Color(1.0, 0.60, 0.26)
	light.omni_range = 4.5
	light.omni_attenuation = 1.5
	light.light_volumetric_fog_energy = 0.8
	body.add_child(light)
	_add_flicker(light, 1.1, 0.5, 8.0, 0.0, flame, 4.0)


## Cold, stuttering screen glow in front of the set.
static func _add_tv_glow(body: RigidBody3D, model: Node3D) -> void:
	var bounds := ModelLoader.get_aabb(model)
	var screen_material := Mats.glow(Color(0.55, 0.70, 0.95), 1.4, true)
	screen_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	screen_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	screen_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	screen_material.albedo_color = Color(0.30, 0.42, 0.62, 0.55)
	var screen := QuadMesh.new()
	screen.size = Vector2(bounds.size.x * 0.56, bounds.size.y * 0.62)
	var screen_instance := MeshInstance3D.new()
	screen_instance.mesh = screen
	screen_instance.material_override = screen_material
	screen_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	screen_instance.position = Vector3(-bounds.size.x * 0.1, bounds.size.y * 0.52, bounds.position.z - 0.004)
	screen_instance.rotation.y = PI
	body.add_child(screen_instance)
	var light := OmniLight3D.new()
	light.name = "ScreenGlow"
	light.position = Vector3(0.0, bounds.size.y * 0.55, bounds.position.z - 0.45)
	light.light_color = Color(0.50, 0.66, 1.0)
	light.omni_range = 5.0
	light.omni_attenuation = 1.6
	light.light_volumetric_fog_energy = 0.6
	body.add_child(light)
	_add_flicker(light, 1.3, 0.75, 22.0, 0.0, screen_material, 1.4)


## Rows of real encyclopedia volumes on the shelves; they ride along if the case is toppled.
static func _fill_bookshelf(body: RigidBody3D, model: Node3D, rng: RandomNumberGenerator) -> void:
	if ModelLoader.is_fallback(model) or not ModelLoader.has_model("props/book_set"):
		return
	var bounds := ModelLoader.get_aabb(model)
	var shelves := 6
	var usable := bounds.size.x * 0.8
	for shelf in shelves:
		if rng.randf() < 0.22:
			continue
		var row := ModelLoader.instance("props/book_set", {
			"fit_height": bounds.size.y * 0.115,
			"rotate_y": 180.0,
			"tint": BOOK_COLORS[rng.randi() % BOOK_COLORS.size()].lerp(Color.WHITE, 0.5) * HOUSE_TINT,
			"shadows": false,
		})
		var row_bounds := ModelLoader.get_aabb(row)
		var slack := maxf(0.0, usable - row_bounds.size.x)
		row.position = Vector3(rng.randf_range(-0.5, 0.5) * slack, bounds.size.y * (0.055 + 0.151 * float(shelf)), bounds.size.z * 0.05)
		body.add_child(row)


static func _add_flicker(light: Light3D, energy: float, amount: float, speed: float, dropout_rate: float,
		glow_material: StandardMaterial3D, glow_energy: float) -> void:
	var flicker := FlickerLight.new()
	flicker.base_energy = energy
	flicker.flicker_amount = amount
	flicker.speed = speed
	flicker.dropout_rate = dropout_rate
	flicker.glow_material = glow_material
	flicker.glow_energy = glow_energy
	light.light_energy = energy
	light.add_child(flicker)
