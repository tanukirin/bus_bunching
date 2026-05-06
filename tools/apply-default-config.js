#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const defaultIndexPath = path.join(repoRoot, "prototype", "index.html");

const CONFIG_KEYS = [
  "name",
  "seed",
  "stopCount",
  "busCount",
  "durationMin",
  "demandMultiplier",
  "capacity",
  "baseSpeedKmh",
  "stopDistanceKm",
  "boardTimeSec",
  "alightTimeSec",
  "randomDelayMeanSec",
  "hotspotStops",
  "hotspotMultiplier",
  "protectHotspotStops",
  "initialDelaySec",
  "distanceThresholdStops",
  "timeThresholdMin",
  "delayThresholdMin",
  "followerLoadLimit",
  "policyMode",
  "springGainSecPerStop",
  "springDeadbandStops",
  "springDamping",
  "springMaxHoldSec",
  "springMinHoldSec",
  "stopManeuverLossSec",
  "doorTimeSec",
  "boardingSetupSec",
  "alightingSetupSec",
  "crowdedExtraSec",
  "crowdingThreshold"
];

const INPUT_VALUE_MAP = {
  seedInput: "seed",
  durationInput: "durationMin",
  stopCountInput: "stopCount",
  busCountInput: "busCount",
  demandInput: "demandMultiplier",
  capacityInput: "capacity",
  distanceThresholdInput: "distanceThresholdStops",
  timeThresholdInput: "timeThresholdMin",
  delayThresholdInput: "delayThresholdMin",
  speedInput: "baseSpeedKmh",
  distanceInput: "stopDistanceKm",
  boardTimeInput: "boardTimeSec",
  alightTimeInput: "alightTimeSec",
  crowdedExtraInput: "crowdedExtraSec",
  stopLossInput: "stopManeuverLossSec",
  doorTimeInput: "doorTimeSec",
  boardingSetupInput: "boardingSetupSec",
  alightingSetupInput: "alightingSetupSec",
  crowdingThresholdInput: "crowdingThreshold",
  randomDelayInput: "randomDelayMeanSec",
  hotspotInput: "hotspotStops",
  hotspotMultiplierInput: "hotspotMultiplier",
  followerLoadInput: "followerLoadLimit",
  initialDelayInput: "initialDelaySec",
  springGainInput: "springGainSecPerStop",
  springDeadbandInput: "springDeadbandStops",
  springDampingInput: "springDamping",
  springMaxHoldInput: "springMaxHoldSec",
  springMinHoldInput: "springMinHoldSec"
};

function usage() {
  console.error("Usage: node tools/apply-default-config.js <bus-bunching-config.json|bus-bunching-results.json> [prototype/index.html|spring/index.html]");
  process.exit(1);
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`JSONを読めません: ${filePath}\n${error.message}`);
  }
}

function extractConfig(payload) {
  const config = payload && (payload.config || payload.settings || payload);
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw new Error("config オブジェクトが見つかりません。");
  }
  const required = ["stopCount", "busCount", "durationMin", "demandMultiplier"];
  const missing = required.filter((key) => !Number.isFinite(Number(config[key])));
  if (missing.length) {
    throw new Error(`必須パラメータが不足しています: ${missing.join(", ")}`);
  }
  return config;
}

function cleanConfig(raw) {
  const clean = {};
  for (const key of CONFIG_KEYS) {
    if (raw[key] !== undefined) clean[key] = raw[key];
  }

  clean.name = String(clean.name || "高頻度都市路線");
  clean.seed = numberOr(clean.seed, 1);
  clean.stopCount = intOr(clean.stopCount, 20);
  clean.busCount = intOr(clean.busCount, 5);
  clean.durationMin = numberOr(clean.durationMin, 90);
  clean.demandMultiplier = numberOr(clean.demandMultiplier, 1);
  clean.capacity = intOr(clean.capacity, 30);
  clean.baseSpeedKmh = numberOr(clean.baseSpeedKmh, 18);
  clean.stopDistanceKm = numberOr(clean.stopDistanceKm, 0.25);
  clean.boardTimeSec = numberOr(clean.boardTimeSec, 3);
  clean.alightTimeSec = numberOr(clean.alightTimeSec, 3);
  clean.randomDelayMeanSec = numberOr(clean.randomDelayMeanSec, 7.4);
  clean.hotspotStops = Array.isArray(clean.hotspotStops)
    ? clean.hotspotStops.map((n) => Number(n)).filter(Number.isInteger)
    : [];
  clean.hotspotMultiplier = numberOr(clean.hotspotMultiplier, 1);
  clean.protectHotspotStops = clean.protectHotspotStops === true || clean.protectHotspotStops === "true";
  clean.initialDelaySec = numberOr(clean.initialDelaySec, 0);
  clean.distanceThresholdStops = numberOr(clean.distanceThresholdStops, 2);
  clean.timeThresholdMin = numberOr(clean.timeThresholdMin, 3);
  clean.delayThresholdMin = numberOr(clean.delayThresholdMin, 2);
  clean.followerLoadLimit = numberOr(clean.followerLoadLimit, 0.9);
  clean.policyMode = ["distance", "time", "hybrid"].includes(clean.policyMode) ? clean.policyMode : "hybrid";
  clean.springGainSecPerStop = numberOr(clean.springGainSecPerStop, 18);
  clean.springDeadbandStops = numberOr(clean.springDeadbandStops, 0.6);
  clean.springDamping = numberOr(clean.springDamping, 0.06);
  clean.springMaxHoldSec = numberOr(clean.springMaxHoldSec, 45);
  clean.springMinHoldSec = numberOr(clean.springMinHoldSec, 8);
  clean.stopManeuverLossSec = numberOr(clean.stopManeuverLossSec, 10);
  clean.doorTimeSec = numberOr(clean.doorTimeSec, 3);
  clean.boardingSetupSec = numberOr(clean.boardingSetupSec, 3);
  clean.alightingSetupSec = numberOr(clean.alightingSetupSec, 3);
  clean.crowdedExtraSec = numberOr(clean.crowdedExtraSec, 5);
  clean.crowdingThreshold = numberOr(clean.crowdingThreshold, 0.8);
  return clean;
}

