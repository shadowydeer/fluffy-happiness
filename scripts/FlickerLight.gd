extends Node
## Add as a child of any Light3D to make it sputter like a failing bulb, a
## candle or a pulsing sigil. Optionally drives an emissive material in sync so
## the bulb mesh dims with the light.
##
## Every flicker also joins `GROUP`, so the demon can haunt it: `haunt_target`
## (0..1) mixes in a hard electrical stutter that eases back out when released.

const GROUP := &"haunt_lights"

@export var base_energy := 2.0
## Share of the energy that wobbles with the noise (0 = steady, 1 = wild).
@export_range(0.0, 1.0) var flicker_amount := 0.3
@export var speed := 6.0
## Average brown-outs per second; 0 disables them.
@export var dropout_rate := 0.0
@export var dropout_floor := 0.08

var glow_material: StandardMaterial3D
var glow_energy := 3.0
## Set by the demon while it is close; 0 leaves the light alone.
var haunt_target := 0.0

var _light: Light3D
var _noise := FastNoiseLite.new()
var _time := 0.0
var _dropout_left := 0.0
var _haunt := 0.0
var _haunt_clock := 0.0
var _blackout_left := 0.0


func _ready() -> void:
	add_to_group(GROUP)
	_light = get_parent() as Light3D
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.35
	_noise.seed = randi()
	_time = randf() * 100.0


## Blown out by the demon: dead for `seconds`, then it stutters back to life.
func blackout(seconds: float) -> void:
	_blackout_left = maxf(_blackout_left, seconds)


func is_blacked_out() -> bool:
	return _blackout_left > 0.0


## Current haunt strength (0..1) after smoothing.
func get_haunt() -> float:
	return _haunt


func _process(delta: float) -> void:
	_time += delta * speed
	# Two octaves: a slow swell plus a fast shiver.
	var wobble := _noise.get_noise_1d(_time) * 0.7 + _noise.get_noise_1d(_time * 3.7 + 50.0) * 0.3
	var level := 1.0 - flicker_amount * (0.5 - wobble * 0.5)

	if _dropout_left > 0.0:
		_dropout_left -= delta
		# Stutter instead of a clean cut so the brown-out reads as electrical.
		level *= dropout_floor if fmod(_time * 5.0, 1.0) < 0.7 else 0.6
	elif dropout_rate > 0.0 and randf() < dropout_rate * delta:
		_dropout_left = randf_range(0.06, 0.35)

	# Haunting bites quickly and lets go slowly.
	_haunt = move_toward(_haunt, haunt_target, delta * (3.5 if haunt_target > _haunt else 0.9))
	if _haunt > 0.001:
		_haunt_clock += delta
		var gate := _noise.get_noise_1d(_haunt_clock * 26.0 + 300.0)
		var surge := 1.25 + 0.25 * _noise.get_noise_1d(_haunt_clock * 60.0)
		var haunted := 0.04 if gate < -0.08 else surge
		level *= lerpf(1.0, haunted, _haunt)

	if _blackout_left > 0.0:
		_blackout_left -= delta
		# Dead, apart from a dying ember of a filament and a stutter in the last half second.
		level *= (0.5 if fmod(_time * 7.0, 1.0) < 0.35 else 0.02) if _blackout_left < 0.5 else 0.0

	if _light:
		_light.light_energy = base_energy * level
	if glow_material:
		glow_material.emission_energy_multiplier = glow_energy * level
