extends RefCounted
## The three kinds of demon a contract can be about, and the numbers that set them apart.
##
## The host picks one per contract (`GameState.demon_archetype`, replicated with the rest
## of the contract state) and every machine builds its demon from the same profile: which
## rig it wears, how big and heavy it is, how it moves and fights, what it pays.
## Everything here is a multiplier on (or a replacement for) the Stage 4 demon, which
## survives unchanged as CLASSIC for the regression tools and is never picked for a job.
##
## Use through a preload:  const Archetypes := preload("res://scripts/DemonArchetypes.gd")

enum Type { SCUTTLER, BRUTE, POLTERGEIST, CLASSIC }

## The ones a contract can roll.
const PLAYABLE: Array[int] = [Type.SCUTTLER, Type.BRUTE, Type.POLTERGEIST]
## The order a career meets them in: cheapest bounty first, then round again.
const CYCLE: Array[int] = [Type.SCUTTLER, Type.POLTERGEIST, Type.BRUTE]

## The horned demon every archetype can be built on when its own rig is missing or does not fit.
const BASE_MODEL := "demon/demon"

const PROFILES: Dictionary = {
	Type.SCUTTLER: {
		"id": &"scuttler",
		"title": "SCUTTLER",
		"blurb": "Small, fast and never where you aimed.",
		"bounty": 100,
		"model": "demon/scuttler",
		# Body: compact and hunched, light enough to drag one-handed once it is down.
		"scale": 0.82,
		"mass": 0.7,
		"hunch": 0.55,
		# Brain: quick on its feet, dodges constantly, pelts the crew with small clutter.
		"speed": 1.35,
		"swipe_damage": 22.0,
		"sidestep_rate": 2.5,
		"throw_rate": 2.2,
		"throw_count": 1,
		"throw_mass": 0.5,
		"blackout_rate": 1.0,
		"possession_rate": 1.0,
		"phase_alpha": 1.0,
		# Look and voice.
		"eye_color": Color(0.62, 1.0, 0.12),
		"glow_color": Color(1.0, 0.72, 0.1),
		"skin_tint": Color(0.52, 0.62, 0.38),
		"embers": 0.5,
		"roar_pitch": 1.4,
	},
	Type.BRUTE: {
		"id": &"brute",
		"title": "BRUTE",
		"blurb": "The horned one. Hits like the van and weighs about as much.",
		"bounty": 300,
		"model": BASE_MODEL,
		"scale": 1.22,
		"mass": 1.6,
		"hunch": 0.0,
		"speed": 0.92,
		"swipe_damage": 35.0,
		"sidestep_rate": 0.6,
		"throw_rate": 0.8,
		"throw_count": 1,
		"throw_mass": 1.3,
		"blackout_rate": 1.0,
		"possession_rate": 1.0,
		"phase_alpha": 1.0,
		"eye_color": Color(1.0, 0.2, 0.04),
		"glow_color": Color(1.0, 0.16, 0.03),
		"skin_tint": Color(0.5, 0.24, 0.2),
		"embers": 2.4,
		"roar_pitch": 0.72,
	},
	Type.POLTERGEIST: {
		"id": &"poltergeist",
		"title": "POLTERGEIST",
		"blurb": "Half here. Kills the lights, throws the furniture and rides the crew.",
		"bounty": 200,
		"model": "demon/poltergeist",
		"scale": 1.02,
		"mass": 0.9,
		"hunch": 0.1,
		"speed": 1.0,
		"swipe_damage": 26.0,
		"sidestep_rate": 1.0,
		"throw_rate": 1.5,
		"throw_count": 3,
		"throw_mass": 1.6,
		"blackout_rate": 2.5,
		"possession_rate": 2.0,
		# Opacity while it stalks through an unlit room.
		"phase_alpha": 0.35,
		"eye_color": Color(0.3, 0.95, 1.0),
		"glow_color": Color(0.5, 0.2, 1.0),
		"skin_tint": Color(0.34, 0.3, 0.52),
		"embers": 0.8,
		"roar_pitch": 1.08,
	},
	Type.CLASSIC: {
		"id": &"classic",
		"title": "DEMON",
		"blurb": "The Stage 4 demon, exactly as it was.",
		"bounty": 0,
		"model": BASE_MODEL,
		"scale": 1.0,
		"mass": 1.0,
		"hunch": 0.0,
		"speed": 1.0,
		"swipe_damage": 28.0,
		"sidestep_rate": 1.0,
		"throw_rate": 1.0,
		"throw_count": 1,
		"throw_mass": 1.0,
		"blackout_rate": 1.0,
		"possession_rate": 1.0,
		"phase_alpha": 1.0,
		"eye_color": Color(1.0, 0.24, 0.06),
		"glow_color": Color(1.0, 0.24, 0.06),
		"skin_tint": Color(1.0, 1.0, 1.0),
		"embers": 1.0,
		"roar_pitch": 1.0,
	},
}


static func is_playable(kind: int) -> bool:
	return PLAYABLE.has(kind)


## The numbers for `kind`; anything unknown reads as CLASSIC.
static func profile(kind: int) -> Dictionary:
	return PROFILES.get(kind, PROFILES[Type.CLASSIC])


## Upper-case English name ("BRUTE"). Labels show it through Loc, which knows ГРОМИЛА.
static func title(kind: int) -> String:
	return str(profile(kind)["title"])


## Extra pay for bringing this one in.
static func bounty(kind: int) -> int:
	return int(profile(kind)["bounty"])


## The archetype after `kind` in the career cycle (the M test key).
static func next(kind: int) -> int:
	return CYCLE[posmod(CYCLE.find(kind) + 1, CYCLE.size())]


## The archetype of the contract after `completed` paid ones.
static func for_contract(completed: int) -> int:
	return CYCLE[posmod(completed, CYCLE.size())]
