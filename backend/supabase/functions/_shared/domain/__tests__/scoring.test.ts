// backend/supabase/functions/_shared/domain/__tests__/scoring.test.ts
// MBI Scoring Engine — Unit Tests (Deno.test) against the canonical _shared/domain.
//
// BINDING CONSTRAINT (Phase C/D, founder): every expected value is derived from a
// documented, authoritative rule — NOT mirrored from current code output, NOT from
// code comments. A test must be able to FAIL when the code is wrong.
//
// SCOPE: four fully-traceable groups only. The numeric deviation THRESHOLD groups
// (HRV/RHR/resp/steps/active-min/sleep/SpO2/stand-hours) are intentionally HELD —
// they trace to a consolidated v1.5 Logic Registry that does not yet exist in the
// repo. They are a follow-on work item gated on that Registry. See ./README.md.

import { getScoreBand, scoreDay } from "../scoring.ts";
import { selectTopDrivers } from "../drivers.ts";
import type { Baseline, DailyInput, MetricDeviation } from "../contracts.ts";
import { DOMAIN_VERSION } from "../contracts.ts";

// ── minimal assert helpers (no external dep / network) ──────────────────────
function assert(cond: boolean, msg: string) { if (!cond) throw new Error(`FAIL: ${msg}`); }
function eq<T>(a: T, b: T, msg: string) { if (a !== b) throw new Error(`FAIL: ${msg} (got ${JSON.stringify(a)}, expected ${JSON.stringify(b)})`); }

// ════════════════════════════════════════════════════════════════════════════
// GROUP 1 — SCORE BANDS
// SOURCE: Founder approval (2026-06) + Canonical Backend Architecture v1.2 +
//         contracts.ts v1.5 ScoreBand. Documented ranges:
//         Thriving 80+ · Recovering 70–79 · Yellowline 60–69 · Drifting 40–59 · Redline <40.
// Expectations are the documented range boundaries, not observed output.
// ════════════════════════════════════════════════════════════════════════════
Deno.test("bands: Thriving is 80 and above", () => {
  eq(getScoreBand(100), "Thriving", "100 → Thriving");
  eq(getScoreBand(80), "Thriving", "80 (lower bound) → Thriving");
});
Deno.test("bands: Recovering is 70–79", () => {
  eq(getScoreBand(79), "Recovering", "79 (upper bound) → Recovering");
  eq(getScoreBand(70), "Recovering", "70 (lower bound) → Recovering");
});
Deno.test("bands: Yellowline is 60–69 (v1.5)", () => {
  eq(getScoreBand(69), "Yellowline", "69 (upper bound) → Yellowline");
  eq(getScoreBand(60), "Yellowline", "60 (lower bound) → Yellowline");
});
Deno.test("bands: Drifting is 40–59", () => {
  eq(getScoreBand(59), "Drifting", "59 (upper bound) → Drifting");
  eq(getScoreBand(40), "Drifting", "40 (lower bound) → Drifting");
});
Deno.test("bands: Redline is below 40", () => {
  eq(getScoreBand(39), "Redline", "39 (upper bound) → Redline");
  eq(getScoreBand(0), "Redline", "0 → Redline");
});

// ════════════════════════════════════════════════════════════════════════════
// GROUP 2 — DETERMINISM + WITHIN-USER PRIMACY
// SOURCE: Non-Negotiable #1 (deterministic: identical inputs → identical outputs)
//         and Non-Negotiable #2 (within-user: scoring compares to the user's own
//         personal baseline, never population constants).
// ════════════════════════════════════════════════════════════════════════════
const personalBaseline: Baseline = {
  hrv_avg: 45, resting_hr_avg: 60, respiratory_rate_avg: 15,
  sleep_duration_avg: 7, sleep_continuity_avg: 90,
  steps_avg: 8000, active_minutes_avg: 30, window_days: 30,
};
const aDay: DailyInput = {
  userId: "u", date: "2026-06-01",
  hrv_ms: 45, resting_hr_bpm: 60, respiratory_rate_rpm: 15,
  sleep_duration_hrs: 7, sleep_continuity_pct: 90, steps: 8000, active_minutes: 30,
};

