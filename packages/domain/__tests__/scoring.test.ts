// packages/domain/__tests__/scoring.test.ts
// MBI Scoring Engine — Determinism & Correctness Tests
// Run: npm test

import { computeBaseline } from "../baseline.ts";
import { computeDeviations } from "../deviation.ts";
import { scoreDay, getScoreBand } from "../scoring.ts";
import { selectTopDrivers } from "../drivers.ts";
import type { DailyInput } from "../contracts.ts";

// ─────────────────────────────────────────
// TEST HELPERS
// ─────────────────────────────────────────
function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(`FAIL: ${message}`);
  console.log(`  ✓ ${message}`);
}

function describe(name: string, fn: () => void) {
  console.log(`\n${name}`);
  fn();
}

// ─────────────────────────────────────────
// FIXTURE DATA
// ─────────────────────────────────────────
const healthyDays: DailyInput[] = Array.from({ length: 7 }, (_, i) => ({
  userId: "test-user",
  date: `2026-04-0${i + 1}`,
  hrv_ms: 55,
  resting_hr_bpm: 58,
  respiratory_rate_rpm: 14,
  sleep_duration_hrs: 7.5,
  sleep_efficiency_pct: 88,
  steps: 9000,
  active_minutes: 45,
  distance_km: 7,
}));

const baseline = computeBaseline(healthyDays)!;

// ─────────────────────────────────────────
// TESTS
// ─────────────────────────────────────────

describe("Baseline Calculation", () => {
  assert(baseline !== null, "Baseline computed from 7 days");
  assert(baseline.hrv_avg === 55, "HRV avg correct");
  assert(baseline.resting_hr_avg === 58, "RHR avg correct");
  assert(baseline.sleep_duration_avg === 7.5, "Sleep duration avg correct");
  assert(baseline.window_days === 7, "Window is 7 days");

  const shortHistory = healthyDays.slice(0, 2);
  assert(computeBaseline(shortHistory) === null, "Returns null with < 3 days");
});

describe("Score Bands", () => {
  assert(getScoreBand(100) === "Thriving", "100 = Thriving");
  assert(getScoreBand(80) === "Thriving", "80 = Thriving");
  assert(getScoreBand(79) === "Recovering", "79 = Recovering");
  assert(getScoreBand(60) === "Recovering", "60 = Recovering");
  assert(getScoreBand(59) === "Drifting", "59 = Drifting");
  assert(getScoreBand(40) === "Drifting", "40 = Drifting");
  assert(getScoreBand(39) === "Redline", "39 = Redline");
  assert(getScoreBand(0) === "Redline", "0 = Redline");
});

describe("Deviation Detection — HRV", () => {
  const devs30 = computeDeviations({ ...healthyDays[0], hrv_ms: 55 * 0.65 }, baseline, 8000);
  const hrv30 = devs30.find((d) => d.metric === "hrv")!;
  assert(hrv30.deviation === -2, "HRV >30% drop = hard flag");

  const devs20 = computeDeviations({ ...healthyDays[0], hrv_ms: 55 * 0.82 }, baseline, 8000);
  const hrv20 = devs20.find((d) => d.metric === "hrv")!;
  assert(hrv20.deviation === -1, "HRV 18% drop = mild flag");

  const devsNorm = computeDeviations({ ...healthyDays[0], hrv_ms: 53 }, baseline, 8000);
  const hrvNorm = devsNorm.find((d) => d.metric === "hrv")!;
  assert(hrvNorm.deviation === 0, "HRV within 15% = normal");

  const devsGuard = computeDeviations({ ...healthyDays[0], hrv_ms: 20 }, baseline, 8000);
  const hrvGuard = devsGuard.find((d) => d.metric === "hrv")!;
  assert(hrvGuard.deviation === -2, "HRV <25ms guardrail = hard flag");
});

