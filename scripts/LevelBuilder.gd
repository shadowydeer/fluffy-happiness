extends Node3D
## Procedurally assembles the whole site from real assets: the fenced, overgrown
## yard with the extraction van, and the cursed house (porch, living room,
## hallway, raised study and ritual room) with its trim, lighting, occult
## markings and physics clutter.
##
## Geometry that has to line up exactly (walls, floors, openings, stairs) is
## still generated here, now skinned with CC0 PBR texture sets. Everything with
## a recognisable shape (furniture, lamps, trees, rocks, signs) is a .glb placed
## through `ModelLoader`.
##
## World layout: +X is east, -Z is north. The street runs along the south edge,
## the house sits to the north and its front door faces south.

const Mats := preload("res://scripts/MaterialLibrary.gd")
const Occult := preload("res://scripts/OccultMarkings.gd")
const PropFactory := preload("res://scripts/PropFactory.gd")
const ExtractionVan := preload("res://scripts/ExtractionVan.gd")
const HingedDoor := preload("res://scripts/HingedDoor.gd")
const FlickerLight := preload("res://scripts/FlickerLight.gd")

const LAYOUT_SEED := 1313

## Height of the house floor and porch deck above the lawn.
const FLOOR_Y := 0.45
const WALL_HEIGHT := 3.4
const WALL_THICKNESS := 0.3
const DOOR_WIDTH := 2.4
const DOOR_HEIGHT := 2.5
## The study is a split level reached by a short flight of steps.
const STUDY_RAISE := 0.45

const HOUSE_WEST := -10.0
const HOUSE_EAST := 10.0
const HOUSE_NORTH := -24.0
const HOUSE_SOUTH := -4.0
const RITUAL_SPLIT := -15.0
const HALL_WEST := 0.0
const HALL_EAST := 4.0
const FRONT_DOOR_X := -4.0
const DAIS_CENTER := Vector3(0.0, FLOOR_Y, -19.5)
const DAIS_HEIGHT := 0.4

const YARD_WEST := -17.0
const YARD_EAST := 17.0
const YARD_NORTH := -29.0
const YARD_SOUTH := 13.6
const GATE_WEST := 2.0
const GATE_EAST := 7.0
const PATH_GAP_WEST := -4.9
const PATH_GAP_EAST := -3.1

## Direction the moonlight travels (from the south-west, 35 degrees up).
const MOON_DIRECTION := Vector3(0.5774, -0.5774, -0.5774)
const MOON_COLOR := Color(0.55, 0.68, 1.0)
const LAMP_COLOR := Color(1.0, 0.70, 0.40)
const VAN_POSITION := Vector3(4.5, 0.0, 5.0)
## Scanned assets are pulled this far toward the night palette.
const DECOR_TINT := Color(0.78, 0.76, 0.74)
const TREE_TINT := Color(0.50, 0.50, 0.54)

var player_spawn := Transform3D(Basis.IDENTITY, Vector3(1.2, 0.1, 7.5))
var van: ExtractionVan
var front_doors: Array[HingedDoor] = []
var interior_doors: Array[HingedDoor] = []
## Where Main parks the idle crew: stood around the back of the van.
var squad_spots: Array[Transform3D] = []
var prop_count := 0

var _rng := RandomNumberGenerator.new()
var _grounds: StaticBody3D
var _house: StaticBody3D
var _decor: Node3D
var _lights: Node3D
var _props: Node3D
var _chalk: StandardMaterial3D
var _blood: StandardMaterial3D
var _flame_mesh: QuadMesh


func _ready() -> void:
	build()


func build() -> void:
	_rng.seed = LAYOUT_SEED
	_grounds = _new_body("Grounds")
	_house = _new_body("House")
	_decor = _new_group("Decor")
	_lights = _new_group("Lights")
	_props = _new_group("Props")
	_chalk = Occult.chalk_material(Color(0.86, 0.86, 0.80), 0.22)
	_blood = Occult.chalk_material(Color(0.75, 0.08, 0.05), 0.9)
	_build_grounds()
	_build_fence()
	_build_yard_dressing()
	_build_treeline()
	_build_house_shell()
	_build_roof()
	_build_porch()
	_build_living_room()
	_build_hallway()
	_build_study()
	_build_ritual_room()
	_build_van()
	_build_van_area()
	_build_triggers()
	_spawn_props()


# =============================================================================
# Yard
# =============================================================================

func _build_grounds() -> void:
	# One wide slab of dead grass and soil, so the treeline beyond the fence has ground under it.
	_span(_grounds, -80.0, 80.0, -1.0, 0.0, -85.0, 75.0, Mats.grass())
	# Street, kerbs, driveway and footpaths are thin overlays on the slab.
	_span(_grounds, -80.0, 80.0, 0.0, 0.02, 14.0, 26.0, Mats.asphalt(), false)
	_span(_grounds, -80.0, 80.0, 0.0, 0.07, 13.62, 14.0, Mats.concrete(), false)
	_span(_grounds, -80.0, 80.0, 0.0, 0.07, 26.0, 26.38, Mats.concrete(), false)
	_span(_grounds, 2.2, 6.8, 0.0, 0.025, -1.6, 13.62, Mats.gravel(), false)
	_span(_grounds, FRONT_DOOR_X - 0.9, FRONT_DOOR_X + 0.9, 0.0, 0.022, -0.3, 13.62, Mats.concrete(), false)
	_span(_grounds, FRONT_DOOR_X + 0.9, 2.2, 0.0, 0.02, 2.4, 3.8, Mats.concrete(), false)
	var paint := Mats.solid(Color(0.55, 0.50, 0.24), 0.7)
	var dash_x := -42.0
	while dash_x < 43.0:
		_span(_grounds, dash_x, dash_x + 2.0, 0.02, 0.024, 19.9, 20.1, paint, false)
		dash_x += 5.0

	# Invisible playfield bounds, taller than anything can be thrown.
	_collider_span(_grounds, -17.2, -16.9, 0.0, 9.0, -29.2, 23.0)
	_collider_span(_grounds, 16.9, 17.2, 0.0, 9.0, -29.2, 23.0)
	_collider_span(_grounds, -17.2, 17.2, 0.0, 9.0, -29.2, -28.9)
	_collider_span(_grounds, -17.2, 17.2, 0.0, 9.0, 22.6, 23.0)

	# Knee-high ground mist hugging the lawn (visible with volumetric fog).
	var mist := FogVolume.new()
	mist.name = "GroundMist"
	mist.size = Vector3(46.0, 1.8, 54.0)
	mist.position = Vector3(0.0, 0.9, -5.0)
	var mist_material := FogMaterial.new()
	mist_material.density = 0.05
	mist_material.albedo = Color(0.62, 0.70, 0.82)
	mist_material.height_falloff = 2.2
	mist_material.edge_fade = 0.3
	mist.material = mist_material
	_decor.add_child(mist)


## Rusted iron railings round the plot: spear-tipped pickets, heavier posts with
## ball finials, and flat rails. The front run leaves the driveway gate and the
## footpath open.
func _build_fence() -> void:
	var iron := Mats.iron()
	var runs: Array = [
		[Vector3(YARD_WEST, 0.0, YARD_NORTH), Vector3(YARD_WEST, 0.0, YARD_SOUTH)],
		[Vector3(YARD_EAST, 0.0, YARD_NORTH), Vector3(YARD_EAST, 0.0, YARD_SOUTH)],
		[Vector3(YARD_WEST, 0.0, YARD_NORTH), Vector3(YARD_EAST, 0.0, YARD_NORTH)],
		[Vector3(YARD_WEST, 0.0, YARD_SOUTH), Vector3(PATH_GAP_WEST, 0.0, YARD_SOUTH)],
		[Vector3(PATH_GAP_EAST, 0.0, YARD_SOUTH), Vector3(GATE_WEST - 0.3, 0.0, YARD_SOUTH)],
		[Vector3(GATE_EAST + 0.3, 0.0, YARD_SOUTH), Vector3(YARD_EAST, 0.0, YARD_SOUTH)],
	]
	var pickets: Array[Transform3D] = []
	var posts: Array[Transform3D] = []
	for run: Array in runs:
		var from: Vector3 = run[0]
		var to: Vector3 = run[1]
		var length := from.distance_to(to)
		var direction := (to - from) / length
		var picket_count := int(length / 0.26)
		for i in range(1, picket_count):
			# A few pickets have rusted loose and lean.
			var lean := Basis.IDENTITY
			if _rng.randf() < 0.06:
				lean = Basis(direction, _rng.randf_range(-0.22, 0.22))
			pickets.append(Transform3D(lean, from + direction * (length * float(i) / float(picket_count))))
		var post_count := maxi(1, int(round(length / 2.6)))
		for i in post_count + 1:
			posts.append(Transform3D(Basis.IDENTITY, from + direction * (length * float(i) / float(post_count))))
		var along_x := absf(direction.x) > 0.5
		for rail_y: float in [0.28, 1.42]:
			var mid := (from + to) * 0.5 + Vector3.UP * rail_y
			var size := Vector3(length, 0.045, 0.02) if along_x else Vector3(0.02, 0.045, length)
			_box(_decor, mid, size, iron, false)

	_decor.add_child(_multimesh("FencePickets", _picket_mesh(), pickets, iron))
	var post_mesh := CylinderMesh.new()
	post_mesh.top_radius = 0.04
	post_mesh.bottom_radius = 0.05
	post_mesh.height = 2.0
	post_mesh.radial_segments = 8
	post_mesh.rings = 1
	var finial := SphereMesh.new()
	finial.radius = 0.075
	finial.height = 0.15
	finial.radial_segments = 10
	finial.rings = 6
	var post_bodies: Array[Transform3D] = []
	var post_tops: Array[Transform3D] = []
	for post in posts:
		post_bodies.append(post.translated(Vector3.UP * 1.0))
		post_tops.append(post.translated(Vector3.UP * 2.05))
	_decor.add_child(_multimesh("FencePosts", post_mesh, post_bodies, iron))
	_decor.add_child(_multimesh("FenceFinials", finial, post_tops, iron))

	# The side and back runs are covered by the playfield bounds; the front run needs its own.
	_collider_span(_grounds, YARD_WEST, PATH_GAP_WEST, 0.0, 1.9, YARD_SOUTH - 0.06, YARD_SOUTH + 0.06)
	_collider_span(_grounds, PATH_GAP_EAST, GATE_WEST - 0.3, 0.0, 1.9, YARD_SOUTH - 0.06, YARD_SOUTH + 0.06)
	_collider_span(_grounds, GATE_EAST + 0.3, YARD_EAST, 0.0, 1.9, YARD_SOUTH - 0.06, YARD_SOUTH + 0.06)

	# Brick gate piers with the iron gate leaves standing open into the drive.
	for pier_x: float in [GATE_WEST - 0.3, GATE_EAST + 0.3]:
		_span(_grounds, pier_x - 0.3, pier_x + 0.3, 0.0, 2.3, YARD_SOUTH - 0.3, YARD_SOUTH + 0.3, Mats.brick())
		_span(_decor, pier_x - 0.37, pier_x + 0.37, 2.3, 2.42, YARD_SOUTH - 0.37, YARD_SOUTH + 0.37, Mats.concrete(), false)
		var cap := SphereMesh.new()
		cap.radius = 0.17
		cap.height = 0.34
		_mesh(_decor, cap, Vector3(pier_x, 2.56, YARD_SOUTH), Mats.concrete())
	var leaf_options := {"fit_height": 2.25, "tint": Color(0.55, 0.52, 0.50), "grunge": 0.5}
	var left_options := leaf_options.duplicate()
	left_options["part"] = "large_iron_gate_left_door"
	var right_options := leaf_options.duplicate()
	right_options["part"] = "large_iron_gate_right_door"
	var left_leaf := _model(_decor, "yard/iron_gate", Vector3(GATE_WEST + 0.1, 0.0, YARD_SOUTH - 0.75), 78.0, left_options)
	var right_leaf := _model(_decor, "yard/iron_gate", Vector3(GATE_EAST - 0.1, 0.0, YARD_SOUTH - 0.75), -78.0, right_options)
	ModelLoader.add_collision(_grounds, left_leaf, ModelLoader.Collision.BOX)
	ModelLoader.add_collision(_grounds, right_leaf, ModelLoader.Collision.BOX)


## A thin round bar with a spear tip, as one mesh.
func _picket_mesh() -> ArrayMesh:
	var shaft := CylinderMesh.new()
	shaft.top_radius = 0.011
	shaft.bottom_radius = 0.011
	shaft.height = 1.62
	shaft.radial_segments = 5
	shaft.rings = 1
	var tip := CylinderMesh.new()
	tip.top_radius = 0.0
	tip.bottom_radius = 0.026
	tip.height = 0.16
	tip.radial_segments = 5
	tip.rings = 1
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.append_from(shaft, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.81, 0.0)))
	tool.append_from(tip, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, 1.70, 0.0)))
	return tool.commit()


