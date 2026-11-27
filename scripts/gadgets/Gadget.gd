extends Node3D
## Base of the exorcist's hand-held gadgets.
##
## A gadget owns its held model (`view`), says where the gloves grip it, and is
## driven by the GadgetManager: `use()` runs on physics ticks while it is the tool
## in hand, `simulate()` on every physics tick (ropes stay tied and batteries
## recharge in the holster), `animate()` on every frame it is shown.
## Models are authored in metres with -Z pointing away from the holder.
##
## In co-op the host works every player's gadgets. Everywhere else a gadget is a
## puppet: `use()` and `simulate()` never run, and `read_net()` feeds it the few
## numbers its drawing code needs (see `write_net()`).

const Parts := preload("res://scripts/gadgets/GadgetParts.gd")

## Palm frames for a fist closed round a vertical grip: fingers forward, back of the hand outward.
const GRIP_RIGHT := Basis(Vector3(0.0, -1.0, 0.0), Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0))
const GRIP_LEFT := Basis(Vector3(0.0, 1.0, 0.0), Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0))
## Render layer of everything held at arm's length; the manager's hand lamp lights only this.
const VIEW_LAYER := 1 << 11

var manager: Node3D
## The Player controller. Untyped: Player.gd already depends on the gadget scripts.
var player
var audio: Node3D
var view: Node3D
var title := "GADGET"
## Where the model sits in first person (camera space) and third person (body space).
var view_offset := Vector3(0.2, -0.2, -0.46)
var view_tilt := Vector3.ZERO
var body_offset := Vector3(0.3, 1.2, -0.42)
## Palm positions on the model; `two_handed` puts the left glove on `palm_left`.
var palm_right := Vector3.ZERO
var palm_left := Vector3.ZERO
var two_handed := false
## How far the fingers close round it, 0..1.
var grip := 1.0
## Recoil, 0..1. The manager bleeds it off.
var kick := 0.0


func setup(owner_manager: Node3D, owner_player: Node, sound: Node3D) -> void:
	manager = owner_manager
	player = owner_player
	audio = sound
	view = Node3D.new()
	view.name = "View"
	view.top_level = true
	view.visible = false
	add_child(view)
	_build(view)
	_light_up(view)


## Puts every part of the held model on the hand lamp's layer.
func _light_up(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).layers |= VIEW_LAYER
	for child in node.get_children():
		_light_up(child)


func _build(_root: Node3D) -> void:
	pass


## `input` holds fire, fire_pressed, fire_released and alt_pressed (all false while the tool is lowered).
func use(_delta: float, _input: Dictionary) -> void:
	pass


func simulate(_delta: float) -> void:
	pass


func animate(_delta: float) -> void:
	pass


## Extra motion of the whole model on top of its resting pose (the tape's wrapping orbit).
func get_view_shift() -> Transform3D:
	return Transform3D.IDENTITY


func equipped() -> void:
	pass


func holstered() -> void:
	pass


## Back to factory state for a new contract.
func reset() -> void:
	kick = 0.0


func get_hint() -> String:
	return ""


## Short status word for the HUD slot.
func get_badge() -> String:
	return ""


func get_progress() -> float:
	return 0.0


func get_progress_label() -> String:
	return ""


## Appends this gadget's drawable state for the wire (fixed sizes: NET_FLOATS, NET_INTS).
func write_net(_floats: PackedFloat32Array, _ints: PackedInt32Array) -> void:
	pass


## The other end of `write_net`, on a machine where this gadget is a puppet.
func read_net(_floats: PackedFloat32Array, _f: int, _ints: PackedInt32Array, _i: int) -> void:
	pass


## A message for whoever holds this gadget, on whichever machine they are.
func notify(text: String) -> void:
	GameState.post_notice_for(player, text)


## True on a machine that only draws this gadget.
func is_puppet() -> bool:
	return not player.simulates


## The live demon, if there is one on site.
func find_demon() -> Node3D:
	var found := get_tree().get_first_node_in_group(GameState.GROUP_DEMON) as Node3D
	return found if is_instance_valid(found) and not found.is_queued_for_deletion() else null


func demon_of(body: Object) -> Node3D:
	if body is RigidBody3D and (body as RigidBody3D).has_meta(&"demon"):
		return (body as RigidBody3D).get_meta(&"demon") as Node3D
	return null
