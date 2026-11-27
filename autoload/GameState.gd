extends Node
## Global session state for BIND & DELIVER (autoload: `GameState`).
##
## Owns the shared physics-layer bits, node groups and the contract objective
## chain. The HUD listens to the signals here; world objects report progress
## through `complete_step()` and take it back with `revoke_step()` (a demon that
## wakes up is no longer subdued).

signal objective_changed(title: String, task: String, progress: float, done: int, total: int)
signal notice_posted(text: String)
signal contract_completed

# Physics layer bits (names mirrored in project.godot -> layer_names).
const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_PROP := 4
const LAYER_INTERACT := 8
## Ragdoll segments of the demon. Nothing on this layer masks it, so limbs never collide with each other.
const LAYER_DEMON := 16

const GROUP_PLAYER := &"player"
const GROUP_GRABBABLE := &"grabbable"
const GROUP_DEMON := &"demon"

const CONTRACT_TITLE := "CONTRACT #0413 // 13 HOLLOW LANE"
const ALL_DONE_TASK := "Demon secured. Stand by for extraction."

const STEP_OPEN_VAN := &"open_van"
const STEP_ENTER_HOUSE := &"enter_house"
const STEP_LOCATE_DEMON := &"locate_demon"
const STEP_SUBDUE_DEMON := &"subdue_demon"
const STEP_LOAD_DEMON := &"load_demon"
const STEP_SEAL_VAN := &"seal_van"

const STEPS: Array[Dictionary] = [
	{"id": STEP_OPEN_VAN, "task": "Open the van's rear doors"},
	{"id": STEP_ENTER_HOUSE, "task": "Break into the cursed house"},
	{"id": STEP_LOCATE_DEMON, "task": "Locate the demon inside the house"},
	{"id": STEP_SUBDUE_DEMON, "task": "Subdue the demon! [K to test stun]"},
	{"id": STEP_LOAD_DEMON, "task": "Drag the demon into the van"},
	{"id": STEP_SEAL_VAN, "task": "Demon inside van! Close doors [F]"},
]

var _completed: Dictionary = {}


## Clears all progress. Called by Main whenever the level is (re)built.
func reset() -> void:
	_completed.clear()
	refresh()


## Re-emits the current objective so late listeners (the HUD) can sync.
func refresh() -> void:
	objective_changed.emit(CONTRACT_TITLE, get_current_task(), get_progress(), _completed.size(), STEPS.size())


## Marks a step as done. Steps may be completed in any order; repeats are ignored.
func complete_step(id: StringName) -> void:
	if _completed.has(id):
		return
	var task := _task_for(id)
	if task.is_empty():
		push_warning("GameState: unknown objective step '%s'" % id)
		return
	_completed[id] = true
	notice_posted.emit("DONE: %s" % task)
	refresh()
	if is_contract_complete():
		contract_completed.emit()


## Re-opens a step whose condition no longer holds (the demon woke up or was hauled back out).
func revoke_step(id: StringName) -> void:
	if _completed.erase(id):
		refresh()


## One-line message in the HUD's notice strip.
func post_notice(text: String) -> void:
	notice_posted.emit(text)


func is_step_done(id: StringName) -> bool:
	return _completed.has(id)


func is_contract_complete() -> bool:
	return _completed.size() >= STEPS.size()


func get_progress() -> float:
	return float(_completed.size()) / float(STEPS.size())


## The first unfinished task, in contract order. A crew that went in without opening the
## van is pointed at the demon first; the doors only matter once there is a body to load.
func get_current_task() -> String:
	var van_skipped := not _completed.has(STEP_OPEN_VAN) and _completed.has(STEP_ENTER_HOUSE)
	for step: Dictionary in STEPS:
		if _completed.has(step["id"]):
			continue
		if van_skipped and step["id"] == STEP_OPEN_VAN and not _completed.has(STEP_SUBDUE_DEMON):
			continue
		return step["task"]
	return ALL_DONE_TASK


## World-space centre of mass. Prop origins sit at their base, so a tumbling prop's origin
## swings well away from the point that actually follows its ballistic path.
func mass_center(body: RigidBody3D) -> Vector3:
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
	return body.global_position + state.center_of_mass if state else body.global_position


func _task_for(id: StringName) -> String:
	for step: Dictionary in STEPS:
		if step["id"] == id:
			return step["task"]
	return ""
