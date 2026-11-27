extends Node
## Real-sample sound engine for BIND & DELIVER (autoload: `SoundManager`).
##
## tools/fetch_assets.py stores CC0 recordings under res://assets/audio/ as
## `<slot>.ogg` or `<slot>.wav`, with optional extra takes `<slot>_2` .. `<slot>_4`.
## This node finds them at start-up, owns the `SFX` and `Ambient` buses (created at
## run time next to `Master`), plays one-shots from a pool of AudioStreamPlayer3D
## voices with a little random pitch, runs the house ambience, turns furniture
## collisions into crashes, pulses a heartbeat when the local exorcist is nearly
## dead, and keeps the three volume sliders in user://settings.cfg.
## A slot with no file on disk is not an error: it plays a short AudioStreamWAV
## synthesised here the first time it is asked for, so every slot always sounds.

signal volume_changed(bus: StringName, linear: float)

const BUS_MASTER := &"Master"
const BUS_SFX := &"SFX"
const BUS_AMBIENT := &"Ambient"
## Feeds SFX through a low-pass: things heard through the walls of the sealed van.
const BUS_MUFFLED := &"Muffled"
const AUDIO_DIR := "res://assets/audio/"
const EXTENSIONS: Array[String] = [".ogg", ".wav"]
const MAX_TAKES := 4

## Every slot. Its place in this list is its id on the wire, so only ever append.
const SLOTS: Array[StringName] = [
	&"amb_drone", &"amb_thunder", &"amb_creak", &"amb_hum",
	&"impact_wood", &"impact_metal", &"impact_thud", &"impact_glass",
	&"lasso_whip", &"lasso_creak", &"lasso_clink", &"lasso_snap",
	&"taser_arc", &"taser_zap", &"taser_hiss", &"taser_beep",
	&"tape_rip", &"tape_snap", &"salt_shatter", &"salt_burst",
	&"demon_roar", &"demon_screech", &"tk_whoosh", &"ragdoll_thud",
	&"van_door_slam", &"van_bang", &"heartbeat", &"cash_register",
	&"ui_click", &"ui_buy", &"ui_deny",
]
## Slots that are held rather than fired: see `get_loop`.
const LOOP_SLOTS: Array[StringName] = [&"amb_drone", &"amb_hum", &"lasso_creak", &"taser_arc", &"tape_rip"]
const SETTING_KEYS := {BUS_MASTER: "master", BUS_SFX: "sfx", BUS_AMBIENT: "ambient"}

## slot -> (unit size, furthest audible distance) in metres.
const REACH := {
	&"demon_roar": Vector2(7.0, 48.0), &"demon_screech": Vector2(7.0, 48.0),
	&"van_door_slam": Vector2(6.0, 42.0), &"van_bang": Vector2(5.0, 34.0),
	&"impact_wood": Vector2(4.5, 32.0), &"impact_metal": Vector2(5.0, 36.0),
	&"impact_thud": Vector2(4.0, 26.0), &"impact_glass": Vector2(4.5, 32.0),
	&"salt_shatter": Vector2(5.0, 34.0), &"salt_burst": Vector2(5.0, 34.0),
	&"amb_creak": Vector2(3.0, 22.0), &"amb_hum": Vector2(1.6, 9.0),
	&"taser_zap": Vector2(2.5, 16.0), &"ui_click": Vector2(2.0, 12.0),
}
const DEFAULT_REACH := Vector2(4.0, 30.0)
## Recordings are mastered hotter than the synthesised stand-ins the game was tuned
## with; this many dB are added whenever a slot plays its real sample.
const SAMPLE_TRIM := {}

const RATE := 22050
const LOW_RATE := 11025
const VOICES_3D := 16
const VOICES_UI := 4
## Seconds of overlap when a recording that was not cut as a loop is held.
const LOOP_FADE := 0.09

# Furniture impacts.
const WATCH_META := &"sound_watched"
const IMPACT_SLOTS := {&"wood": &"impact_wood", &"metal": &"impact_metal", &"thud": &"impact_thud", &"glass": &"impact_glass"}
const CONTACTS := 4
const IMPACT_MIN_SPEED := 1.3     # m/s into the surface; anything gentler is a rest, not a hit
const IMPACT_FULL_SPEED := 9.0
const HEAVY_MASS := 60.0
const BODY_COOLDOWN := 0.2
const GLOBAL_GAP := 0.05
const HOT_TIME := 2.5             # a prop that touched something is listened to this long while it tumbles
const SETTLE_TIME := 1.5          # props dropping into place on a fresh site make no noise
const CRASH_SPEED := 4.5
const CRASH_MASS := 7.0
const CRASH_GAP := 0.3
const BUMP_SCALE := 0.6           # somebody walking into a chair is not a chair thrown at a wall

# Ambience.
const DRONE_DB := -17.0
const DRONE_BACKDROP_DB := -21.0
const HUM_DB := -15.0
const THUNDER_GAP := Vector2(25.0, 70.0)
const CREAK_GAP := Vector2(8.0, 22.0)

# Heartbeat.
const HEART_BELOW := 0.4
const HEART_LOOP_LENGTH := 1.6    # a longer recording is several beats: hold it instead of pulsing it

## How often each slot was asked for; lets tests confirm the hooks without listening.
var play_counts: Dictionary = {}
var impact_count := 0
## Impacts that were hard enough but fell inside a cooldown.
var impact_skipped := 0
var crash_count := 0
## The latest impact: slot, speed, mass, volume_db, pitch, at.
var last_impact: Dictionary = {}
var net_sent := 0
var net_received := 0
var thunder_count := 0
var creak_count := 0
var heartbeat_active := false
var heartbeat_count := 0

var _rng := RandomNumberGenerator.new()
var _volumes: Dictionary = {BUS_MASTER: 1.0, BUS_SFX: 1.0, BUS_AMBIENT: 1.0}
var _samples: Dictionary = {}       # slot -> Array[AudioStream]
var _last_take: Dictionary = {}
var _procedural: Dictionary = {}    # slot -> AudioStreamWAV
var _loops: Dictionary = {}         # slot -> AudioStream
var _voices: Array[AudioStreamPlayer3D] = []
var _voice_stamps: PackedInt64Array = PackedInt64Array()
var _stamp := 0
var _flat: Array[AudioStreamPlayer] = []
var _flat_next := 0

var _clock := 0.0
var _tick := 0
var _watch: Dictionary = {}         # instance id -> index into the arrays below
var _bodies: Array[RigidBody3D] = []
var _impact_slots: Array[StringName] = []
var _quiet_until := PackedFloat32Array()
var _hot_until := PackedFloat32Array()
var _checked := PackedInt64Array()
var _hot: Array[int] = []
var _settle_until := 0.0
var _global_quiet_until := 0.0
var _crash_quiet_until := 0.0

var _amb_main: Node
var _amb_active := false
var _amb_backdrop := false
var _amb_root: Node
var _drone: AudioStreamPlayer
var _thunder: AudioStreamPlayer
var _creak: AudioStreamPlayer3D
var _hum: AudioStreamPlayer3D
var _drone_db := DRONE_DB
var _thunder_in := 0.0
var _creak_in := 0.0
var _house := AABB(Vector3(-9.0, 0.45, -23.0), Vector3(18.0, 3.4, 18.0))