func _build_yard_dressing() -> void:
	# Gnarled dead trees inside the fence.
	_tree("nature/dead_tree_a", Vector3(-12.5, 0.0, 3.5), 8.6, 20.0)
	_tree("nature/dead_tree_c", Vector3(-14.0, 0.0, -12.5), 10.5, 140.0)
	_tree("nature/dead_tree_b", Vector3(13.2, 0.0, -1.5), 7.8, 250.0)
	_tree("nature/dead_tree_a", Vector3(12.0, 0.0, 9.5), 9.4, 95.0)
	_tree("nature/dead_tree_b", Vector3(-8.5, 0.0, 10.0), 7.0, 310.0)
	_tree("nature/dead_tree_c", Vector3(13.8, 0.0, -20.5), 11.0, 15.0)
	_tree("nature/dead_tree_a", Vector3(-13.5, 0.0, -24.5), 9.0, 200.0)

	# Stump, a fallen trunk and snapped branches.
	var stump := _model(_decor, "nature/tree_stump", Vector3(-10.6, 0.0, 7.4), 40.0, {"fit_width": 1.3, "tint": TREE_TINT})
	ModelLoader.add_collision(_grounds, stump, ModelLoader.Collision.CONVEX)
	var trunk := _model(_decor, "nature/fallen_log", Vector3(10.2, 0.0, -2.6), 28.0, {"fit_width": 4.6, "tint": TREE_TINT})
	ModelLoader.add_collision(_grounds, trunk, ModelLoader.Collision.BOX)
	var branch_parts := ["dry_branches_medium_01_a", "dry_branches_medium_01_b", "dry_branches_medium_01_c"]
	var branch_spots := [Vector3(-9.6, 0.0, 1.6), Vector3(11.0, 0.0, 5.4), Vector3(-13.0, 0.0, -6.0), Vector3(8.8, 0.0, -12.5), Vector3(-11.2, 0.0, 11.6)]
	for i in branch_spots.size():
		_model(_decor, "nature/dry_branches", branch_spots[i], _rng.randf() * 360.0, {"part": branch_parts[i % 3], "scale": 1.7, "tint": TREE_TINT})

	# Leafless shrubs along the house and in the fence corners.
	var shrub_parts := ["shrub_02_a", "shrub_02_b", "shrub_02_c", "shrub_02_d"]
	var shrub_spots := [
		Vector3(-9.1, 0.0, -3.1), Vector3(1.4, 0.0, -3.0), Vector3(5.2, 0.0, -3.2), Vector3(8.7, 0.0, -3.0),
		Vector3(-15.6, 0.0, 11.6), Vector3(15.5, 0.0, 12.0), Vector3(-15.8, 0.0, -4.5), Vector3(15.6, 0.0, -12.0),
		Vector3(-11.4, 0.0, -17.0), Vector3(11.6, 0.0, -26.5), Vector3(-2.0, 0.0, -26.8),
	]
	for i in shrub_spots.size():
		_model(_decor, "nature/dead_bushes", shrub_spots[i], _rng.randf() * 360.0,
				{"part": shrub_parts[i % 4], "fit_height": _rng.randf_range(1.1, 1.9), "tint": Color(0.46, 0.44, 0.40)})
	var scrub_parts := ["wild_rooibos_bush_a", "wild_rooibos_bush_b", "wild_rooibos_bush_c", "wild_rooibos_bush_d", "wild_rooibos_bush_e"]
	for i in 16:
		var spot := _yard_spot(0.8)
		_model(_decor, "nature/dry_bushes", spot, _rng.randf() * 360.0,
				{"part": scrub_parts[i % 5], "fit_height": _rng.randf_range(0.45, 0.8), "tint": Color(0.50, 0.46, 0.40), "shadows": false})
	var fern_parts := ["fern_02_a", "fern_02_b", "fern_02_c", "fern_02_d"]
	var fern_spots := [Vector3(-10.5, 0.0, -6.0), Vector3(-10.6, 0.0, -13.5), Vector3(10.6, 0.0, -9.0), Vector3(10.5, 0.0, -17.5),
		Vector3(-7.9, 0.0, -1.0), Vector3(0.2, 0.0, -1.7), Vector3(9.4, 0.0, -3.6), Vector3(-10.4, 0.0, -21.0)]
	for i in fern_spots.size():
		_model(_decor, "nature/fern", fern_spots[i], _rng.randf() * 360.0,
				{"part": fern_parts[i % 4], "fit_width": _rng.randf_range(0.8, 1.2), "tint": Color(0.42, 0.50, 0.40), "shadows": false})

	# Boulders and loose stones.
	var boulder_parts := ["rock_moss_set_01_rock01", "rock_moss_set_01_rock02", "rock_moss_set_01_rock03", "rock_moss_set_01_rock04", "rock_moss_set_01_rock05", "rock_moss_set_01_rock06"]
	var boulder_spots := [Vector3(-13.4, 0.0, 8.6), Vector3(10.6, 0.0, 12.0), Vector3(-15.0, 0.0, -20.0), Vector3(14.6, 0.0, -8.0), Vector3(-7.4, 0.0, 12.4), Vector3(14.2, 0.0, 3.4)]
	for i in boulder_spots.size():
		var boulder := _model(_decor, "nature/rock_set", boulder_spots[i], _rng.randf() * 360.0,
				{"part": boulder_parts[i], "fit_longest": _rng.randf_range(1.0, 1.7), "tint": Color(0.52, 0.52, 0.55)})
		ModelLoader.add_collision(_grounds, boulder, ModelLoader.Collision.CONVEX)
	for i in 14:
		var model_name := "nature/rock_a" if i % 2 == 0 else "nature/rock_b"
		_model(_decor, model_name, _yard_spot(0.6), _rng.randf() * 360.0,
				{"fit_longest": _rng.randf_range(0.18, 0.4), "tint": Color(0.50, 0.50, 0.53), "shadows": false})

	# Tufts of dead grass, drawn as one batch.
	var tufts: Array[Transform3D] = []
	for i in 420:
		var spot := _yard_spot(0.35)
		var basis := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * _rng.randf_range(0.6, 1.5))
		tufts.append(Transform3D(basis, spot))
	# A thicker fringe along the fence and the house footing, where nobody mows.
	for i in 160:
		var edge := _rng.randi() % 4
		var along := _rng.randf()
		var spot := Vector3.ZERO
		if edge == 0:
			spot = Vector3(YARD_WEST + _rng.randf_range(0.2, 1.1), 0.0, lerpf(YARD_NORTH, YARD_SOUTH, along))
		elif edge == 1:
			spot = Vector3(YARD_EAST - _rng.randf_range(0.2, 1.1), 0.0, lerpf(YARD_NORTH, YARD_SOUTH, along))
		elif edge == 2:
			spot = Vector3(lerpf(YARD_WEST, YARD_EAST, along), 0.0, YARD_NORTH + _rng.randf_range(0.2, 1.1))
		else:
			spot = Vector3(lerpf(HOUSE_WEST - 0.9, HOUSE_EAST + 0.9, along), 0.0, HOUSE_NORTH - _rng.randf_range(0.3, 1.0))
		tufts.append(Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * _rng.randf_range(0.9, 1.7)), spot))
	_decor.add_child(ModelLoader.scatter("nature/tall_grass", tufts,
			{"fit_height": 0.42, "tint": Color(0.52, 0.50, 0.36), "shadows": false, "visibility_range": 38.0}))

	_street_lamp(Vector3(-10.0, 0.0, 14.4))
	_mailbox(Vector3(1.2, 0.0, 14.25))
	_for_sale_sign(Vector3(-7.4, 0.0, 6.5))

	# Somebody's car, abandoned at the kerb under a tarp.
	var car := _model(_decor, "yard/covered_car", Vector3(-13.5, 0.0, 15.6), 86.0, {"fit_depth": 4.4, "tint": Color(0.60, 0.62, 0.66)})
	ModelLoader.add_collision(_grounds, car, ModelLoader.Collision.BOX, 0.12)


## A random spot on the lawn that is clear of the house, porch, drive, paths and van.
func _yard_spot(margin: float) -> Vector3:
	for attempt in 40:
		var x := _rng.randf_range(YARD_WEST + 0.6, YARD_EAST - 0.6)
		var z := _rng.randf_range(YARD_NORTH + 0.6, YARD_SOUTH - 0.6)
		if x > HOUSE_WEST - 0.4 - margin and x < HOUSE_EAST + 0.4 + margin and z > HOUSE_NORTH - 0.4 - margin and z < HOUSE_SOUTH + 0.4 + margin:
			continue
		if x > FRONT_DOOR_X - 3.9 - margin and x < FRONT_DOOR_X + 3.9 + margin and z > HOUSE_SOUTH - margin and z < 0.2 + margin:
			continue
		if x > 1.4 - margin and x < 9.8 + margin and z > -1.9 - margin:
			continue
		if x > FRONT_DOOR_X - 1.2 - margin and x < FRONT_DOOR_X + 1.2 + margin and z > -0.6:
			continue
		if x > -8.0 - margin and x < 2.4 and z > 1.4 - margin and z < 5.2 + margin:
			continue
		return Vector3(x, 0.0, z)
	return Vector3(YARD_WEST + 1.5, 0.0, YARD_NORTH + 1.5)


func _tree(model: String, at: Vector3, height: float, yaw: float) -> void:
	_model(_decor, model, at, yaw, {"fit_height": height, "tint": TREE_TINT})
	_collider_span(_grounds, at.x - 0.24, at.x + 0.24, 0.0, minf(height, 6.0), at.z - 0.24, at.z + 0.24)


## Ranks of pines and dead trees beyond the fence and across the street, so
## the plot is surrounded by forest instead of an empty horizon.
func _build_treeline() -> void:
	var pines_a: Array[Transform3D] = []
	var pines_b: Array[Transform3D] = []
	var snags: Array[Transform3D] = []
	var count := 0
	for attempt in 900:
		if count >= 150:
			break
		var x := _rng.randf_range(-62.0, 62.0)
		var z := _rng.randf_range(-70.0, 60.0)
		# Keep the plot and the street corridor clear.
		if x > YARD_WEST - 2.5 and x < YARD_EAST + 2.5 and z > YARD_NORTH - 2.5 and z < 27.5:
			continue
		if z > 12.0 and z < 27.5:
			continue
		var basis := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * _rng.randf_range(0.75, 1.5))
		var placed := Transform3D(basis, Vector3(x, 0.0, z))
		var pick := _rng.randf()
		if pick < 0.42:
			pines_a.append(placed)
		elif pick < 0.84:
			pines_b.append(placed)
		else:
			snags.append(placed)
		count += 1
	var forest := Color(0.26, 0.30, 0.30)
	_decor.add_child(ModelLoader.scatter("nature/pine_a", pines_a, {"fit_height": 10.5, "tint": forest, "shadows": false}))
	_decor.add_child(ModelLoader.scatter("nature/pine_b", pines_b, {"fit_height": 12.5, "tint": forest, "shadows": false}))
	_decor.add_child(ModelLoader.scatter("nature/dead_tree_b", snags, {"fit_height": 9.0, "tint": Color(0.36, 0.36, 0.40), "shadows": false}))


func _street_lamp(at: Vector3) -> void:
	var lamp := _model(_decor, "lighting/street_lamp", at, 0.0, {"fit_height": 4.3, "tint": Color(0.6, 0.6, 0.62), "grunge": 0.4})
	var bounds := ModelLoader.get_aabb(lamp)
	_collider_span(_grounds, at.x - 0.1, at.x + 0.1, 0.0, bounds.size.y, at.z - 0.1, at.z + 0.1)
	var lens := Mats.glow(Color(1.0, 0.62, 0.25), 5.0, true)
	var bulb := SphereMesh.new()
	bulb.radius = 0.07
	bulb.height = 0.16
	var head := at + Vector3(0.0, bounds.size.y * 0.885, 0.0)
	_mesh(_decor, bulb, head, lens).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var light := OmniLight3D.new()
	light.name = "StreetLamp"
	light.position = head
	light.light_color = Color(1.0, 0.62, 0.25)
	light.light_volumetric_fog_energy = 1.6
	light.omni_range = 13.0
	light.omni_attenuation = 1.3
	light.shadow_enabled = true
	light.shadow_bias = 0.1
	light.shadow_normal_bias = 1.5
	_lights.add_child(light)
	_add_flicker(light, 4.5, 0.25, 7.0, 0.25, lens, 5.0)


func _mailbox(at: Vector3) -> void:
	var box := _model(_decor, "yard/mailbox", at, 180.0, {"fit_height": 1.25, "tint": DECOR_TINT, "grunge": 0.6})
	ModelLoader.add_collision(_grounds, box, ModelLoader.Collision.BOX)
	var bounds := ModelLoader.get_aabb(box)
	_label(_decor, "13", 40, at + Vector3(bounds.size.x * 0.5 + 0.004, bounds.size.y * 0.86, 0.0), PI * 0.5, Color(0.92, 0.9, 0.82))


func _for_sale_sign(at: Vector3) -> void:
	var sign := _model(_decor, "yard/sign_board", at, 0.0, {"fit_height": 1.9, "tint": Color(0.72, 0.68, 0.62), "grunge": 0.5})
	ModelLoader.add_collision(_grounds, sign, ModelLoader.Collision.BOX)
	var bounds := ModelLoader.get_aabb(sign)
	var face := at + Vector3(0.0, 0.0, 0.05)
	_label(_decor, "FOR SALE", 76, face + Vector3(0.0, bounds.size.y * 0.57, 0.0), 0.0, Color(0.50, 0.06, 0.04))
	_label(_decor, "MOTIVATED SELLER", 28, face + Vector3(0.0, bounds.size.y * 0.44, 0.0), 0.0, Color(0.10, 0.09, 0.08))
	_label(_decor, "(mildly haunted)", 24, face + Vector3(0.0, bounds.size.y * 0.36, 0.0), 0.0, Color(0.10, 0.09, 0.08))


# =============================================================================
# House shell
# =============================================================================

## Wall face that looks into a room standing on `floor_y`.
func _room_side(material: Material, floor_y: float, extras: Dictionary = {}) -> Dictionary:
	var side := {"mat": material, "floor": floor_y, "interior": true}
	side.merge(extras)
	return side


## Wall face that looks outdoors.
func _outside(material: Material) -> Dictionary:
	return {"mat": material, "floor": FLOOR_Y, "interior": false}


