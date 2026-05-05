import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'domain/config.dart';
import 'domain/exporters.dart';
import 'domain/runner.dart';
import 'domain/simulation.dart';
import 'features/file_bridge.dart';

void main() {
  runApp(const BusBunchingApp());
}

class BusBunchingApp extends StatelessWidget {
  const BusBunchingApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xff244a66);
    return MaterialApp(
      title: 'バス団子シミュレーター',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff5f2ea),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        ),
      ),
      home: const SimulatorHome(),
    );
  }
}

class SimulatorHome extends StatefulWidget {
  const SimulatorHome({super.key});

  @override
  State<SimulatorHome> createState() => _SimulatorHomeState();
}

class _SimulatorHeader extends StatelessWidget implements PreferredSizeWidget {
  const _SimulatorHeader();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: kToolbarHeight,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      flexibleSpace: Semantics(
        label: 'バス団子シミュレーター',
        image: true,
        child: Image.asset('assets/images/header.png', fit: BoxFit.fill),
      ),
    );
  }
}

class _SimulatorHomeState extends State<SimulatorHome> {
  late SimulationConfig _config = presets['urban']!;
  late ComparisonRunner _runner = ComparisonRunner(_config);
  late ComparisonResult _result = _runner.snapshot();
  final _controllers = <String, TextEditingController>{};
  final _importController = TextEditingController();
  int _tab = 0;
  bool _running = false;
  bool _metricsExpanded = false;
  SummaryMetricDisplayMode _summaryMetricMode =
      SummaryMetricDisplayMode.percent;
  double _speed = 18;
  Timer? _timer;
  Timer? _settingsDebounce;
  String _presetKey = 'urban';
  final _seedRandom = math.Random();
  SeedAverageHandle? _seedHandle;
  SeedAverageProgress? _seedProgress;
  SeedAverageResult? _seedAverage;
  String? _seedStatus;

  @override
  void initState() {
    super.initState();
    _syncControllers();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _settingsDebounce?.cancel();
    _seedHandle?.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _importController.dispose();
    super.dispose();
  }

  void _syncControllers() {
    final values = {
      'seed': _config.seed,
      'durationMin': _config.durationMin,
      'stopCount': _config.stopCount,
      'busCount': _config.busCount,
      'demandMultiplier': _config.demandMultiplier,
      'capacity': _config.capacity,
      'baseSpeedKmh': _config.baseSpeedKmh,
      'stopDistanceKm': _config.stopDistanceKm,
      'boardTimeSec': _config.boardTimeSec,
      'alightTimeSec': _config.alightTimeSec,
      'randomDelayMeanSec': _config.randomDelayMeanSec,
      'distanceThresholdStops': _config.distanceThresholdStops,
      'delayThresholdMin': _config.delayThresholdMin,
      'followerLoadLimit': _config.followerLoadLimit,
      'springGainSecPerStop': _config.springGainSecPerStop,
      'springDeadbandStops': _config.springDeadbandStops,
      'springDamping': _config.springDamping,
      'springMaxHoldSec': _config.springMaxHoldSec,
      'springMinHoldSec': _config.springMinHoldSec,
      'fixedStopSec': _config.fixedStopSec,
      'boardingSetupSec': _config.boardingSetupSec,
      'alightingSetupSec': _config.alightingSetupSec,
      'crowdedExtraSec': _config.crowdedExtraSec,
      'crowdingThreshold': _config.crowdingThreshold,
      'hotspotMultiplier': _config.hotspotMultiplier,
      'initialDelaySec': _config.initialDelaySec,
    };
    for (final entry in values.entries) {
      final text = _formatValue(entry.value);
      _controllers.putIfAbsent(entry.key, () => TextEditingController()).text =
          text;
    }
    _controllers
        .putIfAbsent('hotspotStops', () => TextEditingController())
        .text = _config.hotspotStops.join(
      ',',
    );
  }

  String _formatValue(Object value) {
    if (value is int) return '$value';
    if (value is double && value == value.roundToDouble())
      return value.toStringAsFixed(0);
    if (value is num)
      return value
          .toStringAsFixed(2)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    return '$value';
  }

  double _fieldDouble(String key, double fallback) =>
      double.tryParse(_controllers[key]?.text.trim() ?? '') ?? fallback;

  int _fieldInt(String key, int fallback) =>
      double.tryParse(_controllers[key]?.text.trim() ?? '')?.round() ??
      fallback;

  void _resetRunner([SimulationConfig? config]) {
    _timer?.cancel();
    _running = false;
    _config = config ?? _config;
    _runner = ComparisonRunner(_config);
    _result = _runner.snapshot();
    setState(() {});
  }

  bool _sameConfig(SimulationConfig a, SimulationConfig b) =>
      a.toJson().toString() == b.toJson().toString();

  SimulationConfig _readSettingsConfig() {
    final hotspots = (_controllers['hotspotStops']?.text ?? '')
        .split(',')
        .map((part) => int.tryParse(part.trim()))
        .whereType<int>()
        .toList();
    return normalizeConfig({
      ..._config.toJson(),
      'name': _presetKey == 'custom' ? 'カスタム' : _config.name,
      'seed': _fieldInt('seed', _config.seed),
      'durationMin': _fieldDouble('durationMin', _config.durationMin),
      'stopCount': _fieldInt('stopCount', _config.stopCount),
      'busCount': _fieldInt('busCount', _config.busCount),
      'demandMultiplier': _fieldDouble(
        'demandMultiplier',
        _config.demandMultiplier,
      ),
      'capacity': _fieldInt('capacity', _config.capacity),
      'baseSpeedKmh': _fieldDouble('baseSpeedKmh', _config.baseSpeedKmh),
      'stopDistanceKm': _fieldDouble('stopDistanceKm', _config.stopDistanceKm),
      'boardTimeSec': _fieldDouble('boardTimeSec', _config.boardTimeSec),
      'alightTimeSec': _fieldDouble('alightTimeSec', _config.alightTimeSec),
      'randomDelayMeanSec': _fieldDouble(
        'randomDelayMeanSec',
        _config.randomDelayMeanSec,
      ),
      'distanceThresholdStops': _fieldDouble(
        'distanceThresholdStops',
        _config.distanceThresholdStops,
      ),
      'delayThresholdMin': _fieldDouble(
        'delayThresholdMin',
        _config.delayThresholdMin,
      ),
      'followerLoadLimit': _fieldDouble(
        'followerLoadLimit',
        _config.followerLoadLimit,
      ),
      'springGainSecPerStop': _fieldDouble(
        'springGainSecPerStop',
        _config.springGainSecPerStop,
      ),
      'springDeadbandStops': _fieldDouble(
        'springDeadbandStops',
        _config.springDeadbandStops,
      ),
      'springDamping': _fieldDouble('springDamping', _config.springDamping),
      'springMaxHoldSec': _fieldDouble(
        'springMaxHoldSec',
        _config.springMaxHoldSec,
      ),
      'springMinHoldSec': _fieldDouble(
        'springMinHoldSec',
        _config.springMinHoldSec,
      ),
      'fixedStopSec': _fieldDouble('fixedStopSec', _config.fixedStopSec),
      'boardingSetupSec': _fieldDouble(
        'boardingSetupSec',
        _config.boardingSetupSec,
      ),
      'alightingSetupSec': _fieldDouble(
        'alightingSetupSec',
        _config.alightingSetupSec,
      ),
      'crowdedExtraSec': _fieldDouble(
        'crowdedExtraSec',
        _config.crowdedExtraSec,
      ),
      'crowdingThreshold': _fieldDouble(
        'crowdingThreshold',
        _config.crowdingThreshold,
      ),
      'hotspotMultiplier': _fieldDouble(
        'hotspotMultiplier',
        _config.hotspotMultiplier,
      ),
      'initialDelaySec': _fieldDouble(
        'initialDelaySec',
        _config.initialDelaySec,
      ),
      'hotspotStops': hotspots,
    });
  }

