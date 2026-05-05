import 'dart:convert';
import 'dart:math' as math;

const modeKeys = ['plain', 'skip', 'spring'];

const modeLabels = {'plain': '制御なし', 'skip': 'スキップ制御', 'spring': 'スプリング法'};

const noiseMeanFactor =
    0.24 * 0.5 + 0.76 * 0.22 * 0.5 + 0.035 * ((0.6 + 1.8) / 2);

double clampDouble(num value, num min, num max) =>
    math.max(min.toDouble(), math.min(max.toDouble(), value.toDouble()));

double mean(List<num> values) => values.isEmpty
    ? 0
    : values.fold<double>(0, (sum, value) => sum + value.toDouble()) /
          values.length;

double std(List<num> values) {
  if (values.length < 2) return 0;
  final m = mean(values);
  return math.sqrt(
    mean(values.map((value) => math.pow(value.toDouble() - m, 2)).toList()),
  );
}

double percentile(List<num> values, double p) {
  if (values.isEmpty) return 0;
  final ordered = values.map((e) => e.toDouble()).toList()..sort();
  final idx = clampDouble(
    (p / 100 * ordered.length).ceil() - 1,
    0,
    ordered.length - 1,
  ).toInt();
  return ordered[idx];
}

double positiveModulo(num value, num length) =>
    (((value % length) + length) % length).toDouble();

double _number(dynamic value, double fallback) {
  if (value is num && value.isFinite) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null && parsed.isFinite) return parsed;
  }
  return fallback;
}

bool _truthy(dynamic value, {bool fallback = false}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  final text = value.toString().toLowerCase();
  return !{'false', '0', 'no', 'off'}.contains(text);
}

bool _sweepStrictTrue(dynamic value) => value == true || value == 'true';

double legacyDelayScaleToMean(double baseTravelSec, double scaleSec) =>
    math.max(0, baseTravelSec * 0.02 + math.max(0, scaleSec) * noiseMeanFactor);

double delayMeanToScale(double meanSec) =>
    math.max(0, meanSec) / noiseMeanFactor;

class SimulationConfig {
  const SimulationConfig({
    required this.name,
    required this.seed,
    required this.durationMin,
    required this.stopCount,
    required this.busCount,
    required this.demandMultiplier,
    required this.capacity,
    required this.baseSpeedKmh,
    required this.stopDistanceKm,
    required this.boardTimeSec,
    required this.alightTimeSec,
    required this.randomDelayMeanSec,
    required this.hotspotStops,
    required this.hotspotMultiplier,
    required this.protectHotspotStops,
    required this.initialDelaySec,
    required this.distanceThresholdStops,
    required this.delayThresholdMin,
    required this.followerLoadLimit,
    required this.springGainSecPerStop,
    required this.springDeadbandStops,
    required this.springDamping,
    required this.springMaxHoldSec,
    required this.springMinHoldSec,
    required this.forbidHoldingWhenFull,
    required this.fixedStopSec,
    required this.boardingSetupSec,
    required this.alightingSetupSec,
    required this.crowdedExtraSec,
    required this.crowdingThreshold,
  });

  final String name;
  final int seed;
  final double durationMin;
  final int stopCount;
  final int busCount;
  final double demandMultiplier;
  final int capacity;
  final double baseSpeedKmh;
  final double stopDistanceKm;
  final double boardTimeSec;
  final double alightTimeSec;
  final double randomDelayMeanSec;
  final List<int> hotspotStops;
  final double hotspotMultiplier;
  final bool protectHotspotStops;
  final double initialDelaySec;
  final double distanceThresholdStops;
  final double delayThresholdMin;
  final double followerLoadLimit;
  final double springGainSecPerStop;
  final double springDeadbandStops;
  final double springDamping;
  final double springMaxHoldSec;
  final double springMinHoldSec;
  final bool forbidHoldingWhenFull;
  final double fixedStopSec;
  final double boardingSetupSec;
  final double alightingSetupSec;
  final double crowdedExtraSec;
  final double crowdingThreshold;