func _build_house_shell() -> void:
	var edge := WALL_THICKNESS * 0.5
	var study_y := FLOOR_Y + STUDY_RAISE
	var siding := _outside(Mats.siding())
	var living := _room_side(Mats.wallpaper_green(FLOOR_Y), FLOOR_Y)
	var hall := _room_side(Mats.wallpaper_hall(FLOOR_Y), FLOOR_Y, {"wainscot": 1.05})
	var study := _room_side(Mats.wallpaper_ochre(study_y), study_y)
	var ritual := _room_side(Mats.wall_stone(), FLOOR_Y, {"trim": false})

	# Floors, one slab per room so each can carry its own surface.
	_span(_house, HOUSE_WEST - edge, HALL_WEST, 0.0, FLOOR_Y, RITUAL_SPLIT, HOUSE_SOUTH + edge, Mats.floor_wood())
	_span(_house, HALL_WEST, HALL_EAST - edge, 0.0, FLOOR_Y, RITUAL_SPLIT, HOUSE_SOUTH + edge, Mats.floor_hall())
	_span(_house, HALL_EAST - edge, HOUSE_EAST + edge, 0.0, study_y, RITUAL_SPLIT, HOUSE_SOUTH + edge, Mats.floor_wood())
	_span(_house, HOUSE_WEST - edge, HOUSE_EAST + edge, 0.0, FLOOR_Y, HOUSE_NORTH - edge, RITUAL_SPLIT, Mats.floor_stone())
	# Brick footing under the clapboard, with a drip board where they meet.
	var footing := Mats.brick()
	var sill := Mats.trim_painted()
	var footing_top := FLOOR_Y + 0.06
	_span(_decor, HOUSE_WEST - edge - 0.07, HOUSE_EAST + edge + 0.07, 0.0, footing_top, HOUSE_SOUTH + edge, HOUSE_SOUTH + edge + 0.07, footing, false)
	_span(_decor, HOUSE_WEST - edge - 0.07, HOUSE_EAST + edge + 0.07, 0.0, footing_top, HOUSE_NORTH - edge - 0.07, HOUSE_NORTH - edge, footing, false)
	_span(_decor, HOUSE_WEST - edge - 0.07, HOUSE_WEST - edge, 0.0, footing_top, HOUSE_NORTH - edge, HOUSE_SOUTH + edge, footing, false)
	_span(_decor, HOUSE_EAST + edge, HOUSE_EAST + edge + 0.07, 0.0, footing_top, HOUSE_NORTH - edge, HOUSE_SOUTH + edge, footing, false)
	_span(_decor, HOUSE_WEST - edge - 0.1, HOUSE_EAST + edge + 0.1, footing_top, footing_top + 0.05, HOUSE_SOUTH + edge, HOUSE_SOUTH + edge + 0.1, sill, false)
	_span(_decor, HOUSE_WEST - edge - 0.1, HOUSE_EAST + edge + 0.1, footing_top, footing_top + 0.05, HOUSE_NORTH - edge - 0.1, HOUSE_NORTH - edge, sill, false)
	_span(_decor, HOUSE_WEST - edge - 0.1, HOUSE_WEST - edge, footing_top, footing_top + 0.05, HOUSE_NORTH - edge, HOUSE_SOUTH + edge, sill, false)
	_span(_decor, HOUSE_EAST + edge, HOUSE_EAST + edge + 0.1, footing_top, footing_top + 0.05, HOUSE_NORTH - edge, HOUSE_SOUTH + edge, sill, false)
	# Corner boards.
	for corner_x: float in [HOUSE_WEST - edge, HOUSE_EAST + edge]:
		for corner_z: float in [HOUSE_NORTH - edge, HOUSE_SOUTH + edge]:
			_span(_decor, corner_x - 0.07, corner_x + 0.07, footing_top, FLOOR_Y + WALL_HEIGHT + 0.2, corner_z - 0.07, corner_z + 0.07, sill, false)

	# Stained plaster ceiling.
	var ceiling_y := FLOOR_Y + WALL_HEIGHT
	_span(_house, HOUSE_WEST - edge, HOUSE_EAST + edge, ceiling_y, ceiling_y + 0.25, HOUSE_NORTH - edge, HOUSE_SOUTH + edge, Mats.plaster())

	# --- Exterior walls (split per room so each interior face gets its own finish).
	_wall(true, HOUSE_SOUTH, HOUSE_WEST - edge, HALL_WEST, living, siding, [
		{"at": -8.2, "width": 1.5, "bottom": 0.95, "top": 2.45, "window": true},
		{"at": FRONT_DOOR_X, "width": DOOR_WIDTH, "top": DOOR_HEIGHT},
		{"at": -1.4, "width": 1.3, "bottom": 0.95, "top": 2.45, "window": true},
	])
	_wall(true, HOUSE_SOUTH, HALL_WEST, HALL_EAST, hall, siding, [
		{"at": 2.0, "width": 1.2, "bottom": 1.1, "top": 2.5, "window": true, "boarded": true},
	])
	_wall(true, HOUSE_SOUTH, HALL_EAST, HOUSE_EAST + edge, study, siding, [
		{"at": 7.0, "width": 1.8, "bottom": 1.35, "top": 2.9, "window": true},
	])
	_wall(true, HOUSE_NORTH, HOUSE_WEST - edge, HOUSE_EAST + edge, siding, ritual, [
		{"at": -5.5, "width": 1.6, "bottom": 0.9, "top": 2.9, "window": true},
		{"at": 5.5, "width": 1.6, "bottom": 0.9, "top": 2.9, "window": true},
	])
	_wall(false, HOUSE_WEST, HOUSE_NORTH, RITUAL_SPLIT, siding, ritual, [
		{"at": -19.5, "width": 1.6, "bottom": 0.9, "top": 2.9, "window": true},
	])
	_wall(false, HOUSE_WEST, RITUAL_SPLIT, HOUSE_SOUTH, siding, living, [
		{"at": -9.0, "width": 1.8, "bottom": 0.95, "top": 2.45, "window": true},
	])
	_wall(false, HOUSE_EAST, HOUSE_NORTH, RITUAL_SPLIT, ritual, siding, [
		{"at": -19.5, "width": 1.6, "bottom": 0.9, "top": 2.9, "window": true},
	])
	_wall(false, HOUSE_EAST, RITUAL_SPLIT, HOUSE_SOUTH, study, siding, [
		{"at": -8.5, "width": 1.8, "bottom": 1.35, "top": 2.9, "window": true, "boarded": true},
	])

	# --- Interior walls. Every doorway is wide enough to drag a thrashing demon through.
	_wall(false, HALL_WEST, RITUAL_SPLIT, HOUSE_SOUTH, living, hall, [
		{"at": -9.5, "width": DOOR_WIDTH, "top": DOOR_HEIGHT},
	])
	_wall(false, HALL_EAST, RITUAL_SPLIT, HOUSE_SOUTH, hall, study, [
		{"at": -11.5, "width": DOOR_WIDTH, "top": DOOR_HEIGHT + STUDY_RAISE},
	])
	_wall(true, RITUAL_SPLIT, HOUSE_WEST, HALL_WEST, ritual, living, [
		{"at": -6.2, "width": 2.2, "top": DOOR_HEIGHT},
	])
	_wall(true, RITUAL_SPLIT, HALL_WEST, HALL_EAST, ritual, hall, [
		{"at": 2.0, "width": 2.6, "top": DOOR_HEIGHT + 0.2},
	])
	_wall(true, RITUAL_SPLIT, HALL_EAST, HOUSE_EAST, ritual, study, [])

	# Steps up from the hallway into the study.
	_stairs(_house, Vector3(HALL_EAST - edge - 0.96, FLOOR_Y, -11.5), Vector3.RIGHT, DOOR_WIDTH, 3, 0.15, 0.32, Mats.trim_wood())

	# Paneled double doors that start open: hallway <-> living room, hallway <-> ritual room.
	_double_door("HallDoor", false, HALL_WEST, -9.5, DOOR_WIDTH, DOOR_HEIGHT, -1.0, FLOOR_Y)
	_double_door("RitualDoor", true, RITUAL_SPLIT, 2.0, 2.6, DOOR_HEIGHT + 0.2, -1.0, FLOOR_Y)


## Builds one straight wall with door and window openings cut out of it.
## `along_x` walls sit at z = `fixed` and run from x = `from` to `to`; otherwise
## the wall sits at x = `fixed` and runs along z. `neg` / `pos` describe the
## faces looking toward the negative / positive side of the fixed axis (see
## `_room_side` and `_outside`). Opening keys: at, width, bottom, top, window, boarded.
func _wall(along_x: bool, fixed: float, from: float, to: float, neg: Dictionary, pos: Dictionary, openings: Array) -> void:
	var inward := 0
	var room_floor := FLOOR_Y
	if neg["interior"] and not pos["interior"]:
		inward = -1
		room_floor = neg["floor"]
	elif pos["interior"] and not neg["interior"]:
		inward = 1
		room_floor = pos["floor"]
	var sorted := openings.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["at"] < b["at"])
	var cursor := from
	for opening: Dictionary in sorted:
		var half: float = opening["width"] * 0.5
		var start: float = opening["at"] - half
		var end: float = opening["at"] + half
		var bottom: float = opening.get("bottom", 0.0)
		var top: float = opening["top"]
		if start > cursor:
			_wall_piece(along_x, fixed, cursor, start, 0.0, WALL_HEIGHT, neg, pos)
		if bottom > 0.0:
			_wall_piece(along_x, fixed, start, end, 0.0, bottom, neg, pos)
		if top < WALL_HEIGHT:
			_wall_piece(along_x, fixed, start, end, top, WALL_HEIGHT, neg, pos)
		cursor = end
		if opening.get("window", false):
			_window(along_x, fixed, opening["at"], opening["width"], FLOOR_Y + bottom, FLOOR_Y + top, room_floor, inward, opening.get("boarded", false))
		else:
			_door_trim(along_x, fixed, opening["at"], opening["width"], FLOOR_Y + top)
	if cursor < to:
		_wall_piece(along_x, fixed, cursor, to, 0.0, WALL_HEIGHT, neg, pos)


## One rectangular chunk of wall: a single collider, a visual skin on each face,
## and (indoors) its share of baseboard, wainscot and crown moulding.
func _wall_piece(along_x: bool, fixed: float, u0: float, u1: float, v0: float, v1: float, neg: Dictionary, pos: Dictionary) -> void:
	var length := u1 - u0
	var height := v1 - v0
	var mid_u := (u0 + u1) * 0.5
	var mid_y := FLOOR_Y + (v0 + v1) * 0.5
	_aligned_box(_house, along_x, fixed, mid_u, mid_y, length, height, WALL_THICKNESS, null, true)
	var skin := WALL_THICKNESS * 0.5
	_aligned_box(_house, along_x, fixed - skin * 0.5, mid_u, mid_y, length, height, skin, neg["mat"], false)
	_aligned_box(_house, along_x, fixed + skin * 0.5, mid_u, mid_y, length, height, skin, pos["mat"], false)

	var faces: Array = [[neg, -1.0], [pos, 1.0]]
	for entry: Array in faces:
		var side: Dictionary = entry[0]
		var sign: float = entry[1]
		if not side["interior"] or not side.get("trim", true):
			continue
		var face := fixed + sign * skin
		var floor_y: float = side["floor"]
		var reaches_floor := FLOOR_Y + v0 <= floor_y + 0.001 and FLOOR_Y + v1 > floor_y + 0.35
		if reaches_floor:
			var trim := Mats.trim_wood()
			var board_base := floor_y
			if side.has("wainscot"):
				# Dark panelling to dado height, capped with a rail.
				var dado := minf(float(side["wainscot"]), FLOOR_Y + v1 - floor_y)
				_aligned_box(_decor, along_x, face + sign * 0.012, mid_u, floor_y + dado * 0.5, length, dado, 0.024, Mats.panel_wood(), false)
				if dado >= float(side["wainscot"]) - 0.001:
					_aligned_box(_decor, along_x, face + sign * 0.03, mid_u, floor_y + dado + 0.025, length, 0.05, 0.06, trim, false)
				board_base = floor_y
			# Baseboard: tall board with a rounded-over cap.
			_aligned_box(_decor, along_x, face + sign * 0.026, mid_u, board_base + 0.075, length, 0.15, 0.028, trim, false)
			_aligned_box(_decor, along_x, face + sign * 0.02, mid_u, board_base + 0.165, length, 0.03, 0.04, trim, false)
		if v1 >= WALL_HEIGHT - 0.001:
			# Crown moulding: a square section turned on edge into the ceiling corner.
			var crown := _aligned_box(_decor, along_x, face + sign * 0.035, mid_u, FLOOR_Y + WALL_HEIGHT - 0.035, length, 0.1, 0.1, Mats.trim_wood(), false)
			if along_x:
				crown.rotation.x = PI * 0.25
			else:
				crown.rotation.z = PI * 0.25
			crown.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Box positioned in wall space: `u` runs along the wall, `depth` through it.
## A null material makes it collider-only.
func _aligned_box(body: Node3D, along_x: bool, fixed: float, u: float, y: float, u_size: float, y_size: float,
		depth: float, material: Material, solid: bool) -> MeshInstance3D:
	var center := Vector3(u, y, fixed) if along_x else Vector3(fixed, y, u)
	var size := Vector3(u_size, y_size, depth) if along_x else Vector3(depth, y_size, u_size)
	if material == null:
		_collider_box(body, center, size)
		return null
	return _box(body, center, size, material, solid)


## Thick timber door casing: jambs on plinth blocks under a projecting head.
func _door_trim(along_x: bool, fixed: float, at: float, width: float, top_y: float) -> void:
	var trim := Mats.trim_wood()
	var depth := WALL_THICKNESS + 0.1
	var jamb := 0.13
	var height := top_y - FLOOR_Y
	for side: float in [-1.0, 1.0]:
		var u := at + side * (width * 0.5 - jamb * 0.5 + 0.04)
		_aligned_box(_decor, along_x, fixed, u, FLOOR_Y + height * 0.5, jamb, height, depth, trim, false)
		_aligned_box(_decor, along_x, fixed, u, FLOOR_Y + 0.11, jamb + 0.03, 0.22, depth + 0.03, trim, false)
	_aligned_box(_decor, along_x, fixed, at, top_y - 0.05, width + 0.14, 0.16, depth + 0.02, trim, false)
	_aligned_box(_decor, along_x, fixed, at, top_y + 0.05, width + 0.24, 0.05, depth + 0.08, trim, false)


## Six-pane sash window: sill, head, casing, glazing bars and a dusty pane that
## still stops thrown furniture.
func _window(along_x: bool, fixed: float, at: float, width: float, bottom_y: float, top_y: float,
		room_floor: float, inward: int, boarded: bool) -> void:
	var trim := Mats.trim_painted()
	var height := top_y - bottom_y
	var mid_y := (bottom_y + top_y) * 0.5
	var depth := WALL_THICKNESS + 0.1
	var bar := 0.08
	_aligned_box(_decor, along_x, fixed, at, bottom_y + bar * 0.5, width, bar, depth, trim, false)
	_aligned_box(_decor, along_x, fixed, at, bottom_y - 0.02, width + 0.22, 0.045, depth + 0.14, trim, false)
	_aligned_box(_decor, along_x, fixed, at, top_y - bar * 0.5, width, bar, depth, trim, false)
	_aligned_box(_decor, along_x, fixed, at, top_y + 0.04, width + 0.2, 0.07, depth + 0.06, trim, false)
	for side: float in [-1.0, 1.0]:
		_aligned_box(_decor, along_x, fixed, at + side * (width - bar) * 0.5, mid_y, bar, height, depth, trim, false)
		_aligned_box(_decor, along_x, fixed, at + side * (width * 0.5 + 0.045), mid_y, 0.09, height + 0.1, depth + 0.04, trim, false)
	# Glazing bars: one upright, two rails -> six panes.
	_aligned_box(_decor, along_x, fixed, at, mid_y, 0.035, height, 0.05, trim, false)
	for row: float in [-1.0, 1.0]:
		_aligned_box(_decor, along_x, fixed, at, mid_y + row * height / 6.0, width, 0.035, 0.05, trim, false)
	var pane := _aligned_box(_decor, along_x, fixed, at, mid_y, width, height, 0.02, Mats.glass_dusty(), false)
	pane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_aligned_box(_house, along_x, fixed, at, mid_y, width, height, 0.1, null, true)
	if inward == 0:
		return
	var inward_dir := (Vector3(0.0, 0.0, float(inward)) if along_x else Vector3(float(inward), 0.0, 0.0))
	var lateral := Vector3.RIGHT if along_x else Vector3.BACK
	var center := Vector3(at, mid_y, fixed) if along_x else Vector3(fixed, mid_y, at)
	if boarded:
		# Crooked planks nailed across the inside of the frame.
		var plank_mat := Mats.trim_wood()
		for i in 3:
			var plank := _aligned_box(_decor, along_x, fixed + float(inward) * (WALL_THICKNESS * 0.5 + 0.075), at,
					bottom_y + height * (0.22 + 0.28 * float(i)), width + 0.5, 0.17, 0.03, plank_mat, false)
			var skew := _rng.randf_range(-0.16, 0.16)
			if along_x:
				plank.rotation.z = skew
			else:
				plank.rotation.x = skew
	_moonbeam(center + inward_dir * (WALL_THICKNESS * 0.5 + 0.06), inward_dir, lateral, width - 0.18, height - 0.18, room_floor)


