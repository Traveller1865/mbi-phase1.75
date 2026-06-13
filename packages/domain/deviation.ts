// packages/domain/deviation.ts
// MBI Scoring Engine — Deviation Detection
// Version: 1.2 | H-01: Tier 1 metric expansion

import type { Baseline, DailyInput, DeviationState, MetricDeviation } from "./contracts.ts";

// ─────────────────────────────────────────
// WEIGHTS (SoT §2 + H-01 additions)
// spo2       → D1 Autonomic (respiratory stress) — Weight 1×
// resting_energy → D3 Activity (metabolic)       — Weight 1×
// stand_hours    → D3 Activity (sedentary)        — Weight 1×
// ─────────────────────────────────────────
export const METRIC_WEIGHTS: Record<string, number> = {
  hrv: 2,
  resting_hr: 2,
  respiratory_rate: 2,
  sleep_duration: 1.5,
  sleep_efficiency: 1.5,
  steps: 1,
  active_minutes: 1,
  distance: 0,
  // H-01
  spo2: 1,
  resting_energy: 1,
  stand_hours: 1,
};

// ─────────────────────────────────────────
// HRV (SDNN) — Weight 2× (SoT §4.1)
// ─────────────────────────────────────────
function deviateHRV(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null || baseline.hrv_avg == null) return 0;
  if (value < 25) return -2;
  const pctBelow = (baseline.hrv_avg - value) / baseline.hrv_avg;
  if (pctBelow > 0.30) return -2;
  if (pctBelow >= 0.15) return -1;
  return 0;
}

// ─────────────────────────────────────────
// RESTING HEART RATE — Weight 2× (SoT §4.2)
// ─────────────────────────────────────────
function deviateRHR(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null || baseline.resting_hr_avg == null) return 0;
  if (value > 90) return -2;
  const diff = value - baseline.resting_hr_avg;
  if (diff >= 10) return -2;
  if (diff >= 5) return -1;
  return 0;
}

// ─────────────────────────────────────────
// RESPIRATORY RATE — Weight 2× (SoT §4.3)
// ─────────────────────────────────────────
function deviateRespRate(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null || baseline.respiratory_rate_avg == null) return 0;
  if (value > 20) return -2;
  const diff = value - baseline.respiratory_rate_avg;
  if (diff >= 4) return -2;
  if (diff >= 2) return -1;
  return 0;
}

// ─────────────────────────────────────────
// SLEEP DURATION — Weight 1.5× (SoT §4.4)
// ─────────────────────────────────────────
function deviateSleepDuration(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null || baseline.sleep_duration_avg == null) return 0;
  if (value < 5.5) return -2;
  const diff = baseline.sleep_duration_avg - value;
  if (diff >= 2) return -2;
  if (diff >= 1) return -1;
  return 0;
}

// ─────────────────────────────────────────
// SLEEP EFFICIENCY — Weight 1.5× (SoT §4.5)
// ─────────────────────────────────────────
function deviateSleepEfficiency(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null || baseline.sleep_efficiency_avg == null) return 0;
  if (value < 70) return -2;
  const diff = baseline.sleep_efficiency_avg - value;
  if (diff >= 8) return -2;
  if (diff >= 5) return -1;
  return 0;
}

// ─────────────────────────────────────────
// STEPS — Weight 1× behavioral (SoT §4.6)
// ─────────────────────────────────────────
function deviateSteps(value: number | null | undefined, stepGoal: number): DeviationState {
  if (value == null) return 0;
  if (value < stepGoal * 0.5) return -2;
  if (value < stepGoal) return -1;
  return 0;
}

// ─────────────────────────────────────────
// ACTIVE MINUTES — Weight 1× behavioral (SoT §4.7)
// ─────────────────────────────────────────
function deviateActiveMinutes(value: number | null | undefined): DeviationState {
  if (value == null) return 0;
  if (value < 10) return -2;
  if (value < 20) return -1;
  return 0;
}

// ─────────────────────────────────────────
// SPO2 — Weight 1× (H-01 / D1 Autonomic)
// Guardrail: <92% = hard flag (clinical low O2 territory)
// Mild: 92–94% (suppressed but not critical)
// Normal: ≥95%
// Missing baseline → compare to absolute guardrails only
// ─────────────────────────────────────────
function deviateSpO2(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null) return 0;
  if (value < 92) return -2;
  if (value < 95) return -1;
  // If personal baseline exists and today is below it by >3%, flag mild
  if (baseline.spo2_avg != null) {
    const diff = baseline.spo2_avg - value;
    if (diff >= 3) return -1;
  }
  return 0;
}

