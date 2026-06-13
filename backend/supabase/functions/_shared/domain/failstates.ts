// packages/domain/failstates.ts
// MBI Scoring Engine — Fail State Logic
// Version: 1.3 | Scoring Engine Architecture Review v1.0 (May 2026)
// D6: chronos_score<=39 Redline requires confidence_tier "guarded" or "full"
// D4/D5: HRV/RHR absolute guardrails removed from Redline trigger (now reserve flags only)
// D10: Drift approximates adherence via score trend — disengagement language prohibited
// D11: Drift band gate 40-59 confirmed correct and documented

import type { ConfidenceTier, DailyInput, FailState, MetricDeviation } from "./contracts.ts";

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
  const isPhysiologicalRedline = (
    byMetric["hrv"]?.deviation === -2 ||
    byMetric["resting_hr"]?.deviation === -2 ||
    (input.respiratory_rate_rpm != null && input.respiratory_rate_rpm > 20) ||
    (input.sleep_duration_hrs != null && input.sleep_duration_hrs < 5.5) ||
    deviations.filter((d) => d.deviation === -1).length >= 2
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
