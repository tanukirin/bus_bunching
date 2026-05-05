import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;

import 'config.dart';
import 'simulation.dart';

class ModeResult {
  const ModeResult({required this.metrics, required this.history});

  final Map<String, dynamic> metrics;
  final List<Map<String, dynamic>> history;
}

class ComparisonResult {
  const ComparisonResult({
    required this.config,
    required this.events,
    required this.results,
  });

  final SimulationConfig config;
  final List<DemandEvent> events;
  final Map<String, ModeResult> results;

  ModeResult get plain => results['plain']!;
  ModeResult get skip => results['skip']!;
  ModeResult get spring => results['spring']!;
}

class ComparisonRunner {
  ComparisonRunner(SimulationConfig config)
    : config = config,
      events = EventGenerator.demandEvents(config) {
    _resetSims();
  }

  final SimulationConfig config;
  final List<DemandEvent> events;
  late Map<String, SimulationEngine> sims;

  void _resetSims() {
    sims = {
      'plain': SimulationEngine(config, 'plain', events),
      'skip': SimulationEngine(config, 'skip', events),
      'spring': SimulationEngine(config, 'spring', events),
    };
    for (final sim in sims.values) {
      sim.sample();
    }
  }

  double get time => sims['plain']!.time;
  bool get isComplete => time >= config.durationSec;

  void seekTo(double seconds) {
    final target = seconds.clamp(0, config.durationSec).toDouble();
    _resetSims();
    step(target);
  }

  void step(double seconds) {
    final target = math.min(config.durationSec.toDouble(), time + seconds);
    while (time < target) {
      final dt = math.min(1.0, target - time);
      for (final sim in sims.values) {
        sim.step(dt);
      }
    }
  }

  ComparisonResult snapshot() => ComparisonResult(
    config: config,
    events: events,
    results: {
      for (final entry in sims.entries)
        entry.key: ModeResult(
          metrics: entry.value.computeMetrics(),
          history: entry.value.history
              .map((row) => Map<String, dynamic>.from(row))
              .toList(),
        ),
    },
  );
}

ComparisonResult runThreeModes(
  SimulationConfig config, {
  List<String> modes = modeKeys,
  bool includeHistory = true,
  String engine = 'audit',
}) {
  final events = EventGenerator.demandEvents(config);
  final results = <String, ModeResult>{};
  for (final mode in modes) {
    if (!modeKeys.contains(mode)) {
      throw ArgumentError.value(mode, 'mode', 'unsupported mode');
    }
    final sim = SimulationEngine(
      config,
      mode,
      events,
      includeHistory: includeHistory,
      engine: engine,
    );
    final metrics = sim.runToEnd();
    results[mode] = ModeResult(
      metrics: metrics,
      history: includeHistory
          ? sim.history.map((row) => Map<String, dynamic>.from(row)).toList()
          : const [],
    );
  }
  return ComparisonResult(config: config, events: events, results: results);
}

class SeedAverageResult {
  const SeedAverageResult({
    required this.config,
    required this.seeds,
    required this.results,
    required this.sd,
    required this.histories,
  });

  final SimulationConfig config;
  final List<int> seeds;
  final Map<String, Map<String, dynamic>> results;
  final Map<String, Map<String, double>> sd;
  final Map<String, List<Map<String, dynamic>>> histories;

  Map<String, dynamic> toJson() => {
    'type': 'bus-bunching-seed-average-results',
    'version': 1,
    'config': config.toJson(),
    'seedAverage': {
      'seeds': seeds,
      'seedCount': seeds.length,
      for (final mode in modeKeys)
        mode: {
          'metrics': results[mode],
          'sd': sd[mode],
          'history': histories[mode],
        },
    },
  };
}

class SeedAverageProgress {
  const SeedAverageProgress({required this.completed, required this.total});

  final int completed;
  final int total;
}

class SeedAverageHandle {
  SeedAverageHandle._(this.progress, this.done, this._cancel);

