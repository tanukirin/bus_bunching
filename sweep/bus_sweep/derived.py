from __future__ import annotations

import math
from pathlib import Path
from typing import Any

import pandas as pd

from .storage import write_parquet

HIGHER_IS_BETTER = {"completed", "minHeadwayStops", "recentBoardedPassengers"}

KEY_METRICS = [
    "avgTotalMin",
    "avgWaitMin",
    "p95WaitMin",
    "p95TotalMin",
    "headwayRmseStops",
    "maxHeadwayStops",
    "minHeadwayStops",
    "skippedPassengers",
    "skipAvgExtraMin",
    "skipMaxExtraMin",
    "totalSpringHoldMin",
    "maxSpringHoldSec",
    "avgDelayMin",
    "totalBlockedDelayMin",
    "completed",
    "bunchScore",
]

SURFACE_METRICS = [
    "avgTotalMin",
    "avgWaitMin",
    "p95WaitMin",
    "headwayRmseStops",
    "maxHeadwayStops",
    "totalSpringHoldMin",
]

DECISION_WEIGHTS = {
    "avgTotalMin": 0.30,
    "avgWaitMin": 0.25,
    "p95WaitMin": 0.15,
    "headwayRmseStops": 0.20,
    "maxHeadwayStops": 0.10,
}


def metric_direction(metric: str) -> int:
    return 1 if metric in HIGHER_IS_BETTER else -1


def improvement_pct(metric: str, value: Any, base: Any) -> float | None:
    if value is None or base is None or pd.isna(value) or pd.isna(base) or base == 0:
        return None
    if metric_direction(metric) > 0:
        return (value - base) / base * 100
    return (base - value) / base * 100


def scenario_label(row: pd.Series | dict[str, Any]) -> str:
    params = []
    for key, value in row.items():
        if key.startswith("spring") and pd.notna(value):
            params.append(f"{key}={value}")
    return " / ".join(params) if params else str(row.get("scenario_id", "base"))


def parameter_columns(aggregate: pd.DataFrame) -> list[str]:
    return [c for c in aggregate.columns if c not in {"scenario_id", "mode", "metric", "mean", "sd", "n"}]


def build_candidate_table(aggregate: pd.DataFrame) -> pd.DataFrame:
    params = parameter_columns(aggregate)
    wide = aggregate.pivot_table(index=["scenario_id", "mode"], columns="metric", values="mean", aggfunc="mean").reset_index()
    if params:
        scenario_params = aggregate.drop_duplicates("scenario_id")[["scenario_id", *params]]
        wide = wide.merge(scenario_params, on="scenario_id", how="left")

    rows: list[dict[str, Any]] = []
    for scenario_id, group in wide.groupby("scenario_id", sort=False):
        by_mode = {str(row["mode"]): row for _, row in group.iterrows()}
        if "spring" not in by_mode:
            continue
        spring = by_mode["spring"]
        plain = by_mode.get("plain")
        skip = by_mode.get("skip")

        score = 0.0
        for metric, weight in DECISION_WEIGHTS.items():
            base = plain.get(metric) if plain is not None else None
            score += (improvement_pct(metric, spring.get(metric), base) or 0.0) * weight

        warnings: list[str] = []
        strong_warnings: list[str] = []
        if skip is not None and pd.notna(spring.get("avgTotalMin")) and pd.notna(skip.get("avgTotalMin")) and spring.get("avgTotalMin") > skip.get("avgTotalMin"):
            warnings.append("総所要がskipより悪化")
        if plain is not None and pd.notna(spring.get("p95TotalMin")) and pd.notna(plain.get("p95TotalMin")) and spring.get("p95TotalMin") > plain.get("p95TotalMin"):
            strong_warnings.append("95%総所要が制御なしより悪化")
        if pd.notna(spring.get("maxSpringHoldSec")) and spring.get("maxSpringHoldSec") > 120:
            warnings.append("最大保持120秒超")
        if pd.notna(spring.get("totalSpringHoldMin")) and spring.get("totalSpringHoldMin") > 60:
            warnings.append("保持累計60分超")
        if skip is not None and pd.notna(spring.get("skippedPassengers")) and pd.notna(skip.get("skippedPassengers")) and spring.get("skippedPassengers") > skip.get("skippedPassengers") * 0.5:
            warnings.append("スキップ人数がskipの50%超")

        if strong_warnings:
            verdict = "除外候補"
        elif len(warnings) >= 2:
            verdict = "保留"
        elif warnings:
            verdict = "注意"
        else:
            verdict = "推奨"

        row = spring.to_dict()
        row.update(
            {
                "scenario_label": scenario_label(spring),
                "score": score,
                "verdict": verdict,
                "warning_count": len(warnings),
                "strong_warning_count": len(strong_warnings),
                "warning_reasons": " / ".join([*strong_warnings, *warnings]) if strong_warnings or warnings else "なし",
            }
        )
        for metric in KEY_METRICS:
            if plain is not None:
                row[f"{metric}_vs_plain_pct"] = improvement_pct(metric, spring.get(metric), plain.get(metric))
            if skip is not None:
                row[f"{metric}_vs_skip_pct"] = improvement_pct(metric, spring.get(metric), skip.get(metric))
        rows.append(row)

    if not rows:
        return pd.DataFrame()
    candidates = pd.DataFrame(rows).sort_values("score", ascending=False).reset_index(drop=True)
    candidates["rank"] = candidates.index + 1
    candidates["pareto"] = pareto_flags(candidates, ["avgTotalMin", "headwayRmseStops"])
    return candidates


