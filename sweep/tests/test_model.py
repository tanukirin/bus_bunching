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
from bus_sweep.model import EventGenerator, run_three_modes  # noqa: E402
from bus_sweep.stats import AggregateStats  # noqa: E402
from bus_sweep.sweep import expand_sweep, point_values  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()
