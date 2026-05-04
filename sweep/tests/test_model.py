from __future__ import annotations

import json
import math
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWEEP = ROOT / "sweep"
sys.path.insert(0, str(SWEEP))

from bus_sweep.config import PRESETS, normalize_config, seed_sequence  # noqa: E402
from bus_sweep.model import EventGenerator, Passenger, Simulation, run_three_modes  # noqa: E402
from bus_sweep.runner import auto_workers, backup_existing_run_dir, rename_completed_run_dir, run_experiment  # noqa: E402
from bus_sweep.stats import AggregateStats  # noqa: E402
from bus_sweep.sweep import expand_sweep, point_values, scenario_id  # noqa: E402


def node_reference(seed: int, duration_min: int = 12) -> dict:
    script = f"""
const fs = require('fs');
const html = fs.readFileSync('spring/index.html', 'utf8');
const code = html.match(/<script>([\\s\\S]*)<\\/script>/)[1];
const fakeWindow = {{ addEventListener() {{}}, alert(msg) {{ throw new Error(String(msg)); }} }};
const fakeDocument = {{ getElementById() {{ return null; }}, createElement() {{ return {{}}; }}, body: {{ appendChild() {{}} }}, activeElement: null }};
const load = new Function('window', 'document', code + '\\nreturn {{ PRESETS, normalizeConfig, EventGenerator, Simulation, MODE_KEYS }};');
const {{ PRESETS, normalizeConfig, EventGenerator, Simulation, MODE_KEYS }} = load(fakeWindow, fakeDocument);
const config = normalizeConfig({{ ...PRESETS.urban, seed: {seed}, durationMin: {duration_min} }});
const events = EventGenerator.demandEvents(config);
const out = {{ events: events.slice(0, 8), eventCount: events.length, metrics: {{}} }};
for (const mode of MODE_KEYS) {{
  const controlMode = mode === 'plain' ? 'none' : mode;
  const sim = new Simulation({{ ...config, controlMode }}, mode, events);
  out.metrics[mode] = sim.runToEnd();
}}
console.log(JSON.stringify(out));
"""
    raw = subprocess.check_output(["node", "-e", script], cwd=ROOT, text=True)
    return json.loads(raw)