  final Stream<SeedAverageProgress> progress;
  final Future<SeedAverageResult> done;
  final void Function() _cancel;

  void cancel() => _cancel();
}

class SeedAverageRunner {
  static SeedAverageResult runSync({
    required SimulationConfig config,
    required int baseSeed,
    required int count,
    int step = 101,
    bool includeHistory = true,
    String engine = 'fast',
    void Function(int completed, int total)? onProgress,
  }) {
    final seeds = seedSequence(base: baseSeed, count: count, step: step);
    final accumulator = _runSeedChunkSync(
      config: config,
      seeds: seeds,
      includeHistory: includeHistory,
      engine: engine,
      onProgress: onProgress,
    );
    return accumulator.build(config.copyWith(seed: baseSeed), seeds);
  }

  static Future<SeedAverageResult> runIsolated({
    required SimulationConfig config,
    required int baseSeed,
    required int count,
    int step = 101,
    bool includeHistory = true,
    String engine = 'fast',
  }) => Isolate.run(
    () => runSync(
      config: config,
      baseSeed: baseSeed,
      count: count,
      step: step,
      includeHistory: includeHistory,
      engine: engine,
    ),
  );

  static Future<SeedAverageHandle> start({
    required SimulationConfig config,
    required int baseSeed,
    required int count,
    int step = 101,
    bool includeHistory = true,
    String engine = 'fast',
    int? maxWorkers,
  }) async {
    final seeds = seedSequence(base: baseSeed, count: count, step: step);
    final workerCount = _seedAverageWorkerCount(
      seedCount: seeds.length,
      maxWorkers: maxWorkers,
    );
    if (workerCount <= 1) {
      return _startSingleWorker(
        config: config,
        baseSeed: baseSeed,
        seeds: seeds,
        includeHistory: includeHistory,
        engine: engine,
      );
    }
    return _startParallelWorkers(
      config: config,
      baseSeed: baseSeed,
      seeds: seeds,
      includeHistory: includeHistory,
      engine: engine,
      workerCount: workerCount,
    );
  }

  static Future<SeedAverageHandle> _startSingleWorker({
    required SimulationConfig config,
    required int baseSeed,
    required List<int> seeds,
    required bool includeHistory,
    required String engine,
  }) async {
    final receive = ReceivePort();
    final progressController =
        StreamController<SeedAverageProgress>.broadcast();
    final done = Completer<SeedAverageResult>();
    final isolate = await Isolate.spawn(_seedAverageIsolate, {
      'sendPort': receive.sendPort,
      'config': config.toJson(),
      'baseSeed': baseSeed,
      'seeds': seeds,
      'includeHistory': includeHistory,
      'engine': engine,
    });
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      progressController.close();
      receive.close();
    }

