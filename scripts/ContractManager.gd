extends Node
## Runs one extraction contract from break-in to payout (or to failure), then deals the next.
##
## While the contract runs it keeps the clock, counts the props that got smashed
## about and nudges the objective banner ("Open van doors [F] first"). When the
## doors shut on the demon it bolts and seals the van, lets it rock while the
## cargo objects, then tots up the bounty and shows the summary card:
##   base $500, speed up to +$200, +$50 per bind level, up to +$100 for a tidy house.
## NEXT CONTRACT resets the site in place and spawns a tougher demon; KEEP
## EXPLORING just closes the card ([N] brings it back).
##
## The contract is FAILED the moment nobody is left standing: every player downed in
## co-op, or a lone player downed with their second wind already spent. That pays
## nothing, files an incident report, and offers RETRY CONTRACT (same demon tier).
##
## In co-op the host runs all of this; clients are told what to show (see NetSync).

signal payout_ready(payout: Dictionary)
signal contract_failed(report: Dictionary)

const SummaryScene := preload("res://scenes/ContractSummaryUI.tscn")
const GadgetAudio := preload("res://scripts/gadgets/GadgetAudio.gd")

enum Phase { RUNNING, SEALING, SUMMARY, EXPLORING, FAILED }

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
## Seconds between the last exorcist hitting the floor and the incident report.
const FAILURE_DELAY := 1.6

## What head office has to say about it. One line of each kind goes on the report.
const FAILURE_CAUSES: Array[String] = [
	"Crew found resting face-down on site. Unpaid.",
	"Entire team horizontal at time of inspection.",
	"Demon reports the exorcists 'gave up first'.",
	"All personnel temporarily reclassified as furniture.",
]
const FAILURE_NOTES: Array[String] = [
	"The client has asked for the demon's contact details instead.",
	"Hazmat suits are a deductible item. So is the demon.",
	"Head office reminds staff that the tape goes ON the demon.",
	"Please stop letting it throw the good chairs.",
	"A strongly worded sigil has been added to your file.",
]

var phase: Phase = Phase.RUNNING
var elapsed := 0.0
var damaged_props := 0
var failures := 0
var summary: CanvasLayer
var audio: GadgetAudio
var last_report: Dictionary = {}

## Main, the LevelBuilder and this machine's Player. Untyped: they are only ever duck-typed here.
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
var _failing := false


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
	summary.connect(&"retry_pressed", retry_contract)
	summary.connect(&"menu_pressed", _on_menu_pressed)
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


## The paperwork for a lost contract: $0 and head office's opinion.
func compute_report() -> Dictionary:
	var crew := NetworkManager.get_player_count()
	var lines: Array[String] = [FAILURE_CAUSES[randi() % FAILURE_CAUSES.size()]]
	if is_instance_valid(_demon):
		var bind := int(_demon.get(&"bind_level"))
		if bind > 0:
			lines.append("Demon last seen wearing %d wrap(s) of company tape. Tape not recovered." % bind)
		else:
			lines.append("Demon at large, untaped, and now aware of our methods.")
	if damaged_props > 0:
		lines.append("%d household item(s) used as ammunition against staff." % damaged_props)
	if crew <= 1:
		lines.append("One auto-injector expended. It was the only one.")
	else:
		lines.append("%d exorcists down at once. Nobody left to do the reviving." % crew)
	lines.append(FAILURE_NOTES[randi() % FAILURE_NOTES.size()])
	return {"contract": GameState.contract_number, "time": elapsed, "crew": crew, "lines": lines, "total": 0}


## NEXT CONTRACT: the house is put back together, the van unsealed, the crew returned to
## the kerb with fresh gear, and a new, slightly worse demon wakes on the dais.
func next_contract() -> void:
	if not GameState.is_authority() or (phase != Phase.SUMMARY and phase != Phase.EXPLORING):
		return
	_reset_site(true)
	GameState.post_notice("%s  -  something new is awake in there" % GameState.get_contract_title())


## RETRY CONTRACT: the same job again from the kerb, against a demon of the same tier.
func retry_contract() -> void:
	if not GameState.is_authority() or phase != Phase.FAILED:
		return
	_reset_site(false)
	GameState.post_notice("%s  -  take two" % GameState.get_contract_title())


