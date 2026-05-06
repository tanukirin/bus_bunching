from __future__ import annotations

import math
from pathlib import Path
from typing import Any

import pandas as pd

from .storage import write_parquet

HIGHER_IS_BETTER = {"completed", "minHeadwayStops", "recentBoardedPassengers"}

METRIC_PRIORITY = {
    "adjustedAvgTotalMin": 4,
    "adjustedTop5TotalMin": 4,
    "avgWaitMin": 4,
    "top5WaitMin": 4,
    "headwayRmseStops": 3,
    "maxHeadwayStops": 3,
    "minHeadwayStops": 3,
    "completed": 3,
    "waitingNow": 3,
    "deniedPassengers": 3,
    "deniedAvgExtraMin": 3,
    "deniedMaxExtraMin": 3,
    "controlSkippedPassengers": 3,
    "controlSkipAvgExtraMin": 3,
    "controlSkipMaxExtraMin": 3,
    "totalSpringHoldMin": 3,
    "totalBlockedDelayMin": 3,
    "avgDelayMin": 3,
    "maxDelayMin": 3,
    "multiControlSkippedPassengers": 2,
    "fullDeniedAfterControlSkipPassengers": 2,
    "voluntaryDeferredPassengers": 2,
    "voluntaryDeferralEvents": 2,
    "totalVoluntaryDeferralPassengerEvents": 2,
    "voluntaryDeferralAvgExtraMin": 2,
    "voluntaryDeferralMaxExtraMin": 2,
    "avgTotalMin": 2,
    "top5TotalMin": 2,
    "medianWaitMin": 2,
    "maxWaitMin": 2,
    "over10Min": 2,
    "headwayStdStops": 2,
    "headwayCv": 2,
    "avgStopOccupancyRate": 2,
    "totalControlSkipPassengerEvents": 2,
    "maxSpringHoldSec": 2,
    "recentAvgWaitMin": 2,
    "recentTop5WaitMin": 2,
    "bunchScore": 1,
    "bunchStarts": 1,
    "bunchDurationMin": 1,
    "allPassengers": 1,
    "onboardNow": 1,
    "recentBoardedPassengers": 1,
    "idealHeadwayStops": 1,
    "timeMin": 1,
    "headwayErrorSum": 1,
    "springPositiveSignalAvg": 1,
    "springNegativeSignalAvg": 1,
    "springSignalAbsAvg": 1,
    "avgBlockedDelayPerBusMin": 1,
    "maxBlockedDelayMin": 1,
}

KEY_METRICS = [
    "adjustedAvgTotalMin",
    "adjustedTop5TotalMin",
    "avgWaitMin",
    "top5WaitMin",
    "headwayRmseStops",
    "maxHeadwayStops",
    "minHeadwayStops",
    "completed",
    "waitingNow",
    "deniedPassengers",
    "deniedAvgExtraMin",
    "deniedMaxExtraMin",
    "controlSkippedPassengers",
    "controlSkipAvgExtraMin",
    "controlSkipMaxExtraMin",
    "totalSpringHoldMin",
    "totalBlockedDelayMin",
    "avgDelayMin",
    "maxDelayMin",
    "multiControlSkippedPassengers",
    "fullDeniedAfterControlSkipPassengers",
    "voluntaryDeferredPassengers",
    "voluntaryDeferralEvents",
    "totalVoluntaryDeferralPassengerEvents",
    "voluntaryDeferralAvgExtraMin",
    "voluntaryDeferralMaxExtraMin",
    "avgTotalMin",
    "top5TotalMin",
    "medianWaitMin",
    "maxWaitMin",
    "over10Min",
    "headwayStdStops",
    "headwayCv",
    "avgStopOccupancyRate",
    "totalControlSkipPassengerEvents",
    "maxSpringHoldSec",
    "recentAvgWaitMin",
    "recentTop5WaitMin",
]

SURFACE_METRICS = [metric for metric, priority in METRIC_PRIORITY.items() if priority >= 3]

DECISION_WEIGHTS = {
    "adjustedAvgTotalMin": 0.30,
    "adjustedTop5TotalMin": 0.20,
    "avgWaitMin": 0.30,
    "top5WaitMin": 0.20,
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
        if (
            skip is not None
            and pd.notna(spring.get("adjustedAvgTotalMin"))
            and pd.notna(skip.get("adjustedAvgTotalMin"))
            and spring.get("adjustedAvgTotalMin") > skip.get("adjustedAvgTotalMin")
        ):
            warnings.append("補正平均総所要がskipより悪化")
        if (
            plain is not None
            and pd.notna(spring.get("adjustedTop5TotalMin"))
            and pd.notna(plain.get("adjustedTop5TotalMin"))
            and spring.get("adjustedTop5TotalMin") > plain.get("adjustedTop5TotalMin")
        ):
            strong_warnings.append("補正上位5%総所要が制御なしより悪化")
        if pd.notna(spring.get("maxSpringHoldSec")) and spring.get("maxSpringHoldSec") > 120:
            warnings.append("最大保持120秒超")
        if pd.notna(spring.get("totalSpringHoldMin")) and spring.get("totalSpringHoldMin") > 60:
            warnings.append("保持累計60分超")
        if skip is not None and pd.notna(spring.get("controlSkippedPassengers")) and pd.notna(skip.get("controlSkippedPassengers")) and spring.get("controlSkippedPassengers") > skip.get("controlSkippedPassengers") * 0.5:
            warnings.append("スキップ人数がskipの50%超")

        if skip is not None and pd.notna(spring.get("deniedPassengers")) and pd.notna(skip.get("deniedPassengers")) and spring.get("deniedPassengers") > skip.get("deniedPassengers"):
            warnings.append("乗車不可影響人数がskipより多い")

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
    pareto_metrics = [metric for metric in DECISION_WEIGHTS if metric in candidates.columns]
    candidates["pareto"] = pareto_flags(candidates, pareto_metrics) if pareto_metrics else True
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
    rows = aggregate.copy()
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
