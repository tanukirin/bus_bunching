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

class _SimulatorHomeState extends State<SimulatorHome> {
  late SimulationConfig _config = presets['urban']!;
  late ComparisonRunner _runner = ComparisonRunner(_config);
  late ComparisonResult _result = _runner.snapshot();
  final _controllers = <String, TextEditingController>{};
  final _importController = TextEditingController();
  int _tab = 0;
  bool _running = false;
  double _speed = 18;
  Timer? _timer;
  String _presetKey = 'urban';
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

  void _toggleRun() {
    setState(() => _running = !_running);
    _timer?.cancel();
    if (!_running) return;
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

  void _step10() {
    _runner.step(10);
    setState(() => _result = _runner.snapshot());
  }

  void _applySettings() {
    final hotspots = (_controllers['hotspotStops']?.text ?? '')
        .split(',')
        .map((part) => int.tryParse(part.trim()))
        .whereType<int>()
        .toList();
    final next = normalizeConfig({
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
    _presetKey = 'custom';
    _syncControllers();
    _resetRunner(next);
    _snack('設定を反映しました');
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
        running: _running,
        speed: _speed,
        onToggleRun: _toggleRun,
        onStep: _step10,
        onReset: () => _resetRunner(_config),
        onSpeedChanged: (value) => setState(() => _speed = value),
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
        onApply: _applySettings,
      ),
      SeedAveragePage(
        config: _config,
        progress: _seedProgress,
        result: _seedAverage,
        status: _seedStatus,
        running: _seedHandle != null,
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
      appBar: AppBar(
        title: const Text('バス団子シミュレーター'),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: const Icon(Icons.confirmation_number_outlined, size: 16),
              label: Text('seed ${_config.seed}'),
            ),
          ),
        ],
      ),
      body: SafeArea(child: pages[_tab]),
      bottomNavigationBar: NavigationBar(
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
    );
  }
}

class AnalysisPage extends StatelessWidget {
  const AnalysisPage({
    super.key,
    required this.result,
    required this.runner,
    required this.running,
    required this.speed,
    required this.onToggleRun,
    required this.onStep,
    required this.onReset,
    required this.onSpeedChanged,
  });