## Moonlight spilling through a window: a fan of additive sheets standing in for
## the light shaft, drifting dust motes, and (for windows the real moon cannot
## reach) a soft fill light pooling on the floor.
func _moonbeam(origin: Vector3, inward: Vector3, lateral: Vector3, width: float, height: float, room_floor: float) -> void:
	var moonlit := MOON_DIRECTION.dot(inward) > 0.0
	var direction := MOON_DIRECTION
	if not moonlit:
		# Mirror the moon across the wall so north and east windows still get a shaft.
		direction = MOON_DIRECTION - 2.0 * MOON_DIRECTION.dot(inward) * inward
	direction = direction.normalized()
	var drop := origin.y + height * 0.5 - room_floor
	var length := minf(drop / -direction.y, 7.5)

	# Many faint sheets, weakest at the rim, so they blend into one soft volume.
	var far := Color(MOON_COLOR.r, MOON_COLOR.g, MOON_COLOR.b, 0.0)
	var reach := direction * length
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var columns := 14
	for i in columns:
		var t := float(i) / float(columns - 1)
		var near := Color(MOON_COLOR.r, MOON_COLOR.g, MOON_COLOR.b, 0.016 * _rim_falloff(t))
		var offset := lateral * (t - 0.5) * width
		var top := origin + offset + Vector3.UP * height * 0.5
		var bottom := origin + offset - Vector3.UP * height * 0.5
		_shaft_quad(st, top, bottom, bottom + reach, top + reach, near, far)
	var rows := 12
	for i in rows:
		var t := float(i) / float(rows - 1)
		var near := Color(MOON_COLOR.r, MOON_COLOR.g, MOON_COLOR.b, 0.016 * _rim_falloff(t))
		var offset := Vector3.UP * (t - 0.5) * height
		var left := origin + offset - lateral * width * 0.5
		var right := origin + offset + lateral * width * 0.5
		_shaft_quad(st, left, right, right + reach, left + reach, near, far)
	var shaft := MeshInstance3D.new()
	shaft.name = "Moonbeam"
	shaft.mesh = st.commit()
	shaft.material_override = Mats.light_shaft()
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_lights.add_child(shaft)

	_dust(origin + reach * 0.45, Basis.looking_at(direction, Vector3.UP), Vector3(width * 0.5, height * 0.45, length * 0.42), 40,
			Color(0.80, 0.88, 1.0, 0.75))

	if not moonlit:
		var fill := SpotLight3D.new()
		fill.name = "MoonFill"
		var setback := 3.0
		fill.transform = Transform3D(Basis.looking_at(direction, Vector3.UP), origin - direction * setback)
		fill.light_color = MOON_COLOR
		fill.light_energy = 2.4
		fill.light_volumetric_fog_energy = 1.2
		fill.spot_range = setback + length + 1.5
		fill.spot_angle = rad_to_deg(atan(maxf(width, height) * 0.55 / setback))
		fill.spot_attenuation = 0.4
		fill.spot_angle_attenuation = 0.5
		_lights.add_child(fill)