var _heart: AudioStreamPlayer
var _heart_in := 0.0
var _heart_held := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_ensure_buses()
	rescan()
	_build_voices()
	for bus: StringName in SETTING_KEYS:
		var saved: Variant = GameState.get_setting("audio", SETTING_KEYS[bus], 1.0)
		_volumes[bus] = clampf(float(saved), 0.0, 1.0) if (saved is float or saved is int) else 1.0
		_apply_volume(bus)
	GameState.contract_started.connect(_on_contract_started)
	set_physics_process(false)


# --- Samples ---------------------------------------------------------------------------

## Looks through res://assets/audio/ again (the files may have arrived since start-up).
func rescan() -> void:
	_samples.clear()
	_loops.clear()
	_last_take.clear()
	for slot in SLOTS:
		var takes: Array[AudioStream] = []
		for take in MAX_TAKES:
			var base := AUDIO_DIR + String(slot) + ("" if take == 0 else "_%d" % (take + 1))
			for extension in EXTENSIONS:
				var stream := _load_sample(base + extension)
				if stream:
					takes.append(stream)
					break
		if not takes.is_empty():
			_samples[slot] = takes


## True when at least one downloaded recording exists for `slot`.
func has_sample(slot: StringName) -> bool:
	return _samples.has(slot)


## How many recordings were found for `slot`.
func get_take_count(slot: StringName) -> int:
	return (_samples[slot] as Array).size() if _samples.has(slot) else 0


## A recording for `slot` (a random take when there are several), else `fallback`,
## else the slot's synthesised stand-in. Null only for a name that is not a slot.
func get_stream(slot: StringName, fallback: AudioStream = null) -> AudioStream:
	if _samples.has(slot):
		var takes: Array = _samples[slot]
		var pick := _rng.randi() % takes.size()
		# Never the same take twice running when there is a choice.
		if takes.size() > 1 and pick == int(_last_take.get(slot, -1)):
			pick = (pick + 1) % takes.size()
		_last_take[slot] = pick
		return takes[pick]
	if fallback:
		return fallback
	return _fallback(slot)


## `slot` as a stream that repeats without a gap, for the voices that hold a sound
## (ambience, the taser arc, the tape rip, a straining rope). The shared one-shot
## resource is never changed: this is a copy with its own loop points, or a playlist
## that overlaps the end of a recording with its own beginning.
func get_loop(slot: StringName, fallback: AudioStream = null) -> AudioStream:
	if _loops.has(slot):
		return _loops[slot]
	var loop: AudioStream
	if _samples.has(slot):
		loop = _loop_of(_samples[slot])
	elif fallback:
		return _wav_loop(fallback as AudioStreamWAV) if fallback is AudioStreamWAV else fallback
	else:
		var stand_in := _fallback(slot)
		loop = _wav_loop(stand_in) if stand_in else null
	if loop:
		_loops[slot] = loop
	return loop


## dB to add when `slot` plays its real recording instead of the synthesised stand-in.
func get_trim(slot: StringName) -> float:
	return float(SAMPLE_TRIM.get(slot, 0.0)) if _samples.has(slot) else 0.0