function numberOr(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function intOr(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.round(n) : fallback;
}

function jsValue(value) {
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.join(", ")}]`;
  if (typeof value === "boolean") return String(value);
  return String(value);
}

function formatUrbanPreset(config) {
  const lines = [
    `        name: ${jsValue(config.name)},`,
    `        seed: ${config.seed}, stopCount: ${config.stopCount}, busCount: ${config.busCount}, durationMin: ${config.durationMin}, demandMultiplier: ${config.demandMultiplier},`,
    `        capacity: ${config.capacity}, baseSpeedKmh: ${config.baseSpeedKmh}, stopDistanceKm: ${config.stopDistanceKm}, boardTimeSec: ${config.boardTimeSec},`,
    `        alightTimeSec: ${config.alightTimeSec}, randomDelayMeanSec: ${config.randomDelayMeanSec}, hotspotStops: ${jsValue(config.hotspotStops)}, hotspotMultiplier: ${config.hotspotMultiplier},`,
    `        protectHotspotStops: ${config.protectHotspotStops}, initialDelaySec: ${config.initialDelaySec}, distanceThresholdStops: ${config.distanceThresholdStops},`,
    `        timeThresholdMin: ${config.timeThresholdMin}, delayThresholdMin: ${config.delayThresholdMin}, followerLoadLimit: ${config.followerLoadLimit}, policyMode: ${jsValue(config.policyMode)},`,
    `        springGainSecPerStop: ${config.springGainSecPerStop}, springDeadbandStops: ${config.springDeadbandStops}, springDamping: ${config.springDamping}, springMaxHoldSec: ${config.springMaxHoldSec}, springMinHoldSec: ${config.springMinHoldSec},`,
    `        stopManeuverLossSec: ${config.stopManeuverLossSec}, doorTimeSec: ${config.doorTimeSec}, boardingSetupSec: ${config.boardingSetupSec}, alightingSetupSec: ${config.alightingSetupSec},`,
    `        crowdedExtraSec: ${config.crowdedExtraSec}, crowdingThreshold: ${config.crowdingThreshold}`
  ];
  return lines.join("\n");
}

function replaceUrbanPreset(html, config) {
  const replacement = `urban: {\n${formatUrbanPreset(config)}\n      },\n      calm:`;
  const pattern = /urban:\s*\{[\s\S]*?\r?\n\s{6}\},\r?\n\s{6}calm:/;
  if (!pattern.test(html)) throw new Error("PRESETS.urban を見つけられません。");
  return html.replace(pattern, replacement);
}

function replaceInputValues(html, config) {
  let next = html;
  for (const [id, key] of Object.entries(INPUT_VALUE_MAP)) {
    const value = Array.isArray(config[key]) ? config[key].join(",") : config[key];
    const pattern = new RegExp(`(<input\\s+id="${id}"[^>]*\\svalue=")[^"]*(")`);
    if (!pattern.test(next)) continue;
    next = next.replace(pattern, `$1${escapeAttribute(value)}$2`);
  }
  next = replaceSelectOption(next, "policySelect", config.policyMode);
  next = replaceSelectOption(next, "protectHotspotInput", String(config.protectHotspotStops));
  return next;
}

function replaceSelectOption(html, id, selectedValue) {
  const selectPattern = new RegExp(`(<select\\s+id="${id}"[^>]*>)([\\s\\S]*?)(<\\/select>)`);
  const match = html.match(selectPattern);
  if (!match) return html;
  const options = match[2]
    .replace(/\sselected(?=[\s>])/g, "")
    .replace(new RegExp(`(<option\\s+value="${escapeRegExp(selectedValue)}")`), "$1 selected");
  if (!new RegExp(`<option\\s+value="${escapeRegExp(selectedValue)}"`).test(match[2])) {
    throw new Error(`#${id} の選択肢 ${selectedValue} を見つけられません。`);
  }
  return html.replace(selectPattern, `${match[1]}${options}${match[3]}`);
}

function escapeAttribute(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;");
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function main() {
  const inputPath = process.argv[2];
  if (!inputPath) usage();
  const targetPath = process.argv[3]
    ? path.resolve(process.cwd(), process.argv[3])
    : defaultIndexPath;
  const relativeTarget = path.relative(repoRoot, targetPath);
  if (relativeTarget.startsWith("..") || path.isAbsolute(relativeTarget)) {
    throw new Error(`対象HTMLはリポジトリ内を指定してください: ${targetPath}`);
  }
  const payload = readJson(path.resolve(process.cwd(), inputPath));
  const config = cleanConfig(extractConfig(payload));
  let html = fs.readFileSync(targetPath, "utf8");
  html = replaceUrbanPreset(html, config);
  html = replaceInputValues(html, config);
  fs.writeFileSync(targetPath, html, "utf8");
  console.log(`Updated ${path.relative(repoRoot, targetPath)} defaults from ${inputPath}`);
}

main();
