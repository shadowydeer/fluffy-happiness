#!/usr/bin/env python3
"""Download and verify every third-party asset used by BIND & DELIVER.

Standard library only; ffmpeg is used when it is on PATH to trim, loop and
encode sound effects. Run from anywhere:

    python3 tools/fetch_assets.py                   # fetch whatever is missing, then verify
    python3 tools/fetch_assets.py --force           # re-download everything
    python3 tools/fetch_assets.py --verify-offline  # re-check local files against the manifest (alias: --verify)

Models, textures and audio are all CC0 1.0 / public domain and the licence is
re-checked against each API or asset page on every download:
  * Poly Haven    https://api.polyhaven.com   models (glTF packed into one .glb) and PBR textures
  * Poly Pizza    https://poly.pizza          .glb models by Quaternius, Kay Lousberg, CreativeTrio, iPoly3D
  * ambientCG     https://ambientcg.com/api   PBR textures
  * vibeassets    https://vibeassets.io/api   rigged .glb characters (the three demon archetypes)
  * KayKit        https://github.com/KayKit-Game-Assets   glTF props by Kay Lousberg, pinned to a commit
  * OpenGameArt   https://opengameart.org     CC0 entries: monster roars, an OBJ prop converted to .glb
  * BigSoundBank  https://bigsoundbank.com    field recordings and foley by Joseph Sardin
  * Freesound     https://freesound.org       CC0 sounds (the Ogg previews, which need no account)
  * Kenney        https://kenney.nl           impact and interface sound packs
Fonts are SIL Open Font License 1.1 static .ttf files from their upstream
GitHub repositories, stored next to a copy of each licence text.

Nothing is fetched from a guessed URL: every download link comes out of the
source's own API response or asset page for the id listed in the catalogs
below, or is a commit-pinned file that was checked when it was added.
Each file is checked for HTTP 200, a non-trivial size and the right magic
bytes (glTF / JPEG / PNG / Ogg Vorbis / RIFF WAVE / sfnt), fonts must cover
Basic Latin and Russian Cyrillic in their cmap table, and the result is
written to assets/asset_manifest.json.

Rigged models listed in RIGGED_MODELS are also checked for a skin, skinned
vertices and every bone the game maps by name; their bone hierarchy, rest
positions and bounding box are printed and stored in the manifest.

A download that fails never stops the run: the slot is recorded as failed (the
game has a procedural fallback for each one) and a file left by an earlier
good run is kept.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import hashlib
import html
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
MODELS = os.path.join(ASSETS, "models")
TEXTURES = os.path.join(ASSETS, "textures")
AUDIO = os.path.join(ASSETS, "audio")
FONTS = os.path.join(ASSETS, "fonts")
MANIFEST = os.path.join(ASSETS, "asset_manifest.json")
FFMPEG = shutil.which("ffmpeg")

USER_AGENT = "BindAndDeliver-AssetFetcher/2.0 (Godot indie project; contact via repository)"
BROWSER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) " + USER_AGENT
POLYHAVEN_RESOLUTION = "1k"
AMBIENTCG_ATTRIBUTE = "1K-JPG"
WORKERS = 6

# (local name, source, source id, sub-folder)
MODEL_CATALOG = [
    # --- Furniture -------------------------------------------------------
    ("sofa", "polyhaven", "sofa_02", "furniture"),
    ("armchair", "polyhaven", "ArmChair_01", "furniture"),
    ("green_chair", "polyhaven", "GreenChair_01", "furniture"),
    ("rocking_chair", "polyhaven", "Rockingchair_01", "furniture"),
    ("dining_chair", "polyhaven", "painted_wooden_chair_02", "furniture"),
    ("gothic_chair", "polyhaven", "WoodenChair_01", "furniture"),
    ("dining_table", "polyhaven", "WoodenTable_01", "furniture"),
    ("coffee_table", "polyhaven", "gothic_coffee_table", "furniture"),
    ("round_table", "polyhaven", "round_wooden_table_01", "furniture"),
    ("bookshelf", "polyhaven", "wooden_bookshelf_worn", "furniture"),
    ("gothic_cabinet", "polyhaven", "GothicCabinet_01", "furniture"),
    ("commode", "polyhaven", "GothicCommode_01", "furniture"),
    ("painted_cabinet", "polyhaven", "painted_wooden_cabinet", "furniture"),
    ("sideboard", "polyhaven", "WoodenTable_03", "furniture"),
    ("console_table", "polyhaven", "ClassicConsole_01", "furniture"),
    ("nightstand", "polyhaven", "ClassicNightstand_01", "furniture"),
    ("grandfather_clock", "polyhaven", "vintage_grandfather_clock_01", "furniture"),
    ("desk", "polyhaven", "metal_office_desk", "furniture"),
    # --- Lighting --------------------------------------------------------
    ("chandelier", "polyhaven", "Chandelier_02", "lighting"),
    ("hanging_lamp", "polyhaven", "hanging_industrial_lamp", "lighting"),
    ("caged_light", "polyhaven", "caged_hanging_light", "lighting"),
    ("street_lamp", "polyhaven", "street_lamp_01", "lighting"),
    ("wall_lantern", "polyhaven", "street_lamp_02", "lighting"),
    ("kerosene_lantern", "polyhaven", "Lantern_01", "lighting"),
    ("wooden_lantern", "polyhaven", "wooden_lantern_01", "lighting"),
    ("oil_lamp", "polyhaven", "vintage_oil_lamp", "lighting"),
    ("candelabra_set", "polyhaven", "brass_candleholders", "lighting"),
    ("flood_lights", "polyhaven", "flood_lights", "lighting"),
    ("floor_lamp", "polypizza", "9L6lLUl9sD", "lighting"),
    ("candles", "polypizza", "UCTYNYn7qk", "lighting"),
    ("candle", "polypizza", "asGVv9EuOr", "lighting"),
    ("skull_candle", "polypizza", "94tuTO5eJv", "lighting"),
    # --- Clutter props ---------------------------------------------------
    ("television", "polyhaven", "Television_01", "props"),
    ("boombox", "polyhaven", "boombox", "props"),
    ("cardboard_box", "polyhaven", "cardboard_box_01", "props"),
    ("wooden_crate", "polyhaven", "wooden_crate_01", "props"),
    ("book_set", "polyhaven", "book_encyclopedia_set_01", "props"),
    ("wine_bottles", "polyhaven", "wine_bottles_01", "props"),
    ("paint_can", "polyhaven", "can_rusted", "props"),
    ("spray_cans", "polyhaven", "spray_paint_bottles", "props"),
    ("bucket", "polyhaven", "wooden_bucket_01", "props"),
    ("toolbox", "polyhaven", "metal_toolbox", "props"),
    ("tool_chest", "polyhaven", "metal_tool_chest", "props"),
    ("goblets", "polyhaven", "brass_goblets", "props"),
    ("picture_landscape", "polyhaven", "fancy_picture_frame_01", "props"),
    ("picture_estate", "polyhaven", "hanging_picture_frame_02", "props"),
    ("picture_oval", "polyhaven", "hanging_picture_frame_03", "props"),
    ("mirror", "polyhaven", "ornate_mirror_01", "props"),
    ("marble_bust", "polyhaven", "marble_bust_01", "props"),
    ("gothic_statue", "polyhaven", "gothic_statue", "props"),
    ("wheelchair", "polyhaven", "wheelchair_01", "props"),
    ("skull", "polypizza", "7clFQGz5jH", "props"),
    # --- Yard and van area -----------------------------------------------
    ("traffic_cone", "polypizza", "lAx8JytxGD", "yard"),
    ("generator", "polyhaven", "portable_generator", "yard"),
    ("hand_truck", "polyhaven", "hand_truck", "yard"),
    ("old_tyre", "polyhaven", "old_tyre", "yard"),
    ("trash_can", "polyhaven", "metal_trash_can", "yard"),
    ("covered_car", "polyhaven", "covered_car", "yard"),
    ("iron_gate", "polyhaven", "large_iron_gate", "yard"),
    ("mailbox", "polypizza", "2olZ0G8iur", "yard"),
    ("sign_hanging", "polypizza", "AsEgIQcQfw", "yard"),
    ("sign_board", "polypizza", "3MStJYAez7", "yard"),
    # --- Nature ----------------------------------------------------------
    ("dead_tree_a", "polypizza", "Mcd2zYqyww", "nature"),
    ("dead_tree_b", "polypizza", "MlmK5488ou", "nature"),
    ("dead_tree_c", "polypizza", "n8FhMgMldD", "nature"),
    ("pine_a", "polypizza", "699sFuLCN2", "nature"),
    ("pine_b", "polypizza", "igSu0cPoBz", "nature"),
    ("tall_grass", "polypizza", "JSIYtscPmP", "nature"),
    ("dead_bushes", "polyhaven", "shrub_02", "nature"),
    ("dry_bushes", "polyhaven", "wild_rooibos_bush", "nature"),
    ("fern", "polyhaven", "fern_02", "nature"),
    ("dry_branches", "polyhaven", "dry_branches_medium_01", "nature"),
    ("tree_stump", "polyhaven", "tree_stump_01", "nature"),
    ("fallen_log", "polyhaven", "dead_tree_trunk", "nature"),
    ("rock_a", "polyhaven", "moon_rock_02", "nature"),
    ("rock_b", "polyhaven", "moon_rock_03", "nature"),
    ("rock_set", "polyhaven", "rock_moss_set_01", "nature"),
    # --- Hero assets -----------------------------------------------------
    ("van_truck", "polypizza", "cXw6oiFtZ8", "vehicles"),
    ("exorcist", "polypizza", "Yg2bQZO6Hj", "characters"),
    ("gas_mask", "polyhaven", "old_gas_mask", "characters"),
    ("gas_canister", "polyhaven", "propane_tank", "characters"),
    # --- The demon: skinned humanoid, drives the Stage 2 ragdoll ------------
    ("demon", "vibeassets", "6lgzyditwz", "demon"),
    # --- Stage 5 archetypes: same auto-rig, so they drop into that ragdoll ---
    ("scuttler", "vibeassets", "ooq775xp55", "demon"),
    ("poltergeist", "vibeassets", "k6bdm27lba", "demon"),
    # --- Stage 5 van field shop ------------------------------------------
    ("terminal", "polyhaven", "classic_laptop", "shop"),
    ("medkit", "polyhaven", "medical_box", "shop"),
    ("tape_roll", "polyhaven", "medical_tape", "shop"),
    ("shelf", "polyhaven", "worn_metal_rack", "shop"),
    # No CC0 coil of rope turned up; a hose coiled on a wall hook reads the same on the rack.
    ("rope_coil", "polyhaven", "garden_hose_wall_mounted_01", "shop"),
    ("salt_jar", "kaykit", "KayKit-Restaurant-Bits-1.0@153c8a7535b48237854cb54ff6890679f8c574d1:"
                           "addons/kaykit_restaurant_bits/Assets/gltf/jar_A_medium.gltf", "shop"),
    ("battery", "opengameart", "battery-for-rc-cars-etc:battery.zip:battery/battery.obj:battery/battery.png", "shop"),
]

# The bones scripts/DemonSkeletonDriver.gd looks up by name.
DEMON_BONES = [
    "Hips", "Spine02", "Spine01", "Spine", "neck", "Head", "head_end",
    "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
    "RightShoulder", "RightArm", "RightForeArm", "RightHand",
    "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase",
    "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase",
]
RIGGED_MODELS = {"demon": DEMON_BONES, "scuttler": DEMON_BONES, "poltergeist": DEMON_BONES}
# The game falls back to the demon rig for these, so a missing bone is recorded
# as "rig_compatible": false in the manifest instead of failing the download.
OPTIONAL_RIGS = {"scuttler", "poltergeist"}

# (local name, source, source id)
TEXTURE_CATALOG = [
    # Exterior
    ("asphalt_cracked", "polyhaven", "asphalt_02"),
    ("gravel_tarred", "polyhaven", "tarred_gravel"),
    ("ground_dead_grass", "polyhaven", "burned_ground_01"),
    ("siding_clapboard", "polyhaven", "weathered_plank_siding"),
    ("roof_slates", "polyhaven", "roof_slates_03"),
    ("brick_foundation", "polyhaven", "mixed_brick_wall"),
    ("iron_rusted", "polyhaven", "rusty_metal_04"),
    ("concrete_worn", "polyhaven", "concrete_floor_worn_001"),
    ("bark", "polyhaven", "bark_brown_02"),
    ("wood_peeling_paint", "polyhaven", "wood_peeling_paint_weathered"),
    # Interior
    ("wallpaper_mouldy", "ambientcg", "Wallpaper002C"),
    ("wallpaper_decrepit", "polyhaven", "decrepit_wallpaper"),
    ("plaster_damaged", "polyhaven", "damaged_plaster"),
    ("plaster_stained", "polyhaven", "grey_plaster_02"),
    ("floor_dark_planks", "polyhaven", "dark_wooden_planks"),
    ("floor_old_wood", "polyhaven", "old_wood_floor"),
    ("rug_jacquard", "polyhaven", "quatrefoil_jacquard_fabric"),
    ("rug_dirty_carpet", "polyhaven", "dirty_carpet"),
    ("wood_worn", "polyhaven", "wood_cabinet_worn_long"),
    ("stone_blocks", "polyhaven", "medieval_blocks_03"),
    ("stone_cobble_floor", "polyhaven", "cobblestone_floor_08"),
    # Van and gear
    ("metal_tread_plate", "polyhaven", "metal_plate"),
    ("metal_painted_rusty", "polyhaven", "rusty_metal_02"),
    ("fabric_suit", "polyhaven", "terlenka"),
    # Stage 2 demon: fibrous bark stands in for charred sinew, ivory for claws, teeth and bone.
    ("demon/charred_skin", "polyhaven", "bark_willow_02"),
    ("demon/cracked_bone", "ambientcg", "Ivory001B"),
]

# Poly Haven map key -> our file suffix.
POLYHAVEN_MAPS = [("Diffuse", "albedo"), ("nor_gl", "normal"), ("Rough", "roughness"), ("AO", "ao")]
# ambientCG file-name token -> our file suffix.
AMBIENTCG_MAPS = [("_Color", "albedo"), ("_NormalGL", "normal"), ("_Roughness", "roughness"), ("_AmbientOcclusion", "ao")]

# (file name, source, source id, edit) -> assets/audio/<file name>.ogg (or .wav when stored untouched).
# autoload/SoundManager.gd looks slots up by name; "<slot>_2" .. "<slot>_4" are extra takes of one slot.
# Source ids: bigsoundbank = page slug, freesound = user/sound number,
# opengameart = content slug:attached file, kenney = pack slug:zip member.
# Edit keys, all in seconds / dB and applied with ffmpeg: "trim": (start, end), "fade_in", "fade_out",
# "loop": cross-fade length that folds the audio after the trim window back over its start so the
# file repeats without a seam, "gain", "stereo": keep both channels (everything else is mixed to mono
# for AudioStreamPlayer3D).
AUDIO_CATALOG = [
    # --- Horror atmosphere -----------------------------------------------
    ("amb_drone", "freesound", "Nox_Sound/674735", {"trim": (1.0, 29.0), "loop": 3.0, "gain": 9, "stereo": True}),
    ("amb_drone_2", "freesound", "gerainsan/457046", {"gain": 6, "stereo": True}),
    ("amb_thunder", "bigsoundbank", "thunder-2-s3113", {"trim": (0.25, 4.9), "fade_in": 0.05, "fade_out": 0.6}),
    ("amb_thunder_2", "bigsoundbank", "thunder-3-s3114", {"trim": (0.0, 10.6), "fade_in": 0.3, "fade_out": 1.5}),
    ("amb_thunder_3", "bigsoundbank", "thunder-6-s3179", {"trim": (0.2, 8.6), "fade_in": 0.1, "fade_out": 1.2}),
    ("amb_creak", "bigsoundbank", "squeaking-parquet-1-s3051", {"trim": (0.18, 0.98), "fade_out": 0.08}),
    ("amb_creak_2", "bigsoundbank", "squeaking-parquet-10-s3060", {}),
    ("amb_creak_3", "bigsoundbank", "creaking-door-s0302", {}),
    ("amb_creak_4", "bigsoundbank", "squeaking-parquet-3-s3053", {"trim": (0.2, 0.8), "fade_out": 0.08, "gain": 3}),
    ("amb_hum", "bigsoundbank", "neon-or-transformer-1-s2118", {"trim": (1.0, 7.0), "loop": 1.0, "gain": -8}),
    # --- Furniture impacts -----------------------------------------------
    ("impact_wood", "kenney", "impact-sounds:Audio/impactWood_heavy_000.ogg", {}),
    ("impact_wood_2", "kenney", "impact-sounds:Audio/impactPlank_medium_000.ogg", {}),
    ("impact_wood_3", "bigsoundbank", "wooden-chair-falling-on-carpet-s0516", {"trim": (4.08, 4.9), "fade_out": 0.1}),
    ("impact_wood_4", "bigsoundbank", "wooden-chair-falling-on-carpet-s0516", {"trim": (12.25, 13.05), "fade_out": 0.1}),
    ("impact_metal", "kenney", "impact-sounds:Audio/impactMetal_heavy_000.ogg", {}),
    ("impact_metal_2", "kenney", "impact-sounds:Audio/impactTin_medium_000.ogg", {}),
    ("impact_metal_3", "bigsoundbank", "falling-sheet-steel-bar-4-s1774", {"trim": (0.0, 1.3), "fade_out": 0.3, "gain": -2}),
    ("impact_metal_4", "bigsoundbank", "falling-sheet-steel-bar-1-s1771", {"trim": (0.0, 0.6), "fade_out": 0.15}),
    ("impact_thud", "kenney", "impact-sounds:Audio/impactSoft_heavy_000.ogg", {}),
    ("impact_thud_2", "kenney", "impact-sounds:Audio/impactSoft_heavy_002.ogg", {}),
    ("impact_thud_3", "kenney", "impact-sounds:Audio/impactPunch_heavy_000.ogg", {}),
    ("impact_glass", "kenney", "impact-sounds:Audio/impactGlass_medium_000.ogg", {}),
    ("impact_glass_2", "kenney", "impact-sounds:Audio/impactGlass_heavy_001.ogg", {}),
    ("impact_glass_3", "kenney", "impact-sounds:Audio/impactGlass_light_002.ogg", {}),
    # --- Holy Lasso ------------------------------------------------------
    ("lasso_whip", "bigsoundbank", "complete-whip-1-s2961", {"trim": (0.2, 0.95), "fade_out": 0.15}),
    ("lasso_creak", "bigsoundbank", "big-rope-s3426", {"trim": (4.0, 9.0), "loop": 0.75}),
    ("lasso_clink", "freesound", "Rudmer_Rotteveel/457461", {"trim": (0.3, 0.77)}),
    ("lasso_snap", "bigsoundbank", "whip-crack-1-s2949", {"trim": (0.15, 0.8), "fade_out": 0.3, "gain": -1}),
    # --- Holy Taser ------------------------------------------------------
    ("taser_arc", "freesound", "Sclolex/210878", {"trim": (0.6, 4.1), "loop": 0.5}),
    ("taser_zap", "freesound", "AnthonyChan0/264779", {"gain": -1}),
    ("taser_hiss", "bigsoundbank", "hiss-of-steam-train-1-s0227", {"trim": (0.0, 2.5), "fade_out": 0.9}),
    ("taser_beep", "bigsoundbank", "beep-of-a-cash-register-s1417", {"gain": -6}),
    # --- Duct tape -------------------------------------------------------
    ("tape_rip", "freesound", "cj_ascoli/444366", {"gain": -1}),
    ("tape_rip_2", "freesound", "AlaskaRobotics/245200", {"gain": -1}),
    ("tape_rip_3", "bigsoundbank", "adhesive-tape-1-s0297", {"trim": (4.3, 7.45), "fade_in": 0.03, "fade_out": 0.1}),
    ("tape_snap", "freesound", "_natiKatz/223375", {"gain": -1}),
    ("tape_snap_2", "freesound", "baidonovan/187338", {"trim": (0.12, 0.46), "gain": 6}),
    # --- Salt grenade ----------------------------------------------------
    ("salt_shatter", "bigsoundbank", "broken-glass-of-champagne-s1591", {"trim": (0.0, 1.2), "fade_out": 0.3, "gain": -1}),
    ("salt_shatter_2", "bigsoundbank", "glass-burst-s0148", {}),
    ("salt_burst", "freesound", "Qvantor/880771", {"gain": 8}),
    # --- Demon and contract ----------------------------------------------
    ("demon_roar", "opengameart", "big-scary-troll-sounds:troll-roars.ogg", {"trim": (7.0, 8.85), "fade_out": 0.1, "gain": -1}),
    ("demon_roar_2", "opengameart", "cc0-deep-monster-roar:monster_roar.wav", {"trim": (0.08, 4.4), "fade_out": 0.8}),
    ("demon_roar_3", "opengameart", "big-scary-troll-sounds:troll-roars.ogg", {"trim": (3.55, 4.9), "fade_out": 0.1, "gain": -1}),
    ("demon_roar_4", "freesound", "uagadugu/222523", {"trim": (0.2, 3.6), "fade_out": 0.3}),
    ("demon_screech", "bigsoundbank", "barn-owl-s1400", {"trim": (0.1, 2.0), "fade_out": 0.15, "gain": -1}),
    ("demon_screech_2", "bigsoundbank", "sika-deer-rut-call-2-s3618", {"trim": (1.0, 4.6), "fade_in": 0.15, "fade_out": 0.6, "gain": -1}),
    ("tk_whoosh", "freesound", "TheEndOfACycle/674292", {"trim": (0.4, 2.69)}),
    ("ragdoll_thud", "bigsoundbank", "body-fall-2-s2453", {"trim": (0.0, 1.0), "fade_out": 0.15, "gain": -1}),
    ("ragdoll_thud_2", "bigsoundbank", "body-fall-1-s2452", {"trim": (0.0, 1.15), "fade_out": 0.1, "gain": -1}),
    ("van_door_slam", "bigsoundbank", "car-door-3-s1524", {"trim": (1.85, 2.85), "fade_out": 0.2, "gain": -1}),
    ("van_door_slam_2", "bigsoundbank", "car-sliding-door-2-s1494", {"trim": (0.12, 1.89), "gain": -1}),
    ("van_bang", "freesound", "kyles/637480", {"trim": (0.08, 1.45), "fade_out": 0.12}),
    ("van_bang_2", "freesound", "dster777/344565", {"trim": (0.15, 1.25), "fade_out": 0.2}),
    ("heartbeat", "bigsoundbank", "heartbeat-2-s0244", {"trim": (0.0, 0.75), "fade_out": 0.2}),
    ("heartbeat_2", "bigsoundbank", "heartbeat-1-s0243", {"trim": (0.0, 0.8), "fade_out": 0.15}),
    ("cash_register", "freesound", "clubmydia+/584168", {"trim": (1.42, 4.5), "fade_out": 0.3}),
    ("cash_register_2", "freesound", "CapsLok/184438", {"trim": (0.0, 1.45), "fade_out": 0.2}),
    # --- Interface -------------------------------------------------------
    ("ui_click", "kenney", "interface-sounds:Audio/click_001.ogg", {}),
    ("ui_buy", "kenney", "interface-sounds:Audio/confirmation_001.ogg", {}),
    ("ui_deny", "kenney", "interface-sounds:Audio/error_004.ogg", {}),
]

# (file name, licence file name, source, source id, licence id) -> assets/fonts/<file name>.ttf
# github = owner/repo@commit:path, github-release = owner/repo@tag:asset.zip:member;
# the licence id is a path in the same commit or a member of the same zip.
FONT_CATALOG = [
    ("Oswald-Bold", "OFL-Oswald", "github",
     "googlefonts/OswaldFont@89795261ac9eeb9aa8cd99f43982c4e4b0e53261:fonts/ttf/Oswald-Bold.ttf", "OFL.txt"),
    ("Inter-Medium", "OFL-Inter", "github-release", "rsms/inter@v4.1:Inter-4.1.zip:extras/ttf/Inter-Medium.ttf", "LICENSE.txt"),
    ("JetBrainsMono-Medium", "OFL-JetBrainsMono", "github",
     "JetBrains/JetBrainsMono@19371302b95d218af43299bce79ddbddd0bc364d:fonts/ttf/JetBrainsMono-Medium.ttf", "OFL.txt"),
]
# Every HUD and menu string is English or Russian: Basic Latin plus А-я, Ё and ё.
FONT_REQUIRED = list(range(0x20, 0x7F)) + list(range(0x410, 0x450)) + [0x401, 0x451]


class FetchError(Exception):
    pass


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def http_get(url: str, agent: str = USER_AGENT, attempts: int = 4, referer: str = "") -> bytes:
    """GET that insists on HTTP 200 and retries transient failures."""
    last = ""
    headers = {"User-Agent": agent, "Accept": "*/*"}
    if referer:
        headers["Referer"] = referer
    for attempt in range(attempts):
        wait = 1.5 * (attempt + 1)
        try:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=120) as response:
                if response.status != 200:
                    raise FetchError("HTTP %s for %s" % (response.status, url))
                return response.read()
        except urllib.error.HTTPError as error:
            last = "HTTP %s" % error.code
            if error.code in (400, 401, 403, 404, 410):
                break
            if error.code == 429:
                # Sound libraries throttle bursts from one address; give them room.
                wait *= 4
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
            last = str(error)
        time.sleep(wait)
    raise FetchError("%s (%s)" % (url, last))


def http_json(url: str, agent: str = USER_AGENT):
    return json.loads(http_get(url, agent).decode("utf-8"))


_once_guard = threading.Lock()
_once_results: dict = {}


def once(key: str, loader):
    """Runs loader a single time per run, however many worker threads ask for the same key."""
    with _once_guard:
        slot = _once_results.setdefault(key, {"lock": threading.Lock()})
    with slot["lock"]:
        if "value" not in slot and "error" not in slot:
            try:
                slot["value"] = loader()
            except FetchError as error:
                slot["error"] = error
        if "error" in slot:
            raise slot["error"]
        return slot["value"]


def http_once(url: str, agent: str = USER_AGENT, referer: str = "") -> bytes:
    """http_get for pages, archives and recordings that several catalog entries share."""
    return once("GET " + url, lambda: http_get(url, agent, referer=referer))


def page_text(url: str) -> str:
    return http_once(url).decode("utf-8", "replace")


def plain(markup: str) -> str:
    """Text of an HTML fragment."""
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", markup))).strip()


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

def image_format(data: bytes) -> str:
    if data[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    return ""


def audio_kind(data: bytes) -> str:
    """Container of a downloaded sound, judged by its magic bytes."""
    if data[:4] == b"OggS":
        return "ogg"
    if data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        return "wav"
    if data[:4] == b"fLaC":
        return "flac"
    if data[:3] == b"ID3" or (len(data) > 1 and data[0] == 0xFF and data[1] & 0xE0 == 0xE0):
        return "mp3"
    return ""


def audio_info(data: bytes) -> dict:
    """Validates a sound Godot can import (Ogg Vorbis or RIFF/WAVE) and returns its layout and length."""
    kind = audio_kind(data)
    if kind == "ogg":
        # Walk every page: the first one must carry the Vorbis identification
        # header and the last one's granule position is the sample count.
        position = 0
        granule = 0
        pages = 0
        packet = b""
        while position + 27 <= len(data):
            if data[position:position + 4] != b"OggS" or data[position + 4] != 0:
                raise FetchError("corrupt Ogg page at byte %d" % position)
            segments = data[position + 26]
            table = data[position + 27:position + 27 + segments]
            body = position + 27 + segments
            size = sum(table)
            if len(table) != segments or body + size > len(data):
                raise FetchError("truncated Ogg stream")
            if pages == 0:
                packet = data[body:body + size]
            stamp = struct.unpack("<q", data[position + 6:position + 14])[0]
            if stamp > 0:
                granule = stamp
            position = body + size
            pages += 1
        if packet[:8] == b"OpusHead":
            raise FetchError("Ogg Opus stream; Godot only imports Ogg Vorbis")
        if packet[:7] != b"\x01vorbis" or len(packet) < 16:
            raise FetchError("Ogg stream has no Vorbis identification header")
        channels = packet[11]
        rate = struct.unpack("<I", packet[12:16])[0]
        if not channels or not rate or granule <= 0:
            raise FetchError("Ogg Vorbis stream holds no audio")
        return {"format": "ogg", "codec": "vorbis", "channels": channels, "sample_rate": rate,
                "seconds": round(granule / float(rate), 3)}
    if kind == "wav":
        position = 12
        layout = None
        frames = 0
        while position + 8 <= len(data):
            tag = data[position:position + 4]
            size = struct.unpack("<I", data[position + 4:position + 8])[0]
            if tag == b"fmt " and size >= 16:
                layout = struct.unpack("<HHIIHH", data[position + 8:position + 24])
            elif tag == b"data" and layout:
                frames = min(size, len(data) - position - 8) // max(1, layout[4])
            position += 8 + size + (size & 1)
        if layout is None or frames <= 0:
            raise FetchError("WAVE file holds no audio")
        if layout[0] not in (1, 3, 0xFFFE):
            raise FetchError("WAVE codec %d is not PCM" % layout[0])
        return {"format": "wav", "codec": "pcm_%d" % layout[5], "channels": layout[1], "sample_rate": layout[2],
                "seconds": round(frames / float(layout[2]), 3)}
    raise FetchError("not Ogg Vorbis or RIFF/WAVE audio" + (" (%s)" % kind if kind else ""))


def _font_tables(data: bytes) -> dict:
    if data[:4] not in (b"\x00\x01\x00\x00", b"OTTO", b"true"):
        raise FetchError("missing TrueType/OpenType header")
    tables = {}
    for index in range(struct.unpack(">H", data[4:6])[0]):
        tag, _, offset, length = struct.unpack(">4sIII", data[12 + index * 16:28 + index * 16])
        if offset + length > len(data):
            raise FetchError("font table %s runs past the end of the file" % tag.decode("latin-1"))
        tables[tag.decode("latin-1")] = offset
    for needed in ("cmap", "head", "hhea", "hmtx", "maxp", "name"):
        if needed not in tables:
            raise FetchError("font has no %s table" % needed)
    return tables


def _font_codepoints(data: bytes, base: int) -> set:
    """Every code point a font's Unicode cmap subtables map to a real glyph."""
    found = set()
    for index in range(struct.unpack(">H", data[base + 2:base + 4])[0]):
        platform, encoding, offset = struct.unpack(">HHI", data[base + 4 + index * 8:base + 12 + index * 8])
        if platform != 0 and (platform, encoding) not in ((3, 1), (3, 10)):
            continue
        at = base + offset
        kind = struct.unpack(">H", data[at:at + 2])[0]
        if kind == 4:
            doubled = struct.unpack(">H", data[at + 6:at + 8])[0]
            count = doubled // 2
            ends = struct.unpack(">%dH" % count, data[at + 14:at + 14 + doubled])
            starts = struct.unpack(">%dH" % count, data[at + 16 + doubled:at + 16 + 2 * doubled])
            deltas = struct.unpack(">%dH" % count, data[at + 16 + 2 * doubled:at + 16 + 3 * doubled])
            ranges_at = at + 16 + 3 * doubled
            ranges = struct.unpack(">%dH" % count, data[ranges_at:ranges_at + doubled])
            for segment in range(count):
                for code in range(starts[segment], min(ends[segment], 0xFFFE) + 1):
                    if ranges[segment]:
                        slot = ranges_at + 2 * segment + ranges[segment] + 2 * (code - starts[segment])
                        glyph = struct.unpack(">H", data[slot:slot + 2])[0]
                        if glyph:
                            glyph = (glyph + deltas[segment]) & 0xFFFF
                    else:
                        glyph = (code + deltas[segment]) & 0xFFFF
                    if glyph:
                        found.add(code)
        elif kind == 12:
            for group in range(struct.unpack(">I", data[at + 12:at + 16])[0]):
                first, last, glyph = struct.unpack(">III", data[at + 16 + group * 12:at + 28 + group * 12])
                for code in range(first, min(last, 0x10FFFF) + 1):
                    if glyph + code - first:
                        found.add(code)
    return found


