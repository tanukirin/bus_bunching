from __future__ import annotations

import concurrent.futures as futures
import ctypes
import math
import os
import platform
import subprocess
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .config import MODE_KEYS, load_json, normalize_config, seed_sequence
from .derived import write_visual_derivatives
from .model import run_three_modes, scalar_metrics
from .stats import AggregateStats
from .storage import ParquetRowWriter, append_jsonl, ensure_dir, write_json, write_parquet
from .sweep import Scenario, expand_sweep

SPRING_ONLY_PARAMS = {
    "springGainSecPerStop",
    "springDeadbandStops",
    "springDamping",
    "springMaxHoldSec",
    "springMinHoldSec",
}

PRIORITY_CHOICES = ("normal", "below-normal", "idle")


def auto_workers(cpu_count: int | None = None) -> int:
    cpus = cpu_count or os.cpu_count() or 1
    if cpus <= 2:
        return 1
    return max(1, min(12, math.floor(cpus * 0.6)))


def apply_process_priority(priority: str) -> str | None:
    if priority not in PRIORITY_CHOICES:
        raise ValueError(f"unsupported priority: {priority}")
    if priority == "normal":
        return None
    try:
        if platform.system() == "Windows":
            priority_classes = {
                "below-normal": 0x00004000,
                "idle": 0x00000040,
            }
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.GetCurrentProcess.restype = ctypes.c_void_p
            kernel32.SetPriorityClass.argtypes = (ctypes.c_void_p, ctypes.c_uint32)
            kernel32.SetPriorityClass.restype = ctypes.c_int
            handle = kernel32.GetCurrentProcess()
            ok = kernel32.SetPriorityClass(handle, priority_classes[priority])
            if not ok:
                return f"SetPriorityClass failed: {ctypes.get_last_error()}"
        else:
            os.nice(5 if priority == "below-normal" else 10)
    except Exception as exc:  # noqa: BLE001 - priority lowering is best effort.
        return str(exc)
    return None


def chunked(values: list[int], size: int) -> list[list[int]]:
    return [values[i : i + size] for i in range(0, len(values), size)]


def git_commit(cwd: str | Path | None = None) -> str | None:
    try:
        return (
            subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cwd, stderr=subprocess.DEVNULL, text=True)
            .strip()
        )
    except Exception:
        return None


def memory_bytes() -> int | None:
    if platform.system() != "Windows":
        return None

    class MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [
            ("dwLength", ctypes.c_ulong),
            ("dwMemoryLoad", ctypes.c_ulong),
            ("ullTotalPhys", ctypes.c_ulonglong),
            ("ullAvailPhys", ctypes.c_ulonglong),
            ("ullTotalPageFile", ctypes.c_ulonglong),
            ("ullAvailPageFile", ctypes.c_ulonglong),
            ("ullTotalVirtual", ctypes.c_ulonglong),
            ("ullAvailVirtual", ctypes.c_ulonglong),
            ("sullAvailExtendedVirtual", ctypes.c_ulonglong),
        ]

    status = MEMORYSTATUSEX()
    status.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
    if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
        return int(status.ullTotalPhys)
    return None


def machine_profile() -> dict[str, Any]:
    return {
        "platform": platform.platform(),
        "python": platform.python_version(),
        "processor": platform.processor(),
        "cpu_count": os.cpu_count(),
        "memory_bytes": memory_bytes(),
        "note": "Discrete-event simulation uses CPU multiprocessing; GPU is reserved for browser/Plotly rendering.",
    }


def run_chunk(args: tuple[dict[str, Any], Scenario, list[int], list[str], bool, str]) -> dict[str, Any]:
    base_config, scenario, seeds, modes, aggregate_history, engine = args
    result_rows: list[dict[str, Any]] = []
    history_rows: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    for seed in seeds:
        try:
            raw_config = {**base_config, **scenario.params, "seed": seed}
            result = run_three_modes(raw_config, modes=modes, include_history=aggregate_history, engine=engine)
            for mode in modes:
                metrics = scalar_metrics(result[mode]["metrics"])
                result_rows.append(
                    {
                        "scenario_id": scenario.scenario_id,
                        "seed": seed,
                        "mode": mode,
                        **scenario.params,
                        **metrics,
                    }
                )
                if aggregate_history:
                    for row in result[mode]["history"]:
                        history_rows.append(
                            {
                                "scenario_id": scenario.scenario_id,
                                "seed": seed,
                                "mode": mode,
                                **scenario.params,
                                **{k: v for k, v in row.items() if k != "onboardByBus"},
                            }
                        )
        except Exception as exc:  # noqa: BLE001 - worker must report failed seeds.
            errors.append(
                {
                    "scenario_id": scenario.scenario_id,
                    "seed": seed,
                    "error": str(exc),
                    "traceback": traceback.format_exc(),
                }
            )
    return {"rows": result_rows, "history": history_rows, "errors": errors, "seed_count": len(seeds), "scenario_id": scenario.scenario_id}