  bool _commitSettingsIfChanged() {
    var next = _readSettingsConfig();
    if (_sameConfig(_config, next)) return false;
    next = next.copyWith(name: 'カスタム');
    _presetKey = 'custom';
    _resetRunner(next);
    return true;
  }

  void _scheduleSettingsApply() {
    _settingsDebounce?.cancel();
    _settingsDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _commitSettingsIfChanged();
    });
  }

  void _randomizeSeed() {
    final nextSeed = 1 + _seedRandom.nextInt(0x7ffffffe);
    _controllers.putIfAbsent('seed', () => TextEditingController()).text =
        '$nextSeed';
    _settingsDebounce?.cancel();
    _commitSettingsIfChanged();
  }

  void _toggleRun() {
    _timer?.cancel();
    if (_running) {
      setState(() => _running = false);
      return;
    }
    _settingsDebounce?.cancel();
    final changed = _commitSettingsIfChanged();
    if (!changed && _runner.isComplete) {
      _runner = ComparisonRunner(_config);
      _result = _runner.snapshot();
    }
    setState(() => _running = true);
    _timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (!mounted) return;
      _runner.step(0.08 * _speed);
      setState(() => _result = _runner.snapshot());
      if (_runner.isComplete) {
        _timer?.cancel();
        setState(() => _running = false);
      }
    });
  }

  void _rewind10Minutes() {
    _timer?.cancel();
    final target = math.max(0.0, _runner.time - 600);
    _runner.seekTo(target);
    setState(() {
      _running = false;
      _result = _runner.snapshot();
    });
  }

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _snack('$label をクリップボードへコピーしました');
  }

  Future<void> _save(
    String label,
    String fileName,
    String mimeType,
    String text,
  ) async {
    final saved = await FileBridge.saveText(
      fileName: fileName,
      mimeType: mimeType,
      content: text,
    );
    _snack(saved ? '$label を保存しました' : '$label の保存をキャンセルしました');
  }

  Future<void> _openJsonFile() async {
    final text = await FileBridge.openText();
    if (text == null) {
      _snack('ファイル読込をキャンセルしました');
      return;
    }
    setState(() => _importController.text = text);
    _snack('JSONを読み込み欄へ取り込みました');
  }

  void _importTextAsConfig() {
    try {
      final config = configFromJsonText(_importController.text);
      _presetKey = 'custom';
      _config = config;
      _syncControllers();
      _resetRunner(config);
      _snack('設定JSONを読み込みました');
    } catch (error) {
      _snack('設定JSONを読み込めません: $error');
    }
  }

  void _importTextAsSeedAverage() {
    try {
      final result = seedAverageFromJsonText(_importController.text);
      setState(() {
        _seedAverage = result;
        _config = result.config;
        _presetKey = 'custom';
        _syncControllers();
      });
      _resetRunner(result.config);
      _snack('シード平均JSONを読み込みました');
    } catch (error) {
      _snack('シード平均JSONを読み込めません: $error');
    }
  }

  Future<void> _runSeedAverage(int baseSeed, int count) async {
    _seedHandle?.cancel();
    setState(() {
      _seedAverage = null;
      _seedProgress = SeedAverageProgress(completed: 0, total: count);
      _seedStatus = '実行中';
    });
    final handle = await SeedAverageRunner.start(
      config: _config,
      baseSeed: baseSeed,
      count: count.clamp(1, 10000),
      includeHistory: true,
      engine: 'fast',
    );
    _seedHandle = handle;
    handle.progress.listen((progress) {
      if (mounted) setState(() => _seedProgress = progress);
    });
    try {
      final result = await handle.done;
      if (!mounted) return;
      setState(() {
        _seedAverage = result;
        _seedProgress = SeedAverageProgress(
          completed: result.seeds.length,
          total: result.seeds.length,
        );
        _seedStatus = '完了';
        _seedHandle = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _seedStatus = '中断または失敗';
        _seedHandle = null;
      });
    }
  }

  void _cancelSeedAverage() {
    _seedHandle?.cancel();
    setState(() {
      _seedHandle = null;
      _seedStatus = '中断';
    });
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      AnalysisPage(
        result: _result,
        runner: _runner,
        metricsExpanded: _metricsExpanded,
        summaryMetricMode: _summaryMetricMode,
        onToggleSummaryMetricMode: () => setState(
          () => _summaryMetricMode =
              _summaryMetricMode == SummaryMetricDisplayMode.percent
              ? SummaryMetricDisplayMode.absolute
              : SummaryMetricDisplayMode.percent,
        ),
      ),
      SettingsPage(
        presetKey: _presetKey,
        controllers: _controllers,
        onPresetChanged: (key) {
          final preset = presets[key];
          if (preset == null) return;
          setState(() {
            _presetKey = key;
            _config = preset;
            _syncControllers();
          });
          _resetRunner(preset);
        },
        onSettingsChanged: _scheduleSettingsApply,
        onRandomSeed: _randomizeSeed,
      ),
      SeedAveragePage(
        config: _config,
        progress: _seedProgress,
        result: _seedAverage,
        status: _seedStatus,
        running: _seedHandle != null,
        summaryMetricMode: _summaryMetricMode,
        onToggleSummaryMetricMode: () => setState(
          () => _summaryMetricMode =
              _summaryMetricMode == SummaryMetricDisplayMode.percent
              ? SummaryMetricDisplayMode.absolute
              : SummaryMetricDisplayMode.percent,
        ),
        onRun: _runSeedAverage,
        onCancel: _cancelSeedAverage,
      ),
      IoPage(
        controller: _importController,
        comparison: _result,
        seedAverage: _seedAverage,
        onCopyConfig: () => _copy('設定JSON', exportConfigJson(_config)),
        onCopyResults: () => _copy('結果JSON', exportComparisonJson(_result)),
        onCopyMetricsCsv: () => _copy('指標CSV', exportMetricsCsv(_result)),
        onCopySeedJson: _seedAverage == null
            ? null
            : () => _copy('シード平均JSON', exportSeedAverageJson(_seedAverage!)),
        onCopySeedCsv: _seedAverage == null
            ? null
            : () => _copy('シード平均CSV', exportSeedAverageCsv(_seedAverage!)),
        onSaveConfig: () => _save(
          '設定JSON',
          'bus-bunching-config.json',
          'application/json',
          exportConfigJson(_config),
        ),
        onSaveResults: () => _save(
          '結果JSON',
          'bus-bunching-results.json',
          'application/json',
          exportComparisonJson(_result),
        ),
        onSaveMetricsCsv: () => _save(
          '指標CSV',
          'bus-bunching-metrics.csv',
          'text/csv',
          exportMetricsCsv(_result),
        ),
        onSaveSeedJson: _seedAverage == null
            ? null
            : () => _save(
                'シード平均JSON',
                'bus-bunching-seed-average-results.json',
                'application/json',
                exportSeedAverageJson(_seedAverage!),
              ),
        onSaveSeedCsv: _seedAverage == null
            ? null
            : () => _save(
                'シード平均CSV',
                'bus-bunching-seed-average-metrics.csv',
                'text/csv',
                exportSeedAverageCsv(_seedAverage!),
              ),
        onOpenJsonFile: _openJsonFile,
        onImportConfig: _importTextAsConfig,
        onImportSeedAverage: _importTextAsSeedAverage,
      ),
    ];
    return Scaffold(
      appBar: const _SimulatorHeader(),
      body: SafeArea(child: pages[_tab]),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_tab == 0)
            _BottomControlPanel(
              child: ControlPanel(
                running: _running,
                speed: _speed,
                time: _runner.time,
                durationSec: _result.config.durationSec,
                onToggleRun: _toggleRun,
                onRewind: _rewind10Minutes,
                onSpeedChanged: (value) => setState(() => _speed = value),
                metricsExpanded: _metricsExpanded,
                onToggleMetricsExpanded: () =>
                    setState(() => _metricsExpanded = !_metricsExpanded),
              ),
            ),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (index) => setState(() => _tab = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.analytics_outlined),
                selectedIcon: Icon(Icons.analytics),
                label: '分析',
              ),
              NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: '設定',
              ),
              NavigationDestination(
                icon: Icon(Icons.functions_outlined),
                selectedIcon: Icon(Icons.functions),
                label: 'シード平均',
              ),
              NavigationDestination(
                icon: Icon(Icons.ios_share_outlined),
                selectedIcon: Icon(Icons.ios_share),
                label: '入出力',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class AnalysisPage extends StatelessWidget {
  const AnalysisPage({
    super.key,
    required this.result,
    required this.runner,
    required this.metricsExpanded,
    required this.summaryMetricMode,
    required this.onToggleSummaryMetricMode,
  });

  final ComparisonResult result;
  final ComparisonRunner runner;
  final bool metricsExpanded;
  final SummaryMetricDisplayMode summaryMetricMode;
  final VoidCallback onToggleSummaryMetricMode;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              for (final mode in modeKeys) ...[
                ScenarioCard(
                  mode: mode,
                  sim: runner.sims[mode]!,
                  result: result.results[mode]!,
                  baselineMetrics: result.plain.metrics,
                  metricsExpanded: metricsExpanded,
                ),
                const SizedBox(height: 6),
              ],
              const RouteStatusLegend(),
              const SizedBox(height: 8),
              const SizedBox(height: 6),
              SummaryGrid(
                result: result,
                displayMode: summaryMetricMode,
                onToggleDisplayMode: onToggleSummaryMetricMode,
              ),
              const SizedBox(height: 12),
              DetailedMetricsCard(result: result),
              const SizedBox(height: 12),
              MetricCharts.fromComparison(result: result),
            ]),
          ),
        ),
      ],
    );
  }
}

