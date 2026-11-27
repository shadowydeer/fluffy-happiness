extends Node3D
## Voice of the demon.
##
## The roar, the body thud and the telekinesis whoosh are SoundManager slots: the
## CC0 recording downloaded for each, or the stand-in SoundManager synthesises
## when that file is missing. The breathing rasp and the lamp buzz are two short
## AudioStreamWAV buffers synthesised here at start-up. They play from
## AudioStreamPlayer3D nodes that ride the demon's chest, and the voice is shifted
## by the archetype's `roar_pitch`: a Scuttler shrieks, a Brute rumbles.

const Ragdoll := preload("res://scripts/DemonRagdoll.gd")
const DemonArchetypes := preload("res://scripts/DemonArchetypes.gd")

const RATE := 22050

var _ragdoll: Ragdoll
var _voice: AudioStreamPlayer3D
var _buzz: AudioStreamPlayer3D
var _thud: AudioStreamPlayer3D
var _whoosh: AudioStreamPlayer3D
var _rasp_stream: AudioStreamWAV
var _roaring := false
var _rng := RandomNumberGenerator.new()
## How often each cue fired; lets tests confirm the hooks without listening.
var cue_counts: Dictionary = {"roar": 0, "rasp": 0, "buzz": 0, "thud": 0, "whoosh": 0, "screech": 0}
## Set by the co-op host (see NetSync): each cue is passed on to the clients' demons.
static var relay: Callable = Callable()


## Called by the ragdoll once its segments exist.
func build(ragdoll: Node3D) -> void:
	_ragdoll = ragdoll as Ragdoll
	_rng.seed = 4131
	_rasp_stream = _make_rasp()
	_voice = _player("Voice", null, 5.0, 7.0, 48.0)
	_buzz = _player("LampBuzz", _make_buzz(), -3.0, 4.0, 14.0)
	_thud = _player("Thud", null, 2.0, 4.0, 18.0)
	_whoosh = _player("Whoosh", null, 3.0, 4.0, 20.0)
	_ragdoll.impacted.connect(_on_impacted)
	_ragdoll.broke_out.connect(_on_broke_out)


func _process(_delta: float) -> void:
	if _ragdoll:
		global_position = _ragdoll.get_center()


## The archetype's voice: 1 for the classic demon, above for the small ones, below for the Brute.
func get_voice_pitch() -> float:
	var parent := get_parent()
	var kind: Variant = parent.get(&"archetype") if parent else null
	if not kind is int:
		return 1.0
	return clampf(float(DemonArchetypes.profile(kind).get("roar_pitch", 1.0)), 0.4, 2.5)


func play_roar() -> void:
	if relay.is_valid():
		relay.call(&"roar", 1.0)
	_voice.stream = SoundManager.get_stream(&"demon_roar")
	_voice.pitch_scale = get_voice_pitch() * _rng.randf_range(0.9, 1.05)
	_voice.volume_db = 6.0 + SoundManager.get_trim(&"demon_roar")
	_voice.play()
	_roaring = true
	cue_counts["roar"] += 1
	GameState.shake_at(global_position, 0.34, 18.0)


## The shriek of a demon tearing loose or winding up a charge. Host or solo: replicated by SoundManager.
func play_screech(strength: float = 1.0) -> void:
	cue_counts["screech"] += 1
	SoundManager.play_net(&"demon_screech", global_position, 4.0 + linear_to_db(clampf(strength, 0.2, 1.6)), get_voice_pitch())
	GameState.fx(&"roar", global_position, clampf(strength, 0.2, 1.5))


## Quiet, wet breathing rattle for when it is lurking or pinned.
func play_rasp(loudness: float = 1.0) -> void:
	if relay.is_valid():
		relay.call(&"rasp", loudness)
	if _voice.playing and _roaring:
		return
	_roaring = false
	_voice.stream = _rasp_stream
	_voice.pitch_scale = get_voice_pitch() * _rng.randf_range(0.8, 1.15)
	_voice.volume_db = linear_to_db(clampf(loudness, 0.05, 1.5))
	_voice.play()
	cue_counts["rasp"] += 1