## Slow-drifting dust motes (GPU particles) filling a box volume.
func _dust(at: Vector3, basis: Basis, extents: Vector3, amount: int, tint: Color) -> void:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = extents
	process.direction = Vector3(0.3, -1.0, 0.2)
	process.spread = 75.0
	process.gravity = Vector3(0.0, -0.004, 0.0)
	process.initial_velocity_min = 0.012
	process.initial_velocity_max = 0.06
	process.scale_min = 0.012
	process.scale_max = 0.032
	process.turbulence_enabled = true
	process.turbulence_noise_strength = 0.04
	process.turbulence_noise_scale = 2.5
	process.turbulence_influence_min = 0.02
	process.turbulence_influence_max = 0.08
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.25, 0.75, 1.0])
	fade.colors = PackedColorArray([Color(tint, 0.0), tint, tint, Color(tint, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	process.color_ramp = ramp
	var speck := QuadMesh.new()
	speck.size = Vector2.ONE
	speck.material = Mats.dust_mote()
	var dust := GPUParticles3D.new()
	dust.name = "DustMotes"
	dust.transform = Transform3D(basis, at)
	dust.amount = amount
	dust.lifetime = 9.0
	dust.preprocess = 9.0
	dust.randomness = 1.0
	dust.process_material = process
	dust.draw_pass_1 = speck
	dust.visibility_aabb = AABB(-extents * 1.3, extents * 2.6)
	dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_lights.add_child(dust)


## 1 in the middle of the beam's cross-section, easing to 0.25 at its edges.
func _rim_falloff(t: float) -> float:
	return lerpf(0.25, 1.0, sin(t * PI))


func _shaft_quad(st: SurfaceTool, near_a: Vector3, near_b: Vector3, far_b: Vector3, far_a: Vector3, near: Color, far: Color) -> void:
	var corners := [near_a, near_b, far_b, near_a, far_b, far_a]
	var colors := [near, near, far, near, far, far]
	for i in 6:
		st.set_color(colors[i])
		st.add_vertex(corners[i])


## Visible steps with a hidden ramp laid along their nosings, so players glide
## up and dragged bodies do not snag on every riser. `start` is the foot of the
## first riser; `ascent` is the horizontal direction of travel going up.
func _stairs(body: StaticBody3D, start: Vector3, ascent: Vector3, width: float, steps: int, rise: float, run: float, material: Material) -> void:
	var total_run := run * float(steps)
	var total_rise := rise * float(steps)
	var along_x := absf(ascent.x) > 0.5
	for i in steps:
		var near := run * float(i)
		var length := total_run - near
		var height := rise * float(i + 1)
		var center := start + ascent * (near + length * 0.5) + Vector3.UP * height * 0.5
		var size := Vector3(length, height, width) if along_x else Vector3(width, height, length)
		_box(body, center, size, material)
		# Overhanging tread nosing.
		var nose_center := start + ascent * (near - 0.015) + Vector3.UP * (height - 0.02)
		var nose_size := Vector3(0.05, 0.04, width + 0.04) if along_x else Vector3(width + 0.04, 0.04, 0.05)
		_box(_decor, nose_center, nose_size, material, false)
	var slope := ascent * total_run + Vector3.UP * total_rise
	var slope_dir := slope.normalized()
	var side := Vector3.UP.cross(ascent).normalized()
	var normal := slope_dir.cross(side).normalized()
	var thickness := 0.1
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, thickness, slope.length())
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.transform = Transform3D(Basis(side, normal, slope_dir), start - ascent * run + slope * 0.5 - normal * thickness * 0.5)
	body.add_child(collider)


## Gable roof with slate, boxed eaves, gutters, downpipes and a brick chimney.
func _build_roof() -> void:
	var edge := WALL_THICKNESS * 0.5
	var roof_base := FLOOR_Y + WALL_HEIGHT + 0.25
	var roof_height := 4.6
	var overhang := 0.75
	var half_span := HOUSE_EAST + overhang
	var depth := HOUSE_SOUTH - HOUSE_NORTH + 1.3
	var house_center_z := (HOUSE_NORTH + HOUSE_SOUTH) * 0.5
	var roof := PrismMesh.new()
	roof.size = Vector3(half_span * 2.0, roof_height, depth)
	var roof_position := Vector3(0.0, roof_base + roof_height * 0.5, house_center_z)
	_mesh(_house, roof, roof_position, Mats.shingles())
	var roof_collider := CollisionShape3D.new()
	roof_collider.shape = roof.create_convex_shape()
	roof_collider.position = roof_position
	_house.add_child(roof_collider)

	# Clapboard infill on both gable ends, with a dim attic window at the front.
	var gable := PrismMesh.new()
	gable.size = Vector3(half_span * 1.8, roof_height * 0.9, 0.06)
	for end_z: float in [HOUSE_SOUTH + 0.66, HOUSE_NORTH - 0.66]:
		_mesh(_decor, gable, Vector3(0.0, roof_base + roof_height * 0.45, end_z), Mats.siding())
	var attic := CylinderMesh.new()
	attic.top_radius = 0.55
	attic.bottom_radius = 0.55
	attic.height = 0.05
	attic.radial_segments = 24
	var attic_window := _mesh(_decor, attic, Vector3(0.0, roof_base + 1.5, HOUSE_SOUTH + 0.7), Mats.glow(Color(0.85, 0.45, 0.15), 0.9))
	attic_window.rotation.x = PI * 0.5
	var ring := TorusMesh.new()
	ring.inner_radius = 0.54
	ring.outer_radius = 0.66
	ring.rings = 28
	ring.ring_segments = 8
	var attic_frame := _mesh(_decor, ring, Vector3(0.0, roof_base + 1.5, HOUSE_SOUTH + 0.72), Mats.trim_painted())
	attic_frame.rotation.x = PI * 0.5
	_span(_decor, -0.56, 0.56, roof_base + 1.475, roof_base + 1.525, HOUSE_SOUTH + 0.7, HOUSE_SOUTH + 0.75, Mats.trim_painted(), false)
	_span(_decor, -0.025, 0.025, roof_base + 0.94, roof_base + 2.06, HOUSE_SOUTH + 0.7, HOUSE_SOUTH + 0.75, Mats.trim_painted(), false)

	# Boxed eaves: fascia board, soffit, half-round gutter and a downpipe at each corner.
	var paint := Mats.trim_painted()
	var zinc := Mats.iron()
	var z0 := house_center_z - depth * 0.5
	var z1 := house_center_z + depth * 0.5
	for side: float in [-1.0, 1.0]:
		var eave_x := side * half_span
		_span(_decor, minf(eave_x, eave_x - side * 0.05), maxf(eave_x, eave_x - side * 0.05), roof_base - 0.2, roof_base + 0.02, z0, z1, paint, false)
		_span(_decor, minf(side * (HOUSE_EAST + edge), eave_x), maxf(side * (HOUSE_EAST + edge), eave_x), roof_base - 0.2, roof_base - 0.17, z0, z1, paint, false)
		var gutter := CylinderMesh.new()
		gutter.top_radius = 0.075
		gutter.bottom_radius = 0.075
		gutter.height = depth + 0.1
		gutter.radial_segments = 10
		gutter.rings = 1
		var gutter_instance := _mesh(_decor, gutter, Vector3(eave_x + side * 0.07, roof_base - 0.04, house_center_z), zinc)
		gutter_instance.rotation.x = PI * 0.5
		for pipe_z: float in [HOUSE_SOUTH + edge + 0.12, HOUSE_NORTH - edge - 0.12]:
			var pipe_x := side * (HOUSE_EAST + edge + 0.1)
			var pipe := CylinderMesh.new()
			pipe.top_radius = 0.05
			pipe.bottom_radius = 0.05
			pipe.height = roof_base - 0.5
			pipe.radial_segments = 8
			pipe.rings = 1
			_mesh(_decor, pipe, Vector3(pipe_x, (roof_base - 0.3) * 0.5 + 0.1, pipe_z), zinc)
			# Swan-neck from the gutter back to the wall.
			var neck_from := Vector3(eave_x + side * 0.07, roof_base - 0.1, pipe_z)
			var neck_to := Vector3(pipe_x, roof_base - 0.42, pipe_z)
			_rod(_decor, neck_from, neck_to, 0.05, zinc)
			# Shoe kicking the water away from the footing.
			_rod(_decor, Vector3(pipe_x, 0.14, pipe_z), Vector3(pipe_x + side * 0.22, 0.05, pipe_z), 0.05, zinc)

	# Chimney.
	_span(_house, -2.9, -1.7, roof_base, roof_base + 5.4, RITUAL_SPLIT - 0.3, RITUAL_SPLIT + 0.9, Mats.brick())
	_span(_decor, -3.0, -1.6, roof_base + 5.4, roof_base + 5.55, RITUAL_SPLIT - 0.4, RITUAL_SPLIT + 1.0, Mats.concrete(), false)
	for pot_x: float in [-2.6, -2.0]:
		var pot := CylinderMesh.new()
		pot.top_radius = 0.13
		pot.bottom_radius = 0.17
		pot.height = 0.5
		pot.radial_segments = 12
		_mesh(_decor, pot, Vector3(pot_x, roof_base + 5.8, RITUAL_SPLIT + 0.3), Mats.brick())


# =============================================================================
# Porch
# =============================================================================

func _build_porch() -> void:
	var paint := Mats.trim_painted()
	var deck := Mats.floor_hall()
	var west := FRONT_DOOR_X - 3.5
	var east := FRONT_DOOR_X + 3.5
	var north := HOUSE_SOUTH + WALL_THICKNESS * 0.5
	var south := -1.2
	_span(_house, west, east, 0.0, FLOOR_Y, north, south, deck)
	# Brick skirt and a fascia board round the deck edge.
	_span(_decor, west - 0.02, east + 0.02, 0.0, FLOOR_Y - 0.08, south - 0.02, south + 0.04, Mats.brick(), false)
	_span(_decor, west - 0.04, east + 0.04, FLOOR_Y - 0.1, FLOOR_Y + 0.01, south - 0.05, south, paint, false)
	for side_x: float in [west, east]:
		_span(_decor, side_x - 0.04, side_x + 0.04, 0.0, FLOOR_Y - 0.08, north, south, Mats.brick(), false)
	_stairs(_house, Vector3(FRONT_DOOR_X, 0.0, south + 0.9), Vector3.FORWARD, 3.0, 3, 0.15, 0.3, deck)

	# Turned columns on square plinths, carrying a beam and the porch roof.
	var roof_y := FLOOR_Y + 2.9
	for post_x: float in [west + 0.14, FRONT_DOOR_X - 1.6, FRONT_DOOR_X + 1.6, east - 0.14]:
		_column(Vector3(post_x, FLOOR_Y, south - 0.14), roof_y - 0.2 - FLOOR_Y, paint)
	_span(_decor, west, east, roof_y - 0.2, roof_y, south - 0.24, south - 0.04, paint, false)
	for side_x: float in [west + 0.1, east - 0.1]:
		_span(_decor, side_x - 0.08, side_x + 0.08, roof_y - 0.2, roof_y, north, south - 0.04, paint, false)
	_span(_house, west - 0.4, east + 0.4, roof_y, roof_y + 0.12, north, south + 0.45, Mats.shingles())
	_span(_decor, west - 0.42, east + 0.42, roof_y - 0.04, roof_y + 0.14, south + 0.43, south + 0.47, paint, false)
	for side_x: float in [west - 0.42, east + 0.38]:
		_span(_decor, side_x, side_x + 0.04, roof_y - 0.04, roof_y + 0.14, north, south + 0.45, paint, false)
	# Tongue-and-groove porch ceiling.
	_span(_decor, west, east, roof_y - 0.03, roof_y, north, south - 0.04, Mats.trim_wood(), false)

	var rail_top := FLOOR_Y + 0.95
	_porch_rail(Vector3(west + 0.14, 0.0, north), Vector3(west + 0.14, 0.0, south - 0.14), rail_top)
	_porch_rail(Vector3(east - 0.14, 0.0, north), Vector3(east - 0.14, 0.0, south - 0.14), rail_top)
	_porch_rail(Vector3(west + 0.14, 0.0, south - 0.14), Vector3(FRONT_DOOR_X - 1.6, 0.0, south - 0.14), rail_top)
	_porch_rail(Vector3(FRONT_DOOR_X + 1.6, 0.0, south - 0.14), Vector3(east - 0.14, 0.0, south - 0.14), rail_top)

	# Wall lantern by the door: the first warm, unreliable light the crew sees.
	var lantern_at := Vector3(FRONT_DOOR_X + 1.72, FLOOR_Y + 1.25, north)
	var fixture := _model(_decor, "lighting/wall_lantern", lantern_at, 0.0, {"fit_height": 1.05, "tint": Color(0.6, 0.6, 0.6), "grunge": 0.4, "shadows": false})
	var fixture_bounds := ModelLoader.get_aabb(fixture)
	fixture.position.z = north + fixture_bounds.size.z * 0.5
	var flame := Mats.glow(LAMP_COLOR, 4.5, true)
	var bulb := SphereMesh.new()
	bulb.radius = 0.035
	bulb.height = 0.1
	var bulb_at := Vector3(lantern_at.x, lantern_at.y + fixture_bounds.size.y * 0.62, north + fixture_bounds.size.z * 0.62)
	_mesh(_decor, bulb, bulb_at, flame).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lantern := OmniLight3D.new()
	lantern.name = "PorchLantern"
	lantern.position = bulb_at
	lantern.light_color = LAMP_COLOR
	lantern.omni_range = 9.0
	lantern.omni_attenuation = 1.25
	lantern.light_volumetric_fog_energy = 1.4
	lantern.shadow_enabled = true
	lantern.shadow_bias = 0.1
	lantern.shadow_normal_bias = 1.5
	_lights.add_child(lantern)
	_add_flicker(lantern, 3.0, 0.45, 6.0, 0.3, flame, 4.5)

	# Condemned notice nailed up beside the door.
	var notice_x := FRONT_DOOR_X - 2.25
	var board := _box(_decor, Vector3(notice_x, FLOOR_Y + 1.65, north + 0.02), Vector3(1.02, 0.64, 0.035), Mats.surface("wood_peeling_paint", 1.4, Color(0.95, 0.80, 0.30), Color(0.82, 0.70, 0.14), Color(0.5, 0.4, 0.1)), false)
	board.rotation.z = 0.035
	var nail := SphereMesh.new()
	nail.radius = 0.014
	nail.height = 0.02
	for nail_x: float in [-0.45, 0.45]:
		for nail_y: float in [-0.25, 0.25]:
			_mesh(_decor, nail, Vector3(notice_x + nail_x, FLOOR_Y + 1.65 + nail_y, north + 0.04), Mats.metal_dark())
	_label(_decor, "CONDEMNED", 44, Vector3(notice_x, FLOOR_Y + 1.76, north + 0.041), 0.0, Color(0.08, 0.07, 0.06)).rotation.z = 0.035
	_label(_decor, "BY ORDER OF THE PARISH", 16, Vector3(notice_x, FLOOR_Y + 1.52, north + 0.041), 0.0, Color(0.08, 0.07, 0.06)).rotation.z = 0.035

	_build_front_doors()


## Round porch column with a plinth, a base ring and a capital.
func _column(foot: Vector3, height: float, material: Material) -> void:
	_box(_house, foot + Vector3.UP * 0.08, Vector3(0.26, 0.16, 0.26), material)
	var shaft := CylinderMesh.new()
	shaft.top_radius = 0.075
	shaft.bottom_radius = 0.095
	shaft.height = height - 0.3
	shaft.radial_segments = 14
	shaft.rings = 1
	_mesh(_decor, shaft, foot + Vector3.UP * (0.16 + (height - 0.3) * 0.5), material)
	_collider_box(_house, foot + Vector3.UP * (height * 0.5), Vector3(0.17, height, 0.17))
	var ring := TorusMesh.new()
	ring.inner_radius = 0.075
	ring.outer_radius = 0.125
	ring.rings = 16
	ring.ring_segments = 8
	_mesh(_decor, ring, foot + Vector3.UP * 0.19, material)
	_mesh(_decor, ring, foot + Vector3.UP * (height - 0.2), material)
	_box(_decor, foot + Vector3.UP * (height - 0.07), Vector3(0.24, 0.14, 0.24), material, false)


## Balustrade between two points on the deck: top and bottom rail with turned balusters.
func _porch_rail(from: Vector3, to: Vector3, top_y: float) -> void:
	var paint := Mats.trim_painted()
	var length := from.distance_to(to)
	var direction := (to - from) / length
	var along_x := absf(direction.x) > 0.5
	var mid := (from + to) * 0.5
	var long_size := Vector3(length, 1.0, 0.0) if along_x else Vector3(0.0, 1.0, length)
	_collider_box(_house, Vector3(mid.x, (FLOOR_Y + top_y) * 0.5, mid.z), long_size * Vector3(1.0, top_y - FLOOR_Y, 1.0) + (Vector3(0.0, 0.0, 0.08) if along_x else Vector3(0.08, 0.0, 0.0)))
	var cap := (Vector3(length, 0.05, 0.11) if along_x else Vector3(0.11, 0.05, length))
	_box(_decor, Vector3(mid.x, top_y - 0.025, mid.z), cap, paint, false)
	var foot := (Vector3(length, 0.05, 0.06) if along_x else Vector3(0.06, 0.05, length))
	_box(_decor, Vector3(mid.x, FLOOR_Y + 0.11, mid.z), foot, paint, false)
	var baluster := CylinderMesh.new()
	baluster.top_radius = 0.018
	baluster.bottom_radius = 0.024
	baluster.height = top_y - FLOOR_Y - 0.18
	baluster.radial_segments = 8
	baluster.rings = 1
	var spots: Array[Transform3D] = []
	var count := maxi(2, int(length / 0.14))
	for i in range(1, count):
		spots.append(Transform3D(Basis.IDENTITY, from + direction * (length * float(i) / float(count)) + Vector3.UP * (FLOOR_Y + 0.13 + baluster.height * 0.5)))
	_decor.add_child(_multimesh("Balusters", baluster, spots, paint))


## Double front doors on real hinges. They open inward on F and can be barged once unlatched.
func _build_front_doors() -> void:
	var leaf_width := DOOR_WIDTH * 0.5 - 0.03
	var leaf_height := DOOR_HEIGHT - 0.08
	var paint := Mats.trim_painted(false)
	for mirrored: bool in [false, true]:
		var door: HingedDoor = HingedDoor.new()
		door.name = "FrontDoorRight" if mirrored else "FrontDoorLeft"
		door.noun = "front doors"
		door.open_angle = deg_to_rad(-100.0 if mirrored else 100.0)
		door.configure(leaf_width, leaf_height, 0.06, 18.0, paint)
		var hinge_x := FRONT_DOOR_X + (DOOR_WIDTH * 0.5 - 0.02) * (1.0 if mirrored else -1.0)
		door.position = Vector3(hinge_x, FLOOR_Y + 0.03 + leaf_height * 0.5, HOUSE_SOUTH)
		door.rotation.y = PI if mirrored else 0.0
		_dress_door_leaf(door, leaf_width, leaf_height, 0.06, Mats.trim_wood(false), true)
		add_child(door)
		door.hinge_to(_house)
		front_doors.append(door)
	front_doors[0].partner = front_doors[1]
	front_doors[1].partner = front_doors[0]


## Raised panels, a kick rail, strap hinges and a brass knob on both faces of a door leaf.
func _dress_door_leaf(door: Node3D, width: float, height: float, thickness: float, panel_material: Material, glazed: bool) -> void:
	var brass := Mats.solid(Color(0.62, 0.48, 0.20), 0.38, 0.9)
	var proud := thickness + 0.022
	var panel_width := width - 0.3
	# Four fielded panels (or two over a small light on the front doors).
	var rows: Array = [[-0.36, 0.4], [-0.02, 0.24], [0.27, 0.3]]
	for row: Array in rows:
		var center_y: float = float(row[0]) * height
		var panel_height: float = float(row[1]) * height
		if glazed and float(row[0]) > 0.2:
			_box(door, Vector3(width * 0.5, center_y, 0.0), Vector3(panel_width, panel_height, thickness + 0.004), Mats.glass_dark(), false)
			_box(door, Vector3(width * 0.5, center_y, 0.0), Vector3(0.03, panel_height, proud), panel_material, false)
			_box(door, Vector3(width * 0.5, center_y, 0.0), Vector3(panel_width, 0.03, proud), panel_material, false)
		else:
			_box(door, Vector3(width * 0.5, center_y, 0.0), Vector3(panel_width, panel_height, proud), panel_material, false)
			_box(door, Vector3(width * 0.5, center_y, 0.0), Vector3(panel_width - 0.12, panel_height - 0.12, proud + 0.014), panel_material, false)
	_box(door, Vector3(width * 0.5, -height * 0.5 + 0.09, 0.0), Vector3(width - 0.04, 0.16, proud + 0.006), brass, false)
	var knob := SphereMesh.new()
	knob.radius = 0.038
	knob.height = 0.076
	knob.radial_segments = 14
	knob.rings = 8
	var rose := CylinderMesh.new()
	rose.top_radius = 0.045
	rose.bottom_radius = 0.045
	rose.height = 0.012
	rose.radial_segments = 14
	for face: float in [-1.0, 1.0]:
		_mesh(door, knob, Vector3(width - 0.11, -0.08, face * (thickness * 0.5 + 0.055)), brass)
		_rod(door, Vector3(width - 0.11, -0.08, face * thickness * 0.5), Vector3(width - 0.11, -0.08, face * (thickness * 0.5 + 0.05)), 0.012, brass)
		var plate := _mesh(door, rose, Vector3(width - 0.11, -0.08, face * (thickness * 0.5 + 0.008)), brass)
		plate.rotation.x = PI * 0.5
	# Hinge knuckles on the hinge edge.
	for hinge_y: float in [-0.36, 0.0, 0.36]:
		_rod(door, Vector3(0.0, hinge_y * height - 0.06, 0.0), Vector3(0.0, hinge_y * height + 0.06, 0.0), 0.016, Mats.metal_dark())


## A pair of hinged, paneled interior doors that start open. `swing` is the
## side they open toward (-1 = negative side of the wall's fixed axis).
func _double_door(door_name: String, along_x: bool, fixed: float, at: float, width: float, height: float, swing: float, floor_y: float) -> void:
	var leaf_width := width * 0.5 - 0.1
	var leaf_height := height - 0.1
	var wood := Mats.trim_wood(false)
	var pair: Array[HingedDoor] = []
	for second: bool in [false, true]:
		var door: HingedDoor = HingedDoor.new()
		door.name = "%s%s" % [door_name, "B" if second else "A"]
		door.noun = "doors"
		door.configure(leaf_width, leaf_height, 0.05, 14.0, wood)
		var hinge_u := at + (width * 0.5 - 0.09) * (1.0 if second else -1.0)
		var y := floor_y + 0.03 + leaf_height * 0.5
		var angle := deg_to_rad(104.0)
		if along_x:
			# Leaf A runs +X from its hinge, leaf B runs -X; +angle carries A toward -Z.
			door.position = Vector3(hinge_u, y, fixed)
			door.rotation.y = PI if second else 0.0
			door.open_angle = angle * (-swing) * (-1.0 if second else 1.0)
		else:
			# Leaf A runs +Z from its hinge, leaf B runs -Z; +angle carries A toward +X.
			door.position = Vector3(fixed, y, hinge_u)
			door.rotation.y = PI * 0.5 if second else -PI * 0.5
			door.open_angle = angle * swing * (-1.0 if second else 1.0)
		_dress_door_leaf(door, leaf_width, leaf_height, 0.05, Mats.panel_wood(), false)
		add_child(door)
		door.hinge_to(_house)
		pair.append(door)
		interior_doors.append(door)
	pair[0].partner = pair[1]
	pair[1].partner = pair[0]
	pair[0].set_open(true)


# =============================================================================
# Rooms
# =============================================================================

func _build_living_room() -> void:
	var brick := Mats.brick()
	var wall_z := RITUAL_SPLIT + WALL_THICKNESS * 0.5
	# Brick fireplace on the north wall with a bed of sullen embers.
	_span(_house, -3.4, -1.2, FLOOR_Y, FLOOR_Y + 1.35, wall_z, wall_z + 0.55, brick)
	_span(_house, -3.0, -1.6, FLOOR_Y + 1.35, FLOOR_Y + WALL_HEIGHT, wall_z, wall_z + 0.4, brick)
	_span(_house, -3.55, -1.05, FLOOR_Y + 1.35, FLOOR_Y + 1.43, wall_z, wall_z + 0.68, Mats.trim_wood())
	_span(_decor, -3.5, -1.1, FLOOR_Y + 1.27, FLOOR_Y + 1.35, wall_z + 0.55, wall_z + 0.63, Mats.trim_wood(), false)
	_span(_decor, -3.7, -0.9, FLOOR_Y, FLOOR_Y + 0.05, wall_z + 0.55, wall_z + 1.15, Mats.floor_stone(), false)
	_span(_decor, -2.9, -1.7, FLOOR_Y, FLOOR_Y + 0.9, wall_z + 0.55, wall_z + 0.56, Mats.solid(Color(0.01, 0.01, 0.01), 1.0), false)
	var embers := Mats.glow(Color(1.0, 0.32, 0.06), 2.5, true)
	_span(_decor, -2.75, -1.85, FLOOR_Y + 0.05, FLOOR_Y + 0.13, wall_z + 0.56, wall_z + 0.72, embers, false).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Iron fire dogs and a couple of charred logs in the grate.
	for dog_x: float in [-2.65, -1.95]:
		_rod(_decor, Vector3(dog_x, FLOOR_Y + 0.05, wall_z + 0.6), Vector3(dog_x, FLOOR_Y + 0.42, wall_z + 0.6), 0.018, Mats.iron())
		_rod(_decor, Vector3(dog_x, FLOOR_Y + 0.16, wall_z + 0.6), Vector3(dog_x, FLOOR_Y + 0.16, wall_z + 0.95), 0.016, Mats.iron())
	_rod(_decor, Vector3(-2.75, FLOOR_Y + 0.22, wall_z + 0.72), Vector3(-1.85, FLOOR_Y + 0.25, wall_z + 0.8), 0.07, Mats.bark())
	_rod(_decor, Vector3(-2.6, FLOOR_Y + 0.33, wall_z + 0.84), Vector3(-1.95, FLOOR_Y + 0.3, wall_z + 0.7), 0.055, Mats.bark())
	var fire := OmniLight3D.new()
	fire.name = "Embers"
	fire.position = Vector3(-2.3, FLOOR_Y + 0.4, wall_z + 1.05)
	fire.light_color = Color(1.0, 0.38, 0.10)
	fire.omni_range = 6.0
	fire.omni_attenuation = 1.5
	fire.light_volumetric_fog_energy = 0.8
	_lights.add_child(fire)
	_add_flicker(fire, 1.6, 0.6, 3.5, 0.0, embers, 2.5)

	# Distressed ceiling beams, a threadbare rug, pictures and a mirror.
	for beam_z: float in [-6.5, -9.5, -12.5]:
		_span(_decor, HOUSE_WEST + 0.15, HALL_WEST - 0.15, FLOOR_Y + WALL_HEIGHT - 0.24, FLOOR_Y + WALL_HEIGHT, beam_z - 0.12, beam_z + 0.12, Mats.trim_wood(), false)
	_rug(Vector3(-2.6, FLOOR_Y, -12.1), Vector2(4.2, 3.0), Mats.rug_red(), 4.0)
	_picture("props/picture_landscape", Vector3(HOUSE_WEST + 0.17, FLOOR_Y + 1.95, -12.6), Vector3.RIGHT, 0.09, 1.0)
	_picture("props/picture_estate", Vector3(HOUSE_WEST + 0.17, FLOOR_Y + 1.8, -5.6), Vector3.RIGHT, -0.16, 0.95)
	_picture("props/picture_oval", Vector3(HALL_WEST - 0.17, FLOOR_Y + 1.85, -12.9), Vector3.LEFT, 0.06, 0.62)
	_picture("props/mirror", Vector3(-2.3, FLOOR_Y + 2.3, wall_z + 0.42), Vector3.BACK, -0.03, 0.62)

	_chandelier(Vector3(-5.5, FLOOR_Y + WALL_HEIGHT, -9.0), 2.8, 0.18)
	_dust(Vector3(-5.0, FLOOR_Y + 1.6, -9.5), Basis.IDENTITY, Vector3(4.6, 1.4, 5.0), 90, Color(1.0, 0.85, 0.65, 0.5))

	# Chalk work: a half-finished circle on the boards and a daubed sigil on the wall.
	_floor_marking(Occult.pentagram(1.4, _chalk, 11), Vector3(-6.3, FLOOR_Y, -7.6))
	_wall_marking(Occult.sigil(1.3, _blood, 5), Vector3(HALL_WEST - 0.16, FLOOR_Y + 1.85, -6.3), Vector3.LEFT)


func _build_hallway() -> void:
	_rug(Vector3(2.0, FLOOR_Y, -9.6), Vector2(1.5, 9.4), Mats.rug_green(), 0.0)
	_picture("props/mirror", Vector3(HALL_WEST + 0.18, FLOOR_Y + 1.85, -12.6), Vector3.RIGHT, 0.04, 0.6)
	_picture("props/picture_oval", Vector3(HALL_EAST - 0.18, FLOOR_Y + 1.95, -6.2), Vector3.LEFT, -0.1, 0.5)
	_pendant_lamp(Vector3(2.0, FLOOR_Y + WALL_HEIGHT, -6.4), 0.9, 2.2, true, 0.4)
	_pendant_lamp(Vector3(2.0, FLOOR_Y + WALL_HEIGHT, -12.8), 0.9, 1.7, false, 0.9)
	_dust(Vector3(2.0, FLOOR_Y + 1.6, -9.5), Basis.IDENTITY, Vector3(1.7, 1.4, 5.0), 40, Color(1.0, 0.85, 0.65, 0.5))

	# A trail of wards leading toward the ritual room.
	_floor_marking(Occult.rune_circle(0.5, _chalk, 21), Vector3(2.0, FLOOR_Y + 0.012, -6.0))
	_floor_marking(Occult.rune_circle(0.42, _chalk, 22), Vector3(1.6, FLOOR_Y + 0.012, -8.4))
	_floor_marking(Occult.rune_circle(0.55, _chalk, 23), Vector3(2.3, FLOOR_Y + 0.012, -10.8))
	_floor_marking(Occult.rune_circle(0.48, _blood, 24), Vector3(2.0, FLOOR_Y + 0.012, -13.6))
	_wall_marking(Occult.rune_row(6, 0.3, _chalk, 25), Vector3(HALL_WEST + 0.2, FLOOR_Y + 1.75, -6.4), Vector3.RIGHT)


func _build_study() -> void:
	var study_y := FLOOR_Y + STUDY_RAISE
	var wall_z := RITUAL_SPLIT + WALL_THICKNESS * 0.5
	_rug(Vector3(7.0, study_y, -8.2), Vector2(3.6, 4.0), Mats.rug_green(), -3.0)
	_picture("props/picture_estate", Vector3(HALL_EAST + 0.17, study_y + 1.7, -6.5), Vector3.RIGHT, 0.12, 0.9)
	_picture("props/picture_landscape", Vector3(8.6, study_y + 1.75, HOUSE_SOUTH - 0.17), Vector3.FORWARD, -0.05, 0.8)
	_pendant_lamp(Vector3(7.0, FLOOR_Y + WALL_HEIGHT, -9.0), 0.6, 2.3, true, 0.25)
	_dust(Vector3(7.0, study_y + 1.3, -9.5), Basis.IDENTITY, Vector3(2.7, 1.1, 5.0), 60, Color(1.0, 0.85, 0.65, 0.5))
	_floor_marking(Occult.rune_circle(0.95, _chalk, 31), Vector3(6.2, study_y, -12.3))
	_wall_marking(Occult.rune_row(7, 0.32, _blood, 32), Vector3(HOUSE_EAST - 0.16, study_y + 1.0, -12.2), Vector3.LEFT)
	_wall_marking(Occult.sigil(0.9, _chalk, 33), Vector3(9.3, study_y + 1.6, wall_z + 0.012), Vector3.BACK)


func _build_ritual_room() -> void:
	var stone := Mats.wall_stone()
	# Round dais with sloped sides: an elevated stage the demon will have to be dragged off.
	var dais := CylinderMesh.new()
	dais.top_radius = 2.95
	dais.bottom_radius = 3.75
	dais.height = DAIS_HEIGHT
	dais.radial_segments = 40
	dais.rings = 1
	var dais_position := DAIS_CENTER + Vector3.UP * DAIS_HEIGHT * 0.5
	_mesh(_house, dais, dais_position, Mats.floor_stone())
	var dais_shape := CylinderMesh.new()
	dais_shape.top_radius = 2.95
	dais_shape.bottom_radius = 3.75
	dais_shape.height = DAIS_HEIGHT
	dais_shape.radial_segments = 28
	dais_shape.rings = 1
	var dais_collider := CollisionShape3D.new()
	dais_collider.shape = dais_shape.create_convex_shape()
	dais_collider.position = dais_position
	_house.add_child(dais_collider)

	# The main event: a pulsing summoning circle ringed with candles.
	var dais_top := DAIS_CENTER + Vector3.UP * DAIS_HEIGHT
	var ember := Occult.chalk_material(Color(1.0, 0.16, 0.06), 3.0)
	_floor_marking(Occult.pentagram(2.6, ember, 41), dais_top)
	var heart := OmniLight3D.new()
	heart.name = "PentagramGlow"
	heart.position = dais_top + Vector3.UP * 0.6
	heart.light_color = Color(1.0, 0.14, 0.05)
	heart.omni_range = 9.5
	heart.omni_attenuation = 1.2
	heart.light_volumetric_fog_energy = 2.2
	_lights.add_child(heart)
	_add_flicker(heart, 2.4, 0.75, 0.9, 0.0, ember, 3.4)
	for i in 5:
		var angle := -PI * 0.5 + TAU * float(i) / 5.0
		_candle(dais_top + Vector3(cos(angle), 0.0, sin(angle)) * 2.78, _rng.randf_range(0.2, 0.34), true, true)
	# Melted-down clusters between the star points.
	for i in 5:
		var angle := -PI * 0.5 + TAU * (float(i) + 0.5) / 5.0
		_candle_cluster(dais_top + Vector3(cos(angle), 0.0, sin(angle)) * 2.86, _rng.randf() * 360.0, i == 0 or i == 3)
	var haze := FogVolume.new()
	haze.name = "RitualHaze"
	haze.size = Vector3(8.0, 1.4, 8.0)
	haze.position = dais_top + Vector3.UP * 0.6
	var haze_material := FogMaterial.new()
	haze_material.density = 0.22
	haze_material.albedo = Color(0.75, 0.25, 0.2)
	haze_material.emission = Color(0.10, 0.008, 0.004)
	haze_material.height_falloff = 1.6
	haze_material.edge_fade = 0.5
	haze.material = haze_material
	_decor.add_child(haze)
	_dust(dais_top + Vector3.UP * 1.2, Basis.IDENTITY, Vector3(4.0, 1.2, 4.0), 70, Color(1.0, 0.45, 0.3, 0.6))

	# Rusted chains hang over the circle from iron rings in the ceiling.
	var links: Array[Transform3D] = []
	var hooks: Array[Transform3D] = []
	for i in 6:
		var angle := PI * 0.25 + TAU * float(i) / 6.0
		var radius := 1.7 if i % 2 == 0 else 2.3
		var top := Vector3(DAIS_CENTER.x + cos(angle) * radius, FLOOR_Y + WALL_HEIGHT, DAIS_CENTER.z + sin(angle) * radius)
		_chain(top, _rng.randf_range(0.9, 1.7), links, hooks)
	var link := TorusMesh.new()
	link.inner_radius = 0.014
	link.outer_radius = 0.03
	link.rings = 10
	link.ring_segments = 5
	_decor.add_child(_multimesh("ChainLinks", link, links, Mats.iron()))
	var shackle := TorusMesh.new()
	shackle.inner_radius = 0.04
	shackle.outer_radius = 0.07
	shackle.rings = 14
	shackle.ring_segments = 6
	_decor.add_child(_multimesh("ChainShackles", shackle, hooks, Mats.iron()))

	# Stone pillars with plinths and capitals.
	for pillar_x: float in [-6.6, 6.6]:
		for pillar_z: float in [-17.2, -21.8]:
			_pillar(Vector3(pillar_x, FLOOR_Y, pillar_z), stone)

	# Altar against the north wall, under a glowing sigil.
	var wall_z := HOUSE_NORTH + WALL_THICKNESS * 0.5
	_span(_house, -1.2, 1.2, FLOOR_Y, FLOOR_Y + 0.95, wall_z, wall_z + 0.9, stone)
	_span(_decor, -1.32, 1.32, FLOOR_Y + 0.95, FLOOR_Y + 1.04, wall_z, wall_z + 1.0, Mats.floor_stone(), false)
	_span(_decor, -1.36, 1.36, FLOOR_Y, FLOOR_Y + 0.12, wall_z, wall_z + 1.04, Mats.floor_stone(), false)
	# Altar cloth: a runner over the slab that hangs down the front.
	var cloth := Mats.surface("rug_jacquard", 2.6, Color(0.42, 0.06, 0.07), Color(0.35, 0.03, 0.04), Color(0.18, 0.02, 0.02))
	_span(_decor, -0.5, 0.5, FLOOR_Y + 1.04, FLOOR_Y + 1.052, wall_z, wall_z + 1.01, cloth, false)
	_span(_decor, -0.5, 0.5, FLOOR_Y + 0.5, FLOOR_Y + 1.05, wall_z + 1.0, wall_z + 1.012, cloth, false)
	var altar_top := FLOOR_Y + 1.04
	_candelabra(Vector3(-0.95, altar_top, wall_z + 0.45), "brass_candleholder_03", 0.74)
	_candelabra(Vector3(0.95, altar_top, wall_z + 0.45), "brass_candleholder_03", 0.74)
	_candle(Vector3(-0.62, altar_top, wall_z + 0.78), 0.14, false, false)
	_model(_decor, "lighting/skull_candle", Vector3(0.0, altar_top + 0.012, wall_z + 0.42), 0.0, {"fit_height": 0.34, "tint": Color(0.85, 0.82, 0.74), "grunge": 0.35})
	_flame(Vector3(0.0, altar_top + 0.36, wall_z + 0.42), 0.8)
	var skull_glow := OmniLight3D.new()
	skull_glow.name = "AltarCandle"
	skull_glow.position = Vector3(0.0, altar_top + 0.5, wall_z + 0.55)
	skull_glow.light_color = Color(1.0, 0.58, 0.24)
	skull_glow.omni_range = 4.0
	skull_glow.omni_attenuation = 1.5
	_lights.add_child(skull_glow)
	_add_flicker(skull_glow, 1.2, 0.5, 8.0, 0.0)
	# Watchers either side of the altar, silhouetted against the north windows.
	for statue_x: float in [-4.9, 4.9]:
		var statue := _model(_decor, "props/gothic_statue", Vector3(statue_x, FLOOR_Y, wall_z + 0.85), 0.0, {"fit_height": 2.0, "tint": Color(0.58, 0.58, 0.62), "grunge": 0.5})
		ModelLoader.add_collision(_house, statue, ModelLoader.Collision.BOX, 0.12)

	var mark := Occult.chalk_material(Color(1.0, 0.16, 0.06), 1.6)
	_wall_marking(Occult.sigil(1.7, mark, 42), Vector3(0.0, FLOOR_Y + 2.35, wall_z + 0.012), Vector3.BACK)
	_wall_marking(Occult.rune_row(8, 0.34, _blood, 43), Vector3(HOUSE_WEST + 0.16, FLOOR_Y + 1.5, -22.4), Vector3.RIGHT)
	_wall_marking(Occult.rune_row(8, 0.34, _blood, 44), Vector3(HOUSE_EAST - 0.16, FLOOR_Y + 1.5, -16.8), Vector3.LEFT)
	_floor_marking(Occult.rune_circle(0.8, _chalk, 45), Vector3(-7.2, FLOOR_Y, -19.4))
	_floor_marking(Occult.rune_circle(0.7, _chalk, 46), Vector3(7.4, FLOOR_Y, -22.0))


func _pillar(foot: Vector3, material: Material) -> void:
	_collider_box(_house, foot + Vector3.UP * WALL_HEIGHT * 0.5, Vector3(0.62, WALL_HEIGHT, 0.62))
	var shaft := CylinderMesh.new()
	shaft.top_radius = 0.3
	shaft.bottom_radius = 0.34
	shaft.height = WALL_HEIGHT - 0.6
	shaft.radial_segments = 20
	shaft.rings = 1
	_mesh(_decor, shaft, foot + Vector3.UP * WALL_HEIGHT * 0.5, material)
	for end: float in [0.0, 1.0]:
		var y := lerpf(0.15, WALL_HEIGHT - 0.15, end)
		_box(_decor, foot + Vector3.UP * y, Vector3(0.86, 0.3, 0.86), material, false)
		var ring := TorusMesh.new()
		ring.inner_radius = 0.28
		ring.outer_radius = 0.42
		ring.rings = 24
		ring.ring_segments = 8
		_mesh(_decor, ring, foot + Vector3.UP * lerpf(0.34, WALL_HEIGHT - 0.34, end), material)


## Adds the links of one hanging chain (and its end shackle) to the shared batches.
func _chain(top: Vector3, length: float, links: Array[Transform3D], hooks: Array[Transform3D]) -> void:
	var pitch := 0.046
	var count := int(length / pitch)
	var sway := Basis(Vector3(_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.0, 1.0)).normalized(), _rng.randf_range(0.0, 0.05))
	var yaw := _rng.randf() * TAU
	for i in count:
		# Stand each link on edge and turn alternate links a quarter turn.
		var basis := sway * Basis(Vector3.UP, yaw + (PI * 0.5 if i % 2 == 1 else 0.0)) * Basis(Vector3.RIGHT, PI * 0.5)
		links.append(Transform3D(basis * Basis.from_scale(Vector3(0.72, 1.0, 1.0)), top + sway * Vector3(0.0, -pitch * (float(i) + 0.5), 0.0)))
	hooks.append(Transform3D(sway * Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, PI * 0.5), top + sway * Vector3(0.0, -pitch * float(count) - 0.05, 0.0)))


