import 'dart:math' as math;

import 'config.dart';

int _u32(int value) => value & 0xffffffff;

int _imul(int a, int b) => _u32(_u32(a) * _u32(b));

class SeededRng {
  SeededRng(num seed) : seed = _u32(seed.toInt()) == 0 ? 1 : _u32(seed.toInt());

  int seed;

  double next() {
    seed = _u32(seed + 0x6d2b79f5);
    var t = seed;
    t = _imul(t ^ (t >> 15), t | 1);
    t = _u32(t ^ _u32(t + _imul(t ^ (t >> 7), t | 61)));
    return _u32(t ^ (t >> 14)) / 4294967296;
  }

  double range(num min, num max) => min + (max - min) * next();

  int poisson(double lambda) {
    if (lambda <= 0) return 0;
    final limit = math.exp(-lambda);
    var k = 0;
    var p = 1.0;
    do {
      k++;
      p *= next();
    } while (p > limit);
    return k - 1;
  }
}

class DemandEvent {
  const DemandEvent({
    required this.id,
    required this.time,
    required this.origin,
    required this.dest,
  });

  final int id;
  final double time;
  final int origin;
  final int dest;

  Map<String, dynamic> toJson() => {
    'id': id,
    'time': time,
    'origin': origin,
    'dest': dest,
  };
}

class Passenger {
  Passenger({
    required this.id,
    required this.origin,
    required this.dest,
    required this.arrivalTime,
  });

  final int id;
  final int origin;
  final int dest;
  final double arrivalTime;
  double? boardTime;
  double? alightTime;
  int skipCount = 0;
  double? firstSkipTime;
  double? firstDeniedTime;
  List<Map<String, dynamic>> skippedAt = [];
  int deniedFullCount = 0;
  int fullDeniedAfterControlSkipCount = 0;
  int? lastFullDeniedBusId;
}

class StopState {
  StopState(this.id);

  final int id;
  int? occupiedByBusId;
  double serviceEndTime = 0;
  List<int> blockedQueue = [];
  double totalBlockedDelaySec = 0;
  int blockEvents = 0;
  double maxBlockedSec = 0;
  int maxQueue = 0;
  double totalOccupiedSec = 0;
}

class BusState {
  BusState({
    required this.id,
    required this.pos,
    required this.routePos,
    required this.routeSegmentStart,
    required this.fromStop,
    required this.targetStop,
    required this.status,
    required this.dwellRemaining,
    required this.segmentRemaining,
    required this.segmentDuration,
  });

  final int id;
  double pos;
  double routePos;
  int routeSegmentStart;
  int fromStop;
  int targetStop;
  String status;
  double dwellRemaining;
  double segmentRemaining;
  double segmentDuration;
  int segmentIndex = 0;
  List<Passenger> onboard = [];
  double delaySec = 0;
  double totalBlockedDelaySec = 0;
  int blockEvents = 0;
  int? blockedStopId;
  double? blockedStartTime;
  double blockedCurrentSec = 0;
  int? serviceStopId;
  double totalDwell = 0;
  int totalSkipped = 0;
  int springConsecutiveSkips = 0;
  double? springHoldStartTime;
  double? springHoldEndTime;
  double lastSpringSignal = 0;
  String lastAction = '通常';
  int? justSkippedStop;
  bool serviceBoardingOpen = true;
}

class EventGenerator {
  static List<DemandEvent> demandEvents(SimulationConfig config) {
    final rng = SeededRng(config.seed);
    final events = <DemandEvent>[];
    var id = 1;
    final baseRatePerMin = 0.23 * config.demandMultiplier;
    for (
      var t = 0.0;
      t <= config.durationSec + 1800;
      t += config.arrivalQuantumSec
    ) {
      final wave = 0.82 + 0.38 * math.sin((t / config.durationSec) * math.pi);
      for (var stop = 0; stop < config.stopCount; stop++) {
        final centerBias =
            0.75 + 0.35 * math.sin(((stop + 1) / config.stopCount) * math.pi);
        final hotspot = config.hotspotStops.contains(stop)
            ? config.hotspotMultiplier
            : 1.0;
        final rate = baseRatePerMin * wave * centerBias * hotspot;
        final count = rng.poisson(rate * config.arrivalQuantumSec / 60);
        for (var i = 0; i < count; i++) {
          final offset = rng.range(0, config.arrivalQuantumSec);
          final dest = chooseDestination(config, rng, stop);
          events.add(
            DemandEvent(id: id++, time: t + offset, origin: stop, dest: dest),
          );
        }
      }
    }
    events.sort((a, b) => a.time.compareTo(b.time));
    return events;
  }

  static int chooseDestination(
    SimulationConfig config,
    SeededRng rng,
    int origin,
  ) {
    final candidates = <({int stop, double weight})>[];
    for (var step = 1; step < config.stopCount; step++) {
      final stop = (origin + step) % config.stopCount;
      final important = config.hotspotStops.contains(stop);
      final nearTripBias = 1 / math.sqrt(step);
      final importantWeight = important
          ? math.max(2.5, config.hotspotMultiplier * 1.8)
          : 1.0;
      final downstreamHubBonus = important && step <= config.stopCount * 0.75
          ? 1.4
          : 1.0;
      candidates.add((
        stop: stop,
        weight: nearTripBias * importantWeight * downstreamHubBonus,
      ));
    }
    final total = candidates.fold<double>(0, (sum, item) => sum + item.weight);
    var pick = rng.range(0, total);
    for (final candidate in candidates) {
      pick -= candidate.weight;
      if (pick <= 0) return candidate.stop;
    }
    return candidates.last.stop;
  }

  static double travelNoise(
    SimulationConfig config,
    int fromStop,
    double startTimeSec,
  ) {
    final bucket = (startTimeSec / math.max(1, config.noiseBucketSec)).floor();
    final rng = SeededRng(
      config.seed * 100003 + fromStop * 9176 + bucket * 7919,
    );
    final scale = config.randomDelayScaleSec;
    final jitter = rng.range(-0.1, 0.1) * config.baseTravelSec;
    final signal = rng.next() < 0.24
        ? rng.range(0, scale)
        : rng.range(0, scale * 0.22);
    final surge = rng.next() < 0.035
        ? rng.range(scale * 0.6, scale * 1.8)
        : 0.0;
    return math.max(-config.baseTravelSec * 0.18, jitter + signal + surge);
  }
}

