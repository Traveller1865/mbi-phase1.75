// packages/domain/failstates.ts
// MBI Scoring Engine — Fail State Logic
// Version: 1.1 | All four fail states implemented per SoT §8

import type { DailyInput, FailState, MetricDeviation } from "./contracts.ts";

interface FailStateParams {
  deviations: MetricDeviation[];
  chronos_score: number;
  engagementDays: number;       // consecutive days with no user engagement
  recentScores: number[];       // last N scores for trend analysis
  input: DailyInput;
}

/**
 * Compute fail state. Order of evaluation matters:
 * 1. Redline (acute physiological stress)
 * 2. Ghost modes (engagement-based)
 * 3. Drift (sustained risk accumulation)
 * 4. null (normal operation)
 */
export function computeFailState(params: FailStateParams): FailState {
  const { deviations, chronos_score, engagementDays, recentScores, input } = params;

  const byMetric = Object.fromEntries(deviations.map((d) => [d.metric, d]));

  // ─────────────────────────────────────────
  // REDLINE (SoT §8.1) — any one condition sufficient
  // ─────────────────────────────────────────
  const isRedline = (
    // HRV drops >30% from baseline — captured as hard flag
    byMetric["hrv"]?.deviation === -2 ||
    // RHR rises >10 bpm — captured as hard flag
    byMetric["resting_hr"]?.deviation === -2 ||
    // Respiratory rate exceeds 20 rpm absolute
    (input.respiratory_rate_rpm != null && input.respiratory_rate_rpm > 20) ||
    // Sleep under 5.5 hrs absolute
    (input.sleep_duration_hrs != null && input.sleep_duration_hrs < 5.5) ||
    // 2+ mild deviations stacking simultaneously
    deviations.filter((d) => d.deviation === -1).length >= 2
  );

  if (isRedline || chronos_score <= 39) return "Redline";

  // ─────────────────────────────────────────
  // GHOST MODES (SoT §8.3, §8.4) — engagement-based
  // ─────────────────────────────────────────
  if (engagementDays >= 3) {
    // Determine score trend
    const isScoreDeclining = recentScores.length >= 2 &&
      recentScores[recentScores.length - 1] < recentScores[recentScores.length - 2];

    if (isScoreDeclining) {
      // CRITICAL: Never silent during deterioration
      return "Ghost-AtRisk";
    } else {
      return "Ghost-Healthy";
    }
  }

  // ─────────────────────────────────────────
  // DRIFT (SoT §8.2) — sustained risk + low adherence
  // ─────────────────────────────────────────
  // Note: adherence tracking requires the calling layer to pass in
  // a 5-day engagement rate. Here we approximate via score trend.
  if (recentScores.length >= 5) {
    const last5 = recentScores.slice(-5);
    const isRisingRisk = last5[last5.length - 1] < last5[0]; // score declining = risk rising
    // Drift requires low adherence — proxy: chronos in Drifting band + declining trend
    const isDrifting = chronos_score >= 40 && chronos_score < 60 && isRisingRisk;
    if (isDrifting) return "Drift";
  }

  return null;
}