# =============================================================================
# Van, triggers and clutter
# =============================================================================

func _build_van() -> void:
	van = ExtractionVan.new()
	van.name = "ExtractionVan"
	van.position = VAN_POSITION
	add_child(van)


## Work site round the back of the van: tripod floodlight, and where the crew stands.
func _build_van_area() -> void:
	var tripod_at := Vector3(8.3, 0.0, -0.9)
	var aim := Vector3(4.6, 0.9, 1.6)
	var facing := atan2(aim.x - tripod_at.x, aim.z - tripod_at.z)
	var tripod := _model(_decor, "lighting/flood_lights", tripod_at, rad_to_deg(facing),
			{"part_prefix": "flood_lights_standing_double_a", "fit_height": 2.0, "tint": DECOR_TINT})
	_collider_span(_grounds, tripod_at.x - 0.12, tripod_at.x + 0.12, 0.0, 1.9, tripod_at.z - 0.12, tripod_at.z + 0.12)
	var head := tripod_at + Vector3(0.0, ModelLoader.get_aabb(tripod).size.y * 0.9, 0.0)
	var lens := Mats.glow(Color(0.95, 0.97, 1.0), 6.0, true)
	var forward := (aim - head).normalized()
	var right := forward.cross(Vector3.UP).normalized()
	var panel := QuadMesh.new()
	panel.size = Vector2(0.2, 0.15)
	for side: float in [-1.0, 1.0]:
		var face := _mesh(_decor, panel, head + right * side * 0.21 + forward * 0.11, lens)
		face.basis = Basis.looking_at(-forward, Vector3.UP)
		face.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var flood := SpotLight3D.new()
	flood.name = "Floodlight"
	flood.transform = Transform3D(Basis.looking_at(forward, Vector3.UP), head + forward * 0.2)
	flood.light_color = Color(0.92, 0.96, 1.0)
	flood.light_volumetric_fog_energy = 1.6
	flood.spot_range = 16.0
	flood.spot_angle = 38.0
	flood.spot_attenuation = 1.0
	flood.spot_angle_attenuation = 0.7
	flood.shadow_enabled = true
	flood.shadow_bias = 0.08
	flood.shadow_normal_bias = 1.5
	_lights.add_child(flood)
	_add_flicker(flood, 6.0, 0.08, 14.0, 0.04, lens, 6.0)
	# Its cable snakes back to the generator.
	var cable := Mats.rubber()
	var cable_points := [tripod_at + Vector3(0.1, 0.02, 0.1), Vector3(8.9, 0.02, 1.2), Vector3(9.5, 0.02, 3.6), Vector3(9.2, 0.02, 6.1)]
	for i in cable_points.size() - 1:
		_rod(_decor, cable_points[i], cable_points[i + 1], 0.014, cable)

	squad_spots = [
		Transform3D(Basis(Vector3.UP, deg_to_rad(250.0)), Vector3(7.0, 0.0, -0.4)),
		Transform3D(Basis(Vector3.UP, deg_to_rad(100.0)), Vector3(1.5, 0.0, 4.6)),
		Transform3D(Basis(Vector3.UP, deg_to_rad(165.0)), Vector3(6.3, 0.0, 8.9)),
	]