class SimulationEngine {
  SimulationEngine(
    this.config,
    this.mode,
    this.events, {
    this.includeHistory = true,
    this.engine = 'audit',
  }) {
    controlEnabled = mode != 'plain';
    springEnabled = mode == 'spring';
    waiting = List<List<Passenger>>.generate(config.stopCount, (_) => []);
    stops = List<StopState>.generate(config.stopCount, StopState.new);
    buses = _createBuses();
  }

  final SimulationConfig config;
  final String mode;
  final List<DemandEvent> events;
  final bool includeHistory;
  final String engine;

  late final bool controlEnabled;
  late final bool springEnabled;
  late final List<List<Passenger>> waiting;
  late final List<StopState> stops;
  late final List<BusState> buses;
  int eventIndex = 0;
  double time = 0;
  final completed = <Passenger>[];
  final allPassengers = <int, Passenger>{};
  final history = <Map<String, dynamic>>[];
  final skipLog = <Map<String, dynamic>>[];
  final fullPassLog = <Map<String, dynamic>>[];
  final blockLog = <Map<String, dynamic>>[];
  final springHoldLog = <Map<String, dynamic>>[];
  final springSignalLog = <Map<String, dynamic>>[];
  bool bunchActive = false;
  int bunchStarts = 0;
  double bunchDuration = 0;
  double blockedDuringBunchSec = 0;
  int closePairEvents = 0;
  double totalDwell = 0;
  int serviceStopCount = 0;
  double totalSpringHoldSec = 0;
  double maxSpringHoldSec = 0;
  int springControlSkipAssistEvents = 0;
  double totalBlockedDelaySec = 0;
  int blockEvents = 0;
  double maxBlockedSec = 0;
  double? lastSampleTime;

  List<BusState> _createBuses() {
    final out = <BusState>[];
    final spacing = config.stopCount / config.busCount;
    for (var i = 0; i < config.busCount; i++) {
      final routePos = -i * spacing;
      final pos = positiveModulo(routePos, config.stopCount);
      final routeSegmentStart = routePos.floor();
      final stop = positiveModulo(routeSegmentStart, config.stopCount).toInt();
      final initialDelay = i == 0 && config.initialDelaySec > 0;
      final bus = BusState(
        id: i + 1,
        pos: pos,
        routePos: routePos,
        routeSegmentStart: routeSegmentStart,
        fromStop: stop,
        targetStop: (stop + 1) % config.stopCount,
        status: initialDelay ? 'dwelling' : 'moving',
        dwellRemaining: initialDelay ? config.initialDelaySec : 0,
        segmentRemaining: math.max(
          1e-9,
          config.baseTravelSec * (1 - (routePos - routeSegmentStart)),
        ),
        segmentDuration: config.baseTravelSec,
      )..delaySec = i == 0 ? config.initialDelaySec : 0;
      if (initialDelay) {
        bus.serviceStopId = stop;
        occupyStop(stop, bus.id, config.initialDelaySec);
      } else {
        startSegment(bus, stop, false);
        final progress = routePos - routeSegmentStart;
        bus.segmentRemaining = bus.segmentDuration * (1 - progress);
        bus.routePos = routePos;
        bus.pos = positiveModulo(routePos, config.stopCount);
      }
      out.add(bus);
    }
    return out;
  }

  void startSegment(BusState bus, int fromStop, [bool advanceCounter = true]) {
    if (advanceCounter) bus.segmentIndex++;
    final routeStart = bus.routePos.isFinite ? bus.routePos.floor() : fromStop;
    final circularFrom = positiveModulo(routeStart, config.stopCount).toInt();
    final duration = math.max(
      18,
      config.baseTravelSec +
          EventGenerator.travelNoise(config, circularFrom, time),
    );
    bus
      ..routeSegmentStart = routeStart
      ..fromStop = circularFrom
      ..targetStop = positiveModulo(routeStart + 1, config.stopCount).toInt()
      ..segmentDuration = duration.toDouble()
      ..segmentRemaining = duration.toDouble()
      ..routePos = routeStart.toDouble()
      ..pos = positiveModulo(routeStart, config.stopCount)
      ..status = 'moving'
      ..blockedStopId = null
      ..blockedStartTime = null
      ..blockedCurrentSec = 0
      ..serviceStopId = null
      ..springHoldStartTime = null
      ..springHoldEndTime = null
      ..serviceBoardingOpen = true
      ..lastAction = '走行';
  }

  void addArrivals(double untilTime) {
    while (eventIndex < events.length && events[eventIndex].time <= untilTime) {
      final event = events[eventIndex++];
      final passenger = Passenger(
        id: event.id,
        origin: event.origin,
        dest: event.dest,
        arrivalTime: event.time,
      );
      allPassengers[passenger.id] = passenger;
      waiting[event.origin].add(passenger);
    }
  }

