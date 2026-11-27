extends Node3D
## Procedural voice of the demon.
##
## Four short AudioStreamWAV buffers are synthesised at start-up (no audio files
## to ship): a low rasp / roar, an electrical lamp buzz, a heavy body thud and a
## telekinesis whoosh. They play from AudioStreamPlayer3D nodes that ride the
## demon's chest. Stage 5 replaces this with the full SoundManager.

const Ragdoll := preload("res://scripts/DemonRagdoll.gd")

const RATE := 22050

var _ragdoll: Ragdoll
var _voice: AudioStreamPlayer3D
var _buzz: AudioStreamPlayer3D
var _thud: AudioStreamPlayer3D
var _whoosh: AudioStreamPlayer3D
var _roar_stream: AudioStreamWAV
var _rasp_stream: AudioStreamWAV
var _rng := RandomNumberGenerator.new()
## How often each cue fired; lets tests confirm the hooks without listening.
var cue_counts: Dictionary = {"roar": 0, "rasp": 0, "buzz": 0, "thud": 0, "whoosh": 0}


## Called by the ragdoll once its segments exist.
func build(ragdoll: Node3D) -> void:
	_ragdoll = ragdoll as Ragdoll
	_rng.seed = 4131
	_roar_stream = _make_roar()
	_rasp_stream = _make_rasp()
	_voice = _player("Voice", _roar_stream, 5.0, 26.0)
	_buzz = _player("LampBuzz", _make_buzz(), -3.0, 14.0)
	_thud = _player("Thud", _make_thud(), 2.0, 18.0)
	_whoosh = _player("Whoosh", _make_whoosh(), 3.0, 20.0)
	_ragdoll.impacted.connect(_on_impacted)


func _process(_delta: float) -> void:
	if _ragdoll:
		global_position = _ragdoll.get_center()


func play_roar() -> void:
	_voice.stream = _roar_stream
	_voice.pitch_scale = _rng.randf_range(0.88, 1.04)
	_voice.volume_db = 6.0
	_voice.play()
	cue_counts["roar"] += 1


## Quiet, wet breathing rattle for when it is lurking or pinned.
func play_rasp(loudness: float = 1.0) -> void:
	if _voice.playing and _voice.stream == _roar_stream:
		return
	_voice.stream = _rasp_stream
	_voice.pitch_scale = _rng.randf_range(0.8, 1.15)
	_voice.volume_db = linear_to_db(clampf(loudness, 0.05, 1.5))
	_voice.play()
	cue_counts["rasp"] += 1


func play_buzz(strength: float = 1.0) -> void:
	if _buzz.playing:
		return
	_buzz.pitch_scale = _rng.randf_range(0.92, 1.1)
	_buzz.volume_db = linear_to_db(clampf(strength, 0.1, 1.0)) - 4.0
	_buzz.play()
	cue_counts["buzz"] += 1


func play_thud(strength: float = 1.0) -> void:
	_thud.pitch_scale = _rng.randf_range(0.82, 1.1)
	_thud.volume_db = linear_to_db(clampf(strength, 0.2, 1.6))
	_thud.play()
	cue_counts["thud"] += 1


func play_whoosh(pitch: float = 1.0) -> void:
	_whoosh.pitch_scale = pitch * _rng.randf_range(0.93, 1.07)
	_whoosh.play()
	cue_counts["whoosh"] += 1


func _on_impacted(speed: float) -> void:
	play_thud(clampf(speed / 5.0, 0.3, 1.6))


func _player(node_name: String, stream: AudioStream, volume_db: float, max_distance: float) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = node_name
	player.stream = stream
	player.volume_db = volume_db
	player.unit_size = 4.0
	player.max_distance = max_distance
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(player)
	return player


# --- Synthesis ---------------------------------------------------------------------

func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	return wav


## Detuned saws falling in pitch under a breath of filtered noise.
func _make_roar() -> AudioStreamWAV:
	var length := int(RATE * 1.35)
	var samples := PackedFloat32Array()
	samples.resize(length)
	var phases: Array[float] = [0.0, 0.0, 0.0]
	var ratios: Array[float] = [1.0, 1.06, 1.5]
	var breath := 0.0
	for i in length:
		var t := float(i) / RATE
		var u := float(i) / length
		var pitch := lerpf(74.0, 43.0, u) * (1.0 + 0.05 * sin(t * 41.0))
		var voice := 0.0
		for k in 3:
			phases[k] = fmod(phases[k] + pitch * ratios[k] / RATE, 1.0)
			voice += (phases[k] * 2.0 - 1.0) / 3.0
		breath = lerpf(breath, _rng.randf_range(-1.0, 1.0), 0.22)
		var rattle := 0.6 + 0.4 * sin(t * 173.0)
		var envelope := minf(1.0, t / 0.07) * pow(1.0 - u, 1.3)
		samples[i] = tanh((voice * 0.9 * rattle + breath * 0.7) * 2.2) * envelope * 0.9
	return _wav(samples)


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
	return _wav(samples)


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
	return _wav(samples)


## Dull, low body hit with a short knock on top.
func _make_thud() -> AudioStreamWAV:
	var length := int(RATE * 0.32)
	var samples := PackedFloat32Array()
	samples.resize(length)
	var phase := 0.0
	for i in length:
		var t := float(i) / RATE
		phase += lerpf(96.0, 38.0, minf(1.0, t / 0.2)) / RATE
		var knock := _rng.randf_range(-1.0, 1.0) * exp(-t * 90.0) * 0.6
		samples[i] = (sin(phase * TAU) * exp(-t * 13.0) + knock) * 0.9
	return _wav(samples)


## Air being dragged: noise through a filter that opens, then closes.
func _make_whoosh() -> AudioStreamWAV:
	var length := int(RATE * 0.8)
	var samples := PackedFloat32Array()
	samples.resize(length)
	var low := 0.0
	var lower := 0.0
	for i in length:
		var u := float(i) / length
		var open := 0.02 + 0.3 * pow(sin(u * PI), 2.0)
		low = lerpf(low, _rng.randf_range(-1.0, 1.0), open)
		lower = lerpf(lower, low, open)
		samples[i] = lower * pow(sin(u * PI), 1.5) * 1.6
	return _wav(samples)