func _build_triggers() -> void:
	_trigger(GameState.STEP_ENTER_HOUSE, HOUSE_WEST + 0.4, HALL_WEST - 0.4, FLOOR_Y, FLOOR_Y + 2.6, RITUAL_SPLIT + 0.4, HOUSE_SOUTH - 0.7)
	_trigger(GameState.STEP_FIND_RITUAL, HOUSE_WEST + 0.4, HOUSE_EAST - 0.4, FLOOR_Y, FLOOR_Y + 2.6, HOUSE_NORTH + 0.4, RITUAL_SPLIT - 0.7)


func _trigger(step: StringName, x0: float, x1: float, y0: float, y1: float, z0: float, z1: float) -> void:
	var area := Area3D.new()
	area.name = "Trigger_%s" % step
	area.collision_layer = 0
	area.collision_mask = GameState.LAYER_PLAYER
	area.monitorable = false
	var shape := BoxShape3D.new()
	shape.size = Vector3(x1 - x0, y1 - y0, z1 - z0)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	area.add_child(collider)
	area.position = Vector3(x0 + x1, y0 + y1, z0 + z1) * 0.5
	add_child(area)
	area.body_entered.connect(func(body: Node3D) -> void:
		if body.is_in_group(GameState.GROUP_PLAYER):
			GameState.complete_step(step))


func _spawn_props() -> void:
	var fy := FLOOR_Y
	var sy := FLOOR_Y + STUDY_RAISE
	var altar := FLOOR_Y + 1.06

	# --- Van work site and front yard.
	_prop(&"cone", Vector3(2.7, 0.0, 1.3))
	_prop(&"cone", Vector3(6.4, 0.0, 0.9))
	_prop(&"cone", Vector3(2.5, 0.0, 9.0), 20.0, Vector3(88.0, 0.0, 0.0), 0.25)
	_prop(&"crate", Vector3(7.6, 0.0, 2.6), 14.0)
	_prop(&"paint_can", Vector3(7.5, 0.52, 2.7))
	_prop(&"toolbox", Vector3(6.5, 0.0, 3.3), 35.0)
	_prop(&"tool_chest", Vector3(8.8, 0.0, 1.5), -20.0)
	_prop(&"generator", Vector3(9.3, 0.0, 6.6), 95.0)
	_prop(&"hand_truck", Vector3(9.4, 0.0, 3.6), 250.0)
	_prop(&"tyre", Vector3(8.9, 0.0, 9.0), 0.0, Vector3.ZERO, 0.05)
	_prop(&"tyre", Vector3(8.8, 0.2, 9.1), 40.0, Vector3.ZERO, 0.08)
	_prop(&"trash_can", Vector3(0.6, 0.0, 12.4), 30.0)
	_prop(&"spray_can", Vector3(6.3, 0.0, 3.9))
	_prop(&"bucket", Vector3(1.4, 0.0, 1.9))
	_prop(&"box", Vector3(-6.7, 0.0, 0.6), 30.0)

	# --- Porch.
	_prop(&"box", Vector3(-6.6, fy, -2.6), -12.0)
	_prop(&"rocking_chair", Vector3(-1.5, fy, -2.6), 205.0)
	_prop(&"paint_can", Vector3(-2.4, fy, -1.8))
	_prop(&"lantern", Vector3(-6.0, fy, -3.3), 20.0, Vector3.ZERO, 0.02, true)
	_prop(&"bottle", Vector3(-1.0, fy, -3.4))

	# --- Living room: an interrupted dinner party.
	_prop(&"sofa", Vector3(-2.6, fy, -11.2), 4.0)
	_prop(&"coffee_table", Vector3(-2.6, fy, -12.7), 8.0)
	_prop(&"armchair", Vector3(-4.9, fy, -13.2), 142.0)
	_prop(&"table", Vector3(-6.4, fy, -7.4), 25.0, Vector3(0.0, 0.0, 96.0), 0.8)
	_prop(&"chair", Vector3(-7.9, fy, -6.4), 110.0)
	_prop(&"chair", Vector3(-4.8, fy, -8.6), -60.0)
	_prop(&"chair", Vector3(-7.4, fy, -9.6), 40.0, Vector3(92.0, 0.0, 0.0), 0.35)
	_prop(&"chair", Vector3(-5.9, fy, -6.9), -150.0, Vector3(0.0, 0.0, -94.0), 0.35)
	_prop(&"crate", Vector3(-9.0, fy, -4.9), 40.0)
	_prop(&"tv", Vector3(-9.0, fy + 0.52, -4.9), -45.0, Vector3.ZERO, 0.02, true)
	_prop(&"lamp", Vector3(-9.1, fy, -14.0), 0.0, Vector3.ZERO, 0.02, true)
	_prop(&"lamp", Vector3(-3.4, fy, -7.0), 70.0, Vector3(0.0, 0.0, 86.0), 0.3)
	_prop(&"sideboard", Vector3(-9.45, fy, -11.0), 270.0)
	_prop(&"radio", Vector3(-9.4, fy + 0.88, -11.2), 265.0)
	_prop(&"box", Vector3(-1.1, fy, -5.0), 10.0)
	_prop(&"box", Vector3(-1.2, fy + 0.6, -5.1), -25.0)
	_prop(&"box", Vector3(-0.9, fy, -6.5), 50.0)
	_prop(&"box", Vector3(-8.6, fy, -12.9), 15.0)
	_prop(&"paint_can", Vector3(-7.6, fy, -8.2))
	_prop(&"paint_can", Vector3(-5.3, fy, -7.0), 0.0, Vector3(90.0, 0.0, 0.0), 0.12)
	_prop(&"spray_can", Vector3(-7.2, fy, -8.7))
	_prop(&"spray_can", Vector3(-6.9, fy, -9.0), 0.0, Vector3(90.0, 0.0, 0.0), 0.06)
	_prop(&"book", Vector3(-2.7, fy + 0.48, -12.6), 20.0)
	_prop(&"book", Vector3(-2.3, fy + 0.48, -12.85), -40.0)
	_prop(&"bottle", Vector3(-3.0, fy + 0.48, -12.9))
	_prop(&"goblet", Vector3(-2.2, fy + 0.48, -12.5))
	_prop(&"bottle", Vector3(-1.4, fy, -10.2), 0.0, Vector3(90.0, 0.0, 0.0), 0.06)
	_prop(&"book", Vector3(-3.9, fy, -9.9), 75.0)
	_prop(&"book", Vector3(-6.9, fy, -11.9), 130.0)
	_prop(&"book", Vector3(-8.0, fy, -13.6), 10.0)
	_prop(&"picture", Vector3(-9.55, fy, -8.2), 90.0, Vector3(0.0, 0.0, -14.0), 0.05)
	_prop(&"oil_lantern", Vector3(-1.75, fy + 1.44, RITUAL_SPLIT + 0.5), 0.0, Vector3.ZERO, 0.02, true)
	_prop(&"bust", Vector3(-2.9, fy + 1.44, RITUAL_SPLIT + 0.5), 20.0)

	# --- Hallway.
	_prop(&"grandfather_clock", Vector3(0.5, fy, -4.5), 0.0)
	_prop(&"box", Vector3(3.2, fy, -5.0), 5.0)
	_prop(&"box", Vector3(3.1, fy + 0.6, -5.1), 35.0)
	_prop(&"box", Vector3(3.3, fy, -6.4), -20.0)
	_prop(&"wheelchair", Vector3(1.0, fy, -7.0), 160.0)
	_prop(&"console_table", Vector3(3.5, fy, -8.2), 270.0)
	_prop(&"goblet", Vector3(3.5, fy + 0.9, -7.8))
	_prop(&"skull", Vector3(3.5, fy + 0.9, -8.5), 250.0)
	_prop(&"paint_can", Vector3(0.7, fy, -13.9))
	_prop(&"paint_can", Vector3(1.0, fy, -14.3))
	_prop(&"book", Vector3(2.6, fy, -9.4), 60.0)
	_prop(&"book", Vector3(1.5, fy, -12.0), -30.0)
	_prop(&"bucket", Vector3(0.6, fy, -12.4))

	# --- Study.
	_prop(&"bookshelf", Vector3(5.4, sy, RITUAL_SPLIT + 0.46), 180.0)
	_prop(&"bookshelf", Vector3(7.5, sy, RITUAL_SPLIT + 0.46), 180.0)
	_prop(&"cabinet", Vector3(9.3, sy, -5.4), 90.0)
	_prop(&"desk", Vector3(7.7, sy, -7.2), 90.0)
	_prop(&"green_chair", Vector3(6.6, sy, -7.2), 95.0)
	_prop(&"armchair", Vector3(5.3, sy, -9.2), -75.0)
	_prop(&"round_table", Vector3(8.5, sy, -10.6))
	_prop(&"chair", Vector3(7.4, sy, -11.6), 0.0, Vector3(0.0, 0.0, 92.0), 0.35)
	_prop(&"lamp", Vector3(9.2, sy, -12.9), 0.0, Vector3.ZERO, 0.02, true)
	_prop(&"nightstand", Vector3(4.6, sy, -8.0), -90.0)
	_prop(&"crate", Vector3(4.9, sy, -5.0), -8.0)
	_prop(&"box", Vector3(4.9, sy + 0.52, -5.0), 22.0)
	_prop(&"box", Vector3(5.2, sy, -6.3), 40.0)
	_prop(&"bust", Vector3(7.7, sy + 0.72, -6.6), 200.0)
	_prop(&"book", Vector3(7.6, sy + 0.72, -7.5), 15.0)
	_prop(&"book", Vector3(7.65, sy + 0.78, -7.52), -10.0)
	_prop(&"book", Vector3(7.9, sy + 0.72, -7.9), 80.0)
	_prop(&"bottle", Vector3(8.4, sy + 0.8, -10.5))
	_prop(&"goblet", Vector3(8.7, sy + 0.8, -10.8))
	_prop(&"book", Vector3(8.3, sy + 0.8, -10.9), 30.0)
	_prop(&"book", Vector3(5.6, sy, -13.2), 35.0)
	_prop(&"book", Vector3(6.3, sy, -13.5), -70.0)
	_prop(&"book", Vector3(7.6, sy, -13.0), 5.0)
	_prop(&"book", Vector3(8.4, sy, -12.3), 150.0)
	_prop(&"book", Vector3(6.9, sy, -11.0), -15.0)
	_prop(&"picture", Vector3(4.4, sy, -13.4), 90.0, Vector3(0.0, 0.0, -12.0), 0.05)

	# --- Ritual room.
	_prop(&"gothic_chair", Vector3(-2.1, fy, -23.0), 180.0)
	_prop(&"gothic_chair", Vector3(2.1, fy, -23.0), 180.0)
	_prop(&"chair", Vector3(-4.4, fy, -17.0), 60.0, Vector3(90.0, 0.0, 0.0), 0.35)
	_prop(&"chair", Vector3(4.6, fy, -21.6), -120.0, Vector3(0.0, 0.0, 95.0), 0.35)
	_prop(&"chair", Vector3(4.2, fy, -16.6), 215.0)
	_prop(&"coffee_table", Vector3(-8.2, fy, -22.2), 30.0, Vector3(0.0, 0.0, 180.0), 0.55)
	_prop(&"paint_can", Vector3(-3.9, fy, -20.6))
	_prop(&"paint_can", Vector3(-4.2, fy, -21.0))
	_prop(&"paint_can", Vector3(3.9, fy, -18.4), 0.0, Vector3(90.0, 0.0, 0.0), 0.12)
	_prop(&"box", Vector3(8.6, fy, -16.3), 12.0)
	_prop(&"box", Vector3(8.4, fy, -17.6), -35.0)
	_prop(&"crate", Vector3(-8.8, fy, -16.2), 5.0)
	_prop(&"bucket", Vector3(7.7, fy, -22.7))
	_prop(&"lantern", Vector3(-7.9, fy, -23.2), 60.0, Vector3.ZERO, 0.02, true)
	_prop(&"skull", Vector3(1.3, fy + DAIS_HEIGHT, -18.5), 30.0)
	_prop(&"skull", Vector3(-1.7, fy + DAIS_HEIGHT, -20.5), 200.0)
	_prop(&"skull", Vector3(6.0, fy, -20.0), 120.0)
	_prop(&"skull", Vector3(-0.55, altar, HOUSE_NORTH + 0.62), 170.0)
	_prop(&"goblet", Vector3(0.5, altar, HOUSE_NORTH + 0.9))
	_prop(&"goblet", Vector3(0.34, altar, HOUSE_NORTH + 1.02))
	_prop(&"goblet", Vector3(2.4, fy, -22.4), 0.0, Vector3(90.0, 0.0, 0.0), 0.06)
	_prop(&"book", Vector3(-0.2, altar, HOUSE_NORTH + 0.95), 25.0)
	_prop(&"book", Vector3(-2.4, fy, -21.9), 100.0)
	_prop(&"book", Vector3(2.9, fy, -21.6), -50.0)
	_prop(&"bottle", Vector3(5.5, fy, -17.2))
	_prop(&"bottle", Vector3(5.8, fy, -17.0), 0.0, Vector3(90.0, 0.0, 0.0), 0.06)


