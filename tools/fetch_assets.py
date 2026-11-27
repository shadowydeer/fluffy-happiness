#!/usr/bin/env python3
"""Download and verify every third-party asset used by BIND & DELIVER.

Standard library only. Run from anywhere:

    python3 tools/fetch_assets.py            # fetch whatever is missing, then verify
    python3 tools/fetch_assets.py --force    # re-download everything
    python3 tools/fetch_assets.py --verify   # offline: re-check local files against the manifest

Sources (all CC0 1.0 / public domain; licence is re-checked against each API):
  * Poly Haven  https://api.polyhaven.com   models (glTF packed into one .glb) and PBR textures
  * Poly Pizza  https://poly.pizza          .glb models by Quaternius, Kay Lousberg, CreativeTrio, iPoly3D
  * ambientCG   https://ambientcg.com/api   PBR textures

Nothing is fetched from a guessed URL: every download link comes out of the
source's own API response for the asset id listed in the catalog below.
Each file is checked for HTTP 200, a non-trivial size and the right magic
bytes (glTF / JPEG / PNG), and the result is written to
assets/asset_manifest.json.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import hashlib
import io
import json
import os
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
MODELS = os.path.join(ASSETS, "models")
TEXTURES = os.path.join(ASSETS, "textures")
MANIFEST = os.path.join(ASSETS, "asset_manifest.json")

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
]

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


class FetchError(Exception):
    pass


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def http_get(url: str, agent: str = USER_AGENT, attempts: int = 4) -> bytes:
    """GET that insists on HTTP 200 and retries transient failures."""
    last = ""
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": agent, "Accept": "*/*"})
            with urllib.request.urlopen(request, timeout=120) as response:
                if response.status != 200:
                    raise FetchError("HTTP %s for %s" % (response.status, url))
                return response.read()
        except urllib.error.HTTPError as error:
            last = "HTTP %s" % error.code
            if error.code in (400, 401, 403, 404, 410):
                break
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
            last = str(error)
        time.sleep(1.5 * (attempt + 1))
    raise FetchError("%s (%s)" % (url, last))


def http_json(url: str, agent: str = USER_AGENT):
    return json.loads(http_get(url, agent).decode("utf-8"))


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

def image_format(data: bytes) -> str:
    if data[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    return ""


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


def file_record(path: str, data: bytes, kind: str) -> dict:
    return {
        "path": "res://" + os.path.relpath(path, ROOT).replace(os.sep, "/"),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "format": kind,
        "verified": True,
    }


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


MODEL_SOURCES = {"polyhaven": fetch_polyhaven_model, "polypizza": fetch_polypizza_model}
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
            write_file(path, data)
        record.update(glb_summary(data))
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