def can_reuse_plain_skip(scenarios: list[Scenario]) -> bool:
    return all(set(scenario.params).issubset(SPRING_ONLY_PARAMS) for scenario in scenarios)


def run_spring_only_sweep_chunk(args: tuple[dict[str, Any], list[Scenario], list[int], list[str], bool, str]) -> dict[str, Any]:
    base_config, scenarios, seeds, modes, aggregate_history, engine = args
    result_rows: list[dict[str, Any]] = []
    history_rows: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    baseline_modes = [mode for mode in modes if mode in {"plain", "skip"}]
    compute_spring = "spring" in modes
    for seed in seeds:
        try:
            baseline = run_three_modes({**base_config, "seed": seed}, modes=baseline_modes, include_history=aggregate_history, engine=engine) if baseline_modes else {}
            for scenario in scenarios:
                if compute_spring:
                    spring_result = run_three_modes(
                        {**base_config, **scenario.params, "seed": seed},
                        modes=["spring"],
                        include_history=aggregate_history,
                        engine=engine,
                    )
                else:
                    spring_result = {}
                combined = {**baseline, **spring_result}
                for mode in modes:
                    metrics = scalar_metrics(combined[mode]["metrics"])
                    result_rows.append(
                        {
                            "scenario_id": scenario.scenario_id,
                            "seed": seed,
                            "mode": mode,
                            **scenario.params,
                            **metrics,
                        }
                    )
                    if aggregate_history:
                        for row in combined[mode]["history"]:
                            history_rows.append(
                                {
                                    "scenario_id": scenario.scenario_id,
                                    "seed": seed,
                                    "mode": mode,
                                    **scenario.params,
                                    **{k: v for k, v in row.items() if k != "onboardByBus"},
                                }
                            )
        except Exception as exc:  # noqa: BLE001 - worker must report failed seeds.
            errors.append(
                {
                    "scenario_id": "*",
                    "seed": seed,
                    "error": str(exc),
                    "traceback": traceback.format_exc(),
                }
            )
    return {"rows": result_rows, "history": history_rows, "errors": errors, "seed_count": len(seeds) * len(scenarios), "scenario_id": "spring-only-sweep"}