def font_info(data: bytes) -> dict:
    """Validates an sfnt font and its Latin + Russian Cyrillic coverage; returns its naming and size."""
    tables = _font_tables(data)
    codepoints = _font_codepoints(data, tables["cmap"])
    absent = [code for code in FONT_REQUIRED if code not in codepoints]
    if absent:
        raise FetchError("font lacks %d of the %d Latin/Cyrillic characters the game needs (first U+%04X)" % (
            len(absent), len(FONT_REQUIRED), absent[0]))
    names = {}
    base = tables["name"]
    _, count, strings = struct.unpack(">HHH", data[base:base + 6])
    for index in range(count):
        platform, _, language, key, length, offset = struct.unpack(">6H", data[base + 6 + index * 12:base + 18 + index * 12])
        raw = data[base + strings + offset:base + strings + offset + length]
        if platform == 3 and language == 0x409:
            names[key] = raw.decode("utf-16-be", "replace")
        elif platform == 1:
            names.setdefault(key, raw.decode("mac-roman", "replace"))
    return {
        "format": "otf" if data[:4] == b"OTTO" else "ttf",
        "family": names.get(16, names.get(1, "")),
        "style": names.get(17, names.get(2, "")),
        "version": names.get(5, ""),
        "glyphs": struct.unpack(">H", data[tables["maxp"] + 4:tables["maxp"] + 6])[0],
        "codepoints": len(codepoints),
        "cyrillic": True,
        # A variable font carries an fvar table; the game expects one fixed weight per file.
        "variable": "fvar" in tables,
    }