func play_buzz(strength: float = 1.0) -> void:
	if relay.is_valid():
		relay.call(&"buzz", strength)
	if _buzz.playing:
		return
	_buzz.pitch_scale = _rng.randf_range(0.92, 1.1)
	_buzz.volume_db = linear_to_db(clampf(strength, 0.1, 1.0)) - 4.0
	_buzz.play()
	cue_counts["buzz"] += 1


func play_thud(strength: float = 1.0) -> void:
	if relay.is_valid():
		relay.call(&"thud", strength)
	_thud.stream = SoundManager.get_stream(&"ragdoll_thud")
	# A heavier body lands lower, but only by half as much as its voice drops.
	_thud.pitch_scale = sqrt(get_voice_pitch()) * _rng.randf_range(0.82, 1.1)
	_thud.volume_db = linear_to_db(clampf(strength, 0.2, 1.6)) + SoundManager.get_trim(&"ragdoll_thud")
	_thud.play()
	cue_counts["thud"] += 1


func play_whoosh(pitch: float = 1.0) -> void:
	if relay.is_valid():
		relay.call(&"whoosh", pitch)
	_whoosh.stream = SoundManager.get_stream(&"tk_whoosh")
	_whoosh.pitch_scale = pitch * _rng.randf_range(0.93, 1.07)
	_whoosh.volume_db = 3.0 + SoundManager.get_trim(&"tk_whoosh")
	_whoosh.play()
	cue_counts["whoosh"] += 1


func _on_impacted(speed: float) -> void:
	play_thud(clampf(speed / 5.0, 0.3, 1.6))


func _on_broke_out(_level_before: int) -> void:
	play_screech(1.0)


func _player(node_name: String, stream: AudioStream, volume_db: float, unit_size: float, max_distance: float) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = node_name
	player.stream = stream
	player.bus = SoundManager.BUS_SFX
	player.volume_db = volume_db
	player.unit_size = unit_size
	player.max_distance = max_distance
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	player.attenuation_filter_cutoff_hz = 4500.0
	player.attenuation_filter_db = -22.0
	add_child(player)
	return player


# --- Synthesis ---------------------------------------------------------------------

## A dry rattle: gated noise over a low hum.
func _make_rasp() -> AudioStreamWAV:
	var length := int(RATE * 0.9)
	var samples := PackedFloat32Array()
	samples.resize(length)
	var breath := 0.0
	for i in length:
		var t := float(i) / RATE
		var u := float(i) / length
		breath = lerpf(breath, _rng.randf_range(-1.0, 1.0), 0.12)
		var gate := 0.35 + 0.65 * maxf(0.0, sin(t * 151.0))
		var hum := sin(t * TAU * 61.0) * 0.25
		samples[i] = (breath * gate * 1.3 + hum) * sin(u * PI) * 0.5
	return SoundManager.make_wav(samples, RATE)


## Mains hum with harmonics, chopped by an arcing contact.
func _make_buzz() -> AudioStreamWAV:
	var length := int(RATE * 0.45)
	var samples := PackedFloat32Array()
	samples.resize(length)
	var arc := 1.0
	for i in length:
		var t := float(i) / RATE
		var u := float(i) / length
		if i % 180 == 0:
			arc = 1.0 if _rng.randf() < 0.62 else 0.08
		var hum := signf(sin(t * TAU * 100.0)) * 0.45 + sin(t * TAU * 50.0) * 0.3 + sin(t * TAU * 300.0) * 0.15
		var crackle := _rng.randf_range(-1.0, 1.0) * (0.5 if arc < 0.5 else 0.06)
		samples[i] = (hum * arc + crackle) * minf(1.0, minf(u, 1.0 - u) * 12.0) * 0.4
	return SoundManager.make_wav(samples, RATE)
