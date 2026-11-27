extends CanvasLayer
## The field shop screen (scenes/ShopUI.tscn). Built in code like the rest of the UI.
## ShopManager owns one instance and shows it for this machine's player; it lists
## ShopManager.ITEM_IDS with price, level and a BUY button, and the crew's bank.

signal closed

var _shop: Node


func setup(shop: Node) -> void:
	_shop = shop


func is_open() -> bool:
	return visible


func open() -> void:
	visible = true


func close() -> void:
	if visible:
		visible = false
		closed.emit()


## Re-reads prices, levels and the bank.
func refresh() -> void:
	pass
