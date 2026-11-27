extends Node
## The van's field shop (child of Main, named "Shop"; also `GameState.shop`).
##
## Sells gadget upgrades, salt grenades and the auto-injector out of the crew's bank.
## The host decides every purchase; a client's request goes to it over the wire and
## the result comes back with the rest of the contract state (GameState.upgrades,
## salt_charges, bank_cash). It also owns the shop screen and the salt grenades in flight.

signal purchased(item: StringName, peer_id: int)
signal purchase_denied(item: StringName, reason: String)
## A salt grenade went off at `at` (every machine).
signal grenade_burst(at: Vector3)

const ITEM_TASER := &"taser"
const ITEM_LASSO := &"lasso"
const ITEM_TAPE := &"tape"
const ITEM_SALT := &"salt"
const ITEM_INJECTOR := &"injector"
## Display order.
const ITEM_IDS: Array[StringName] = [ITEM_TASER, ITEM_LASSO, ITEM_TAPE, ITEM_SALT, ITEM_INJECTOR]


func setup(_main: Node) -> void:
	GameState.shop = self


func _exit_tree() -> void:
	if GameState.shop == self:
		GameState.shop = null


## Title, description and stats line of an item, in English (Loc translates on display).
func get_item(_item: StringName) -> Dictionary:
	return {}


## Price of the next purchase of `item`; -1 when it is maxed out.
func get_cost(_item: StringName) -> int:
	return -1


## Level owned (upgrades), charges in the pool (salt) or 0.
func get_level(_item: StringName) -> int:
	return 0


func can_buy(_item: StringName) -> bool:
	return false


## Asks for a purchase on behalf of this machine's player. Safe to call anywhere.
func request_buy(_item: StringName) -> void:
	pass


func open_ui() -> void:
	pass


func close_ui() -> void:
	pass


func is_ui_open() -> bool:
	return false
