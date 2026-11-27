extends Node3D
## The exorcist's tool belt: three gadgets and a pair of empty hands.
##
## Slots: 1 Holy Lasso, 2 Holy Taser, 3 Duct Tape; 0 (or the active slot's key
## again) puts everything away; the mouse wheel cycles. LMB / RMB work the tool
## in hand. E always grabs with the bare hands: the tool drops out of the way for
## as long as the grab lasts, and comes back up afterwards.
##
## The manager owns the held model's pose. In first person the model leads and
## the gloves follow it (ExorcistModel solves the arms onto the grip points); in
## third person the same model rides the character's hand. It adds the equip
## swing, walk bob, view sway and recoil that every tool shares.

signal slot_changed(slot: int)

const Gadget := preload("res://scripts/gadgets/Gadget.gd")
const HolyLasso := preload("res://scripts/gadgets/HolyLasso.gd")
const HolyTaser := preload("res://scripts/gadgets/HolyTaser.gd")
const DuctTape := preload("res://scripts/gadgets/DuctTape.gd")
const GadgetAudio := preload("res://scripts/gadgets/GadgetAudio.gd")

enum Slot { HANDS, LASSO, TASER, TAPE }

const SLOT_TITLES: Array[String] = ["HANDS", "HOLY LASSO", "HOLY TASER", "DUCT TAPE"]
const HANDS_HINT := "[LMB / E] Grab   [RMB] Throw   [1] Lasso   [2] Taser   [3] Duct tape"
## Seconds to lower one tool, and again to raise the next.
const SWAP_TIME := 0.15

var slot: int = Slot.HANDS
var lasso: HolyLasso
var taser: HolyTaser
var tape: DuctTape
var audio: GadgetAudio

## The Player controller and its ExorcistModel. Untyped: Player.gd depends on this script.
var _player
var _model
var _camera: Camera3D
var _gadgets: Array[Gadget] = []
## The tool whose model is in hand right now; trails `slot` during a swap.
var _shown: int = Slot.HANDS
var _raise := 0.0
var _fire_locked := false
var _was_fire := false
var _was_alt := false
var _stride := 0.0
var _sway := Vector2.ZERO
var _last_view := Basis.IDENTITY
var _pose := Transform3D.IDENTITY
var _lamp: OmniLight3D


func setup(player: Node, model: Node, camera: Camera3D) -> void:
	_player = player
	_model = model
	_camera = camera
	audio = GadgetAudio.new()
	audio.name = "Audio"
	add_child(audio)
	lasso = HolyLasso.new()
	lasso.name = "HolyLasso"
	taser = HolyTaser.new()
	taser.name = "HolyTaser"
	tape = DuctTape.new()
	tape.name = "DuctTape"
	_gadgets = [null, lasso, taser, tape]
	for i in range(1, _gadgets.size()):
		add_child(_gadgets[i])
		_gadgets[i].setup(self, player, audio)
	# Spill from the helmet lamp: lights the tool in hand (and the gloves on it) and nothing
	# else, so dark steel can still be read against a dark house.
	_lamp = OmniLight3D.new()
	_lamp.name = "HandLamp"
	_lamp.top_level = true
	_lamp.light_color = Color(1.0, 0.92, 0.8)
	_lamp.omni_range = 1.4
	_lamp.omni_attenuation = 0.8
	_lamp.light_cull_mask = Gadget.VIEW_LAYER
	_lamp.light_volumetric_fog_energy = 0.0
	_lamp.shadow_enabled = false
	_lamp.visible = false
	add_child(_lamp)
	_model.pose_updated.connect(_place_view)


# --- Public API --------------------------------------------------------------------

## Switches slot. Asking for the slot already in hand puts it away.
func select(index: int) -> void:
	index = clampi(index, 0, _gadgets.size() - 1)
	_set_slot(Slot.HANDS if index == slot else index)


func is_armed() -> bool:
	return slot != Slot.HANDS


func get_title() -> String:
	return SLOT_TITLES[slot]


func get_hint() -> String:
	return _gadgets[slot].get_hint() if slot != Slot.HANDS else HANDS_HINT


## Short status word under a HUD slot (1-3).
func get_badge(index: int) -> String:
	return _gadgets[index].get_badge() if index > 0 and index < _gadgets.size() else ""


func get_battery() -> float:
	return taser.battery / 100.0


func get_progress() -> float:
	return _gadgets[slot].get_progress() if slot != Slot.HANDS else 0.0


func get_progress_label() -> String:
	return _gadgets[slot].get_progress_label() if slot != Slot.HANDS else ""


## How far up the tool in hand is, 0 (holstered) to 1 (ready).
func get_raise() -> float:
	return _raise


func is_demon_anchored(demon: Node) -> bool:
	return lasso.is_anchoring(demon)


## World position of the right glove; where a rope is held when no tool model is showing.
func get_hand_position() -> Vector3:
	return _model.get_palm_position(1)


## The next LMB press is swallowed (it was spent on a menu or on recapturing the mouse).
func lock_fire() -> void:
	_fire_locked = true


## Fresh batteries, coiled rope, a new roll: called between contracts.
func reset() -> void:
	for i in range(1, _gadgets.size()):
		_gadgets[i].reset()
	audio.stop_loops()
	_was_fire = false
	_was_alt = false


