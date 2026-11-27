extends Node3D
## Procedural sound kit for the gadgets and the extraction sequence.
##
## Every cue is a short AudioStreamWAV synthesised the first time it is asked for
## (no audio files to ship) and shared by every instance of this node. One-shots
## play from a small pool of 3D voices, or flat when no position is given; the
## looping cues (taser buzz, tape rip, rope creak) each keep their own voice.

const RATE := 22050
const VOICES := 6
const LOOPS: Array[StringName] = [&"buzz", &"rip", &"creak"]

static var _streams: Dictionary = {}

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
	add_child(_flat)


## Plays a one-shot. With no position it is not spatialised (interface sounds).
func play(cue: StringName, at: Vector3 = Vector3.INF, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	cue_counts[cue] = int(cue_counts.get(cue, 0)) + 1
	var stream := _stream(cue)
	if stream == null:
		return
	if not at.is_finite():
		_flat.stream = stream
		_flat.volume_db = volume_db
		_flat.pitch_scale = pitch
		_flat.play()
		return
	var voice := _voices[_next]
	_next = (_next + 1) % VOICES
	voice.stream = stream
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
		voice.stream = _stream(cue)
		_loop_voices[cue] = voice
	voice.global_position = at
	voice.volume_db = volume_db
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
	voice.unit_size = 4.0
	voice.max_distance = 28.0
	voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	voice.top_level = true
	add_child(voice)
	return voice


# --- Synthesis ---------------------------------------------------------------------

func _stream(cue: StringName) -> AudioStreamWAV:
	if _streams.has(cue):
		return _streams[cue]
	var samples := PackedFloat32Array()
	match cue:
		&"whip": samples = _whip()
		&"creak": samples = _creak()
		&"clink": samples = _clink()
		&"snap": samples = _snap()
		&"buzz": samples = _buzz()
		&"hiss": samples = _hiss()
		&"beep": samples = _beep()
		&"rip": samples = _rip()
		&"tape_done": samples = _tape_done()
		&"slam": samples = _slam()
		&"bang": samples = _bang()
		&"growl": samples = _growl()
		&"chaching": samples = _chaching()
		&"equip": samples = _equip()
		&"dry": samples = _dry()
		_:
			push_warning("GadgetAudio: unknown cue '%s'" % cue)
			return null
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	if LOOPS.has(cue):
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = samples.size()
	_streams[cue] = wav
	return wav


func _buffer(seconds: float) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(int(RATE * seconds))
	return samples


func _noise() -> float:
	return _rng.randf_range(-1.0, 1.0)


## Rope cutting air, ending in a crack.
func _whip() -> PackedFloat32Array:
	var samples := _buffer(0.3)
	var low := 0.0
	for i in samples.size():
		var u := float(i) / samples.size()
		low = lerpf(low, _noise(), 0.04 + 0.5 * u * u)
		var crack := _noise() * exp(-absf(u - 0.82) * 90.0) * 1.4
		samples[i] = low * sin(u * PI) * 0.9 + crack
	return samples


## Stick-slip groan of a rope under load. Loops.
func _creak() -> PackedFloat32Array:
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
func _clink() -> PackedFloat32Array:
	var samples := _buffer(0.4)
	for i in samples.size():
		var t := float(i) / RATE
		var ring := sin(t * TAU * 2140.0) * 0.5 + sin(t * TAU * 3370.0) * 0.3 + sin(t * TAU * 5120.0) * 0.2
		samples[i] = ring * exp(-t * 14.0) * 0.7 + _noise() * exp(-t * 220.0) * 0.8 + sin(t * TAU * 180.0) * exp(-t * 40.0) * 0.5
	return samples


## A rope letting go.
func _snap() -> PackedFloat32Array:
	var samples := _buffer(0.24)
	for i in samples.size():
		var t := float(i) / RATE
		samples[i] = _noise() * exp(-t * 55.0) + sin(t * TAU * lerpf(160.0, 60.0, minf(1.0, t * 8.0))) * exp(-t * 22.0) * 0.8
	return samples


## Arcing electricity. Loops.
func _buzz() -> PackedFloat32Array:
	var samples := _buffer(0.24)
	var arc := 1.0
	for i in samples.size():
		var t := float(i) / RATE
		if i % 90 == 0:
			arc = 1.0 if _rng.randf() < 0.7 else 0.25
		var hum := signf(sin(t * TAU * 125.0)) * 0.4 + sin(t * TAU * 250.0) * 0.2 + signf(sin(t * TAU * 1000.0)) * 0.12
		samples[i] = (hum * arc + _noise() * 0.35 * arc) * 0.55
	return samples


## Steam venting from an overheated coil.
func _hiss() -> PackedFloat32Array:
	var samples := _buffer(1.5)
	var bright := 0.0
	for i in samples.size():
		var u := float(i) / samples.size()
		bright = lerpf(bright, _noise(), 0.7)
		samples[i] = (_noise() - bright * 0.6) * pow(1.0 - u, 1.6) * minf(1.0, u * 40.0) * 0.5
	return samples


## Three warning pips.
func _beep() -> PackedFloat32Array:
	var samples := _buffer(0.5)
	for i in samples.size():
		var t := float(i) / RATE
		var pip := fmod(t, 0.166)
		samples[i] = signf(sin(t * TAU * 1900.0)) * (0.3 if pip < 0.08 else 0.0)
	return samples


## Tape tearing off the roll. Loops.
func _rip() -> PackedFloat32Array:
	var samples := _buffer(0.36)
	var previous := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var raw := _noise()
		var teeth := fmod(t * 42.0, 1.0)
		samples[i] = (raw - previous * 0.85) * (0.25 + 0.75 * teeth * teeth) * 0.5
		previous = raw
	return samples


## The last tear and a flat-handed slap to stick it down.
func _tape_done() -> PackedFloat32Array:
	var samples := _buffer(0.26)
	var previous := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		var raw := _noise()
		var tear := (raw - previous * 0.85) * exp(-t * 26.0) * 0.6
		previous = raw
		var slap := 0.0
		if t > 0.12:
			slap = (sin((t - 0.12) * TAU * 210.0) + _noise() * 0.6) * exp(-(t - 0.12) * 50.0)
		samples[i] = tear + slap * 0.9
	return samples


## Two steel doors meeting their frame.
func _slam() -> PackedFloat32Array:
	var samples := _buffer(0.8)
	for i in samples.size():
		var t := float(i) / RATE
		var body := sin(t * TAU * lerpf(92.0, 48.0, minf(1.0, t * 6.0))) * exp(-t * 7.0)
		var plate := (sin(t * TAU * 310.0) * 0.4 + sin(t * TAU * 733.0) * 0.25 + sin(t * TAU * 1180.0) * 0.15) * exp(-t * 9.0)
		samples[i] = tanh((body + plate + _noise() * exp(-t * 60.0)) * 1.6) * 0.9
	return samples


## Something heavy hitting sheet metal from the inside.
func _bang() -> PackedFloat32Array:
	var samples := _buffer(0.4)
	var low := 0.0
	for i in samples.size():
		var t := float(i) / RATE
		low = lerpf(low, _noise(), 0.08)
		samples[i] = (sin(t * TAU * 74.0) * exp(-t * 16.0) + sin(t * TAU * 148.0) * exp(-t * 24.0) * 0.5 + low * exp(-t * 30.0) * 1.5) * 0.95
	return samples


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


## Cash drawer: two bells and the tray hitting its stop.
func _chaching() -> PackedFloat32Array:
	var samples := _buffer(0.8)
	for i in samples.size():
		var t := float(i) / RATE
		var first := (sin(t * TAU * 1318.0) + sin(t * TAU * 2637.0) * 0.4) * exp(-t * 9.0)
		var second := 0.0
		if t > 0.13:
			second = (sin((t - 0.13) * TAU * 1760.0) + sin((t - 0.13) * TAU * 3520.0) * 0.4) * exp(-(t - 0.13) * 6.0)
		samples[i] = (first * 0.4 + second * 0.45) + _noise() * exp(-t * 90.0) * 0.5
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
