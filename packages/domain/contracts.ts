// packages/domain/contracts.ts
// MBI Scoring Engine — Type Contracts
// Version: 1.2 | H-01: Tier 1 metric expansion

export const DOMAIN_VERSION = "1.2";

// ─────────────────────────────────────────
// INPUT TYPES
// ─────────────────────────────────────────

export interface DailyInput {
  userId: string;
  date: string; // ISO date YYYY-MM-DD
  hrv_ms?: number | null;
  resting_hr_bpm?: number | null;
  respiratory_rate_rpm?: number | null;
  sleep_duration_hrs?: number | null;
  sleep_efficiency_pct?: number | null;
  steps?: number | null;
  active_minutes?: number | null;
  distance_km?: number | null;
  // H-01: Tier 1 expansion — all optional, missing = silently excluded
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
  sleep_efficiency_avg?: number | null;
  steps_avg?: number | null;
  active_minutes_avg?: number | null;
  // H-01: Tier 1 baseline values
  spo2_avg?: number | null;
  resting_energy_avg?: number | null;
  stand_hours_avg?: number | null;
  window_days: number;
}

// ─────────────────────────────────────────
// DEVIATION
// ─────────────────────────────────────────

export type DeviationState = 0 | -1 | -2; // Normal | Mild | Hard

export interface MetricDeviation {
  metric: MetricName;
  value: number | null;
  deviation: DeviationState;
  weight: number;
}

export type MetricName =
  | "hrv"
  | "resting_hr"
  | "respiratory_rate"
  | "sleep_duration"
  | "sleep_efficiency"
  | "steps"
  | "active_minutes"
  | "distance"
  | "spo2"
  | "resting_energy"
  | "stand_hours";

// ─────────────────────────────────────────
// SCORE OUTPUT
// ─────────────────────────────────────────

export type ScoreBand = "Thriving" | "Recovering" | "Drifting" | "Redline";
export type FailState = "Redline" | "Drift" | "Ghost-Healthy" | "Ghost-AtRisk" | null;

export interface DomainScores {
  d1_autonomic: number | null;
  d2_sleep: number | null;
  d3_activity: number | null;
  d4_stress: number | null;
  d5_allostatic: number | null;
}

export interface ScoringResult {
  chronos_score: number;
  score_band: ScoreBand;
  health_score: number;
  risk_score: number;
  alpha: number;
  domain_scores: DomainScores;
  driver_1: MetricName;
  driver_2: MetricName;
  delta_override_triggered: boolean;
  fail_state: FailState;
  is_provisional: boolean;
  domain_version: string;
  deviations: MetricDeviation[];
}

// ─────────────────────────────────────────
// NARRATIVE INPUT (what Claude receives)
// ─────────────────────────────────────────

export interface NarrativeInput {
  chronos_score: number;
  score_band: ScoreBand;
  driver_1: MetricName;
  driver_2: MetricName;
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