  void step(double dt) {
    final nextTime = math.min(config.durationSec.toDouble(), time + dt);
    addArrivals(nextTime);
    final actualDt = nextTime - time;
    for (final bus in buses) {
      bus.justSkippedStop = null;
      if (bus.status == 'dwelling') {
        bus.dwellRemaining -= actualDt;
        bus.delaySec += actualDt;
        boardDuringDwell(bus, nextTime);
        if (bus.dwellRemaining <= 0) {
          releaseStop(bus.serviceStopId, bus.id);
          startSegment(bus, bus.fromStop);
        }
      } else if (bus.status == 'blocked') {
        updateBlockedBus(bus, actualDt);
      } else {
        final proposedRemaining = bus.segmentRemaining - actualDt;
        final proposedProgress = clampDouble(
          1 - proposedRemaining / bus.segmentDuration,
          0,
          1,
        );
        final proposedRoutePos = bus.routeSegmentStart + proposedProgress;
        final maxRoutePos = maxRoutePosBeforeLeader(bus);
        final cappedRoutePos = math.min(proposedRoutePos, maxRoutePos);
        final capped = cappedRoutePos < proposedRoutePos - 1e-6;
        bus.routePos = cappedRoutePos;
        bus.pos = positiveModulo(bus.routePos, config.stopCount);
        final remainingRatio = clampDouble(
          bus.routeSegmentStart + 1 - bus.routePos,
          0,
          1,
        );
        bus.segmentRemaining = remainingRatio * bus.segmentDuration;
        final idealTravel = config.baseTravelSec;
        final actualTravel =
            config.baseTravelSec +
            math.max(0, bus.segmentDuration - idealTravel);
        bus.delaySec += math.max(
          0,
          (actualTravel - idealTravel) /
              math.max(1, bus.segmentDuration) *
              actualDt,
        );
        if (capped) {
          bus.delaySec += actualDt;
          bus.lastAction = '前車追従';
        }
        bus.delaySec = math.max(0, bus.delaySec - actualDt * 0.14);
        if (!capped && proposedRemaining <= 0) {
          bus.routePos = (bus.routeSegmentStart + 1).toDouble();
          bus.pos = bus.targetStop.toDouble();
          handleArrival(bus, bus.targetStop);
        }
      }
    }
    time = nextTime;
    final lastSample = lastSampleTime ?? 0;
    if ((includeHistory || engine == 'audit') &&
        (time - lastSample >= config.sampleIntervalSec ||
            time >= config.durationSec)) {
      sample();
    }
  }

  double nextFastDt() {
    final remaining = config.durationSec - time;
    if (remaining <= 0) return 0;
    final candidates = <double>[remaining, 5];
    if (eventIndex < events.length) {
      candidates.add(math.max(0.25, events[eventIndex].time - time));
    }
    for (final bus in buses) {
      if (bus.status == 'dwelling') {
        candidates.add(math.max(0.25, bus.dwellRemaining));
      } else if (bus.status == 'moving') {
        candidates.add(math.max(0.25, bus.segmentRemaining));
      } else if (bus.status == 'blocked' && bus.blockedStopId != null) {
        final stop = stops[bus.blockedStopId!];
        candidates.add(
          stop.occupiedByBusId != null
              ? math.max(0.25, stop.serviceEndTime - time)
              : 0.25,
        );
      }
    }
    if (includeHistory) {
      final lastSample = lastSampleTime ?? 0;
      candidates.add(
        math.max(0.25, lastSample + config.sampleIntervalSec - time),
      );
    }
    return math.max(
      0.25,
      candidates.where((value) => value.isFinite && value > 0).reduce(math.min),
    );
  }

  double maxRoutePosBeforeLeader(BusState bus) {
    const epsilon = 0.012;
    final ordered = [...buses]..sort((a, b) => a.id.compareTo(b.id));
    final index = ordered.indexWhere((item) => item.id == bus.id);
    if (index < 0) return double.infinity;
    final leader = index == 0 ? ordered.last : ordered[index - 1];
    final leaderRoutePos = index == 0
        ? leader.routePos + config.stopCount
        : leader.routePos;
    final targetRoutePos = bus.routeSegmentStart + 1;
    final targetStop = positiveModulo(targetRoutePos, config.stopCount).toInt();
    final leaderAtTarget =
        leader.status == 'dwelling' && leader.serviceStopId == targetStop;
    final berthBlocked =
        stops[targetStop].occupiedByBusId != null ||
        stops[targetStop].blockedQueue.isNotEmpty;
    if (targetRoutePos <= leaderRoutePos + 1e-6 &&
        (leaderAtTarget || berthBlocked)) {
      return targetRoutePos.toDouble();
    }
    return leaderRoutePos - epsilon;
  }

  void handleArrival(BusState bus, int stop) {
    final berth = stops[stop];
    if (berth.occupiedByBusId != null && berth.occupiedByBusId != bus.id) {
      enterBlocked(bus, stop);
      return;
    }
    beginService(bus, stop);
  }

  void beginService(BusState bus, int stop) {
    removeFromBlockedQueue(bus, stop);
    finishBlockedIfNeeded(bus, stop);
    bus
      ..routePos = bus.routePos.roundToDouble()
      ..pos = stop.toDouble();
    final alighting = <Passenger>[];
    final staying = <Passenger>[];
    for (final passenger in bus.onboard) {
      (passenger.dest == stop ? alighting : staying).add(passenger);
    }
    bus.onboard = staying;
    for (final passenger in alighting) {
      passenger.alightTime = time;
      completed.add(passenger);
    }

    final decision = controlDecision(bus, stop, alighting.length);
    var boarded = 0;
    if (decision['skip'] == true) {
      final skippedNow = waiting[stop].length;
      for (final passenger in waiting[stop]) {
        passenger.skipCount++;
        passenger.firstSkipTime ??= time;
        passenger.firstDeniedTime ??= time;
        passenger.skippedAt.add({'time': time, 'stop': stop, 'busId': bus.id});
      }
      bus.totalSkipped += skippedNow;
      bus.lastAction = decision['assist'] == true ? '補助スキップ' : '降車のみ';
      bus.justSkippedStop = stop;
      if (decision['assist'] == true) {
        bus.springConsecutiveSkips++;
        springControlSkipAssistEvents++;
      }
      skipLog.add({
        'time': time,
        'stop': stop,
        'busId': bus.id,
        'passengers': skippedNow,
        'reason': decision['reason'],
        'assist': decision['assist'] == true,
      });
    } else {
      bus.springConsecutiveSkips = 0;
      final queue = waiting[stop];
      final capacityLeft = config.capacity - bus.onboard.length;
      final boardCount = clampDouble(capacityLeft, 0, queue.length).toInt();
      for (var i = 0; i < boardCount; i++) {
        final passenger = queue.removeAt(0);
        passenger.boardTime = time;
        bus.onboard.add(passenger);
        boarded++;
      }
      if (queue.isNotEmpty) {
        for (final passenger in queue) {
          recordFullDenial(passenger, bus.id, time);
        }
        fullPassLog.add({
          'time': time,
          'stop': stop,
          'busId': bus.id,
          'passengers': queue.length,
        });
      }
      bus.lastAction = boarded > 0 || alighting.isNotEmpty
          ? '乗$boarded 降${alighting.length}'
          : '停車短';
    }

    final baseDwell = calculateDwellTime(
      bus,
      boarded,
      alighting.length,
      decision['skip'] == true,
    );
    var holdSec = math.max(0.0, (decision['holdSec'] as num? ?? 0).toDouble());
    if (holdSec > 0 &&
        config.forbidHoldingWhenFull &&
        bus.onboard.length >= config.capacity) {
      holdSec = 0;
    }
    final dwell = baseDwell + holdSec;
    bus.serviceBoardingOpen = decision['skip'] != true;
    if (holdSec > 0) {
      bus
        ..lastAction = 'スプリング保持 ${holdSec.toStringAsFixed(0)}秒'
        ..springHoldStartTime = time + baseDwell
        ..springHoldEndTime = time + dwell;
      totalSpringHoldSec += holdSec;
      maxSpringHoldSec = math.max(maxSpringHoldSec, holdSec);
      springHoldLog.add({
        'time': time,
        'stop': stop,
        'busId': bus.id,
        'holdSec': holdSec,
        'signal': decision['springSignal'],
        'hFront': decision['hFront'],
        'hBack': decision['hBack'],
      });
    }
    bus
      ..totalDwell += dwell
      ..fromStop = stop
      ..routePos = bus.routePos.roundToDouble()
      ..routeSegmentStart = bus.routePos.round()
      ..pos = stop.toDouble();
    totalDwell += dwell;
    if (dwell > 0) {
      serviceStopCount++;
      occupyStop(stop, bus.id, dwell);
      bus
        ..status = 'dwelling'
        ..dwellRemaining = dwell
        ..serviceStopId = stop;
    } else {
      startSegment(bus, stop);
    }
  }