## Spawns one clutter prop. `lift` raises the spawn point so tipped-over props
## start clear of the floor and settle under gravity.
func _prop(kind: StringName, at: Vector3, yaw_degrees: float = 0.0, tilt_degrees: Vector3 = Vector3.ZERO,
		lift: float = 0.02, lit: bool = false) -> RigidBody3D:
	var prop := PropFactory.create(kind, _rng, lit)
	if prop == null:
		return null
	prop.position = at + Vector3.UP * lift
	prop.rotation = Vector3(deg_to_rad(tilt_degrees.x), deg_to_rad(yaw_degrees), deg_to_rad(tilt_degrees.z))
	_props.add_child(prop, true)
	prop_count += 1
	return prop


# =============================================================================
# Set dressing helpers
# =============================================================================

## Industrial pendant with a failing bulb. `at` is the ceiling fixing point.
func _pendant_lamp(at: Vector3, drop: float, energy: float, shadows: bool, dropout_rate: float) -> void:
	# The fitting must not shadow its own bulb, or it throws a black disc across the ceiling.
	var fitting := _model(_decor, "lighting/hanging_lamp", at, _rng.randf() * 360.0,
			{"fit_height": drop + 0.5, "anchor": "top", "tint": Color(0.7, 0.7, 0.7), "shadows": false})
	var reach := ModelLoader.get_aabb(fitting).size.y
	var bulb_material := Mats.glow(LAMP_COLOR, 4.0, true)
	var bulb := SphereMesh.new()
	bulb.radius = 0.055
	bulb.height = 0.12
	_mesh(_decor, bulb, at + Vector3.DOWN * (reach - 0.02), bulb_material).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var light := OmniLight3D.new()
	light.name = "PendantLamp"
	light.position = at + Vector3.DOWN * (reach + 0.08)
	light.light_color = LAMP_COLOR
	light.omni_range = 10.5
	light.omni_attenuation = 1.25
	light.light_volumetric_fog_energy = 1.2
	light.shadow_enabled = shadows
	light.shadow_bias = 0.1
	light.shadow_normal_bias = 1.5
	_lights.add_child(light)
	_add_flicker(light, energy, 0.35, 6.5, dropout_rate, bulb_material, 4.0)


## Brass chandelier on a chain; its arms carry small emissive bulbs.
func _chandelier(at: Vector3, energy: float, dropout_rate: float) -> void:
	var chain_length := 0.45
	_rod(_decor, at, at + Vector3.DOWN * chain_length, 0.012, Mats.iron())
	var fitting := _model(_decor, "lighting/chandelier", at + Vector3.DOWN * chain_length, 0.0,
			{"fit_height": 0.95, "anchor": "top", "tint": Color(0.75, 0.72, 0.68), "shadows": false})
	var bounds := ModelLoader.get_aabb(fitting)
	var glow_material := Mats.glow(LAMP_COLOR, 3.0, true)
	var light := OmniLight3D.new()
	light.name = "Chandelier"
	light.position = at + Vector3.DOWN * (chain_length + bounds.size.y * 0.75)
	light.light_color = LAMP_COLOR
	light.omni_range = 11.0
	light.omni_attenuation = 1.2
	light.light_volumetric_fog_energy = 1.2
	light.shadow_enabled = true
	light.shadow_bias = 0.1
	light.shadow_normal_bias = 1.5
	_lights.add_child(light)
	_add_flicker(light, energy, 0.3, 6.5, dropout_rate, glow_material, 3.0)
	var bulb := SphereMesh.new()
	bulb.radius = 0.03
	bulb.height = 0.07
	for i in 6:
		var angle := TAU * float(i) / 6.0
		var offset := Vector3(cos(angle) * bounds.size.x * 0.36, -chain_length - bounds.size.y * 0.42, sin(angle) * bounds.size.x * 0.36)
		_mesh(_decor, bulb, at + offset, glow_material).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## One wax candle with an animated flame; `glow` adds a small shadowless light.
func _candle(at: Vector3, height: float, lit: bool, glow: bool) -> void:
	_model(_decor, "lighting/candle", at, _rng.randf() * 360.0, {"fit_height": height, "tint": Color(0.86, 0.80, 0.66), "shadows": false})
	if not lit:
		return
	_flame(at + Vector3.UP * (height - 0.005), 1.0)
	if glow:
		var light := OmniLight3D.new()
		light.name = "Candle"
		light.position = at + Vector3.UP * (height + 0.1)
		light.light_color = Color(1.0, 0.58, 0.24)
		light.omni_range = 3.4
		light.omni_attenuation = 1.6
		_lights.add_child(light)
		_add_flicker(light, 0.75, 0.55, 9.0, 0.0)


## Three candles melted together. Flames only; a cluster borrows light from its neighbours.
func _candle_cluster(at: Vector3, yaw: float, glow: bool) -> void:
	var cluster := _model(_decor, "lighting/candles", at, yaw, {"fit_height": 0.3, "tint": Color(0.86, 0.80, 0.66), "shadows": false})
	var bounds := ModelLoader.get_aabb(cluster)
	var turn := Basis(Vector3.UP, deg_to_rad(yaw))
	# Wick positions measured on the model: tall centre candle and two shorter ones.
	var wicks := [Vector3(-0.02, 1.0, -0.14), Vector3(0.26, 0.76, 0.2), Vector3(-0.3, 0.58, 0.22)]
	for wick: Vector3 in wicks:
		_flame(at + turn * Vector3(wick.x * bounds.size.x, wick.y * bounds.size.y, wick.z * bounds.size.z), 0.85)
	if glow:
		var light := OmniLight3D.new()
		light.name = "CandleCluster"
		light.position = at + Vector3.UP * 0.4
		light.light_color = Color(1.0, 0.58, 0.24)
		light.omni_range = 3.0
		light.omni_attenuation = 1.6
		_lights.add_child(light)
		_add_flicker(light, 0.6, 0.5, 8.0, 0.0)


## Brass candelabra from the Poly Haven set, with a flame on each arm.
func _candelabra(at: Vector3, part: String, height: float) -> void:
	var holder := _model(_decor, "lighting/candelabra_set", at, 0.0, {"part": part, "fit_height": height, "tint": Color(0.80, 0.74, 0.62)})
	var bounds := ModelLoader.get_aabb(holder)
	var spread := bounds.size.x * 0.5
	# Five arms: centre, two mid, two outer (heights measured on the model).
	var arms := [Vector2(0.0, 1.0), Vector2(-0.52, 0.9), Vector2(0.52, 0.9), Vector2(-0.94, 0.8), Vector2(0.94, 0.8)]
	for arm: Vector2 in arms:
		_flame(at + Vector3(arm.x * spread, arm.y * bounds.size.y - 0.004, 0.0), 0.7)
	var light := OmniLight3D.new()
	light.name = "Candelabra"
	light.position = at + Vector3(0.0, height + 0.1, 0.2)
	light.light_color = Color(1.0, 0.60, 0.26)
	light.omni_range = 4.6
	light.omni_attenuation = 1.5
	_lights.add_child(light)
	_add_flicker(light, 1.3, 0.45, 8.0, 0.0)


## Camera-facing animated flame sitting on a wick at `at`.
func _flame(at: Vector3, scale: float) -> void:
	if _flame_mesh == null:
		_flame_mesh = QuadMesh.new()
		_flame_mesh.size = Vector2(0.055, 0.12)
		_flame_mesh.center_offset = Vector3(0.0, 0.06, 0.0)
		_flame_mesh.material = Mats.candle_flame()
	var flame := MeshInstance3D.new()
	flame.name = "Flame"
	flame.mesh = _flame_mesh
	flame.position = at
	flame.scale = Vector3.ONE * scale
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The shader moves the vertices, so give culling a generous box.
	flame.extra_cull_margin = 0.3
	_decor.add_child(flame)


func _add_flicker(light: Light3D, energy: float, amount: float, speed: float, dropout_rate: float,
		glow_material: StandardMaterial3D = null, glow_energy: float = 3.0) -> void:
	var flicker := FlickerLight.new()
	flicker.base_energy = energy
	flicker.flicker_amount = amount
	flicker.speed = speed
	flicker.dropout_rate = dropout_rate
	flicker.glow_material = glow_material
	flicker.glow_energy = glow_energy
	light.light_energy = energy
	light.add_child(flicker)


## Framed picture or mirror hung askew. `facing` is the wall normal pointing into the room.
func _picture(model: String, at: Vector3, facing: Vector3, roll: float, width: float) -> void:
	var frame := ModelLoader.instance(model, {"fit_width": width, "anchor": "center", "tint": DECOR_TINT, "shadows": false})
	frame.transform = Transform3D(Basis.looking_at(-facing, Vector3.UP), at)
	frame.rotate_object_local(Vector3.BACK, roll)
	_decor.add_child(frame)


## Dusty rug: a thin slab of woven texture with a darker bound edge.
func _rug(center: Vector3, size: Vector2, material: Material, yaw_degrees: float) -> void:
	var pivot := Node3D.new()
	pivot.position = center
	pivot.rotation.y = deg_to_rad(yaw_degrees)
	_decor.add_child(pivot)
	var border := _box(pivot, Vector3(0.0, 0.006, 0.0), Vector3(size.x, 0.012, size.y), Mats.surface("rug_dirty_carpet", 1.0, Color(0.30, 0.24, 0.20), Color(0.12, 0.08, 0.07), Color(0.05, 0.03, 0.03)), false)
	border.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var field := _box(pivot, Vector3(0.0, 0.009, 0.0), Vector3(size.x - 0.3, 0.012, size.y - 0.3), material, false)
	field.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _floor_marking(marking: MeshInstance3D, at: Vector3) -> void:
	marking.position = at + Vector3.UP * 0.014
	_decor.add_child(marking)


## Stands a flat marking up against a wall whose normal is `facing`.
func _wall_marking(marking: MeshInstance3D, at: Vector3, facing: Vector3) -> void:
	marking.transform = Transform3D(Basis(Quaternion(Vector3.UP, facing)), at)
	_decor.add_child(marking)


## Places a normalised .glb (bottom centre at `at`).
func _model(parent: Node3D, model: String, at: Vector3, yaw_degrees: float = 0.0, options: Dictionary = {}) -> Node3D:
	var node := ModelLoader.instance(model, options)
	node.position = at
	node.rotation.y = deg_to_rad(yaw_degrees)
	parent.add_child(node)
	return node


# =============================================================================
# Geometry helpers
# =============================================================================

func _new_body(body_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.collision_layer = GameState.LAYER_WORLD
	body.collision_mask = 0
	add_child(body)
	return body


func _new_group(group_name: String) -> Node3D:
	var group := Node3D.new()
	group.name = group_name
	add_child(group)
	return group


func _mesh(parent: Node3D, mesh: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	parent.add_child(instance)
	return instance


func _multimesh(node_name: String, mesh: Mesh, transforms: Array[Transform3D], material: Material) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = material
	return instance


## Round bar between two points.
func _rod(parent: Node3D, from: Vector3, to: Vector3, radius: float, material: Material) -> MeshInstance3D:
	var span := to - from
	var length := span.length()
	var bar := CylinderMesh.new()
	bar.top_radius = radius
	bar.bottom_radius = radius
	bar.height = length
	bar.radial_segments = 8
	bar.rings = 1
	var instance := _mesh(parent, bar, (from + to) * 0.5, material)
	if length > 0.0001:
		var up := span / length
		var side := up.cross(Vector3.UP)
		if side.length_squared() < 0.0001:
			side = Vector3.RIGHT
		side = side.normalized()
		instance.basis = Basis(side, up, side.cross(up))
	return instance


## Box by centre and size. With `solid`, `parent` must be a physics body.
func _box(parent: Node3D, center: Vector3, size: Vector3, material: Material, solid: bool = true) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	if solid:
		_collider_box(parent, center, size)
	return _mesh(parent, mesh, center, material)


## Box by min/max corners.
func _span(parent: Node3D, x0: float, x1: float, y0: float, y1: float, z0: float, z1: float, material: Material, solid: bool = true) -> MeshInstance3D:
	return _box(parent, Vector3(x0 + x1, y0 + y1, z0 + z1) * 0.5, Vector3(x1 - x0, y1 - y0, z1 - z0), material, solid)


func _collider_box(body: Node3D, center: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = center
	body.add_child(collider)


func _collider_span(body: Node3D, x0: float, x1: float, y0: float, y1: float, z0: float, z1: float) -> void:
	_collider_box(body, Vector3(x0 + x1, y0 + y1, z0 + z1) * 0.5, Vector3(x1 - x0, y1 - y0, z1 - z0))


func _label(parent: Node3D, text: String, font_size: int, at: Vector3, yaw: float, color: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = font_size
	label.pixel_size = 0.004
	label.outline_size = 0
	label.modulate = color
	label.shaded = true
	label.double_sided = false
	label.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	label.position = at
	label.rotation.y = yaw
	parent.add_child(label)
	return label