class _BottomControlPanel extends StatelessWidget {
  const _BottomControlPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: child,
      ),
    );
  }
}

class ControlPanel extends StatelessWidget {
  const ControlPanel({
    super.key,
    required this.running,
    required this.speed,
    required this.time,
    required this.durationSec,
    required this.onToggleRun,
    required this.onRewind,
    required this.onSpeedChanged,
    required this.metricsExpanded,
    required this.onToggleMetricsExpanded,
  });

  final bool running;
  final double speed;
  final double time;
  final int durationSec;
  final VoidCallback onToggleRun;
  final VoidCallback onRewind;
  final ValueChanged<double> onSpeedChanged;
  final bool metricsExpanded;
  final VoidCallback onToggleMetricsExpanded;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (running)
                  IconButton.filled(
                    onPressed: onToggleRun,
                    tooltip: '一時停止',
                    icon: const Icon(Icons.pause),
                  )
                else
                  FilledButton.icon(
                    onPressed: onToggleRun,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('再生'),
                  ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: onRewind,
                  tooltip: '10分戻す',
                  icon: const Icon(Icons.fast_rewind),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: metricsExpanded ? '全指標を隠す' : '全指標を表示',
                  child: FilledButton.tonalIcon(
                    onPressed: onToggleMetricsExpanded,
                    icon: Icon(
                      metricsExpanded
                          ? Icons.table_rows
                          : Icons.table_rows_outlined,
                      size: 18,
                    ),
                    label: const Text('指標'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${_timeText(time)} / ${_timeText(durationSec.toDouble())}',
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(Icons.speed, size: 18),
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: Slider(
                      value: speed,
                      min: 1,
                      max: 240,
                      divisions: 239,
                      label: '${speed.round()}x',
                      onChanged: onSpeedChanged,
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${speed.round()}x', textAlign: TextAlign.end),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum MetricDirection { lowerBetter, higherBetter, neutral }

enum MetricDeltaTone { improved, worsened, neutral }

enum SummaryMetricDisplayMode { percent, absolute }

const metricImprovedColor = Color(0xff0f7b52);
const metricWorsenedColor = Color(0xffc83f3f);
const metricNeutralColor = Color(0xff68707c);

class MetricDefinition {
  const MetricDefinition(
    this.key,
    this.label,
    this.unit, {
    this.detailLabel,
    this.direction = MetricDirection.lowerBetter,
    this.digits = 1,
  });

  final String key;
  final String label;
  final String unit;
  final String? detailLabel;
  final MetricDirection direction;
  final int digits;

  String get compactLabel => detailLabel ?? label;
}

const _primaryMetricDefinitions = [
  MetricDefinition('avgWaitMin', '平均待ち', '分'),
  MetricDefinition('adjustedAvgTotalMin', '補正総所要', '分'),
  MetricDefinition('headwayRmseStops', '車間RMSE', '停'),
  MetricDefinition('maxHeadwayStops', '最大車間', '停'),
  MetricDefinition('deniedAvgExtraMin', 'スキップ乗客追加待ち', '分'),
  MetricDefinition('totalBlockedDelayMin', '前車待ち遅延', '分'),
];

const _scenarioMetricDefinitions = [
  ..._primaryMetricDefinitions,
  MetricDefinition('totalSpringHoldMin', '保持', '分'),
];

const _detailMetricDefinitions = [
  MetricDefinition('avgWaitMin', '平均待ち時間', '分'),
  MetricDefinition('recentAvgWaitMin', '直近5分平均待ち', '分', detailLabel: '直近平均待ち'),
  MetricDefinition(
    'recentTop5WaitMin',
    '直近5分上位5%待ち',
    '分',
    detailLabel: '直近上位5%待ち',
  ),
  MetricDefinition(
    'recentBoardedPassengers',
    '直近5分乗車人数',
    '人',
    detailLabel: '直近乗車人数',
    direction: MetricDirection.higherBetter,
    digits: 0,
  ),
  MetricDefinition('medianWaitMin', '中央値待ち時間', '分', detailLabel: '中央値待ち'),
  MetricDefinition('top5WaitMin', '上位5%待ち時間', '分', detailLabel: '上位5%待ち'),
  MetricDefinition('maxWaitMin', '最大待ち時間', '分'),
  MetricDefinition('avgTotalMin', '平均総所要時間', '分', detailLabel: '平均総所要'),
  MetricDefinition('top5TotalMin', '上位5%総所要時間', '分', detailLabel: '上位5%所要'),
  MetricDefinition(
    'adjustedAvgTotalMin',
    '補正平均総所要時間',
    '分',
    detailLabel: '補正平均所要',
  ),
  MetricDefinition(
    'adjustedTop5TotalMin',
    '補正上位5%総所要時間',
    '分',
    detailLabel: '補正上位5%所要',
  ),
  MetricDefinition(
    'allPassengers',
    '発生乗客数',
    '人',
    detailLabel: '発生乗客数',
    direction: MetricDirection.neutral,
    digits: 0,
  ),
  MetricDefinition(
    'completed',
    '完了乗客数',
    '人',
    detailLabel: '完了乗客数',
    direction: MetricDirection.higherBetter,
    digits: 0,
  ),
  MetricDefinition('onboardNow', '乗車中人数', '人', digits: 0),
  MetricDefinition('waitingNow', '待機中人数', '人', digits: 0),
  MetricDefinition(
    'expectedStopToStopSec',
    '見込み停留所間',
    '秒',
    detailLabel: '見込み区間',
    direction: MetricDirection.neutral,
  ),
  MetricDefinition('averageDwellSec', '平均停車', '秒', detailLabel: '平均停車'),
  MetricDefinition('bunchScore', '団子度', '', digits: 0),
  MetricDefinition(
    'minHeadwayStops',
    '最小車間',
    '停',
    direction: MetricDirection.higherBetter,
  ),
  MetricDefinition('maxHeadwayStops', '最大車間', '停'),
  MetricDefinition('headwayRmseStops', '車間RMSE', '停'),
  MetricDefinition('headwayCv', '車間CV', ''),
  MetricDefinition(
    'bunchStarts',
    '団子発生回数',
    '回',
    detailLabel: '団子発生回数',
    digits: 0,
  ),
  MetricDefinition('bunchDurationMin', '団子継続時間', '分'),
  MetricDefinition('avgDelayMin', '平均遅延', '分'),
  MetricDefinition('maxDelayMin', '最大遅延', '分'),
  MetricDefinition('totalBlockedDelayMin', '総前車待ち遅延', '分'),
  MetricDefinition(
    'blockEvents',
    '前車待ち発生回数',
    '回',
    detailLabel: '前車待ち回数',
    digits: 0,
  ),
  MetricDefinition('maxBlockedDelayMin', '最大前車待ち', '分'),
  MetricDefinition('loadStd', '混雑偏りSD', ''),
  MetricDefinition('totalDwellMin', '総停車時間', '分'),
  MetricDefinition(
    'deniedPassengers',
    '乗車不可影響人数',
    '人',
    detailLabel: '乗車不可人数',
    digits: 0,
  ),
  MetricDefinition(
    'deniedAvgExtraMin',
    '乗車不可平均追加待ち',
    '分',
    detailLabel: '乗車不可平均待ち',
  ),
  MetricDefinition(
    'deniedMaxExtraMin',
    '乗車不可最大追加待ち',
    '分',
    detailLabel: '乗車不可最大待ち',
  ),
  MetricDefinition(
    'controlSkipEvents',
    '制御スキップ回数',
    '回',
    detailLabel: '制御スキップ回数',
    digits: 0,
  ),
  MetricDefinition(
    'controlSkippedPassengers',
    '制御スキップ人数',
    '人',
    detailLabel: '制御スキップ人数',
    digits: 0,
  ),
  MetricDefinition(
    'controlSkipAvgExtraMin',
    '制御スキップ追加待ち平均',
    '分',
    detailLabel: '制御追加待ち平均',
  ),
  MetricDefinition(
    'controlSkipMaxExtraMin',
    '制御スキップ追加待ち最大',
    '分',
    detailLabel: '制御追加待ち最大',
  ),
  MetricDefinition(
    'multiControlSkippedPassengers',
    '複数回制御スキップ',
    '人',
    detailLabel: '複数回制御',
    digits: 0,
  ),
  MetricDefinition(
    'fullPassEvents',
    '満員通過回数',
    '回',
    detailLabel: '満員通過回数',
    digits: 0,
  ),
  MetricDefinition(
    'fullDeniedPassengers',
    '満員影響人数',
    '人',
    detailLabel: '満員影響人数',
    digits: 0,
  ),
  MetricDefinition(
    'fullDeniedAfterControlSkipPassengers',
    '制御スキップ後満員影響人数',
    '人',
    detailLabel: '制御後満員影響',
    digits: 0,
  ),
  MetricDefinition(
    'springHoldEvents',
    'スプリング保持回数',
    '回',
    detailLabel: '保持回数',
    digits: 0,
  ),
  MetricDefinition('totalSpringHoldMin', 'スプリング保持累積', '分', detailLabel: '保持累積'),
  MetricDefinition('avgSpringHoldSec', 'スプリング保持平均', '秒', detailLabel: '保持平均'),
  MetricDefinition('maxSpringHoldSec', 'スプリング保持最大', '秒', detailLabel: '保持最大'),
  MetricDefinition(
    'springControlSkipAssistEvents',
    '補助スキップ回数',
    '回',
    detailLabel: '補助スキップ回数',
    digits: 0,
  ),
  MetricDefinition(
    'springInterventionCount',
    'スプリング介入回数',
    '回',
    detailLabel: '介入回数',
    digits: 0,
  ),
  MetricDefinition(
    'springPositiveSignalAvg',
    '正の信号平均',
    '',
    detailLabel: '正信号',
    direction: MetricDirection.neutral,
  ),
  MetricDefinition(
    'springNegativeSignalAvg',
    '負の信号平均',
    '',
    detailLabel: '負信号',
    direction: MetricDirection.neutral,
  ),
  MetricDefinition(
    'springSignalAbsAvg',
    '信号絶対値平均',
    '',
    detailLabel: '信号絶対',
    direction: MetricDirection.neutral,
  ),
];

class SummaryGrid extends StatelessWidget {
  const SummaryGrid({
    super.key,
    required this.result,
    this.displayMode = SummaryMetricDisplayMode.percent,
    this.onToggleDisplayMode,
  });

  final ComparisonResult result;
  final SummaryMetricDisplayMode displayMode;
  final VoidCallback? onToggleDisplayMode;

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final definition in _primaryMetricDefinitions)
        _SummaryItem(
          definition.label,
          _summaryMetricDisplay(
            definition,
            result.plain.metrics,
            result.skip.metrics,
            displayMode,
          ),
          _summaryMetricDisplay(
            definition,
            result.plain.metrics,
            result.spring.metrics,
            displayMode,
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '主要指標',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (onToggleDisplayMode != null)
              SegmentedButton<SummaryMetricDisplayMode>(
                segments: const [
                  ButtonSegment(
                    value: SummaryMetricDisplayMode.percent,
                    label: Text('％'),
                  ),
                  ButtonSegment(
                    value: SummaryMetricDisplayMode.absolute,
                    label: Text('値'),
                  ),
                ],
                selected: {displayMode},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onSelectionChanged: (_) => onToggleDisplayMode!(),
              ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 720 ? 3 : 2;
            return GridView.count(
              crossAxisCount: columns,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: columns == 3 ? 2.7 : 1.85,
              children: items.map((item) => _MetricTile(item: item)).toList(),
            );
          },
        ),
      ],
    );
  }
}

class _SummaryItem {
  const _SummaryItem(this.label, this.skip, this.spring);
  final String label;
  final _DeltaDisplay skip;
  final _DeltaDisplay spring;
}

class _DeltaDisplay {
  const _DeltaDisplay(this.text, this.tone);
  final String text;
  final MetricDeltaTone tone;
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.item});
  final _SummaryItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(item.label, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            _DeltaText(prefix: 'S', display: item.skip),
            _DeltaText(prefix: 'Sp', display: item.spring),
          ],
        ),
      ),
    );
  }
}

