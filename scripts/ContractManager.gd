extends Node
## Runs one extraction contract from break-in to payout, then deals the next.
##
## While the contract runs it keeps the clock, counts the props that got smashed
## about and nudges the objective banner ("Open van doors [F] first"). When the
## doors shut on the demon it bolts and seals the van, lets it rock while the
## cargo objects, then tots up the bounty and shows the summary card:
##   base $500, speed up to +$200, +$50 per bind level, up to +$100 for a tidy house.
## NEXT CONTRACT resets the site in place and spawns a tougher demon; KEEP
## EXPLORING just closes the card ([N] brings it back).

signal payout_ready(payout: Dictionary)

const SummaryScene := preload("res://scenes/ContractSummaryUI.tscn")
const GadgetAudio := preload("res://scripts/gadgets/GadgetAudio.gd")

enum Phase { RUNNING, SEALING, SUMMARY, EXPLORING }

const BASE_BOUNTY := 500
const SPEED_BONUS := 200
## Seconds: the full speed bonus at or under the first, none at or over the second.
const SPEED_FULL := 240.0
const SPEED_NONE := 720.0
const BIND_BONUS := 50
const CARE_BONUS := 100
const CARE_PARTIAL := 50
## Velocity change in one tick (m/s) that counts as a prop being smashed about.
const IMPACT_SPEED := 5.0
## Seconds between the doors sealing and the summary: the van rocks for most of it.
const SUMMARY_DELAY := 3.1

var phase: Phase = Phase.RUNNING
var elapsed := 0.0
var damaged_props := 0
var summary: CanvasLayer
var audio: GadgetAudio

## Main, the LevelBuilder and the Player. Untyped: they are only ever duck-typed here.
var _main
var _level
var _player
var _demon: Node3D
var _props: Array[RigidBody3D] = []
var _last_velocity := PackedVector3Array()
var _damaged: Dictionary = {}
var _wait := 0.0
var _hint_left := 0.0
var _paid := false


func setup(main: Node) -> void:
	_main = main
	_level = main.get(&"level")
	_player = main.get(&"player")
	audio = GadgetAudio.new()
	audio.name = "Audio"
	add_child(audio)
	summary = SummaryScene.instantiate() as CanvasLayer
	add_child(summary)
	summary.connect(&"next_pressed", next_contract)
	summary.connect(&"explore_pressed", keep_exploring)
	(_level.van as Node).connect(&"banged", _on_van_banged)
	GameState.contract_completed.connect(_on_contract_completed)
	_props = _level.get_props()
	_last_velocity.resize(_props.size())
	bind_demon(main.get(&"demon"))


func bind_demon(demon: Node3D) -> void:
	_demon = demon


## Line items of the payout as things stand right now.
func compute_payout() -> Dictionary:
	var bind := clampi(int(_demon.get(&"bind_level")), 0, 3) if is_instance_valid(_demon) else 0
	var pace := clampf(inverse_lerp(SPEED_NONE, SPEED_FULL, elapsed), 0.0, 1.0)
	var speed := int(round(SPEED_BONUS * pace / 5.0)) * 5
	var care := 0
	var care_note := "HOUSE TRASHED  (%d props wrecked - the landlord will be in touch)" % damaged_props
	if damaged_props == 0:
		care = CARE_BONUS
		care_note = "INTACT PROPERTY BONUS"
	elif damaged_props <= 3:
		care = CARE_PARTIAL
		care_note = "PROPERTY CARE  (%d scuffed)" % damaged_props
	elif damaged_props <= 8:
		care_note = "ROUGHED UP  (%d props knocked about)" % damaged_props
	return {
		"contract": GameState.contract_number,
		"time": elapsed,
		"base": BASE_BOUNTY,
		"speed": speed,
		"bind_level": bind,
		"bind": bind * BIND_BONUS,
		"care": care,
		"care_note": care_note,
		"damaged": damaged_props,
		"total": BASE_BOUNTY + speed + bind * BIND_BONUS + care,
	}


