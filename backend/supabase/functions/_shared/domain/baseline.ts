// backend/supabase/functions/_shared/domain/baseline.ts
// MBI Scoring Engine — Baseline Calculation
// Version: 1.3 | sleep_efficiency_avg renamed to sleep_continuity_avg (D3)

import type { DailyInput, Baseline } from "./contracts.ts";

export function computeBaseline(rows: DailyInput[]): Baseline | null {
  if (rows.length < 3) return null;
  const window = rows.slice(-7);
  const count = window.length;

  const avg = (vals: (number | null | undefined)[]): number | null => {
    const clean = vals.filter((v): v is number => v != null && !isNaN(v));
    if (clean.length === 0) return null;
    return clean.reduce((a, b) => a + b, 0) / clean.length;
  };

  const sd = (vals: (number | null | undefined)[], mean: number | null): number | null => {
    if (mean == null) return null;
    const clean = vals.filter((v): v is number => v != null && !isNaN(v));
    if (clean.length < 2) return null;
    const variance = clean.reduce((acc, v) => acc + Math.pow(v - mean, 2), 0) / clean.length;
    return Math.sqrt(variance);
  };

  const hrv_avg = avg(window.map((r) => r.hrv_ms));
  const rhr_avg = avg(window.map((r) => r.resting_hr_bpm));

  return {
    hrv_avg,
    hrv_sd:               sd(window.map((r) => r.hrv_ms), hrv_avg),
    resting_hr_avg:       rhr_avg,
    resting_hr_sd:        sd(window.map((r) => r.resting_hr_bpm), rhr_avg),
    respiratory_rate_avg: avg(window.map((r) => r.respiratory_rate_rpm)),
    sleep_duration_avg:   avg(window.map((r) => r.sleep_duration_hrs)),
    sleep_continuity_avg: avg(window.map((r) => r.sleep_continuity_pct)),
    steps_avg:            avg(window.map((r) => r.steps)),
    active_minutes_avg:   avg(window.map((r) => r.active_minutes)),
    spo2_avg:             avg(window.map((r) => r.spo2_pct)),
    resting_energy_avg:   avg(window.map((r) => r.resting_energy)),
    stand_hours_avg:      avg(window.map((r) => r.stand_hours)),
    window_days:          count,
  };
}