  final ComparisonResult result;
  final ComparisonRunner runner;
  final bool running;
  final double speed;
  final VoidCallback onToggleRun;
  final VoidCallback onStep;
  final VoidCallback onReset;
  final ValueChanged<double> onSpeedChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        ControlPanel(
          running: running,
          speed: speed,
          time: runner.time,
          durationSec: result.config.durationSec,
          onToggleRun: onToggleRun,
          onStep: onStep,
          onReset: onReset,
          onSpeedChanged: onSpeedChanged,
        ),
        const SizedBox(height: 12),
        SummaryGrid(result: result),
        const SizedBox(height: 12),
        for (final mode in modeKeys) ...[
          ScenarioCard(
            mode: mode,
            sim: runner.sims[mode]!,
            result: result.results[mode]!,
          ),
          const SizedBox(height: 12),
        ],
        TrendCard(result: result),
      ],
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
    required this.onStep,
    required this.onReset,
    required this.onSpeedChanged,
  });

  final bool running;
  final double speed;
  final double time;
  final int durationSec;
  final VoidCallback onToggleRun;
  final VoidCallback onStep;
  final VoidCallback onReset;
  final ValueChanged<double> onSpeedChanged;

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
                FilledButton.icon(
                  onPressed: onToggleRun,
                  icon: Icon(running ? Icons.pause : Icons.play_arrow),
                  label: Text(running ? '一時停止' : '再生'),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: onStep,
                  tooltip: '10秒進める',
                  icon: const Icon(Icons.forward_10),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: onReset,
                  tooltip: 'リセット',
                  icon: const Icon(Icons.restart_alt),
                ),
                const Spacer(),
                Text(
                  '${_timeText(time)} / ${_timeText(durationSec.toDouble())}',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.speed, size: 18),
                Expanded(
                  child: Slider(
                    value: speed,
                    min: 1,
                    max: 240,
                    divisions: 239,
                    label: '${speed.round()}x',
                    onChanged: onSpeedChanged,
                  ),
                ),
                SizedBox(
                  width: 48,
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

class SummaryGrid extends StatelessWidget {
  const SummaryGrid({super.key, required this.result});

  final ComparisonResult result;

  @override
  Widget build(BuildContext context) {
    final p = result.plain.metrics;
    final s = result.skip.metrics;
    final g = result.spring.metrics;
    double improve(Map<String, dynamic> m, String key) {
      final base = (p[key] as num?)?.toDouble() ?? 0;
      final value = (m[key] as num?)?.toDouble() ?? 0;
      return base > 0 ? (base - value) / base * 100 : 0;
    }

    final items = [
      _SummaryItem(
        '待ち改善',
        'S ${_fmt(improve(s, 'avgWaitMin'), 0)}% / Sp ${_fmt(improve(g, 'avgWaitMin'), 0)}%',
        '平均待ち時間',
      ),
      _SummaryItem(
        '補正総所要',
        'S ${_fmt(improve(s, 'adjustedAvgTotalMin'), 0)}% / Sp ${_fmt(improve(g, 'adjustedAvgTotalMin'), 0)}%',
        '未完了客も評価',
      ),
      _SummaryItem(
        '車間RMSE',
        '${_fmt((g['headwayRmseStops'] as num?)?.toDouble())}停',
        '小さいほど均等',
      ),
      _SummaryItem(
        '最大車間',
        '${_fmt((g['maxHeadwayStops'] as num?)?.toDouble())}停',
        '空白区間',
      ),
      _SummaryItem(
        '保持累計',
        '${_fmt((g['totalSpringHoldMin'] as num?)?.toDouble())}分',
        'spring制御',
      ),
      _SummaryItem(
        '乗車不可',
        '${(g['deniedPassengers'] as num?)?.round() ?? 0}人',
        '副作用',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 720 ? 3 : 2;
        return GridView.count(
          crossAxisCount: columns,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: columns == 3 ? 2.2 : 1.55,
          children: items.map((item) => _MetricTile(item: item)).toList(),
        );
      },
    );
  }
}

class _SummaryItem {
  const _SummaryItem(this.label, this.value, this.sub);
  final String label;
  final String value;
  final String sub;
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.item});
  final _SummaryItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(item.label, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                item.value,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            Text(
              item.sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class ScenarioCard extends StatelessWidget {
  const ScenarioCard({
    super.key,
    required this.mode,
    required this.sim,
    required this.result,
  });

  final String mode;
  final SimulationEngine sim;
  final ModeResult result;

  @override
  Widget build(BuildContext context) {
    final metrics = result.metrics;
    final color = _modeColor(mode);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                Text(
                  modeLabels[mode]!,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Chip(
                  label: Text('団子度 ${(metrics['bunchScore'] as num).round()}'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 180,
              width: double.infinity,
              child: CustomPaint(
                painter: RoutePainter(sim: sim, modeColor: color),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MiniMetric(
                  '平均待ち',
                  '${_fmt((metrics['avgWaitMin'] as num?)?.toDouble())}分',
                ),
                _MiniMetric(
                  '補正総所要',
                  '${_fmt((metrics['adjustedAvgTotalMin'] as num?)?.toDouble())}分',
                ),
                _MiniMetric(
                  '最小車間',
                  '${_fmt((metrics['minHeadwayStops'] as num?)?.toDouble())}停',
                ),
                _MiniMetric(
                  '前車待ち',
                  '${_fmt((metrics['totalBlockedDelayMin'] as num?)?.toDouble())}分',
                ),
                _MiniMetric(
                  '保持',
                  '${_fmt((metrics['totalSpringHoldMin'] as num?)?.toDouble())}分',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric(this.label, this.value);
  final String label;
  final String value;

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
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
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

class RoutePainter extends CustomPainter {
  RoutePainter({required this.sim, required this.modeColor});

  final SimulationEngine sim;
  final Color modeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final c = sim.config;
    final pad = math.min(28.0, size.width * 0.08);
    final y = size.height * 0.5;
    final left = pad;
    final right = size.width - pad;
    final stopPaint = Paint()..color = const Color(0xff79828f);
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
      final x = xFor(i.toDouble());
      canvas.drawCircle(Offset(x, y), 4.5, stopPaint);
      final queue = sim.waiting[i].length;
      if (queue > 0) {
        final qp = Paint()
          ..color = Colors.orange.shade700.withValues(alpha: 0.7);
        canvas.drawRect(
          Rect.fromLTWH(x - 5, y + 10, 10, math.min(34, 4 + queue * 1.8)),
          qp,
        );
      }
    }
    for (final bus in sim.buses) {
      final x = xFor(bus.pos);
      final isBlocked = bus.status == 'blocked';
      final isHolding =
          bus.springHoldStartTime != null &&
          sim.time >= bus.springHoldStartTime! &&
          sim.time <= (bus.springHoldEndTime ?? 0);
      final paint = Paint()
        ..color = isBlocked
            ? Colors.red.shade600
            : (isHolding ? Colors.amber.shade700 : modeColor);
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, y - 26), width: 30, height: 18),
        const Radius.circular(5),
      );
      canvas.drawRRect(rect, paint);
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
      textPainter.paint(canvas, Offset(x - textPainter.width / 2, y - 33));
    }
  }

  @override
  bool shouldRepaint(covariant RoutePainter oldDelegate) => true;
}

class TrendCard extends StatelessWidget {
  const TrendCard({super.key, required this.result});

  final ComparisonResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '主要グラフ',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              width: double.infinity,
              child: CustomPaint(
                painter: TrendPainter(
                  result: result,
                  metric: 'adjustedAvgTotalMin',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TrendPainter extends CustomPainter {
  TrendPainter({required this.result, required this.metric});
  final ComparisonResult result;
  final String metric;

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 34.0;
    const padR = 10.0;
    const padT = 10.0;
    const padB = 24.0;
    final all = [
      for (final mode in modeKeys)
        for (final row in result.results[mode]!.history)
          (row[metric] as num?)?.toDouble() ?? double.nan,
    ].where((value) => value.isFinite).toList();
    final maxY = all.isEmpty ? 1.0 : math.max(1.0, all.reduce(math.max));
    final maxX = math.max(1.0, result.config.durationMin);
    final axis = Paint()
      ..color = const Color(0xffc9c4b9)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(padL, size.height - padB),
      Offset(size.width - padR, size.height - padB),
      axis,
    );
    canvas.drawLine(Offset(padL, padT), Offset(padL, size.height - padB), axis);
    for (final mode in modeKeys) {
      final rows = result.results[mode]!.history;
      if (rows.length < 2) continue;
      final path = Path();
      for (var i = 0; i < rows.length; i++) {
        final t = ((rows[i]['t'] as num?)?.toDouble() ?? 0) / 60;
        final yv = ((rows[i][metric] as num?)?.toDouble() ?? 0).clamp(0, maxY);
        final x = padL + t / maxX * (size.width - padL - padR);
        final y = size.height - padB - yv / maxY * (size.height - padT - padB);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = _modeColor(mode)
          ..strokeWidth = 2.4
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant TrendPainter oldDelegate) => true;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.presetKey,
    required this.controllers,
    required this.onPresetChanged,
    required this.onApply,
  });

  final String presetKey;
  final Map<String, TextEditingController> controllers;
  final ValueChanged<String> onPresetChanged;
  final VoidCallback onApply;

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
                      : 'urban',
                  decoration: const InputDecoration(labelText: 'プリセット'),
                  items: [
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
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: onApply,
                  icon: const Icon(Icons.check),
                  label: const Text('入力設定を反映'),
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
  });
  final String title;
  final List<_ConfigField> fields;
  final Map<String, TextEditingController> controllers;

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
                  keyboardType: field.key == 'hotspotStops'
                      ? TextInputType.text
                      : const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: field.label,
                    border: const OutlineInputBorder(),
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
    required this.onRun,
    required this.onCancel,
  });

  final SimulationConfig config;
  final SeedAverageProgress? progress;
  final SeedAverageResult? result;
  final String? status;
  final bool running;
  final Future<void> Function(int baseSeed, int count) onRun;
  final VoidCallback onCancel;

  @override
  State<SeedAveragePage> createState() => _SeedAveragePageState();
}

class _SeedAveragePageState extends State<SeedAveragePage> {
  late final _baseSeed = TextEditingController(text: '${widget.config.seed}');
  final _count = TextEditingController(text: '200');

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
                                (int.tryParse(_count.text) ?? 200).clamp(
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
                    result: ComparisonResult(
                      config: result.config,
                      events: const [],
                      results: {
                        for (final mode in modeKeys)
                          mode: ModeResult(
                            metrics: result.results[mode]!,
                            history: result.histories[mode] ?? const [],
                          ),
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
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