  int get durationSec => (durationMin * 60).round();
  double get baseTravelSec =>
      math.max(1e-9, stopDistanceKm / baseSpeedKmh * 3600);
  double get randomDelayScaleSec => delayMeanToScale(randomDelayMeanSec);
  double get baseStopSec => fixedStopSec;
  int get sampleIntervalSec => 15;
  int get waitWindowSec => 300;
  int get arrivalQuantumSec => 5;
  int get noiseBucketSec => 60;
  List<int> get forbiddenStops =>
      protectHotspotStops ? List<int>.from(hotspotStops) : const [];

  SimulationConfig copyWith({
    String? name,
    int? seed,
    double? durationMin,
    int? stopCount,
    int? busCount,
    double? demandMultiplier,
    int? capacity,
    double? baseSpeedKmh,
    double? stopDistanceKm,
    double? boardTimeSec,
    double? alightTimeSec,
    double? randomDelayMeanSec,
    List<int>? hotspotStops,
    double? hotspotMultiplier,
    bool? protectHotspotStops,
    double? initialDelaySec,
    double? distanceThresholdStops,
    double? delayThresholdMin,
    double? followerLoadLimit,
    double? springGainSecPerStop,
    double? springDeadbandStops,
    double? springDamping,
    double? springMaxHoldSec,
    double? springMinHoldSec,
    bool? forbidHoldingWhenFull,
    double? fixedStopSec,
    double? boardingSetupSec,
    double? alightingSetupSec,
    double? crowdedExtraSec,
    double? crowdingThreshold,
  }) => normalizeConfig({
    ...toJson(),
    if (name != null) 'name': name,
    if (seed != null) 'seed': seed,
    if (durationMin != null) 'durationMin': durationMin,
    if (stopCount != null) 'stopCount': stopCount,
    if (busCount != null) 'busCount': busCount,
    if (demandMultiplier != null) 'demandMultiplier': demandMultiplier,
    if (capacity != null) 'capacity': capacity,
    if (baseSpeedKmh != null) 'baseSpeedKmh': baseSpeedKmh,
    if (stopDistanceKm != null) 'stopDistanceKm': stopDistanceKm,
    if (boardTimeSec != null) 'boardTimeSec': boardTimeSec,
    if (alightTimeSec != null) 'alightTimeSec': alightTimeSec,
    if (randomDelayMeanSec != null) 'randomDelayMeanSec': randomDelayMeanSec,
    if (hotspotStops != null) 'hotspotStops': hotspotStops,
    if (hotspotMultiplier != null) 'hotspotMultiplier': hotspotMultiplier,
    if (protectHotspotStops != null) 'protectHotspotStops': protectHotspotStops,
    if (initialDelaySec != null) 'initialDelaySec': initialDelaySec,
    if (distanceThresholdStops != null)
      'distanceThresholdStops': distanceThresholdStops,
    if (delayThresholdMin != null) 'delayThresholdMin': delayThresholdMin,
    if (followerLoadLimit != null) 'followerLoadLimit': followerLoadLimit,
    if (springGainSecPerStop != null)
      'springGainSecPerStop': springGainSecPerStop,
    if (springDeadbandStops != null) 'springDeadbandStops': springDeadbandStops,
    if (springDamping != null) 'springDamping': springDamping,
    if (springMaxHoldSec != null) 'springMaxHoldSec': springMaxHoldSec,
    if (springMinHoldSec != null) 'springMinHoldSec': springMinHoldSec,
    if (forbidHoldingWhenFull != null)
      'forbidHoldingWhenFull': forbidHoldingWhenFull,
    if (fixedStopSec != null) 'fixedStopSec': fixedStopSec,
    if (boardingSetupSec != null) 'boardingSetupSec': boardingSetupSec,
    if (alightingSetupSec != null) 'alightingSetupSec': alightingSetupSec,
    if (crowdedExtraSec != null) 'crowdedExtraSec': crowdedExtraSec,
    if (crowdingThreshold != null) 'crowdingThreshold': crowdingThreshold,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'seed': seed,
    'durationMin': durationMin,
    'stopCount': stopCount,
    'busCount': busCount,
    'demandMultiplier': demandMultiplier,
    'capacity': capacity,
    'baseSpeedKmh': baseSpeedKmh,
    'stopDistanceKm': stopDistanceKm,
    'boardTimeSec': boardTimeSec,
    'alightTimeSec': alightTimeSec,
    'randomDelayMeanSec': randomDelayMeanSec,
    'hotspotStops': hotspotStops,
    'hotspotMultiplier': hotspotMultiplier,
    'protectHotspotStops': protectHotspotStops,
    'initialDelaySec': initialDelaySec,
    'distanceThresholdStops': distanceThresholdStops,
    'delayThresholdMin': delayThresholdMin,
    'followerLoadLimit': followerLoadLimit,
    'springGainSecPerStop': springGainSecPerStop,
    'springDeadbandStops': springDeadbandStops,
    'springDamping': springDamping,
    'springMaxHoldSec': springMaxHoldSec,
    'springMinHoldSec': springMinHoldSec,
    'forbidHoldingWhenFull': forbidHoldingWhenFull,
    'fixedStopSec': fixedStopSec,
    'boardingSetupSec': boardingSetupSec,
    'alightingSetupSec': alightingSetupSec,
    'crowdedExtraSec': crowdedExtraSec,
    'crowdingThreshold': crowdingThreshold,
    'durationSec': durationSec,
    'baseTravelSec': baseTravelSec,
    'randomDelayScaleSec': randomDelayScaleSec,
    'sampleIntervalSec': sampleIntervalSec,
    'waitWindowSec': waitWindowSec,
    'arrivalQuantumSec': arrivalQuantumSec,
    'noiseBucketSec': noiseBucketSec,
    'forbiddenStops': forbiddenStops,
  };

  static SimulationConfig fromJson(Map<String, dynamic> raw) =>
      normalizeConfig(raw);
}

SimulationConfig normalizeConfig(Map<String, dynamic> raw) {
  final stopCount = math.max(2, _number(raw['stopCount'], 20).round());
  final busCount = math.max(1, _number(raw['busCount'], 5).round());
  final baseSpeed = math.max(1e-9, _number(raw['baseSpeedKmh'], 15));
  final distance = math.max(1e-9, _number(raw['stopDistanceKm'], 0.3));
  final baseTravelSec = distance / baseSpeed * 3600;
  final legacyScale = _number(raw['randomDelaySec'], 26);
  final rawMean = _number(raw['randomDelayMeanSec'], double.nan);
  final hasLegacyStopKeys =
      raw.containsKey('stopManeuverLossSec') || raw.containsKey('doorTimeSec');
  final fixedStop = raw.containsKey('fixedStopSec')
      ? math.max(0, _number(raw['fixedStopSec'], 18))
      : hasLegacyStopKeys
      ? math.max(
          0,
          _number(raw['stopManeuverLossSec'], 0) +
              _number(raw['doorTimeSec'], 0),
        )
      : 10.0;
  final rawHotspots = raw['hotspotStops'];
  final hotspots = rawHotspots is Iterable
      ? rawHotspots
            .whereType<num>()
            .map((value) => value.toInt())
            .where((value) => value >= 0 && value < stopCount)
            .toList()
      : <int>[];
  return SimulationConfig(
    name: (raw['name'] ?? 'カスタム').toString(),
    seed: _number(raw['seed'], 1).round().clamp(1, 0x7fffffff),
    durationMin: math.max(1 / 60, _number(raw['durationMin'], 120)),
    stopCount: stopCount,
    busCount: busCount,
    demandMultiplier: math.max(0, _number(raw['demandMultiplier'], 0.8)),
    capacity: math.max(1, _number(raw['capacity'], 36).toInt()),
    baseSpeedKmh: baseSpeed,
    stopDistanceKm: distance,
    boardTimeSec: math.max(0, _number(raw['boardTimeSec'], 3)),
    alightTimeSec: math.max(0, _number(raw['alightTimeSec'], 3)),
    randomDelayMeanSec: math.max(
      0,
      rawMean.isFinite
          ? rawMean
          : legacyDelayScaleToMean(baseTravelSec, legacyScale),
    ),
    hotspotStops: hotspots,
    hotspotMultiplier: math.max(0, _number(raw['hotspotMultiplier'], 1)),
    protectHotspotStops: _sweepStrictTrue(raw['protectHotspotStops']),
    initialDelaySec: math.max(0, _number(raw['initialDelaySec'], 0)),
    distanceThresholdStops: math.max(
      0,
      _number(raw['distanceThresholdStops'], 1.8),
    ),
    delayThresholdMin: math.max(0, _number(raw['delayThresholdMin'], 0)),
    followerLoadLimit: math.max(0, _number(raw['followerLoadLimit'], 0.9)),
    springGainSecPerStop: math.max(0, _number(raw['springGainSecPerStop'], 18)),
    springDeadbandStops: math.max(0, _number(raw['springDeadbandStops'], 0.6)),
    springDamping: math.max(0, _number(raw['springDamping'], 0.06)),
    springMaxHoldSec: math.max(0, _number(raw['springMaxHoldSec'], 45)),
    springMinHoldSec: math.max(0, _number(raw['springMinHoldSec'], 8)),
    forbidHoldingWhenFull: _truthy(
      raw['forbidHoldingWhenFull'],
      fallback: true,
    ),
    fixedStopSec: fixedStop.toDouble(),
    boardingSetupSec: math.max(0, _number(raw['boardingSetupSec'], 2)),
    alightingSetupSec: math.max(0, _number(raw['alightingSetupSec'], 1)),
    crowdedExtraSec: math.max(0, _number(raw['crowdedExtraSec'], 5)),
    crowdingThreshold: _number(raw['crowdingThreshold'], 0.75),
  );
}

Map<String, dynamic> extractConfigPayload(Map<String, dynamic> payload) {
  final config = payload['config'] ?? payload['settings'] ?? payload;
  if (config is! Map) {
    throw const FormatException('config object not found');
  }
  return Map<String, dynamic>.from(config);
}

SimulationConfig configFromJsonText(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('JSON object expected');
  return normalizeConfig(
    extractConfigPayload(Map<String, dynamic>.from(decoded)),
  );
}

List<int> seedSequence({
  required int base,
  required int count,
  int step = 101,
}) => List<int>.generate(
  math.max(1, count),
  (index) => math.max(1, base) + index * step,
);

final presets = <String, SimulationConfig>{
  'urban': normalizeConfig({
    'name': '高頻度都市路線',
    'seed': 58021,
    'stopCount': 20,
    'busCount': 5,
    'durationMin': 120,
    'demandMultiplier': 0.8,
    'capacity': 36,
    'baseSpeedKmh': 15,
    'stopDistanceKm': 0.3,
    'boardTimeSec': 3,
    'alightTimeSec': 3,
    'randomDelayMeanSec': 28,
    'hotspotStops': [0, 7, 14],
    'hotspotMultiplier': 3,
    'protectHotspotStops': false,
    'initialDelaySec': 0,
    'distanceThresholdStops': 1.8,
    'delayThresholdMin': 5,
    'followerLoadLimit': 0.9,
    'springGainSecPerStop': 40,
    'springDeadbandStops': 1.2,
    'springDamping': 0,
    'springMaxHoldSec': 180,
    'springMinHoldSec': 20,
    'forbidHoldingWhenFull': true,
    'fixedStopSec': 13,
    'boardingSetupSec': 3.5,
    'alightingSetupSec': 3.5,
    'crowdedExtraSec': 4,
    'crowdingThreshold': 0.8,
  }),
  'calm': normalizeConfig({
    'name': '穏やかな需要',
    'seed': 18,
    'stopCount': 14,
    'busCount': 5,
    'durationMin': 80,
    'demandMultiplier': 0.42,
    'capacity': 62,
    'baseSpeedKmh': 20,
    'stopDistanceKm': 0.55,
    'boardTimeSec': 4,
    'alightTimeSec': 4,
    'randomDelaySec': 8,
    'hotspotStops': [4],
    'hotspotMultiplier': 1.2,
    'distanceThresholdStops': 1,
    'delayThresholdMin': 1.5,
    'followerLoadLimit': 0.78,
  }),
  'rush': normalizeConfig({
    'name': '通勤ラッシュ',
    'seed': 77,
    'stopCount': 18,
    'busCount': 7,
    'durationMin': 100,
    'demandMultiplier': 1.95,
    'capacity': 58,
    'baseSpeedKmh': 16,
    'stopDistanceKm': 0.45,
    'boardTimeSec': 4,
    'alightTimeSec': 4,
    'randomDelaySec': 34,
    'hotspotStops': [2, 3, 4, 5],
    'hotspotMultiplier': 2.2,
    'distanceThresholdStops': 1.3,
    'delayThresholdMin': 1,
    'followerLoadLimit': 0.86,
  }),
  'station': normalizeConfig({
    'name': '駅前集中',
    'seed': 91,
    'stopCount': 15,
    'busCount': 5,
    'durationMin': 90,
    'demandMultiplier': 1.65,
    'capacity': 54,
    'baseSpeedKmh': 18,
    'stopDistanceKm': 0.48,
    'boardTimeSec': 4,
    'alightTimeSec': 4,
    'randomDelaySec': 32,
    'hotspotStops': [5],
    'hotspotMultiplier': 5.2,
    'distanceThresholdStops': 1.2,
    'delayThresholdMin': 1.1,
    'followerLoadLimit': 0.82,
  }),
  'rain': normalizeConfig({
    'name': '雨の日',
    'seed': 123,
    'stopCount': 16,
    'busCount': 6,
    'durationMin': 90,
    'demandMultiplier': 1.35,
    'capacity': 54,
    'baseSpeedKmh': 15,
    'stopDistanceKm': 0.48,
    'boardTimeSec': 4,
    'alightTimeSec': 4,
    'randomDelaySec': 42,
    'hotspotStops': [3, 4],
    'hotspotMultiplier': 2.2,
    'distanceThresholdStops': 1.3,
    'delayThresholdMin': 1,
    'followerLoadLimit': 0.84,
  }),
  'suburban': normalizeConfig({
    'name': '低頻度郊外路線',
    'seed': 203,
    'stopCount': 18,
    'busCount': 3,
    'durationMin': 120,
    'demandMultiplier': 0.9,
    'capacity': 56,
    'baseSpeedKmh': 25,
    'stopDistanceKm': 0.9,
    'boardTimeSec': 4,
    'alightTimeSec': 4,
    'randomDelaySec': 18,
    'hotspotStops': [6],
    'hotspotMultiplier': 1.8,
    'distanceThresholdStops': 1.1,
    'delayThresholdMin': 2.5,
    'followerLoadLimit': 0.72,
  }),
  'important': normalizeConfig({
    'name': '重要停留所あり',
    'seed': 314,
    'stopCount': 17,
    'busCount': 6,
    'durationMin': 90,
    'demandMultiplier': 1.45,
    'capacity': 54,
    'baseSpeedKmh': 18,
    'stopDistanceKm': 0.5,
    'boardTimeSec': 4,
    'alightTimeSec': 4,
    'randomDelaySec': 28,
    'hotspotStops': [3, 8, 12],
    'hotspotMultiplier': 2.4,
    'distanceThresholdStops': 1.25,
    'delayThresholdMin': 1.2,
    'followerLoadLimit': 0.82,
  }),
};
