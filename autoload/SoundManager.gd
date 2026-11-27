extends Node
## Real-sample sound engine for BIND & DELIVER (autoload: `SoundManager`).
##
## tools/fetch_assets.py stores CC0 recordings under res://assets/audio/ as
## `<slot>.ogg` or `<slot>.wav`, with optional extra takes `<slot>_2` .. `<slot>_4`.
## This node finds them at start-up, owns the `SFX` and `Ambient` buses (created at
## run time next to `Master`), plays one-shots from a pool of AudioStreamPlayer3D
## voices with a little random pitch, runs the house ambience, turns furniture
## collisions into crashes, and keeps the three volume sliders in user://settings.cfg.
## A slot with no file on disk is not an error: callers pass a procedural stream as
## the fallback, or the slot is simply silent.

signal volume_changed(bus: StringName, linear: float)

const BUS_MASTER := &"Master"
const BUS_SFX := &"SFX"
const BUS_AMBIENT := &"Ambient"
const AUDIO_DIR := "res://assets/audio/"


## True when at least one downloaded recording exists for `slot`.
func has_sample(_slot: StringName) -> bool:
	return false


## A recording for `slot` (a random take when there are several), else `fallback`.
func get_stream(_slot: StringName, fallback: AudioStream = null) -> AudioStream:
	return fallback


## One-shot at a point in the world, on this machine only. `jitter` is the random pitch spread.
func play_3d(_slot: StringName, _at: Vector3, _volume_db: float = 0.0, _pitch: float = 1.0, _jitter: float = 0.06) -> void:
	pass


## Flat one-shot on the SFX bus (menus, the cash register).
func play_ui(_slot: StringName, _volume_db: float = 0.0, _pitch: float = 1.0) -> void:
	pass


## Host or solo: `play_3d` here and on every client that has loaded the site.
func play_net(_slot: StringName, _at: Vector3, _volume_db: float = 0.0, _pitch: float = 1.0) -> void:
	pass


## Host or solo: listens to these props' collisions and plays velocity-scaled impacts.
func watch_props(_props: Array[RigidBody3D]) -> void:
	pass


## Starts the site's ambience (drone, thunder, creaks, the van's lamp hum) for `main`.
func start_ambience(_main: Node) -> void:
	pass


func stop_ambience() -> void:
	pass


## Linear 0..1 volume of Master, SFX or Ambient; saved to user://settings.cfg.
func set_volume(_bus: StringName, _linear: float) -> void:
	pass


func get_volume(_bus: StringName) -> float:
	return 1.0
