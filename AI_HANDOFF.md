# Codex Handoff: Bus Bunching Simulator

This file is written for future Codex sessions, not primarily for humans.
Read this before modifying the project.

## Current Repository State

- Workspace: `C:\Users\suzuk\Desktop\apps\bus_bunching`
- Remote: `https://github.com/tanukirin/bus_bunching.git`
- Branch: `main`
- Last pushed commit at time of this handoff:
  - `5a4b669 Improve seed average controls`
- Current working tree has local uncommitted changes in:
  - `index.html`
  - `README.md`
  - `AI_HANDOFF.md`
- The uncommitted `index.html` change raises seed-average experiment capacity from 100 to 100000, changes the default seed-average count to 200, adds streaming aggregation plus cancellation, and adds seed-average JSON/CSV export. It has not been pushed unless a later session did so.
- Ignored local generated files:
  - `bus-bunching-results*.json`
  - `bus-bunching-results*.csv`
  - `bus-bunching-metrics*.csv`
  - `bus-bunching-config*.json`
  - `old/`

Run first:

```powershell
git status -sb
git log -5 --oneline
```

## Project Purpose

Single-file browser app for comparing:

- normal high-frequency bus operation where bus bunching emerges naturally
- proposed control where a delayed leading bus may serve a stop as alighting-only and leave boarding passengers for the following bus

It is educational / exploratory, not a calibrated operations model.

Important current assumptions:

- one-way circular route
- displayed as a mostly straight horizontal route
- no overtaking
- one berth per stop
- if a stop is occupied, following buses wait before the stop
- passenger arrivals and travel delays are seed-driven and reproducible
- control and no-control runs share the same generated passenger demand events

## File Map

- `index.html`
  - whole app: HTML, CSS, simulation, rendering, charts, import/export
  - use as the current template for future subprojects
- `README.md`
  - user-facing description and parameter docs
- `tools/apply-default-config.js`
  - updates default config embedded in `index.html` from an exported config JSON
- `LICENSE`
  - MIT
- `.gitignore`
  - ignores generated result/config files and `old/`

## Important Code Locations In `index.html`

Line numbers drift. Use `rg`.

```powershell
rg -n "const PRESETS|function normalizeConfig|class EventGenerator|class Simulation|class ComparisonApp" index.html
rg -n "runSeedAverage|createSeedAverageAccumulator|runFastDetailed|travelNoise|chooseDestination" index.html
```

Key components:

- Utility / stats helpers near top of script
  - `fmt`, `mean`, `std`, `pct`, `circularForward`, `positiveModulo`, `parseList`
  - `formatSeedList`
  - seed-average aggregators:
    - `createSeedAverageAccumulator`
    - `addMetricStreamingStats`
    - `addHistoryStreamingStats`
    - `meanFromStreamingStats`
    - `sdFromStreamingStats`
- `PARAM_HELP`
  - tooltip text for parameter controls
- `SeededRng`
  - deterministic RNG
- `EventGenerator`
  - `demandEvents(config)`
  - `chooseDestination(config, rng, origin)`
  - `travelNoise(config, fromStop, startTimeSec)`
- `Simulation`
  - simulation state, bus movement, dwell, blocking, metrics
  - `runToEnd()`
  - `computeMetrics()`
  - `sample()`
- `ComparisonApp`
  - DOM app controller
  - settings binding
  - animation loop
  - rendering
  - seed average UI
  - export/import

## Seed Average State

Recent local changes:

- `seedAverageCountInput` max is now `100000`
- `seedAverageCountInput` default is now `200`
- Large seed counts use streaming aggregation instead of storing all results
- `seedAverageCancelBtn` requests cancellation
- `seedAverageExportJsonBtn` exports the latest seed-average result as JSON
- `seedAverageExportCsvBtn` exports the latest seed-average metric means and SDs as CSV
- If cancelled after some seeds, app displays a partial average
- `formatSeedList` truncates huge seed lists in the UI
- `runSeedAverage()` builds seeds as:

```js
baseSeed + 101 * i
```

Important: 100000 seeds can still be CPU-expensive in a browser. The implementation is memory-friendlier, not magically fast.

If adding heavy experiment tools, consider a Web Worker or Node-based batch runner rather than running everything on the UI thread.

## Simulation Model Notes

Passenger generation:

- `EventGenerator.demandEvents(config)`
- base demand rate:

```js
0.23 * config.demandMultiplier
```

- demand is modified by time wave, stop position bias, and hotspot multiplier
- passenger destination is chosen by `chooseDestination`; hotspot stops are also more likely destinations

Travel delay:

- `EventGenerator.travelNoise(config, fromStop, startTimeSec)`
- shared by stop segment and time bucket, not bus-specific free noise
- bucket size uses `config.noiseBucketSec`
- `randomDelayMeanSec` is converted internally to delay scale using `NOISE_MEAN_FACTOR`

Bus movement:

- circular route position
- no overtaking outside stops
- one berth at each stop
- blocked bus records front-vehicle waiting delay separately from dwell/travel delay

Dwell time:

- includes maneuver loss, door time, alighting setup, boarding setup, per-passenger boarding/alighting time, crowded extra
- boarding and alighting are sequential, not simultaneous
- if no alighting and no waiting passengers, stop service is skipped / zero dwell depending on current logic

Control:

- alighting-only stop handling can be triggered if leading bus is delayed and follower is close enough
- policy modes: distance, time, hybrid
- important/hotspot stop protection is controlled by `protectHotspotStops`
- removed mechanisms: cooldown, per-trip max skips, max consecutive skips

