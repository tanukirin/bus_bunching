from __future__ import annotations

import copy
import json
import math
from pathlib import Path
from typing import Any


MODE_KEYS = ("plain", "skip", "spring")

NOISE_MEAN_FACTOR = 0.24 * 0.5 + 0.76 * 0.22 * 0.5 + 0.035 * ((0.6 + 1.8) / 2)

PRESETS: dict[str, dict[str, Any]] = {
    "urban": {
        "name": "高頻度都市路線",
        "seed": 58021,
        "stopCount": 20,
        "busCount": 5,
        "durationMin": 120,
        "demandMultiplier": 0.8,
        "capacity": 36,
        "baseSpeedKmh": 15,
        "stopDistanceKm": 0.3,
        "boardTimeSec": 3,
        "alightTimeSec": 3,
        "randomDelayMeanSec": 28,
        "hotspotStops": [0, 7, 14],
        "hotspotMultiplier": 3,
        "protectHotspotStops": False,
        "initialDelaySec": 0,
        "distanceThresholdStops": 1.8,
        "timeThresholdMin": 3,
        "delayThresholdMin": 5,
        "followerLoadLimit": 0.9,
        "policyMode": "hybrid",
        "springGainSecPerStop": 40,
        "springDeadbandStops": 1.2,
        "springDamping": 0,
        "springMaxHoldSec": 180,
        "springMinHoldSec": 20,
        "fixedStopSec": 13,
        "boardingSetupSec": 3.5,
        "alightingSetupSec": 3.5,
        "crowdedExtraSec": 4,
        "crowdingThreshold": 0.8,
    }
}


def clamp(value: float, minimum: float, maximum: float) -> float:
    return max(minimum, min(maximum, value))


def number_with_default(value: Any, fallback: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return fallback
    return number if math.isfinite(number) else fallback


def legacy_delay_scale_to_mean(base_travel_sec: float, scale_sec: float) -> float:
    return max(0.0, base_travel_sec * 0.02 + max(0.0, scale_sec) * NOISE_MEAN_FACTOR)


def delay_mean_to_scale(mean_sec: float) -> float:
    return max(0.0, mean_sec) / NOISE_MEAN_FACTOR


def normalize_config(raw: dict[str, Any]) -> dict[str, Any]:
    c = copy.deepcopy(raw)
    c["stopCount"] = int(clamp(round(number_with_default(c.get("stopCount"), 20)), 8, 28))
    c["busCount"] = int(
        clamp(round(number_with_default(c.get("busCount"), 5)), 3, min(10, c["stopCount"] - 2))
    )
    c["durationMin"] = number_with_default(c.get("durationMin"), 120)
    c["durationSec"] = round(c["durationMin"] * 60)
    c["baseSpeedKmh"] = number_with_default(c.get("baseSpeedKmh"), 15)
    c["stopDistanceKm"] = number_with_default(c.get("stopDistanceKm"), 0.3)
    c["baseTravelSec"] = max(20.0, c["stopDistanceKm"] / max(4.0, c["baseSpeedKmh"]) * 3600)

    legacy_scale = number_with_default(c.get("randomDelaySec"), 26)
    if not math.isfinite(number_with_default(c.get("randomDelayMeanSec"), math.nan)):
        c["randomDelayMeanSec"] = legacy_delay_scale_to_mean(c["baseTravelSec"], legacy_scale)
    c["randomDelayMeanSec"] = clamp(number_with_default(c.get("randomDelayMeanSec"), 0), 0, 180)
    c["randomDelayScaleSec"] = delay_mean_to_scale(c["randomDelayMeanSec"])
    c.pop("randomDelaySec", None)

    c["demandMultiplier"] = number_with_default(c.get("demandMultiplier"), 0.8)
    c["capacity"] = int(number_with_default(c.get("capacity"), 36))
    c["boardTimeSec"] = number_with_default(c.get("boardTimeSec"), 3)
    c["alightTimeSec"] = number_with_default(c.get("alightTimeSec"), 3)
    if "fixedStopSec" in c:
        c["fixedStopSec"] = number_with_default(c.get("fixedStopSec"), 18)
    else:
        c["fixedStopSec"] = number_with_default(c.get("stopManeuverLossSec"), 14) + number_with_default(c.get("doorTimeSec"), 4)
    c.pop("stopManeuverLossSec", None)
    c.pop("doorTimeSec", None)
    c["boardingSetupSec"] = number_with_default(c.get("boardingSetupSec"), 2)
    c["alightingSetupSec"] = number_with_default(c.get("alightingSetupSec"), 1)
    c["crowdedExtraSec"] = number_with_default(c.get("crowdedExtraSec"), 5)
    c["crowdingThreshold"] = number_with_default(c.get("crowdingThreshold"), 0.75)
    c["baseStopSec"] = c["fixedStopSec"]
    c["sampleIntervalSec"] = 15
    c["waitWindowSec"] = 300
    c["arrivalQuantumSec"] = 5
    c["noiseBucketSec"] = 60
    c["controlEnabled"] = raw.get("controlEnabled") is not False
    c["controlMode"] = raw.get("controlMode") or "none"
    c["seed"] = int(number_with_default(raw.get("seed"), 1)) or 1
    c["initialDelaySec"] = number_with_default(c.get("initialDelaySec"), 0)
    c["distanceThresholdStops"] = clamp(number_with_default(c.get("distanceThresholdStops"), 1.8), 0.2, 3)
    c["delayThresholdMin"] = clamp(number_with_default(c.get("delayThresholdMin"), 0), 0, 12)
    c["followerLoadLimit"] = clamp(number_with_default(c.get("followerLoadLimit"), 0.9), 0.3, 1)
    c["springGainSecPerStop"] = clamp(number_with_default(c.get("springGainSecPerStop"), 18), 0, 90)
    c["springDeadbandStops"] = clamp(number_with_default(c.get("springDeadbandStops"), 0.6), 0, 4)
    c["springDamping"] = clamp(number_with_default(c.get("springDamping"), 0.06), 0, 0.5)
    c["springMaxHoldSec"] = clamp(number_with_default(c.get("springMaxHoldSec"), 45), 0, 180)
    c["springMinHoldSec"] = clamp(number_with_default(c.get("springMinHoldSec"), 8), 0, 60)
    c["hotspotMultiplier"] = number_with_default(c.get("hotspotMultiplier"), 1)
    hotspot_stops = c.get("hotspotStops") or []
    c["hotspotStops"] = [int(n) for n in hotspot_stops if isinstance(n, (int, float)) and 0 <= int(n) < c["stopCount"]]
    c["protectHotspotStops"] = raw.get("protectHotspotStops") is True or raw.get("protectHotspotStops") == "true"
    c["forbiddenStops"] = list(c["hotspotStops"]) if c["protectHotspotStops"] else []
    return c


def extract_config(payload: dict[str, Any]) -> dict[str, Any]:
    config = payload.get("config") or payload.get("settings") or payload
    if not isinstance(config, dict):
        raise ValueError("config object not found")
    return config


def load_json(path: str | Path) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as f:
        return json.load(f)


def load_config(path: str | Path) -> dict[str, Any]:
    return normalize_config(extract_config(load_json(path)))


def seed_sequence(spec: dict[str, Any]) -> list[int]:
    base = max(1, int(spec.get("base", 1)))
    count = max(1, int(spec.get("count", 1)))
    step = int(spec.get("step", 101))
    return [base + i * step for i in range(count)]