Deno.test("determinism: identical inputs produce identical outputs (NN #1)", () => {
  const a = scoreDay({ input: aDay, baseline: personalBaseline, historyDays: 30, recentScores: [80, 80, 80] });
  const b = scoreDay({ input: aDay, baseline: personalBaseline, historyDays: 30, recentScores: [80, 80, 80] });
  eq(a.chronos_score, b.chronos_score, "chronos_score is deterministic");
  eq(a.score_band, b.score_band, "score_band is deterministic");
  eq(a.health_score, b.health_score, "health_score is deterministic");
  eq(a.risk_score, b.risk_score, "risk_score is deterministic");
  eq(a.driver_1, b.driver_1, "driver_1 is deterministic");
  eq(a.driver_2, b.driver_2, "driver_2 is deterministic");
  eq(a.fail_state, b.fail_state, "fail_state is deterministic");
});

Deno.test("within-user primacy: identical input scores differently under different personal baselines (NN #2)", () => {
  // The SAME physiological day, judged against two different personal baselines.
  // If scoring used population constants, both would score identically.
  // Matched baseline = the day is the user's own norm; Fitter baseline = the day is
  // far below a much healthier personal norm.
  const fitterBaseline: Baseline = {
    hrv_avg: 120, resting_hr_avg: 45, respiratory_rate_avg: 12,
    sleep_duration_avg: 9, sleep_continuity_avg: 99,
    steps_avg: 18000, active_minutes_avg: 120, window_days: 30,
  };
  const matched = scoreDay({ input: aDay, baseline: personalBaseline, historyDays: 30, recentScores: [80, 80, 80] });
  const fitter  = scoreDay({ input: aDay, baseline: fitterBaseline,  historyDays: 30, recentScores: [80, 80, 80] });

  assert(matched.chronos_score !== null && fitter.chronos_score !== null, "both produce a score");
  assert(matched.chronos_score !== fitter.chronos_score,
    "same input must score differently under different personal baselines (within-user, not population)");
  assert((matched.chronos_score as number) > (fitter.chronos_score as number),
    "a day matching the user's own baseline scores higher than one far below a healthier baseline");
});

// ════════════════════════════════════════════════════════════════════════════
// GROUP 3 — PROVISIONAL / NULL-BASELINE
// SOURCE: D12 (four-tier confidence model; NO synthetic score for users without a
//         usable baseline — 0–2 day users see a baseline-building state, not a number).
// ════════════════════════════════════════════════════════════════════════════
Deno.test("provisional: no baseline yields no synthetic score (D12)", () => {
  const r = scoreDay({ input: aDay, baseline: null, historyDays: 1, recentScores: [] });
  eq(r.chronos_score, null, "no baseline → chronos_score is null (no synthetic score)");
  eq(r.score_band, null, "no baseline → score_band is null");
  eq(r.is_provisional, true, "no baseline → is_provisional is true");
  eq(r.confidence_tier, "none", "no baseline / <3 days → confidence_tier none");
  eq(r.domain_version, DOMAIN_VERSION, "domain_version is stamped (v1.5)");
});

// ════════════════════════════════════════════════════════════════════════════
// GROUP 4 — NULL driver_2 PATH
// SOURCE: contracts.ts ScoringResult.driver_2 : MetricName | null (driver_2 is
//         explicitly nullable) + the driver-selection fix rationale (when a second
//         distinct weighted metric exists, driver_2 must be that metric, not null).
// ════════════════════════════════════════════════════════════════════════════
Deno.test("drivers: driver_2 is null when only one metric carries weight", () => {
  // Only one weighted metric exists → there is no possible second driver → null.
  const devs: MetricDeviation[] = [
    { metric: "steps",    value: 1000, deviation: -1, weight: 1 },
    { metric: "distance", value: 0,    deviation: 0,  weight: 0 },
  ];
  const { driver_1, driver_2 } = selectTopDrivers(devs);
  eq(driver_1, "steps", "the single weighted metric is driver_1");
  eq(driver_2, null, "no second weighted metric → driver_2 is null (contract permits null)");
});

Deno.test("drivers: driver_2 is a distinct second metric when one exists (fix)", () => {
  // Two weighted metrics present (steps flagged, hrv weighted-but-unflagged).
  // The fix guarantees driver_2 falls back to the next weighted metric rather than null.
  const devs: MetricDeviation[] = [
    { metric: "steps", value: 1000, deviation: -1, weight: 1 },
    { metric: "hrv",   value: 50,   deviation: 0,  weight: 2 },
  ];
  const { driver_1, driver_2 } = selectTopDrivers(devs);
  assert(driver_2 !== null, "a second weighted metric exists → driver_2 is not null");
  assert(driver_1 !== driver_2, "driver_1 and driver_2 are distinct (never duplicated)");
});