    receive.listen((message) {
      if (message is Map && message['type'] == 'progress') {
        progressController.add(
          SeedAverageProgress(
            completed: message['completed'] as int,
            total: message['total'] as int,
          ),
        );
      } else if (message is Map && message['type'] == 'done') {
        done.complete(_seedAverageResultFromMessage(message['result'] as Map));
        close();
      } else if (message is Map && message['type'] == 'error') {
        done.completeError(message['message'] ?? 'seed average failed');
        close();
      }
    });
    return SeedAverageHandle._(progressController.stream, done.future, () {
      isolate.kill(priority: Isolate.immediate);
      if (!done.isCompleted) done.completeError('seed average cancelled');
      close();
    });
  }

  static Future<SeedAverageHandle> _startParallelWorkers({
    required SimulationConfig config,
    required int baseSeed,
    required List<int> seeds,
    required bool includeHistory,
    required String engine,
    required int workerCount,
  }) async {
    final receive = ReceivePort();
    final progressController =
        StreamController<SeedAverageProgress>.broadcast();
    final done = Completer<SeedAverageResult>();
    final chunks = _splitSeeds(seeds, workerCount);
    final isolates = <Isolate>[];
    final completedByWorker = List<int>.filled(chunks.length, 0);
    final accumulator = _SeedAverageAccumulator(includeHistory: includeHistory);
    var remainingWorkers = chunks.length;
    var closed = false;

    int completedTotal() =>
        completedByWorker.fold<int>(0, (sum, value) => sum + value);

    void close() {
      if (closed) return;
      closed = true;
      progressController.close();
      receive.close();
    }

    void fail(Object error) {
      for (final isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
      if (!done.isCompleted) done.completeError(error);
      close();
    }

    receive.listen((message) {
      if (closed) return;
      if (message is! Map) return;
      final type = message['type'];
      if (type == 'progress') {
        final workerId = message['workerId'] as int;
        completedByWorker[workerId] = message['completed'] as int;
        progressController.add(
          SeedAverageProgress(completed: completedTotal(), total: seeds.length),
        );
      } else if (type == 'chunkDone') {
        final workerId = message['workerId'] as int;
        completedByWorker[workerId] = chunks[workerId].length;
        accumulator.mergeMessage(message['stats'] as Map);
        remainingWorkers--;
        progressController.add(
          SeedAverageProgress(completed: completedTotal(), total: seeds.length),
        );
        if (remainingWorkers == 0) {
          done.complete(
            accumulator.build(config.copyWith(seed: baseSeed), seeds),
          );
          close();
        }
      } else if (type == 'error') {
        fail(message['message'] ?? 'seed average failed');
      }
    });

    try {
      for (var workerId = 0; workerId < chunks.length; workerId++) {
        isolates.add(
          await Isolate.spawn(_seedAverageChunkIsolate, {
            'sendPort': receive.sendPort,
            'workerId': workerId,
            'config': config.toJson(),
            'seeds': chunks[workerId],
            'includeHistory': includeHistory,
            'engine': engine,
          }),
        );
      }
    } catch (error) {
      fail(error);
    }

    return SeedAverageHandle._(progressController.stream, done.future, () {
      fail('seed average cancelled');
    });
  }
}

void _seedAverageIsolate(Map<String, dynamic> message) {
  final sendPort = message['sendPort'] as SendPort;
  try {
    final config = normalizeConfig(
      Map<String, dynamic>.from(message['config'] as Map),
    );
    final seeds = (message['seeds'] as Iterable)
        .whereType<num>()
        .map((value) => value.toInt())
        .toList();
    final accumulator = _runSeedChunkSync(
      config: config,
      seeds: seeds,
      includeHistory: message['includeHistory'] as bool,
      engine: message['engine'] as String,
      onProgress: (completed, total) {
        if (completed == total || completed % (total >= 1000 ? 10 : 3) == 0) {
          sendPort.send({
            'type': 'progress',
            'completed': completed,
            'total': total,
          });
        }
      },
    );
    final result = accumulator.build(
      config.copyWith(seed: message['baseSeed'] as int),
      seeds,
    );
    sendPort.send({'type': 'done', 'result': result.toJson()});
  } catch (error, stackTrace) {
    sendPort.send({'type': 'error', 'message': '$error\n$stackTrace'});
  }
}

void _seedAverageChunkIsolate(Map<String, dynamic> message) {
  final sendPort = message['sendPort'] as SendPort;
  final workerId = message['workerId'] as int;
  try {
    final config = normalizeConfig(
      Map<String, dynamic>.from(message['config'] as Map),
    );
    final seeds = (message['seeds'] as Iterable)
        .whereType<num>()
        .map((value) => value.toInt())
        .toList();
    final accumulator = _runSeedChunkSync(
      config: config,
      seeds: seeds,
      includeHistory: message['includeHistory'] as bool,
      engine: message['engine'] as String,
      onProgress: (completed, total) {
        if (completed == total || completed % (total >= 1000 ? 10 : 3) == 0) {
          sendPort.send({
            'type': 'progress',
            'workerId': workerId,
            'completed': completed,
            'total': total,
          });
        }
      },
    );
    sendPort.send({
      'type': 'chunkDone',
      'workerId': workerId,
      'stats': accumulator.toMessage(),
    });
  } catch (error, stackTrace) {
    sendPort.send({
      'type': 'error',
      'workerId': workerId,
      'message': '$error\n$stackTrace',
    });
  }
}

