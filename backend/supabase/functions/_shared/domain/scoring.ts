// backend/supabase/functions/_shared/domain/scoring.ts
// MBI Scoring Engine — Score Formula, Bands, Alpha, Domain Scores
// Version: 1.5 | Pre-Beta Sprint (May 2026)
// v1.5: Yellowline band added (60–69). Recovering now 70–79. Drifting 40–59 unchanged.
// D12: Removed hardcoded fallback of 70; four-tier confidence model
// D11: pre_drift_signal detection (score>59, 5-day decline >15pts)
// D3: sleep_continuity in domain compositions
// D13: spo2 added to D5 allostatic composite
// Range v1.0: zone_1, zone_2, range_trust_state on ScoringResult

import type {
  Baseline, ConfidenceTier, DailyInput, DomainScores, MetricDeviation,
  MetricName, ReserveFlag, ScoreBand, ScoringResult, ZoneState, RangeTrustState,
} from "./contracts.ts";
import { DOMAIN_VERSION } from "./contracts.ts";
import { computeDeviations, DeviationContext } from "./deviation.ts";
import { selectTopDrivers } from "./drivers.ts";
import { computeFailState } from "./failstates.ts";

function computeConfidenceTier(historyDays: number): ConfidenceTier {
  if (historyDays < 3) return "none";
  if (historyDays < 5) return "low";
  if (historyDays < 7) return "guarded";
  return "full";
}

function computeAlpha(deviations: MetricDeviation[]): number {
  const flaggedCount = deviations.filter((d) => d.deviation !== 0).length;
  if (flaggedCount >= 3) return 1.0;
  if (flaggedCount === 2) return 0.8;
  return 0.6;
}

export function getScoreBand(score: number): ScoreBand {
  if (score >= 80) return "Thriving";
  if (score >= 70) return "Recovering";
  if (score >= 60) return "Yellowline";  // caution zone — early decline signal
  if (score >= 40) return "Drifting";
  return "Redline";
}

function computeHealthAndRisk(deviations: MetricDeviation[]): { health: number; risk: number } {
  let totalWeight = 0, healthWeighted = 0, riskWeighted = 0;
  for (const d of deviations) {
    if (d.weight === 0) continue;
    totalWeight += d.weight;
    const healthContrib = d.deviation === 0 ? 100 : d.deviation === -1 ? 60 : 20;
    healthWeighted += healthContrib * d.weight;
    const riskPenalty = d.deviation === -2 ? 30 * d.weight : d.deviation === -1 ? 15 * d.weight : 0;
    riskWeighted += riskPenalty;
  }
  return {
    health: Math.max(0, Math.min(100, totalWeight > 0 ? healthWeighted / totalWeight : 100)),
    risk:   Math.max(0, Math.min(100, totalWeight > 0 ? riskWeighted  / totalWeight : 0)),
  };
}

function computeDomainScores(deviations: MetricDeviation[], historyDays: number): DomainScores {
  const byMetric = Object.fromEntries(deviations.map((d) => [d.metric, d]));
  const domainScore = (metrics: string[]): number | null => {
    const relevant = metrics.map((m) => byMetric[m]).filter(Boolean);
    if (relevant.length === 0) return null;
    const totalW = relevant.reduce((s, d) => s + d.weight, 0);
    if (totalW === 0) return null;
    return Math.max(0, Math.min(100,
      relevant.reduce((s, d) => s + (d.deviation === 0 ? 100 : d.deviation === -1 ? 60 : 20) * d.weight, 0) / totalW
    ));
  };
  return {
    d1_autonomic:  domainScore(["hrv", "resting_hr"]),
    d2_sleep:      domainScore(["sleep_duration", "sleep_continuity"]),
    d3_activity:   domainScore(["steps", "active_minutes"]),
    // D4/D5 snapshot formula retained pending burden-index rewrite (D8/D9 — separate sprint)
    d4_stress:     historyDays >= 7  ? domainScore(["hrv", "resting_hr", "sleep_duration"]) : null,
    d5_allostatic: historyDays >= 30 ? domainScore(["hrv", "resting_hr", "sleep_duration", "sleep_continuity", "steps", "spo2"]) : null,
  };
}

