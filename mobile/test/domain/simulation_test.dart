import 'dart:math' as math;

import 'package:bus_bunching_mobile/domain/config.dart';
import 'package:bus_bunching_mobile/domain/exporters.dart';
import 'package:bus_bunching_mobile/domain/runner.dart';
import 'package:bus_bunching_mobile/domain/simulation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('demand events match browser fixture', () {
    final config = presets['urban']!.copyWith(seed: 238592, durationMin: 12);
    final events = EventGenerator.demandEvents(config);
    expect(events.length, 166);
    final expected = [
      (1, 1.3271661673206836, 12, 4),
      (2, 6.389238245319575, 8, 14),
      (3, 26.253447843482718, 3, 14),
      (4, 31.958891978720203, 3, 11),
      (5, 32.30320523609407, 8, 11),
      (6, 34.093348970636725, 19, 7),
      (7, 49.219705765135586, 5, 0),
      (8, 66.05392134282738, 7, 9),
    ];
    for (var i = 0; i < expected.length; i++) {
      expect(events[i].id, expected[i].$1);
      expect(events[i].time, closeTo(expected[i].$2, 1e-10));
      expect(events[i].origin, expected[i].$3);
      expect(events[i].dest, expected[i].$4);
    }
  });

  test('key metrics match browser fixture', () {
    final config = presets['urban']!.copyWith(seed: 238592, durationMin: 12);
    final result = runThreeModes(config);
    final expected = {
      'plain': {
        'completed': 7,
        'avgWaitMin': 1.9644084153203516,
        'adjustedAvgTotalMin': 20.422176172088463,
        'top5WaitMin': 5.299101310952877,
        'headwayRmseStops': 0.8351497839461504,
        'totalBlockedDelayMin': 0,
      },
      'skip': {
        'completed': 7,
        'avgWaitMin': 1.9644084153203516,
        'adjustedAvgTotalMin': 20.422176172088463,
        'top5WaitMin': 5.299101310952877,
        'headwayRmseStops': 0.8351497839461504,
        'totalBlockedDelayMin': 0,
      },
      'spring': {
        'completed': 9,
        'avgWaitMin': 2.722129185019596,
        'adjustedAvgTotalMin': 21.326322269928195,
        'top5WaitMin': 5.520424038008787,
        'headwayRmseStops': 0.7080757245257828,
        'totalSpringHoldMin': 2.700693258377259,
      },
    };
    for (final mode in expected.keys) {
      final metrics = result.results[mode]!.metrics;
      for (final entry in expected[mode]!.entries) {
        final actual = metrics[entry.key] as num;
        expect(
          actual.toDouble(),
          closeTo(entry.value.toDouble(), 1e-7),
          reason: '$mode.${entry.key}',
        );
      }
      expect(
        metrics.keys.any((key) => key.toLowerCase().contains('p95')),
        isFalse,
      );
    }
  });

  test('comparison runner shares demand events across modes', () {
    final runner = ComparisonRunner(presets['urban']!.copyWith(durationMin: 8));
    expect(
      identical(runner.sims['plain']!.events, runner.sims['skip']!.events),
      isTrue,
    );
    expect(
      identical(runner.sims['skip']!.events, runner.sims['spring']!.events),
      isTrue,
    );
  });

  test('comparison runner seek rebuilds deterministic state', () {
    final config = presets['urban']!.copyWith(seed: 456, durationMin: 20);
    final stepped = ComparisonRunner(config)..step(600);
    final sought = ComparisonRunner(config)..seekTo(600);
    expect(sought.time, stepped.time);
    for (final mode in modeKeys) {
      final a = stepped.sims[mode]!.computeMetrics();
      final b = sought.sims[mode]!.computeMetrics();
      expect(b['completed'], a['completed'], reason: '$mode.completed');
      expect(
        (b['adjustedAvgTotalMin'] as num).toDouble(),
        closeTo((a['adjustedAvgTotalMin'] as num).toDouble(), 1e-9),
        reason: '$mode.adjustedAvgTotalMin',
      );
      expect(
        (b['headwayRmseStops'] as num).toDouble(),
        closeTo((a['headwayRmseStops'] as num).toDouble(), 1e-9),
        reason: '$mode.headwayRmseStops',
      );
    }
  });

  test('no overtaking and one berth are preserved during stepping', () {
    final runner = ComparisonRunner(presets['rush']!.copyWith(durationMin: 20));
    for (var i = 0; i < 100; i++) {
      runner.step(5);
      for (final sim in runner.sims.values) {
        for (final stop in sim.stops) {
          final occupied = stop.occupiedByBusId;
          if (occupied != null) {
            expect(stop.blockedQueue.contains(occupied), isFalse);
          }
        }
        final ordered = [...sim.buses]..sort((a, b) => a.id.compareTo(b.id));
        for (var j = 1; j < ordered.length; j++) {
          expect(ordered[j].routePos <= ordered[j - 1].routePos + 1e-6, isTrue);
        }
      }
    }
  });

  test('adjusted total penalizes incomplete passengers', () {
    final metrics = runThreeModes(
      presets['urban']!.copyWith(
        seed: 12345,
        durationMin: 3,
        demandMultiplier: 2.2,
        initialDelaySec: 180,
      ),
      modes: const ['plain'],
      includeHistory: false,
    ).plain.metrics;
    expect(
      (metrics['allPassengers'] as int) - (metrics['completed'] as int),
      greaterThan(0),
    );
    expect(
      metrics['adjustedAvgTotalMin'] as double,
      greaterThanOrEqualTo(metrics['avgTotalMin'] as double),
    );
    expect(
      metrics['adjustedTop5TotalMin'] as double,
      greaterThanOrEqualTo(metrics['top5TotalMin'] as double),
    );
  });

  test('seed average computes mean and sd', () {
    final result = SeedAverageRunner.runSync(
      config: presets['urban']!.copyWith(durationMin: 4),
      baseSeed: 100,
      count: 3,
      includeHistory: false,
      engine: 'fast',
    );
    expect(result.seeds, [100, 201, 302]);
    expect(result.results['plain']!['avgWaitMin'], isA<double>());
    expect(result.sd['spring']!['headwayRmseStops'], isA<double>());
    expect(result.histories['plain'], isEmpty);
  });

  test('seed average JSON import does not map legacy p95 aliases', () {
    final json = '''
{
  "type": "bus-bunching-seed-average-results",
  "version": 1,
  "config": {
    "name": "fixture",
    "seed": 1,
    "durationMin": 1,
    "stopCount": 4,
    "busCount": 2
  },
  "seedAverage": {
    "seeds": [1],
    "plain": {"metrics": {"p95WaitMin": 9}, "sd": {}, "history": [{"t": 0, "p95WaitMin": 9}]},
    "skip": {"metrics": {}, "sd": {}, "history": []},
    "spring": {"metrics": {}, "sd": {}, "history": []}
  }
}
''';
    final result = seedAverageFromJsonText(json);
    expect(result.results['plain']!.containsKey('top5WaitMin'), isFalse);
    expect(result.results['plain']!['p95WaitMin'], 9);
    expect(
      result.histories['plain']!.first.containsKey('top5WaitMin'),
      isFalse,
    );
  });

  test('RNG remains deterministic', () {
    final a = SeededRng(42);
    final b = SeededRng(42);
    for (var i = 0; i < 20; i++) {
      expect(a.next(), b.next());
    }
    expect(a.next(), inInclusiveRange(0, 1));
    expect(math.max(0, a.poisson(0)), isA<int>());
  });
}
