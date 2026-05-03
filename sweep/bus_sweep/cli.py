from __future__ import annotations

import argparse
import json
from pathlib import Path

import pyarrow.parquet as pq

from .derived import write_visual_derivatives
from .runner import run_experiment


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bus_sweep", description="Run and inspect bus bunching sweep experiments.")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="run an experiment")
    run.add_argument("--config", required=True, help="experiment JSON path")
    run.add_argument("--out", required=True, help="output run directory")
    run.add_argument("--workers", default="auto", help="'auto' or a positive integer")
    run.add_argument("--chunk-size", type=int, default=None, help="seed chunk size per worker task")
    run.add_argument("--engine", default="fast", choices=["fast", "audit"], help="simulation engine")

    summary = sub.add_parser("summarize", help="print a compact run summary")
    summary.add_argument("--run", required=True, help="run directory")
    summary.add_argument("--top", type=int, default=12, help="number of ranked rows")
    summary.add_argument("--no-derivatives", action="store_true", help="skip visual derivative parquet generation")

    benchmark = sub.add_parser("benchmark", help="run a small throughput benchmark")
    benchmark.add_argument("--config", required=True, help="experiment JSON path")
    benchmark.add_argument("--seeds", type=int, default=50, help="seed count override")
    benchmark.add_argument("--workers", default="1", help="'auto' or a positive integer")
    benchmark.add_argument("--engine", default="fast", choices=["fast", "audit"], help="simulation engine")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "run":
        manifest = run_experiment(args.config, args.out, args.workers, args.chunk_size, engine=args.engine if hasattr(args, "engine") else "fast")
        print(json.dumps({k: manifest[k] for k in ["name", "elapsed_sec", "processed_units", "result_rows", "failure_count"]}, ensure_ascii=False, indent=2))
        return 0
    if args.command == "summarize":
        if not args.no_derivatives:
            counts = write_visual_derivatives(Path(args.run))
            print("Visual derivatives:", json.dumps(counts, ensure_ascii=False))
        print_summary(Path(args.run), args.top)
        return 0
    if args.command == "benchmark":
        return run_benchmark(args)
    return 2


def run_benchmark(args: argparse.Namespace) -> int:
    import tempfile
    import time

    from .config import load_json

    spec = load_json(args.config)
    spec["seeds"] = {**(spec.get("seeds") or {}), "count": args.seeds}
    spec["history"] = {"aggregate": False, "perSeed": False}
    with tempfile.TemporaryDirectory(prefix="bus_sweep_bench_") as tmp:
        config_path = Path(tmp) / "benchmark.json"
        out_dir = Path(tmp) / "run"
        config_path.write_text(json.dumps(spec, ensure_ascii=False, indent=2), encoding="utf-8")
        started = time.perf_counter()
        manifest = run_experiment(config_path, out_dir, workers=args.workers, engine=args.engine)
        elapsed = time.perf_counter() - started
        print(
            json.dumps(
                {
                    "engine": args.engine,
                    "workers": args.workers,
                    "elapsed_sec": elapsed,
                    "processed_units": manifest.get("processed_units"),
                    "throughput_units_per_sec": manifest.get("processed_units", 0) / max(elapsed, 1e-9),
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    return 0


def print_summary(run_dir: Path, top: int) -> None:
    manifest_path = run_dir / "manifest.json"
    aggregate_path = run_dir / "aggregate.parquet"
    if not manifest_path.exists() or not aggregate_path.exists():
        raise SystemExit(f"run outputs not found: {run_dir}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    rows = pq.read_table(aggregate_path).to_pylist()
    metric_rows = [
        r
        for r in rows
        if r["mode"] in {"skip", "spring"} and r["metric"] in {"adjustedAvgTotalMin", "avgWaitMin", "top5WaitMin", "headwayRmseStops"}
    ]
    print(f"Run: {manifest.get('name')}  scenarios={manifest.get('scenario_count')} seeds={manifest.get('seed_count')} workers={manifest.get('workers')}")
    print(f"Elapsed: {manifest.get('elapsed_sec', 0):.2f}s  failures={manifest.get('failure_count')}")
    print()
    for row in sorted(metric_rows, key=lambda r: (r["metric"], r["mode"], r["mean"]))[:top]:
        params = " ".join(f"{k}={v}" for k, v in row.items() if k not in {"scenario_id", "mode", "metric", "mean", "sd", "n"} and v is not None)
        print(f"{row['metric']:20s} {row['mode']:7s} mean={row['mean']:.4f} sd={row['sd']:.4f} n={row['n']} {params}")


if __name__ == "__main__":
    raise SystemExit(main())
