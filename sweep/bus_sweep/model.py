from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

from .config import MODE_KEYS, clamp, normalize_config


def mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def std(values: list[float]) -> float:
    if len(values) < 2:
        return 0.0
    m = mean(values)
    return math.sqrt(mean([(v - m) ** 2 for v in values]))


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = int(clamp(math.ceil((p / 100) * len(ordered)) - 1, 0, len(ordered) - 1))
    return ordered[idx]


def positive_modulo(value: float, length: int) -> float:
    return ((value % length) + length) % length


def u32(value: int) -> int:
    return value & 0xFFFFFFFF


def imul(a: int, b: int) -> int:
    return u32(u32(a) * u32(b))


class SeededRng:
    """Mulberry32-compatible RNG used by the browser simulator."""

    __slots__ = ("seed",)

    def __init__(self, seed: int | float):
        self.seed = u32(int(seed)) or 1

    def next(self) -> float:
        self.seed = u32(self.seed + 0x6D2B79F5)
        t = self.seed
        t = imul(t ^ (t >> 15), t | 1)
        t = u32(t ^ u32(t + imul(t ^ (t >> 7), t | 61)))
        return u32(t ^ (t >> 14)) / 4294967296

    def range(self, minimum: float, maximum: float) -> float:
        return minimum + (maximum - minimum) * self.next()

    def poisson(self, lam: float) -> int:
        if lam <= 0:
            return 0
        limit = math.exp(-lam)
        k = 0
        p = 1.0
        while True:
            k += 1
            p *= self.next()
            if p <= limit:
                return k - 1


@dataclass(slots=True)
class Passenger:
    id: int
    origin: int
    dest: int
    arrivalTime: float
    boardTime: float | None = None
    alightTime: float | None = None
    skipCount: int = 0
    firstSkipTime: float | None = None
    firstDeniedTime: float | None = None
    skippedAt: list[dict[str, Any]] = field(default_factory=list)
    deniedFullCount: int = 0
    fullDeniedAfterControlSkipCount: int = 0
    lastFullDeniedBusId: int | None = None


@dataclass(slots=True)
class Stop:
    id: int
    occupiedByBusId: int | None = None
    serviceEndTime: float = 0.0
    blockedQueue: list[int] = field(default_factory=list)
    totalBlockedDelaySec: float = 0.0
    blockEvents: int = 0
    maxBlockedSec: float = 0.0
    maxQueue: int = 0
    totalOccupiedSec: float = 0.0


@dataclass(slots=True)
class Bus:
    id: int
    pos: float
    routePos: float
    routeSegmentStart: int
    fromStop: int
    targetStop: int
    status: str
    dwellRemaining: float
    segmentRemaining: float
    segmentDuration: float
    segmentIndex: int = 0
    onboard: list[Passenger] = field(default_factory=list)
    delaySec: float = 0.0
    totalBlockedDelaySec: float = 0.0
    blockEvents: int = 0
    blockedStopId: int | None = None
    blockedStartTime: float | None = None
    blockedCurrentSec: float = 0.0
    serviceStopId: int | None = None
    totalDwell: float = 0.0
    totalSkipped: int = 0
    springConsecutiveSkips: int = 0
    springHoldStartTime: float | None = None
    springHoldEndTime: float | None = None
    lastSpringSignal: float = 0.0
    lastAction: str = "通常"
    justSkippedStop: int | None = None
    serviceBoardingOpen: bool = True


class EventGenerator:
    @staticmethod
    def demand_events(config: dict[str, Any]) -> list[dict[str, Any]]:
        rng = SeededRng(config["seed"])
        events: list[dict[str, Any]] = []
        event_id = 1
        base_rate_per_min = 0.23 * config["demandMultiplier"]
        t = 0
        while t <= config["durationSec"] + 1800:
            wave = 0.82 + 0.38 * math.sin((t / config["durationSec"]) * math.pi)
            for stop in range(config["stopCount"]):
                center_bias = 0.75 + 0.35 * math.sin(((stop + 1) / config["stopCount"]) * math.pi)
                hotspot = config["hotspotMultiplier"] if stop in config["hotspotStops"] else 1
                rate = base_rate_per_min * wave * center_bias * hotspot
                count = rng.poisson(rate * config["arrivalQuantumSec"] / 60)
                for _ in range(count):
                    offset = rng.range(0, config["arrivalQuantumSec"])
                    dest = EventGenerator.choose_destination(config, rng, stop)
                    events.append({"id": event_id, "time": t + offset, "origin": stop, "dest": dest})
                    event_id += 1
            t += config["arrivalQuantumSec"]
        events.sort(key=lambda row: row["time"])
        return events

    @staticmethod
    def choose_destination(config: dict[str, Any], rng: SeededRng, origin: int) -> int:
        candidates: list[tuple[int, float]] = []
        for step in range(1, config["stopCount"]):
            stop = (origin + step) % config["stopCount"]
            is_important = stop in config["hotspotStops"]
            near_trip_bias = 1 / math.sqrt(step)
            important_weight = max(2.5, config["hotspotMultiplier"] * 1.8) if is_important else 1
            downstream_hub_bonus = 1.4 if is_important and step <= config["stopCount"] * 0.75 else 1
            candidates.append((stop, near_trip_bias * important_weight * downstream_hub_bonus))
        total = sum(weight for _, weight in candidates)
        pick = rng.range(0, total)
        for stop, weight in candidates:
            pick -= weight
            if pick <= 0:
                return stop
        return candidates[-1][0]

    @staticmethod
    def travel_noise(config: dict[str, Any], from_stop: int, start_time_sec: float) -> float:
        bucket = math.floor(start_time_sec / max(1, config.get("noiseBucketSec") or 60))
        rng = SeededRng(config["seed"] * 100003 + from_stop * 9176 + bucket * 7919)
        scale = config.get("randomDelayScaleSec", max(0, config.get("randomDelaySec", 0)))
        jitter = rng.range(-0.1, 0.1) * config["baseTravelSec"]
        signal = rng.range(0, scale) if rng.next() < 0.24 else rng.range(0, scale * 0.22)
        surge = rng.range(scale * 0.6, scale * 1.8) if rng.next() < 0.035 else 0
        return max(-config["baseTravelSec"] * 0.18, jitter + signal + surge)