_SeedAverageAccumulator _runSeedChunkSync({
  required SimulationConfig config,
  required List<int> seeds,
  required bool includeHistory,
  required String engine,
  void Function(int completed, int total)? onProgress,
}) {
  final accumulator = _SeedAverageAccumulator(includeHistory: includeHistory);
  for (var i = 0; i < seeds.length; i++) {
    final result = runThreeModes(
      config.copyWith(seed: seeds[i]),
      includeHistory: includeHistory,
      engine: engine,
    );
    accumulator.add(result);
    onProgress?.call(i + 1, seeds.length);
  }
  return accumulator;
}

int _seedAverageWorkerCount({required int seedCount, int? maxWorkers}) {
  if (seedCount <= 1) return 1;
  final cpuBound = math.max(1, Platform.numberOfProcessors - 1);
  final configured = maxWorkers == null ? cpuBound : math.max(1, maxWorkers);
  return math.min(seedCount, math.min(4, math.min(cpuBound, configured)));
}

List<List<int>> _splitSeeds(List<int> seeds, int workerCount) {
  final chunks = <List<int>>[];
  final size = (seeds.length / workerCount).ceil();
  for (var start = 0; start < seeds.length; start += size) {
    chunks.add(seeds.sublist(start, math.min(seeds.length, start + size)));
  }
  return chunks;
}

SeedAverageResult _seedAverageResultFromMessage(Map raw) {
  final payload = Map<String, dynamic>.from(raw);
  final config = normalizeConfig(extractConfigPayload(payload));
  final source = Map<String, dynamic>.from(
    (payload['seedAverage'] ?? payload) as Map,
  );
  final seeds = (source['seeds'] as Iterable? ?? const [])
      .whereType<num>()
      .map((value) => value.toInt())
      .toList();
  final results = <String, Map<String, dynamic>>{};
  final sd = <String, Map<String, double>>{};
  final histories = <String, List<Map<String, dynamic>>>{};
  for (final mode in modeKeys) {
    final modeSource = Map<String, dynamic>.from(
      (source[mode] ?? const {}) as Map,
    );
    results[mode] = Map<String, dynamic>.from(
      (modeSource['metrics'] ?? source['${mode}Metrics'] ?? const {}) as Map,
    );
    sd[mode] = Map<String, double>.fromEntries(
      Map<String, dynamic>.from(
            (modeSource['sd'] ?? source['${mode}Sd'] ?? const {}) as Map,
          ).entries
          .where((entry) => entry.value is num)
          .map((entry) => MapEntry(entry.key, (entry.value as num).toDouble())),
    );
    histories[mode] =
        ((modeSource['history'] ?? source['${mode}History'] ?? const [])
                as Iterable)
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
  }
  if (seeds.isEmpty)
    throw const FormatException('seed average result has no seeds');
  return SeedAverageResult(
    config: config,
    seeds: seeds,
    results: results,
    sd: sd,
    histories: histories,
  );
}

class _MetricStats {
  int n = 0;
  double sum = 0;
  double sq = 0;

  void add(num value) {
    final v = value.toDouble();
    if (!v.isFinite) return;
    n++;
    sum += v;
    sq += v * v;
  }

  double get average => n == 0 ? 0 : sum / n;
  double get sd {
    if (n == 0) return 0;
    final m = average;
    return math.sqrt(math.max(0, sq / n - m * m));
  }

  Map<String, dynamic> toMessage() => {'n': n, 'sum': sum, 'sq': sq};

