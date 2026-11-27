extends Node
## Global session state for BIND & DELIVER (autoload: `GameState`).
##
## Owns the shared physics-layer bits, node groups, the contract objective chain
## and the crew's career: contract number, bank balance and the last payout. It
## outlives the level, so the field shop can read and spend `bank_cash`, and it keeps
## what the shop sold: gadget upgrade levels, the crew's salt grenades and which demon
## archetype the current contract is about. It also owns `user://settings.cfg`.
## The HUD listens to the signals here; world objects report progress through
## `complete_step()` and take it back with `revoke_step()` (a demon that wakes up
## is no longer subdued).
##
## In co-op only the host changes any of this: on a client every mutator is a
## no-op and the state arrives through `apply_sync()` (see NetSync).

signal objective_changed(title: String, task: String, progress: float, done: int, total: int)
signal notice_posted(text: String)
signal contract_completed
signal contract_started(number: int)
signal bank_changed(total: int)
## An upgrade level, the salt grenade count or the revive boost changed.
signal loadout_changed
## The contract is now about a different kind of demon (see DemonArchetypes).
signal archetype_changed(kind: int)

const DemonArchetypes := preload("res://scripts/DemonArchetypes.gd")

# Physics layer bits (names mirrored in project.godot -> layer_names).
const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_PROP := 4
const LAYER_INTERACT := 8
## Ragdoll segments of the demon. Nothing on this layer masks it, so limbs never collide with each other.
const LAYER_DEMON := 16

## Render layer of the local player's own body: the first-person camera culls it.
const RENDER_OWN_BODY := 1 << 12

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

const SETTINGS_PATH := "user://settings.cfg"

## Field shop upgrades, by id. Each goes from level 0 (stock) to UPGRADE_MAX.
const UPGRADE_TASER := &"taser"
const UPGRADE_LASSO := &"lasso"
const UPGRADE_TAPE := &"tape"
const UPGRADE_MAX := 2
## Salt grenades the crew can carry, and how many every contract starts with at least.
const SALT_MAX := 4
const SALT_STARTER := 1

## Network references to bodies: 0 nothing, 1.. loose props, then demon limbs, then players by seat.
const REF_DEMON := 1000
const REF_PLAYER := 2000

var contract_number := FIRST_CONTRACT
## Contracts paid out so far; also how much harder the next demon is.
var contracts_completed := 0
var bank_cash := 0
## Line items of the most recent payout (see ContractManager.compute_payout).
var last_payout: Dictionary = {}

## Gadget upgrade levels bought at the field shop, shared by the whole crew.
var upgrades: Dictionary = {UPGRADE_TASER: 0, UPGRADE_LASSO: 0, UPGRADE_TAPE: 0}
## Salt grenades left in the crew's pool (slot 4).
var salt_charges := SALT_STARTER
## Co-op: an auto-injector was bought for this contract, so revives are quicker.
var revive_boost := false
## Which demon this contract is about: a DemonArchetypes.Type.
var demon_archetype: int = DemonArchetypes.Type.BRUTE
## Pins the archetype of every contract (the M test key and the regression tools); -1 lets it cycle.
var archetype_lock := -1

## The site's JuiceManager (camera shake, dust, sparks) and ShopManager; null in the menu.
var juice: Node
var shop: Node
## The site's NetSync while a co-op contract is running; null in solo and in the menu.
var net: Node
## The site's PossessionSystem.
var possession: Node
## The player this machine controls.
var local_player: Node
## The site's loose props in level order; a prop's index is its id on the wire.
var net_props: Array[RigidBody3D] = []

var _completed: Dictionary = {}
var _milestones: Dictionary = {}
var _task_override := ""
var _alert := ""


## Clears all progress on the current contract. Called by Main whenever the level is (re)built.
func reset() -> void:
	_completed.clear()
	_milestones.clear()
	_task_override = ""
	_alert = ""
	if is_authority():
		# Every contract starts with at least the free starter grenade, and no borrowed adrenaline.
		var changed := revive_boost or salt_charges < SALT_STARTER
		salt_charges = maxi(salt_charges, SALT_STARTER)
		revive_boost = false
		if changed:
			loadout_changed.emit()
	refresh()


## True where the world is simulated: solo, or the co-op host. Clients only mirror it.
func is_authority() -> bool:
	return NetworkManager.is_authority()


## Moves on to the next job: new number, clean objective chain.
func advance_contract() -> void:
	if not is_authority():
		return
	contract_number += 1
	reset()
	contract_started.emit(contract_number)


func get_contract_title() -> String:
	return "CONTRACT #%04d // %s" % [contract_number, SITE_NAME]


