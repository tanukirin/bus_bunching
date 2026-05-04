# Codex Handoff: Bus Bunching Simulator

This file is for future Codex sessions. Read it before modifying the project.

## Repository State

- Workspace: `C:\Users\suzuk\Desktop\apps\bus_bunching`
- Remote: `https://github.com/tanukirin/bus_bunching.git`
- Branch: `main`
- Latest pushed commits at time of this handoff:
  - `6eb5e7a Improve dashboard CSV exports`
  - `b4f24b1 Improve sweep metrics and dashboard`
  - `5466335 Add bus sweep analysis workbench`
- Known local uncommitted/untracked files at handoff time:
  - `AI_HANDOFF.md` modified by this handoff update
  - `sweep/configs/default_experiment.json` modified by user or previous work; inspect before staging
  - `spring/bus-bunching-seed-average-metrics.csv` untracked generated output
  - `spring/bus-bunching-seed-average-results.json` untracked generated output
- Do not stage generated result files unless the user explicitly asks.

Run first in a new session:

```powershell
git status -sb
git log -5 --oneline
```

## Project Structure

- `index.html`
  - Original single-file browser simulator.
  - Keep as the baseline unless explicitly asked to change it.
- `spring/index.html`
  - Browser-based three-way comparison app.
  - Compares `plain`, `skip`, and `spring` under the same seed and same demand events.
- `sweep/`
  - Python package and Streamlit/Plotly analysis workbench for large seed and parameter sweeps.
  - This is the current main analysis tool for large experiments.
- `tools/apply-default-config.js`
  - Updates embedded defaults from exported config JSON.
  - Root target by default; pass a second target for spring:

```powershell
node tools/apply-default-config.js bus-bunching-config.json spring/index.html
```

## Core Simulation Invariants

Preserve these across browser and Python implementations:

- circular one-way route
- no overtaking
- one berth per stop
- blocked buses wait before occupied stops
- deterministic passenger demand and travel delay by seed
- for each seed/scenario, `plain`, `skip`, and `spring` share the same generated demand events

The fairness invariant is important: do not regenerate demand independently per mode.

## Spring Control Model

Direction convention:

```text
進行方向 →

後方バス        自車          前方バス
   A ----------- B ------------ C
        h_back        h_front
```

- `h_back`: distance from rear bus A to current bus B
- `h_front`: distance from current bus B to front bus C
- `idealHeadwayStops = stopCount / busCount`
- `springSignal = h_front - h_back`

Interpretation:

- `springSignal > 0`: front is open and rear is close, so the current bus wants to move forward.
- `springSignal < 0`: front is close and rear is open, so the current bus should avoid moving forward.

Spring behavior:

- Holding is considered when `springSignal < -springDeadbandStops`, `h_front < H`, and `h_back > H`.
- Holding seconds:

```js
clamp(
  (-springSignal - springDeadbandStops) * springGainSecPerStop - springDamping * bus.delaySec,
  0,
  springMaxHoldSec
)
```

- Holds shorter than `springMinHoldSec` are suppressed.
- Auxiliary spring skip is considered only when `springSignal > Math.max(springDeadbandStops, 0.5)`, `h_front > H`, and `h_back < H`.
- Auxiliary skip also must pass normal distance skip safety checks and `springSkipImprovesHeadway()`.
- Do not add speed control unless explicitly requested.

## Python Sweep Workbench

Package: `sweep/bus_sweep/`

- `config.py`: presets, normalization, JSON import/export
- `model.py`: RNG, demand events, `Simulation`, three-mode execution
- `sweep.py`: Cartesian parameter grid expansion, supports `values` and `min`/`max`/`points`
- `runner.py`: ProcessPool-based chunked execution, progress, manifest, output writing
- `stats.py`: streaming aggregation, non-finite values ignored
- `storage.py`: Parquet writing helpers
- `derived.py`: candidate table, metric surfaces, mode deltas for dashboard
- `dashboard.py`: Streamlit + Plotly dashboard
- `cli.py`: CLI entry points

Run from `sweep/`:

