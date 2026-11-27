extends Node3D
## Sound kit for the gadgets and the extraction sequence.
##
## Each cue is a SoundManager slot: the CC0 recording downloaded for it, or the
## stand-in SoundManager synthesises when that file is missing. The three cues
## without a slot of their own (holster click, dead trigger, the growl inside the
## van) are short AudioStreamWAV buffers synthesised here on first use and shared
## by every instance. One-shots play from a small pool of 3D voices on the SFX
## bus, or flat when no position is given; the looping cues (taser buzz, tape rip,
## rope creak) each keep their own voice.

const RATE := 22050
const VOICES := 6
const LOOPS: Array[StringName] = [&"buzz", &"rip", &"creak"]
## cue -> SoundManager slot.
const SLOTS := {
	&"whip": &"lasso_whip", &"creak": &"lasso_creak", &"clink": &"lasso_clink", &"snap": &"lasso_snap",
	&"buzz": &"taser_arc", &"zap": &"taser_zap", &"hiss": &"taser_hiss", &"beep": &"taser_beep",
	&"rip": &"tape_rip", &"tape_done": &"tape_snap",
	&"shatter": &"salt_shatter", &"burst": &"salt_burst",
	&"slam": &"van_door_slam", &"bang": &"van_bang", &"growl": &"demon_roar",
	&"chaching": &"cash_register",
}
## Cues synthesised here. `growl` borrows the roar recording when there is one.
const OWN: Array[StringName] = [&"equip", &"dry", &"growl"]
## Positioned cues that come from inside the sealed van: played through the low-pass bus.
const MUFFLED: Array[StringName] = [&"bang", &"growl"]

static var _streams: Dictionary = {}
## Set by the co-op host (see NetSync): every positioned one-shot is passed on to the clients.
static var relay: Callable = Callable()

## How often each cue fired; lets tests confirm the hooks without listening.
var cue_counts: Dictionary = {}

var _voices: Array[AudioStreamPlayer3D] = []
var _next := 0
var _loop_voices: Dictionary = {}
var _flat: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 90210
	for i in VOICES:
		_voices.append(_voice("Voice%d" % i))
	_flat = AudioStreamPlayer.new()
	_flat.name = "Flat"
	_flat.bus = SoundManager.BUS_SFX
	add_child(_flat)


## Plays a one-shot. With no position it is not spatialised (interface sounds).
func play(cue: StringName, at: Vector3 = Vector3.INF, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	cue_counts[cue] = int(cue_counts.get(cue, 0)) + 1
	var stream := _stream(cue)
	if stream == null:
		return
	if relay.is_valid() and at.is_finite():
		relay.call(cue, at, volume_db, pitch)
	volume_db += _trim(cue)
	if not at.is_finite():
		_flat.stream = stream
		_flat.volume_db = volume_db
		_flat.pitch_scale = pitch
		_flat.play()
		return
	var voice := _voices[_next]
	_next = (_next + 1) % VOICES
	voice.stream = stream
	voice.bus = SoundManager.BUS_MUFFLED if MUFFLED.has(cue) else SoundManager.BUS_SFX
	voice.global_position = at
	voice.volume_db = volume_db
	voice.pitch_scale = pitch * _rng.randf_range(0.96, 1.05)
	voice.play()


## Starts, moves or stops one of the looping cues.
func set_loop(cue: StringName, active: bool, at: Vector3 = Vector3.ZERO, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	var voice: AudioStreamPlayer3D = _loop_voices.get(cue)
	if not active:
		if voice and voice.playing:
			voice.stop()
		return
	if voice == null:
		voice = _voice("Loop_%s" % cue)
		voice.stream = SoundManager.get_loop(SLOTS[cue]) if SLOTS.has(cue) else _stream(cue)
		_loop_voices[cue] = voice
	voice.global_position = at
	voice.volume_db = volume_db + _trim(cue)
	voice.pitch_scale = pitch
	if not voice.playing:
		cue_counts[cue] = int(cue_counts.get(cue, 0)) + 1
		voice.play()


func stop_loops() -> void:
	for cue: StringName in _loop_voices:
		(_loop_voices[cue] as AudioStreamPlayer3D).stop()


func _voice(node_name: String) -> AudioStreamPlayer3D:
	var voice := AudioStreamPlayer3D.new()
	voice.name = node_name
	voice.bus = SoundManager.BUS_SFX
	voice.unit_size = 4.0
	voice.max_distance = 28.0
	voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	voice.attenuation_filter_cutoff_hz = 4500.0
	voice.attenuation_filter_db = -22.0
	voice.top_level = true
	add_child(voice)
	return voice


## The recording for `cue` (a fresh random take each call), or its synthesised stand-in.
func _stream(cue: StringName) -> AudioStream:
	var slot: StringName = SLOTS.get(cue, &"")
	if slot != &"" and (SoundManager.has_sample(slot) or not OWN.has(cue)):
		return SoundManager.get_stream(slot)
	return _synth(cue)


func _trim(cue: StringName) -> float:
	return SoundManager.get_trim(SLOTS[cue]) if SLOTS.has(cue) else 0.0


# --- Synthesis ---------------------------------------------------------------------

func _synth(cue: StringName) -> AudioStreamWAV:
	if _streams.has(cue):
		return _streams[cue]
	var samples := PackedFloat32Array()
	match cue:
		&"growl": samples = _growl()
		&"equip": samples = _equip()
		&"dry": samples = _dry()
		_:
			push_warning("GadgetAudio: unknown cue '%s'" % cue)
			return null
	var wav := SoundManager.make_wav(samples, RATE)
	_streams[cue] = wav
	return wav


func _buffer(seconds: float) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(RATE * seconds))
	return samples


func _noise() -> float:
	return _rng.randf_range(-1.0, 1.0)


## A furious voice with a steel box in the way.
func _growl() -> PackedFloat32Array:
	var samples := _buffer(0.9)
	var phase := 0.0
	var low := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var u := float(i) / samples.size()
		phase = fmod(phase + (58.0 + 9.0 * sin(t * 31.0)) / RATE, 1.0)
		low = lerpf(low, (phase * 2.0 - 1.0) * (0.6 + 0.4 * sin(t * 163.0)), 0.07)
		samples[i] = low * sin(u * PI) * 2.2
	return samples


## A holster click and a short rustle.
func _equip() -> PackedFloat32Array:
	var samples := _buffer(0.14)
	var low := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		low = lerpf(low, _noise(), 0.3)
		samples[i] = low * exp(-t * 28.0) * 0.5 + sin(t * TAU * 900.0) * exp(-t * 160.0) * 0.5
	return samples


## A dead trigger.
func _dry() -> PackedFloat32Array:
	var samples := _buffer(0.08)
	for i in samples.size():
		var t := float(i) / RATE
		samples[i] = (_noise() * 0.5 + sin(t * TAU * 420.0)) * exp(-t * 120.0) * 0.6
	return samples