## 16-bit mono AudioStreamWAV from -1..1 samples.
func make_wav(samples: PackedFloat32Array, rate: int = RATE, loop: bool = false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = samples.size()
	return wav


func _load_sample(path: String) -> AudioStream:
	if ResourceLoader.exists(path):
		var imported := ResourceLoader.load(path) as AudioStream
		if imported:
			return imported
	# Downloaded but never imported (a checkout that has not been opened in the editor): read the file itself.
	if not FileAccess.file_exists(path):
		return null
	if path.ends_with(".ogg"):
		return AudioStreamOggVorbis.load_from_file(path)
	return _read_wav(path)


## Plain RIFF reader for PCM (8, 16, 24 bit) and 32-bit float files.
func _read_wav(path: String) -> AudioStreamWAV:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF" or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		return null
	var encoding := 0
	var channels := 0
	var rate := 0
	var bits := 0
	var data := PackedByteArray()
	var cursor := 12
	while cursor + 8 <= bytes.size():
		var tag := bytes.slice(cursor, cursor + 4).get_string_from_ascii()
		var size := bytes.decode_u32(cursor + 4)
		var body := cursor + 8
		if tag == "fmt " and body + 16 <= bytes.size():
			encoding = bytes.decode_u16(body)
			channels = bytes.decode_u16(body + 2)
			rate = bytes.decode_u32(body + 4)
			bits = bytes.decode_u16(body + 14)
			# WAVE_FORMAT_EXTENSIBLE keeps the real encoding in its sub-format.
			if encoding == 0xFFFE and body + 26 <= bytes.size():
				encoding = bytes.decode_u16(body + 24)
		elif tag == "data":
			data = bytes.slice(body, mini(body + size, bytes.size()))
		cursor = body + size + (size & 1)
	if data.is_empty() or channels < 1 or channels > 2 or rate <= 0:
		return null
	var wav := AudioStreamWAV.new()
	wav.mix_rate = rate
	wav.stereo = channels == 2
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	if encoding == 1 and bits == 16:
		wav.data = data
	elif encoding == 1 and bits == 8:
		# RIFF stores 8-bit audio unsigned, the engine wants it signed.
		for i in data.size():
			data[i] = (data[i] + 128) & 0xFF
		wav.format = AudioStreamWAV.FORMAT_8_BITS
		wav.data = data
	elif encoding == 1 and bits == 24:
		var count := data.size() / 3
		var narrow := PackedByteArray()
		narrow.resize(count * 2)
		for i in count:
			narrow[i * 2] = data[i * 3 + 1]
			narrow[i * 2 + 1] = data[i * 3 + 2]
		wav.data = narrow
	elif encoding == 3 and bits == 32:
		var count := data.size() / 4
		var narrow := PackedByteArray()
		narrow.resize(count * 2)
		for i in count:
			narrow.encode_s16(i * 2, int(clampf(data.decode_float(i * 4), -1.0, 1.0) * 32767.0))
		wav.data = narrow
	else:
		return null
	return wav


func _fallback(slot: StringName) -> AudioStreamWAV:
	if _procedural.has(slot):
		return _procedural[slot]
	var wav := _synth(slot)
	if wav == null:
		push_warning("SoundManager: unknown slot '%s'" % slot)
	_procedural[slot] = wav
	return wav


func _loop_of(takes: Array) -> AudioStream:
	if takes.size() == 1:
		var only: AudioStream = takes[0]
		if only is AudioStreamWAV:
			return _wav_loop(only as AudioStreamWAV)
		if only is AudioStreamOggVorbis and (only as AudioStreamOggVorbis).loop:
			return only
	# Recordings cut as one-shots: chain them, each starting just before the last one ends.
	var list := AudioStreamPlaylist.new()
	list.stream_count = takes.size()
	for i in takes.size():
		var copy := (takes[i] as AudioStream).duplicate() as AudioStream
		var length := copy.get_length()
		if copy is AudioStreamOggVorbis:
			var ogg := copy as AudioStreamOggVorbis
			ogg.loop = false
			if length > LOOP_FADE * 4.0:
				# The playlist moves on after `beat_count` beats and fades out whatever is left.
				ogg.bpm = 60.0 / LOOP_FADE
				ogg.beat_count = maxi(1, int(length / LOOP_FADE) - 1)
		elif copy is AudioStreamWAV:
			(copy as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_DISABLED
		list.set_list_stream(i, copy)
	list.loop = true
	list.shuffle = takes.size() > 2
	list.fade_time = LOOP_FADE
	return list


## Copy of `wav` that loops, with its tail cross-faded into its head so the seam does not click.
func _wav_loop(wav: AudioStreamWAV) -> AudioStreamWAV:
	var copy := wav.duplicate() as AudioStreamWAV
	if copy.loop_mode != AudioStreamWAV.LOOP_DISABLED:
		return copy
	copy.loop_mode = AudioStreamWAV.LOOP_FORWARD
	if copy.format != AudioStreamWAV.FORMAT_16_BITS:
		copy.loop_end = int(copy.get_length() * copy.mix_rate)
		return copy
	var channels := 2 if copy.stereo else 1
	var frames := copy.data.size() / (2 * channels)
	var fade := mini(int(copy.mix_rate * LOOP_FADE), frames / 4)
	copy.loop_end = frames
	if fade < 8:
		return copy
	var data := copy.data
	var tail := (frames - fade) * channels
	for i in fade * channels:
		var blend := float(i / channels) / fade
		var at := (tail + i) * 2
		data.encode_s16(at, int(lerpf(data.decode_s16(at), data.decode_s16(i * 2), blend)))
	copy.data = data
	copy.loop_begin = fade
	return copy


# --- Buses and volume --------------------------------------------------------------------

## Linear 0..1 volume of Master, SFX or Ambient; saved to user://settings.cfg.
func set_volume(bus: StringName, linear: float) -> void:
	if not SETTING_KEYS.has(bus):
		return
	linear = clampf(linear, 0.0, 1.0)
	if is_equal_approx(float(_volumes[bus]), linear):
		return
	_volumes[bus] = linear
	_apply_volume(bus)
	GameState.set_setting("audio", SETTING_KEYS[bus], linear)
	volume_changed.emit(bus, linear)


func get_volume(bus: StringName) -> float:
	return float(_volumes.get(bus, 1.0))


func _ensure_buses() -> void:
	_ensure_bus(BUS_SFX, BUS_MASTER)
	_ensure_bus(BUS_AMBIENT, BUS_MASTER)
	var sfx := AudioServer.get_bus_index(BUS_SFX)
	if AudioServer.get_bus_effect_count(sfx) == 0:
		# A table of bottles going over must not clip the mix.
		var limiter := AudioEffectHardLimiter.new()
		limiter.ceiling_db = -1.0
		AudioServer.add_bus_effect(sfx, limiter)
	var muffled := _ensure_bus(BUS_MUFFLED, BUS_SFX)
	if AudioServer.get_bus_effect_count(muffled) == 0:
		var wall := AudioEffectLowPassFilter.new()
		wall.cutoff_hz = 1100.0
		AudioServer.add_bus_effect(muffled, wall)


func _ensure_bus(bus: StringName, send: StringName) -> int:
	var index := AudioServer.get_bus_index(bus)
	if index >= 0:
		return index
	AudioServer.add_bus()
	index = AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus)
	AudioServer.set_bus_send(index, send)
	return index


func _apply_volume(bus: StringName) -> void:
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		return
	var linear: float = _volumes[bus]
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(index, linear <= 0.001)


# --- One-shots ---------------------------------------------------------------------------

## One-shot at a point in the world, on this machine only. `jitter` is the random pitch spread.
func play_3d(slot: StringName, at: Vector3, volume_db: float = 0.0, pitch: float = 1.0, jitter: float = 0.06) -> void:
	if not at.is_finite():
		play_ui(slot, volume_db, pitch)
		return
	var stream := get_stream(slot)
	if stream == null:
		return
	play_counts[slot] = int(play_counts.get(slot, 0)) + 1
	var reach: Vector2 = REACH.get(slot, DEFAULT_REACH)
	var camera := get_viewport().get_camera_3d()
	if camera and camera.global_position.distance_squared_to(at) > reach.y * reach.y:
		return
	var voice := _take_voice()
	voice.stream = stream
	voice.global_position = at
	voice.unit_size = reach.x
	voice.max_distance = reach.y
	voice.volume_db = volume_db + get_trim(slot)
	voice.pitch_scale = clampf(pitch * (1.0 + _rng.randf_range(-jitter, jitter)), 0.1, 4.0)
	voice.play()


## Flat one-shot on the SFX bus (menus, the cash register).
func play_ui(slot: StringName, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	var stream := get_stream(slot)
	if stream == null:
		return
	play_counts[slot] = int(play_counts.get(slot, 0)) + 1
	var voice := _flat[_flat_next]
	_flat_next = (_flat_next + 1) % _flat.size()
	voice.stream = stream
	voice.volume_db = volume_db + get_trim(slot)
	voice.pitch_scale = clampf(pitch, 0.1, 4.0)
	voice.play()


## Host or solo: `play_3d` here and on every client that has loaded the site.
## A client calling this hears nothing: its copy arrives from the host.
func play_net(slot: StringName, at: Vector3, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if not NetworkManager.is_authority():
		return
	play_3d(slot, at, volume_db, pitch)
	if not NetworkManager.is_networked():
		return
	var index := SLOTS.find(slot)
	if index < 0:
		return
	for id in NetworkManager.get_ready_clients():
		_net_play.rpc_id(id, index, at, volume_db, pitch)
		net_sent += 1


@rpc("authority", "call_remote", "unreliable")
func _net_play(index: int, at: Vector3, volume_db: float, pitch: float) -> void:
	if index < 0 or index >= SLOTS.size():
		return
	net_received += 1
	play_3d(SLOTS[index], at, minf(volume_db, 12.0), pitch)


## How many pooled 3D voices are sounding right now.
func get_busy_voices() -> int:
	var busy := 0
	for voice in _voices:
		if voice.playing:
			busy += 1
	return busy


func _build_voices() -> void:
	for i in VOICES_3D:
		var voice := AudioStreamPlayer3D.new()
		voice.name = "Voice%d" % i
		_tune_3d(voice, BUS_SFX)
		add_child(voice)
		_voices.append(voice)
		_voice_stamps.append(0)
	for i in VOICES_UI:
		var voice := AudioStreamPlayer.new()
		voice.name = "Flat%d" % i
		voice.bus = BUS_SFX
		add_child(voice)
		_flat.append(voice)
	_heart = AudioStreamPlayer.new()
	_heart.name = "Heartbeat"
	_heart.bus = BUS_SFX
	add_child(_heart)


## Inverse-distance falloff, with the highs rolled off as the sound gets further away.
func _tune_3d(voice: AudioStreamPlayer3D, bus: StringName) -> void:
	voice.bus = bus
	voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	voice.attenuation_filter_cutoff_hz = 4500.0
	voice.attenuation_filter_db = -22.0
	voice.max_db = 3.0


## A silent voice if there is one, else the one that has been sounding longest.
func _take_voice() -> AudioStreamPlayer3D:
	var pick := 0
	var oldest := _stamp + 1
	for i in _voices.size():
		if not _voices[i].playing:
			pick = i
			break
		if _voice_stamps[i] < oldest:
			oldest = _voice_stamps[i]
			pick = i
	_stamp += 1
	_voice_stamps[pick] = _stamp
	return _voices[pick]


# --- Furniture impacts ---------------------------------------------------------------------

## Host or solo: listens to these props' collisions and plays velocity-scaled impacts.
## Replaces the previous list, so it is safe to call again for a new site or after a reset.
func watch_props(props: Array[RigidBody3D]) -> void:
	_watch.clear()
	_bodies.clear()
	_impact_slots.clear()
	_quiet_until.clear()
	_hot_until.clear()
	_checked.clear()
	_hot.clear()
	_settle_until = _clock + SETTLE_TIME
	# A client's props are frozen mirrors: it hears the host's impacts through `play_net`.
	if NetworkManager.is_authority():
		for prop in props:
			if not is_instance_valid(prop) or _watch.has(prop.get_instance_id()):
				continue
			_watch[prop.get_instance_id()] = _bodies.size()
			_bodies.append(prop)
			_impact_slots.append(IMPACT_SLOTS.get(prop.get_meta(&"impact", &"wood"), &"impact_wood"))
			_quiet_until.append(0.0)
			_hot_until.append(0.0)
			_checked.append(-1)
			prop.contact_monitor = true
			prop.max_contacts_reported = maxi(prop.max_contacts_reported, CONTACTS)
			if not prop.has_meta(WATCH_META):
				prop.set_meta(WATCH_META, true)
				prop.body_entered.connect(_on_prop_contact.bind(prop))
	set_physics_process(not _bodies.is_empty())


func get_watched_count() -> int:
	return _bodies.size()


func _on_contract_started(_number: int) -> void:
	# The level has just put every prop back on its mark.
	_settle_until = _clock + SETTLE_TIME


func _on_prop_contact(_other: Node, prop: RigidBody3D) -> void:
	var index: int = _watch.get(prop.get_instance_id(), -1)
	if index < 0 or _clock < _settle_until:
		return
	if _hot_until[index] <= _clock and not _hot.has(index):
		_hot.append(index)
	_hot_until[index] = _clock + HOT_TIME
	_inspect(index)


func _physics_process(delta: float) -> void:
	_clock += delta
	# Only props that touched something lately are looked at: a chair that lands on a
	# corner and then falls flat hits the same floor twice without a second signal.
	var i := _hot.size() - 1
	while i >= 0:
		var index := _hot[i]
		var body := _bodies[index]
		if not is_instance_valid(body) or body.sleeping or body.freeze or _hot_until[index] <= _clock:
			_hot_until[index] = 0.0
			_hot.remove_at(i)
		else:
			_inspect(index)
		i -= 1
	_tick += 1


## Reads the prop's contacts for the fastest approach along a contact normal.
func _inspect(index: int) -> void:
	if _checked[index] == _tick or _quiet_until[index] > _clock:
		return
	_checked[index] = _tick
	var body := _bodies[index]
	if not is_instance_valid(body) or not body.is_inside_tree():
		return
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
	if state == null:
		return
	var best := 0.0
	var best_contact := -1
	var struck := false
	for contact in mini(state.get_contact_count(), CONTACTS):
		var own := state.get_contact_local_velocity_at_position(contact)
		var theirs := state.get_contact_collider_velocity_at_position(contact)
		# The normal points out of the other body, so closing speed is against it.
		var approach := -(own - theirs).dot(state.get_contact_local_normal(contact))
		if approach > best:
			best = approach
			best_contact = contact
			struck = theirs.length_squared() > own.length_squared()
	if best_contact < 0 or best < IMPACT_MIN_SPEED:
		return
	_impact(index, state.get_contact_collider_object(best_contact), best, state.get_contact_local_position(best_contact), struck)


## `struck` is true when the other body was the one doing the moving.
func _impact(index: int, other: Object, speed: float, at: Vector3, struck: bool) -> void:
	var body := _bodies[index]
	var slot := _impact_slots[index]
	var mass := body.mass
	var may_crash := true
	var other_index: int = _watch.get(other.get_instance_id(), -1) if is_instance_valid(other) else -1
	if other_index >= 0:
		# Two props: the lighter one sets the weight of the hit, the moving one its voice.
		mass = minf(mass, _bodies[other_index].mass)
		if struck:
			slot = _impact_slots[other_index]
	elif other is CharacterBody3D:
		speed *= BUMP_SCALE
		may_crash = false
		if speed < IMPACT_MIN_SPEED:
			return
	if _clock < _global_quiet_until:
		impact_skipped += 1
		return
	_quiet_until[index] = _clock + BODY_COOLDOWN
	if other_index >= 0:
		_quiet_until[other_index] = _clock + BODY_COOLDOWN
	_global_quiet_until = _clock + GLOBAL_GAP

	var hardness := clampf((speed - IMPACT_MIN_SPEED) / (IMPACT_FULL_SPEED - IMPACT_MIN_SPEED), 0.0, 1.0)
	var weight := clampf(log(1.0 + mass) / log(1.0 + HEAVY_MASS), 0.0, 1.0)
	# Heavy is louder and lower; a harder hit is louder and a touch brighter.
	var volume_db := clampf(lerpf(-8.0, 1.5, sqrt(hardness)) + lerpf(-2.0, 1.5, weight), -10.0, 3.0)
	var pitch := lerpf(1.3, 0.72, weight) * lerpf(0.95, 1.08, hardness)
	impact_count += 1
	last_impact = {"slot": slot, "speed": speed, "mass": mass, "volume_db": volume_db, "pitch": pitch, "at": at}
	play_net(slot, at, volume_db, pitch)
	if may_crash and speed >= CRASH_SPEED and mass >= CRASH_MASS and _clock >= _crash_quiet_until:
		_crash_quiet_until = _clock + CRASH_GAP
		crash_count += 1
		GameState.fx(&"crash", at, clampf(hardness * (0.6 + 0.9 * weight), 0.0, 1.5))


# --- Ambience --------------------------------------------------------------------------------

## Starts the site's ambience (drone, thunder, creaks, the van's lamp hum) for `main`.
## With `main.backdrop` set (the title screen) it is only the quiet drone and the thunder.
func start_ambience(main: Node) -> void:
	if not is_instance_valid(main):
		return
	if _amb_active and _amb_main == main:
		return
	stop_ambience()
	_amb_main = main
	_amb_active = true
	_amb_backdrop = bool(main.get(&"backdrop"))
	_amb_root = Node.new()
	_amb_root.name = "Ambience"
	add_child(_amb_root)

	_drone_db = DRONE_BACKDROP_DB if _amb_backdrop else DRONE_DB
	_drone = AudioStreamPlayer.new()
	_drone.name = "Drone"
	_drone.bus = BUS_AMBIENT
	_drone.stream = get_loop(&"amb_drone")
	# Eased up in _process so the site does not open with a thump.
	_drone.volume_db = -60.0
	_amb_root.add_child(_drone)
	_drone.play()
	_thunder = AudioStreamPlayer.new()
	_thunder.name = "Thunder"
	_thunder.bus = BUS_AMBIENT
	_amb_root.add_child(_thunder)
	_thunder_in = _rng.randf_range(10.0, 26.0)
	if _amb_backdrop:
		return

	var level: Variant = main.get(&"level")
	_read_house(level as Node)
	_creak = AudioStreamPlayer3D.new()
	_creak.name = "Creak"
	_tune_3d(_creak, BUS_AMBIENT)
	_creak.unit_size = 3.0
	_creak.max_distance = 22.0
	_amb_root.add_child(_creak)
	_creak_in = _rng.randf_range(6.0, 14.0)

	var van: Variant = (level as Node).get(&"van") if level is Node else null
	if van is Node3D and is_instance_valid(van):
		_hum = AudioStreamPlayer3D.new()
		_hum.name = "LampHum"
		_tune_3d(_hum, BUS_AMBIENT)
		_hum.unit_size = 1.6
		_hum.max_distance = 9.0
		_hum.volume_db = HUM_DB + get_trim(&"amb_hum")
		_hum.stream = get_loop(&"amb_hum")
		_amb_root.add_child(_hum)
		var lamp := (van as Node3D).find_child("WorkLight", true, false) as Node3D
		_hum.global_position = lamp.global_position if lamp else (van as Node3D).global_position + Vector3.UP * 2.3
		_hum.play()


func stop_ambience() -> void:
	_amb_active = false
	_amb_main = null
	_drone = null
	_thunder = null
	_creak = null
	_hum = null
	if is_instance_valid(_amb_root):
		remove_child(_amb_root)
		_amb_root.queue_free()
	_amb_root = null


func is_ambience_active() -> bool:
	return _amb_active


## What the ambience is doing right now (tests): players sounding and seconds to the next event.
func get_ambience_state() -> Dictionary:
	return {
		"active": _amb_active,
		"backdrop": _amb_backdrop,
		"drone": is_instance_valid(_drone) and _drone.playing,
		"hum": is_instance_valid(_hum) and _hum.playing,
		"creaks": is_instance_valid(_creak),
		"thunder_in": _thunder_in,
		"creak_in": _creak_in,
		"players": _amb_root.get_child_count() if is_instance_valid(_amb_root) else 0,
	}


## Runs the ambience clock forward (tests): the thunder and creak timers fire as they would in play.
func advance_ambience(seconds: float) -> void:
	_tick_ambience(seconds)


func _process(delta: float) -> void:
	if _amb_active:
		_tick_ambience(delta)
	_tick_heartbeat(delta)


func _tick_ambience(delta: float) -> void:
	if not _amb_active:
		return
	if not is_instance_valid(_amb_main):
		stop_ambience()
		return
	if is_instance_valid(_drone):
		_drone.volume_db = move_toward(_drone.volume_db, _drone_db + get_trim(&"amb_drone"), delta * 22.0)
	_thunder_in -= delta
	if _thunder_in <= 0.0:
		_thunder_in = _rng.randf_range(THUNDER_GAP.x, THUNDER_GAP.y)
		thunder_count += 1
		_thunder.stream = get_stream(&"amb_thunder")
		_thunder.volume_db = _rng.randf_range(-16.0, -11.0) + (-3.0 if _amb_backdrop else 0.0) + get_trim(&"amb_thunder")
		_thunder.pitch_scale = _rng.randf_range(0.85, 1.1)
		_thunder.play()
	if _amb_backdrop or not is_instance_valid(_creak):
		return
	_creak_in -= delta
	if _creak_in <= 0.0:
		_creak_in = _rng.randf_range(CREAK_GAP.x, CREAK_GAP.y)
		creak_count += 1
		# Under a floorboard or up in the joists, somewhere in the house.
		var height := 0.05 if _rng.randf() < 0.65 else _house.size.y
		_creak.global_position = _house.position + Vector3(_rng.randf() * _house.size.x, height, _rng.randf() * _house.size.z)
		_creak.stream = get_stream(&"amb_creak")
		_creak.volume_db = _rng.randf_range(-15.0, -10.0) + get_trim(&"amb_creak")
		_creak.pitch_scale = _rng.randf_range(0.8, 1.15)
		_creak.play()


## Interior of the house from the level's own constants, a metre in from the walls.
func _read_house(level: Node) -> void:
	if level == null or level.get_script() == null:
		return
	var constants := (level.get_script() as Script).get_script_constant_map()
	if not (constants.has("HOUSE_WEST") and constants.has("HOUSE_EAST") and constants.has("HOUSE_NORTH") and constants.has("HOUSE_SOUTH")):
		return
	var west := float(constants["HOUSE_WEST"]) + 1.0
	var north := float(constants["HOUSE_NORTH"]) + 1.0
	var floor_y := float(constants.get("FLOOR_Y", 0.45))
	_house = AABB(Vector3(west, floor_y, north), Vector3(float(constants["HOUSE_EAST"]) - 1.0 - west,
			float(constants.get("WALL_HEIGHT", 3.4)), float(constants["HOUSE_SOUTH"]) - 1.0 - north))


# --- Heartbeat -----------------------------------------------------------------------------

## The local exorcist's pulse: silent above 40% health, faster and louder the lower it drops.
func _tick_heartbeat(delta: float) -> void:
	var player := GameState.local_player
	var danger := 0.0
	if is_instance_valid(player) and not get_tree().paused and not bool(player.get(&"is_downed")):
		var hp := float(player.get(&"hp"))
		var full := maxf(1.0, float(player.get(&"max_hp")))
		if hp > 0.0 and hp < full * HEART_BELOW:
			danger = 1.0 - hp / (full * HEART_BELOW)
	if danger <= 0.0 and not heartbeat_active:
		return
	if danger <= 0.0:
		heartbeat_active = false
		_heart_in = 0.0
		if _heart_held:
			_heart.stop()
			_heart_held = false
		return
	heartbeat_active = true
	var volume_db := lerpf(-14.0, -3.0, danger) + get_trim(&"heartbeat")
	var sample := get_stream(&"heartbeat")
	if sample and sample.get_length() > HEART_LOOP_LENGTH:
		# A recording of a beating heart: keep it running and push its rate instead.
		_heart.volume_db = volume_db
		_heart.pitch_scale = lerpf(0.95, 1.35, danger)
		if not _heart_held or not _heart.playing:
			_heart.stream = get_loop(&"heartbeat")
			_heart.play()
			_heart_held = true
			heartbeat_count += 1
		return
	_heart_in -= delta
	if _heart_in <= 0.0:
		_heart_in = lerpf(1.05, 0.46, danger)
		heartbeat_count += 1
		play_counts[&"heartbeat"] = int(play_counts.get(&"heartbeat", 0)) + 1
		_heart.stream = sample
		_heart.volume_db = volume_db
		_heart.pitch_scale = lerpf(0.94, 1.1, danger)
		_heart.play()


# --- Synthesised stand-ins -------------------------------------------------------------------

func _synth(slot: StringName) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7700 + SLOTS.find(slot)
	match slot:
		&"amb_drone": return make_wav(_gen_drone(rng), LOW_RATE, true)
		&"amb_thunder": return make_wav(_gen_thunder(rng), LOW_RATE)
		&"amb_creak": return make_wav(_gen_floor_creak(rng))
		&"amb_hum": return make_wav(_gen_hum(), RATE, true)
		&"impact_wood": return make_wav(_gen_wood(rng))
		&"impact_metal": return make_wav(_gen_metal(rng))
		&"impact_thud": return make_wav(_gen_thud(rng, 78.0, 34.0, 0.9))
		&"impact_glass": return make_wav(_gen_glass(rng, 0.55, 9))
		&"lasso_whip": return make_wav(_gen_whip(rng))
		&"lasso_creak": return make_wav(_gen_rope_creak(), RATE, true)
		&"lasso_clink": return make_wav(_gen_clink(rng))
		&"lasso_snap": return make_wav(_gen_snap(rng))
		&"taser_arc": return make_wav(_gen_arc(rng), RATE, true)
		&"taser_zap": return make_wav(_gen_zap(rng))
		&"taser_hiss": return make_wav(_gen_hiss(rng))
		&"taser_beep": return make_wav(_gen_beep())
		&"tape_rip": return make_wav(_gen_rip(rng), RATE, true)
		&"tape_snap": return make_wav(_gen_tape_snap(rng))
		&"salt_shatter": return make_wav(_gen_glass(rng, 0.85, 16))
		&"salt_burst": return make_wav(_gen_salt_burst(rng))
		&"demon_roar": return make_wav(_gen_roar(rng))
		&"demon_screech": return make_wav(_gen_screech(rng))
		&"tk_whoosh": return make_wav(_gen_whoosh(rng))
		&"ragdoll_thud": return make_wav(_gen_thud(rng, 96.0, 38.0, 0.6))
		&"van_door_slam": return make_wav(_gen_slam(rng))
		&"van_bang": return make_wav(_gen_bang(rng))
		&"heartbeat": return make_wav(_gen_heartbeat(rng))
		&"cash_register": return make_wav(_gen_chaching(rng))
		&"ui_click": return make_wav(_gen_click(rng))
		&"ui_buy": return make_wav(_gen_buy())
		&"ui_deny": return make_wav(_gen_deny())
	return null


func _buffer(seconds: float, rate: int = RATE) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(rate * seconds))
	return samples


## Two pairs of beating sub-bass tones under slow wind. Six seconds, every tone a whole number of cycles. Loops.
func _gen_drone(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(6.0, LOW_RATE)
	var count := samples.size()
	var blend := LOW_RATE / 2
	# The wind runs half a second long so its end can be folded back over its start.
	var air := PackedFloat32Array()
	air.resize(count + blend)
	var low := 0.0
	for i in count + blend:
		low = lerpf(low, rng.randf_range(-1.0, 1.0), 0.03)
		air[i] = low
	for i in count:
		var t := float(i) / LOW_RATE
		var swell := 0.6 + 0.4 * sin(t * TAU / 6.0)
		var tone := sin(t * TAU * 36.0) * 0.3 + sin(t * TAU * 36.5) * 0.26 + sin(t * TAU * 54.0) * 0.16 * swell
		tone += sin(t * TAU * (54.0 + 1.0 / 3.0)) * 0.14 + sin(t * TAU * 72.0) * 0.1 + sin(t * TAU * 108.5) * 0.06 * (1.0 - swell * 0.6)
		var wind := air[i]
		if i < blend:
			var k := float(i) / blend
			wind = air[i] * k + air[count + i] * (1.0 - k)
		samples[i] = tone * 0.75 + wind * 1.6 * (0.5 + 0.5 * sin(t * TAU / 3.0 + 1.0))
	return samples


## Three overlapping rolls of very low noise, a long way off.
func _gen_thunder(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(4.5, LOW_RATE)
	var starts: Array[float] = [0.0, 0.55, 1.4]
	var gains: Array[float] = [1.0, 0.7, 0.5]
	var decays: Array[float] = [2.2, 1.6, 1.1]
	var low := 0.0
	var lower := 0.0
	for i in samples.size():
		var t := float(i) / LOW_RATE
		var u := float(i) / samples.size()
		low = lerpf(low, rng.randf_range(-1.0, 1.0), 0.06)
		lower = lerpf(lower, low, 0.12)
		var roll := 0.0
		for k in 3:
			var since := t - starts[k]
			if since > 0.0:
				roll += gains[k] * minf(1.0, since / 0.05) * exp(-since * decays[k])
		var rumble := 0.75 + 0.25 * sin(t * 19.0 + sin(t * 3.1) * 2.0)
		samples[i] = tanh(lower * 9.0 * roll * rumble) * 0.8 * minf(1.0, (1.0 - u) * 5.0)
	return samples


## A floorboard taking weight: a slow stick-slip groan that rises and lets go.
func _gen_floor_creak(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.9)
	var phase := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var u := float(i) / samples.size()
		phase = fmod(phase + (118.0 + 46.0 * sin(u * PI * 1.5) + 10.0 * sin(t * 37.0)) / RATE, 1.0)
		var grip := pow(0.5 + 0.5 * sin(t * TAU * (9.0 + 7.0 * u)), 2.0)
		var board := (phase * 2.0 - 1.0) * 0.3 + sin(phase * TAU * 3.0) * 0.12 + rng.randf_range(-1.0, 1.0) * 0.04
		samples[i] = board * grip * pow(sin(u * PI), 0.8)
	return samples


## Mains hum from a tired ballast: 50 Hz and its harmonics. One second, loops.
func _gen_hum() -> PackedFloat32Array:
	var samples := _buffer(1.0)
	for i in samples.size():
		var t := float(i) / RATE
		var buzz := signf(sin(t * TAU * 100.0)) * 0.16 + sin(t * TAU * 50.0) * 0.3 + sin(t * TAU * 150.0) * 0.12 + sin(t * TAU * 300.0) * 0.05
		samples[i] = buzz * (0.9 + 0.1 * sin(t * TAU * 3.0))
	return samples


## A knock on a hollow board: a splintery burst over four quickly dying modes, then a rattle.
func _gen_wood(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.42)
	var low := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		low = lerpf(low, rng.randf_range(-1.0, 1.0), 0.35)
		var body := sin(t * TAU * 142.0) * exp(-t * 18.0) * 0.7 + sin(t * TAU * 318.0) * exp(-t * 26.0) * 0.5
		body += sin(t * TAU * 566.0) * exp(-t * 38.0) * 0.3 + sin(t * TAU * 921.0) * exp(-t * 55.0) * 0.2
		var rattle := 0.0
		if t > 0.07:
			rattle = (sin((t - 0.07) * TAU * 410.0) + low) * exp(-(t - 0.07) * 60.0) * 0.3
		samples[i] = tanh((body + low * exp(-t * 70.0) * 0.9 + rattle) * 1.4) * 0.9
	return samples


## Something hollow and steel: inharmonic partials ringing down, two of them beating.
func _gen_metal(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.9)
	var tones: Array[float] = [212.0, 487.0, 493.0, 843.0, 1318.0, 2104.0, 3175.0]
	var decays: Array[float] = [5.0, 6.5, 6.0, 8.0, 11.0, 15.0, 22.0]
	var gains: Array[float] = [0.34, 0.26, 0.2, 0.24, 0.18, 0.12, 0.08]
	for i in samples.size():
		var t := float(i) / RATE
		var ring := 0.0
		for k in tones.size():
			ring += sin(t * TAU * tones[k]) * exp(-t * decays[k]) * gains[k]
		samples[i] = tanh((ring + rng.randf_range(-1.0, 1.0) * exp(-t * 160.0) * 0.8) * 1.3) * 0.9
	return samples


## Dull, low body hit with a short knock on top.
func _gen_thud(rng: RandomNumberGenerator, from_hz: float, to_hz: float, knock_gain: float) -> PackedFloat32Array:
	var samples := _buffer(0.32)
	var phase := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		phase += lerpf(from_hz, to_hz, minf(1.0, t / 0.2)) / RATE
		var knock := rng.randf_range(-1.0, 1.0) * exp(-t * 90.0) * knock_gain
		samples[i] = (sin(phase * TAU) * exp(-t * 13.0) + knock) * 0.9
	return samples


## Glass going: a bright crack, then `shards` little bells landing at their own moments.
func _gen_glass(rng: RandomNumberGenerator, seconds: float, shards: int) -> PackedFloat32Array:
	var samples := _buffer(seconds)
	var previous := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var raw := rng.randf_range(-1.0, 1.0)
		samples[i] = (raw - previous * 0.9) * exp(-t * 34.0) * 0.55
		previous = raw
	for shard in shards:
		var start := int(rng.randf_range(0.0, seconds * 0.45) * RATE)
		var pitch := rng.randf_range(2100.0, 7400.0)
		var decay := rng.randf_range(22.0, 60.0)
		var gain := rng.randf_range(0.1, 0.24)
		for i in mini(int(RATE * 0.16), samples.size() - start):
			var t := float(i) / RATE
			samples[start + i] += sin(t * TAU * pitch) * exp(-t * decay) * gain
	return samples


## Rope cutting air, ending in a crack.
func _gen_whip(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.3)
	var low := 0.0
	for i in samples.size():
		var u := float(i) / samples.size()
		low = lerpf(low, rng.randf_range(-1.0, 1.0), 0.04 + 0.5 * u * u)
		var crack := rng.randf_range(-1.0, 1.0) * exp(-absf(u - 0.82) * 90.0) * 1.4
		samples[i] = low * sin(u * PI) * 0.9 + crack
	return samples


## Stick-slip groan of a rope under load. Loops.
func _gen_rope_creak() -> PackedFloat32Array:
	var samples := _buffer(0.6)
	var phase := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var u := float(i) / samples.size()
		phase = fmod(phase + (86.0 + 22.0 * sin(u * TAU)) / RATE, 1.0)
		var grip := 0.5 + 0.5 * sin(t * TAU * 5.0)
		samples[i] = (phase * 2.0 - 1.0) * grip * grip * 0.32 + sin(t * TAU * 172.0) * 0.07 * grip
	return samples


## Iron struck into stone: a bright inharmonic ring.
func _gen_clink(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.4)
	for i in samples.size():
		var t := float(i) / RATE
		var ring := sin(t * TAU * 2140.0) * 0.5 + sin(t * TAU * 3370.0) * 0.3 + sin(t * TAU * 5120.0) * 0.2
		samples[i] = ring * exp(-t * 14.0) * 0.7 + rng.randf_range(-1.0, 1.0) * exp(-t * 220.0) * 0.8 + sin(t * TAU * 180.0) * exp(-t * 40.0) * 0.5
	return samples


## A rope letting go.
func _gen_snap(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.24)
	for i in samples.size():
		var t := float(i) / RATE
		samples[i] = rng.randf_range(-1.0, 1.0) * exp(-t * 55.0) + sin(t * TAU * lerpf(160.0, 60.0, minf(1.0, t * 8.0))) * exp(-t * 22.0) * 0.8
	return samples


## Arcing electricity. Loops.
func _gen_arc(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.24)
	var arc := 1.0
	for i in samples.size():
		var t := float(i) / RATE
		if i % 90 == 0:
			arc = 1.0 if rng.randf() < 0.7 else 0.25
		var hum := signf(sin(t * TAU * 125.0)) * 0.4 + sin(t * TAU * 250.0) * 0.2 + signf(sin(t * TAU * 1000.0)) * 0.12
		samples[i] = (hum * arc + rng.randf_range(-1.0, 1.0) * 0.35 * arc) * 0.55
	return samples


## One spark jumping the prongs.
func _gen_zap(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.16)
	for i in samples.size():
		var t := float(i) / RATE
		var gate := 0.5 + 0.5 * signf(sin(t * TAU * 620.0))
		var spark := rng.randf_range(-1.0, 1.0) * exp(-t * 38.0) * gate
		samples[i] = spark * 0.7 + signf(sin(t * TAU * 2400.0)) * exp(-t * 60.0) * 0.22 + sin(t * TAU * 140.0) * exp(-t * 45.0) * 0.3
	return samples


## Steam venting from an overheated coil.
func _gen_hiss(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(1.5)
	var bright := 0.0
	for i in samples.size():
		var u := float(i) / samples.size()
		var raw := rng.randf_range(-1.0, 1.0)
		bright = lerpf(bright, raw, 0.7)
		samples[i] = (raw - bright * 0.6) * pow(1.0 - u, 1.6) * minf(1.0, u * 40.0) * 0.5
	return samples


## Three warning pips.
func _gen_beep() -> PackedFloat32Array:
	var samples := _buffer(0.5)
	for i in samples.size():
		var t := float(i) / RATE
		samples[i] = signf(sin(t * TAU * 1900.0)) * (0.3 if fmod(t, 0.166) < 0.08 else 0.0)
	return samples


## Tape tearing off the roll. Loops.
func _gen_rip(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.36)
	var previous := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var raw := rng.randf_range(-1.0, 1.0)
		var teeth := fmod(t * 42.0, 1.0)
		samples[i] = (raw - previous * 0.85) * (0.25 + 0.75 * teeth * teeth) * 0.5
		previous = raw
	return samples


## The last tear and a flat-handed slap to stick it down.
func _gen_tape_snap(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.26)
	var previous := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var raw := rng.randf_range(-1.0, 1.0)
		var tear := (raw - previous * 0.85) * exp(-t * 26.0) * 0.6
		previous = raw
		var slap := 0.0
		if t > 0.12:
			slap = (sin((t - 0.12) * TAU * 210.0) + rng.randf_range(-1.0, 1.0) * 0.6) * exp(-(t - 0.12) * 50.0)
		samples[i] = tear + slap * 0.9
	return samples


## Blessed salt flashing off: a bright rush of hiss under a shimmer of small bells.
func _gen_salt_burst(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(1.1)
	var bells: Array[float] = [2637.0, 3136.0, 3951.0, 5274.0]
	var previous := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var raw := rng.randf_range(-1.0, 1.0)
		var hiss := (raw - previous * 0.92) * minf(1.0, t / 0.012) * exp(-t * 3.6) * 0.42
		previous = raw
		var shimmer := 0.0
		for k in bells.size():
			shimmer += sin(t * TAU * bells[k]) * (0.6 + 0.4 * sin(t * TAU * (5.0 + 2.0 * k)))
		samples[i] = hiss + shimmer * exp(-t * 4.5) * 0.07 + sin(t * TAU * 96.0) * exp(-t * 26.0) * 0.5
	return samples


## Detuned saws falling in pitch under a breath of filtered noise.
func _gen_roar(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(1.35)
	var phases: Array[float] = [0.0, 0.0, 0.0]
	var ratios: Array[float] = [1.0, 1.06, 1.5]
	var breath := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var u := float(i) / samples.size()
		var pitch := lerpf(74.0, 43.0, u) * (1.0 + 0.05 * sin(t * 41.0))
		var voice := 0.0
		for k in 3:
			phases[k] = fmod(phases[k] + pitch * ratios[k] / RATE, 1.0)
			voice += (phases[k] * 2.0 - 1.0) / 3.0
		breath = lerpf(breath, rng.randf_range(-1.0, 1.0), 0.22)
		var rattle := 0.6 + 0.4 * sin(t * 173.0)
		var envelope := minf(1.0, t / 0.07) * pow(1.0 - u, 1.3)
		samples[i] = tanh((voice * 0.9 * rattle + breath * 0.7) * 2.2) * envelope * 0.9
	return samples


## The roar's upper register: two saws climbing to a shriek and breaking, roughened at 70 Hz.
func _gen_screech(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(1.0)
	var first := 0.0
	var second := 0.0
	var breath := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var u := float(i) / samples.size()
		var pitch := lerpf(420.0, 780.0, minf(1.0, u * 3.0)) if u < 0.34 else lerpf(780.0, 300.0, (u - 0.34) / 0.66)
		pitch *= 1.0 + 0.04 * sin(t * 57.0)
		first = fmod(first + pitch / RATE, 1.0)
		second = fmod(second + pitch * 1.493 / RATE, 1.0)
		breath = lerpf(breath, rng.randf_range(-1.0, 1.0), 0.5)
		var rough := 0.55 + 0.45 * signf(sin(t * TAU * 70.0))
		var envelope := minf(1.0, t / 0.03) * pow(1.0 - u, 0.9)
		samples[i] = tanh(((first * 2.0 - 1.0) * 0.6 + (second * 2.0 - 1.0) * 0.4) * rough * 2.4 + breath * 0.5) * envelope * 0.8
	return samples


## Air being dragged: noise through a filter that opens, then closes.
func _gen_whoosh(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.8)
	var low := 0.0
	var lower := 0.0
	for i in samples.size():
		var u := float(i) / samples.size()
		var open := 0.02 + 0.3 * pow(sin(u * PI), 2.0)
		low = lerpf(low, rng.randf_range(-1.0, 1.0), open)
		lower = lerpf(lower, low, open)
		samples[i] = lower * pow(sin(u * PI), 1.5) * 1.6
	return samples


## Two steel doors meeting their frame.
func _gen_slam(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.8)
	for i in samples.size():
		var t := float(i) / RATE
		var body := sin(t * TAU * lerpf(92.0, 48.0, minf(1.0, t * 6.0))) * exp(-t * 7.0)
		var plate := (sin(t * TAU * 310.0) * 0.4 + sin(t * TAU * 733.0) * 0.25 + sin(t * TAU * 1180.0) * 0.15) * exp(-t * 9.0)
		samples[i] = tanh((body + plate + rng.randf_range(-1.0, 1.0) * exp(-t * 60.0)) * 1.6) * 0.9
	return samples


## Something heavy hitting sheet metal from the inside.
func _gen_bang(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.4)
	var low := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		low = lerpf(low, rng.randf_range(-1.0, 1.0), 0.08)
		samples[i] = (sin(t * TAU * 74.0) * exp(-t * 16.0) + sin(t * TAU * 148.0) * exp(-t * 24.0) * 0.5 + low * exp(-t * 30.0) * 1.5) * 0.95
	return samples


## Lub-dub: two soft low thumps a fifth of a second apart.
func _gen_heartbeat(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.5)
	var low := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		low = lerpf(low, rng.randf_range(-1.0, 1.0), 0.04)
		var lub := sin(t * TAU * lerpf(64.0, 40.0, minf(1.0, t * 9.0))) * exp(-t * 22.0)
		var dub := 0.0
		if t > 0.19:
			var since := t - 0.19
			dub = sin(since * TAU * lerpf(76.0, 46.0, minf(1.0, since * 9.0))) * exp(-since * 28.0) * 0.75
		samples[i] = (lub + dub) * 0.9 + low * (exp(-t * 40.0) + (exp(-(t - 0.19) * 50.0) if t > 0.19 else 0.0)) * 0.8
	return samples


## Cash drawer: two bells and the tray hitting its stop.
func _gen_chaching(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.8)
	for i in samples.size():
		var t := float(i) / RATE
		var first := (sin(t * TAU * 1318.0) + sin(t * TAU * 2637.0) * 0.4) * exp(-t * 9.0)
		var second := 0.0
		if t > 0.13:
			second = (sin((t - 0.13) * TAU * 1760.0) + sin((t - 0.13) * TAU * 3520.0) * 0.4) * exp(-(t - 0.13) * 6.0)
		samples[i] = (first * 0.4 + second * 0.45) + rng.randf_range(-1.0, 1.0) * exp(-t * 90.0) * 0.5
	return samples


## A key switch.
func _gen_click(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var samples := _buffer(0.05)
	for i in samples.size():
		var t := float(i) / RATE
		samples[i] = sin(t * TAU * 1800.0) * exp(-t * 160.0) * 0.5 + rng.randf_range(-1.0, 1.0) * exp(-t * 400.0) * 0.3
	return samples


## Two rising chimes: sold.
func _gen_buy() -> PackedFloat32Array:
	var samples := _buffer(0.45)
	for i in samples.size():
		var t := float(i) / RATE
		var first := (sin(t * TAU * 1047.0) + sin(t * TAU * 2094.0) * 0.3) * exp(-t * 11.0)
		var second := 0.0
		if t > 0.09:
			second = (sin((t - 0.09) * TAU * 1568.0) + sin((t - 0.09) * TAU * 3136.0) * 0.3) * exp(-(t - 0.09) * 8.0)
		samples[i] = first * 0.35 + second * 0.4
	return samples


## Two falling buzzes: not enough cash.
func _gen_deny() -> PackedFloat32Array:
	var samples := _buffer(0.3)
	var low := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var tone := 196.0 if t < 0.13 else 156.0
		var gate := 1.0 if (t < 0.11 or (t > 0.14 and t < 0.27)) else 0.0
		low = lerpf(low, signf(sin(t * TAU * tone)) * gate, 0.25)
		samples[i] = low * 0.4
	return samples
