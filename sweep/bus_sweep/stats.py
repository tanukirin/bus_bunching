from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any


SEED_AVERAGE_SD_KEYS = {
    "avgWaitMin",
    "top5WaitMin",
    "maxWaitMin",
    "recentAvgWaitMin",
    "recentTop5WaitMin",
    "recentBoardedPassengers",
    "avgTotalMin",
    "top5TotalMin",
    "adjustedAvgTotalMin",
    "adjustedTop5TotalMin",
    "bunchScore",
    "bunchDurationMin",
    "headwayErrorSum",
    "headwayRmseStops",
    "minHeadwayStops",
    "maxHeadwayStops",
    "avgDelayMin",
    "maxDelayMin",
    "totalBlockedDelayMin",
    "blockEvents",
    "maxBlockedDelayMin",
    "deniedPassengers",
    "deniedAvgExtraMin",
    "deniedMaxExtraMin",
    "controlSkippedPassengers",
    "controlSkipAvgExtraMin",
    "controlSkipMaxExtraMin",
    "multiControlSkippedPassengers",
    "fullDeniedAfterControlSkipPassengers",
    "fullPassEvents",
    "fullDeniedPassengers",
    "springHoldEvents",
    "totalSpringHoldMin",
    "avgSpringHoldSec",
    "maxSpringHoldSec",
    "springControlSkipAssistEvents",
    "springInterventionCount",
    "springPositiveSignalAvg",
    "springNegativeSignalAvg",
    "springSignalAbsAvg",
}


@dataclass(slots=True)
class Stat:
    n: int = 0
    total: float = 0.0
    sq: float = 0.0

    def add(self, value: Any) -> None:
        if isinstance(value, bool):
            return
        if not isinstance(value, (int, float)) or not math.isfinite(value):
            return
        self.n += 1
        self.total += float(value)
        self.sq += float(value) * float(value)

    @property
    def mean(self) -> float:
        return self.total / self.n if self.n else math.nan

    @property
    def sd(self) -> float:
        if not self.n:
            return math.nan
        m = self.mean
        return math.sqrt(max(0.0, self.sq / self.n - m * m))


class AggregateStats:
    def __init__(self) -> None:
        self.metrics: dict[tuple[str, str], dict[str, Stat]] = {}
        self.history: dict[tuple[str, str, float], dict[str, Stat]] = {}

    def add_metric_row(self, scenario_id: str, mode: str, metrics: dict[str, Any]) -> None:
        bucket = self.metrics.setdefault((scenario_id, mode), {})
        for key, value in metrics.items():
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                bucket.setdefault(key, Stat()).add(value)

    def add_history_rows(self, scenario_id: str, mode: str, rows: list[dict[str, Any]]) -> None:
        for row in rows:
            t = row.get("t")
            if not isinstance(t, (int, float)) or not math.isfinite(t):
                continue
            bucket = self.history.setdefault((scenario_id, mode, float(t)), {})
            for key, value in row.items():
                if key == "onboardByBus":
                    continue
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    bucket.setdefault(key, Stat()).add(value)

    def aggregate_rows(self, scenario_params: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for (scenario_id, mode), stats in sorted(self.metrics.items()):
            params = scenario_params.get(scenario_id, {})
            for metric, stat in sorted(stats.items()):
                rows.append(
                    {
                        "scenario_id": scenario_id,
                        "mode": mode,
                        "metric": metric,
                        "mean": stat.mean,
                        "sd": stat.sd,
                        "n": stat.n,
                        **params,
                    }
                )
        return rows

    def history_rows(self, scenario_params: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for (scenario_id, mode, t), stats in sorted(self.history.items()):
            row = {"scenario_id": scenario_id, "mode": mode, "t": t, **scenario_params.get(scenario_id, {})}
            for metric, stat in sorted(stats.items()):
                row[metric] = stat.mean
            rows.append(row)
        return rows