## Pays the crew. Returns the new balance.
func add_cash(amount: int) -> int:
	if not is_authority():
		return bank_cash
	bank_cash += amount
	bank_changed.emit(bank_cash)
	return bank_cash


## Takes `amount` out of the bank if it is there. Host only, like every other mutator.
func spend_cash(amount: int) -> bool:
	if not is_authority() or amount < 0 or amount > bank_cash:
		return false
	bank_cash -= amount
	bank_changed.emit(bank_cash)
	return true


# --- Field shop loadout ----------------------------------------------------------------

func get_upgrade(id: StringName) -> int:
	return int(upgrades.get(id, 0))


func set_upgrade(id: StringName, level: int) -> void:
	if not is_authority() or not upgrades.has(id):
		return
	level = clampi(level, 0, UPGRADE_MAX)
	if level != int(upgrades[id]):
		upgrades[id] = level
		loadout_changed.emit()


## Adds grenades to the crew's pool (capped at SALT_MAX). Returns the new count.
func add_salt(count: int) -> int:
	if is_authority():
		var total := clampi(salt_charges + count, 0, SALT_MAX)
		if total != salt_charges:
			salt_charges = total
			loadout_changed.emit()
	return salt_charges


## Takes one grenade out of the pool; false when it is empty.
func use_salt() -> bool:
	if not is_authority() or salt_charges <= 0:
		return false
	salt_charges -= 1
	loadout_changed.emit()
	return true


func set_revive_boost(active: bool) -> void:
	if is_authority() and active != revive_boost:
		revive_boost = active
		loadout_changed.emit()


## Host: the kind of demon the contract is about. Every peer hears `archetype_changed`.
func set_archetype(kind: int) -> void:
	if not is_authority() or kind == demon_archetype:
		return
	demon_archetype = kind
	archetype_changed.emit(kind)


## The archetype a contract should open with: the pinned one, else the cycle by career length.
func pick_archetype() -> int:
	return archetype_lock if archetype_lock >= 0 else DemonArchetypes.for_contract(contracts_completed)


# --- Juice ---------------------------------------------------------------------------

## A world effect with its camera shake (see JuiceManager), here and on every client.
## Only the host's call does anything in co-op: clients get theirs over the wire.
func fx(kind: StringName, at: Vector3, strength: float = 1.0) -> void:
	if is_instance_valid(juice):
		juice.call(&"emit_fx", kind, at, strength)


## Shakes this machine's camera by up to `amount` (0..1), fading to nothing `radius` metres from `at`.
func shake_at(at: Vector3, amount: float, radius: float = 14.0) -> void:
	if is_instance_valid(juice):
		juice.call(&"shake_at", at, amount, radius)


# --- Settings --------------------------------------------------------------------------

## One value from user://settings.cfg (audio volumes, language).
func get_setting(section: String, key: String, default: Variant = null) -> Variant:
	var file := ConfigFile.new()
	if file.load(SETTINGS_PATH) != OK:
		return default
	return file.get_value(section, key, default)


## Writes one value, keeping every other section of the file as it was.
func set_setting(section: String, key: String, value: Variant) -> void:
	var file := ConfigFile.new()
	file.load(SETTINGS_PATH)
	file.set_value(section, key, value)
	file.save(SETTINGS_PATH)


## Re-emits the current objective so late listeners (the HUD) can sync.
func refresh() -> void:
	objective_changed.emit(get_contract_title(), get_current_task(), get_progress(), _completed.size(), STEPS.size())


## Marks a step as done. Steps may be completed in any order; repeats are ignored.
func complete_step(id: StringName) -> void:
	if not is_authority():
		return
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
	post_notice("DONE: %s" % task)
	refresh()
	if is_contract_complete():
		contracts_completed += 1
		contract_completed.emit()


## Re-opens a step whose condition no longer holds (the demon woke up or was hauled back out).
func revoke_step(id: StringName) -> void:
	if not is_authority():
		return
	if _milestones.erase(id):
		return
	if _completed.erase(id):
		refresh()


## One-line message in the HUD's notice strip, for the whole crew.
func post_notice(text: String) -> void:
	notice_posted.emit(text)
	if is_authority() and is_instance_valid(net):
		net.call(&"send_notice", text, 0)


## A notice only `player` needs to read (their taser overheated, their rope snapped).
func post_notice_for(player: Object, text: String) -> void:
	if player == null or not is_instance_valid(player) or player.get(&"is_local"):
		notice_posted.emit(text)
	elif is_authority() and is_instance_valid(net):
		net.call(&"send_notice", text, int(player.get(&"peer_id")))


## Replaces the banner's task line with a more pressing instruction ("" restores it).
func set_task_override(text: String) -> void:
	if text == _task_override or not is_authority():
		return
	_task_override = text
	refresh()