def glb_summary(data: bytes) -> dict:
    """Validates a binary glTF container and returns counts read from its JSON chunk."""
    if len(data) < 28 or data[:4] != b"glTF":
        raise FetchError("missing glTF magic bytes")
    version, declared = struct.unpack("<II", data[4:12])
    if version != 2:
        raise FetchError("unsupported glTF version %d" % version)
    if declared != len(data):
        raise FetchError("glb length header %d does not match file size %d" % (declared, len(data)))
    json_length, json_type = struct.unpack("<II", data[12:20])
    if json_type != 0x4E4F534A:
        raise FetchError("first glb chunk is not JSON")
    document = json.loads(data[20:20 + json_length].decode("utf-8"))
    triangles = 0
    for mesh in document.get("meshes", []):
        for primitive in mesh.get("primitives", []):
            if primitive.get("mode", 4) != 4:
                continue
            if "indices" in primitive:
                triangles += document["accessors"][primitive["indices"]]["count"] // 3
            else:
                triangles += document["accessors"][primitive["attributes"]["POSITION"]]["count"] // 3
    for image in document.get("images", []):
        if "uri" in image and not image["uri"].startswith("data:"):
            raise FetchError("glb references external file %s" % image["uri"])
    return {
        "triangles": triangles,
        "meshes": len(document.get("meshes", [])),
        "materials": len(document.get("materials", [])),
        "embedded_images": len(document.get("images", [])),
        "animations": len(document.get("animations", [])),
        "skins": len(document.get("skins", [])),
    }


