extends Node
## Session and lobby layer for BIND & DELIVER (autoload: `NetworkManager`).
##
## Solo play never opens a socket. Co-op is 2-4 humans over ENet: one hosts and runs
## the authoritative simulation (demon, props, van, contract), the others join by
## address. This node owns the peer, the roster (name + suit per player) and the
## scene flow menu -> contract -> menu; the per-contract replication lives in
## NetSync, a child of Main. There are no bots: every roster entry is a person.

signal roster_changed
signal joined_lobby
signal connection_failed(reason: String)
## The session ended under us while still in the lobby (the host left).
signal session_closed(reason: String)
signal player_left(id: int)
## A peer has built its site and can take in-game RPCs.
signal peer_ready(id: int)

enum Mode { SOLO, HOST, CLIENT }

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 4
const MENU_SCENE := "res://scenes/LobbyMenu.tscn"
const GAME_SCENE := "res://scenes/Main.tscn"
const SUIT_NAMES: Array[String] = ["ORANGE", "TEAL", "OLIVE", "PURPLE"]
const NAME_LIMIT := 14

var mode: Mode = Mode.SOLO
## Peer id -> {"name": String, "suit": int}. Solo is the single entry 1.
var players: Dictionary = {}
var local_name := "EXORCIST"
var local_suit := 0
var port := DEFAULT_PORT
var in_game := false
## Shown by the menu after being dropped back to it (host quit, connection lost).
var last_message := ""

var _ready_peers: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_reset_roster()


# --- Queries -----------------------------------------------------------------------

func is_networked() -> bool:
	return mode != Mode.SOLO


## True on the machine that simulates the world: solo, or the co-op host.
func is_authority() -> bool:
	return mode != Mode.CLIENT


func local_id() -> int:
	return 1 if mode == Mode.SOLO else multiplayer.get_unique_id()


## Humans in the session. Never less than one.
func get_player_count() -> int:
	return maxi(1, players.size())


## Roster ids in seat order: the host first, then joiners by id. Identical on every peer.
func get_ids() -> Array[int]:
	var ids: Array[int] = []
	for id: int in players:
		ids.append(id)
	ids.sort()
	return ids


## 0-3: which spawn spot and body slot a player takes.
func get_seat(id: int) -> int:
	return maxi(0, get_ids().find(id))


func get_player_name(id: int) -> String:
	return str((players.get(id, {}) as Dictionary).get("name", "EXORCIST"))


func get_player_suit(id: int) -> int:
	return int((players.get(id, {}) as Dictionary).get("suit", 0))


func is_peer_ready(id: int) -> bool:
	return _ready_peers.has(id)


## This machine's LAN addresses, for the host to read out to friends.
func get_local_addresses() -> PackedStringArray:
	var found := PackedStringArray()
	for address in IP.get_local_addresses():
		if address.count(".") == 3 and not address.begins_with("127.") and not address.begins_with("169.254."):
			found.append(address)
	if found.is_empty():
		found.append("127.0.0.1")
	return found


# --- Session -----------------------------------------------------------------------

## Opens a lobby on `listen_port`. Returns OK, or the socket error (port in use).
func host_game(listen_port: int, player_name: String, suit: int) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(listen_port, MAX_PLAYERS - 1)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	port = listen_port
	set_identity(player_name, suit)
	return OK


## Starts connecting; `joined_lobby` or `connection_failed` follows.
func join_game(address: String, join_port: int, player_name: String, suit: int) -> Error:
	leave()
	local_name = _clean_name(player_name)
	local_suit = posmod(suit, SUIT_NAMES.size())
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address.strip_edges(), join_port)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	port = join_port
	players.clear()
	roster_changed.emit()
	return OK


## Name and suit colour; safe to call at any time in the menu.
func set_identity(player_name: String, suit: int) -> void:
	local_name = _clean_name(player_name)
	local_suit = posmod(suit, SUIT_NAMES.size())
	match mode:
		Mode.CLIENT:
			if _is_connected():
				_register.rpc_id(1, local_name, local_suit)
		_:
			players[1] = {"name": local_name, "suit": local_suit}
			_broadcast_roster()


## Closes the socket (if any) and falls back to a one-person roster.
func leave() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer and not (peer is OfflineMultiplayerPeer):
		peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.SOLO
	in_game = false
	_ready_peers.clear()
	_reset_roster()


## PLAY SOLO: one human, no socket, straight into the contract.
func start_solo() -> void:
	leave()
	in_game = true
	_go(GAME_SCENE)


## START CONTRACT (host): the lobby is closed to newcomers and everyone loads the site.
func start_contract() -> void:
	if mode != Mode.HOST:
		return
	(multiplayer.multiplayer_peer as ENetMultiplayerPeer).refuse_new_connections = true
	_begin_game.rpc()


## Back to the title screen, dropping out of any session. The others carry on (or, if
## this was the host, are sent back to their own menus).
func return_to_menu(message: String = "") -> void:
	last_message = message
	leave()
	_go(MENU_SCENE)


## Called by Main once its site is built and its NetSync can take RPCs.
func announce_ready() -> void:
	_ready_peers[local_id()] = true
	if mode != Mode.SOLO and _is_connected():
		_peer_ready.rpc()
	peer_ready.emit(local_id())


# --- RPCs --------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _register(player_name: String, suit: int) -> void:
	if mode != Mode.HOST:
		return
	var id := multiplayer.get_remote_sender_id()
	# A contract in progress cannot be joined half-way.
	if in_game and not players.has(id):
		return
	players[id] = {"name": _clean_name(player_name), "suit": posmod(suit, SUIT_NAMES.size())}
	_broadcast_roster()


@rpc("authority", "call_remote", "reliable")
func _sync_roster(roster: Dictionary) -> void:
	var before := players.keys()
	players = roster
	roster_changed.emit()
	for id: int in before:
		if not players.has(id):
			_ready_peers.erase(id)
			player_left.emit(id)


@rpc("authority", "call_local", "reliable")
func _begin_game() -> void:
	in_game = true
	_ready_peers.clear()
	_go(GAME_SCENE)


@rpc("any_peer", "call_remote", "reliable")
func _peer_ready() -> void:
	var id := multiplayer.get_remote_sender_id()
	_ready_peers[id] = true
	peer_ready.emit(id)


# --- Peer events -------------------------------------------------------------------

func _on_peer_disconnected(id: int) -> void:
	if mode != Mode.HOST or not players.has(id):
		return
	players.erase(id)
	_ready_peers.erase(id)
	_broadcast_roster()
	player_left.emit(id)


func _on_connected() -> void:
	_register.rpc_id(1, local_name, local_suit)
	joined_lobby.emit()


func _on_connection_failed() -> void:
	leave()
	connection_failed.emit("Could not reach the host.")


func _on_server_disconnected() -> void:
	var reason := "The host closed the session."
	if in_game:
		return_to_menu(reason)
		return
	leave()
	session_closed.emit(reason)


# --- Helpers -----------------------------------------------------------------------

func _broadcast_roster() -> void:
	roster_changed.emit()
	if mode == Mode.HOST:
		_sync_roster.rpc(players)


func _reset_roster() -> void:
	players = {1: {"name": local_name, "suit": local_suit}}
	roster_changed.emit()


func _is_connected() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _clean_name(text: String) -> String:
	var cleaned := text.strip_edges().to_upper().substr(0, NAME_LIMIT)
	return cleaned if not cleaned.is_empty() else "EXORCIST"


func _go(scene: String) -> void:
	var tree := get_tree()
	tree.paused = false
	tree.change_scene_to_file.call_deferred(scene)