## An emergency that outranks both the task and its override ("EXORCISE DANA!"). "" clears it.
func set_alert(text: String) -> void:
	if text == _alert or not is_authority():
		return
	_alert = text
	refresh()


func get_alert() -> String:
	return _alert


func is_step_done(id: StringName) -> bool:
	return _completed.has(id) or _milestones.has(id)


func is_contract_complete() -> bool:
	return _completed.size() >= STEPS.size()


func get_progress() -> float:
	return float(_completed.size()) / float(STEPS.size())


## The first unfinished task, in contract order, unless something more pressing overrides it.
func get_current_task() -> String:
	if not _alert.is_empty():
		return _alert
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


# --- Crew --------------------------------------------------------------------------

## Every exorcist on site. All of them are people: there are no bots.
func get_players() -> Array[Node3D]:
	var found: Array[Node3D] = []
	for node in get_tree().get_nodes_in_group(GROUP_PLAYER):
		if is_instance_valid(node) and not node.is_queued_for_deletion() and node is Node3D:
			found.append(node as Node3D)
	return found


func get_player_at_seat(seat: int) -> Node3D:
	for player in get_players():
		if int(player.get(&"seat")) == seat:
			return player
	return null


# --- Replication ---------------------------------------------------------------------

## True for a rigid body that can be grabbed, roped or shocked. On a client such bodies
## are frozen mirrors of the host's, so `freeze` alone would say no.
func is_loose(body: Object) -> bool:
	var rigid := body as RigidBody3D
	return rigid != null and (not rigid.freeze or rigid.has_meta(&"net_mirror"))


## Wire id of a prop, a demon limb or a player; 0 for anything else.
func body_ref(body: Object) -> int:
	if body == null or not is_instance_valid(body) or not (body is Node):
		return 0
	var node := body as Node
	if node.has_meta(&"demon_part"):
		return REF_DEMON + int(node.get_meta(&"demon_part"))
	if node.is_in_group(GROUP_PLAYER):
		return REF_PLAYER + int(node.get(&"seat"))
	if node.has_meta(&"net_id"):
		return 1 + int(node.get_meta(&"net_id"))
	return 0


func ref_body(ref: int) -> Node3D:
	if ref <= 0:
		return null
	if ref >= REF_PLAYER:
		return get_player_at_seat(ref - REF_PLAYER)
	if ref >= REF_DEMON:
		var demon := get_tree().get_first_node_in_group(GROUP_DEMON)
		if not is_instance_valid(demon) or demon.is_queued_for_deletion():
			return null
		return demon.call(&"get_body", ref - REF_DEMON) as Node3D
	var index := ref - 1
	if index >= net_props.size() or not is_instance_valid(net_props[index]):
		return null
	return net_props[index]


## Everything a client needs to mirror the contract's progress.
func get_sync() -> Array:
	var done: Array[String] = []
	for id: StringName in _completed:
		done.append(String(id))
	var marks: Array[String] = []
	for id: StringName in _milestones:
		marks.append(String(id))
	return [contract_number, contracts_completed, bank_cash, done, marks, _task_override, _alert,
			demon_archetype, get_upgrade(UPGRADE_TASER), get_upgrade(UPGRADE_LASSO), get_upgrade(UPGRADE_TAPE),
			salt_charges, revive_boost]


func apply_sync(data: Array) -> void:
	if data.size() < 7:
		return
	var number := int(data[0])
	var started := number != contract_number
	contract_number = number
	contracts_completed = int(data[1])
	_completed.clear()
	for id: Variant in data[3]:
		_completed[StringName(str(id))] = true
	_milestones.clear()
	for id: Variant in data[4]:
		_milestones[StringName(str(id))] = true
	_task_override = str(data[5])
	_alert = str(data[6])
	var cash := int(data[2])
	if cash != bank_cash:
		bank_cash = cash
		bank_changed.emit(bank_cash)
	if data.size() >= 13:
		_apply_loadout(data)
	if started:
		contract_started.emit(contract_number)
	refresh()


func _apply_loadout(data: Array) -> void:
	var kind := int(data[7])
	if kind != demon_archetype:
		demon_archetype = kind
		archetype_changed.emit(kind)
	var gear := {UPGRADE_TASER: int(data[8]), UPGRADE_LASSO: int(data[9]), UPGRADE_TAPE: int(data[10])}
	var salt := int(data[11])
	var boost := bool(data[12])
	if gear != upgrades or salt != salt_charges or boost != revive_boost:
		upgrades = gear
		salt_charges = salt
		revive_boost = boost
		loadout_changed.emit()


func _task_for(id: StringName) -> String:
	for step: Dictionary in STEPS:
		if step["id"] == id:
			return step["task"]
	return ""