class _DeltaText extends StatelessWidget {
  const _DeltaText({required this.prefix, required this.display});

  final String prefix;
  final _DeltaDisplay display;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        '$prefix ${display.text}',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: metricDeltaToneColor(display.tone),
        ),
      ),
    );
  }
}

class DetailedMetricsCard extends StatefulWidget {
  const DetailedMetricsCard({super.key, required this.result});

  final ComparisonResult result;

  @override
  State<DetailedMetricsCard> createState() => _DetailedMetricsCardState();
}

class _DetailedMetricsCardState extends State<DetailedMetricsCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final definition in _detailMetricDefinitions)
        _DetailMetricRow(
          definition: definition,
          plain: _metricNumber(widget.result.plain.metrics, definition.key),
          skip: _metricNumber(widget.result.skip.metrics, definition.key),
          spring: _metricNumber(widget.result.spring.metrics, definition.key),
        ),
    ];
    return Card(
      child: Column(
        children: [
          ListTile(
            dense: true,
            title: const Text('詳細指標'),
            trailing: IconButton(
              tooltip: _expanded ? '詳細指標を隠す' : '詳細指標を表示',
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: Table(
                columnWidths: const {
                  0: FlexColumnWidth(1.08),
                  1: FlexColumnWidth(0.9),
                  2: FlexColumnWidth(0.9),
                  3: FlexColumnWidth(1.0),
                },
                border: TableBorder(
                  horizontalInside: BorderSide(
                    color: Colors.black.withValues(alpha: 0.06),
                  ),
                ),
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.04),
                    ),
                    children: const [
                      _TableHeader('指標'),
                      _TableHeader('制御なし'),
                      _TableHeader('スキップ'),
                      _TableHeader('スプリング'),
                    ],
                  ),
                  for (final row in rows)
                    TableRow(
                      children: [
                        _DetailLabel(row.definition),
                        _PlainValue(
                          definition: row.definition,
                          value: row.plain,
                        ),
                        _ToneValue(
                          definition: row.definition,
                          base: row.plain,
                          value: row.skip,
                        ),
                        _ToneValue(
                          definition: row.definition,
                          base: row.plain,
                          value: row.spring,
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailMetricRow {
  const _DetailMetricRow({
    required this.definition,
    required this.plain,
    required this.skip,
    required this.spring,
  });

  final MetricDefinition definition;
  final double? plain;
  final double? skip;
  final double? spring;
}

class _TableHeader extends StatelessWidget {
  const _TableHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: Text(
          label,
          maxLines: 1,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class _DetailLabel extends StatelessWidget {
  const _DetailLabel(this.definition);

  final MetricDefinition definition;

  @override
  Widget build(BuildContext context) {
    final label = definition.compactLabel;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: label.length > 7 ? 9 : 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PlainValue extends StatelessWidget {
  const _PlainValue({required this.definition, required this.value});

  final MetricDefinition definition;
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Text(
          _formatMetricValue(definition, value),
          maxLines: 1,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _ToneValue extends StatelessWidget {
  const _ToneValue({
    required this.definition,
    required this.base,
    required this.value,
  });

  final MetricDefinition definition;
  final double? base;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final tone = metricDeltaTone(definition, base, value);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Text(
          _formatMetricValue(definition, value),
          maxLines: 1,
          style: TextStyle(
            color: metricDeltaToneColor(tone),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

_DeltaDisplay _deltaDisplay(
  MetricDefinition definition,
  Map<String, dynamic> baseMetrics,
  Map<String, dynamic> valueMetrics,
) {
  final base = _metricNumber(baseMetrics, definition.key);
  final value = _metricNumber(valueMetrics, definition.key);
  final absolute = _formatMetricValue(definition, value);
  final rate = metricImprovementPercent(definition, base, value);
  final tone = metricDeltaTone(definition, base, value);
  if (rate == null) return _DeltaDisplay('- / $absolute', tone);
  final sign = rate > 0 ? '+' : '';
  return _DeltaDisplay('$sign${_fmt(rate, 0)}% / $absolute', tone);
}

_DeltaDisplay _summaryMetricDisplay(
  MetricDefinition definition,
  Map<String, dynamic> baseMetrics,
  Map<String, dynamic> valueMetrics,
  SummaryMetricDisplayMode mode,
) {
  final base = _metricNumber(baseMetrics, definition.key);
  final value = _metricNumber(valueMetrics, definition.key);
  final tone = metricDeltaTone(definition, base, value);
  if (mode == SummaryMetricDisplayMode.absolute) {
    return _DeltaDisplay(_formatMetricValue(definition, value), tone);
  }
  final rate = metricImprovementPercent(definition, base, value);
  if (rate == null) return _DeltaDisplay('-', tone);
  final sign = rate > 0 ? '+' : '';
  return _DeltaDisplay('$sign${_fmt(rate, 0)}%', tone);
}

double? _metricNumber(Map<String, dynamic> metrics, String key) {
  final value = metrics[key];
  if (value is num) return value.toDouble();
  return null;
}

String _formatMetricValue(MetricDefinition definition, double? value) {
  if (value == null || !value.isFinite) return '-';
  final number = definition.digits == 0
      ? value.round().toString()
      : _fmt(value, definition.digits);
  return definition.unit.isEmpty ? number : '$number${definition.unit}';
}

double? metricImprovementPercent(
  MetricDefinition definition,
  double? base,
  double? value,
) {
  if (definition.direction == MetricDirection.neutral ||
      base == null ||
      value == null ||
      !base.isFinite ||
      !value.isFinite ||
      base.abs() < 0.000001) {
    return null;
  }
  return switch (definition.direction) {
    MetricDirection.lowerBetter => (base - value) / base.abs() * 100,
    MetricDirection.higherBetter => (value - base) / base.abs() * 100,
    MetricDirection.neutral => null,
  };
}

MetricDeltaTone metricDeltaTone(
  MetricDefinition definition,
  double? base,
  double? value,
) {
  final rate = metricImprovementPercent(definition, base, value);
  if (rate == null) return MetricDeltaTone.neutral;
  if (rate >= 5) return MetricDeltaTone.improved;
  if (rate <= -3) return MetricDeltaTone.worsened;
  return MetricDeltaTone.neutral;
}

Color metricDeltaToneColor(MetricDeltaTone tone) => switch (tone) {
  MetricDeltaTone.improved => metricImprovedColor,
  MetricDeltaTone.worsened => metricWorsenedColor,
  MetricDeltaTone.neutral => metricNeutralColor,
};

class ScenarioCard extends StatelessWidget {
  const ScenarioCard({
    super.key,
    required this.mode,
    required this.sim,
    required this.result,
    required this.baselineMetrics,
    required this.metricsExpanded,
  });

  final String mode;
  final SimulationEngine sim;
  final ModeResult result;
  final Map<String, dynamic> baselineMetrics;
  final bool metricsExpanded;

  @override
  Widget build(BuildContext context) {
    final metrics = result.metrics;
    final color = _modeColor(mode);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    modeLabels[mode]!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '団子度 ${(metrics['bunchScore'] as num).round()}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 84,
              width: double.infinity,
              child: CustomPaint(painter: RoutePainter(sim: sim)),
            ),
            if (metricsExpanded) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final definition in _scenarioMetricDefinitions)
                    _MiniMetric.fromDefinition(
                      definition: definition,
                      baseMetrics: baselineMetrics,
                      metrics: metrics,
                      compare: mode != 'plain',
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric(
    this.label,
    this.value, {
    this.tone = MetricDeltaTone.neutral,
  });

  factory _MiniMetric.fromDefinition({
    required MetricDefinition definition,
    required Map<String, dynamic> baseMetrics,
    required Map<String, dynamic> metrics,
    required bool compare,
  }) {
    if (!compare) {
      return _MiniMetric(
        definition.label,
        _formatMetricValue(definition, _metricNumber(metrics, definition.key)),
      );
    }
    final display = _deltaDisplay(definition, baseMetrics, metrics);
    return _MiniMetric(definition.label, display.text, tone: display.tone);
  }

  final String label;
  final String value;
  final MetricDeltaTone tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: metricDeltaToneColor(tone),
              ),
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

enum BusVisualState {
  normal,
  blocked,
  springHold,
  assistSkip,
  alightOnlySkip,
  crowded,
  delayed,
  followerClose,
}

const _normalBusColor = Color(0xff2c6fbb);
const _blockedBusColor = Color(0xffc83f3f);
const _springBusColor = Color(0xff7357c8);
const _delayedBusColor = Color(0xffb47b13);
const _followerCloseBusColor = Color(0xff16848b);
const _hotspotStopColor = Color(0xfff4b24d);
const _occupiedBerthColor = Color(0xff26313d);

Color busVisualStateColor(BusVisualState state) => switch (state) {
  BusVisualState.normal => _normalBusColor,
  BusVisualState.blocked => _blockedBusColor,
  BusVisualState.springHold => _springBusColor,
  BusVisualState.assistSkip => _springBusColor,
  BusVisualState.alightOnlySkip => _springBusColor,
  BusVisualState.crowded => _blockedBusColor,
  BusVisualState.delayed => _delayedBusColor,
  BusVisualState.followerClose => _followerCloseBusColor,
};

BusVisualState busVisualStateFor(SimulationEngine sim, BusState bus) {
  if (bus.status == 'blocked') return BusVisualState.blocked;
  final holding =
      bus.springHoldStartTime != null &&
      sim.time >= bus.springHoldStartTime! &&
      sim.time <= (bus.springHoldEndTime ?? 0);
  if (holding || bus.lastAction.startsWith('スプリング保持')) {
    return BusVisualState.springHold;
  }
  if (bus.lastAction.startsWith('補助スキップ')) {
    return BusVisualState.assistSkip;
  }
  if (bus.justSkippedStop != null || bus.lastAction.startsWith('降車のみ')) {
    return BusVisualState.alightOnlySkip;
  }
  final loadRatio = bus.onboard.length / math.max(1, sim.config.capacity);
  if (loadRatio > 0.85) return BusVisualState.crowded;
  if (sim.config.delayThresholdMin > 0 &&
      bus.delaySec > sim.config.delayThresholdMin * 60) {
    return BusVisualState.delayed;
  }
  final follower = sim.findFollower(bus);
  if (follower != null &&
      sim.routeDistanceBehind(follower, bus) <=
          sim.config.distanceThresholdStops) {
    return BusVisualState.followerClose;
  }
  return BusVisualState.normal;
}

class RouteStatusLegend extends StatelessWidget {
  const RouteStatusLegend({super.key});

  @override
  Widget build(BuildContext context) {
    const items = [
      _LegendSwatch('通常', _normalBusColor),
      _LegendSwatch('前車待ち・満員', _blockedBusColor),
      _LegendSwatch('保持・補助・降車', _springBusColor),
      _LegendSwatch('遅延', _delayedBusColor),
      _LegendSwatch('後続接近', _followerCloseBusColor),
      _LegendSwatch('需要集中', _hotspotStopColor),
      _LegendSwatch('使用中', _occupiedBerthColor),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final item in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: item.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 3),
              Text(item.label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
      ],
    );
  }
}

class _LegendSwatch {
  const _LegendSwatch(this.label, this.color);
  final String label;
  final Color color;
}

class RoutePainter extends CustomPainter {
  RoutePainter({required this.sim});

  final SimulationEngine sim;

  @override
  void paint(Canvas canvas, Size size) {
    final c = sim.config;
    final pad = math.min(22.0, size.width * 0.06);
    final y = size.height * 0.56;
    final left = pad;
    final right = size.width - pad;
    final linePaint = Paint()
      ..color = const Color(0xffc9c4b9)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(left, y), Offset(right, y), linePaint);
    double xFor(double pos) =>
        left +
        positiveModulo(pos, c.stopCount) /
            math.max(1, c.stopCount - 1) *
            (right - left);
    for (var i = 0; i < c.stopCount; i++) {
      final stop = sim.stops[i];
      final x = xFor(i.toDouble());
      final activeBlock = stop.blockedQueue.isNotEmpty;
      final hotspot = c.hotspotStops.contains(i);
      final fillPaint = Paint()
        ..color = hotspot ? _hotspotStopColor : const Color(0xfff5f2ea);
      final strokePaint = Paint()
        ..color = activeBlock ? _blockedBusColor : const Color(0xff79828f)
        ..strokeWidth = activeBlock ? 2.2 : 1.4
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(Offset(x, y), 5, fillPaint);
      canvas.drawCircle(Offset(x, y), 5, strokePaint);
      if (stop.occupiedByBusId != null) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x - 5, y + 8, 10, 5),
            const Radius.circular(1.5),
          ),
          Paint()..color = _occupiedBerthColor,
        );
      }
      final queue = sim.waiting[i].length;
      if (queue > 0) {
        canvas.drawRect(
          Rect.fromLTWH(x - 3, y + 15, 6, math.min(18, 3 + queue * 1.2)),
          Paint()..color = _hotspotStopColor.withValues(alpha: 0.72),
        );
      }
      if (activeBlock) {
        _paintSmallLabel(canvas, '前', Offset(x, y - 19), _blockedBusColor);
      }
    }
    for (final bus in sim.buses) {
      final x = xFor(bus.pos);
      final visualState = busVisualStateFor(sim, bus);
      final color = busVisualStateColor(visualState);
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, y - 24), width: 28, height: 16),
        const Radius.circular(5),
      );
      canvas.drawRRect(rect, Paint()..color = color);
      final loadRatio = (bus.onboard.length / math.max(1, c.capacity)).clamp(
        0.0,
        1.0,
      );
      final bar = Rect.fromLTWH(x - 14, y - 13, 28, 3);
      canvas.drawRect(
        bar,
        Paint()..color = Colors.white.withValues(alpha: 0.5),
      );
      canvas.drawRect(
        Rect.fromLTWH(bar.left, bar.top, bar.width * loadRatio, bar.height),
        Paint()
          ..color = loadRatio > 0.85
              ? _blockedBusColor
              : const Color(0xff5ca66b),
      );
      final statusLabel = _busStateLabel(visualState);
      if (statusLabel.isNotEmpty) {
        _paintSmallLabel(canvas, statusLabel, Offset(x, y - 43), color);
      }
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${bus.id}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(x - textPainter.width / 2, y - 31));
    }
  }

  String _busStateLabel(BusVisualState state) => switch (state) {
    BusVisualState.blocked => '前車',
    BusVisualState.springHold => '保持',
    BusVisualState.assistSkip => '補助',
    BusVisualState.alightOnlySkip => '降車',
    BusVisualState.crowded => '満員',
    BusVisualState.delayed => '遅延',
    BusVisualState.followerClose => '接近',
    BusVisualState.normal => '',
  };

  void _paintSmallLabel(
    Canvas canvas,
    String text,
    Offset center,
    Color color,
  ) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(center.dx - textPainter.width / 2, center.dy),
    );
  }

  @override
  bool shouldRepaint(covariant RoutePainter oldDelegate) => true;
}

class MetricCharts extends StatelessWidget {
  const MetricCharts({
    super.key,
    required this.histories,
    required this.durationMin,
  });

  factory MetricCharts.fromComparison({required ComparisonResult result}) =>
      MetricCharts(
        histories: {
          for (final mode in modeKeys) mode: result.results[mode]!.history,
        },
        durationMin: result.config.durationMin,
      );

  factory MetricCharts.fromSeedAverage({required SeedAverageResult result}) =>
      MetricCharts(
        histories: {
          for (final mode in modeKeys) mode: result.histories[mode] ?? const [],
        },
        durationMin: result.config.durationMin,
      );

  final Map<String, List<Map<String, dynamic>>> histories;
  final double durationMin;

  @override
  Widget build(BuildContext context) {
    final charts = _chartSpecs(histories);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '主要グラフ',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        const MetricChartLegend(),
        const SizedBox(height: 8),
        for (final chart in charts) ...[
          MetricChartCard(spec: chart, durationMin: durationMin),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class MetricChartCard extends StatelessWidget {
  const MetricChartCard({
    super.key,
    required this.spec,
    required this.durationMin,
  });

  final MetricChartSpec spec;
  final double durationMin;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    spec.title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(spec.unit, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 168,
              width: double.infinity,
              child: CustomPaint(
                painter: MetricTrendPainter(
                  series: spec.series,
                  durationMin: durationMin,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MetricChartSpec {
  const MetricChartSpec({
    required this.title,
    required this.unit,
    required this.series,
  });

  final String title;
  final String unit;
  final List<MetricSeries> series;
}

class MetricSeries {
  const MetricSeries({
    required this.name,
    required this.color,
    required this.history,
    required this.metric,
    this.dashed = false,
  });

  final String name;
  final Color color;
  final List<Map<String, dynamic>> history;
  final String metric;
  final bool dashed;
}

class MetricChartLegend extends StatelessWidget {
  const MetricChartLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      children: [
        for (final mode in modeKeys)
          _LegendItem(
            label: modeLabels[mode]!,
            color: _modeColor(mode),
            dashed: false,
          ),
        const _LegendItem(
          label: '破線は上位5%または最大',
          color: Color(0xff68707c),
          dashed: true,
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.label,
    required this.color,
    required this.dashed,
  });

  final String label;
  final Color color;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size(18, 8),
          painter: _LegendLinePainter(color: color, dashed: dashed),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _LegendLinePainter extends CustomPainter {
  const _LegendLinePainter({required this.color, required this.dashed});

  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(0, size.height / 2)
      ..lineTo(size.width, size.height / 2);
    if (dashed) {
      _drawDashedPath(canvas, path, paint);
    } else {
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LegendLinePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.dashed != dashed;
}

class MetricTrendPainter extends CustomPainter {
  MetricTrendPainter({required this.series, required this.durationMin});

  final List<MetricSeries> series;
  final double durationMin;

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 48.0;
    const padR = 10.0;
    const padT = 12.0;
    const padB = 24.0;
    final all = [
      for (final item in series)
        for (final row in item.history)
          (row[item.metric] as num?)?.toDouble() ?? double.nan,
    ].where((value) => value.isFinite).toList();
    final maxY = all.isEmpty ? 1.0 : math.max(1.0, all.reduce(math.max));
    final maxX = math.max(1.0, durationMin);
    final axis = Paint()
      ..color = const Color(0xffc9c4b9)
      ..strokeWidth = 1;
    final grid = Paint()
      ..color = const Color(0xffddd8ce)
      ..strokeWidth = 0.8;
    for (final fraction in const [0.0, 0.5, 1.0]) {
      final y = size.height - padB - fraction * (size.height - padT - padB);
      canvas.drawLine(Offset(padL, y), Offset(size.width - padR, y), grid);
      final label = _fmt(maxY * fraction);
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(color: Color(0xff5f6670), fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.right,
      )..layout(maxWidth: padL - 6);
      textPainter.paint(
        canvas,
        Offset(padL - 7 - textPainter.width, y - textPainter.height / 2),
      );
    }
    canvas.drawLine(
      Offset(padL, size.height - padB),
      Offset(size.width - padR, size.height - padB),
      axis,
    );
    canvas.drawLine(Offset(padL, padT), Offset(padL, size.height - padB), axis);
    for (final item in series) {
      final rows = item.history;
      if (rows.length < 2) continue;
      final path = Path();
      var hasStarted = false;
      for (var i = 0; i < rows.length; i++) {
        final t = ((rows[i]['t'] as num?)?.toDouble() ?? 0) / 60;
        final raw = (rows[i][item.metric] as num?)?.toDouble();
        if (raw == null || !raw.isFinite) {
          hasStarted = false;
          continue;
        }
        final yv = raw.clamp(0, maxY);
        final x = padL + t / maxX * (size.width - padL - padR);
        final y = size.height - padB - yv / maxY * (size.height - padT - padB);
        if (!hasStarted) {
          path.moveTo(x, y);
          hasStarted = true;
        } else {
          path.lineTo(x, y);
        }
      }
      final paint = Paint()
        ..color = item.color
        ..strokeWidth = item.dashed ? 1.8 : 2.4
        ..style = PaintingStyle.stroke;
      if (item.dashed) {
        _drawDashedPath(canvas, path, paint);
      } else {
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant MetricTrendPainter oldDelegate) => true;
}

void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
  const dash = 7.0;
  const gap = 5.0;
  for (final metric in path.computeMetrics()) {
    var distance = 0.0;
    while (distance < metric.length) {
      final next = math.min(distance + dash, metric.length);
      canvas.drawPath(metric.extractPath(distance, next), paint);
      distance += dash + gap;
    }
  }
}

List<MetricChartSpec> _chartSpecs(
  Map<String, List<Map<String, dynamic>>> histories,
) {
  List<MetricSeries> modeSeries(String metric) => [
    for (final mode in modeKeys)
      MetricSeries(
        name: modeLabels[mode]!,
        color: _modeColor(mode),
        history: histories[mode] ?? const [],
        metric: metric,
      ),
  ];

  List<MetricSeries> pairedSeries(
    String averageMetric,
    String topMetric,
    String averageLabel,
    String topLabel,
  ) => [
    for (final mode in modeKeys)
      MetricSeries(
        name: '${modeLabels[mode]} $averageLabel',
        color: _modeColor(mode),
        history: histories[mode] ?? const [],
        metric: averageMetric,
      ),
    for (final mode in modeKeys)
      MetricSeries(
        name: '${modeLabels[mode]} $topLabel',
        color: _modeAltColor(mode),
        history: histories[mode] ?? const [],
        metric: topMetric,
        dashed: true,
      ),
  ];

  return [
    MetricChartSpec(
      title: '待ち時間',
      unit: '平均 / 上位5% 分',
      series: pairedSeries('avgWaitMin', 'top5WaitMin', '平均', '上位5%'),
    ),
    MetricChartSpec(
      title: '総所要時間',
      unit: '補正平均 / 上位5% 分',
      series: pairedSeries(
        'adjustedAvgTotalMin',
        'adjustedTop5TotalMin',
        '補正平均',
        '上位5%',
      ),
    ),
    MetricChartSpec(
      title: '直近5分の待ち時間',
      unit: '平均 / 上位5% 分',
      series: pairedSeries(
        'recentAvgWaitMin',
        'recentTop5WaitMin',
        '直近平均',
        '上位5%',
      ),
    ),
    MetricChartSpec(
      title: '最小車間',
      unit: '停留所数',
      series: modeSeries('minHeadwayStops'),
    ),
    MetricChartSpec(
      title: '最大車間',
      unit: '停留所数',
      series: modeSeries('maxHeadwayStops'),
    ),
    MetricChartSpec(
      title: 'RMSE',
      unit: '停留所数',
      series: modeSeries('headwayRmseStops'),
    ),
    MetricChartSpec(
      title: 'スキップ乗客の追加待ち',
      unit: '平均 / 最大 分',
      series: pairedSeries(
        'deniedAvgExtraMin',
        'deniedMaxExtraMin',
        '平均',
        '最大',
      ),
    ),
    MetricChartSpec(
      title: '前車待ち遅延',
      unit: '累積 分',
      series: modeSeries('totalBlockedDelayMin'),
    ),
  ];
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.presetKey,
    required this.controllers,
    required this.onPresetChanged,
    required this.onSettingsChanged,
    required this.onRandomSeed,
  });

  final String presetKey;
  final Map<String, TextEditingController> controllers;
  final ValueChanged<String> onPresetChanged;
  final VoidCallback onSettingsChanged;
  final VoidCallback onRandomSeed;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  initialValue: presets.containsKey(presetKey)
                      ? presetKey
                      : 'custom',
                  decoration: const InputDecoration(labelText: 'プリセット'),
                  items: [
                    if (!presets.containsKey(presetKey))
                      const DropdownMenuItem(
                        value: 'custom',
                        child: Text('カスタム'),
                      ),
                    for (final entry in presets.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value.name),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) onPresetChanged(value);
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _SettingsSection(
          title: '基本',
          fields: [
            _ConfigField('seed', 'ランダムシード'),
            _ConfigField('durationMin', '時間 分'),
            _ConfigField('stopCount', '停留所数'),
            _ConfigField('busCount', 'バス台数'),
            _ConfigField('demandMultiplier', '需要倍率'),
            _ConfigField('capacity', '定員'),
          ],
          controllers: controllers,
          onChanged: onSettingsChanged,
          onRandomSeed: onRandomSeed,
        ),
        _SettingsSection(
          title: '運行・需要',
          fields: [
            _ConfigField('baseSpeedKmh', '基本速度 km/h'),
            _ConfigField('stopDistanceKm', '停留所間 km'),
            _ConfigField('fixedStopSec', '固定停車秒'),
            _ConfigField('boardTimeSec', '乗車 秒/人'),
            _ConfigField('alightTimeSec', '降車 秒/人'),
            _ConfigField('randomDelayMeanSec', '区間平均遅れ秒'),
            _ConfigField('hotspotStops', '需要集中停留所'),
            _ConfigField('hotspotMultiplier', '集中倍率'),
          ],
          controllers: controllers,
          onChanged: onSettingsChanged,
          onRandomSeed: onRandomSeed,
        ),
        _SettingsSection(
          title: '制御',
          fields: [
            _ConfigField('distanceThresholdStops', '後続車間しきい値 停'),
            _ConfigField('delayThresholdMin', '先行遅延しきい値 分'),
            _ConfigField('followerLoadLimit', '後続混雑しきい値'),
            _ConfigField('springGainSecPerStop', 'スプリングゲイン'),
            _ConfigField('springDeadbandStops', '不感帯 停'),
            _ConfigField('springDamping', '遅延減衰'),
            _ConfigField('springMaxHoldSec', '最大保持秒'),
            _ConfigField('springMinHoldSec', '最小保持秒'),
          ],
          controllers: controllers,
          onChanged: onSettingsChanged,
          onRandomSeed: onRandomSeed,
        ),
      ],
    );
  }
}

class _ConfigField {
  const _ConfigField(this.key, this.label);
  final String key;
  final String label;
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.fields,
    required this.controllers,
    required this.onChanged,
    required this.onRandomSeed,
  });
  final String title;
  final List<_ConfigField> fields;
  final Map<String, TextEditingController> controllers;
  final VoidCallback onChanged;
  final VoidCallback onRandomSeed;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            for (final field in fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: controllers[field.key],
                  onChanged: (_) => onChanged(),
                  keyboardType: field.key == 'hotspotStops'
                      ? TextInputType.text
                      : const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: field.label,
                    border: const OutlineInputBorder(),
                    suffixIcon: field.key == 'seed'
                        ? IconButton(
                            onPressed: onRandomSeed,
                            tooltip: 'ランダムなシードに変更',
                            icon: const Icon(Icons.casino_outlined),
                          )
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class SeedAveragePage extends StatefulWidget {
  const SeedAveragePage({
    super.key,
    required this.config,
    required this.progress,
    required this.result,
    required this.status,
    required this.running,
    required this.summaryMetricMode,
    required this.onToggleSummaryMetricMode,
    required this.onRun,
    required this.onCancel,
  });

  final SimulationConfig config;
  final SeedAverageProgress? progress;
  final SeedAverageResult? result;
  final String? status;
  final bool running;
  final SummaryMetricDisplayMode summaryMetricMode;
  final VoidCallback onToggleSummaryMetricMode;
  final Future<void> Function(int baseSeed, int count) onRun;
  final VoidCallback onCancel;

  @override
  State<SeedAveragePage> createState() => _SeedAveragePageState();
}

class _SeedAveragePageState extends State<SeedAveragePage> {
  late final _baseSeed = TextEditingController(text: '${widget.config.seed}');
  final _count = TextEditingController(text: '100');

  @override
  void didUpdateWidget(covariant SeedAveragePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.seed != widget.config.seed && !widget.running) {
      _baseSeed.text = '${widget.config.seed}';
    }
  }

  @override
  void dispose() {
    _baseSeed.dispose();
    _count.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final result = widget.result;
    final value = progress == null || progress.total == 0
        ? 0.0
        : progress.completed / progress.total;
    final comparisonResult = result == null
        ? null
        : ComparisonResult(
            config: result.config,
            events: const [],
            results: {
              for (final mode in modeKeys)
                mode: ModeResult(
                  metrics: result.results[mode]!,
                  history: result.histories[mode] ?? const [],
                ),
            },
          );
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _baseSeed,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '基準シード'),
                ),
                TextField(
                  controller: _count,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '平均シード数 上限10000',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: widget.running
                            ? null
                            : () => widget.onRun(
                                int.tryParse(_baseSeed.text) ??
                                    widget.config.seed,
                                (int.tryParse(_count.text) ?? 100).clamp(
                                  1,
                                  10000,
                                ),
                              ),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('シード平均を実行'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: widget.running ? widget.onCancel : null,
                      icon: const Icon(Icons.stop),
                      tooltip: '中断',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: widget.running
                      ? value.clamp(0, 1)
                      : (result == null ? 0 : 1),
                ),
                const SizedBox(height: 8),
                Text(widget.status ?? '未実行'),
              ],
            ),
          ),
        ),
        if (result != null) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${result.seeds.length} seeds',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SummaryGrid(
                    result: comparisonResult!,
                    displayMode: widget.summaryMetricMode,
                    onToggleDisplayMode: widget.onToggleSummaryMetricMode,
                  ),
                  const SizedBox(height: 12),
                  DetailedMetricsCard(result: comparisonResult),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          MetricCharts.fromSeedAverage(result: result),
        ],
      ],
    );
  }
}

