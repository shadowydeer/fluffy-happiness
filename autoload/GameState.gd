extends Node
## Global session state for BIND & DELIVER (autoload: `GameState`).
##
## Owns the shared physics-layer bits, node groups, the contract objective chain
## and the crew's career: contract number, bank balance and the last payout. It
## outlives the level, so the Stage 5 shop can read and spend `bank_cash`.
## The HUD listens to the signals here; world objects report progress through
## `complete_step()` and take it back with `revoke_step()` (a demon that wakes up
## is no longer subdued).

signal objective_changed(title: String, task: String, progress: float, done: int, total: int)
signal notice_posted(text: String)
signal contract_completed
signal contract_started(number: int)
signal bank_changed(total: int)

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

const FIRST_CONTRACT := 413
const SITE_NAME := "13 HOLLOW LANE"
const ALL_DONE_TASK := "CONTRACT COMPLETE!"

const STEP_OPEN_VAN := &"open_van"
const STEP_ENTER_HOUSE := &"enter_house"
const STEP_LOCATE_DEMON := &"locate_demon"
const STEP_SUBDUE_DEMON := &"subdue_demon"
const STEP_LOAD_DEMON := &"load_demon"
const STEP_SEAL_VAN := &"seal_van"

## The contract, in order. Every one of these has to be done to get paid.
const STEPS: Array[Dictionary] = [
	{"id": STEP_LOCATE_DEMON, "task": "Enter the cursed house & locate the demon"},
	{"id": STEP_SUBDUE_DEMON, "task": "Subdue the demon! [2: Holy Taser]"},
	{"id": STEP_LOAD_DEMON, "task": "Bind with Duct Tape [3] & haul to the van"},
	{"id": STEP_SEAL_VAN, "task": "Close the van's rear doors [F] to extract!"},
]
## Things worth noting on the way that the contract does not depend on.
const MILESTONES: Array[StringName] = [STEP_OPEN_VAN, STEP_ENTER_HOUSE]

var contract_number := FIRST_CONTRACT
## Contracts paid out so far; also how much harder the next demon is.
var contracts_completed := 0
var bank_cash := 0
## Line items of the most recent payout (see ContractManager.compute_payout).
var last_payout: Dictionary = {}

var _completed: Dictionary = {}
var _milestones: Dictionary = {}
var _task_override := ""


## Clears all progress on the current contract. Called by Main whenever the level is (re)built.
func reset() -> void:
	_completed.clear()
	_milestones.clear()
	_task_override = ""
	refresh()


## Moves on to the next job: new number, clean objective chain.
func advance_contract() -> void:
	contract_number += 1
	reset()
	contract_started.emit(contract_number)


func get_contract_title() -> String:
	return "CONTRACT #%04d // %s" % [contract_number, SITE_NAME]


## Pays the crew. Returns the new balance.
func add_cash(amount: int) -> int:
	bank_cash += amount
	bank_changed.emit(bank_cash)
	return bank_cash


## Re-emits the current objective so late listeners (the HUD) can sync.
func refresh() -> void:
	objective_changed.emit(get_contract_title(), get_current_task(), get_progress(), _completed.size(), STEPS.size())


## Marks a step as done. Steps may be completed in any order; repeats are ignored.
func complete_step(id: StringName) -> void:
	if MILESTONES.has(id):
		_milestones[id] = true
		return
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
		contracts_completed += 1
		contract_completed.emit()


## Re-opens a step whose condition no longer holds (the demon woke up or was hauled back out).
func revoke_step(id: StringName) -> void:
	if _milestones.erase(id):
		return
	if _completed.erase(id):
		refresh()


## One-line message in the HUD's notice strip.
func post_notice(text: String) -> void:
	notice_posted.emit(text)


## Replaces the banner's task line with a more pressing instruction ("" restores it).
func set_task_override(text: String) -> void:
	if text == _task_override:
		return
	_task_override = text
	refresh()


func is_step_done(id: StringName) -> bool:
	return _completed.has(id) or _milestones.has(id)


func is_contract_complete() -> bool:
	return _completed.size() >= STEPS.size()


func get_progress() -> float:
	return float(_completed.size()) / float(STEPS.size())


## The first unfinished task, in contract order, unless something more pressing overrides it.
func get_current_task() -> String:
	if not _task_override.is_empty():
		return _task_override
	for step: Dictionary in STEPS:
		if not _completed.has(step["id"]):
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
