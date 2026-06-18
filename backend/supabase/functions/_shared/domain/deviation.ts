// backend/supabase/functions/_shared/domain/deviation.ts
// MBI Scoring Engine — Deviation Detection
// Version: 1.4 | Learning Foundation v1.0 (May 2026)
// D3: sleep_efficiency→sleep_continuity; standalone >=8% hard removed; corroboration required
// D4: HRV <25ms absolute guardrail demoted to LOW_ABSOLUTE_RESERVE reserve flag
// D5: RHR >90bpm demoted to HIGH_ABSOLUTE_RHR; SAFETY_OVERRIDE_RHR at >100bpm
// D13: deviateSpo2() weight 1.0; deviateStandHours() weight 0.25; resting_energy weight 0
// Total weight pool: 11 → 12.25

import type { Baseline, DailyInput, DeviationState, MetricDeviation, ReserveFlag } from "./contracts.ts";

export const METRIC_WEIGHTS: Record<string, number> = {
  hrv:              2,
  resting_hr:       2,
  respiratory_rate: 2,
  sleep_duration:   1.5,
  sleep_continuity: 1.5,
  steps:            1,
  active_minutes:   1,
  spo2:             1.0,
  stand_hours:      0.25,
  resting_energy:   0,
  distance:         0,
};

// HRV — three-layer framework (D4)
// Relative thresholds unchanged. <25ms is now reserve flag only, not hard deviation.
function deviateHRV(
  value: number | null | undefined,
  baseline: Baseline,
): { deviation: DeviationState; reserve_flag: ReserveFlag } {
  if (value == null || baseline.hrv_avg == null) return { deviation: 0, reserve_flag: null };
  const pctBelow = (baseline.hrv_avg - value) / baseline.hrv_avg;
  if (pctBelow > 0.30) return { deviation: -2, reserve_flag: null };
  if (pctBelow >= 0.15) return { deviation: -1, reserve_flag: null };
  // Use personal p10 if available (trust state provisional or higher).
  // Fall back to hardcoded 25ms only if p10 not yet computed.
  const hrvFloor = baseline.p10_hrv_7d ?? 25;
  const reserve_flag: ReserveFlag = value < hrvFloor ? "LOW_ABSOLUTE_RESERVE" : null;
  return { deviation: 0, reserve_flag };
}

// RHR — three-layer framework (D5)
// Relative thresholds unchanged. >90bpm is reserve flag. >100bpm is safety override.
function deviateRHR(
  value: number | null | undefined,
  baseline: Baseline,
): { deviation: DeviationState; reserve_flag: ReserveFlag } {
  if (value == null || baseline.resting_hr_avg == null) return { deviation: 0, reserve_flag: null };
  const diff = value - baseline.resting_hr_avg;
  if (diff >= 10) return { deviation: -2, reserve_flag: null };
  if (diff >= 5)  return { deviation: -1, reserve_flag: null };
  if (value > 100) return { deviation: 0, reserve_flag: "SAFETY_OVERRIDE_RHR" };
  // Use personal p90 if available. Fall back to 90bpm if not yet computed.
  const rhrCeiling = baseline.p90_resting_hr ?? 90;
  if (value > rhrCeiling) return { deviation: 0, reserve_flag: "HIGH_ABSOLUTE_RHR" };
  return { deviation: 0, reserve_flag: null };
}

// Respiratory Rate (unchanged)
function deviateRespRate(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null || baseline.respiratory_rate_avg == null) return 0;
  if (value > 20) return -2;
  const diff = value - baseline.respiratory_rate_avg;
  if (diff >= 4) return -2;
  if (diff >= 2) return -1;
  return 0;
}

// Sleep Duration
// Absolute floor: < 5.5h is clinically significant sleep deprivation for adults
// (AASM / NIH threshold). Hard-flag regardless of personal baseline.
// Sub-2h floor: catastrophic extreme — overrides sleep_continuity in post-processing.
// Relative checks provide an additional layer for users with a long-term short-sleep pattern.
function deviateSleepDuration(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null || baseline.sleep_duration_avg == null) return 0;
  if (value < 5.5) return -2;   // absolute clinical floor
  const diff = baseline.sleep_duration_avg - value;
  if (diff >= 2) return -2;
  if (diff >= 1) return -1;
  return 0;
}

// Sleep Continuity (renamed from Sleep Efficiency — D3)
// Base function: <70% absolute → hard; >=5% below baseline → mild.
// >=8% below baseline hard requires corroboration (applied in post-processing).
// Locked Phase 1 decision: corroboration required for relative hard escalation.
function deviateSleepContinuityBase(
  value: number | null | undefined,
  baseline: Baseline,
): DeviationState {
  if (value == null || baseline.sleep_continuity_avg == null) return 0;
  if (value < 70) return -2;  // absolute: standalone hard, no corroboration needed
  const diff = baseline.sleep_continuity_avg - value;
  if (diff >= 5) return -1;   // mild standalone; post-processing may upgrade to hard with corroboration
  return 0;
}

// SpO2 — overnight average, device-conditional (D13)
function deviateSpo2(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null || baseline.spo2_avg == null) return 0;
  const diff = baseline.spo2_avg - value;
  if (diff >= 5) return -2;
  if (diff >= 3) return -1;
  return 0;
}

// Stand Hours — sedentary floor detector (D13)
// Never hard standalone — post-processing upgrades when all three activity metrics flagged.
function deviateStandHoursBase(
  value: number | null | undefined,
  baseline: Baseline,
): DeviationState {
  if (value == null) return 0;
  const diff = baseline.stand_hours_avg != null ? baseline.stand_hours_avg - value : 0;
  if (value < 4 || diff > 5) return -1;
  return 0;
}