describe("Deviation Detection — RHR", () => {
  const devs10 = computeDeviations({ ...healthyDays[0], resting_hr_bpm: 68 }, baseline, 8000);
  const rhr10 = devs10.find((d) => d.metric === "resting_hr")!;
  assert(rhr10.deviation === -2, "RHR +10 bpm = hard flag");

  const devs6 = computeDeviations({ ...healthyDays[0], resting_hr_bpm: 64 }, baseline, 8000);
  const rhr6 = devs6.find((d) => d.metric === "resting_hr")!;
  assert(rhr6.deviation === -1, "RHR +6 bpm = mild flag");

  const devsGuard = computeDeviations({ ...healthyDays[0], resting_hr_bpm: 91 }, baseline, 8000);
  const rhrGuard = devsGuard.find((d) => d.metric === "resting_hr")!;
  assert(rhrGuard.deviation === -2, "RHR >90 guardrail = hard flag");
});

describe("Deviation Detection — Sleep", () => {
  const devGuard = computeDeviations({ ...healthyDays[0], sleep_duration_hrs: 5.0 }, baseline, 8000);
  const sleepGuard = devGuard.find((d) => d.metric === "sleep_duration")!;
  assert(sleepGuard.deviation === -2, "Sleep <5.5h guardrail = hard flag");

  const dev2hr = computeDeviations({ ...healthyDays[0], sleep_duration_hrs: 5.4 }, baseline, 8000);
  const sleep2hr = dev2hr.find((d) => d.metric === "sleep_duration")!;
  assert(sleep2hr.deviation === -2, "Sleep 2h below baseline = hard flag");
});

describe("Top-2 Driver Selection", () => {
  const devs = computeDeviations(
    { ...healthyDays[0], hrv_ms: 30, resting_hr_bpm: 70, sleep_duration_hrs: 5.0 },
    baseline,
    8000
  );
  const { driver_1, driver_2 } = selectTopDrivers(devs);
  assert(["hrv", "resting_hr", "sleep_duration"].includes(driver_1), "Driver 1 is flagged metric");
  assert(["hrv", "resting_hr", "sleep_duration"].includes(driver_2), "Driver 2 is flagged metric");
  assert(driver_1 !== driver_2, "Drivers are distinct");
});

describe("Full Score — Healthy Day", () => {
  const result = scoreDay({
    input: healthyDays[6],
    baseline,
    historyDays: 7,
    recentScores: [85, 87, 88],
  });
  assert(result.chronos_score >= 75, "Healthy day scores ≥75");
  assert(result.score_band === "Thriving" || result.score_band === "Recovering", "Healthy day in upper bands");
  assert(result.fail_state === null, "No fail state on healthy day");
  assert(result.driver_1 !== result.driver_2, "Two distinct drivers");
  assert(result.domain_version === "1.1", "Domain version stamped");
});

describe("Full Score — Redline Day", () => {
  const result = scoreDay({
    input: { ...healthyDays[0], hrv_ms: 20, resting_hr_bpm: 90, sleep_duration_hrs: 5.0 },
    baseline,
    historyDays: 7,
    recentScores: [82, 75, 68],
  });
  assert(result.fail_state === "Redline", "Redline triggered on acute stress");
});

describe("Delta Override", () => {
  const result = scoreDay({
    input: { ...healthyDays[0], hrv_ms: 50 },
    baseline,
    historyDays: 7,
    recentScores: [90, 91, 90], // avg 90.3, drop of >15 will trigger if score <75
  });
  // Only way to verify: if score drops >15 from 3-day avg
  const avg3 = (90 + 91 + 90) / 3;
  if (avg3 - result.chronos_score > 15) {
    assert(result.delta_override_triggered === true, "Delta override triggered");
  } else {
    assert(result.delta_override_triggered === false, "Delta override not triggered when drop ≤15");
  }
});

describe("Determinism", () => {
  const input = healthyDays[6];
  const r1 = scoreDay({ input, baseline, historyDays: 7, recentScores: [80, 82, 81] });
  const r2 = scoreDay({ input, baseline, historyDays: 7, recentScores: [80, 82, 81] });
  assert(r1.chronos_score === r2.chronos_score, "Identical inputs produce identical scores");
  assert(r1.driver_1 === r2.driver_1, "Identical inputs produce identical driver_1");
  assert(r1.driver_2 === r2.driver_2, "Identical inputs produce identical driver_2");
});

describe("Provisional Scoring", () => {
  const result = scoreDay({
    input: healthyDays[0],
    baseline: null,
    historyDays: 1,
    recentScores: [],
  });
  assert(result.is_provisional === true, "No baseline = provisional");
});

console.log("\n✅ All tests passed\n");
