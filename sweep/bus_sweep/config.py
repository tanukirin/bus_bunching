from __future__ import annotations

import copy
import json
import math
from pathlib import Path
from typing import Any


MODE_KEYS = ("plain", "skip", "spring")

NOISE_MEAN_FACTOR = 0.24 * 0.5 + 0.76 * 0.22 * 0.5 + 0.035 * ((0.6 + 1.8) / 2)
MIN_POSITIVE = 1e-9
MIN_DURATION_MIN = 1 / 60

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
        "stopBerthMode": "single",
        "stopBerthCapacity": 1,
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
        "springVoluntaryDeferralEnabled": False,
        "springControlSkipEnabled": True,
        "springHoldingEnabled": True,
        "forbidHoldingWhenFull": True,
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


def bool_with_default(value: Any, fallback: bool) -> bool:
    if value is None:
        return fallback
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"true", "1", "yes", "on"}:
            return True
        if lowered in {"false", "0", "no", "off"}:
            return False
        return fallback
    if isinstance(value, (int, float)):
        return value != 0
    return fallback


def legacy_delay_scale_to_mean(base_travel_sec: float, scale_sec: float) -> float:
    return max(0.0, base_travel_sec * 0.02 + max(0.0, scale_sec) * NOISE_MEAN_FACTOR)


def delay_mean_to_scale(mean_sec: float) -> float:
    return max(0.0, mean_sec) / NOISE_MEAN_FACTOR


def normalize_config(raw: dict[str, Any]) -> dict[str, Any]:
    c = copy.deepcopy(raw)
    c["stopCount"] = max(2, int(round(number_with_default(c.get("stopCount"), 20))))
    c["busCount"] = max(1, int(round(number_with_default(c.get("busCount"), 5))))
    c["durationMin"] = max(MIN_DURATION_MIN, number_with_default(c.get("durationMin"), 120))
    c["durationSec"] = round(c["durationMin"] * 60)
    c["baseSpeedKmh"] = max(MIN_POSITIVE, number_with_default(c.get("baseSpeedKmh"), 15))
    c["stopDistanceKm"] = max(MIN_POSITIVE, number_with_default(c.get("stopDistanceKm"), 0.3))
    c["baseTravelSec"] = max(MIN_POSITIVE, c["stopDistanceKm"] / c["baseSpeedKmh"] * 3600)

    legacy_scale = number_with_default(c.get("randomDelaySec"), 26)
    if not math.isfinite(number_with_default(c.get("randomDelayMeanSec"), math.nan)):
        c["randomDelayMeanSec"] = legacy_delay_scale_to_mean(c["baseTravelSec"], legacy_scale)
    c["randomDelayMeanSec"] = max(0.0, number_with_default(c.get("randomDelayMeanSec"), 0))
    c["randomDelayScaleSec"] = delay_mean_to_scale(c["randomDelayMeanSec"])
    c.pop("randomDelaySec", None)

    c["demandMultiplier"] = max(0.0, number_with_default(c.get("demandMultiplier"), 0.8))
    c["capacity"] = max(1, int(number_with_default(c.get("capacity"), 36)))
    c["boardTimeSec"] = max(0.0, number_with_default(c.get("boardTimeSec"), 3))
    c["alightTimeSec"] = max(0.0, number_with_default(c.get("alightTimeSec"), 3))
    if "fixedStopSec" in c:
        c["fixedStopSec"] = max(0.0, number_with_default(c.get("fixedStopSec"), 18))
    else:
        c["fixedStopSec"] = max(
            0.0,
            number_with_default(c.get("stopManeuverLossSec"), 14) + number_with_default(c.get("doorTimeSec"), 4),
        )
    c.pop("stopManeuverLossSec", None)
    c.pop("doorTimeSec", None)
    c["boardingSetupSec"] = max(0.0, number_with_default(c.get("boardingSetupSec"), 2))
    c["alightingSetupSec"] = max(0.0, number_with_default(c.get("alightingSetupSec"), 1))
    c["crowdedExtraSec"] = max(0.0, number_with_default(c.get("crowdedExtraSec"), 5))
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
    c["distanceThresholdStops"] = max(0.0, number_with_default(c.get("distanceThresholdStops"), 1.8))
    c["delayThresholdMin"] = max(0.0, number_with_default(c.get("delayThresholdMin"), 0))
    c["followerLoadLimit"] = max(0.0, number_with_default(c.get("followerLoadLimit"), 0.9))
    c["springGainSecPerStop"] = max(0.0, number_with_default(c.get("springGainSecPerStop"), 18))
    c["springDeadbandStops"] = max(0.0, number_with_default(c.get("springDeadbandStops"), 0.6))
    c["springDamping"] = max(0.0, number_with_default(c.get("springDamping"), 0.06))
    c["springMaxHoldSec"] = max(0.0, number_with_default(c.get("springMaxHoldSec"), 45))
    c["springMinHoldSec"] = max(0.0, number_with_default(c.get("springMinHoldSec"), 8))
    c["springVoluntaryDeferralEnabled"] = bool_with_default(raw.get("springVoluntaryDeferralEnabled"), False)
    c["springControlSkipEnabled"] = bool_with_default(raw.get("springControlSkipEnabled"), True)
    c["springHoldingEnabled"] = bool_with_default(raw.get("springHoldingEnabled"), True)
    c["forbidHoldingWhenFull"] = bool_with_default(raw.get("forbidHoldingWhenFull"), True)
    c["hotspotMultiplier"] = max(0.0, number_with_default(c.get("hotspotMultiplier"), 1))
    hotspot_stops = c.get("hotspotStops") or []
    c["hotspotStops"] = [int(n) for n in hotspot_stops if isinstance(n, (int, float)) and 0 <= int(n) < c["stopCount"]]
    c["protectHotspotStops"] = raw.get("protectHotspotStops") is True or raw.get("protectHotspotStops") == "true"
    c["forbiddenStops"] = list(c["hotspotStops"]) if c["protectHotspotStops"] else []
    berth_mode = str(raw.get("stopBerthMode") or c.get("stopBerthMode") or "single").strip().lower()
    c["stopBerthMode"] = berth_mode if berth_mode in {"single", "all", "hotspot"} else "single"
    c["stopBerthCapacity"] = max(1, int(number_with_default(c.get("stopBerthCapacity"), 1)))
    return c


def extract_config(payload: dict[str, Any]) -> dict[str, Any]:
    config = payload.get("config") or payload.get("settings") or payload
    if not isinstance(config, dict):
        raise ValueError("config object not found")
    return config


def load_json(path: str | Path) -> dict[str, Any]:
    # Accept UTF-8 with or without BOM (PowerShell Set-Content often writes BOM).
    with Path(path).open("r", encoding="utf-8-sig") as f:
        return json.load(f)


def load_config(path: str | Path) -> dict[str, Any]:
    return normalize_config(extract_config(load_json(path)))


def seed_sequence(spec: dict[str, Any]) -> list[int]:
    base = max(1, int(spec.get("base", 1)))
    count = max(1, int(spec.get("count", 1)))
    step = int(spec.get("step", 101))
    return [base + i * step for i in range(count)]
