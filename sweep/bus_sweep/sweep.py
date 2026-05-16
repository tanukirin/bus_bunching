from __future__ import annotations

import hashlib
import itertools
import json
import math
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True, slots=True)
class Scenario:
    scenario_id: str
    params: dict[str, Any]


def expand_sweep(items: list[dict[str, Any]] | None) -> list[Scenario]:
    if not items:
        return [Scenario("base", {})]
    values: list[list[dict[str, Any]]] = []
    for item in items:
        values.append(expand_sweep_axis(item))
    scenarios: list[Scenario] = []
    for combo in itertools.product(*values):
        params: dict[str, Any] = {}
        for axis_params in combo:
            duplicates = sorted(set(params) & set(axis_params))
            if duplicates:
                raise ValueError(f"duplicate sweep param(s): {', '.join(duplicates)}")
            params.update(axis_params)
        scenarios.append(Scenario(scenario_id(params), params))
    return scenarios


def expand_sweep_axis(item: dict[str, Any]) -> list[dict[str, Any]]:
    if not isinstance(item, dict):
        raise ValueError(f"invalid sweep item: {item!r}")
    if "group" in item:
        if "param" in item:
            raise ValueError(f"sweep item cannot use both param and group: {item!r}")
        return expand_group_axis(item)

    name = item.get("param")
    if not isinstance(name, str) or not name:
        raise ValueError(f"invalid sweep param: {item!r}")
    if {"min", "max", "points"} <= set(item):
        vals = point_values(float(item["min"]), float(item["max"]), int(item["points"]), item.get("scale", "linear"))
    elif "values" in item:
        vals = list(item["values"])
    elif {"start", "stop", "step"} <= set(item):
        vals = range_values(float(item["start"]), float(item["stop"]), float(item["step"]))
    else:
        raise ValueError(f"sweep item needs min/max/points, values, or start/stop/step: {item!r}")
    if not vals:
        raise ValueError(f"sweep param has no values: {name}")
    return [{name: value} for value in vals]


def expand_group_axis(item: dict[str, Any]) -> list[dict[str, Any]]:
    group = item.get("group")
    if not isinstance(group, str) or not group:
        raise ValueError(f"invalid sweep group: {item!r}")
    raw_values = item.get("values")
    if not isinstance(raw_values, list) or not raw_values:
        raise ValueError(f"sweep group has no values: {group}")

    axis_values: list[dict[str, Any]] = []
    expected_keys: set[str] | None = None
    for raw_value in raw_values:
        if not isinstance(raw_value, dict) or not raw_value:
            raise ValueError(f"sweep group value must be a non-empty object: {group}")
        keys = set(raw_value)
        invalid_keys = [key for key in keys if not isinstance(key, str) or not key]
        if invalid_keys:
            raise ValueError(f"sweep group has invalid param name(s): {group}")
        if expected_keys is None:
            expected_keys = keys
        elif keys != expected_keys:
            raise ValueError(f"sweep group values must use the same params: {group}")
        axis_values.append(dict(raw_value))
    return axis_values


def range_values(start: float, stop: float, step: float) -> list[float]:
    if step == 0:
        raise ValueError("range step must not be zero")
    values: list[float] = []
    current = start
    if step > 0:
        while current <= stop + 1e-12:
            values.append(round(current, 12))
            current += step
    else:
        while current >= stop - 1e-12:
            values.append(round(current, 12))
            current += step
    return values


def point_values(minimum: float, maximum: float, points: int, scale: str = "linear") -> list[float]:
    if points < 1:
        raise ValueError("points must be at least 1")
    if points == 1:
        return [round(minimum, 12)]
    if scale == "linear":
        step = (maximum - minimum) / (points - 1)
        return [round(minimum + step * i, 12) for i in range(points)]
    if scale == "log":
        if minimum <= 0 or maximum <= 0:
            raise ValueError("log scale needs positive min and max")
        lo = math.log(minimum)
        hi = math.log(maximum)
        step = (hi - lo) / (points - 1)
        return [round(math.exp(lo + step * i), 12) for i in range(points)]
    raise ValueError(f"unsupported scale: {scale}")


def scenario_id(params: dict[str, Any]) -> str:
    if not params:
        return "base"
    raw = json.dumps(params, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    prefix = "__".join(f"{safe_key(k)}={safe_value(v)}" for k, v in params.items())
    digest = hashlib.sha1(raw.encode("utf-8")).hexdigest()[:8]
    suffix = f"__{digest}"
    max_length = 120
    if len(prefix) + len(suffix) <= max_length:
        return f"{prefix}{suffix}"
    return f"{prefix[: max_length - len(suffix)]}{suffix}"


def safe_key(value: str) -> str:
    return "".join(ch if ch.isalnum() else "_" for ch in value)


def safe_value(value: Any) -> str:
    text = str(value).replace(".", "p").replace("-", "m")
    return "".join(ch if ch.isalnum() else "_" for ch in text)