def _node_matrix(node: dict) -> list:
    """Row-major 4x4 local transform of a glTF node."""
    if "matrix" in node:
        m = node["matrix"]
        return [[m[column * 4 + row] for column in range(4)] for row in range(4)]
    t = node.get("translation", [0.0, 0.0, 0.0])
    x, y, z, w = node.get("rotation", [0.0, 0.0, 0.0, 1.0])
    s = node.get("scale", [1.0, 1.0, 1.0])
    r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    return [[r[i][0] * s[0], r[i][1] * s[1], r[i][2] * s[2], t[i]] for i in range(3)] + [[0.0, 0.0, 0.0, 1.0]]


def _matrix_product(a: list, b: list) -> list:
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def glb_rig(data: bytes, required_bones: list) -> dict:
    """Checks a skinned .glb and returns its bone hierarchy, rest pose and bounds.

    Raises FetchError when there is no skin, no skinned vertices, a non-finite
    rest transform or a bone the game needs is missing.
    """
    json_length = struct.unpack("<I", data[12:16])[0]
    document = json.loads(data[20:20 + json_length].decode("utf-8"))
    nodes = document.get("nodes", [])
    skins = document.get("skins", [])
    if not skins:
        raise FetchError("model has no skin")
    skin = skins[0]
    joints = skin["joints"]
    parent = {child: index for index, node in enumerate(nodes) for child in node.get("children", [])}
    world: dict = {}

    def world_of(index: int) -> list:
        if index not in world:
            local = _node_matrix(nodes[index])
            world[index] = _matrix_product(world_of(parent[index]), local) if index in parent else local
        return world[index]

    joint_set = set(joints)
    bones = []
    for joint in joints:
        matrix = world_of(joint)
        rest = [matrix[0][3], matrix[1][3], matrix[2][3]]
        if any(value != value or abs(value) == float("inf") for row in matrix for value in row):
            raise FetchError("bone %s has a non-finite rest transform" % nodes[joint].get("name"))
        above = parent.get(joint)
        bones.append({
            "name": nodes[joint].get("name", "joint_%d" % joint),
            "parent": nodes[above].get("name", "") if above in joint_set else "",
            "rest": [round(value, 4) for value in rest],
            "rotation": [round(value, 4) for value in nodes[joint].get("rotation", [0.0, 0.0, 0.0, 1.0])],
        })
    names = {bone["name"] for bone in bones}
    absent = [name for name in required_bones if name not in names]
    if absent:
        raise FetchError("skeleton is missing bones: %s" % ", ".join(absent))

    vertices = 0
    skinned = 0
    low = [float("inf")] * 3
    high = [float("-inf")] * 3
    for node in nodes:
        if "mesh" not in node or "skin" not in node:
            continue
        skinned += 1
        for primitive in document["meshes"][node["mesh"]]["primitives"]:
            attributes = primitive["attributes"]
            if "JOINTS_0" not in attributes or "WEIGHTS_0" not in attributes:
                raise FetchError("skinned mesh has no joint weights")
            accessor = document["accessors"][attributes["POSITION"]]
            vertices += accessor["count"]
            for axis in range(3):
                low[axis] = min(low[axis], accessor["min"][axis])
                high[axis] = max(high[axis], accessor["max"][axis])
    if vertices <= 0:
        raise FetchError("skinned mesh has no vertices")
    # Unit vector from each shoulder joint to its wrist: (+-1, 0, 0) is a T-pose,
    # a falling y an A-pose, a rising z arms held out in front.
    rest = {bone["name"]: bone["rest"] for bone in bones}
    arms = {}
    for side in ("Left", "Right"):
        if side + "Arm" in rest and side + "Hand" in rest:
            reach = [rest[side + "Hand"][axis] - rest[side + "Arm"][axis] for axis in range(3)]
            length = sum(value * value for value in reach) ** 0.5 or 1.0
            arms[side.lower()] = [round(value / length, 3) for value in reach]
    return {
        "skeleton": skin.get("name", ""),
        "joints": len(joints),
        "vertices": vertices,
        "skinned_meshes": skinned,
        "animations": [clip.get("name", "") for clip in document.get("animations", [])],
        "bounds_min": [round(value, 4) for value in low],
        "bounds_max": [round(value, 4) for value in high],
        "height": round(high[1] - low[1], 4),
        "arm_direction": arms,
        "bones": bones,
    }