class Simulation:
    def __init__(self, config: dict[str, Any], mode: str, demand_events: list[dict[str, Any]], include_history: bool = True, engine: str = "audit"):
        self.config = config
        self.mode = mode
        self.include_history = include_history
        self.engine = engine
        self.controlEnabled = mode != "plain"
        self.springEnabled = mode == "spring"
        self.events = demand_events
        self.eventIndex = 0
        self.time = 0.0
        self.waiting: list[list[Passenger]] = [[] for _ in range(config["stopCount"])]
        self.stops = [Stop(id=i) for i in range(config["stopCount"])]
        self.completed: list[Passenger] = []
        self.allPassengers: dict[int, Passenger] = {}
        self.history: list[dict[str, Any]] = []
        self.skipLog: list[dict[str, Any]] = []
        self.fullPassLog: list[dict[str, Any]] = []
        self.blockLog: list[dict[str, Any]] = []
        self.springHoldLog: list[dict[str, Any]] = []
        self.springSignalLog: list[dict[str, Any]] = []
        self.bunchActive = False
        self.bunchStarts = 0
        self.bunchDuration = 0.0
        self.blockedDuringBunchSec = 0.0
        self.closePairEvents = 0
        self.totalDwell = 0.0
        self.serviceStopCount = 0
        self.totalSpringHoldSec = 0.0
        self.maxSpringHoldSec = 0.0
        self.springControlSkipAssistEvents = 0
        self.totalBlockedDelaySec = 0.0
        self.blockEvents = 0
        self.maxBlockedSec = 0.0
        self.lastSampleTime: float | None = None
        self.lastSnapshot: dict[str, Any] | None = None
        self.buses = self.create_buses()

    def create_buses(self) -> list[Bus]:
        buses: list[Bus] = []
        spacing = self.config["stopCount"] / self.config["busCount"]
        for i in range(self.config["busCount"]):
            route_pos = -i * spacing
            pos = positive_modulo(route_pos, self.config["stopCount"])
            route_segment_start = math.floor(route_pos)
            stop = int(positive_modulo(route_segment_start, self.config["stopCount"]))
            initial_delay = i == 0 and self.config["initialDelaySec"] > 0
            bus = Bus(
                id=i + 1,
                pos=pos,
                routePos=route_pos,
                routeSegmentStart=route_segment_start,
                fromStop=stop,
                targetStop=(stop + 1) % self.config["stopCount"],
                status="dwelling" if initial_delay else "moving",
                dwellRemaining=self.config["initialDelaySec"] if initial_delay else 0,
                segmentRemaining=max(1e-9, self.config["baseTravelSec"] * (1 - (route_pos - route_segment_start))),
                segmentDuration=self.config["baseTravelSec"],
                delaySec=self.config["initialDelaySec"] if i == 0 else 0,
                serviceStopId=stop if initial_delay else None,
            )
            buses.append(bus)
            if initial_delay:
                self.occupy_stop(stop, i + 1, self.config["initialDelaySec"])
            else:
                self.start_segment(bus, stop, False)
                progress = route_pos - route_segment_start
                bus.segmentRemaining = bus.segmentDuration * (1 - progress)
                bus.routePos = route_pos
                bus.pos = positive_modulo(route_pos, self.config["stopCount"])
        return buses

    def start_segment(self, bus: Bus, from_stop: int, advance_counter: bool = True) -> None:
        if advance_counter:
            bus.segmentIndex += 1
        route_start = math.floor(bus.routePos) if math.isfinite(bus.routePos) else from_stop
        circular_from = int(positive_modulo(route_start, self.config["stopCount"]))
        duration = max(1e-9, self.config["baseTravelSec"] + EventGenerator.travel_noise(self.config, circular_from, self.time))
        bus.routeSegmentStart = route_start
        bus.fromStop = circular_from
        bus.targetStop = int(positive_modulo(route_start + 1, self.config["stopCount"]))
        bus.segmentDuration = duration
        bus.segmentRemaining = duration
        bus.routePos = route_start
        bus.pos = positive_modulo(bus.routePos, self.config["stopCount"])
        bus.status = "moving"
        bus.blockedStopId = None
        bus.blockedStartTime = None
        bus.blockedCurrentSec = 0
        bus.serviceStopId = None
        bus.springHoldStartTime = None
        bus.springHoldEndTime = None
        bus.serviceBoardingOpen = True
        bus.lastAction = "走行"

    def add_arrivals(self, until_time: float) -> None:
        while self.eventIndex < len(self.events) and self.events[self.eventIndex]["time"] <= until_time:
            e = self.events[self.eventIndex]
            self.eventIndex += 1
            p = Passenger(e["id"], e["origin"], e["dest"], e["time"])
            self.allPassengers[p.id] = p
            self.waiting[p.origin].append(p)

    def step(self, dt: float) -> None:
        next_time = min(self.config["durationSec"], self.time + dt)
        self.add_arrivals(next_time)
        actual_dt = next_time - self.time
        for bus in self.buses:
            bus.justSkippedStop = None
            if bus.status == "dwelling":
                bus.dwellRemaining -= actual_dt
                bus.delaySec += actual_dt
                self.board_during_dwell(bus, next_time)
                if bus.dwellRemaining <= 0:
                    self.release_stop(bus.serviceStopId, bus.id)
                    self.start_segment(bus, bus.fromStop, True)
            elif bus.status == "blocked":
                self.update_blocked_bus(bus, actual_dt)
            else:
                proposed_remaining = bus.segmentRemaining - actual_dt
                proposed_progress = clamp(1 - proposed_remaining / bus.segmentDuration, 0, 1)
                proposed_route_pos = bus.routeSegmentStart + proposed_progress
                max_route_pos = self.max_route_pos_before_leader(bus)
                capped_route_pos = min(proposed_route_pos, max_route_pos)
                capped = capped_route_pos < proposed_route_pos - 1e-6
                bus.routePos = capped_route_pos
                bus.pos = positive_modulo(bus.routePos, self.config["stopCount"])
                remaining_ratio = clamp(bus.routeSegmentStart + 1 - bus.routePos, 0, 1)
                bus.segmentRemaining = remaining_ratio * bus.segmentDuration
                ideal_travel = self.config["baseTravelSec"]
                actual_travel = self.config["baseTravelSec"] + max(0, bus.segmentDuration - ideal_travel)
                bus.delaySec += max(0, (actual_travel - ideal_travel) / max(1, bus.segmentDuration) * actual_dt)
                if capped:
                    bus.delaySec += actual_dt
                    bus.lastAction = "前車追従"
                bus.delaySec = max(0, bus.delaySec - actual_dt * 0.14)
                if not capped and proposed_remaining <= 0:
                    bus.routePos = bus.routeSegmentStart + 1
                    bus.pos = bus.targetStop
                    self.handle_arrival(bus, bus.targetStop)
        self.time = next_time
        last_sample = self.lastSampleTime if self.lastSampleTime is not None else 0
        if (self.include_history or self.engine == "audit") and (self.time - last_sample >= self.config["sampleIntervalSec"] or self.time >= self.config["durationSec"]):
            self.sample()

    def next_fast_dt(self) -> float:
        remaining = self.config["durationSec"] - self.time
        if remaining <= 0:
            return 0.0
        candidates = [remaining, 5.0]
        if self.eventIndex < len(self.events):
            candidates.append(max(0.25, self.events[self.eventIndex]["time"] - self.time))
        for bus in self.buses:
            if bus.status == "dwelling":
                candidates.append(max(0.25, bus.dwellRemaining))
            elif bus.status == "moving":
                candidates.append(max(0.25, bus.segmentRemaining))
            elif bus.status == "blocked" and bus.blockedStopId is not None:
                stop = self.stops[bus.blockedStopId]
                if stop.occupiedByBusId is not None:
                    candidates.append(max(0.25, stop.serviceEndTime - self.time))
                else:
                    candidates.append(0.25)
        if self.include_history:
            last_sample = self.lastSampleTime if self.lastSampleTime is not None else 0
            candidates.append(max(0.25, last_sample + self.config["sampleIntervalSec"] - self.time))
        return max(0.25, min(v for v in candidates if math.isfinite(v) and v > 0))

    def max_route_pos_before_leader(self, bus: Bus) -> float:
        epsilon = 0.012
        ordered = sorted(self.buses, key=lambda b: b.id)
        index = next((i for i, b in enumerate(ordered) if b.id == bus.id), -1)
        if index < 0:
            return math.inf
        leader = ordered[-1] if index == 0 else ordered[index - 1]
        leader_route_pos = leader.routePos + self.config["stopCount"] if index == 0 else leader.routePos
        target_route_pos = bus.routeSegmentStart + 1
        target_stop = int(positive_modulo(target_route_pos, self.config["stopCount"]))
        leader_at_target = leader.status == "dwelling" and leader.serviceStopId == target_stop
        berth_blocked = self.stops[target_stop].occupiedByBusId is not None or len(self.stops[target_stop].blockedQueue) > 0
        if target_route_pos <= leader_route_pos + 1e-6 and (leader_at_target or berth_blocked):
            return target_route_pos
        return leader_route_pos - epsilon

    def handle_arrival(self, bus: Bus, stop: int) -> None:
        berth = self.stops[stop]
        if berth.occupiedByBusId is not None and berth.occupiedByBusId != bus.id:
            self.enter_blocked(bus, stop)
            return
        self.begin_service(bus, stop)

    def begin_service(self, bus: Bus, stop: int) -> None:
        self.remove_from_blocked_queue(bus, stop)
        self.finish_blocked_if_needed(bus, stop)
        bus.routePos = round(bus.routePos)
        bus.pos = stop
        alighting: list[Passenger] = []
        staying: list[Passenger] = []
        for p in bus.onboard:
            (alighting if p.dest == stop else staying).append(p)
        bus.onboard = staying
        for p in alighting:
            p.alightTime = self.time
            self.completed.append(p)
        decision = self.control_decision(bus, stop, len(alighting))
        boarded = 0
        if decision.get("skip"):
            skipped_now = len(self.waiting[stop])
            for p in self.waiting[stop]:
                p.skipCount += 1
                if p.firstSkipTime is None:
                    p.firstSkipTime = self.time
                if p.firstDeniedTime is None:
                    p.firstDeniedTime = self.time
                p.skippedAt.append({"time": self.time, "stop": stop, "busId": bus.id})
            bus.totalSkipped += skipped_now
            bus.lastAction = "補助スキップ" if decision.get("assist") else "降車のみ"
            bus.justSkippedStop = stop
            if decision.get("assist"):
                bus.springConsecutiveSkips += 1
                self.springControlSkipAssistEvents += 1
            self.skipLog.append(
                {"time": self.time, "stop": stop, "busId": bus.id, "passengers": skipped_now, "reason": decision.get("reason"), "assist": bool(decision.get("assist"))}
            )
        else:
            bus.springConsecutiveSkips = 0
            queue = self.waiting[stop]
            capacity_left = self.config["capacity"] - len(bus.onboard)
            board_count = int(clamp(capacity_left, 0, len(queue)))
            for _ in range(board_count):
                p = queue.pop(0)
                p.boardTime = self.time
                bus.onboard.append(p)
                boarded += 1
            if queue:
                for p in queue:
                    self.record_full_denial(p, bus.id, self.time)
                self.fullPassLog.append({"time": self.time, "stop": stop, "busId": bus.id, "passengers": len(queue)})
            bus.lastAction = f"乗{boarded} 降{len(alighting)}" if boarded or alighting else "停車短"

        base_dwell = self.calculate_dwell_time(bus, boarded, len(alighting), bool(decision.get("skip")))
        hold_sec = max(0.0, float(decision.get("holdSec") or 0))
        if hold_sec > 0 and self.config["forbidHoldingWhenFull"] and len(bus.onboard) >= self.config["capacity"]:
            hold_sec = 0.0
        dwell = base_dwell + hold_sec
        bus.serviceBoardingOpen = not bool(decision.get("skip"))
        if hold_sec > 0:
            bus.lastAction = f"スプリング保持 {hold_sec:.0f}秒"
            bus.springHoldStartTime = self.time + base_dwell
            bus.springHoldEndTime = self.time + dwell
            self.totalSpringHoldSec += hold_sec
            self.maxSpringHoldSec = max(self.maxSpringHoldSec, hold_sec)
            self.springHoldLog.append(
                {
                    "time": self.time,
                    "stop": stop,
                    "busId": bus.id,
                    "holdSec": hold_sec,
                    "signal": decision.get("springSignal"),
                    "hFront": decision.get("hFront"),
                    "hBack": decision.get("hBack"),
                }
            )
        bus.totalDwell += dwell
        self.totalDwell += dwell
        bus.fromStop = stop
        bus.routePos = round(bus.routePos)
        bus.routeSegmentStart = int(bus.routePos)
        bus.pos = stop
        if dwell > 0:
            self.serviceStopCount += 1
            self.occupy_stop(stop, bus.id, dwell)
            bus.status = "dwelling"
            bus.dwellRemaining = dwell
            bus.serviceStopId = stop
        else:
            self.start_segment(bus, stop, True)

    def board_during_dwell(self, bus: Bus, current_time: float) -> None:
        stop = bus.serviceStopId
        if stop is None or not bus.serviceBoardingOpen:
            return
        queue = self.waiting[stop]
        if not queue:
            return
        boarded = 0
        while queue and len(bus.onboard) < self.config["capacity"] and queue[0].arrivalTime <= current_time + 1e-9:
            p = queue.pop(0)
            p.boardTime = max(p.arrivalTime, self.time)
            bus.onboard.append(p)
            boarded += 1
        if boarded:
            bus.lastAction = f"蛛懷ｻ願ｿｽ荵苓ｻ・{boarded}"
        if queue and len(bus.onboard) >= self.config["capacity"]:
            denied_now = 0
            for p in queue:
                if p.arrivalTime <= current_time + 1e-9 and p.lastFullDeniedBusId != bus.id:
                    self.record_full_denial(p, bus.id, p.arrivalTime)
                    denied_now += 1
            if denied_now:
                self.fullPassLog.append({"time": current_time, "stop": stop, "busId": bus.id, "passengers": denied_now})
        if self.config["forbidHoldingWhenFull"] and len(bus.onboard) >= self.config["capacity"]:
            self.cancel_spring_hold_for_full_bus(bus, current_time)

    def record_full_denial(self, passenger: Passenger, bus_id: int, denied_time: float) -> None:
        passenger.deniedFullCount += 1
        passenger.lastFullDeniedBusId = bus_id
        if passenger.firstDeniedTime is None:
            passenger.firstDeniedTime = denied_time
        if passenger.skipCount > 0:
            passenger.fullDeniedAfterControlSkipCount += 1

    def cancel_spring_hold_for_full_bus(self, bus: Bus, current_time: float) -> None:
        if bus.springHoldStartTime is None or bus.springHoldEndTime is None:
            return
        old_end = bus.springHoldEndTime
        new_end = max(bus.springHoldStartTime, min(current_time, old_end))
        if new_end >= old_end - 1e-9:
            return
        cancelled = old_end - new_end
        bus.springHoldEndTime = new_end
        bus.dwellRemaining = min(bus.dwellRemaining, max(0.0, new_end - current_time))
        self.totalSpringHoldSec = max(0.0, self.totalSpringHoldSec - cancelled)
        bus.totalDwell = max(0.0, bus.totalDwell - cancelled)
        self.totalDwell = max(0.0, self.totalDwell - cancelled)
        if bus.serviceStopId is not None:
            stop = self.stops[bus.serviceStopId]
            if stop.occupiedByBusId == bus.id:
                stop.serviceEndTime = min(stop.serviceEndTime, new_end)
            stop.totalOccupiedSec = max(0.0, stop.totalOccupiedSec - cancelled)
        for row in reversed(self.springHoldLog):
            if row.get("busId") == bus.id and row.get("stop") == bus.serviceStopId:
                row["holdSec"] = max(0.0, new_end - bus.springHoldStartTime)
                row["cancelledByFull"] = True
                break
        self.maxSpringHoldSec = max([float(row.get("holdSec") or 0.0) for row in self.springHoldLog], default=0.0)

    def calculate_dwell_time(self, bus: Bus, boarded: int, alighted: int, skip: bool) -> float:
        if boarded == 0 and alighted == 0:
            return 0.0
        if skip and alighted == 0:
            return 0.0
        load_ratio = len(bus.onboard) / max(1, self.config["capacity"])
        crowded_extra = self.config["crowdedExtraSec"] if load_ratio >= self.config["crowdingThreshold"] else 0
        boarding_process = self.config["boardingSetupSec"] + crowded_extra + boarded * self.config["boardTimeSec"] if boarded > 0 else 0
        alighting_process = self.config["alightingSetupSec"] + crowded_extra + alighted * self.config["alightTimeSec"] if alighted > 0 else 0
        return self.config["fixedStopSec"] + boarding_process + alighting_process

    def occupy_stop(self, stop_id: int, bus_id: int, dwell_sec: float) -> None:
        stop = self.stops[stop_id]
        stop.occupiedByBusId = bus_id
        stop.serviceEndTime = self.time + dwell_sec
        stop.totalOccupiedSec += dwell_sec

    def release_stop(self, stop_id: int | None, bus_id: int) -> None:
        if stop_id is None:
            return
        stop = self.stops[stop_id]
        if stop.occupiedByBusId == bus_id:
            stop.occupiedByBusId = None
            stop.serviceEndTime = self.time

    def enter_blocked(self, bus: Bus, stop_id: int) -> None:
        stop = self.stops[stop_id]
        if bus.id not in stop.blockedQueue:
            stop.blockedQueue.append(bus.id)
            stop.maxQueue = max(stop.maxQueue, len(stop.blockedQueue))
        bus.status = "blocked"
        bus.blockedStopId = stop_id
        bus.blockedStartTime = self.time
        bus.blockedCurrentSec = 0
        bus.segmentRemaining = 0
        bus.routePos = round(bus.routePos) - 0.08
        bus.pos = positive_modulo(bus.routePos, self.config["stopCount"])
        bus.lastAction = "前車待ち"

    def update_blocked_bus(self, bus: Bus, dt: float) -> None:
        stop = self.stops[bus.blockedStopId] if bus.blockedStopId is not None else None
        if stop is None:
            return
        if stop.occupiedByBusId is None and stop.blockedQueue and stop.blockedQueue[0] == bus.id:
            self.begin_service(bus, bus.blockedStopId)
            return
        bus.blockedCurrentSec += dt
        bus.totalBlockedDelaySec += dt
        bus.delaySec += dt
        self.totalBlockedDelaySec += dt
        stop.totalBlockedDelaySec += dt

    def remove_from_blocked_queue(self, bus: Bus, stop_id: int) -> None:
        queue = self.stops[stop_id].blockedQueue
        if bus.id in queue:
            queue.remove(bus.id)

    def finish_blocked_if_needed(self, bus: Bus, stop_id: int) -> None:
        if bus.blockedStartTime is None:
            return
        duration = max(0.0, self.time - bus.blockedStartTime)
        stop = self.stops[stop_id]
        bus.blockEvents += 1
        self.blockEvents += 1
        self.maxBlockedSec = max(self.maxBlockedSec, duration)
        stop.blockEvents += 1
        stop.maxBlockedSec = max(stop.maxBlockedSec, duration)
        self.blockLog.append({"time": self.time, "stop": stop_id, "busId": bus.id, "duration": duration})
        bus.blockedStartTime = None
        bus.blockedCurrentSec = 0
        bus.blockedStopId = None

    def control_decision(self, bus: Bus, stop: int, alighting_count: int = 0) -> dict[str, Any]:
        if not self.controlEnabled:
            return {"skip": False, "holdSec": 0, "reason": "control off"}
        if self.springEnabled:
            return self.spring_decision(bus, stop, alighting_count)
        return self.distance_skip_decision(bus, stop, alighting_count, False)

    def distance_skip_decision(self, bus: Bus, stop: int, alighting_count: int = 0, assist: bool = False) -> dict[str, Any]:
        if len(self.waiting[stop]) == 0 and alighting_count == 0:
            return {"skip": False, "holdSec": 0, "reason": "no demand"}
        if stop in self.config["forbiddenStops"]:
            return {"skip": False, "holdSec": 0, "reason": "forbidden stop"}
        if bus.delaySec < self.config["delayThresholdMin"] * 60:
            return {"skip": False, "holdSec": 0, "reason": "delay small"}
        follower = self.find_follower(bus)
        if follower is None:
            return {"skip": False, "holdSec": 0, "reason": "no follower"}
        follower_load = len(follower.onboard) / self.config["capacity"]
        if follower_load > self.config["followerLoadLimit"]:
            return {"skip": False, "holdSec": 0, "reason": "follower crowded"}
        distance_behind = self.route_distance_behind(follower, bus)
        return {"skip": distance_behind <= self.config["distanceThresholdStops"], "holdSec": 0, "assist": assist, "reason": f"behind={distance_behind:.2f}"}

    def spring_decision(self, bus: Bus, stop: int, alighting_count: int = 0) -> dict[str, Any]:
        ctx = self.headway_context(bus)
        bus.lastSpringSignal = ctx["springSignal"]
        self.springSignalLog.append({"time": self.time, "busId": bus.id, "stop": stop, **ctx})
        h = ctx["idealHeadwayStops"]
        deadband = self.config["springDeadbandStops"]
        hold_candidate = ctx["springSignal"] < -deadband and ctx["hFront"] < h and ctx["hBack"] > h
        if hold_candidate:
            if self.config["forbidHoldingWhenFull"] and len(bus.onboard) >= self.config["capacity"]:
                return {"skip": False, "holdSec": 0, "reason": "full bus holding forbidden", **ctx}
            hold_sec = clamp(
                (-ctx["springSignal"] - deadband) * self.config["springGainSecPerStop"] - self.config["springDamping"] * bus.delaySec,
                0,
                self.config["springMaxHoldSec"],
            )
            if hold_sec >= self.config["springMinHoldSec"]:
                return {"skip": False, "holdSec": hold_sec, "reason": f"spring hold signal={ctx['springSignal']:.2f}", **ctx}
        skip_candidate = ctx["springSignal"] > max(deadband, 0.5) and ctx["hFront"] > h and ctx["hBack"] < h
        if not skip_candidate:
            return {"skip": False, "holdSec": 0, "reason": f"spring neutral signal={ctx['springSignal']:.2f}"}
        base_decision = self.distance_skip_decision(bus, stop, alighting_count, True)
        if not base_decision.get("skip"):
            base_decision["assist"] = False
            return base_decision
        if not self.spring_skip_improves_headway(bus, stop, alighting_count):
            return {"skip": False, "holdSec": 0, "reason": "spring headway cost"}
        return {**base_decision, "assist": True, "reason": f"{base_decision['reason']} spring={ctx['springSignal']:.2f}", **ctx}

    def headway_context(self, bus: Bus) -> dict[str, float | int | None]:
        leader = self.find_leader(bus)
        follower = self.find_follower(bus)
        h_front = self.route_distance_ahead(bus, leader) if leader else self.config["stopCount"]
        h_back = self.route_distance_behind(follower, bus) if follower else self.config["stopCount"]
        ideal = self.config["stopCount"] / self.config["busCount"]
        return {
            "leaderId": leader.id if leader else None,
            "followerId": follower.id if follower else None,
            "hFront": h_front,
            "hBack": h_back,
            "idealHeadwayStops": ideal,
            "springSignal": h_front - h_back,
        }

    def spring_skip_improves_headway(self, bus: Bus, stop: int, alighting_count: int) -> bool:
        capacity_left = max(0, self.config["capacity"] - len(bus.onboard))
        boarded_if_normal = min(capacity_left, len(self.waiting[stop]))
        saved_dwell = self.calculate_dwell_time(bus, boarded_if_normal, alighting_count, False)
        forward_stops = clamp(saved_dwell / max(1, self.config["baseTravelSec"]), 0, self.config["stopCount"] / 2)
        if forward_stops <= 0:
            return True
        return self.headway_error_cost(bus.id, forward_stops) < self.headway_error_cost()

    def headway_error_cost(self, bus_id: int | None = None, forward_stops: float = 0) -> float:
        ideal = self.config["stopCount"] / self.config["busCount"]
        positions = sorted(positive_modulo(b.pos + (forward_stops if b.id == bus_id else 0), self.config["stopCount"]) for b in self.buses)
        gaps = [(positions[(i + 1) % len(positions)] - positions[i] + self.config["stopCount"]) % self.config["stopCount"] for i in range(len(positions))]
        return sum((h - ideal) ** 2 for h in gaps)

    def find_follower(self, bus: Bus) -> Bus | None:
        best = None
        best_dist = math.inf
        for other in self.buses:
            if other.id == bus.id:
                continue
            dist = self.route_distance_behind(other, bus)
            if 0.01 < dist < best_dist:
                best = other
                best_dist = dist
        return best

    def find_leader(self, bus: Bus) -> Bus | None:
        best = None
        best_dist = math.inf
        for other in self.buses:
            if other.id == bus.id:
                continue
            dist = self.route_distance_ahead(bus, other)
            if 0.01 < dist < best_dist:
                best = other
                best_dist = dist
        return best

    def route_distance_ahead(self, bus: Bus, leader: Bus) -> float:
        dist = leader.routePos - bus.routePos
        while dist <= 0:
            dist += self.config["stopCount"]
        return dist

    def route_distance_behind(self, follower: Bus, leader: Bus) -> float:
        dist = leader.routePos - follower.routePos
        while dist <= 0:
            dist += self.config["stopCount"]
        return dist

    def headways(self) -> list[float]:
        positions = sorted(b.pos for b in self.buses)
        return [(positions[(i + 1) % len(positions)] - positions[i] + self.config["stopCount"]) % self.config["stopCount"] for i in range(len(positions))]

    def stops_ahead(self, origin: int | float, dest: int | float) -> float:
        return positive_modulo(dest - origin, self.config["stopCount"])

    def expected_stop_to_stop_sec(self) -> tuple[float, float]:
        average_dwell_sec = self.totalDwell / max(1, self.serviceStopCount)
        expected = self.config["baseTravelSec"] + self.config.get("randomDelayMeanSec", 0.0) + average_dwell_sec
        return expected, average_dwell_sec

    def bus_arrival_to_stop_sec(self, bus: Bus, stop: int, expected_stop_to_stop_sec: float) -> float:
        if bus.status == "moving":
            remaining = max(0.0, bus.segmentRemaining)
            stops_after_target = self.stops_ahead(bus.targetStop, stop)
            return remaining + stops_after_target * expected_stop_to_stop_sec
        if bus.status == "dwelling":
            dwell = max(0.0, bus.dwellRemaining)
            if bus.serviceStopId == stop:
                return dwell
            stops_after_current = self.stops_ahead(bus.pos, stop)
            return dwell + stops_after_current * expected_stop_to_stop_sec
        if bus.status == "blocked":
            blocked_wait = 0.0
            if bus.blockedStopId is not None:
                berth = self.stops[bus.blockedStopId]
                blocked_wait = max(0.0, berth.serviceEndTime - self.time) if berth.occupiedByBusId is not None else 0.0
                if bus.blockedStopId == stop:
                    return blocked_wait
                stops_after_block = self.stops_ahead(bus.blockedStopId, stop)
                return blocked_wait + stops_after_block * expected_stop_to_stop_sec
        return self.stops_ahead(bus.pos, stop) * expected_stop_to_stop_sec

    def min_bus_arrival_to_stop_sec(self, stop: int, expected_stop_to_stop_sec: float) -> float:
        if not self.buses:
            return 0.0
        return min(self.bus_arrival_to_stop_sec(bus, stop, expected_stop_to_stop_sec) for bus in self.buses)

    def adjusted_total_times_min(self) -> tuple[list[float], float, float]:
        expected_stop_sec, average_dwell_sec = self.expected_stop_to_stop_sec()
        ideal_headway_sec = (self.config["stopCount"] / max(1, self.config["busCount"])) * expected_stop_sec
        capacity = max(1, self.config["capacity"])
        values: list[float] = []
        seen: set[int] = set()

        for p in self.completed:
            if p.alightTime is not None:
                values.append(max(0.0, p.alightTime - p.arrivalTime) / 60)
                seen.add(p.id)

        for bus in self.buses:
            for p in bus.onboard:
                if p.id in seen:
                    continue
                elapsed = max(0.0, self.time - p.arrivalTime)
                remaining_stops = self.stops_ahead(bus.pos, p.dest)
                values.append((elapsed + remaining_stops * expected_stop_sec) / 60)
                seen.add(p.id)

        min_arrival_cache: dict[int, float] = {}
        for origin, queue in enumerate(self.waiting):
            if not queue:
                continue
            min_bus_arrival = min_arrival_cache.setdefault(origin, self.min_bus_arrival_to_stop_sec(origin, expected_stop_sec))
            queue_penalty = max(0, len(queue) - capacity) / capacity * ideal_headway_sec
            for p in queue:
                if p.id in seen:
                    continue
                elapsed = max(0.0, self.time - p.arrivalTime)
                trip_stops = self.stops_ahead(p.origin, p.dest)
                values.append((elapsed + min_bus_arrival + queue_penalty + trip_stops * expected_stop_sec) / 60)
                seen.add(p.id)

        return values, expected_stop_sec, average_dwell_sec

    def sample(self) -> None:
        if self.lastSampleTime == self.time and self.history:
            return
        metrics = self.compute_metrics()
        delta_sec = 0 if self.lastSampleTime is None else max(0, self.time - self.lastSampleTime)
        is_bunched = metrics["minHeadwayStops"] < metrics["idealHeadwayStops"] * 0.3 or metrics["closePairs"] > 0
        if is_bunched:
            self.bunchDuration += delta_sec
            self.blockedDuringBunchSec += metrics["activeBlockedBuses"] * delta_sec
            if not self.bunchActive:
                self.bunchStarts += 1
        self.bunchActive = is_bunched
        self.closePairEvents += metrics["closePairs"]
        metrics["bunchStarts"] = self.bunchStarts
        metrics["bunchDurationMin"] = self.bunchDuration / 60
        metrics["blockedDuringBunchMin"] = self.blockedDuringBunchSec / 60
        self.lastSnapshot = metrics
        self.history.append(
            {
                "t": self.time,
                "bunchScore": metrics["bunchScore"],
                "avgWaitMin": metrics["avgWaitMin"],
                "top5WaitMin": metrics["top5WaitMin"],
                "avgTotalMin": metrics["avgTotalMin"],
                "top5TotalMin": metrics["top5TotalMin"],
                "adjustedAvgTotalMin": metrics["adjustedAvgTotalMin"],
                "adjustedTop5TotalMin": metrics["adjustedTop5TotalMin"],
                "recentAvgWaitMin": metrics["recentAvgWaitMin"],
                "recentTop5WaitMin": metrics["recentTop5WaitMin"],
                "recentBoardedPassengers": metrics["recentBoardedPassengers"],
                "minHeadwayStops": metrics["minHeadwayStops"],
                "maxHeadwayStops": metrics["maxHeadwayStops"],
                "headwayRmseStops": metrics["headwayRmseStops"],
                "deniedPassengers": metrics["deniedPassengers"],
                "deniedAvgExtraMin": metrics["deniedAvgExtraMin"],
                "deniedMaxExtraMin": metrics["deniedMaxExtraMin"],
                "controlSkipAvgExtraMin": metrics["controlSkipAvgExtraMin"],
                "controlSkipMaxExtraMin": metrics["controlSkipMaxExtraMin"],
                "totalSpringHoldMin": metrics["totalSpringHoldMin"],
                "springInterventionCount": metrics["springInterventionCount"],
                "totalBlockedDelayMin": metrics["totalBlockedDelayMin"],
                "activeBlockedBuses": metrics["activeBlockedBuses"],
                "blockedDuringBunchMin": metrics["blockedDuringBunchMin"],
                "onboardByBus": [len(b.onboard) for b in self.buses],
            }
        )
        self.lastSampleTime = self.time

    def compute_metrics(self) -> dict[str, Any]:
        waits = [(p.boardTime - p.arrivalTime) / 60 for p in self.completed if p.boardTime is not None]
        recent_start = max(0, self.time - self.config["waitWindowSec"])
        recent_waits = [
            (p.boardTime - p.arrivalTime) / 60
            for p in self.allPassengers.values()
            if p.boardTime is not None and p.boardTime > recent_start and p.boardTime <= self.time
        ]
        rides = [(p.alightTime - p.boardTime) / 60 for p in self.completed if p.alightTime is not None and p.boardTime is not None]
        totals = [(p.alightTime - p.arrivalTime) / 60 for p in self.completed if p.alightTime is not None]
        adjusted_totals, expected_stop_sec, average_dwell_sec = self.adjusted_total_times_min()
        control_skipped = [p for p in self.allPassengers.values() if p.skipCount > 0]
        control_skipped_boarded = [p for p in control_skipped if p.boardTime is not None and p.firstSkipTime is not None]
        control_skip_extra = [
            (p.boardTime - p.firstSkipTime) / 60
            for p in control_skipped_boarded
            if p.boardTime is not None and p.firstSkipTime is not None
        ]
        denied = [p for p in self.allPassengers.values() if p.firstDeniedTime is not None]
        denied_boarded = [p for p in denied if p.boardTime is not None]
        denied_extra = [
            (p.boardTime - p.firstDeniedTime) / 60
            for p in denied_boarded
            if p.boardTime is not None and p.firstDeniedTime is not None
        ]
        headways = self.headways()
        ideal = self.config["stopCount"] / self.config["busCount"]
        min_hw = min(headways)
        max_hw = max(headways)
        cv = std(headways) / mean(headways) if mean(headways) else 0
        headway_errors = [h - ideal for h in headways]
        headway_error_sum = sum(e * e for e in headway_errors)
        headway_rmse = math.sqrt(headway_error_sum / max(1, len(headway_errors)))
        close_pairs = len([h for h in headways if h <= 1])
        min_ratio = min_hw / max(0.01, ideal)
        close_severity = mean([clamp((ideal * 0.55 - h) / (ideal * 0.55), 0, 1) for h in headways])
        bunch_score = clamp(clamp(cv / 1.35, 0, 1) * 45 + clamp((0.65 - min_ratio) / 0.65, 0, 1) * 35 + close_severity * 20, 0, 100)
        load_by_bus = [len(b.onboard) for b in self.buses]
        onboard_now = sum(load_by_bus)
        delay_by_bus = [b.delaySec / 60 for b in self.buses]
        stop_blocked_delay_mins = [s.totalBlockedDelaySec / 60 for s in self.stops]
        stop_occupied_mins = [s.totalOccupiedSec / 60 for s in self.stops]
        stop_occupancy_rates = [s.totalOccupiedSec / self.time if self.time > 0 else 0 for s in self.stops]
        signals = [row["springSignal"] for row in self.springSignalLog if math.isfinite(row.get("springSignal", math.nan))]
        positive_signals = [v for v in signals if v > 0]
        negative_signals = [v for v in signals if v < 0]
        spring_hold_events = len(self.springHoldLog)
        return {
            "timeMin": self.time / 60,
            "completed": len(self.completed),
            "allPassengers": len(self.allPassengers),
            "onboardNow": onboard_now,
            "waitingNow": sum(len(q) for q in self.waiting),
            "avgWaitMin": mean(waits),
            "recentAvgWaitMin": mean(recent_waits) if recent_waits else math.nan,
            "recentTop5WaitMin": pct(recent_waits, 95) if recent_waits else math.nan,
            "recentBoardedPassengers": len(recent_waits),
            "medianWaitMin": pct(waits, 50),
            "top5WaitMin": pct(waits, 95),
            "maxWaitMin": max(waits) if waits else 0,
            "over10Min": len([w for w in waits if w >= 10]),
            "avgRideMin": mean(rides),
            "avgTotalMin": mean(totals),
            "top5TotalMin": pct(totals, 95),
            "adjustedAvgTotalMin": mean(adjusted_totals),
            "adjustedTop5TotalMin": pct(adjusted_totals, 95),
            "expectedStopToStopSec": expected_stop_sec,
            "averageDwellSec": average_dwell_sec,
            "serviceStopCount": self.serviceStopCount,
            "deniedPassengers": len(denied),
            "deniedAvgExtraMin": mean(denied_extra),
            "deniedMaxExtraMin": max(denied_extra) if denied_extra else 0,
            "controlSkippedPassengers": len(control_skipped),
            "controlSkipEvents": len(self.skipLog),
            "controlSkipAvgExtraMin": mean(control_skip_extra),
            "controlSkipMaxExtraMin": max(control_skip_extra) if control_skip_extra else 0,
            "multiControlSkippedPassengers": len([p for p in control_skipped if p.skipCount >= 2]),
            "fullDeniedAfterControlSkipPassengers": len([p for p in self.allPassengers.values() if p.fullDeniedAfterControlSkipCount > 0]),
            "fullPassEvents": len(self.fullPassLog),
            "fullDeniedPassengers": len([p for p in self.allPassengers.values() if p.deniedFullCount > 0]),
            "headwayStdStops": std(headways),
            "idealHeadwayStops": ideal,
            "minHeadwayStops": min_hw,
            "maxHeadwayStops": max_hw,
            "headwayErrorSum": headway_error_sum,
            "headwayRmseStops": headway_rmse,
            "headwayCv": cv,
            "closePairs": close_pairs,
            "bunchScore": bunch_score,
            "bunchStarts": self.bunchStarts,
            "bunchDurationMin": self.bunchDuration / 60,
            "avgDelayMin": mean(delay_by_bus),
            "maxDelayMin": max(delay_by_bus) if delay_by_bus else 0,
            "loadStd": std(load_by_bus),
            "totalDwellMin": self.totalDwell / 60,
            "totalControlSkipPassengerEvents": sum(b.totalSkipped for b in self.buses),
            "springHoldEvents": spring_hold_events,
            "totalSpringHoldMin": self.totalSpringHoldSec / 60,
            "avgSpringHoldSec": self.totalSpringHoldSec / spring_hold_events if spring_hold_events else 0,
            "maxSpringHoldSec": self.maxSpringHoldSec,
            "springControlSkipAssistEvents": self.springControlSkipAssistEvents,
            "springInterventionCount": spring_hold_events + self.springControlSkipAssistEvents,
            "springPositiveSignalAvg": mean(positive_signals) if positive_signals else 0,
            "springNegativeSignalAvg": mean(negative_signals) if negative_signals else 0,
            "springSignalAbsAvg": mean([abs(v) for v in signals]) if signals else 0,
            "totalBlockedDelayMin": self.totalBlockedDelaySec / 60,
            "avgBlockedDelayPerBusMin": self.totalBlockedDelaySec / 60 / max(1, self.config["busCount"]),
            "blockEvents": self.blockEvents,
            "avgBlockDurationMin": self.totalBlockedDelaySec / self.blockEvents / 60 if self.blockEvents else 0,
            "maxBlockedDelayMin": self.maxBlockedSec / 60,
            "activeBlockedBuses": len([b for b in self.buses if b.status == "blocked"]),
            "stopBlockedDelayMins": stop_blocked_delay_mins,
            "stopBlockEvents": [s.blockEvents for s in self.stops],
            "stopMaxQueues": [s.maxQueue for s in self.stops],
            "stopOccupiedMins": stop_occupied_mins,
            "stopOccupancyRates": stop_occupancy_rates,
            "totalStopOccupiedMin": sum(stop_occupied_mins),
            "avgStopOccupancyRate": mean(stop_occupancy_rates),
            "blockedDuringBunchMin": self.blockedDuringBunchSec / 60,
        }

    def run_audit(self, max_steps: int = 20000) -> dict[str, Any]:
        steps = 0
        while self.time < self.config["durationSec"] and steps < max_steps:
            self.step(1)
            steps += 1
        if self.lastSampleTime != self.time:
            self.sample()
        return self.compute_metrics()

    def run_fast(self, max_steps: int = 20000) -> dict[str, Any]:
        steps = 0
        while self.time < self.config["durationSec"] and steps < max_steps:
            self.step(self.next_fast_dt())
            steps += 1
        if self.include_history and self.lastSampleTime != self.time:
            self.sample()
        return self.compute_metrics()

    def run_to_end(self, max_steps: int = 20000) -> dict[str, Any]:
        if self.engine == "fast":
            return self.run_fast(max_steps)
        return self.run_audit(max_steps)


def run_three_modes(raw_config: dict[str, Any], modes: list[str] | tuple[str, ...] = MODE_KEYS, include_history: bool = True, engine: str = "audit") -> dict[str, dict[str, Any]]:
    invalid_modes = [mode for mode in modes if mode not in MODE_KEYS]
    if invalid_modes:
        raise ValueError(f"unsupported mode(s): {', '.join(invalid_modes)}")
    config = normalize_config(raw_config)
    events = EventGenerator.demand_events(config)
    result: dict[str, dict[str, Any]] = {}
    for mode in modes:
        control_mode = "none" if mode == "plain" else mode
        sim = Simulation({**config, "controlMode": control_mode}, mode, events, include_history=include_history, engine=engine)
        metrics = sim.run_to_end()
        result[mode] = {"metrics": metrics, "history": [dict(row) for row in sim.history] if include_history else []}
    return result


def scalar_metrics(metrics: dict[str, Any]) -> dict[str, float | int]:
    out: dict[str, float | int] = {}
    for key, value in metrics.items():
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            out[key] = value
        elif isinstance(value, float):
            out[key] = value
    return out