function checkDeltaOverride(currentScore: number, recentScores: number[]): boolean {
  if (recentScores.length < 3) return false;
  const last3Avg = recentScores.slice(-3).reduce((a, b) => a + b, 0) / 3;
  return last3Avg - currentScore > 15;
}

// Pre-Drift signal (D11): score >59 (not yet Drifting band) with 5-day decline >15 points
// Not a fail state — surfaces in narrative annotation and Trend tab only
function checkPreDrift(currentScore: number, recentScores: number[]): boolean {
  if (recentScores.length < 5 || currentScore <= 59) return false;
  return recentScores[0] - currentScore > 15; // recentScores[0] is oldest of last 5
}

export function selectNudgeDomain(domainScores: DomainScores): "d1_autonomic" | "d2_sleep" | "d3_activity" {
  const candidates: Array<["d1_autonomic" | "d2_sleep" | "d3_activity", number | null]> = [
    ["d1_autonomic", domainScores.d1_autonomic],
    ["d2_sleep",     domainScores.d2_sleep],
    ["d3_activity",  domainScores.d3_activity],
  ];
  const available = candidates.filter(([, v]) => v != null) as Array<["d1_autonomic" | "d2_sleep" | "d3_activity", number]>;
  if (available.length === 0) return "d1_autonomic";
  available.sort((a, b) => a[1] - b[1]);
  return available[0][0];
}

const EMPTY_DOMAINS: DomainScores = { d1_autonomic: null, d2_sleep: null, d3_activity: null, d4_stress: null, d5_allostatic: null };

export function scoreDay(params: {
  input: DailyInput;
  baseline: Baseline | null;
  historyDays: number;
  recentScores: number[];
  stepGoal?: number;
  engagementDays?: number;
  deviationContext?: DeviationContext;
  // Range Architecture v1.0 — pre-computed zone results from score/index.ts
  zone_1?: ZoneState;
  zone_2?: ZoneState;
  range_trust_state?: RangeTrustState;
}): ScoringResult {
  const {
    input, baseline, historyDays, recentScores,
    stepGoal = 8000, engagementDays = 0, deviationContext = {},
    zone_1 = null, zone_2 = null, range_trust_state = "establishing",
  } = params;

  const confidence_tier = computeConfidenceTier(historyDays);
  const is_provisional  = confidence_tier !== "full";

  // D12: No synthetic score. 0-2 day users see baseline-building UI state.
  if (confidence_tier === "none" || !baseline) {
    return {
      chronos_score: null, score_band: null, health_score: null, risk_score: null, alpha: null,
      domain_scores: EMPTY_DOMAINS, driver_1: "hrv", driver_2: "resting_hr",
      delta_override_triggered: false, fail_state: null, is_provisional: true,
      confidence_tier, pre_drift_signal: false, domain_version: DOMAIN_VERSION,
      deviations: [], reserve_flags: [], zone_1, zone_2, range_trust_state,
    };
  }

  const deviations    = computeDeviations(input, baseline, stepGoal, deviationContext);
  const alpha         = computeAlpha(deviations);
  const { health, risk } = computeHealthAndRisk(deviations);
  const rawScore      = health - risk * alpha;
  const chronos_score = Math.max(0, Math.min(100, Math.round(rawScore)));
  const score_band    = getScoreBand(chronos_score);
  const domain_scores = computeDomainScores(deviations, historyDays);
  const { driver_1, driver_2 } = selectTopDrivers(deviations);
  const delta_override_triggered = checkDeltaOverride(chronos_score, recentScores);
  const pre_drift_signal         = checkPreDrift(chronos_score, recentScores.slice(-5));
  const reserve_flags: ReserveFlag[] = deviations
    .map((d) => d.reserve_flag ?? null)
    .filter((f): f is NonNullable<ReserveFlag> => f !== null);
  const fail_state = computeFailState({ deviations, chronos_score, engagementDays, recentScores, input, confidence_tier });

  return {
    chronos_score, score_band, health_score: Math.round(health), risk_score: Math.round(risk),
    alpha, domain_scores, driver_1, driver_2, delta_override_triggered,
    fail_state, is_provisional, confidence_tier, pre_drift_signal,
    domain_version: DOMAIN_VERSION, deviations, reserve_flags,
    zone_1, zone_2, range_trust_state,
  };
}