# --- Input -------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _player.controls_locked:
		return
	var key := event as InputEventKey
	if key and key.pressed and not key.echo:
		match key.physical_keycode:
			KEY_1:
				select(Slot.LASSO)
			KEY_2:
				select(Slot.TASER)
			KEY_3:
				select(Slot.TAPE)
			KEY_0:
				_set_slot(Slot.HANDS)
			KEY_R:
				lasso.request_release()
		return
	var button := event as InputEventMouseButton
	if button and button.pressed:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_slot(posmod(slot - 1, _gadgets.size()))
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_slot(posmod(slot + 1, _gadgets.size()))


func _set_slot(index: int) -> void:
	if index == slot:
		return
	if slot != Slot.HANDS:
		_gadgets[slot].holstered()
	slot = index
	audio.play(&"equip", (_player as Node3D).global_position + Vector3.UP * 1.2, -6.0)
	slot_changed.emit(slot)


## Knocked flat, hauling something by hand, or looking at a menu: the tool hangs at the hip.
func _is_lowered() -> bool:
	return _player.is_knocked_down() or _player.is_hand_grabbing() or _player.controls_locked


func _physics_process(delta: float) -> void:
	var usable := slot != Slot.HANDS and _shown == slot and _raise > 0.9 and not _is_lowered()
	var fire_down := Input.is_action_pressed(&"gadget_fire")
	if not fire_down:
		_fire_locked = false
	var fire := usable and fire_down and not _fire_locked
	var alt := usable and Input.is_action_pressed(&"gadget_alt")
	var input := {"fire": fire, "fire_pressed": fire and not _was_fire, "fire_released": _was_fire and not fire, "alt_pressed": alt and not _was_alt}
	_was_fire = fire
	_was_alt = alt
	if _shown != Slot.HANDS and _shown == slot:
		_gadgets[slot].use(delta, input)
	for i in range(1, _gadgets.size()):
		_gadgets[i].simulate(delta)


# --- Pose --------------------------------------------------------------------------

func _process(delta: float) -> void:
	var up := _shown == slot and slot != Slot.HANDS and not _is_lowered()
	_raise = move_toward(_raise, 1.0 if up else 0.0, delta / SWAP_TIME)
	if _raise <= 0.0 and _shown != slot:
		if _shown != Slot.HANDS:
			_gadgets[_shown].view.visible = false
		_shown = slot
		if _shown != Slot.HANDS:
			_gadgets[_shown].equipped()
	var gadget: Gadget = _gadgets[_shown]
	if gadget == null or _raise <= 0.02:
		_model.set_tool(false)
		return
	gadget.kick = maxf(0.0, gadget.kick - delta * 6.0)
	gadget.animate(delta)

	var speed := Vector2(_player.velocity.x, _player.velocity.z).length()
	if speed > 0.3 and _player.is_on_floor():
		_stride += delta * (5.0 + speed * 1.6)
	var gait := clampf(speed / 4.4, 0.0, 1.4)
	var bob := Vector3(sin(_stride * 0.5) * 0.011, absf(cos(_stride * 0.5)) * 0.014 - 0.007, 0.0) * gait
	# The view turning drags the tool a little behind it.
	var view_basis := _camera.global_transform.basis.orthonormalized()
	var turn := (_last_view.inverse() * view_basis).get_euler()
	_last_view = view_basis
	_sway = _sway.lerp(Vector2(turn.y, turn.x) * 0.8, minf(1.0, delta * 10.0)).limit_length(0.07)
	var drop := 1.0 - smoothstep(0.0, 1.0, _raise)
	var shift := gadget.get_view_shift()
	if _player.is_first_person_view():
		var offset := gadget.view_offset + bob + Vector3(-_sway.x * 0.5, _sway.y * 0.4, 0.0)
		offset += Vector3(0.03, -0.42, 0.08) * drop + Vector3(0.0, 0.012, 0.055) * gadget.kick
		var tilt := Basis.from_euler(gadget.view_tilt + Vector3(0.14 * gadget.kick - 0.9 * drop, 0.3 * drop, 0.0))
		_pose = Transform3D(view_basis, _camera.global_position) * Transform3D(tilt, offset) * shift
	else:
		# Carried at the ready in front of the chest, tipping with the line of sight.
		var body: Transform3D = (_player as Node3D).global_transform
		var pitch: float = _player.get_look_pitch()
		var tilt := Basis(Vector3.RIGHT, pitch * 0.55 - 0.7 * drop) * Basis.from_euler(gadget.view_tilt * 0.4)
		_pose = body * Transform3D(tilt, gadget.body_offset + bob + Vector3(0.0, -0.3, 0.1) * drop) * shift
	_model.set_tool(true, Transform3D(_pose.basis * Gadget.GRIP_RIGHT, _pose * gadget.palm_right),
			Transform3D(_pose.basis * Gadget.GRIP_LEFT, _pose * gadget.palm_left), gadget.two_handed, gadget.grip)


## Runs once the arms are solved: the model is hung on the glove that actually holds it.
func _place_view() -> void:
	var gadget: Gadget = _gadgets[_shown]
	if gadget == null or _raise <= 0.02 or _player.is_knocked_down():
		if gadget:
			gadget.view.visible = false
		_lamp.visible = false
		return
	var palm: Vector3 = _model.get_palm_position(1)
	gadget.view.global_transform = Transform3D(_pose.basis, palm - _pose.basis * gadget.palm_right)
	gadget.view.visible = true
	# Up and back from the tool, on the holder's side of it.
	_lamp.global_position = gadget.view.global_transform * Vector3(-0.16, 0.3, 0.3)
	_lamp.light_energy = 1.1 * _raise
	_lamp.visible = true
