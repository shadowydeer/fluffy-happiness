# BIND & DELIVER

A 3D physics-based co-op comedy-horror game for Godot 4.3+. One to four
exorcists break into a cursed house, tackle and bind a ragdoll demon, and
shove it into the back of a van.

This repository currently contains **Stages 1, 1.5 and 2**: the cursed house and
yard, the extraction van, the physics player controller and HUD, the CC0 model and
PBR texture pass, and the active-ragdoll demon with its poltergeist AI, knockdowns
and drag-to-van capture. All assets live under `assets/`, so the game runs offline.

## Running it

1. Open the folder in Godot 4.3 or newer (Forward+ renderer) and press **F5**,
   or run `godot --path .` from the repository root.
2. `scenes/Main.tscn` is the main scene. It holds a single node; `Main.gd`
   builds the environment, level, player and HUD when the scene starts.

Volumetric fog and SSAO need the Forward+ renderer. On Mobile or Compatibility
the level still builds and plays, with the moonbeam meshes standing in for the
missing fog shafts.

## Controls

| Input | Action |
| --- | --- |
| `W` `A` `S` `D` | Move |
| `Shift` | Sprint (drains stamina) |
| `Space` | Jump |
| `Ctrl` | Crouch (hold) |
| Mouse | Look |
| `LMB` / `E` (hold) | Grab a physics prop, or any part of the demon, within 3.2 m |
| `RMB` (while holding) | Throw / shove the prop or the demon |
| `F` | Use doors (van rear doors, front doors) |
| `V` | Toggle first / third person |
| `T` | Toggle headlamp |
| `Esc` | Release the mouse (click to recapture) |
| `K` | Test: stun / wake the demon |
| `J` | Test: cycle demon AI (lurking > enraged > poltergeist throw) |
| `L` | Test: cycle bind level 0-3 |
| `F1` | Show / hide the test-key hint on the HUD |

Bindings live in **Project Settings > Input Map**.

## Layout

```
project.godot            Input map, GameState autoload, physics layer names, render settings
autoload/
  GameState.gd           Physics layer bits, groups, contract objective chain, HUD signals
scenes/
  Main.tscn              Entry scene (one node + Main.gd)
  Player.tscn            CharacterBody3D, capsule, head, spring-arm camera, headlamp, model
  HUD.tscn               CanvasLayer + HUD.gd
  Demon.tscn             Ragdoll root (DemonRagdoll.gd) with Visuals, Audio and AI children
scripts/
  Main.gd                WorldEnvironment (ACES, SSAO, fog, volumetric fog, glow) and moonlight
  LevelBuilder.gd        Yard, house shell, rooms, lamps, moonbeams, markings, triggers, props
  ExtractionVan.gd       Van body, cargo cage, ramp, lights, hinged rear doors, cargo zone
  HingedDoor.gd          RigidBody3D door leaf on a HingeJoint3D with a driven swing and latch
  PropFactory.gd         The throwable clutter, with per-prop mass / friction / bounce
  OccultMarkings.gd      Procedural chalk pentagrams, rune circles, sigils and rune rows
  MaterialLibrary.gd     Cached procedural materials (noise-textured, glow, glass, shafts)
  FlickerLight.gd        Noise-driven flicker and brown-outs for any Light3D
  Player.gd              Movement, stamina, camera modes, headlamp, grab / throw, interaction
  ExorcistModel.gd       Rigged hazmat exorcist: skeletal clips plus procedural crouch, lean and arm IK
  HUD.gd                 Objective banner, demon status panel, stamina bar, gadget slots, prompts
  DemonRagdoll.gd        11 rigid bodies on 10 6-DOF joints, balance, poses, stun / bind / struggle
  DemonVisuals.gd        Sculpted anatomy per segment, ember cracks, eyes, ash and spark particles
  DemonAI.gd             State machine, waypoint navigation, haunting, swipes, poltergeist throws
  DemonAudio.gd          Procedural rasp, roar, buzz, thud and whoosh buffers
  Crosshair.gd           Reactive reticle
```

## How the pieces fit

- **Physics layers**: `1 world`, `2 player`, `3 props`, `4 interactable`,
  `5 demon_limbs`. Demon segments collide with layers 1-4 and never with layer 5.
  Props carry the `grabbable` group and a `display_name` meta used in prompts.
- **Grabbing** never freezes the prop. Each physics tick the distance between
  the grab point and the hands becomes a target velocity, and the velocity
  error becomes a capped force applied at the grab point, so props swing, snag
  on door frames and sag under their own weight. Tune it under **Grab** on the
  Player node (`pull_stiffness`, `pull_response`, `max_pull_force`,
  `throw_impulse`). The sofa weighs more than one exorcist can lift.
- **Doors** are rigid bodies pinned by a `HingeJoint3D`. A damped torque drives
  them open or shut, swing limits are enforced in `_integrate_forces`, and a
  shut leaf latches until someone uses it. Anything with `interact()` and
  `get_prompt()` on the interactable layer works with `F`.