func _reset_site(advance: bool) -> void:
	summary.call(&"hide_summary")
	if advance:
		GameState.advance_contract()
	else:
		GameState.reset()
	_level.reset_props()
	_level.reset_doors()
	var tier := GameState.contracts_completed
	# Everyone else's gadgets are worked here too: coil their ropes and charge their tasers.
	for body: Node in (_main.players as Dictionary).values():
		if body != _player and is_instance_valid(body):
			(body.get(&"gadgets") as Node).call(&"reset")
	_player.reset_for_contract(_main.get_local_spawn())
	_release_controls()
	bind_demon(_main.respawn_demon(tier))
	elapsed = 0.0
	damaged_props = 0
	_damaged.clear()
	_last_velocity.fill(Vector3.ZERO)
	_paid = false
	_failing = false
	phase = Phase.RUNNING
	if is_instance_valid(GameState.net):
		GameState.net.call(&"site_reset", tier)


## KEEP EXPLORING: the card goes away and the site is left as it is.
func keep_exploring() -> void:
	if phase != Phase.SUMMARY:
		return
	phase = Phase.EXPLORING
	summary.call(&"hide_summary")
	_release_controls()
	GameState.set_task_override("%s  [N] next contract" % GameState.ALL_DONE_TASK)


# --- What the host tells a client to show ------------------------------------------------

func remote_summary(payout: Dictionary) -> void:
	GameState.last_payout = payout
	phase = Phase.SUMMARY
	audio.play(&"chaching")
	_open_card()
	summary.call(&"show_summary", payout, false)


func remote_failure(report: Dictionary) -> void:
	last_report = report
	phase = Phase.FAILED
	_open_card()
	summary.call(&"show_failure", report, false)


## The host has reset the site (next contract or retry): back to the kerb with fresh gear.
func remote_reset(tier: int) -> void:
	summary.call(&"hide_summary")
	_player.reset_for_contract(_main.get_local_spawn())
	_release_controls()
	bind_demon(_main.respawn_demon(tier))
	phase = Phase.RUNNING


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.physical_keycode == KEY_N and phase == Phase.EXPLORING:
		_show_summary()


func _physics_process(delta: float) -> void:
	if not GameState.is_authority():
		return
	match phase:
		Phase.RUNNING:
			elapsed += delta
			_track_damage()
			_hint_left -= delta
			if _hint_left <= 0.0:
				_hint_left = 0.25
				_update_hint()
			_watch_crew(delta)
		Phase.SEALING:
			_wait -= delta
			if _wait <= 0.0:
				_show_summary()


## The contract is lost once nobody is on their feet. A beat is left between the last
## body hitting the floor and the report, so the fall is seen.
func _watch_crew(delta: float) -> void:
	var crew := GameState.get_players()
	var standing := false
	for body in crew:
		if not body.get(&"is_downed"):
			standing = true
			break
	if standing or crew.is_empty():
		_failing = false
		return
	if not _failing:
		_failing = true
		_wait = FAILURE_DELAY
		return
	_wait -= delta
	if _wait <= 0.0:
		fail_contract()


## Nobody left standing: no pay, an incident report, and the offer of another go.
func fail_contract() -> void:
	if phase == Phase.FAILED or not GameState.is_authority():
		return
	phase = Phase.FAILED
	failures += 1
	_failing = false
	GameState.set_task_override("")
	GameState.set_alert("")
	last_report = compute_report()
	audio.play(&"bang")
	_open_card()
	summary.call(&"show_failure", last_report, true)
	contract_failed.emit(last_report)
	if is_instance_valid(GameState.net):
		GameState.net.call(&"show_failure", last_report)


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
	if GameState.is_authority():
		# One roll of the dice for everybody: the host's sounds are passed on to the clients.
		audio.play(&"bang", at, lerpf(-1.0, 5.0, strength), randf_range(0.85, 1.1))
		if randf() < 0.5:
			audio.play(&"growl", at, 0.0, randf_range(0.85, 1.05))
	if at.distance_to((_player as Node3D).global_position) < 9.0:
		_player.shake(0.14 * strength)


func _show_summary() -> void:
	phase = Phase.SUMMARY
	var payout: Dictionary = GameState.last_payout
	if not _paid and GameState.is_authority():
		_paid = true
		payout = compute_payout()
		payout["bank"] = GameState.add_cash(int(payout["total"]))
		GameState.last_payout = payout
		audio.play(&"chaching")
		payout_ready.emit(payout)
		if is_instance_valid(GameState.net):
			GameState.net.call(&"show_summary", payout)
	_open_card()
	summary.call(&"show_summary", payout, GameState.is_authority())


## A report card is going up: it owns the mouse, and nothing in the world listens to the keys.
func _open_card() -> void:
	var pause: Variant = _main.get(&"pause_menu")
	if is_instance_valid(pause):
		(pause as Node).call(&"close")
	_player.controls_locked = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_menu_pressed() -> void:
	NetworkManager.return_to_menu()


func _release_controls() -> void:
	_player.controls_locked = false
	# The click that pressed the button must not also fire a gadget.
	_player.gadgets.lock_fire()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