## Metrics And Rendering

Metrics are produced by `Simulation.computeMetrics()`.

Major metric groups:

- passenger waits: average, median, p95, max, recent window
- ride/total travel time
- headway and bunching score
- delay
- load imbalance
- dwell time
- skip harms
- blocked/front-vehicle waiting delay
- stop occupancy and stop-level blocked delay

Charts are canvas-based and are rendered by:

- `renderCharts(data)`
- `drawLineChart`
- `drawBarChart`
- `clearCharts`

Normal animation and seed-average results use the same `renderResultData(data)` pathway.

## Current UI Concepts

Top tabs:

- `animationTab`
- `seedAverageTab`

Seed average view:

- can be opened before running
- has its own controls:
  - `seedAverageBaseSeedInput`
  - `seedAverageCountInput`
  - `seedAverageRunBtn`
  - `seedAverageCancelBtn`
  - `seedAverageRandomBtn`
  - `seedAverageSyncBtn`
- no bus-position animation in seed-average mode
- shows summary/charts/comments/details after run

Side lightweight panel:

- `multiSeedBtn` currently just opens the seed-average tab
- `sweepBtn` still runs a small distance-threshold sweep and writes into `experimentOutput`

## Known Technical Debt

- `index.html` is large. Future subprojects should probably split code into modules, but do not do a large refactor inside the current app unless requested.
- Some older helper functions still exist:
  - `averageMetrics`
  - `sdMetrics`
  - `averageHistories`
  They are still useful for small-array aggregation, but seed-average large-count path should use `createSeedAverageAccumulator`.
- Browser UI for very large seed counts is still CPU-bound and single-threaded.
- No automated browser test suite exists.
- Shell output may display Japanese text as mojibake depending on PowerShell encoding. Do not assume the actual file is corrupted solely from shell display.

## Validation Commands Used Recently

Syntax check:

```powershell
@'
const fs = require('fs');
const html = fs.readFileSync('index.html', 'utf8');
const code = html.match(/<script>([\s\S]*)<\/script>/)[1];
new Function(code);
console.log('syntax ok');
'@ | node -
```

Diff whitespace check:

```powershell
git diff --check
```

Streaming seed average smoke test:

```powershell
@'
const fs = require('fs');
let html = fs.readFileSync('index.html', 'utf8');
let code = html.match(/<script>([\s\S]*)<\/script>/)[1];
code = code.replace(/window\.addEventListener\([\s\S]*?\n    \}\);/, '');
const test = `
const config = normalizeConfig({...PRESETS.urban, durationMin: 20});
const seeds = Array.from({ length: 50 }, (_, i) => 420550 + 101 * i);
const acc = createSeedAverageAccumulator();
for (const seed of seeds) {
  const events = EventGenerator.demandEvents({...config, seed});
  const plain = new Simulation({...config, seed, controlEnabled: false}, 'plain', events);
  const control = new Simulation({...config, seed, controlEnabled: true}, 'control', events);
  plain.runToEnd();
  control.runToEnd();
  acc.add({
    plain: { metrics: plain.computeMetrics(), history: plain.history },
    control: { metrics: control.computeMetrics(), history: control.history }
  });
}
const out = acc.build(seeds, config);
if (!Number.isFinite(out.plainMetrics.avgWaitMin) || !Number.isFinite(out.controlSd.avgWaitMin) || !out.controlHistory.length) throw new Error('bad streaming aggregate');
console.log('stream aggregate ok', out.seeds.length, fmt(out.plainMetrics.avgWaitMin), fmt(out.controlSd.avgWaitMin), out.controlHistory.length);
`;
new Function(code + test)();
'@ | node -
```

## Subproject Strategy

The user plans to create multiple subprojects in this directory based on current source.

Recommended structure:

```text
bus_bunching/
  index.html                  # current baseline app
  README.md
  tools/
  experiments/
    spring-control/
      index.html
      README.md
    parameter-sweep/
      index.html or app files
      README.md
```

But `experiments/` is not currently created. If creating it, check `.gitignore`; currently `old/` is ignored but `experiments/` is not.

For future subprojects:

- Copy current `index.html` first, then change one model idea per subproject.
- Do not mutate baseline behavior unless the user explicitly asks.
- Preserve deterministic seeding and same-demand no-control/control comparison.
- If adding spring method:
  - add a separate policy path, not by overwriting alighting-only skip logic
  - likely place near control policy inside `Simulation`
  - add parameters and metrics explicitly
- If adding parameter sweep / batch tools:
  - prefer streaming aggregation
  - do not store all histories for huge sweeps unless needed
  - consider Node CLI or Web Worker for large runs
  - export summarized results as CSV/JSON

## Git / Publish Notes

When asked to publish:

1. `git status -sb`
2. inspect diff
3. stage only intended files
4. run syntax check
5. `git commit -m "..."`
6. `git push origin main`

Current environment often requires escalated permission for `git add`, `git commit`, and `git push`.

## User Preferences Learned

- User wants direct implementation, not just suggestions.
- User wants practical UI/UX quality and clear operational interpretation.
- User often asks to push to GitHub after changes.
- User cares about:
  - no overtaking artifacts
  - realistic dwell time assumptions
  - one berth/no passing stop behavior
  - seed reproducibility
  - results validity and why metrics differ
  - fairness metrics for skipped passengers
  - scalable seed-average / batch experiments
