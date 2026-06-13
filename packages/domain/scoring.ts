// packages/domain/scoring.ts
// MBI Scoring Engine — Score Formula, Bands, Alpha, Domain Scores
// Version: 1.2 | H-01: Tier 1 metric expansion

import type {
  Baseline,
  DailyInput,
  DomainScores,
  MetricDeviation,
  ScoreBand,
  ScoringResult,
} from "./contracts.ts";
import { DOMAIN_VERSION } from "./contracts.ts";
import { computeDeviations } from "./deviation.ts";
import { selectTopDrivers } from "./drivers.ts";
import { computeFailState } from "./failstates.ts";

// ─────────────────────────────────────────
// DYNAMIC ALPHA (SoT §5.1)
// ─────────────────────────────────────────
function computeAlpha(deviations: MetricDeviation[]): number {
  const flaggedCount = deviations.filter((d) => d.deviation !== 0).length;
  if (flaggedCount >= 3) return 1.0;
  if (flaggedCount === 2) return 0.8;
  if (flaggedCount === 1) return 0.6;
  return 0.6;
}

// ─────────────────────────────────────────
// SCORE BAND (SoT §5.2)
// ─────────────────────────────────────────
export function getScoreBand(score: number): ScoreBand {
  if (score >= 80) return "Thriving";
  if (score >= 60) return "Recovering";
  if (score >= 40) return "Drifting";
  return "Redline";
}

// ─────────────────────────────────────────
// HEALTH SCORE & RISK SCORE
// ─────────────────────────────────────────
function computeHealthAndRisk(deviations: MetricDeviation[]): { health: number; risk: number } {
  const MAX_PER_METRIC = 100;
  let totalWeight = 0;
  let healthWeighted = 0;
  let riskWeighted = 0;

  for (const d of deviations) {
    if (d.weight === 0) continue;
    // Modularity: metric with null value contributes 0 weight to pool
    // so it doesn't inflate or deflate scores for present metrics
    if (d.value == null) continue;
    totalWeight += d.weight;

    const healthContrib = d.deviation === 0 ? MAX_PER_METRIC
      : d.deviation === -1 ? MAX_PER_METRIC * 0.6
      : MAX_PER_METRIC * 0.2;
    healthWeighted += healthContrib * d.weight;

    const riskPenalty = d.deviation === -2 ? 30 * d.weight
      : d.deviation === -1 ? 15 * d.weight
      : 0;
    riskWeighted += riskPenalty;
  }

  const health = totalWeight > 0 ? healthWeighted / totalWeight : 100;
  const risk = totalWeight > 0 ? riskWeighted / totalWeight : 0;

  return {
    health: Math.max(0, Math.min(100, health)),
    risk: Math.max(0, Math.min(100, risk)),
  };
}

// ─────────────────────────────────────────
// DOMAIN SCORES (SoT §7 + H-01 expansion)
// D1 Autonomic:  hrv, resting_hr, respiratory_rate, spo2
// D2 Sleep:      sleep_duration, sleep_efficiency
// D3 Activity:   steps, active_minutes, resting_energy, stand_hours
// Missing metrics silently excluded — weight pool only counts present metrics
// ─────────────────────────────────────────
function computeDomainScores(
  deviations: MetricDeviation[],
  historyDays: number
): DomainScores {
  const byMetric = Object.fromEntries(deviations.map((d) => [d.metric, d]));

  const domainScore = (metrics: string[]): number | null => {
    const relevant = metrics
      .map((m) => byMetric[m])
      .filter((d) => d != null && d.value != null); // only present metrics
    if (relevant.length === 0) return null;
    const totalW = relevant.reduce((s, d) => s + d.weight, 0);
    if (totalW === 0) return null;
    const score = relevant.reduce((s, d) => {
      const contrib = d.deviation === 0 ? 100
        : d.deviation === -1 ? 60
        : 20;
      return s + contrib * d.weight;
    }, 0) / totalW;
    return Math.max(0, Math.min(100, score));
  };

  return {
    d1_autonomic: domainScore(["hrv", "resting_hr", "respiratory_rate", "spo2"]),
    d2_sleep: domainScore(["sleep_duration", "sleep_efficiency"]),
    d3_activity: domainScore(["steps", "active_minutes", "resting_energy", "stand_hours"]),
    d4_stress: historyDays >= 7
      ? domainScore(["hrv", "resting_hr", "sleep_duration"])
      : null,
    d5_allostatic: historyDays >= 30
      ? domainScore(["hrv", "resting_hr", "sleep_duration", "sleep_efficiency", "steps"])
      : null,
  };
}

