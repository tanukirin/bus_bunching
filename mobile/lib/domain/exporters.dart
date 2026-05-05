import 'dart:convert';

import 'config.dart';
import 'runner.dart';

String prettyJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

String exportConfigJson(SimulationConfig config) => prettyJson({
  'type': 'bus-bunching-config',
  'version': 1,
  'exportedAt': DateTime.now().toUtc().toIso8601String(),
  'config': config.toJson(),
});

String exportComparisonJson(ComparisonResult result) => prettyJson({
  'type': 'bus-bunching-results',
  'version': 1,
  'generatedAt': DateTime.now().toUtc().toIso8601String(),
  'config': result.config.toJson(),
  for (final mode in modeKeys)
    mode: {
      'metrics': result.results[mode]!.metrics,
      'history': result.results[mode]!.history,
    },
});

String exportMetricsCsv(ComparisonResult result) {
  final metricKeys = <String>{};
  for (final mode in modeKeys) {
    result.results[mode]!.metrics.forEach((key, value) {
      if (value is num) metricKeys.add(key);
    });
  }
  final rows = <List<Object?>>[
    ['metric', ...modeKeys],
    for (final key in metricKeys.toList()..sort())
      [
        key,
        for (final mode in modeKeys) result.results[mode]!.metrics[key] ?? '',
      ],
  ];
  return _csv(rows);
}

String exportSeedAverageJson(SeedAverageResult result) =>
    prettyJson(result.toJson());

String exportSeedAverageCsv(SeedAverageResult result) {
  final keys = <String>{};
  for (final mode in modeKeys) {
    result.results[mode]!.forEach((key, value) {
      if (value is num) keys.add(key);
    });
  }
  final rows = <List<Object?>>[
    ['seed_count', result.seeds.length],
    ['seeds', result.seeds.join(' ')],
    [],
    [
      'metric',
      'plain_mean',
      'skip_mean',
      'spring_mean',
      'plain_sd',
      'skip_sd',
      'spring_sd',
    ],
    for (final key in keys.toList()..sort())
      [
        key,
        result.results['plain']![key] ?? '',
        result.results['skip']![key] ?? '',
        result.results['spring']![key] ?? '',
        result.sd['plain']![key] ?? '',
        result.sd['skip']![key] ?? '',
        result.sd['spring']![key] ?? '',
      ],
  ];
  return _csv(rows);
}

SeedAverageResult seedAverageFromJsonText(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('JSON object expected');
  return _seedAverageFromMap(Map<String, dynamic>.from(decoded));
}

SeedAverageResult _seedAverageFromMap(Map<String, dynamic> payload) {
  final config = normalizeConfig(extractConfigPayload(payload));
  final source = Map<String, dynamic>.from(
    (payload['seedAverage'] ?? payload) as Map,
  );
  final seeds = (source['seeds'] as Iterable? ?? const [])
      .whereType<num>()
      .map((value) => value.toInt())
      .toList();
  if (seeds.isEmpty) throw const FormatException('seeds not found');
  final results = <String, Map<String, dynamic>>{};
  final sd = <String, Map<String, double>>{};
  final histories = <String, List<Map<String, dynamic>>>{};
  for (final mode in modeKeys) {
    final modeSource = Map<String, dynamic>.from(
      (source[mode] ?? const {}) as Map,
    );
    results[mode] = _metricAliases(
      Map<String, dynamic>.from(
        (modeSource['metrics'] ?? source['${mode}Metrics'] ?? const {}) as Map,
      ),
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
            .map((row) => _metricAliases(Map<String, dynamic>.from(row)))
            .toList();
  }
  return SeedAverageResult(
    config: config,
    seeds: seeds,
    results: results,
    sd: sd,
    histories: histories,
  );
}

Map<String, dynamic> _metricAliases(Map<String, dynamic> metrics) {
  const aliases = {
    'p95WaitMin': 'top5WaitMin',
    'p95TotalMin': 'top5TotalMin',
    'recentP95WaitMin': 'recentTop5WaitMin',
    'adjustedP95TotalMin': 'adjustedTop5TotalMin',
  };
  for (final entry in aliases.entries) {
    if (metrics.containsKey(entry.key) && !metrics.containsKey(entry.value)) {
      metrics[entry.value] = metrics[entry.key];
    }
  }
  return metrics;
}

String _csv(List<List<Object?>> rows) =>
    rows.map((row) => row.map(_cell).join(',')).join('\n');

String _cell(Object? value) => '"${'$value'.replaceAll('"', '""')}"';