```powershell
python -m bus_sweep.cli run --config configs/default_experiment.json --out runs/default --workers auto --engine fast
python -m bus_sweep.cli summarize --run runs/default
streamlit run bus_sweep/dashboard.py -- --runs runs
```

Smoke run:

```powershell
python -m bus_sweep.cli run --config configs/smoke_experiment.json --out runs/smoke-fast --workers 2 --chunk-size 2 --engine fast
python -m bus_sweep.cli summarize --run runs/smoke-fast
```

Engine modes:

- `fast`: event-sized steps for broad exploration; default for CLI.
- `audit`: fixed-step style closer to browser behavior; use for verification.

Worker defaults are designed for a high-end CPU. ProcessPool commands may require elevated permission in this environment because Windows pipe creation can fail under sandboxing.

## Sweep Outputs

Each run directory typically contains:

- `manifest.json`: config, hardware, worker count, start/end times, failures
- `results.parquet`: seed-level scalar metrics
- `aggregate.parquet`: scenario / mode / metric mean, sd, n
- `history.parquet`: scenario / mode average history if enabled
- `candidates.parquet`: candidate rankings and warnings, generated by summarize/derived
- `metric_surfaces.parquet`: surface data for terrain maps
- `mode_deltas.parquet`: plain/skip/spring deltas for visual comparisons
- `progress.jsonl`: throttled progress and failure events

`sweep/runs/` is generated output and should stay out of git.

## Metrics And Naming

Current metric naming uses `top5...`, not `p95...`.

Important user-facing metrics:

- `adjustedAvgTotalMin`: corrected average total journey time
- `adjustedTop5TotalMin`: corrected top 5% total journey time
- `avgTotalMin`: completed-passenger-only average total journey time
- `top5TotalMin`: completed-passenger-only top 5% total journey time
- `avgWaitMin`
- `top5WaitMin`
- `recentAvgWaitMin`
- `recentTop5WaitMin`
- `headwayRmseStops`
- `maxHeadwayStops`
- `skippedPassengers`
- `totalSpringHoldMin`
- `maxSpringHoldSec`

Do not reintroduce `p95...` output keys unless the user explicitly asks for compatibility migration.

### Corrected Total Time

Corrected total time prevents incomplete passengers from being dropped from the evaluation.

Definitions:

- denominator: all generated/arrived passengers in `allPassengers`
- completed passenger: `alightTime - arrivalTime`
- onboard passenger: `currentTime - arrivalTime + remainingStopsToDest * expectedStopToStopSec`
- waiting passenger: `currentTime - arrivalTime + minBusArrivalToOriginSec + queuePenaltySec + tripStops * expectedStopToStopSec`

Components:

- `baseTravelSec = max(20, stopDistanceKm / max(4, baseSpeedKmh) * 3600)`
- `averageDwellSec = totalDwell / max(1, serviceStopCount)`
- `expectedStopToStopSec = baseTravelSec + randomDelayMeanSec + averageDwellSec`
- `idealHeadwaySec = (stopCount / busCount) * expectedStopToStopSec`
- `queuePenaltySec = max(0, waitingAtOrigin - capacity) / capacity * idealHeadwaySec`
- `minBusArrivalToOriginSec`: minimum estimated arrival time to origin across all buses

This is a comparison penalty metric, not an exact forecast.

## Dashboard Notes

Current dashboard tabs:

- `地形図`: parameter surfaces; blue means better, red means worse
- `候補ポートフォリオ`: candidate ranking and tradeoff map
- `方式差分`: plain/skip/spring slope and improvement bars
- `リスク`: holding/skip/risk distributions
- `詳細`: exports, all scenario data, candidate tables, time series
- `指標ガイド`: metric definitions

Dashboard conventions:

- No Streamlit sidebar; controls are at the top or inside tabs.
- Candidate table uses Plotly Table instead of pandas Styler to avoid matplotlib/NumPy binary issues.
- Candidate table shows both plain ratio and skip ratio where relevant.
- Terrain maps are generated for all metrics; primary metrics are shown first and the rest are folded.
- Portfolio tab does not duplicate the heatmap already covered by the terrain tab.