  void boardDuringDwell(BusState bus, double currentTime) {
    final stop = bus.serviceStopId;
    if (stop == null || !bus.serviceBoardingOpen) return;
    final queue = waiting[stop];
    if (queue.isEmpty) return;
    var boarded = 0;
    while (queue.isNotEmpty &&
        bus.onboard.length < config.capacity &&
        queue.first.arrivalTime <= currentTime + 1e-9) {
      final passenger = queue.removeAt(0);
      passenger.boardTime = math.max(passenger.arrivalTime, time);
      bus.onboard.add(passenger);
      boarded++;
    }
    if (boarded > 0) bus.lastAction = '停車中乗車 $boarded';
    if (queue.isNotEmpty && bus.onboard.length >= config.capacity) {
      var deniedNow = 0;
      for (final passenger in queue) {
        if (passenger.arrivalTime <= currentTime + 1e-9 &&
            passenger.lastFullDeniedBusId != bus.id) {
          recordFullDenial(passenger, bus.id, passenger.arrivalTime);
          deniedNow++;
        }
      }
      if (deniedNow > 0) {
        fullPassLog.add({
          'time': currentTime,
          'stop': stop,
          'busId': bus.id,
          'passengers': deniedNow,
        });
      }
    }
    if (config.forbidHoldingWhenFull && bus.onboard.length >= config.capacity) {
      cancelSpringHoldForFullBus(bus, currentTime);
    }
  }

  void recordFullDenial(Passenger passenger, int busId, double deniedTime) {
    passenger.deniedFullCount += 1;
    passenger.lastFullDeniedBusId = busId;
    passenger.firstDeniedTime ??= deniedTime;
    if (passenger.skipCount > 0) passenger.fullDeniedAfterControlSkipCount++;
  }

  void cancelSpringHoldForFullBus(BusState bus, double currentTime) {
    if (bus.springHoldStartTime == null || bus.springHoldEndTime == null)
      return;
    final oldEnd = bus.springHoldEndTime!;
    final newEnd = math.max(
      bus.springHoldStartTime!,
      math.min(currentTime, oldEnd),
    );
    if (newEnd >= oldEnd - 1e-9) return;
    final cancelled = oldEnd - newEnd;
    bus
      ..springHoldEndTime = newEnd
      ..dwellRemaining = math.min(
        bus.dwellRemaining,
        math.max(0, newEnd - currentTime),
      )
      ..totalDwell = math.max(0, bus.totalDwell - cancelled);
    totalSpringHoldSec = math.max(0, totalSpringHoldSec - cancelled);
    totalDwell = math.max(0, totalDwell - cancelled);
    if (bus.serviceStopId != null) {
      final stop = stops[bus.serviceStopId!];
      if (stop.occupiedByBusId == bus.id)
        stop.serviceEndTime = math.min(stop.serviceEndTime, newEnd);
      stop.totalOccupiedSec = math.max(0, stop.totalOccupiedSec - cancelled);
    }
    for (var i = springHoldLog.length - 1; i >= 0; i--) {
      final row = springHoldLog[i];
      if (row['busId'] == bus.id && row['stop'] == bus.serviceStopId) {
        row['holdSec'] = math.max(0, newEnd - bus.springHoldStartTime!);
        row['cancelledByFull'] = true;
        break;
      }
    }
    maxSpringHoldSec = springHoldLog.fold<double>(
      0,
      (maxValue, row) =>
          math.max(maxValue, (row['holdSec'] as num? ?? 0).toDouble()),
    );
  }

  double calculateDwellTime(
    BusState bus,
    int boarded,
    int alighted,
    bool skip,
  ) {
    if (boarded == 0 && alighted == 0) return 0;
    if (skip && alighted == 0) return 0;
    final loadRatio = bus.onboard.length / math.max(1, config.capacity);
    final crowdedExtra = loadRatio >= config.crowdingThreshold
        ? config.crowdedExtraSec
        : 0.0;
    final boardingProcess = boarded > 0
        ? config.boardingSetupSec + crowdedExtra + boarded * config.boardTimeSec
        : 0.0;
    final alightingProcess = alighted > 0
        ? config.alightingSetupSec +
              crowdedExtra +
              alighted * config.alightTimeSec
        : 0.0;
    return config.fixedStopSec + boardingProcess + alightingProcess;
  }