- **Stairs** are visible steps with a hidden ramp along their nosings, so
  players and dragged bodies do not catch on every riser.
- **Objectives** are steps in `GameState.STEPS`; world objects call
  `GameState.complete_step()` and the HUD follows `objective_changed`.
- **Suit colours**: set `suit_variant` on the Main node (0 orange, 1 teal,
  2 olive, 3 purple) or call `Player.set_suit()`. The idle crew by the van takes the other three.
- **Gadget slots** are still empty; `HUD.set_gadget_slot(index, name)` is
  the hook for Stage 3.

## Stage 1.5: visual overhaul

- **Assets**: `tools/fetch_assets.py` downloads and verifies the CC0 `.glb` models and
  1K PBR texture sets listed in `assets/asset_manifest.json`; everything lives under
  `assets/`, so the game runs offline.
- **Exorcist**: the rigged CC0 worker is re-dressed in code (suit fabric in four team
  colours, split-out rubber gloves, full-face gas mask with glowing lenses, hardhat lamp,
  harness, twin canisters, hose, belt). Idle / walk / run are skeletal clips; crouch,
  airborne tuck, sprint lean, head pitch and arm reach are layered on by a
  `SkeletonModifier3D` with two-bone IK.
- **First person**: the same body stays visible with the head hidden; the gloves are
  IK-posed in view with stride bob and look sway, and reach toward a grabbed prop.
- **Grab tether**: a soft camera-facing thread from the right glove to a contact ring on
  the grab point. It sags when slack and turns amber as the grip nears breaking.
- **Lighting**: ACES, SSAO, SSIL, thresholded glow, volumetric fog (cold outside, a warm
  `FogVolume` indoors), four-split moon shadows, and one shadow-tuning pass over every lamp
  in `Main._tune_lights()`.

## Stage 2: the demon

- **Ragdoll**: `Pelvis`, `Torso`, `Head` and four two-segment limbs (54 kg, 26 kg of it
  in the core) joined by `Generic6DOFJoint3D` with anatomical limits. Awake, a PD upright
  torque and foot-ray support keep it standing while pose targets drive the lurch, arm
  swings and head tracking. Stunned, the drives drop out and it falls in a heap.
- **Stun and bind**: `stun_meter` drains from 100; at 0 it scrambles up `ENRAGED`.
  `bind_level` 0-3 weakens its struggle pulses and eases the drag (Stage 3 gadgets set it).
- **AI**: `LURKING` around the ritual room, `STALKING` once you are inside (a direct
  headlamp beam freezes it, then enrages it), `ENRAGED` charges and swipes within 1.8 m,
  and every 5-8 s within 10 m it levitates one or two props for 0.65 s and hurls them.
  It walks a doorway waypoint graph with ray feelers, opens shut doors and kicks clutter
  aside. Lamps and candles within 7 m of it flicker and recover when it leaves.
- **Knockdown**: a swipe, or a prop arriving faster than 6.5 m/s, floors the player for
  1.6-2.2 s (camera to the floor, slide, shake, red vignette, held object dropped), then
  2 s of immunity. Works in first and third person.
- **Capture**: a stunned torso inside the van's cage `Area3D` sets `is_in_van`; shutting
  the doors seals it and completes the contract.
- **Textures**: `charred_skin` and `cracked_bone` under `assets/textures/demon/`, listed
  in the manifest and fetched by `tools/fetch_assets.py`.

### Trying it

1. `F` on the van's rear doors, then walk into the house. The demon stalks you; the HUD
   status panel (state, stun bar, bind pips) appears once you have seen it.
2. Shine the headlamp on it, or press `J`, to enrage it. `J` again forces a throw.
3. Grab it awake (`LMB` / `E`): the prompt reads `GRAB DEMON (ARM)` and it floors you.
4. `K` stuns it. Grab any part (`DRAG DEMON (LEG)`) and haul it out, up the ramp and
   into the cage. `L` changes how hard it thrashes. `F` on the doors seals the capture.
5. `K` again wakes it early, to watch it scramble upright.

## Checks

```
godot --headless --path . --import          # first run only: builds the import cache
godot --headless --fixed-fps 60 --path . -s tools/smoke_test.gd
```

The smoke test boots the real game and plays the contract through the player's own
input paths (F on the van doors, grab, haul up the ramp, throw, house triggers, V / T /
Ctrl / Space). It then runs the Stage 2 loop: ragdoll layout and layers, locating the
demon, haunted lights, swipe and thrown-prop knockdowns, `K` / `J` / `L` / `F1` as real
key presses, dragging the stunned demon up the ramp, capture and sealing, and a final
check that no segment ever went non-finite. `tools/setup_sandbox.sh` installs Godot 4.3
and a software Vulkan stack for headless Linux machines.

Headless runs print `Parameter "m" is null` on exit. That is the dummy renderer freeing
meshes and predates Stage 2; it does not appear with a real renderer.
