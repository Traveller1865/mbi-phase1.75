// _shared/domain/ontology/types.ts
// Ontology Engine v1 — Type Contracts
// Ontology version: phase1_75-v1.0

export const ONTOLOGY_VERSION = "phase1_75-v1.0";

export type TrustState = "establishing" | "calibrating" | "provisional" | "trusted" | "established";
export type PathwayState = "CALM" | "ELEVATED" | "FLAGGED";
export type PathwayKey = "autonomic" | "sleep" | "metabolic";

export type ConditionClass =
  | "load_accumulating"
  | "recovery_deficit"
  | "autonomic_strain"
  | "metabolic_stress_early"
  | "sleep_debt_compounding";

// Raw row shapes from Supabase queries
export interface DailyInputRow {
  date: string;
  hrv_ms: number | null;
  resting_hr_bpm: number | null;
  respiratory_rate_rpm: number | null;
  sleep_duration_hrs: number | null;
  sleep_continuity_pct: number | null;
  steps: number | null;
  active_minutes: number | null;
}

export interface DailyScoreRow {
  date: string;
  d1_autonomic: number | null;
  d2_sleep: number | null;
  d3_activity: number | null;
  chronos_score: number | null;
}

export interface BaselinesRow {
  range_trust_state: string;
  hrv_7d_rolling_avg: number | null;
  p20_hrv_7d: number | null;
  p80_hrv_7d: number | null;
  p20_resting_hr: number | null;
  p80_resting_hr: number | null;
  p20_sleep_duration: number | null;
  p80_sleep_duration: number | null;
  p20_sleep_continuity: number | null;
  p80_sleep_continuity: number | null;
  p20_steps_weekday: number | null;
  p80_steps_weekday: number | null;
  p20_steps_weekend: number | null;
  p80_steps_weekend: number | null;
  p20_active_minutes_weekday: number | null;
  p80_active_minutes_weekday: number | null;
  p20_active_minutes_weekend: number | null;
  p80_active_minutes_weekend: number | null;
  respiratory_rate_avg: number | null;
}

export interface NodeActivationRow {
  node_key: string;
  activation_date: string;
  is_active: boolean;
  days_active: number;
}

export interface ContributingMetric {
  metric_key: string;
  direction: string;
  deviation_magnitude: number;
}

export interface ActivationResult {
  node_key: string;
  is_active: boolean;
  activation_strength: number;
  contributing_metrics: ContributingMetric[];
  days_active: number;
  // Set when a gate blocked evaluation — 'insufficient_data' | 'travel_suppression'
  skipped_reason?: string;
}

export interface PathwayClassification {
  pathway_key: PathwayKey;
  state: PathwayState;
  trajectory_label: string | null;
  condition_class: ConditionClass | null;
  escalation_level: number;
  confidence_gate: number;
  days_in_pattern: number;
  activating_nodes: Array<{ node_key: string; activation_strength: number }>;
  // Confidence gate components — included for suppressed_classifications audit log
  _trustFactor: number;
  _depthFactor: number;
  _stabilityFactor: number;
}

export interface EvaluationContext {
  date: string;           // yyyy-MM-dd
  isWeekend: boolean;
  inputs30d: DailyInputRow[];
  scores30d: DailyScoreRow[];
  baselines: BaselinesRow;
  priorActivations30d: NodeActivationRow[];
  priorPathways30d: Array<{ pathway_key: string; state: string; classification_date: string }>;
  trustState: TrustState;
}