def run_experiment(
    config_path: str | Path,
    out_dir: str | Path,
    workers: str | int = "auto",
    chunk_size: int | None = None,
    engine: str = "fast",
    priority: str = "below-normal",
) -> dict[str, Any]:
    spec = load_json(config_path)
    out = ensure_dir(out_dir)
    progress_path = out / "progress.jsonl"
    if progress_path.exists():
        progress_path.unlink()

    base_config = normalize_config(spec.get("baseConfig") or spec.get("config") or {})
    seeds = seed_sequence(spec.get("seeds") or {"base": base_config.get("seed", 1), "count": 1, "step": 101})
    scenarios = expand_sweep(spec.get("sweep") or [])
    modes = list(spec.get("modes") or MODE_KEYS)
    invalid_modes = [mode for mode in modes if mode not in MODE_KEYS]
    if invalid_modes:
        raise ValueError(f"unsupported mode(s): {', '.join(invalid_modes)}")
    aggregate_history = bool((spec.get("history") or {}).get("aggregate", True))
    progress_interval_sec = max(0.1, float((spec.get("progress") or {}).get("intervalSec", 2.0)))
    worker_count = auto_workers() if workers == "auto" else max(1, int(workers))
    priority_error = apply_process_priority(priority)
    chunk = chunk_size or max(1, min(50, math.ceil(len(seeds) / max(1, worker_count * 4))))
    scenario_params = {s.scenario_id: s.params for s in scenarios}

    spring_only_reuse = can_reuse_plain_skip(scenarios)
    manifest = {
        "type": "bus-bunching-sweep-run",
        "version": 1,
        "name": spec.get("name") or Path(out).name,
        "config_path": str(config_path),
        "started_at": datetime.now(timezone.utc).isoformat(),
        "finished_at": None,
        "git_commit": git_commit(Path(__file__).resolve().parents[2]),
        "machine": machine_profile(),
        "workers": worker_count,
        "chunk_size": chunk,
        "seed_count": len(seeds),
        "scenario_count": len(scenarios),
        "optimization": {
            "plain_skip_reused_across_spring_scenarios": spring_only_reuse,
            "note": "When only spring parameters are swept, plain/skip are invariant and are computed once per seed chunk.",
        },
        "modes": modes,
        "sweep": spec.get("sweep") or [],
        "progress_interval_sec": progress_interval_sec,
        "engine": engine,
        "priority": priority,
        "priority_error": priority_error,
        "write_mode": "streaming",
        "baseConfig": base_config,
    }
    write_json(out / "manifest.json", manifest)

    if spring_only_reuse:
        tasks = [(base_config, scenarios, seed_chunk, modes, aggregate_history, engine) for seed_chunk in chunked(seeds, chunk)]
        worker_fn = run_spring_only_sweep_chunk
    else:
        tasks = [(base_config, scenario, seed_chunk, modes, aggregate_history, engine) for scenario in scenarios for seed_chunk in chunked(seeds, chunk)]
        worker_fn = run_chunk
    total_units = len(scenarios) * len(seeds)
    processed_units = 0
    started = time.perf_counter()
    result_rows_written = 0
    history_rows_written = 0
    aggregate = AggregateStats()
    failures: list[dict[str, Any]] = []
    last_progress_write = 0.0

    append_jsonl(progress_path, {"event": "start", "total_units": total_units, "tasks": len(tasks), "workers": worker_count, "time": time.time()})
    write_json(out / "status.json", {"event": "start", "processed_units": 0, "total_units": total_units, "time": time.time()})
    try:
        with (
            ParquetRowWriter(out / "results.parquet") as results_writer,
            ParquetRowWriter(out / "history.parquet") as history_writer,
            futures.ProcessPoolExecutor(max_workers=worker_count, initializer=apply_process_priority, initargs=(priority,)) as executor,
        ):
            future_map = {executor.submit(worker_fn, task): task for task in tasks}
            for future in futures.as_completed(future_map):
                payload = future.result()
                processed_units += int(payload["seed_count"])
                rows = payload["rows"]
                history = payload["history"]
                results_writer.write_rows(rows)
                history_writer.write_rows(history)
                result_rows_written += len(rows)
                history_rows_written += len(history)
                failures.extend(payload["errors"])
                for row in rows:
                    metrics = {k: v for k, v in row.items() if k not in {"scenario_id", "seed", "mode", *scenario_params.get(row["scenario_id"], {}).keys()}}
                    aggregate.add_metric_row(row["scenario_id"], row["mode"], metrics)
                for row in history:
                    aggregate.add_history_rows(row["scenario_id"], row["mode"], [row])
                elapsed = max(1e-9, time.perf_counter() - started)
                now = time.perf_counter()
                should_write_progress = (
                    now - last_progress_write >= progress_interval_sec
                    or processed_units >= total_units
                    or bool(payload["errors"])
                )
                if should_write_progress:
                    progress_payload = {
                        "event": "progress",
                        "processed_units": processed_units,
                        "total_units": total_units,
                        "throughput_units_per_sec": processed_units / elapsed,
                        "scenario_id": payload["scenario_id"],
                        "errors": len(payload["errors"]),
                        "time": time.time(),
                    }
                    append_jsonl(progress_path, progress_payload)
                    write_json(out / "status.json", progress_payload)
                    last_progress_write = now
    except KeyboardInterrupt:
        append_jsonl(progress_path, {"event": "cancelled", "processed_units": processed_units, "time": time.time()})
        raise

    aggregate_rows = aggregate.aggregate_rows(scenario_params)
    history_rows = aggregate.history_rows(scenario_params)
    write_parquet(out / "aggregate.parquet", aggregate_rows)
    if history_rows:
        write_parquet(out / "history.parquet", history_rows)
    if failures:
        write_json(out / "failures.json", {"failures": failures})
    manifest["finished_at"] = datetime.now(timezone.utc).isoformat()
    manifest["elapsed_sec"] = time.perf_counter() - started
    manifest["processed_units"] = processed_units
    manifest["result_rows"] = result_rows_written
    manifest["history_rows"] = history_rows_written if not history_rows else len(history_rows)
    manifest["failure_count"] = len(failures)
    manifest["throughput_units_per_sec"] = processed_units / max(manifest["elapsed_sec"], 1e-9)
    try:
        manifest["visual_derivatives"] = write_visual_derivatives(out)
    except Exception as exc:  # noqa: BLE001 - derivatives should not invalidate a completed run.
        manifest["visual_derivatives_error"] = str(exc)
    write_json(out / "manifest.json", manifest)
    finish_payload = {"event": "finish", "processed_units": processed_units, "elapsed_sec": manifest["elapsed_sec"], "time": time.time()}
    append_jsonl(progress_path, finish_payload)
    write_json(out / "status.json", finish_payload)
    return manifest