  void occupyStop(int stopId, int busId, double dwellSec) {
    stops[stopId]
      ..occupiedByBusId = busId
      ..serviceEndTime = time + dwellSec
      ..totalOccupiedSec += dwellSec;
  }

  void releaseStop(int? stopId, int busId) {
    if (stopId == null) return;
    final stop = stops[stopId];
    if (stop.occupiedByBusId == busId) {
      stop
        ..occupiedByBusId = null
        ..serviceEndTime = time;
    }
  }

  void enterBlocked(BusState bus, int stopId) {
    final stop = stops[stopId];
    if (!stop.blockedQueue.contains(bus.id)) {
      stop.blockedQueue.add(bus.id);
      stop.maxQueue = math.max(stop.maxQueue, stop.blockedQueue.length);
    }
    bus
      ..status = 'blocked'
      ..blockedStopId = stopId
      ..blockedStartTime = time
      ..blockedCurrentSec = 0
      ..segmentRemaining = 0
      ..routePos = bus.routePos.round() - 0.08
      ..pos = positiveModulo(bus.routePos, config.stopCount)
      ..lastAction = '前車待ち';
  }

  void updateBlockedBus(BusState bus, double dt) {
    final stopId = bus.blockedStopId;
    if (stopId == null) return;
    final stop = stops[stopId];
    if (stop.occupiedByBusId == null &&
        stop.blockedQueue.isNotEmpty &&
        stop.blockedQueue.first == bus.id) {
      beginService(bus, stopId);
      return;
    }
    bus
      ..blockedCurrentSec += dt
      ..totalBlockedDelaySec += dt
      ..delaySec += dt;
    totalBlockedDelaySec += dt;
    stop.totalBlockedDelaySec += dt;
  }

  void removeFromBlockedQueue(BusState bus, int stopId) {
    stops[stopId].blockedQueue.remove(bus.id);
  }

  void finishBlockedIfNeeded(BusState bus, int stopId) {
    if (bus.blockedStartTime == null) return;
    final duration = math.max(0.0, time - bus.blockedStartTime!);
    final stop = stops[stopId];
    bus.blockEvents++;
    blockEvents++;
    maxBlockedSec = math.max(maxBlockedSec, duration);
    stop.blockEvents += 1;
    stop.maxBlockedSec = math.max(stop.maxBlockedSec, duration);
    blockLog.add({
      'time': time,
      'stop': stopId,
      'busId': bus.id,
      'duration': duration,
    });
    bus
      ..blockedStartTime = null
      ..blockedCurrentSec = 0
      ..blockedStopId = null;
  }

  Map<String, dynamic> controlDecision(
    BusState bus,
    int stop, [
    int alightingCount = 0,
  ]) {
    if (!controlEnabled)
      return {'skip': false, 'holdSec': 0.0, 'reason': 'control off'};
    if (springEnabled) return springDecision(bus, stop, alightingCount);
    return distanceSkipDecision(bus, stop, alightingCount, false);
  }

  Map<String, dynamic> distanceSkipDecision(
    BusState bus,
    int stop, [
    int alightingCount = 0,
    bool assist = false,
  ]) {
    if (waiting[stop].isEmpty && alightingCount == 0)
      return {'skip': false, 'holdSec': 0.0, 'reason': 'no demand'};
    if (config.forbiddenStops.contains(stop))
      return {'skip': false, 'holdSec': 0.0, 'reason': 'forbidden stop'};
    if (bus.delaySec < config.delayThresholdMin * 60)
      return {'skip': false, 'holdSec': 0.0, 'reason': 'delay small'};
    final follower = findFollower(bus);
    if (follower == null)
      return {'skip': false, 'holdSec': 0.0, 'reason': 'no follower'};
    final followerLoad = follower.onboard.length / config.capacity;
    if (followerLoad > config.followerLoadLimit)
      return {'skip': false, 'holdSec': 0.0, 'reason': 'follower crowded'};
    final distanceBehind = routeDistanceBehind(follower, bus);
    return {
      'skip': distanceBehind <= config.distanceThresholdStops,
      'holdSec': 0.0,
      'assist': assist,
      'reason': 'behind=${distanceBehind.toStringAsFixed(2)}',
    };
  }

  Map<String, dynamic> springDecision(
    BusState bus,
    int stop, [
    int alightingCount = 0,
  ]) {
    final ctx = headwayContext(bus);
    bus.lastSpringSignal = ctx['springSignal']!;
    springSignalLog.add({'time': time, 'busId': bus.id, 'stop': stop, ...ctx});
    final h = ctx['idealHeadwayStops']!;
    final deadband = config.springDeadbandStops;
    final holdCandidate =
        ctx['springSignal']! < -deadband &&
        ctx['hFront']! < h &&
        ctx['hBack']! > h;
    if (holdCandidate) {
      if (config.forbidHoldingWhenFull &&
          bus.onboard.length >= config.capacity) {
        return {
          'skip': false,
          'holdSec': 0.0,
          'reason': 'full bus holding forbidden',
          ...ctx,
        };
      }
      final holdSec = clampDouble(
        (-ctx['springSignal']! - deadband) * config.springGainSecPerStop -
            config.springDamping * bus.delaySec,
        0,
        config.springMaxHoldSec,
      );
      if (holdSec >= config.springMinHoldSec) {
        return {
          'skip': false,
          'holdSec': holdSec,
          'reason': 'spring hold',
          ...ctx,
        };
      }
    }
    final skipCandidate =
        ctx['springSignal']! > math.max(deadband, 0.5) &&
        ctx['hFront']! > h &&
        ctx['hBack']! < h;
    if (!skipCandidate)
      return {
        'skip': false,
        'holdSec': 0.0,
        'reason': 'spring neutral',
        ...ctx,
      };
    final base = distanceSkipDecision(bus, stop, alightingCount, true);
    if (base['skip'] != true) return {...base, 'assist': false};
    if (!springSkipImprovesHeadway(bus, stop, alightingCount)) {
      return {'skip': false, 'holdSec': 0.0, 'reason': 'spring headway cost'};
    }
    return {...base, 'assist': true, ...ctx};
  }