// Steps (unchanged)
function deviateSteps(value: number | null | undefined, stepGoal: number): DeviationState {
  if (value == null) return 0;
  if (value < stepGoal * 0.5) return -2;
  if (value < stepGoal) return -1;
  return 0;
}

// Active Minutes (unchanged)
function deviateActiveMinutes(value: number | null | undefined): DeviationState {
  if (value == null) return 0;
  if (value < 10) return -2;
  if (value < 20) return -1;
  return 0;
}

export interface DeviationContext {
  prevSleepContinuityDeviation?: DeviationState | null;
}

export function computeDeviations(
  input: DailyInput,
  baseline: Baseline,
  stepGoal: number = 8000,
  context: DeviationContext = {},
): MetricDeviation[] {

  const hrvResult  = deviateHRV(input.hrv_ms, baseline);
  const rhrResult  = deviateRHR(input.resting_hr_bpm, baseline);
  const respRate   = deviateRespRate(input.respiratory_rate_rpm, baseline);
  const sleepDur   = deviateSleepDuration(input.sleep_duration_hrs, baseline);
  const sleepContBase = deviateSleepContinuityBase(input.sleep_continuity_pct, baseline);
  const stepsDeviation = deviateSteps(input.steps, stepGoal);
  const activeMins = deviateActiveMinutes(input.active_minutes);
  const standBase  = deviateStandHoursBase(input.stand_hours, baseline);
  const spo2Dev    = deviateSpo2(input.spo2_pct, baseline);

  // SpO2 absolute reserve: <94% sustained = Low SpO2 Reserve (watchlist)
  const spo2ReserveFlag: ReserveFlag =
    (input.spo2_pct != null && input.spo2_pct < 94 && spo2Dev === 0) ? "LOW_ABSOLUTE_RESERVE" : null;

  // POST-PROCESSING: sleep continuity override for extreme sleep duration
  // When sleep_duration is hard-flagged, the recorded sleep_continuity percentage is
  // computed on an already-compromised session and does not reflect restorative sleep.
  // A 43-minute sleep at 93% continuity is still a catastrophic night — the continuity
  // figure must not inflate the domain score.
  //
  //   < 2h (extreme floor):   force sleep_continuity to -2 (hard override)
  //   -2 from relative diff:  force sleep_continuity to at least -1 (mild override)
  //
  // This prevents d2_sleep from returning > 60 when sleep_duration is hard-flagged.
  let sleepContFinal = sleepContBase;
  let sleepContCorroborated = false;

  if (input.sleep_duration_hrs != null && input.sleep_duration_hrs < 2) {
    // Extreme floor override: catastrophically short sleep → both metrics hard
    sleepContFinal = -2;
    sleepContCorroborated = true;
  } else if (sleepDur === -2 && sleepContFinal === 0) {
    // Relative hard override: sleep is hard-flagged by baseline diff → mild flag continuity
    sleepContFinal = -1;
  } else if (sleepContBase === -1 && input.sleep_continuity_pct != null && baseline.sleep_continuity_avg != null) {
    // Standard corroboration check (unchanged)
    const contDiff = baseline.sleep_continuity_avg - input.sleep_continuity_pct;
    if (contDiff >= 8) {
      const hasCorroboration =
        sleepDur !== 0 ||
        hrvResult.deviation !== 0 ||
        rhrResult.deviation !== 0 ||
        context.prevSleepContinuityDeviation === -1 ||
        context.prevSleepContinuityDeviation === -2;
      if (hasCorroboration) {
        sleepContFinal = -2;
        sleepContCorroborated = true;
      }
    }
  }

  // POST-PROCESSING: stand hours — hard only when all three activity metrics flagged
  const standFinal = (standBase === -1 && stepsDeviation !== 0 && activeMins !== 0) ? -2 : standBase;

  return [
    { metric: "hrv",              value: input.hrv_ms ?? null,               deviation: hrvResult.deviation,  weight: METRIC_WEIGHTS.hrv,              reserve_flag: hrvResult.reserve_flag },
    { metric: "resting_hr",       value: input.resting_hr_bpm ?? null,       deviation: rhrResult.deviation,  weight: METRIC_WEIGHTS.resting_hr,        reserve_flag: rhrResult.reserve_flag },
    { metric: "respiratory_rate", value: input.respiratory_rate_rpm ?? null,  deviation: respRate,             weight: METRIC_WEIGHTS.respiratory_rate,   reserve_flag: null },
    { metric: "sleep_duration",   value: input.sleep_duration_hrs ?? null,   deviation: sleepDur,             weight: METRIC_WEIGHTS.sleep_duration,     reserve_flag: null },
    { metric: "sleep_continuity", value: input.sleep_continuity_pct ?? null, deviation: sleepContFinal,       weight: METRIC_WEIGHTS.sleep_continuity,   reserve_flag: null, corroboration_state: sleepContCorroborated },
    { metric: "steps",            value: input.steps ?? null,                deviation: stepsDeviation,       weight: METRIC_WEIGHTS.steps },
    { metric: "active_minutes",   value: input.active_minutes ?? null,       deviation: activeMins,           weight: METRIC_WEIGHTS.active_minutes },
    { metric: "spo2",             value: input.spo2_pct ?? null,             deviation: spo2Dev,              weight: METRIC_WEIGHTS.spo2,              reserve_flag: spo2ReserveFlag },
    { metric: "stand_hours",      value: input.stand_hours ?? null,          deviation: standFinal,           weight: METRIC_WEIGHTS.stand_hours },
    { metric: "resting_energy",   value: input.resting_energy ?? null,       deviation: 0,                   weight: METRIC_WEIGHTS.resting_energy },
  ];
}