class ModelPortTests(unittest.TestCase):
    def test_demand_events_match_browser_reference(self) -> None:
        config = normalize_config({**PRESETS["urban"], "seed": 238592, "durationMin": 12})
        py_events = EventGenerator.demand_events(config)
        js = node_reference(238592, 12)
        self.assertEqual(len(py_events), js["eventCount"])
        for py_event, js_event in zip(py_events[:8], js["events"]):
            self.assertEqual(py_event["id"], js_event["id"])
            self.assertEqual(py_event["origin"], js_event["origin"])
            self.assertEqual(py_event["dest"], js_event["dest"])
            self.assertAlmostEqual(py_event["time"], js_event["time"], places=10)

    def test_key_metrics_match_browser_reference(self) -> None:
        config = normalize_config({**PRESETS["urban"], "seed": 238592, "durationMin": 12})
        py = run_three_modes(config)
        js = node_reference(238592, 12)["metrics"]
        keys = ["completed", "avgWaitMin", "avgTotalMin", "bunchScore", "headwayRmseStops", "totalBlockedDelayMin"]
        for mode in ("plain", "skip", "spring"):
            for key in keys:
                self.assertTrue(math.isfinite(py[mode]["metrics"][key]))
                self.assertAlmostEqual(py[mode]["metrics"][key], js[mode][key], places=7, msg=f"{mode}.{key}")

    def test_top5_metric_names_and_adjusted_metrics_are_emitted(self) -> None:
        config = normalize_config({**PRESETS["urban"], "seed": 238592, "durationMin": 8})
        py = run_three_modes(config, include_history=True)
        required = {"top5WaitMin", "top5TotalMin", "recentTop5WaitMin", "adjustedAvgTotalMin", "adjustedTop5TotalMin"}
        legacy_prefix = "p" + "95"
        for mode in ("plain", "skip", "spring"):
            metrics = py[mode]["metrics"]
            self.assertTrue(required <= set(metrics))
            self.assertFalse(any(legacy_prefix in key.lower() for key in metrics))
            for row in py[mode]["history"]:
                self.assertFalse(any(legacy_prefix in key.lower() for key in row))

    def test_adjusted_total_penalizes_incomplete_passengers(self) -> None:
        config = normalize_config({**PRESETS["urban"], "seed": 12345, "durationMin": 3, "demandMultiplier": 2.2, "initialDelaySec": 180})
        metrics = run_three_modes(config, modes=["plain"], include_history=False)["plain"]["metrics"]
        incomplete = metrics["allPassengers"] - metrics["completed"]
        self.assertGreater(incomplete, 0)
        self.assertGreaterEqual(metrics["adjustedAvgTotalMin"], metrics["avgTotalMin"])
        self.assertGreaterEqual(metrics["adjustedTop5TotalMin"], metrics["top5TotalMin"])

    def test_adjusted_total_uses_expected_stop_to_stop_components(self) -> None:
        config = normalize_config({**PRESETS["urban"], "seed": 54321, "durationMin": 6})
        events = EventGenerator.demand_events(config)
        sim = Simulation(config, "plain", events, include_history=False)
        metrics = sim.run_to_end()
        expected = config["baseTravelSec"] + config["randomDelayMeanSec"] + metrics["averageDwellSec"]
        self.assertAlmostEqual(metrics["expectedStopToStopSec"], expected, places=7)
        self.assertGreaterEqual(metrics["serviceStopCount"], 0)

    def test_adjusted_total_matches_actual_when_all_passengers_completed(self) -> None:
        config = normalize_config({**PRESETS["urban"], "seed": 1, "durationMin": 1})
        sim = Simulation(config, "plain", [], include_history=False)
        passenger = Passenger(1, 0, 2, arrivalTime=10.0, boardTime=20.0, alightTime=130.0)
        sim.time = 180.0
        sim.allPassengers[passenger.id] = passenger
        sim.completed.append(passenger)
        metrics = sim.compute_metrics()
        self.assertAlmostEqual(metrics["adjustedAvgTotalMin"], metrics["avgTotalMin"], places=7)
        self.assertAlmostEqual(metrics["adjustedTop5TotalMin"], metrics["top5TotalMin"], places=7)

    def test_legacy_stop_fixed_parts_are_combined(self) -> None:
        config = normalize_config({"stopManeuverLossSec": 10, "doorTimeSec": 3})
        self.assertEqual(config["fixedStopSec"], 13)
        self.assertNotIn("stopManeuverLossSec", config)
        self.assertNotIn("doorTimeSec", config)

    def test_parameter_upper_bounds_are_not_clamped(self) -> None:
        config = normalize_config(
            {
                "stopCount": 60,
                "busCount": 40,
                "randomDelayMeanSec": 999,
                "distanceThresholdStops": 25,
                "delayThresholdMin": 90,
                "followerLoadLimit": 2.5,
                "springGainSecPerStop": 150,
                "springDeadbandStops": 12,
                "springDamping": 2,
                "springMaxHoldSec": 600,
                "springMinHoldSec": 300,
            }
        )
        self.assertEqual(config["stopCount"], 60)
        self.assertEqual(config["busCount"], 40)
        self.assertEqual(config["randomDelayMeanSec"], 999)
        self.assertEqual(config["distanceThresholdStops"], 25)
        self.assertEqual(config["delayThresholdMin"], 90)
        self.assertEqual(config["followerLoadLimit"], 2.5)
        self.assertEqual(config["springGainSecPerStop"], 150)
        self.assertEqual(config["springDeadbandStops"], 12)
        self.assertEqual(config["springDamping"], 2)
        self.assertEqual(config["springMaxHoldSec"], 600)
        self.assertEqual(config["springMinHoldSec"], 300)

    def test_parameter_lower_bounds_prevent_invalid_runtime_values(self) -> None:
        config = normalize_config(
            {
                "stopCount": 1,
                "busCount": 0,
                "durationMin": -5,
                "baseSpeedKmh": 0,
                "stopDistanceKm": -1,
                "capacity": 0,
                "demandMultiplier": -1,
                "boardTimeSec": -1,
                "alightTimeSec": -1,
                "fixedStopSec": -1,
                "boardingSetupSec": -1,
                "alightingSetupSec": -1,
                "crowdedExtraSec": -1,
                "randomDelayMeanSec": -1,
                "distanceThresholdStops": -1,
                "delayThresholdMin": -1,
                "followerLoadLimit": -1,
                "springGainSecPerStop": -1,
                "springDeadbandStops": -1,
                "springDamping": -1,
                "springMaxHoldSec": -1,
                "springMinHoldSec": -1,
                "hotspotMultiplier": -1,
            }
        )
        self.assertEqual(config["stopCount"], 2)
        self.assertEqual(config["busCount"], 1)
        self.assertGreater(config["durationMin"], 0)
        self.assertGreater(config["durationSec"], 0)
        self.assertGreater(config["baseSpeedKmh"], 0)
        self.assertGreater(config["stopDistanceKm"], 0)
        self.assertGreater(config["baseTravelSec"], 0)
        for key in [
            "demandMultiplier",
            "boardTimeSec",
            "alightTimeSec",
            "fixedStopSec",
            "boardingSetupSec",
            "alightingSetupSec",
            "crowdedExtraSec",
            "randomDelayMeanSec",
            "distanceThresholdStops",
            "delayThresholdMin",
            "followerLoadLimit",
            "springGainSecPerStop",
            "springDeadbandStops",
            "springDamping",
            "springMaxHoldSec",
            "springMinHoldSec",
            "hotspotMultiplier",
        ]:
            self.assertEqual(config[key], 0)
        self.assertEqual(config["capacity"], 1)

    def test_recent_nan_is_not_averaged_as_zero(self) -> None:
        stats = AggregateStats()
        stats.add_metric_row("s1", "plain", {"recentAvgWaitMin": math.nan, "avgWaitMin": 1.0})
        stats.add_metric_row("s1", "plain", {"recentAvgWaitMin": 4.0, "avgWaitMin": 3.0})
        rows = stats.aggregate_rows({"s1": {}})
        by_metric = {row["metric"]: row for row in rows}
        self.assertEqual(by_metric["recentAvgWaitMin"]["n"], 1)
        self.assertEqual(by_metric["recentAvgWaitMin"]["mean"], 4.0)
        self.assertEqual(by_metric["avgWaitMin"]["n"], 2)
        self.assertEqual(by_metric["avgWaitMin"]["mean"], 2.0)

    def test_sweep_grid_dimensions(self) -> None:
        scenarios = expand_sweep(
            [
                {"param": "a", "min": 1, "max": 2, "points": 2},
                {"param": "b", "min": 10, "max": 30, "points": 3},
                {"param": "c", "values": [0, 1]},
            ]
        )
        self.assertEqual(len(scenarios), 12)
        self.assertEqual(seed_sequence({"base": 10, "count": 3, "step": 101}), [10, 111, 212])

    def test_sweep_point_values(self) -> None:
        self.assertEqual(point_values(20, 60, 3), [20, 40, 60])
        self.assertEqual(point_values(1.0, 1.4, 2), [1.0, 1.4])
        self.assertEqual(point_values(5, 9, 1), [5])

    def test_auto_workers_leaves_desktop_headroom(self) -> None:
        self.assertEqual(auto_workers(1), 1)
        self.assertEqual(auto_workers(2), 1)
        self.assertEqual(auto_workers(4), 2)
        self.assertEqual(auto_workers(8), 4)
        self.assertEqual(auto_workers(16), 9)
        self.assertEqual(auto_workers(64), 12)

    def test_long_scenario_ids_keep_digest(self) -> None:
        long_key = "spring" + "VeryLongParameterName" * 8
        first = scenario_id({long_key: "x" * 80})
        second = scenario_id({long_key: "y" * 80})
        self.assertLessEqual(len(first), 120)
        self.assertRegex(first, r"__[0-9a-f]{8}$")
        self.assertNotEqual(first, second)

    def test_invalid_modes_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "unsupported mode"):
            run_three_modes(PRESETS["urban"], modes=["plain", "sprng"])

    def test_experiment_rejects_invalid_modes_before_workers(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory(prefix="bus_sweep_bad_modes_") as tmp:
            config_path = Path(tmp) / "bad.json"
            out_dir = Path(tmp) / "out"
            config_path.write_text(
                json.dumps(
                    {
                        "baseConfig": {**PRESETS["urban"], "durationMin": 1},
                        "seeds": {"base": 1, "count": 1},
                        "modes": ["plain", "sprng"],
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "unsupported mode"):
                run_experiment(config_path, out_dir, workers=1)

    def test_existing_run_dir_is_backed_up_with_sweep_name(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory(prefix="bus_sweep_backup_") as tmp:
            root = Path(tmp)
            out_dir = root / "default"
            out_dir.mkdir()
            (out_dir / "manifest.json").write_text(
                json.dumps(
                    {
                        "name": "default experiment",
                        "seed_count": 3,
                        "scenario_count": 4,
                        "sweep": [
                            {"param": "springGainSecPerStop", "min": 20, "max": 60},
                            {"param": "springDeadbandStops", "min": 0.8, "max": 1.6},
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (out_dir / "results.parquet").write_bytes(b"old")
            backup = backup_existing_run_dir(out_dir, {"sweep": []})
            self.assertIsNotNone(backup)
            assert backup is not None
            self.assertFalse(out_dir.exists())
            self.assertTrue((backup / "manifest.json").exists())
            self.assertEqual(backup.parent, root)
            self.assertFalse(backup.name.startswith("default__"))
            self.assertFalse(backup.name.startswith("default-experiment__"))
            self.assertTrue(backup.name.startswith("springGainSecPerStop-springDeadbandStops__"))
            self.assertIn("springGainSecPerStop", backup.name)
            self.assertIn("springDeadbandStops", backup.name)
            self.assertIn("seeds3", backup.name)
            self.assertIn("scenarios4", backup.name)

    def test_existing_run_backup_rejects_unreadable_manifest(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory(prefix="bus_sweep_bad_manifest_") as tmp:
            out_dir = Path(tmp) / "default"
            out_dir.mkdir()
            (out_dir / "manifest.json").write_text("{not json", encoding="utf-8")
            (out_dir / "results.parquet").write_bytes(b"old")
            with self.assertRaisesRegex(ValueError, "manifest is unreadable"):
                backup_existing_run_dir(out_dir, {"sweep": []})

    def test_completed_run_is_renamed_for_dashboard_visibility(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory(prefix="bus_sweep_rename_") as tmp:
            root = Path(tmp)
            run_dir = root / "default"
            run_dir.mkdir()
            (run_dir / "manifest.json").write_text(
                json.dumps(
                    {
                        "name": "default experiment",
                        "finished_at": "2026-05-04T00:00:00+00:00",
                        "seed_count": 2,
                        "scenario_count": 3,
                        "sweep": [{"param": "demandMultiplier"}],
                    }
                ),
                encoding="utf-8",
            )
            renamed = rename_completed_run_dir(run_dir)
            self.assertFalse(run_dir.exists())
            self.assertTrue((renamed / "manifest.json").exists())
            self.assertEqual(renamed.parent, root)
            self.assertTrue(renamed.name.startswith("demandMultiplier__"))
            self.assertIn("demandMultiplier", renamed.name)
            self.assertEqual(rename_completed_run_dir(renamed), renamed)

    def test_unfinished_run_is_not_renamed(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory(prefix="bus_sweep_unfinished_") as tmp:
            run_dir = Path(tmp) / "default"
            run_dir.mkdir()
            (run_dir / "manifest.json").write_text(json.dumps({"name": "unfinished", "finished_at": None}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "not finished"):
                rename_completed_run_dir(run_dir)


if __name__ == "__main__":
    unittest.main()