  Map<String, double> headwayContext(BusState bus) {
    final leader = findLeader(bus);
    final follower = findFollower(bus);
    final hFront = leader == null
        ? config.stopCount.toDouble()
        : routeDistanceAhead(bus, leader);
    final hBack = follower == null
        ? config.stopCount.toDouble()
        : routeDistanceBehind(follower, bus);
    final ideal = config.stopCount / config.busCount;
    return {
      'hFront': hFront,
      'hBack': hBack,
      'idealHeadwayStops': ideal,
      'springSignal': hFront - hBack,
    };
  }

  bool springSkipImprovesHeadway(BusState bus, int stop, int alightingCount) {
    final capacityLeft = math.max(0, config.capacity - bus.onboard.length);
    final boardedIfNormal = math.min(capacityLeft, waiting[stop].length);
    final savedDwell = calculateDwellTime(
      bus,
      boardedIfNormal,
      alightingCount,
      false,
    );
    final forwardStops = clampDouble(
      savedDwell / math.max(1, config.baseTravelSec),
      0,
      config.stopCount / 2,
    );
    if (forwardStops <= 0) return true;
    return headwayErrorCost(bus.id, forwardStops) < headwayErrorCost();
  }

  double headwayErrorCost([int? busId, double forwardStops = 0]) {
    final ideal = config.stopCount / config.busCount;
    final positions =
        buses
            .map(
              (bus) => positiveModulo(
                bus.pos + (bus.id == busId ? forwardStops : 0),
                config.stopCount,
              ),
            )
            .toList()
          ..sort();
    var cost = 0.0;
    for (var i = 0; i < positions.length; i++) {
      final gap = positiveModulo(
        positions[(i + 1) % positions.length] - positions[i],
        config.stopCount,
      );
      cost += math.pow(gap - ideal, 2).toDouble();
    }
    return cost;
  }

  BusState? findFollower(BusState bus) {
    BusState? best;
    var bestDist = double.infinity;
    for (final other in buses) {
      if (other.id == bus.id) continue;
      final dist = routeDistanceBehind(other, bus);
      if (dist > 0.01 && dist < bestDist) {
        best = other;
        bestDist = dist;
      }
    }
    return best;
  }

  BusState? findLeader(BusState bus) {
    BusState? best;
    var bestDist = double.infinity;
    for (final other in buses) {
      if (other.id == bus.id) continue;
      final dist = routeDistanceAhead(bus, other);
      if (dist > 0.01 && dist < bestDist) {
        best = other;
        bestDist = dist;
      }
    }
    return best;
  }

  double routeDistanceAhead(BusState bus, BusState leader) {
    var dist = leader.routePos - bus.routePos;
    while (dist <= 0) {
      dist += config.stopCount;
    }
    return dist;
  }

  double routeDistanceBehind(BusState follower, BusState leader) {
    var dist = leader.routePos - follower.routePos;
    while (dist <= 0) {
      dist += config.stopCount;
    }
    return dist;
  }

  double stopsAhead(num origin, num dest) =>
      positiveModulo(dest - origin, config.stopCount);

  List<double> headways() {
    final positions = buses.map((bus) => bus.pos).toList()..sort();
    return [
      for (var i = 0; i < positions.length; i++)
        positiveModulo(
          positions[(i + 1) % positions.length] - positions[i],
          config.stopCount,
        ),
    ];
  }

  ({double expectedStopSec, double averageDwellSec}) expectedStopToStopSec() {
    final averageDwellSec = totalDwell / math.max(1, serviceStopCount);
    return (
      expectedStopSec:
          config.baseTravelSec + config.randomDelayMeanSec + averageDwellSec,
      averageDwellSec: averageDwellSec,
    );
  }

  double busArrivalToStopSec(BusState bus, int stop, double expectedStopSec) {
    if (bus.status == 'moving') {
      return math.max(0.0, bus.segmentRemaining) +
          stopsAhead(bus.targetStop, stop) * expectedStopSec;
    }
    if (bus.status == 'dwelling') {
      final dwell = math.max(0.0, bus.dwellRemaining);
      if (bus.serviceStopId == stop) return dwell;
      return dwell + stopsAhead(bus.pos, stop) * expectedStopSec;
    }
    if (bus.status == 'blocked' && bus.blockedStopId != null) {
      final berth = stops[bus.blockedStopId!];
      final blockedWait = berth.occupiedByBusId != null
          ? math.max(0.0, berth.serviceEndTime - time)
          : 0.0;
      if (bus.blockedStopId == stop) return blockedWait;
      return blockedWait +
          stopsAhead(bus.blockedStopId!, stop) * expectedStopSec;
    }
    return stopsAhead(bus.pos, stop) * expectedStopSec;
  }

  double minBusArrivalToStopSec(int stop, double expectedStopSec) => buses
      .map((bus) => busArrivalToStopSec(bus, stop, expectedStopSec))
      .reduce(math.min);

