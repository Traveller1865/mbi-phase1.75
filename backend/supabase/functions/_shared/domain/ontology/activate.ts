// _shared/domain/ontology/activate.ts
// Ontology Engine v1 — Node Activation Rules (all 12)
// Ontology version: phase1_75-v1.0
//
// INVARIANT: Every rule is a deterministic threshold comparison.
// No LLM call, no probabilistic output, no population norms.
// All thresholds use personal baselines (within-user percentiles).
//
// Activation strength formula (all v1 rules):
//   strength = Math.min(days_meeting_threshold / required_days_in_window, 1.0)

import type {
  ActivationResult,
  ContributingMetric,
  DailyInputRow,
  DailyScoreRow,
  BaselinesRow,
  NodeActivationRow,
  EvaluationContext,
  TrustState,
} from "./types.ts";

// ─────────────────────────────────────────
// DATA COMPLETENESS GATES (v1.1 Hardening)
// Each node has a minimum data presence requirement before its rule fires.
// Returns false → rule returns { is_active: false, skipped_reason: 'insufficient_data' }
// ─────────────────────────────────────────

function countInputDays(rows: DailyInputRow[], pred: (r: DailyInputRow) => boolean): number {
  return rows.filter(pred).length;
}

function countScoreDays(rows: DailyScoreRow[], pred: (r: DailyScoreRow) => boolean): number {
  return rows.filter(pred).length;
}

export function checkDataCompleteness(
  nodeKey: string,
  inputWindow: DailyInputRow[],
  scoresWindow?: DailyScoreRow[],
): boolean {
  switch (nodeKey) {
    case "poor_sleep_quality":
    case "quality_sleep":
      // sleep_duration_hrs + sleep_continuity: 5 of last 7 days
      return countInputDays(inputWindow, r => r.sleep_duration_hrs != null && r.sleep_continuity_pct != null) >= 5;

    case "physical_inactivity":
    case "daily_exercise":
      // steps + active_minutes: 5 of last 7 days
      return countInputDays(inputWindow, r => r.steps != null && r.active_minutes != null) >= 5;

    case "circadian_disruption":
      // sleep_start_time / wake_time not stored — use sleep_duration_hrs as proxy: 5 of last 7
      return countInputDays(inputWindow, r => r.sleep_duration_hrs != null) >= 5;

    case "low_hrv":
      // hrv: 4 of last 5 days
      return countInputDays(inputWindow, r => r.hrv_ms != null) >= 4;

    case "elevated_resting_hr":
      // resting_hr: 4 of last 5 days
      return countInputDays(inputWindow, r => r.resting_hr_bpm != null) >= 4;

    case "autonomic_dysfunction": {
      // hrv + resting_hr: 4/5; respiratory_rate: 3/5
      const hrvRhr = countInputDays(inputWindow, r => r.hrv_ms != null && r.resting_hr_bpm != null);
      const resp   = countInputDays(inputWindow, r => r.respiratory_rate_rpm != null);
      return hrvRhr >= 4 && resp >= 3;
    }

    case "sympathetic_dominance": {
      // All 4 consecutive required days must have hrv + resting_hr
      if (inputWindow.length < 4) return false;
      return inputWindow.slice(-4).every(r => r.hrv_ms != null && r.resting_hr_bpm != null);
    }

    case "sleep_fragmentation":
      // sleep_continuity + sleep_duration_hrs: 5 of last 7 days
      return countInputDays(inputWindow, r => r.sleep_continuity_pct != null && r.sleep_duration_hrs != null) >= 5;

    case "sustained_recovery_deficit":
      // hrv + (sleep_dur or sleep_cont) + (steps or active_minutes): 5 of last 7
      return countInputDays(inputWindow, r =>
        r.hrv_ms != null &&
        (r.sleep_duration_hrs != null || r.sleep_continuity_pct != null) &&
        (r.steps != null || r.active_minutes != null),
      ) >= 5;

    case "recovery_load_imbalance": {
      // D3 score (5/7) + hrv or resting_hr (5/7)
      const hrvRhr2 = countInputDays(inputWindow, r => r.hrv_ms != null || r.resting_hr_bpm != null);
      const d3days  = scoresWindow
        ? countScoreDays(scoresWindow, r => r.d3_activity != null)
        : 0;
      return hrvRhr2 >= 5 && d3days >= 5;
    }

    default:
      return true; // unknown node — do not gate
  }
}