// ─────────────────────────────────────────
// DELTA OVERRIDE (SoT §6)
// ─────────────────────────────────────────
function checkDeltaOverride(currentScore: number, recentScores: number[]): boolean {
  if (recentScores.length < 3) return false;
  const last3Avg = recentScores.slice(-3).reduce((a, b) => a + b, 0) / 3;
  return last3Avg - currentScore > 15;
}

// ─────────────────────────────────────────
// NUDGE DOMAIN
// ─────────────────────────────────────────
export function selectNudgeDomain(
  domainScores: DomainScores
): "d1_autonomic" | "d2_sleep" | "d3_activity" {
  const candidates: Array<["d1_autonomic" | "d2_sleep" | "d3_activity", number | null]> = [
    ["d1_autonomic", domainScores.d1_autonomic],
    ["d2_sleep", domainScores.d2_sleep],
    ["d3_activity", domainScores.d3_activity],
  ];
  const available = candidates.filter(([, v]) => v != null) as Array<["d1_autonomic" | "d2_sleep" | "d3_activity", number]>;
  if (available.length === 0) return "d1_autonomic";
  available.sort((a, b) => a[1] - b[1]);
  return available[0][0];
}

// ─────────────────────────────────────────
// MAIN: scoreDay
// ─────────────────────────────────────────
export function scoreDay(params: {
  input: DailyInput;
  baseline: Baseline | null;
  historyDays: number;
  recentScores: number[];
  stepGoal?: number;
  engagementDays?: number;
}): ScoringResult {
  const {
    input,
    baseline,
    historyDays,
    recentScores,
    stepGoal = 8000,
    engagementDays = 0,
  } = params;

  const isProvisional = historyDays < 7;

  if (!baseline) {
    return {
      chronos_score: 70,
      score_band: "Recovering",
      health_score: 70,
      risk_score: 0,
      alpha: 0.6,
      domain_scores: { d1_autonomic: null, d2_sleep: null, d3_activity: null, d4_stress: null, d5_allostatic: null },
      driver_1: "hrv",
      driver_2: "resting_hr",
      delta_override_triggered: false,
      fail_state: null,
      is_provisional: true,
      domain_version: DOMAIN_VERSION,
      deviations: [],
    };
  }

  const deviations = computeDeviations(input, baseline, stepGoal);
  const alpha = computeAlpha(deviations);
  const { health, risk } = computeHealthAndRisk(deviations);
  const rawScore = health - risk * alpha;
  const chronos_score = Math.max(0, Math.min(100, Math.round(rawScore)));
  const score_band = getScoreBand(chronos_score);
  const domain_scores = computeDomainScores(deviations, historyDays);
  const { driver_1, driver_2 } = selectTopDrivers(deviations);
  const delta_override_triggered = checkDeltaOverride(chronos_score, recentScores);
  const fail_state = computeFailState({
    deviations,
    chronos_score,
    engagementDays,
    recentScores,
    input,
  });

  return {
    chronos_score,
    score_band,
    health_score: Math.round(health),
    risk_score: Math.round(risk),
    alpha,
    domain_scores,
    driver_1,
    driver_2,
    delta_override_triggered,
    fail_state,
    is_provisional: isProvisional,
    domain_version: DOMAIN_VERSION,
    deviations,
  };
}