  ({List<double> values, double expectedStopSec, double averageDwellSec})
  adjustedTotalTimesMin() {
    final expected = expectedStopToStopSec();
    final expectedStopSec = expected.expectedStopSec;
    final idealHeadwaySec =
        (config.stopCount / math.max(1, config.busCount)) * expectedStopSec;
    final capacity = math.max(1, config.capacity);
    final values = <double>[];
    final seen = <int>{};
    for (final passenger in completed) {
      if (passenger.alightTime != null) {
        values.add(
          math.max(0, passenger.alightTime! - passenger.arrivalTime) / 60,
        );
        seen.add(passenger.id);
      }
    }
    for (final bus in buses) {
      for (final passenger in bus.onboard) {
        if (seen.contains(passenger.id)) continue;
        final elapsed = math.max(0, time - passenger.arrivalTime);
        values.add(
          (elapsed + stopsAhead(bus.pos, passenger.dest) * expectedStopSec) /
              60,
        );
        seen.add(passenger.id);
      }
    }
    final minArrivalCache = <int, double>{};
    for (var origin = 0; origin < waiting.length; origin++) {
      final queue = waiting[origin];
      if (queue.isEmpty) continue;
      final minBusArrival = minArrivalCache.putIfAbsent(
        origin,
        () => minBusArrivalToStopSec(origin, expectedStopSec),
      );
      final queuePenalty =
          math.max(0, queue.length - capacity) / capacity * idealHeadwaySec;
      for (final passenger in queue) {
        if (seen.contains(passenger.id)) continue;
        final elapsed = math.max(0, time - passenger.arrivalTime);
        values.add(
          (elapsed +
                  minBusArrival +
                  queuePenalty +
                  stopsAhead(passenger.origin, passenger.dest) *
                      expectedStopSec) /
              60,
        );
        seen.add(passenger.id);
      }
    }
    return (
      values: values,
      expectedStopSec: expectedStopSec,
      averageDwellSec: expected.averageDwellSec,
    );
  }

  void sample() {
    if (lastSampleTime == time && history.isNotEmpty) return;
    final metrics = computeMetrics();
    final deltaSec = lastSampleTime == null
        ? 0.0
        : math.max(0, time - lastSampleTime!);
    final isBunched =
        (metrics['minHeadwayStops'] as double) <
            (metrics['idealHeadwayStops'] as double) * 0.3 ||
        (metrics['closePairs'] as int) > 0;
    if (isBunched) {
      bunchDuration += deltaSec;
      blockedDuringBunchSec +=
          (metrics['activeBlockedBuses'] as int) * deltaSec;
      if (!bunchActive) bunchStarts++;
    }
    bunchActive = isBunched;
    closePairEvents += metrics['closePairs'] as int;
    metrics['bunchStarts'] = bunchStarts;
    metrics['bunchDurationMin'] = bunchDuration / 60;
    metrics['blockedDuringBunchMin'] = blockedDuringBunchSec / 60;
    history.add({
      't': time,
      for (final key in [
        'bunchScore',
        'avgWaitMin',
        'top5WaitMin',
        'avgTotalMin',
        'top5TotalMin',
        'adjustedAvgTotalMin',
        'adjustedTop5TotalMin',
        'recentAvgWaitMin',
        'recentTop5WaitMin',
        'recentBoardedPassengers',
        'minHeadwayStops',
        'maxHeadwayStops',
        'headwayRmseStops',
        'deniedPassengers',
        'deniedAvgExtraMin',
        'deniedMaxExtraMin',
        'controlSkipAvgExtraMin',
        'controlSkipMaxExtraMin',
        'totalSpringHoldMin',
        'springInterventionCount',
        'totalBlockedDelayMin',
        'activeBlockedBuses',
        'blockedDuringBunchMin',
      ])
        key: metrics[key],
      'onboardByBus': buses.map((bus) => bus.onboard.length).toList(),
    });
    lastSampleTime = time;
  }