def rig_report(name: str, data: bytes) -> dict:
    """Manifest fields for a rigged model: its skeleton and whether the demon ragdoll can drive it."""
    required = RIGGED_MODELS[name]
    rig = glb_rig(data, [] if name in OPTIONAL_RIGS else required)
    present = {bone["name"] for bone in rig["bones"]}
    absent = [bone for bone in required if bone not in present]
    return {"rig": rig, "rig_compatible": not absent, "rig_missing_bones": absent,
            "rig_extra_bones": sorted(present - set(required))}


def print_rig(record: dict) -> None:
    """Bone tree with rest positions (metres, model space) and the bind-pose bounding box."""
    rig = record["rig"]
    entry = record["files"][0]
    print("")
    print("RIG %s  %s  %s  %d mesh(es), %d vertices, %d triangles, skeleton '%s' with %d bones" % (
        record["name"], entry["path"], human(entry["bytes"]), record["meshes"], rig["vertices"],
        record["triangles"], rig["skeleton"], rig["joints"]))
    print("  bounding box  min (%.3f, %.3f, %.3f)  max (%.3f, %.3f, %.3f)  height %.3f m" % (
        *rig["bounds_min"], *rig["bounds_max"], rig["height"]))
    absent = record.get("rig_missing_bones", [])
    print("  ragdoll bones %s  extra bones: %s  arm direction L %s R %s  animations: %s" % (
        "all %d present" % len(RIGGED_MODELS.get(record["name"], [])) if not absent else "MISSING " + ", ".join(absent),
        ", ".join(record.get("rig_extra_bones", [])) or "none",
        rig.get("arm_direction", {}).get("left", "?"), rig.get("arm_direction", {}).get("right", "?"),
        ", ".join(rig.get("animations", [])) or "none"))
    children: dict = {}
    for bone in rig["bones"]:
        children.setdefault(bone["parent"], []).append(bone)

    def show(bone: dict, depth: int) -> None:
        print("  %-26s rest (%7.3f, %7.3f, %7.3f)  local rotation (%.3f, %.3f, %.3f, %.3f)" % (
            "  " * depth + bone["name"], *bone["rest"], *bone["rotation"]))
        for child in children.get(bone["name"], []):
            show(child, depth + 1)

    for root in children.get("", []):
        show(root, 0)


def file_record(path: str, data: bytes, kind: str) -> dict:
    return {
        "path": "res://" + os.path.relpath(path, ROOT).replace(os.sep, "/"),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "format": kind,
        "verified": True,
    }


# ---------------------------------------------------------------------------
# Embedded JPEG repair
#
# Godot's JPEG decoder only accepts chroma planes sampled 1x1. Some encoders
# write full-resolution images with every component marked 1x2 (or 2x1 / 2x2),
# which is legal but makes the .glb fail to import. Such a scan holds exactly
# the same 8x8 blocks, only visited in a different order, so it can be
# re-ordered without touching a single coefficient.
# ---------------------------------------------------------------------------

STANDARD_DC_COUNTS = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
STANDARD_DC_SYMBOLS = list(range(12))


def _huffman_codes(counts: list, symbols: list) -> dict:
    """Canonical JPEG Huffman table as {bit string: symbol}."""
    codes = {}
    code = 0
    index = 0
    for length in range(1, 17):
        for _ in range(counts[length - 1]):
            codes[format(code, "0%db" % length)] = symbols[index]
            code += 1
            index += 1
        code <<= 1
    return codes


def _jpeg_segments(blob: bytes) -> tuple:
    """Splits a JPEG into its header segments and the entropy-coded scan."""
    if blob[:2] != b"\xff\xd8":
        raise FetchError("embedded image is not a JPEG")
    segments = []
    position = 2
    while position + 4 <= len(blob):
        if blob[position] != 0xFF:
            raise FetchError("corrupt JPEG header")
        marker = blob[position + 1]
        length = struct.unpack(">H", blob[position + 2:position + 4])[0]
        body = blob[position + 4:position + 2 + length]
        position += 2 + length
        segments.append((marker, body))
        if marker == 0xDA:
            end = position
            while True:
                end = blob.find(b"\xff", end)
                if end < 0 or end + 1 >= len(blob):
                    raise FetchError("JPEG scan has no end marker")
                if blob[end + 1] == 0x00:
                    end += 2
                    continue
                break
            return segments, blob[position:end]
    raise FetchError("JPEG has no scan")


def jpeg_sampling(blob: bytes) -> list:
    """(h, v) sampling factors of each component of a baseline JPEG, or [] for other kinds."""
    try:
        segments, _ = _jpeg_segments(blob)
    except FetchError:
        return []
    for marker, body in segments:
        if marker == 0xC0:
            return [(body[7 + c * 3] >> 4, body[7 + c * 3] & 15) for c in range(body[5])]
    return []