// ─────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────

function isWeekendDate(dateStr: string): boolean {
  const day = new Date(dateStr).getUTCDay();
  return day === 0 || day === 6;
}

function last(rows: DailyInputRow[], n: number): DailyInputRow[] {
  return rows.slice(-n);
}

function computeHRV7dAvg(rows: DailyInputRow[], upToIndex: number): number | null {
  const window = rows
    .slice(Math.max(0, upToIndex - 6), upToIndex + 1)
    .map(r => r.hrv_ms)
    .filter((v): v is number => v != null);
  if (window.length === 0) return null;
  return window.reduce((a, b) => a + b, 0) / window.length;
}

function notEnoughTrust(required: "provisional" | "trusted", trust: TrustState): boolean {
  const order: TrustState[] = ["establishing", "calibrating", "provisional", "trusted", "established"];
  return order.indexOf(trust) < order.indexOf(required);
}

function strengthFromDays(daysMet: number, required: number): number {
  if (daysMet < required) return 0;
  return Math.min(daysMet / required, 1.0);
}

function consecutiveDaysActive(priorActivations: NodeActivationRow[], nodeKey: string, beforeDate: string, requiredDays: number): number {
  // Returns the count of consecutive days immediately before `beforeDate` where node was active
  const active = priorActivations
    .filter(a => a.node_key === nodeKey && a.is_active && a.activation_date < beforeDate)
    .sort((a, b) => b.activation_date.localeCompare(a.activation_date)); // descending
  let streak = 0;
  let prev: Date | null = null;
  for (const row of active) {
    const d = new Date(row.activation_date);
    if (prev === null) {
      streak = 1;
      prev = d;
    } else {
      const diff = Math.round((prev.getTime() - d.getTime()) / 86_400_000);
      if (diff === 1) { streak++; prev = d; }
      else break;
    }
    if (streak >= requiredDays) return streak;
  }
  return streak;
}

// ─────────────────────────────────────────
// RULE 1 — poor_sleep_quality
// ≥ provisional
// sleep_duration_hrs < p20 OR sleep_continuity_pct < p20
// on 3+ of last 7 days
// ─────────────────────────────────────────