## NEXT CONTRACT: the house is put back together, the van unsealed, the crew returned to
## the kerb with fresh gear, and a new, slightly worse demon wakes on the dais.
func next_contract() -> void:
	if phase != Phase.SUMMARY and phase != Phase.EXPLORING:
		return
	summary.call(&"hide_summary")
	GameState.advance_contract()
	_level.reset_props()
	_level.reset_doors()
	_player.reset_for_contract(_level.player_spawn)
	_release_controls()
	bind_demon(_main.respawn_demon(GameState.contracts_completed))
	elapsed = 0.0
	damaged_props = 0
	_damaged.clear()
	_last_velocity.fill(Vector3.ZERO)
	_paid = false
	phase = Phase.RUNNING
	GameState.post_notice("%s  -  something new is awake in there" % GameState.get_contract_title())


## KEEP EXPLORING: the card goes away and the site is left as it is.
func keep_exploring() -> void:
	if phase != Phase.SUMMARY:
		return
	phase = Phase.EXPLORING
	summary.call(&"hide_summary")
	_release_controls()
	GameState.set_task_override("%s  [N] next contract" % GameState.ALL_DONE_TASK)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.physical_keycode == KEY_N and phase == Phase.EXPLORING:
		_show_summary()


func _physics_process(delta: float) -> void:
	match phase:
		Phase.RUNNING:
			elapsed += delta
			_track_damage()
			_hint_left -= delta
			if _hint_left <= 0.0:
				_hint_left = 0.25
				_update_hint()
		Phase.SEALING:
			_wait -= delta
			if _wait <= 0.0:
				_show_summary()


## A prop whose velocity jumps by more than IMPACT_SPEED in one tick was hurled or hit hard.
func _track_damage() -> void:
	for i in _props.size():
		var prop := _props[i]
		if not is_instance_valid(prop):
			continue
		var velocity := Vector3.ZERO if prop.sleeping else prop.linear_velocity
		if not _damaged.has(i) and (velocity - _last_velocity[i]).length_squared() > IMPACT_SPEED * IMPACT_SPEED:
			_damaged[i] = true
			damaged_props = _damaged.size()
		_last_velocity[i] = velocity


## A subdued demon arriving at a shut van: say so, instead of repeating "haul it to the van".
func _update_hint() -> void:
	var text := ""
	if is_instance_valid(_demon) and GameState.is_step_done(GameState.STEP_SUBDUE_DEMON) and not GameState.is_step_done(GameState.STEP_LOAD_DEMON):
		var van: Node3D = _level.van
		var chest: Vector3 = _demon.call(&"get_center")
		if not van.call(&"are_doors_open") and chest.distance_to(van.global_position) < 9.0:
			text = "Open van doors [F] first"
	GameState.set_task_override(text)


func _on_contract_completed() -> void:
	phase = Phase.SEALING
	_wait = SUMMARY_DELAY
	GameState.set_task_override("")
	var van: Node3D = _level.van
	van.call(&"seal")
	audio.play(&"slam", van.global_position + Vector3.UP * 1.5, 5.0)
	_player.shake(0.4)
	GameState.post_notice("DEMON CONTAINED  -  the seal is holding")


func _on_van_banged(strength: float) -> void:
	var van: Node3D = _level.van
	var at := van.global_position + Vector3.UP * 1.6
	audio.play(&"bang", at, lerpf(-1.0, 5.0, strength), randf_range(0.85, 1.1))
	if randf() < 0.5:
		audio.play(&"growl", at, 0.0, randf_range(0.85, 1.05))
	if at.distance_to((_player as Node3D).global_position) < 9.0:
		_player.shake(0.14 * strength)


func _show_summary() -> void:
	phase = Phase.SUMMARY
	var payout: Dictionary = GameState.last_payout
	if not _paid:
		_paid = true
		payout = compute_payout()
		payout["bank"] = GameState.add_cash(int(payout["total"]))
		GameState.last_payout = payout
		audio.play(&"chaching")
		payout_ready.emit(payout)
	_player.controls_locked = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	summary.call(&"show_summary", payout)


func _release_controls() -> void:
	_player.controls_locked = false
	# The click that pressed the button must not also fire a gadget.
	_player.gadgets.lock_fire()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
