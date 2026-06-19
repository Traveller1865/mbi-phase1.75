// backend/supabase/functions/_shared/domain/failstates.ts
// MBI Scoring Engine — Fail State Logic
// Version: 1.4 | Scoring Engine Architecture Review v1.0 (May 2026)
// D6: chronos_score<=39 Redline requires confidence_tier "guarded" or "full"
// D4/D5: HRV/RHR absolute guardrails removed from Redline trigger (now reserve flags only)
// D10: Drift approximates adherence via score trend — disengagement language prohibited
// D11: Drift band gate 40-59 confirmed correct and documented
// v1.4: Breadth Redline (≥2 metrics at -1) now counts PHYSIOLOGICAL signals only.
//       Activity/behavioral metrics (steps, active_minutes, stand_hours, distance,
//       resting_energy) are not acute physiological stress and must not push a
//       healthy-scoring day into Redline (fixed 87-composite false positive).

import type { ConfidenceTier, DailyInput, FailState, MetricDeviation } from "./contracts.ts";

// Metrics that represent acute physiological state (autonomic / respiratory / sleep / oxygenation).
// Used to gate the breadth-based Redline trigger so behavioral metrics (a low-step day)
// cannot, by themselves, contribute to a "physiological Redline".
const PHYSIOLOGICAL_REDLINE_METRICS = [
  "hrv", "resting_hr", "respiratory_rate", "sleep_duration", "sleep_continuity", "spo2",
];

interface FailStateParams {
  deviations: MetricDeviation[];
  chronos_score: number;
  engagementDays: number;
  recentScores: number[];
  input: DailyInput;
  confidence_tier: ConfidenceTier;
}

export function computeFailState(params: FailStateParams): FailState {
  const { deviations, chronos_score, engagementDays, recentScores, input, confidence_tier } = params;
  const byMetric = Object.fromEntries(deviations.map((d) => [d.metric, d]));

  // REDLINE — physiological conditions (D4/D5: absolute guardrails removed, relative thresholds retained)
  // v1.4: breadth trigger counts physiological signals only (excludes steps/activity).
  const physiologicalMildCount = deviations.filter(
    (d) => d.deviation === -1 && PHYSIOLOGICAL_REDLINE_METRICS.includes(d.metric)
  ).length;
  const isPhysiologicalRedline = (
    byMetric["hrv"]?.deviation === -2 ||
    byMetric["resting_hr"]?.deviation === -2 ||
    (input.respiratory_rate_rpm != null && input.respiratory_rate_rpm > 20) ||
    (input.sleep_duration_hrs != null && input.sleep_duration_hrs < 5.5) ||
    physiologicalMildCount >= 2
  );
  if (isPhysiologicalRedline) return "Redline";

  // D6: score<=39 triggers Redline only at guarded/full confidence
  // Low confidence (3-4 days): low score from sparse data surfaces as Data Confidence state, not Redline
  if (chronos_score <= 39 && (confidence_tier === "guarded" || confidence_tier === "full")) {
    return "Redline";
  }

  // GHOST MODES
  if (engagementDays >= 3) {
    const isScoreDeclining = recentScores.length >= 2 &&
      recentScores[recentScores.length - 1] < recentScores[recentScores.length - 2];
    return isScoreDeclining ? "Ghost-AtRisk" : "Ghost-Healthy";
  }

  // DRIFT (D10: Phase 1 approximation — score trend proxies adherence)
  // (D11: band gate 40-59 confirmed correct)
  if (recentScores.length >= 5) {
    const last5 = recentScores.slice(-5);
    const isRisingRisk = last5[last5.length - 1] < last5[0];
    if (chronos_score >= 40 && chronos_score < 60 && isRisingRisk) return "Drift";
  }

  return null;
}