class IoPage extends StatelessWidget {
  const IoPage({
    super.key,
    required this.controller,
    required this.comparison,
    required this.seedAverage,
    required this.onCopyConfig,
    required this.onCopyResults,
    required this.onCopyMetricsCsv,
    required this.onCopySeedJson,
    required this.onCopySeedCsv,
    required this.onSaveConfig,
    required this.onSaveResults,
    required this.onSaveMetricsCsv,
    required this.onSaveSeedJson,
    required this.onSaveSeedCsv,
    required this.onOpenJsonFile,
    required this.onImportConfig,
    required this.onImportSeedAverage,
  });

  final TextEditingController controller;
  final ComparisonResult comparison;
  final SeedAverageResult? seedAverage;
  final VoidCallback onCopyConfig;
  final VoidCallback onCopyResults;
  final VoidCallback onCopyMetricsCsv;
  final VoidCallback? onCopySeedJson;
  final VoidCallback? onCopySeedCsv;
  final VoidCallback onSaveConfig;
  final VoidCallback onSaveResults;
  final VoidCallback onSaveMetricsCsv;
  final VoidCallback? onSaveSeedJson;
  final VoidCallback? onSaveSeedCsv;
  final VoidCallback onOpenJsonFile;
  final VoidCallback onImportConfig;
  final VoidCallback onImportSeedAverage;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onCopyConfig,
                  icon: const Icon(Icons.settings),
                  label: const Text('設定JSONコピー'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onCopyResults,
                  icon: const Icon(Icons.data_object),
                  label: const Text('結果JSONコピー'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onCopyMetricsCsv,
                  icon: const Icon(Icons.table_chart),
                  label: const Text('指標CSVコピー'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onCopySeedJson,
                  icon: const Icon(Icons.functions),
                  label: const Text('平均JSONコピー'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onCopySeedCsv,
                  icon: const Icon(Icons.grid_on),
                  label: const Text('平均CSVコピー'),
                ),
                FilledButton.icon(
                  onPressed: onSaveConfig,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('設定JSON保存'),
                ),
                FilledButton.icon(
                  onPressed: onSaveResults,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('結果JSON保存'),
                ),
                FilledButton.icon(
                  onPressed: onSaveMetricsCsv,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('指標CSV保存'),
                ),
                FilledButton.icon(
                  onPressed: onSaveSeedJson,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('平均JSON保存'),
                ),
                FilledButton.icon(
                  onPressed: onSaveSeedCsv,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('平均CSV保存'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: controller,
                  minLines: 8,
                  maxLines: 16,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'JSON貼り付け',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: onOpenJsonFile,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('JSONファイルを選択'),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onImportConfig,
                        icon: const Icon(Icons.upload_file),
                        label: const Text('設定として読込'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: onImportSeedAverage,
                        icon: const Icon(Icons.functions),
                        label: const Text('平均結果として読込'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _timeText(double sec) {
  final m = sec ~/ 60;
  final s = sec.floor() % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String _fmt(double? value, [int digits = 1]) {
  if (value == null || !value.isFinite) return '-';
  return value.toStringAsFixed(digits);
}

Color _modeColor(String mode) => switch (mode) {
  'plain' => const Color(0xffc83f3f),
  'skip' => const Color(0xff25865f),
  'spring' => const Color(0xff7357c8),
  _ => const Color(0xff244a66),
};

Color _modeAltColor(String mode) => switch (mode) {
  'plain' => const Color(0xffa12d2d),
  'skip' => const Color(0xff166f4b),
  'spring' => const Color(0xff5a43a6),
  _ => const Color(0xff244a66),
};