export function evalPoorSleepQuality(ctx: EvaluationContext): ActivationResult {
  const NODE = "poor_sleep_quality";
  if (notEnoughTrust("provisional", ctx.trustState)) return noActivation(NODE);
  const window = last(ctx.inputs30d, 7);
  if (!checkDataCompleteness(NODE, window)) return noActivation(NODE, "insufficient_data");
  const b = ctx.baselines;
  const p20dur = b.p20_sleep_duration;
  const p20cont = b.p20_sleep_continuity;
  if (p20dur == null && p20cont == null) return noActivation(NODE);

  const contributing: ContributingMetric[] = [];
  let daysMet = 0;
  for (const row of window) {
    const durBad  = p20dur  != null && row.sleep_duration_hrs   != null && row.sleep_duration_hrs  < p20dur;
    const contBad = p20cont != null && row.sleep_continuity_pct != null && row.sleep_continuity_pct < p20cont;
    if (durBad || contBad) daysMet++;
    if (durBad && row.sleep_duration_hrs != null && p20dur != null) {
      contributing.push({ metric_key: "sleep_duration_hrs", direction: "below_baseline", deviation_magnitude: round2(p20dur - row.sleep_duration_hrs) });
    }
    if (contBad && row.sleep_continuity_pct != null && p20cont != null) {
      contributing.push({ metric_key: "sleep_continuity", direction: "below_baseline", deviation_magnitude: round2(p20cont - row.sleep_continuity_pct) });
    }
  }
  const required = 3;
  const is_active = daysMet >= required;
  return {
    node_key: NODE,
    is_active,
    activation_strength: is_active ? strengthFromDays(daysMet, required) : 0,
    contributing_metrics: is_active ? dedup(contributing) : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 2 — physical_inactivity
// ≥ provisional
// steps < p20 AND active_minutes < p20 on 4+ of last 7 days
// ─────────────────────────────────────────

export function evalPhysicalInactivity(ctx: EvaluationContext): ActivationResult {
  const NODE = "physical_inactivity";
  if (notEnoughTrust("provisional", ctx.trustState)) return noActivation(NODE);
  const b = ctx.baselines;
  const window = last(ctx.inputs30d, 7);
  if (!checkDataCompleteness(NODE, window)) return noActivation(NODE, "insufficient_data");
  let daysMet = 0;
  const contributing: ContributingMetric[] = [];
  for (const row of window) {
    const weekend = isWeekendDate(row.date);
    const p20steps = weekend ? b.p20_steps_weekend : b.p20_steps_weekday;
    const p20am    = weekend ? b.p20_active_minutes_weekend : b.p20_active_minutes_weekday;
    const stepsBad = p20steps != null && row.steps != null && row.steps < p20steps;
    const amBad    = p20am    != null && row.active_minutes != null && row.active_minutes < p20am;
    if (stepsBad && amBad) {
      daysMet++;
      if (p20steps != null && row.steps != null) contributing.push({ metric_key: "steps", direction: "below_baseline", deviation_magnitude: round2(p20steps - row.steps) });
      if (p20am != null && row.active_minutes != null) contributing.push({ metric_key: "active_minutes", direction: "below_baseline", deviation_magnitude: round2(p20am - row.active_minutes) });
    }
  }
  const required = 4;
  const is_active = daysMet >= required;
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? strengthFromDays(daysMet, required) : 0,
    contributing_metrics: is_active ? dedup(contributing) : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 3 — circadian_disruption
// ≥ trusted (21d)
// Sleep duration standard deviation > 1.5 hours across last 7 days
// (proxy for schedule variance — sleep_start_time not in daily_inputs)
// Requires 5+ days with sleep data in window.
// ─────────────────────────────────────────

export function evalCircadianDisruption(ctx: EvaluationContext): ActivationResult {
  const NODE = "circadian_disruption";
  if (notEnoughTrust("trusted", ctx.trustState)) return noActivation(NODE);
  const window = last(ctx.inputs30d, 7);
  if (!checkDataCompleteness(NODE, window)) return noActivation(NODE, "insufficient_data");
  const durVals = window.map(r => r.sleep_duration_hrs).filter((v): v is number => v != null);
  if (durVals.length < 5) return noActivation(NODE);
  const mean = durVals.reduce((a, b) => a + b, 0) / durVals.length;
  const variance = durVals.reduce((sum, v) => sum + (v - mean) ** 2, 0) / durVals.length;
  const stdev = Math.sqrt(variance);
  const is_active = stdev > 1.5;
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? Math.min(stdev / 1.5 - 1 + 1, 1.0) : 0, // strength proportional to excess
    contributing_metrics: is_active ? [{ metric_key: "sleep_duration_hrs", direction: "variance_high", deviation_magnitude: round2(stdev) }] : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 4 — low_hrv
// ≥ provisional
// hrv_7d_rolling_avg < p20_hrv_7d on 3+ of last 5 days
// ─────────────────────────────────────────

export function evalLowHRV(ctx: EvaluationContext): ActivationResult {
  const NODE = "low_hrv";
  if (notEnoughTrust("provisional", ctx.trustState)) return noActivation(NODE);
  const p20 = ctx.baselines.p20_hrv_7d;
  if (p20 == null) return noActivation(NODE);
  const allRows = ctx.inputs30d;
  const last5Idx = Math.max(0, allRows.length - 5);
  if (!checkDataCompleteness(NODE, allRows.slice(last5Idx))) return noActivation(NODE, "insufficient_data");
  let daysMet = 0;
  const contributing: ContributingMetric[] = [];
  for (let i = last5Idx; i < allRows.length; i++) {
    const avg7d = computeHRV7dAvg(allRows, i);
    if (avg7d != null && avg7d < p20) {
      daysMet++;
      contributing.push({ metric_key: "hrv", direction: "below_baseline", deviation_magnitude: round2(p20 - avg7d) });
    }
  }
  const required = 3;
  const is_active = daysMet >= required;
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? strengthFromDays(daysMet, required) : 0,
    contributing_metrics: is_active ? dedup(contributing) : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 5 — elevated_resting_hr
// ≥ provisional
// resting_hr_bpm > p80_resting_hr on 3+ of last 5 days
// ─────────────────────────────────────────

export function evalElevatedRestingHR(ctx: EvaluationContext): ActivationResult {
  const NODE = "elevated_resting_hr";
  if (notEnoughTrust("provisional", ctx.trustState)) return noActivation(NODE);
  const p80 = ctx.baselines.p80_resting_hr;
  if (p80 == null) return noActivation(NODE);
  const window = last(ctx.inputs30d, 5);
  if (!checkDataCompleteness(NODE, window)) return noActivation(NODE, "insufficient_data");
  let daysMet = 0;
  const contributing: ContributingMetric[] = [];
  for (const row of window) {
    if (row.resting_hr_bpm != null && row.resting_hr_bpm > p80) {
      daysMet++;
      contributing.push({ metric_key: "resting_hr", direction: "above_baseline", deviation_magnitude: round2(row.resting_hr_bpm - p80) });
    }
  }
  const required = 3;
  const is_active = daysMet >= required;
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? strengthFromDays(daysMet, required) : 0,
    contributing_metrics: is_active ? dedup(contributing) : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 6 — autonomic_dysfunction (composite)
// ≥ provisional
// low_hrv ACTIVE AND elevated_resting_hr ACTIVE
// AND respiratory_rate > respiratory_rate_avg + 2rpm on 2+ of last 5 days
// ─────────────────────────────────────────

export function evalAutonomicDysfunction(
  ctx: EvaluationContext,
  lowHRVActive: boolean,
  elevatedRHRActive: boolean,
): ActivationResult {
  const NODE = "autonomic_dysfunction";
  if (notEnoughTrust("provisional", ctx.trustState)) return noActivation(NODE);
  if (!lowHRVActive || !elevatedRHRActive) return noActivation(NODE);
  if (!checkDataCompleteness(NODE, last(ctx.inputs30d, 5))) return noActivation(NODE, "insufficient_data");
  const avgRR = ctx.baselines.respiratory_rate_avg;
  const threshold = avgRR != null ? avgRR + 2 : null;
  const window = last(ctx.inputs30d, 5);
  let daysMet = 0;
  const contributing: ContributingMetric[] = [];
  for (const row of window) {
    if (threshold != null && row.respiratory_rate_rpm != null && row.respiratory_rate_rpm > threshold) {
      daysMet++;
      contributing.push({ metric_key: "respiratory_rate", direction: "above_baseline", deviation_magnitude: round2(row.respiratory_rate_rpm - threshold) });
    }
  }
  const required = 2;
  const is_active = daysMet >= required;
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? strengthFromDays(daysMet, required) : 0,
    contributing_metrics: is_active ? contributing : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 7 — sympathetic_dominance (composite)
// ≥ provisional
// low_hrv ACTIVE for 4+ consecutive days AND elevated_resting_hr ACTIVE for 4+ consecutive days
// ─────────────────────────────────────────

export function evalSympatheticDominance(
  ctx: EvaluationContext,
  lowHRVActive: boolean,
  elevatedRHRActive: boolean,
): ActivationResult {
  const NODE = "sympathetic_dominance";
  if (notEnoughTrust("provisional", ctx.trustState)) return noActivation(NODE);
  if (!lowHRVActive || !elevatedRHRActive) return noActivation(NODE);
  if (!checkDataCompleteness(NODE, last(ctx.inputs30d, 4))) return noActivation(NODE, "insufficient_data");
  const hrvStreak = consecutiveDaysActive(ctx.priorActivations30d, "low_hrv", ctx.date, 4);
  const rhrStreak = consecutiveDaysActive(ctx.priorActivations30d, "elevated_resting_hr", ctx.date, 4);
  const is_active = hrvStreak >= 4 && rhrStreak >= 4;
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? Math.min(Math.min(hrvStreak, rhrStreak) / 4, 1.0) : 0,
    contributing_metrics: is_active ? [
      { metric_key: "hrv", direction: "below_baseline", deviation_magnitude: hrvStreak },
      { metric_key: "resting_hr", direction: "above_baseline", deviation_magnitude: rhrStreak },
    ] : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 8 — sleep_fragmentation
// ≥ trusted
// sleep_continuity_pct < p20 on 3+ of last 7 days
// WITH sleep_duration_hrs std-dev > 1.5 across same window
// ─────────────────────────────────────────

export function evalSleepFragmentation(ctx: EvaluationContext): ActivationResult {
  const NODE = "sleep_fragmentation";
  if (notEnoughTrust("trusted", ctx.trustState)) return noActivation(NODE);
  const p20cont = ctx.baselines.p20_sleep_continuity;
  if (p20cont == null) return noActivation(NODE);
  const window = last(ctx.inputs30d, 7);
  if (!checkDataCompleteness(NODE, window)) return noActivation(NODE, "insufficient_data");
  let contDaysMet = 0;
  const contributing: ContributingMetric[] = [];
  const durVals: number[] = [];
  for (const row of window) {
    if (row.sleep_continuity_pct != null && row.sleep_continuity_pct < p20cont) {
      contDaysMet++;
      contributing.push({ metric_key: "sleep_continuity", direction: "below_baseline", deviation_magnitude: round2(p20cont - row.sleep_continuity_pct) });
    }
    if (row.sleep_duration_hrs != null) durVals.push(row.sleep_duration_hrs);
  }
  const required = 3;
  if (contDaysMet < required) return noActivation(NODE);
  // Duration variance check
  if (durVals.length < 3) return noActivation(NODE);
  const mean = durVals.reduce((a, b) => a + b, 0) / durVals.length;
  const stdev = Math.sqrt(durVals.reduce((s, v) => s + (v - mean) ** 2, 0) / durVals.length);
  const is_active = stdev > 1.5;
  if (is_active) contributing.push({ metric_key: "sleep_duration_hrs", direction: "variance_high", deviation_magnitude: round2(stdev) });
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? strengthFromDays(contDaysMet, required) : 0,
    contributing_metrics: is_active ? contributing : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 9 — sustained_recovery_deficit (composite)
// ≥ provisional
// low_hrv ACTIVE AND poor_sleep_quality ACTIVE AND physical_inactivity ACTIVE
// for 5+ days within rolling 7-day window (all three simultaneously per day)
// Previously: chronic_fatigue_signal — renamed for regulatory safety (v1.1)
// ─────────────────────────────────────────

export function evalSustainedRecoveryDeficit(
  ctx: EvaluationContext,
  lowHRVActive: boolean,
  poorSleepActive: boolean,
  inactivityActive: boolean,
): ActivationResult {
  const NODE = "sustained_recovery_deficit";
  if (notEnoughTrust("provisional", ctx.trustState)) return noActivation(NODE);
  if (!lowHRVActive || !poorSleepActive || !inactivityActive) return noActivation(NODE);
  if (!checkDataCompleteness(NODE, last(ctx.inputs30d, 7))) return noActivation(NODE, "insufficient_data");
  // Check prior 30d activations: count days all three were active in last 7
  const cutoff = dateMinus(ctx.date, 7);
  const lowHRVDays    = new Set(ctx.priorActivations30d.filter(a => a.node_key === "low_hrv"            && a.is_active && a.activation_date >= cutoff).map(a => a.activation_date));
  const poorSleepDays = new Set(ctx.priorActivations30d.filter(a => a.node_key === "poor_sleep_quality"  && a.is_active && a.activation_date >= cutoff).map(a => a.activation_date));
  const inactDays     = new Set(ctx.priorActivations30d.filter(a => a.node_key === "physical_inactivity" && a.is_active && a.activation_date >= cutoff).map(a => a.activation_date));
  let overlapDays = 0;
  for (const d of lowHRVDays) { if (poorSleepDays.has(d) && inactDays.has(d)) overlapDays++; }
  const required = 5;
  const is_active = overlapDays >= required;
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? strengthFromDays(overlapDays, required) : 0,
    contributing_metrics: is_active ? [
      { metric_key: "hrv", direction: "below_baseline", deviation_magnitude: overlapDays },
      { metric_key: "sleep_duration_hrs", direction: "below_baseline", deviation_magnitude: overlapDays },
      { metric_key: "steps", direction: "below_baseline", deviation_magnitude: overlapDays },
    ] : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 10 — recovery_load_imbalance (composite)
// ≥ provisional
// D3 score > 7d avg D3 + 10 pts AND (low_hrv ACTIVE OR elevated_rhr ACTIVE)
// on 3+ of last 7 days
// ─────────────────────────────────────────

export function evalRecoveryLoadImbalance(
  ctx: EvaluationContext,
  lowHRVActive: boolean,
  elevatedRHRActive: boolean,
): ActivationResult {
  const NODE = "recovery_load_imbalance";
  if (notEnoughTrust("provisional", ctx.trustState)) return noActivation(NODE);
  if (!lowHRVActive && !elevatedRHRActive) return noActivation(NODE);
  if (!checkDataCompleteness(NODE, last(ctx.inputs30d, 7), ctx.scores30d.slice(-7))) return noActivation(NODE, "insufficient_data");
  const scores7d = ctx.scores30d.slice(-7);
  const d3vals = scores7d.map(r => r.d3_activity).filter((v): v is number => v != null);
  if (d3vals.length < 3) return noActivation(NODE);
  const avgD3 = d3vals.reduce((a, b) => a + b, 0) / d3vals.length;
  const threshold = avgD3 + 10;
  let daysMet = 0;
  for (const row of scores7d) {
    if (row.d3_activity != null && row.d3_activity > threshold) daysMet++;
  }
  const required = 3;
  const is_active = daysMet >= required;
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? strengthFromDays(daysMet, required) : 0,
    contributing_metrics: is_active ? [{ metric_key: "active_minutes", direction: "above_baseline", deviation_magnitude: round2(avgD3) }] : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 11 — daily_exercise (PROTECTIVE)
// ≥ provisional
// steps >= p50 AND active_minutes >= p50 on 5+ of last 7 days
// p50 = midpoint of (p20, p80)
// ─────────────────────────────────────────

export function evalDailyExercise(ctx: EvaluationContext): ActivationResult {
  const NODE = "daily_exercise";
  if (notEnoughTrust("provisional", ctx.trustState)) return noActivation(NODE);
  const b = ctx.baselines;
  const window = last(ctx.inputs30d, 7);
  if (!checkDataCompleteness(NODE, window)) return noActivation(NODE, "insufficient_data");
  let daysMet = 0;
  const contributing: ContributingMetric[] = [];
  for (const row of window) {
    const weekend = isWeekendDate(row.date);
    const p20s = weekend ? b.p20_steps_weekend : b.p20_steps_weekday;
    const p80s = weekend ? b.p80_steps_weekend : b.p80_steps_weekday;
    const p20a = weekend ? b.p20_active_minutes_weekend : b.p20_active_minutes_weekday;
    const p80a = weekend ? b.p80_active_minutes_weekend : b.p80_active_minutes_weekday;
    const p50steps = (p20s != null && p80s != null) ? (p20s + p80s) / 2 : null;
    const p50am    = (p20a != null && p80a != null) ? (p20a + p80a) / 2 : null;
    const stepsOk = p50steps != null && row.steps != null && row.steps >= p50steps;
    const amOk    = p50am    != null && row.active_minutes != null && row.active_minutes >= p50am;
    if (stepsOk && amOk) {
      daysMet++;
      if (p50steps != null && row.steps != null) contributing.push({ metric_key: "steps", direction: "above_baseline", deviation_magnitude: round2(row.steps - p50steps) });
    }
  }
  const required = 5;
  const is_active = daysMet >= required;
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? strengthFromDays(daysMet, required) : 0,
    contributing_metrics: is_active ? dedup(contributing) : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// RULE 12 — quality_sleep (PROTECTIVE)
// ≥ provisional
// sleep_duration_hrs within p20-p80 AND sleep_continuity >= p50 on 5+ of last 7 days
// ─────────────────────────────────────────

export function evalQualitySleep(ctx: EvaluationContext): ActivationResult {
  const NODE = "quality_sleep";
  if (notEnoughTrust("provisional", ctx.trustState)) return noActivation(NODE);
  const b = ctx.baselines;
  if (!checkDataCompleteness(NODE, last(ctx.inputs30d, 7))) return noActivation(NODE, "insufficient_data");
  const p20d = b.p20_sleep_duration;
  const p80d = b.p80_sleep_duration;
  const p20c = b.p20_sleep_continuity;
  const p80c = b.p80_sleep_continuity;
  const p50c = (p20c != null && p80c != null) ? (p20c + p80c) / 2 : null;
  if (p20d == null || p80d == null || p50c == null) return noActivation(NODE);
  const window = last(ctx.inputs30d, 7);
  let daysMet = 0;
  for (const row of window) {
    const durOk  = row.sleep_duration_hrs != null && row.sleep_duration_hrs >= p20d && row.sleep_duration_hrs <= p80d;
    const contOk = row.sleep_continuity_pct != null && row.sleep_continuity_pct >= p50c;
    if (durOk && contOk) daysMet++;
  }
  const required = 5;
  const is_active = daysMet >= required;
  return {
    node_key: NODE, is_active,
    activation_strength: is_active ? strengthFromDays(daysMet, required) : 0,
    contributing_metrics: is_active ? [{ metric_key: "sleep_duration_hrs", direction: "above_baseline", deviation_magnitude: daysMet }] : [],
    days_active: is_active ? daysActiveFromPrior(ctx.priorActivations30d, NODE, ctx.date) : 0,
  };
}

// ─────────────────────────────────────────
// EVALUATE ALL 12 RULES
// Returns a map from node_key → ActivationResult
// ─────────────────────────────────────────

export function evaluateAllNodes(ctx: EvaluationContext): Map<string, ActivationResult> {
  const results = new Map<string, ActivationResult>();

  // --- Pass 1: non-composite rules ---
  const poorSleep   = evalPoorSleepQuality(ctx);
  const inactivity  = evalPhysicalInactivity(ctx);
  const circadian   = evalCircadianDisruption(ctx);
  const lowHRV      = evalLowHRV(ctx);
  const elevRHR     = evalElevatedRestingHR(ctx);
  const sleepFrag   = evalSleepFragmentation(ctx);
  const exercise    = evalDailyExercise(ctx);
  const qualSleep   = evalQualitySleep(ctx);

  results.set("poor_sleep_quality",   poorSleep);
  results.set("physical_inactivity",  inactivity);
  results.set("circadian_disruption", circadian);
  results.set("low_hrv",              lowHRV);
  results.set("elevated_resting_hr",  elevRHR);
  results.set("sleep_fragmentation",  sleepFrag);
  results.set("daily_exercise",       exercise);
  results.set("quality_sleep",        qualSleep);

  // --- Pass 2: composite rules (read from pass 1 results) ---
  const autonomicDysf       = evalAutonomicDysfunction(ctx, lowHRV.is_active, elevRHR.is_active);
  const sympathDom          = evalSympatheticDominance(ctx, lowHRV.is_active, elevRHR.is_active);
  const sustainedRecovery   = evalSustainedRecoveryDeficit(ctx, lowHRV.is_active, poorSleep.is_active, inactivity.is_active);
  const recoveryLoad        = evalRecoveryLoadImbalance(ctx, lowHRV.is_active, elevRHR.is_active);

  results.set("autonomic_dysfunction",      autonomicDysf);
  results.set("sympathetic_dominance",      sympathDom);
  results.set("sustained_recovery_deficit", sustainedRecovery);
  results.set("recovery_load_imbalance",    recoveryLoad);

  return results;
}

// ─────────────────────────────────────────
// SMALL UTILITIES
// ─────────────────────────────────────────

function noActivation(node_key: string, skipped_reason?: string): ActivationResult {
  const r: ActivationResult = { node_key, is_active: false, activation_strength: 0, contributing_metrics: [], days_active: 0 };
  if (skipped_reason) r.skipped_reason = skipped_reason;
  return r;
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

function dedup(metrics: ContributingMetric[]): ContributingMetric[] {
  const seen = new Set<string>();
  return metrics.filter(m => { const k = `${m.metric_key}:${m.direction}`; if (seen.has(k)) return false; seen.add(k); return true; });
}

function daysActiveFromPrior(priorActivations: NodeActivationRow[], nodeKey: string, beforeDate: string): number {
  // Count consecutive days active immediately before today (include today = 1)
  const streak = consecutiveDaysActive(priorActivations, nodeKey, beforeDate, 1);
  return streak + 1; // +1 for today
}

function dateMinus(dateStr: string, days: number): string {
  const d = new Date(dateStr);
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().split("T")[0];
}
