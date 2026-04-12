"""
ha_commands.py
--------------
Handles parsing natural language home commands and executing them
via the Home Assistant REST API.

Usage:
    from ha_commands import handle_home_command
    result = await handle_home_command("turn off the kitchen lights")
    # result: { "success": True, "action": "...", "error": None }
"""

import re
import os
import httpx
from typing import Optional, Union   # <-- ADD Union

# ========== Configuration ==========
HA_HOST  = os.getenv("HA_HOST", "http://homeassistant.local:8123")
HA_TOKEN = os.getenv("HA_TOKEN", "")

# ========== Entity Map ==========
ENTITY_MAP = {
    "lights":              ["light.living_room", "light.kitchen", "light.bedroom"],
    "all lights":          ["light.living_room", "light.kitchen", "light.bedroom"],
    "living room lights":  "light.living_room",
    "living room light":   "light.living_room",
    "kitchen lights":      "light.kitchen",
    "bedroom lights":      "light.bedroom",
    "bedroom light":       "light.bedroom",
}

# ========== Script Map ==========
SCRIPT_MAP = {
    "water the plants":    "script.water_the_plants",
    "water plants":        "script.water_the_plants",
    "goodnight":           "script.goodnight_routine",
    "good night":          "script.goodnight_routine",
    "movie night":         "script.movie_night",
    "morning routine":     "script.morning_routine",
}

# ========== Scene Map ==========
SCENE_MAP = {
    "movie night":         "scene.movie_night",
    "relax":               "scene.relax",
    "bright":              "scene.bright",
    "dim":                 "scene.dim",
}

# ========== Shopping / To-Do Lists ==========
SHOPPING_LIST_ENTITY = os.getenv("HA_SHOPPING_LIST_ENTITY", "todo.shopping_list")

# ========== Intent Patterns ==========
PATTERNS = [
    (re.compile(
        r"add (.+?) to (?:(?:my|the) )?(?:shopping list|grocery list|todo list|to-do list|to do list)",
        re.IGNORECASE
    ), "add_todo"),

    (re.compile(
        r"(?:run|execute|trigger|start|activate)?\s*(" + "|".join(re.escape(k) for k in SCRIPT_MAP) + r")",
        re.IGNORECASE
    ), "run_script"),

    (re.compile(
        r"(?:activate|set|enable|turn on)?\s*(" + "|".join(re.escape(k) for k in SCENE_MAP) + r")\s*(?:scene|mode)?",
        re.IGNORECASE
    ), "activate_scene"),

    (re.compile(
        r"(?:dim|set|turn|brighten)\s+(?:the\s+)?(.+?)\s+(?:lights?\s+)?(?:to\s+)?(\d{1,3})\s*(?:percent|%)?",
        re.IGNORECASE
    ), "set_brightness"),

    (re.compile(
        r"set\s+(?:the\s+)?(?:thermostat|heating|temperature|temp)\s+(?:to\s+)?(\d{1,2}(?:\.\d)?)\s*(?:degrees?|°[CF]?)?",
        re.IGNORECASE
    ), "set_temperature"),

    (re.compile(
        r"turn\s+on\s+(?:the\s+)?(.+)",
        re.IGNORECASE
    ), "turn_on"),

    (re.compile(
        r"turn\s+off\s+(?:the\s+)?(.+)",
        re.IGNORECASE
    ), "turn_off"),

    (re.compile(
        r"toggle\s+(?:the\s+)?(.+)",
        re.IGNORECASE
    ), "toggle"),

    (re.compile(
        r"switch\s+off\s+(?:the\s+)?(.+)",
        re.IGNORECASE
    ), "turn_off"),

    (re.compile(
        r"switch\s+on\s+(?:the\s+)?(.+)",
        re.IGNORECASE
    ), "turn_on"),
]

# ========== HA API Helper ==========
def _ha_headers() -> dict:
    return {
        "Authorization": f"Bearer {HA_TOKEN}",
        "Content-Type": "application/json",
    }

async def _call_service(domain: str, service: str, payload: dict) -> dict:
    url = f"{HA_HOST}/api/services/{domain}/{service}"
    print(f"  [HA] POST {url} payload={payload}")
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(url, headers=_ha_headers(), json=payload)
        resp.raise_for_status()
        return resp.json()

# ========== Entity Resolution ==========
def _resolve_entity(phrase: str) -> Optional[Union[str, list]]:   # <-- FIXED LINE
    """
    Fuzzy-match a spoken phrase to an entity ID.
    Returns a string, a list of strings, or None.
    """
    phrase = phrase.strip().lower()

    if phrase in ENTITY_MAP:
        return ENTITY_MAP[phrase]

    for key, entity in ENTITY_MAP.items():
        if key in phrase or phrase in key:
            return entity

    return None