  Map<String, dynamic> computeMetrics() {
    final waits = completed
        .where((p) => p.boardTime != null)
        .map((p) => (p.boardTime! - p.arrivalTime) / 60)
        .toList();
    final recentStart = math.max(0, time - config.waitWindowSec);
    final recentWaits = allPassengers.values
        .where(
          (p) =>
              p.boardTime != null &&
              p.boardTime! > recentStart &&
              p.boardTime! <= time,
        )
        .map((p) => (p.boardTime! - p.arrivalTime) / 60)
        .toList();
    final rides = completed
        .where((p) => p.alightTime != null && p.boardTime != null)
        .map((p) => (p.alightTime! - p.boardTime!) / 60)
        .toList();
    final totals = completed
        .where((p) => p.alightTime != null)
        .map((p) => (p.alightTime! - p.arrivalTime) / 60)
        .toList();
    final adjusted = adjustedTotalTimesMin();
    final controlSkipped = allPassengers.values
        .where((p) => p.skipCount > 0)
        .toList();
    final controlSkipExtra = controlSkipped
        .where((p) => p.boardTime != null && p.firstSkipTime != null)
        .map((p) => (p.boardTime! - p.firstSkipTime!) / 60)
        .toList();
    final denied = allPassengers.values
        .where((p) => p.firstDeniedTime != null)
        .toList();
    final deniedExtra = denied
        .where((p) => p.boardTime != null && p.firstDeniedTime != null)
        .map((p) => (p.boardTime! - p.firstDeniedTime!) / 60)
        .toList();
    final hws = headways();
    final ideal = config.stopCount / config.busCount;
    final minHw = hws.reduce(math.min);
    final maxHw = hws.reduce(math.max);
    final cv = mean(hws) == 0 ? 0.0 : std(hws) / mean(hws);
    final errors = hws.map((h) => h - ideal).toList();
    final errorSum = errors.fold<double>(
      0,
      (sum, error) => sum + error * error,
    );
    final closePairs = hws.where((h) => h <= 1).length;
    final closeSeverity = mean(
      hws
          .map((h) => clampDouble((ideal * 0.55 - h) / (ideal * 0.55), 0, 1))
          .toList(),
    );
    final bunchScore = clampDouble(
      clampDouble(cv / 1.35, 0, 1) * 45 +
          clampDouble((0.65 - minHw / math.max(0.01, ideal)) / 0.65, 0, 1) *
              35 +
          closeSeverity * 20,
      0,
      100,
    );
    final loads = buses.map((bus) => bus.onboard.length).toList();
    final delays = buses.map((bus) => bus.delaySec / 60).toList();
    final signals = springSignalLog
        .map((row) => (row['springSignal'] as num?)?.toDouble())
        .whereType<double>()
        .where((value) => value.isFinite)
        .toList();
    final positiveSignals = signals.where((value) => value > 0).toList();
    final negativeSignals = signals.where((value) => value < 0).toList();
    final springHoldEvents = springHoldLog.length;
    return {
      'timeMin': time / 60,
      'completed': completed.length,
      'allPassengers': allPassengers.length,
      'onboardNow': loads.fold<int>(0, (sum, value) => sum + value),
      'waitingNow': waiting.fold<int>(0, (sum, queue) => sum + queue.length),
      'avgWaitMin': mean(waits),
      'recentAvgWaitMin': recentWaits.isEmpty ? double.nan : mean(recentWaits),
      'recentTop5WaitMin': recentWaits.isEmpty
          ? double.nan
          : percentile(recentWaits, 95),
      'recentBoardedPassengers': recentWaits.length,
      'medianWaitMin': percentile(waits, 50),
      'top5WaitMin': percentile(waits, 95),
      'maxWaitMin': waits.isEmpty ? 0.0 : waits.reduce(math.max),
      'over10Min': waits.where((w) => w >= 10).length,
      'avgRideMin': mean(rides),
      'avgTotalMin': mean(totals),
      'top5TotalMin': percentile(totals, 95),
      'adjustedAvgTotalMin': mean(adjusted.values),
      'adjustedTop5TotalMin': percentile(adjusted.values, 95),
      'expectedStopToStopSec': adjusted.expectedStopSec,
      'averageDwellSec': adjusted.averageDwellSec,
      'serviceStopCount': serviceStopCount,
      'deniedPassengers': denied.length,
      'deniedAvgExtraMin': mean(deniedExtra),
      'deniedMaxExtraMin': deniedExtra.isEmpty
          ? 0.0
          : deniedExtra.reduce(math.max),
      'controlSkippedPassengers': controlSkipped.length,
      'controlSkipEvents': skipLog.length,
      'controlSkipAvgExtraMin': mean(controlSkipExtra),
      'controlSkipMaxExtraMin': controlSkipExtra.isEmpty
          ? 0.0
          : controlSkipExtra.reduce(math.max),
      'multiControlSkippedPassengers': controlSkipped
          .where((p) => p.skipCount >= 2)
          .length,
      'fullDeniedAfterControlSkipPassengers': allPassengers.values
          .where((p) => p.fullDeniedAfterControlSkipCount > 0)
          .length,
      'fullPassEvents': fullPassLog.length,
      'fullDeniedPassengers': allPassengers.values
          .where((p) => p.deniedFullCount > 0)
          .length,
      'headwayStdStops': std(hws),
      'idealHeadwayStops': ideal,
      'minHeadwayStops': minHw,
      'maxHeadwayStops': maxHw,
      'headwayErrorSum': errorSum,
      'headwayRmseStops': math.sqrt(errorSum / math.max(1, errors.length)),
      'headwayCv': cv,
      'closePairs': closePairs,
      'bunchScore': bunchScore,
      'bunchStarts': bunchStarts,
      'bunchDurationMin': bunchDuration / 60,
      'avgDelayMin': mean(delays),
      'maxDelayMin': delays.isEmpty ? 0.0 : delays.reduce(math.max),
      'loadStd': std(loads),
      'totalDwellMin': totalDwell / 60,
      'totalControlSkipPassengerEvents': buses.fold<int>(
        0,
        (sum, bus) => sum + bus.totalSkipped,
      ),
      'springHoldEvents': springHoldEvents,
      'totalSpringHoldMin': totalSpringHoldSec / 60,
      'avgSpringHoldSec': springHoldEvents == 0
          ? 0.0
          : totalSpringHoldSec / springHoldEvents,
      'maxSpringHoldSec': maxSpringHoldSec,
      'springControlSkipAssistEvents': springControlSkipAssistEvents,
      'springInterventionCount':
          springHoldEvents + springControlSkipAssistEvents,
      'springPositiveSignalAvg': positiveSignals.isEmpty
          ? 0.0
          : mean(positiveSignals),
      'springNegativeSignalAvg': negativeSignals.isEmpty
          ? 0.0
          : mean(negativeSignals),
      'springSignalAbsAvg': signals.isEmpty
          ? 0.0
          : mean(signals.map((value) => value.abs()).toList()),
      'totalBlockedDelayMin': totalBlockedDelaySec / 60,
      'avgBlockedDelayPerBusMin':
          totalBlockedDelaySec / 60 / math.max(1, config.busCount),
      'blockEvents': blockEvents,
      'avgBlockDurationMin': blockEvents == 0
          ? 0.0
          : totalBlockedDelaySec / blockEvents / 60,
      'maxBlockedDelayMin': maxBlockedSec / 60,
      'activeBlockedBuses': buses
          .where((bus) => bus.status == 'blocked')
          .length,
      'stopBlockedDelayMins': stops
          .map((stop) => stop.totalBlockedDelaySec / 60)
          .toList(),
      'stopBlockEvents': stops.map((stop) => stop.blockEvents).toList(),
      'stopMaxQueues': stops.map((stop) => stop.maxQueue).toList(),
      'stopOccupiedMins': stops
          .map((stop) => stop.totalOccupiedSec / 60)
          .toList(),
      'stopOccupancyRates': stops
          .map((stop) => time > 0 ? stop.totalOccupiedSec / time : 0.0)
          .toList(),
      'totalStopOccupiedMin': stops.fold<double>(
        0,
        (sum, stop) => sum + stop.totalOccupiedSec / 60,
      ),
      'avgStopOccupancyRate': mean(
        stops
            .map((stop) => time > 0 ? stop.totalOccupiedSec / time : 0.0)
            .toList(),
      ),
      'blockedDuringBunchMin': blockedDuringBunchSec / 60,
    };
  }

  Map<String, dynamic> runAudit([int maxSteps = 20000]) {
    var steps = 0;
    while (time < config.durationSec && steps < maxSteps) {
      step(1);
      steps++;
    }
    if (lastSampleTime != time) sample();
    return computeMetrics();
  }

  Map<String, dynamic> runFast([int maxSteps = 20000]) {
    var steps = 0;
    while (time < config.durationSec && steps < maxSteps) {
      step(nextFastDt());
      steps++;
    }
    if (includeHistory && lastSampleTime != time) sample();
    return computeMetrics();
  }

  Map<String, dynamic> runToEnd([int maxSteps = 20000]) =>
      engine == 'fast' ? runFast(maxSteps) : runAudit(maxSteps);
}
