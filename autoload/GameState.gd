extends Node
## Global session state for BIND & DELIVER (autoload: `GameState`).
##
## Owns the shared physics-layer bits, node groups and the contract objective
## chain. The HUD listens to the signals here; world objects report progress
## through `complete_step()`.

signal objective_changed(title: String, task: String, progress: float, done: int, total: int)
signal notice_posted(text: String)
signal contract_completed

# Physics layer bits (names mirrored in project.godot -> layer_names).
const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_PROP := 4
const LAYER_INTERACT := 8

const GROUP_PLAYER := &"player"
const GROUP_GRABBABLE := &"grabbable"

const CONTRACT_TITLE := "CONTRACT #0413 // 13 HOLLOW LANE"
const ALL_DONE_TASK := "Site prepped. Stand by for the demon."

const STEP_OPEN_VAN := &"open_van"
const STEP_ENTER_HOUSE := &"enter_house"
const STEP_FIND_RITUAL := &"find_ritual"
const STEP_LOAD_CARGO := &"load_cargo"

const STEPS: Array[Dictionary] = [
	{"id": STEP_OPEN_VAN, "task": "Open the van's rear doors"},
	{"id": STEP_ENTER_HOUSE, "task": "Break into the cursed house"},
	{"id": STEP_FIND_RITUAL, "task": "Locate the ritual room"},
	{"id": STEP_LOAD_CARGO, "task": "Cage test: haul any junk into the van"},
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


func is_step_done(id: StringName) -> bool:
	return _completed.has(id)


func is_contract_complete() -> bool:
	return _completed.size() >= STEPS.size()


func get_progress() -> float:
	return float(_completed.size()) / float(STEPS.size())


## The first unfinished task, in contract order.
func get_current_task() -> String:
	for step: Dictionary in STEPS:
		if not _completed.has(step["id"]):
			return step["task"]
	return ALL_DONE_TASK


func _task_for(id: StringName) -> String:
	for step: Dictionary in STEPS:
		if step["id"] == id:
			return step["task"]
	return ""