def pareto_flags(df: pd.DataFrame, metrics: list[str]) -> list[bool]:
    flags: list[bool] = []
    values = df[metrics].to_dict("records")
    for i, row in enumerate(values):
        dominated = False
        for j, other in enumerate(values):
            if i == j:
                continue
            no_worse = all(other[m] <= row[m] for m in metrics if pd.notna(other[m]) and pd.notna(row[m]))
            better = any(other[m] < row[m] for m in metrics if pd.notna(other[m]) and pd.notna(row[m]))
            if no_worse and better:
                dominated = True
                break
        flags.append(not dominated)
    return flags


def build_metric_surfaces(aggregate: pd.DataFrame, candidates: pd.DataFrame | None = None) -> pd.DataFrame:
    params = parameter_columns(aggregate)
    rows = aggregate[aggregate["metric"].isin(SURFACE_METRICS)].copy()
    rows["direction"] = rows["metric"].map(metric_direction)
    rows["display_value"] = rows["mean"] * rows["direction"]
    rows["is_best"] = False
    if candidates is not None and not candidates.empty:
        best_ids = set(candidates.head(10)["scenario_id"].astype(str))
        rows["top10_candidate"] = rows["scenario_id"].astype(str).isin(best_ids)
    else:
        rows["top10_candidate"] = False
    for (metric, mode), idx in rows.groupby(["metric", "mode"]).groups.items():
        group = rows.loc[idx]
        if metric_direction(metric) > 0:
            best_idx = group["mean"].idxmax()
        else:
            best_idx = group["mean"].idxmin()
        rows.loc[best_idx, "is_best"] = True
    return rows[["scenario_id", "mode", "metric", "mean", "display_value", "direction", "is_best", "top10_candidate", *params]]


def build_mode_deltas(aggregate: pd.DataFrame) -> pd.DataFrame:
    wide = aggregate[aggregate["metric"].isin(KEY_METRICS)].pivot_table(
        index=["scenario_id", "metric"],
        columns="mode",
        values="mean",
        aggfunc="mean",
    ).reset_index()
    rows: list[dict[str, Any]] = []
    for _, row in wide.iterrows():
        metric = row["metric"]
        for base, target in [("plain", "skip"), ("plain", "spring"), ("skip", "spring")]:
            if base in wide.columns and target in wide.columns:
                rows.append(
                    {
                        "scenario_id": row["scenario_id"],
                        "metric": metric,
                        "base_mode": base,
                        "target_mode": target,
                        "base_value": row.get(base),
                        "target_value": row.get(target),
                        "improvement_pct": improvement_pct(metric, row.get(target), row.get(base)),
                    }
                )
    return pd.DataFrame(rows)


def build_visual_derivatives(aggregate: pd.DataFrame) -> dict[str, pd.DataFrame]:
    candidates = build_candidate_table(aggregate)
    return {
        "candidates": candidates,
        "metric_surfaces": build_metric_surfaces(aggregate, candidates),
        "mode_deltas": build_mode_deltas(aggregate),
    }


def write_visual_derivatives(run_dir: str | Path) -> dict[str, int]:
    run = Path(run_dir)
    aggregate = pd.read_parquet(run / "aggregate.parquet")
    derivatives = build_visual_derivatives(aggregate)
    counts: dict[str, int] = {}
    for name, frame in derivatives.items():
        write_parquet(run / f"{name}.parquet", frame.to_dict("records"))
        counts[name] = len(frame)
    return counts