Detail tab exports:

- Human-readable CSV: one row per `scenario × mode`, including `制御なし`, `スキップ制御`, and `スプリング法`; absolute metric values only; internal scenario ID at the end.
- Scenario-wide CSV: one row per scenario, with mode-prefixed metric columns.
- Long aggregate CSV: DB-style `scenario_id / mode / metric / mean / sd / n`.
- Seed-level CSV: per-seed scalar metrics.
- Parquet downloads for raw aggregate/results where useful.

The ugly internal `scenario_id` values such as `springGainSecPerStop=...__...` are implementation IDs. Human-readable exports should show `シナリオ001` plus parameter columns and keep `内部ID` at the end.

## Config Notes

Experiment JSON shape:

- `baseConfig`: browser-compatible base config
- `seeds`: `base`, `count`, `step`
- `sweep`: list of parameter specs
  - `{ "param": "...", "values": [...] }`
  - or `{ "param": "...", "min": ..., "max": ..., "points": ... }`
- `modes`: usually `["plain", "skip", "spring"]`
- `history.aggregate`: save average time series or not
- `progress.intervalSec`: minimum interval for `progress.jsonl` events

At handoff time, `sweep/configs/default_experiment.json` is locally modified. Inspect it before staging or changing it.

## Browser App Notes

Root `index.html` and `spring/index.html` remain large single-file apps. Do not split them unless the user explicitly asks for a larger refactor.

Useful search points:

```powershell
Select-String -Path index.html -Pattern "const PRESETS|function normalizeConfig|class EventGenerator|class Simulation|class ComparisonApp"
Select-String -Path spring/index.html -Pattern "MODE_KEYS|class EventGenerator|class Simulation|headwayContext|springDecision|computeMetrics|runSeedAverage"
```

PowerShell may display Japanese text as mojibake in command output. Do not assume file corruption from terminal output alone; read with `-Encoding UTF8`.

## Validation Commands

Python checks:

```powershell
python -m py_compile sweep\bus_sweep\model.py sweep\bus_sweep\derived.py sweep\bus_sweep\dashboard.py sweep\bus_sweep\stats.py sweep\bus_sweep\cli.py
python -m unittest discover -s sweep\tests
```

Streamlit HTTP smoke check:

```powershell
$p = Start-Process -FilePath python -ArgumentList @('-m','streamlit','run','bus_sweep/dashboard.py','--server.port','8505','--server.headless','true','--','--runs','runs') -WorkingDirectory 'C:\Users\suzuk\Desktop\apps\bus_bunching\sweep' -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 8
try { Invoke-WebRequest -Uri 'http://localhost:8505' -UseBasicParsing -TimeoutSec 10 } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
```

Browser syntax checks:

```powershell
@'
const fs = require('fs');
const html = fs.readFileSync('spring/index.html', 'utf8');
const code = html.match(/<script>([\s\S]*)<\/script>/)[1];
new Function(code);
console.log('syntax ok');
'@ | node -
```

Whitespace check:

```powershell
git diff --check
```

## Git And Publishing

When asked to publish:

1. `git status -sb`
2. inspect the diff and untracked files
3. stage only intended files
4. run relevant checks
5. `git commit -m "..."`
6. `git push origin main`

Current environment often requires escalated permission for `git add` and `git commit` because `.git/index.lock` creation may be denied. `git push origin main` has worked through normal git credentials even when `gh auth status` reported an invalid token.

## User Preferences

- User usually wants implementation, not just a proposal.
- User often asks to push to GitHub after changes.
- User cares about:
  - deterministic same-demand comparison
  - no overtaking artifacts
  - one berth/no-passing stop behavior
  - realistic dwell, holding, skip, and passenger fairness assumptions
  - seed-average correctness and scalability
  - corrected total journey time and clear metric definitions
  - missing-data handling
  - high-quality Japanese UI/UX and readable CSV exports
- Keep explanations concrete and concise.
