// backend/supabase/functions/_shared/domain/contracts.ts
// MBI Scoring Engine — Type Contracts
// Version: 1.6 | Pre-Beta Sprint (June 2026)
// Changes v1.6: Yellowline removed from ScoreBand (Drifting expands to 40–69); new
//               DeclineSignal type + decline_signal field on ScoringResult — a
//               momentum signal (decline from the upper range), not a band.
// Changes v1.5: Yellowline added to ScoreBand; 8 p10/p90 percentile fields
//               added to Baseline (sleep, steps, active_minutes); range_trust_state
//               added to ScoringResult row (written to daily_scores in addition to baselines)
// Changes v1.4: ZoneState + RangeTrustState types; zone_1/zone_2/range_trust_state on ScoringResult

export const DOMAIN_VERSION = "1.6";

export type ZoneState =
  | "elevated"
  | "within_range_high"
  | "within_range_low"
  | "below_range"
  | "flagged"
  | null;

export type RangeTrustState =
  | "establishing"
  | "calibrating"
  | "provisional"
  | "trusted"
  | "established";

export type ReserveFlag =
  | "LOW_ABSOLUTE_RESERVE"
  | "HIGH_ABSOLUTE_RHR"
  | "SAFETY_OVERRIDE_RHR"
  | null;

export type ConfidenceTier = "none" | "low" | "guarded" | "full";

export interface DailyInput {
  userId: string;
  date: string;
  hrv_ms?: number | null;
  resting_hr_bpm?: number | null;
  respiratory_rate_rpm?: number | null;
  sleep_duration_hrs?: number | null;
  sleep_continuity_pct?: number | null;
  steps?: number | null;
  active_minutes?: number | null;
  distance_km?: number | null;
  spo2_pct?: number | null;
  resting_energy?: number | null;
  stand_hours?: number | null;
}

export interface Baseline {
  hrv_avg?: number | null;
  hrv_sd?: number | null;
  resting_hr_avg?: number | null;
  resting_hr_sd?: number | null;
  respiratory_rate_avg?: number | null;
  sleep_duration_avg?: number | null;
  sleep_continuity_avg?: number | null;
  steps_avg?: number | null;
  active_minutes_avg?: number | null;
  window_days: number;
  spo2_avg?: number | null;
  resting_energy_avg?: number | null;
  stand_hours_avg?: number | null;
  // Personal percentile thresholds (Learning Foundation v1.0)
  // Populated once trust state reaches provisional (7+ valid days).
  // Used by deviation.ts to replace hardcoded absolute reserve flag thresholds.
  p10_hrv_7d?: number | null;
  p90_hrv_7d?: number | null;
  p10_resting_hr?: number | null;
  p90_resting_hr?: number | null;
  // Extended percentile thresholds (v1.5) — sleep, steps, active_minutes
  // Written to baselines via spread in score/index.ts; now typed for consumer access.
  p10_sleep_duration?: number | null;
  p90_sleep_duration?: number | null;
  p10_sleep_continuity?: number | null;
  p90_sleep_continuity?: number | null;
  p10_steps?: number | null;
  p90_steps?: number | null;
  p10_active_minutes?: number | null;
  p90_active_minutes?: number | null;
}

export type DeviationState = 0 | -1 | -2;

export interface MetricDeviation {
  metric: MetricName;
  value: number | null;
  deviation: DeviationState;
  weight: number;
  reserve_flag?: ReserveFlag;
  corroboration_state?: boolean;
}

export type MetricName =
  | "hrv"
  | "resting_hr"
  | "respiratory_rate"
  | "sleep_duration"
  | "sleep_continuity"
  | "steps"
  | "active_minutes"
  | "distance"
  | "spo2"
  | "stand_hours"
  | "resting_energy";

export type ScoreBand = "Thriving" | "Recovering" | "Drifting" | "Redline";
export type FailState = "Redline" | "Drift" | "Ghost-Healthy" | "Ghost-AtRisk" | null;

// Momentum signal (v1.6) — fires when a user in the upper range (score ≥ 70) has
// declined meaningfully over the past week. Separate field from score_band, never
// an override. Lowercase by spec (persisted to daily_scores.decline_signal).
export type DeclineSignal = "yellowline" | null;

export interface DomainScores {
  d1_autonomic: number | null;
  d2_sleep: number | null;
  d3_activity: number | null;
  d4_stress: number | null;
  d5_allostatic: number | null;
}

export interface ScoringResult {
  chronos_score: number | null;
  score_band: ScoreBand | null;
  decline_signal: DeclineSignal;
  health_score: number | null;
  risk_score: number | null;
  alpha: number | null;
  domain_scores: DomainScores;
  driver_1: MetricName;
  driver_2: MetricName | null;
  delta_override_triggered: boolean;
  fail_state: FailState;
  is_provisional: boolean;
  confidence_tier: ConfidenceTier;
  pre_drift_signal: boolean;
  domain_version: string;
  deviations: MetricDeviation[];
  reserve_flags: ReserveFlag[];
  // Range Architecture v1.0 — zone classification results (null when trust state < provisional)
  zone_1: ZoneState;
  zone_2: ZoneState;
  range_trust_state: RangeTrustState;
}

export interface NarrativeInput {
  chronos_score: number;
  score_band: ScoreBand;
  driver_1: MetricName;
  driver_2: MetricName | null;
  delta_override_triggered: boolean;
  fail_state: FailState;
  domain_scores: DomainScores;
  is_provisional: boolean;
  nudge_domain: "d1_autonomic" | "d2_sleep" | "d3_activity";
}

export interface NarrativeOutput {
  explanation_text: string;
  nudge_text: string;
  prompt_version: string;
  model_version: string;
}