# ========== Action Handlers ==========
async def _handle_turn_on(entity_phrase: str) -> dict:
    entity = _resolve_entity(entity_phrase)
    if not entity:
        return {"success": False, "action": None, "error": f"Could not find entity matching '{entity_phrase}'"}

    domain = "light" if "light" in str(entity) else "switch"
    payload = {"entity_id": entity}
    await _call_service(domain, "turn_on", payload)
    return {"success": True, "action": f"Turned on {entity_phrase}", "error": None}

async def _handle_turn_off(entity_phrase: str) -> dict:
    entity = _resolve_entity(entity_phrase)
    if not entity:
        return {"success": False, "action": None, "error": f"Could not find entity matching '{entity_phrase}'"}

    domain = "light" if "light" in str(entity) else "switch"
    payload = {"entity_id": entity}
    await _call_service(domain, "turn_off", payload)
    return {"success": True, "action": f"Turned off {entity_phrase}", "error": None}

async def _handle_toggle(entity_phrase: str) -> dict:
    entity = _resolve_entity(entity_phrase)
    if not entity:
        return {"success": False, "action": None, "error": f"Could not find entity matching '{entity_phrase}'"}

    domain = "light" if "light" in str(entity) else "switch"
    payload = {"entity_id": entity}
    await _call_service(domain, "toggle", payload)
    return {"success": True, "action": f"Toggled {entity_phrase}", "error": None}

async def _handle_set_brightness(entity_phrase: str, brightness_pct: int) -> dict:
    entity = _resolve_entity(entity_phrase)
    if not entity:
        return {"success": False, "action": None, "error": f"Could not find entity matching '{entity_phrase}'"}

    payload = {"entity_id": entity, "brightness_pct": brightness_pct}
    await _call_service("light", "turn_on", payload)
    return {"success": True, "action": f"Set {entity_phrase} brightness to {brightness_pct}%", "error": None}

async def _handle_set_temperature(temperature: float) -> dict:
    payload = {"entity_id": ENTITY_MAP.get("thermostat", "climate.living_room"), "temperature": temperature}
    await _call_service("climate", "set_temperature", payload)
    return {"success": True, "action": f"Set thermostat to {temperature}°", "error": None}

async def _handle_add_todo(item: str) -> dict:
    payload = {"entity_id": SHOPPING_LIST_ENTITY, "item": item.strip().capitalize()}
    await _call_service("todo", "add_item", payload)
    return {"success": True, "action": f"Added '{item.strip()}' to your shopping list", "error": None}

async def _handle_run_script(phrase: str) -> dict:
    key = phrase.strip().lower()
    script_entity = SCRIPT_MAP.get(key)
    if not script_entity:
        for k, v in SCRIPT_MAP.items():
            if k in key or key in k:
                script_entity = v
                break

    if not script_entity:
        return {"success": False, "action": None, "error": f"No script found for '{phrase}'"}

    script_name = script_entity.replace("script.", "")
    await _call_service("script", script_name, {})
    return {"success": True, "action": f"Ran script: {phrase}", "error": None}

async def _handle_activate_scene(phrase: str) -> dict:
    key = phrase.strip().lower()
    scene_entity = SCENE_MAP.get(key)
    if not scene_entity:
        for k, v in SCENE_MAP.items():
            if k in key or key in k:
                scene_entity = v
                break

    if not scene_entity:
        return {"success": False, "action": None, "error": f"No scene found for '{phrase}'"}

    await _call_service("scene", "turn_on", {"entity_id": scene_entity})
    return {"success": True, "action": f"Activated scene: {phrase}", "error": None}

# ========== Main Entry Point ==========
async def handle_home_command(text: str) -> dict:
    """
    Parse a natural language command and execute it via HA REST API.

    Returns:
        {
            "success": bool,
            "action":  str | None,
            "error":   str | None
        }
    """
    print(f"\n[ha_commands] Parsing command: \"{text}\"")

    for pattern, handler_key in PATTERNS:
        match = pattern.search(text)
        if not match:
            continue

        print(f"  [ha_commands] Matched handler: {handler_key} | groups: {match.groups()}")

        try:
            if handler_key == "turn_on":
                return await _handle_turn_on(match.group(1))
            elif handler_key == "turn_off":
                return await _handle_turn_off(match.group(1))
            elif handler_key == "toggle":
                return await _handle_toggle(match.group(1))
            elif handler_key == "set_brightness":
                return await _handle_set_brightness(match.group(1), int(match.group(2)))
            elif handler_key == "set_temperature":
                return await _handle_set_temperature(float(match.group(1)))
            elif handler_key == "add_todo":
                return await _handle_add_todo(match.group(1))
            elif handler_key == "run_script":
                return await _handle_run_script(match.group(1))
            elif handler_key == "activate_scene":
                return await _handle_activate_scene(match.group(1))

        except httpx.HTTPStatusError as e:
            return {"success": False, "action": None, "error": f"HA API error {e.response.status_code}: {e.response.text[:200]}"}
        except Exception as e:
            return {"success": False, "action": None, "error": str(e)}

    return {"success": False, "action": None, "error": f"Could not parse command: '{text}'"}