// ─────────────────────────────────────────
// RESTING ENERGY — Weight 1× (H-01 / D3 Activity)
// Metabolic suppression signal.
// Uses personal baseline only — no universal guardrail
// (highly individual: varies by body composition, age, sex)
// Mild: >15% below personal baseline
// Hard: >30% below personal baseline
// Missing baseline → no deviation (cannot judge without context)
// ─────────────────────────────────────────
function deviateRestingEnergy(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null || baseline.resting_energy_avg == null) return 0;
  const pctBelow = (baseline.resting_energy_avg - value) / baseline.resting_energy_avg;
  if (pctBelow > 0.30) return -2;
  if (pctBelow >= 0.15) return -1;
  return 0;
}

// ─────────────────────────────────────────
// STAND HOURS — Weight 1× (H-01 / D3 Activity)
// Apple's goal is 12 stand hours. Use that as the behavioral target.
// Hard: <6 stand hours (half of goal — sedentary day)
// Mild: <9 stand hours (below goal but not severe)
// Normal: ≥9 stand hours
// Personal baseline check: if below baseline by >3 hrs, flag mild
// ─────────────────────────────────────────
function deviateStandHours(value: number | null | undefined, baseline: Baseline): DeviationState {
  if (value == null) return 0;
  if (value < 6) return -2;
  if (value < 9) return -1;
  if (baseline.stand_hours_avg != null) {
    const diff = baseline.stand_hours_avg - value;
    if (diff >= 3) return -1;
  }
  return 0;
}

// ─────────────────────────────────────────
// MAIN: compute all deviations
// Architecture: every metric is optional.
// null value → deviation = 0, metric participates with 0 weight effectively
// (weight stays in array but deviation = 0 → no penalty, no benefit)
// ─────────────────────────────────────────
export function computeDeviations(
  input: DailyInput,
  baseline: Baseline,
  stepGoal: number = 8000
): MetricDeviation[] {
  return [
    {
      metric: "hrv",
      value: input.hrv_ms ?? null,
      deviation: deviateHRV(input.hrv_ms, baseline),
      weight: METRIC_WEIGHTS.hrv,
    },
    {
      metric: "resting_hr",
      value: input.resting_hr_bpm ?? null,
      deviation: deviateRHR(input.resting_hr_bpm, baseline),
      weight: METRIC_WEIGHTS.resting_hr,
    },
    {
      metric: "respiratory_rate",
      value: input.respiratory_rate_rpm ?? null,
      deviation: deviateRespRate(input.respiratory_rate_rpm, baseline),
      weight: METRIC_WEIGHTS.respiratory_rate,
    },
    {
      metric: "sleep_duration",
      value: input.sleep_duration_hrs ?? null,
      deviation: deviateSleepDuration(input.sleep_duration_hrs, baseline),
      weight: METRIC_WEIGHTS.sleep_duration,
    },
    {
      metric: "sleep_efficiency",
      value: input.sleep_efficiency_pct ?? null,
      deviation: deviateSleepEfficiency(input.sleep_efficiency_pct, baseline),
      weight: METRIC_WEIGHTS.sleep_efficiency,
    },
    {
      metric: "steps",
      value: input.steps ?? null,
      deviation: deviateSteps(input.steps, stepGoal),
      weight: METRIC_WEIGHTS.steps,
    },
    {
      metric: "active_minutes",
      value: input.active_minutes ?? null,
      deviation: deviateActiveMinutes(input.active_minutes),
      weight: METRIC_WEIGHTS.active_minutes,
    },
    // H-01: Tier 1 metrics
    {
      metric: "spo2",
      value: input.spo2_pct ?? null,
      deviation: deviateSpO2(input.spo2_pct, baseline),
      weight: METRIC_WEIGHTS.spo2,
    },
    {
      metric: "resting_energy",
      value: input.resting_energy ?? null,
      deviation: deviateRestingEnergy(input.resting_energy, baseline),
      weight: METRIC_WEIGHTS.resting_energy,
    },
    {
      metric: "stand_hours",
      value: input.stand_hours ?? null,
      deviation: deviateStandHours(input.stand_hours, baseline),
      weight: METRIC_WEIGHTS.stand_hours,
    },
  ];
}