  void mergeMessage(Map raw) {
    final otherN = raw['n'];
    final otherSum = raw['sum'];
    final otherSq = raw['sq'];
    if (otherN is! num || otherSum is! num || otherSq is! num) return;
    n += otherN.toInt();
    sum += otherSum.toDouble();
    sq += otherSq.toDouble();
  }
}

class _SeedAverageAccumulator {
  _SeedAverageAccumulator({required this.includeHistory});

  final bool includeHistory;
  final metrics = {for (final mode in modeKeys) mode: <String, _MetricStats>{}};
  final histories = {
    for (final mode in modeKeys) mode: <Map<String, _MetricStats>>[],
  };

  void add(ComparisonResult result) {
    for (final mode in modeKeys) {
      for (final entry in result.results[mode]!.metrics.entries) {
        final value = entry.value;
        if (value is num) {
          metrics[mode]!.putIfAbsent(entry.key, _MetricStats.new).add(value);
        }
      }
      if (!includeHistory) continue;
      final rows = histories[mode]!;
      final history = result.results[mode]!.history;
      for (var i = 0; i < history.length; i++) {
        if (rows.length <= i) rows.add({});
        for (final entry in history[i].entries) {
          final value = entry.value;
          if (value is num) {
            rows[i].putIfAbsent(entry.key, _MetricStats.new).add(value);
          }
        }
      }
    }
  }

  Map<String, dynamic> toMessage() => {
    'metrics': {
      for (final mode in modeKeys)
        mode: {
          for (final entry in metrics[mode]!.entries)
            entry.key: entry.value.toMessage(),
        },
    },
    'histories': {
      for (final mode in modeKeys)
        mode: [
          for (final row in histories[mode]!)
            {
              for (final entry in row.entries)
                entry.key: entry.value.toMessage(),
            },
        ],
    },
  };

  void mergeMessage(Map raw) {
    final rawMetrics = Map<String, dynamic>.from(
      (raw['metrics'] ?? const {}) as Map,
    );
    for (final mode in modeKeys) {
      final rawModeMetrics = Map<String, dynamic>.from(
        (rawMetrics[mode] ?? const {}) as Map,
      );
      for (final entry in rawModeMetrics.entries) {
        final rawStats = entry.value;
        if (rawStats is Map) {
          metrics[mode]!
              .putIfAbsent(entry.key, _MetricStats.new)
              .mergeMessage(rawStats);
        }
      }
    }
    if (!includeHistory) return;
    final rawHistories = Map<String, dynamic>.from(
      (raw['histories'] ?? const {}) as Map,
    );
    for (final mode in modeKeys) {
      final rawRows = (rawHistories[mode] ?? const []) as Iterable;
      final rows = histories[mode]!;
      var i = 0;
      for (final rawRow in rawRows) {
        if (rawRow is! Map) continue;
        if (rows.length <= i) rows.add({});
        for (final entry in Map<String, dynamic>.from(rawRow).entries) {
          final rawStats = entry.value;
          if (rawStats is Map) {
            rows[i]
                .putIfAbsent(entry.key, _MetricStats.new)
                .mergeMessage(rawStats);
          }
        }
        i++;
      }
    }
  }

  SeedAverageResult build(
    SimulationConfig config,
    List<int> seeds,
  ) => SeedAverageResult(
    config: config,
    seeds: seeds,
    results: {
      for (final mode in modeKeys)
        mode: {
          for (final entry in metrics[mode]!.entries)
            entry.key: entry.value.average,
        },
    },
    sd: {
      for (final mode in modeKeys)
        mode: {
          for (final entry in metrics[mode]!.entries) entry.key: entry.value.sd,
        },
    },
    histories: {
      for (final mode in modeKeys)
        mode: [
          for (final row in histories[mode]!)
            {for (final entry in row.entries) entry.key: entry.value.average},
        ],
    },
  );
}