def jpeg_flatten_sampling(blob: bytes) -> bytes:
    """Losslessly rewrites a baseline JPEG whose components all share one HxV factor as 1x1."""
    segments, scan = _jpeg_segments(blob)
    frame = None
    tables = {}
    selectors = {}
    for marker, body in segments:
        if marker == 0xC0:
            frame = body
        elif marker in (0xC1, 0xC2, 0xC9, 0xCA):
            raise FetchError("only baseline JPEGs can be re-ordered")
        elif marker == 0xDD and struct.unpack(">H", body[:2])[0]:
            raise FetchError("JPEG restart intervals are not supported")
        elif marker == 0xC4:
            at = 0
            while at < len(body):
                key = body[at]
                counts = list(body[at + 1:at + 17])
                symbols = list(body[at + 17:at + 17 + sum(counts)])
                tables[key] = (counts, symbols)
                at += 17 + sum(counts)
        elif marker == 0xDA:
            for c in range(body[0]):
                selectors[body[1 + c * 2]] = (body[2 + c * 2] >> 4, body[2 + c * 2] & 15)
    if frame is None:
        raise FetchError("JPEG has no baseline frame")
    height, width, count = struct.unpack(">HHB", frame[1:6])
    components = [(frame[6 + c * 3], frame[7 + c * 3] >> 4, frame[7 + c * 3] & 15) for c in range(count)]
    factor_h, factor_v = components[0][1], components[0][2]
    if any((h, v) != (factor_h, factor_v) for _, h, v in components):
        raise FetchError("JPEG components use different sampling factors")

    # The leading 1 keeps the zero bits at the start of the scan; skip "0b1".
    bits = bin(int.from_bytes(b"\x01" + scan.replace(b"\xff\x00", b"\xff"), "big"))[3:]
    decoders = {key: _huffman_codes(*table) for key, table in tables.items()}
    mcu_columns = -(-width // (8 * factor_h))
    mcu_rows = -(-height // (8 * factor_v))
    # blocks[component][row][column] = (absolute DC value, AC bits exactly as stored)
    blocks = [[[None] * (mcu_columns * factor_h) for _ in range(mcu_rows * factor_v)] for _ in components]
    predictors = [0] * count
    at = 0

    def symbol(table: dict) -> int:
        nonlocal at
        for length in range(1, 17):
            found = table.get(bits[at:at + length])
            if found is not None:
                at += length
                return found
        raise FetchError("corrupt JPEG scan")

    for mcu_row in range(mcu_rows):
        for mcu_column in range(mcu_columns):
            for c, (component_id, _, _) in enumerate(components):
                dc_table = decoders[selectors[component_id][0]]
                ac_table = decoders[16 + selectors[component_id][1]]
                for v in range(factor_v):
                    for h in range(factor_h):
                        size = symbol(dc_table)
                        if size:
                            value = int(bits[at:at + size], 2)
                            at += size
                            if value < 1 << (size - 1):
                                value -= (1 << size) - 1
                            predictors[c] += value
                        start = at
                        k = 1
                        while k < 64:
                            run_size = symbol(ac_table)
                            if run_size & 15:
                                at += run_size & 15
                                k += (run_size >> 4) + 1
                            elif run_size == 0xF0:
                                k += 16
                            else:
                                break
                        blocks[c][mcu_row * factor_v + v][mcu_column * factor_h + h] = (predictors[c], bits[start:at])

    dc_codes = {value: key for key, value in _huffman_codes(STANDARD_DC_COUNTS, STANDARD_DC_SYMBOLS).items()}
    out = []
    predictors = [0] * count
    for row in range(-(-height // 8)):
        for column in range(-(-width // 8)):
            for c in range(count):
                value, ac_bits = blocks[c][row][column]
                difference = value - predictors[c]
                predictors[c] = value
                size = abs(difference).bit_length()
                out.append(dc_codes[size])
                if size:
                    out.append(format(difference if difference >= 0 else difference + (1 << size) - 1, "0%db" % size))
                out.append(ac_bits)
    stream = "".join(out)
    stream += "1" * (-len(stream) % 8)
    packed = int(stream, 2).to_bytes(len(stream) // 8, "big").replace(b"\xff", b"\xff\x00")

    def segment(marker: int, body: bytes) -> bytes:
        return bytes([0xFF, marker]) + struct.pack(">H", len(body) + 2) + body

    result = bytearray(b"\xff\xd8")
    for marker, body in segments:
        if marker == 0xC0:
            flat = bytearray(body)
            for c in range(count):
                flat[7 + c * 3] = 0x11
            result += segment(marker, bytes(flat))
        elif marker == 0xC4:
            continue
        elif marker == 0xDA:
            for key, (counts, symbols) in sorted(tables.items()):
                if key < 16:
                    counts, symbols = STANDARD_DC_COUNTS, STANDARD_DC_SYMBOLS
                result += segment(0xC4, bytes([key]) + bytes(counts) + bytes(symbols))
            result += segment(marker, body)
        else:
            result += segment(marker, body)
    return bytes(result) + packed + b"\xff\xd9"


def glb_repair_images(data: bytes) -> tuple:
    """Re-orders embedded JPEGs Godot cannot decode. Returns (glb bytes, number of images fixed)."""
    json_length = struct.unpack("<I", data[12:16])[0]
    document = json.loads(data[20:20 + json_length].decode("utf-8"))
    views = document.get("bufferViews", [])
    binary_start = 20 + json_length
    if binary_start + 8 > len(data):
        return data, 0
    binary_length = struct.unpack("<I", data[binary_start:binary_start + 4])[0]
    binary = data[binary_start + 8:binary_start + 8 + binary_length]
    replacements = {}
    for image in document.get("images", []):
        if image.get("mimeType") != "image/jpeg" or "bufferView" not in image:
            continue
        view = views[image["bufferView"]]
        start = view.get("byteOffset", 0)
        blob = binary[start:start + view["byteLength"]]
        factors = jpeg_sampling(blob)
        if len(factors) == 3 and factors[1] != (1, 1):
            replacements[image["bufferView"]] = jpeg_flatten_sampling(blob)
    if not replacements:
        return data, 0
    blob = bytearray()
    for index, view in enumerate(views):
        start = view.get("byteOffset", 0)
        content = replacements.get(index, binary[start:start + view["byteLength"]])
        while len(blob) % 4:
            blob.append(0)
        view["byteOffset"] = len(blob)
        view["byteLength"] = len(content)
        blob += content
    while len(blob) % 4:
        blob.append(0)
    document["buffers"][0]["byteLength"] = len(blob)
    text = json.dumps(document, separators=(",", ":")).encode("utf-8")
    text += b" " * (-len(text) % 4)
    total = 12 + 8 + len(text) + 8 + len(blob)
    packed = b"glTF" + struct.pack("<II", 2, total) + struct.pack("<II", len(text), 0x4E4F534A) + text
    packed += struct.pack("<II", len(blob), 0x004E4942) + bytes(blob)
    return packed, len(replacements)


def write_file(path: str, data: bytes) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = path + ".part"
    with open(temporary, "wb") as handle:
        handle.write(data)
    os.replace(temporary, path)


# ---------------------------------------------------------------------------
# glTF -> GLB packing (Poly Haven ships .gltf + .bin + loose textures)
# ---------------------------------------------------------------------------

def pack_glb(document: dict, resources: dict) -> bytes:
    """Embeds every buffer and image of a glTF document into one binary chunk."""
    blob = bytearray()
    remap = {}
    for index, buffer in enumerate(document.get("buffers", [])):
        uri = urllib.parse.unquote(buffer["uri"])
        while len(blob) % 4:
            blob.append(0)
        remap[index] = len(blob)
        blob += resources[uri]
    for view in document.get("bufferViews", []):
        view["byteOffset"] = view.get("byteOffset", 0) + remap[view.get("buffer", 0)]
        view["buffer"] = 0
    for image in document.get("images", []):
        uri = urllib.parse.unquote(image.pop("uri"))
        data = resources[uri]
        kind = image_format(data)
        if not kind:
            raise FetchError("texture %s is not a JPEG or PNG" % uri)
        while len(blob) % 4:
            blob.append(0)
        document.setdefault("bufferViews", []).append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)})
        image["bufferView"] = len(document["bufferViews"]) - 1
        image["mimeType"] = "image/" + kind
        image.setdefault("name", os.path.splitext(os.path.basename(uri))[0])
        blob += data
    while len(blob) % 4:
        blob.append(0)
    document["buffers"] = [{"byteLength": len(blob)}]
    text = json.dumps(document, separators=(",", ":")).encode("utf-8")
    text += b" " * ((4 - len(text) % 4) % 4)
    total = 12 + 8 + len(text) + 8 + len(blob)
    out = io.BytesIO()
    out.write(struct.pack("<4sII", b"glTF", 2, total))
    out.write(struct.pack("<II", len(text), 0x4E4F534A))
    out.write(text)
    out.write(struct.pack("<II", len(blob), 0x004E4942))
    out.write(bytes(blob))
    return out.getvalue()


# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

_polyhaven_index: dict = {}


def polyhaven_info(asset_id: str, kind: str) -> dict:
    if kind not in _polyhaven_index:
        _polyhaven_index[kind] = http_json("https://api.polyhaven.com/assets?t=" + kind)
    info = _polyhaven_index[kind].get(asset_id)
    if info is None:
        raise FetchError("Poly Haven has no %s called %s" % (kind, asset_id))
    return info


def fetch_polyhaven_model(asset_id: str) -> tuple:
    info = polyhaven_info(asset_id, "models")
    files = http_json("https://api.polyhaven.com/files/" + asset_id)
    try:
        entry = files["gltf"][POLYHAVEN_RESOLUTION]["gltf"]
    except KeyError:
        raise FetchError("no %s glTF listed for %s" % (POLYHAVEN_RESOLUTION, asset_id))
    document = json.loads(http_get(entry["url"]).decode("utf-8"))
    resources = {}
    urls = [entry["url"]]
    for relative, include in entry.get("include", {}).items():
        resources[relative] = http_get(include["url"])
        urls.append(include["url"])
    data = pack_glb(document, resources)
    meta = {
        "source": "Poly Haven",
        "source_id": asset_id,
        "source_page": "https://polyhaven.com/a/" + asset_id,
        "title": info.get("name", asset_id),
        "author": ", ".join(sorted(info.get("authors", {}).keys())),
        "license": "CC0 1.0",
        "download_urls": urls,
        "note": "glTF, .bin and %s textures packed into a single .glb by tools/fetch_assets.py" % POLYHAVEN_RESOLUTION,
    }
    return data, meta


def fetch_polypizza_model(public_id: str) -> tuple:
    page = "https://poly.pizza/m/" + public_id
    html = http_get(page, BROWSER_AGENT).decode("utf-8", "replace")
    match = re.search(r"window\.__SERVER_APP_STATE__\s*=\s*(\{.*?\})\s*;?\s*</script>", html, re.S)
    if not match:
        raise FetchError("could not read model data from " + page)
    model = json.loads(match.group(1))["initialData"]["model"]
    licence = model.get("Licence", "")
    if "CC0" not in licence.upper().replace(" ", ""):
        raise FetchError("%s is %s, not CC0" % (page, licence))
    url = "https://static.poly.pizza/%s.glb" % model["ResourceID"]
    data = http_get(url, BROWSER_AGENT)
    meta = {
        "source": "Poly Pizza",
        "source_id": public_id,
        "source_page": page,
        "title": model.get("Title", public_id),
        "author": model.get("Creator", {}).get("Username", ""),
        "license": licence,
        "download_urls": [url],
    }
    return data, meta


def fetch_vibeassets_model(asset_id: str) -> tuple:
    info = http_json("https://vibeassets.io/api/asset/" + urllib.parse.quote(asset_id))["asset"]
    licence = info.get("license", "")
    if not licence.upper().replace(" ", "").startswith("CC0"):
        raise FetchError("%s is %s, not CC0" % (info.get("page_url", asset_id), licence))
    if info.get("format") != "glb":
        raise FetchError("%s is %s, not a .glb" % (asset_id, info.get("format")))
    url = info["download_url"]
    data = http_get(url)
    if info.get("size_bytes") and len(data) != int(info["size_bytes"]):
        raise FetchError("%s: got %d bytes, the API lists %s" % (url, len(data), info["size_bytes"]))
    meta = {
        "source": "vibeassets",
        "source_id": asset_id,
        "source_page": info.get("page_url", "https://vibeassets.io/a/" + asset_id),
        "title": info.get("title", asset_id),
        "author": "vibeassets.io contributor (text-to-3D, auto-rigged)",
        "license": "CC0 1.0",
        "download_urls": [url],
    }
    return data, meta


def fetch_kaykit_model(ref: str) -> tuple:
    """A .gltf from one of Kay Lousberg's GitHub packs ("Repo@commit:path"), packed with its .bin and atlas."""
    repo, rest = ref.split("@", 1)
    commit, path = rest.split(":", 1)
    base = "https://raw.githubusercontent.com/KayKit-Game-Assets/%s/%s/" % (repo, commit)
    licence = http_once(base + "LICENSE.txt").decode("utf-8", "replace")
    if "Creative Commons Zero" not in licence:
        raise FetchError("%sLICENSE.txt does not state CC0" % base)
    url = base + urllib.parse.quote(path)
    document = json.loads(http_get(url).decode("utf-8"))
    folder = path.rsplit("/", 1)[0]
    resources = {}
    urls = [url]
    for entry in document.get("buffers", []) + document.get("images", []):
        uri = entry.get("uri", "")
        if not uri or uri.startswith("data:"):
            continue
        urls.append(base + urllib.parse.quote(folder + "/" + urllib.parse.unquote(uri)))
        resources[urllib.parse.unquote(uri)] = http_once(urls[-1])
    meta = {
        "source": "KayKit",
        "source_id": ref,
        "source_page": "https://github.com/KayKit-Game-Assets/" + repo,
        "title": "%s (%s)" % (os.path.splitext(os.path.basename(path))[0], plain(licence).split(" Created")[0]),
        "author": "Kay Lousberg",
        "license": "CC0 1.0",
        "download_urls": urls,
        "note": "glTF, .bin and texture atlas packed into a single .glb by tools/fetch_assets.py",
    }
    return pack_glb(document, resources), meta


def opengameart_file(ref: str) -> tuple:
    """A file attached to an OpenGameArt entry whose licence list includes CC0 ("content-slug:file name")."""
    slug, name = ref.split(":", 1)
    page = "https://opengameart.org/content/" + slug
    markup = page_text(page)
    licences = [plain(found) for found in re.findall(r"<div class='license-name'>(.*?)</div>", markup, re.S)]
    if "CC0" not in licences:
        raise FetchError("%s is %s, not CC0" % (page, ", ".join(licences) or "unlicensed"))
    link = re.search(r'<a href="(https://opengameart\.org/sites/default/files/[^"]+)" type="[^"]*length=(\d+)"[^>]*download="%s"'
                     % re.escape(html.escape(name)), markup)
    if not link:
        raise FetchError("%s has no attached file called %s" % (page, name))
    data = http_once(link.group(1))
    if len(data) != int(link.group(2)):
        raise FetchError("%s: got %d bytes, the page lists %s" % (link.group(1), len(data), link.group(2)))
    title = re.search(r"<title>(.*?)</title>", markup, re.S)
    author = re.search(r"<span class='username'>(.*?)</span>", markup, re.S)
    meta = {
        "source": "OpenGameArt",
        "source_id": ref,
        "source_page": page,
        "title": plain(title.group(1)).split(" | ")[0] if title else slug,
        "author": plain(author.group(1)) if author else "",
        "license": "CC0 1.0",
        "download_urls": [link.group(1)],
    }
    return data, meta


def obj_to_glb(text: str, texture: bytes, name: str) -> bytes:
    """Flat-shaded .glb of a one-material Wavefront OBJ and its colour map, re-centred to stand on the origin."""
    points = []
    coords = []
    corners = []
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "v":
            points.append([float(value) for value in parts[1:4]])
        elif parts[0] == "vt":
            # OBJ puts v = 0 at the bottom of the image, glTF at the top.
            coords.append([float(parts[1]), 1.0 - float(parts[2])])
        elif parts[0] == "f":
            face = []
            for token in parts[1:]:
                refs = token.split("/")
                point = int(refs[0])
                coord = int(refs[1]) if len(refs) > 1 and refs[1] else 0
                face.append((points[point - 1 if point > 0 else point],
                             coords[coord - 1 if coord > 0 else coord] if coord else [0.0, 0.0]))
            # Newell's method gives one normal for the whole polygon.
            normal = [0.0, 0.0, 0.0]
            for index, (here, _) in enumerate(face):
                there = face[(index + 1) % len(face)][0]
                normal[0] += (here[1] - there[1]) * (here[2] + there[2])
                normal[1] += (here[2] - there[2]) * (here[0] + there[0])
                normal[2] += (here[0] - there[0]) * (here[1] + there[1])
            length = sum(value * value for value in normal) ** 0.5 or 1.0
            normal = [value / length for value in normal]
            for index in range(1, len(face) - 1):
                for point, coord in (face[0], face[index], face[index + 1]):
                    corners.append((point, normal, coord))
    if not corners:
        raise FetchError("OBJ has no faces")
    low = [min(corner[0][axis] for corner in corners) for axis in range(3)]
    high = [max(corner[0][axis] for corner in corners) for axis in range(3)]
    shift = [(low[0] + high[0]) / 2.0, low[1], (low[2] + high[2]) / 2.0]
    positions = [[corner[0][axis] - shift[axis] for axis in range(3)] for corner in corners]
    count = len(corners)
    blob = b"".join(struct.pack("<3f", *position) for position in positions)
    blob += b"".join(struct.pack("<3f", *corner[1]) for corner in corners)
    blob += b"".join(struct.pack("<2f", *corner[2]) for corner in corners)
    kind = image_format(texture)
    if not kind:
        raise FetchError("OBJ colour map is not a JPEG or PNG")
    document = {
        "asset": {"version": "2.0", "generator": "tools/fetch_assets.py obj_to_glb"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": name, "mesh": 0}],
        "meshes": [{"name": name, "primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "material": 0}]}],
        "materials": [{"name": name, "pbrMetallicRoughness": {"baseColorTexture": {"index": 0},
                                                                "metallicFactor": 0.0, "roughnessFactor": 0.7}}],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9729, "minFilter": 9987}],
        "images": [{"uri": "colour." + kind}],
        "buffers": [{"uri": "mesh.bin", "byteLength": len(blob)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": count * 12, "target": 34962},
            {"buffer": 0, "byteOffset": count * 12, "byteLength": count * 12, "target": 34962},
            {"buffer": 0, "byteOffset": count * 24, "byteLength": count * 8, "target": 34962},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": count, "type": "VEC3",
             "min": [min(position[axis] for position in positions) for axis in range(3)],
             "max": [max(position[axis] for position in positions) for axis in range(3)]},
            {"bufferView": 1, "componentType": 5126, "count": count, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": count, "type": "VEC2"},
        ],
    }
    return pack_glb(document, {"mesh.bin": blob, "colour." + kind: texture})


def fetch_opengameart_model(ref: str) -> tuple:
    """An OBJ and its texture out of a CC0 OpenGameArt zip ("content-slug:archive:member.obj:member.png")."""
    slug, archive, model, texture = ref.split(":")
    data, meta = opengameart_file(slug + ":" + archive)
    with zipfile.ZipFile(io.BytesIO(data)) as bundle:
        glb = obj_to_glb(bundle.read(model).decode("utf-8", "replace"), bundle.read(texture),
                         os.path.splitext(os.path.basename(model))[0])
    meta["source_id"] = ref
    meta["note"] = ("%s and %s from %s converted to a flat-shaded .glb, re-centred to stand on the origin, "
                    "by tools/fetch_assets.py" % (model, texture, archive))
    return glb, meta


def fetch_polyhaven_texture(asset_id: str) -> tuple:
    info = polyhaven_info(asset_id, "textures")
    files = http_json("https://api.polyhaven.com/files/" + asset_id)
    maps = {}
    urls = []
    for key, suffix in POLYHAVEN_MAPS:
        try:
            entry = files[key][POLYHAVEN_RESOLUTION]["jpg"]
        except KeyError:
            continue
        maps[suffix] = http_get(entry["url"])
        urls.append(entry["url"])
    meta = {
        "source": "Poly Haven",
        "source_id": asset_id,
        "source_page": "https://polyhaven.com/a/" + asset_id,
        "title": info.get("name", asset_id),
        "author": ", ".join(sorted(info.get("authors", {}).keys())),
        "license": "CC0 1.0",
        "download_urls": urls,
    }
    return maps, meta


def fetch_ambientcg_texture(asset_id: str) -> tuple:
    query = "https://ambientcg.com/api/v2/full_json?include=downloadData&id=" + urllib.parse.quote(asset_id)
    found = http_json(query).get("foundAssets", [])
    if not found:
        raise FetchError("ambientCG has no asset called " + asset_id)
    downloads = found[0]["downloadFolders"]["default"]["downloadFiletypeCategories"]["zip"]["downloads"]
    chosen = [d for d in downloads if d.get("attribute") == AMBIENTCG_ATTRIBUTE]
    if not chosen:
        raise FetchError("no %s download for %s" % (AMBIENTCG_ATTRIBUTE, asset_id))
    url = chosen[0]["fullDownloadPath"]
    archive = http_get(url)
    if archive[:2] != b"PK":
        raise FetchError("ambientCG download for %s is not a zip archive" % asset_id)
    maps = {}
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        for member in bundle.namelist():
            stem = os.path.splitext(member)[0]
            for token, suffix in AMBIENTCG_MAPS:
                if stem.endswith(token):
                    maps[suffix] = bundle.read(member)
    meta = {
        "source": "ambientCG",
        "source_id": asset_id,
        "source_page": "https://ambientcg.com/view?id=" + asset_id,
        "title": found[0].get("displayName", asset_id),
        "author": "ambientCG (Lennart Demes)",
        "license": "CC0 1.0",
        "download_urls": [url],
        "note": "maps extracted from the %s zip" % AMBIENTCG_ATTRIBUTE,
    }
    return maps, meta


MODEL_SOURCES = {"polyhaven": fetch_polyhaven_model, "polypizza": fetch_polypizza_model, "vibeassets": fetch_vibeassets_model}
TEXTURE_SOURCES = {"polyhaven": fetch_polyhaven_texture, "ambientcg": fetch_ambientcg_texture}


# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

def model_path(name: str, folder: str) -> str:
    return os.path.join(MODELS, folder, name + ".glb")


def texture_path(name: str, suffix: str) -> str:
    # Sets may live in a sub-folder ("demon/charred_skin"); files are named after the leaf.
    return os.path.join(TEXTURES, name, "%s_%s.jpg" % (os.path.basename(name), suffix))


def do_model(job: tuple, previous: dict, force: bool) -> dict:
    name, source, asset_id, folder = job
    path = model_path(name, folder)
    record = {"name": name, "type": "model", "category": folder, "status": "ok"}
    try:
        old = previous.get(name)
        if not force and old and old.get("source_id") == asset_id and os.path.isfile(path):
            data = open(path, "rb").read()
            record.update({k: v for k, v in old.items() if k not in ("files", "status")})
            record["cached"] = True
        else:
            data, meta = MODEL_SOURCES[source](asset_id)
            record.update(meta)
            data, repaired = glb_repair_images(data)
            if repaired:
                record["note"] = ("%d embedded JPEG(s) re-ordered losslessly to 1x1 sampling so Godot can decode them; "
                                  "mesh, skin and pixels are unchanged" % repaired)
            # Validate before anything lands on disk.
            glb_summary(data)
            if name in RIGGED_MODELS:
                glb_rig(data, RIGGED_MODELS[name])
            write_file(path, data)
        record.update(glb_summary(data))
        if name in RIGGED_MODELS:
            record["rig"] = glb_rig(data, RIGGED_MODELS[name])
        record["files"] = [file_record(path, data, "glb")]
    except (FetchError, KeyError, ValueError, OSError) as error:
        record["status"] = "failed"
        record["error"] = str(error)
        record["files"] = []
    return record


def do_texture(job: tuple, previous: dict, force: bool) -> dict:
    name, source, asset_id = job
    record = {"name": name, "type": "texture_set", "status": "ok"}
    try:
        old = previous.get(name)
        cached = {}
        if not force and old and old.get("source_id") == asset_id:
            for entry in old.get("files", []):
                local = os.path.join(ROOT, entry["path"].replace("res://", ""))
                if os.path.isfile(local):
                    cached[entry["map"]] = open(local, "rb").read()
        if cached and len(cached) == len(old.get("files", [])):
            maps = cached
            record.update({k: v for k, v in old.items() if k not in ("files", "status")})
            record["cached"] = True
        else:
            maps, meta = TEXTURE_SOURCES[source](asset_id)
            record.update(meta)
        files = []
        for suffix in ("albedo", "normal", "roughness", "ao"):
            if suffix not in maps:
                continue
            kind = image_format(maps[suffix])
            if kind != "jpeg":
                raise FetchError("%s map of %s is not a JPEG" % (suffix, asset_id))
            path = texture_path(name, suffix)
            if not record.get("cached"):
                write_file(path, maps[suffix])
            entry = file_record(path, maps[suffix], kind)
            entry["map"] = suffix
            files.append(entry)
        present = [f["map"] for f in files]
        for required in ("albedo", "normal", "roughness"):
            if required not in present:
                raise FetchError("%s has no %s map" % (asset_id, required))
        record["maps"] = present
        record["files"] = files
    except (FetchError, KeyError, ValueError, OSError, zipfile.BadZipFile) as error:
        record["status"] = "failed"
        record["error"] = str(error)
        record["files"] = []
    return record


def load_previous() -> dict:
    if not os.path.isfile(MANIFEST):
        return {}
    try:
        with open(MANIFEST, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError):
        return {}
    return {entry["name"]: entry for entry in manifest.get("models", []) + manifest.get("textures", [])}


def human(size: int) -> str:
    if size >= 1 << 20:
        return "%.2f MB" % (size / (1 << 20))
    return "%.1f KB" % (size / 1024.0)


def print_summary(models: list, textures: list) -> None:
    print("")
    print("%-22s %-11s %-30s %10s %9s  %s" % ("MODEL", "SOURCE", "TITLE", "SIZE", "TRIS", "FILE"))
    for record in models:
        if record["status"] != "ok":
            print("%-22s FAILED: %s" % (record["name"], record.get("error", "")))
            continue
        entry = record["files"][0]
        print("%-22s %-11s %-30s %10s %9d  %s" % (record["name"], record["source"], record["title"][:30],
                human(entry["bytes"]), record["triangles"], entry["path"]))
    print("")
    print("%-22s %-11s %-30s %10s  %s" % ("TEXTURE SET", "SOURCE", "TITLE", "SIZE", "MAPS"))
    for record in textures:
        if record["status"] != "ok":
            print("%-22s FAILED: %s" % (record["name"], record.get("error", "")))
            continue
        total = sum(entry["bytes"] for entry in record["files"])
        print("%-22s %-11s %-30s %10s  %s" % (record["name"], record["source"], record["title"][:30], human(total),
                ", ".join(record["maps"])))
    for record in models:
        if record["status"] == "ok" and "rig" in record:
            print_rig(record)


def verify_offline() -> int:
    if not os.path.isfile(MANIFEST):
        print("No manifest at %s. Run without --verify first." % MANIFEST)
        return 1
    with open(MANIFEST, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    problems = 0
    checked = 0
    for record in manifest.get("models", []) + manifest.get("textures", []):
        for entry in record.get("files", []):
            local = os.path.join(ROOT, entry["path"].replace("res://", ""))
            checked += 1
            try:
                data = open(local, "rb").read()
                if hashlib.sha256(data).hexdigest() != entry["sha256"]:
                    raise FetchError("checksum mismatch")
                if entry["format"] == "glb":
                    glb_summary(data)
                    if record["name"] in RIGGED_MODELS:
                        record["rig"] = glb_rig(data, RIGGED_MODELS[record["name"]])
                        print_rig(record)
                elif image_format(data) != entry["format"]:
                    raise FetchError("not a valid %s" % entry["format"])
            except (OSError, FetchError) as error:
                problems += 1
                print("BAD  %s: %s" % (entry["path"], error))
    print("Checked %d files, %d problem(s)." % (checked, problems))
    return 1 if problems else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--force", action="store_true", help="re-download files that already exist")
    parser.add_argument("--verify", action="store_true", help="only re-check local files against the manifest")
    args = parser.parse_args()
    if args.verify:
        return verify_offline()

    previous = load_previous()
    started = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        model_jobs = [pool.submit(do_model, job, previous, args.force) for job in MODEL_CATALOG]
        texture_jobs = [pool.submit(do_texture, job, previous, args.force) for job in TEXTURE_CATALOG]
        models = [job.result() for job in model_jobs]
        textures = [job.result() for job in texture_jobs]

    failed = [r for r in models + textures if r["status"] != "ok"]
    model_bytes = sum(f["bytes"] for r in models for f in r["files"])
    texture_bytes = sum(f["bytes"] for r in textures for f in r["files"])
    manifest = {
        "generator": "tools/fetch_assets.py",
        "generated_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "license_summary": "Every asset is CC0 1.0 (public domain dedication). Attribution is not required; authors are listed as a courtesy.",
        "totals": {
            "models": len([r for r in models if r["status"] == "ok"]),
            "texture_sets": len([r for r in textures if r["status"] == "ok"]),
            "files": sum(len(r["files"]) for r in models + textures),
            "model_bytes": model_bytes,
            "texture_bytes": texture_bytes,
            "triangles": sum(r.get("triangles", 0) for r in models),
            "failed": len(failed),
        },
        "models": models,
        "textures": textures,
    }
    os.makedirs(ASSETS, exist_ok=True)
    with open(MANIFEST, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=1, sort_keys=False)
        handle.write("\n")

    print_summary(models, textures)
    print("")
    print("%d models (%s, %d triangles) and %d texture sets (%s) in %.0f s. Manifest: %s" % (
        manifest["totals"]["models"], human(model_bytes), manifest["totals"]["triangles"],
        manifest["totals"]["texture_sets"], human(texture_bytes), time.time() - started,
        os.path.relpath(MANIFEST, ROOT)))
    if failed:
        print("%d asset(s) FAILED; the game falls back to placeholder meshes for those." % len(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
