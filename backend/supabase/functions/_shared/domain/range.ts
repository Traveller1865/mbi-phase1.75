// packages/domain/range.ts
// MBI Baseline Range Architecture v1.0 — Phase 2 Sprint 1
// Implements: five-state trust model, p20/p80 percentile boundaries,
//             HRV 7-day smoothing, zone classification (Layer 1).
// Architectural constraint: all boundary values derive exclusively from
// the individual user's own history. No population norms or clinical
// thresholds are used in range or zone computation.

// ZoneState and RangeTrustState are the canonical types — defined in contracts.ts.
// range.ts imports them rather than redefining to avoid duplicate exports in index.ts.
import type { DailyInput, ZoneState, RangeTrustState } from "./contracts.ts";

// Re-export for callers who import directly from range.ts (avoids needing two imports)
export type { ZoneState, RangeTrustState };

export interface RangePercentiles {
  // HRV (uses 7d rolling average as input)
  p20_hrv_7d:                    number | null;
  p80_hrv_7d:                    number | null;
  p10_hrv_7d:                    number | null;  // reserve flag floor (personal)
  p90_hrv_7d:                    number | null;
  // Resting HR
  p20_resting_hr:                number | null;
  p80_resting_hr:                number | null;
  p10_resting_hr:                number | null;
  p90_resting_hr:                number | null;  // reserve flag ceiling (personal)
  // Sleep Duration
  p20_sleep_duration:            number | null;
  p80_sleep_duration:            number | null;
  p10_sleep_duration:            number | null;
  p90_sleep_duration:            number | null;
  // Sleep Continuity (p80 may be auto-widened to p85 for ceiling-effect users)
  p20_sleep_continuity:          number | null;
  p80_sleep_continuity:          number | null;
  p10_sleep_continuity:          number | null;
  p90_sleep_continuity:          number | null;
  // Steps — weekday / weekend split for zone classification,
  // combined p10/p90 for reserve flag use (no day-split needed for tail signals)
  p20_steps_weekday:             number | null;
  p80_steps_weekday:             number | null;
  p20_steps_weekend:             number | null;
  p80_steps_weekend:             number | null;
  p10_steps:                     number | null;
  p90_steps:                     number | null;
  // Active Minutes — weekday / weekend split + combined tails
  p20_active_minutes_weekday:    number | null;
  p80_active_minutes_weekday:    number | null;
  p20_active_minutes_weekend:    number | null;
  p80_active_minutes_weekend:    number | null;
  p10_active_minutes:            number | null;
  p90_active_minutes:            number | null;
}

export interface ValidDayCounts {
  total: number;        // all valid observations in history
  last35: number;       // valid observations within the last 35 calendar days
  last60: number;       // valid observations within the last 60 calendar days
}

// ─────────────────────────────────────────
// VALID DAY COUNTING
// A day is valid if at least one primary metric is non-null.
// Missing-data rows (all nulls) do not advance the trust counter.
// ─────────────────────────────────────────

export function computeValidDays(
  rows: DailyInput[],
  referenceDate: string,
): ValidDayCounts {
  const refMs = new Date(referenceDate).getTime();
  const ms35  = 35 * 86_400_000;
  const ms60  = 60 * 86_400_000;

  let total = 0, last35 = 0, last60 = 0;

  for (const row of rows) {
    // A day is valid if at least one primary metric was captured
    const hasData =
      row.hrv_ms != null ||
      row.resting_hr_bpm != null ||
      row.sleep_duration_hrs != null;

    if (!hasData) continue;
    total++;

    const rowMs = new Date(row.date).getTime();
    const age   = refMs - rowMs;
    if (age <= ms60) last60++;
    if (age <= ms35) last35++;
  }

  return { total, last35, last60 };
}

// ─────────────────────────────────────────
// TRUST STATE COMPUTATION
// Five-state unified confidence model.
// Recency constraints apply to Trusted and Established states.
// ─────────────────────────────────────────

export function computeTrustState(counts: ValidDayCounts): RangeTrustState {
  // Established: 42+ valid days within last 60 calendar days
  if (counts.last60 >= 42) return "established";
  // Trusted: 21–41 valid days within last 35 calendar days
  if (counts.last35 >= 21) return "trusted";
  // Provisional: 7–20 valid days total
  if (counts.total >= 7)  return "provisional";
  // Calibrating: 3–6 valid days
  if (counts.total >= 3)  return "calibrating";
  // Establishing: 0–2 valid days
  return "establishing";
}

// ─────────────────────────────────────────
// HRV 7-DAY ROLLING AVERAGE
// Raw daily HRV is too noisy for zone classification.
// Uses the last 7 valid (non-null) HRV readings from history.
// ─────────────────────────────────────────

export function computeHRV7dRollingAvg(rows: DailyInput[]): number | null {
  // rows are expected in ascending date order; take the last 7 with non-null HRV
  const validHRV = rows
    .map((r) => r.hrv_ms)
    .filter((v): v is number => v != null && !isNaN(v));

  const window = validHRV.slice(-7);
  if (window.length === 0) return null;
  return window.reduce((a, b) => a + b, 0) / window.length;
}

// ─────────────────────────────────────────
// PERCENTILE COMPUTATION
// Sorts the value array and interpolates at position p (0–1).
// Requires at least 2 values; returns null otherwise.
// ─────────────────────────────────────────

function computePercentile(values: number[], p: number): number | null {
  if (values.length < 2) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const pos    = p * (sorted.length - 1);
  const lo     = Math.floor(pos);
  const hi     = Math.ceil(pos);
  if (lo === hi) return sorted[lo];
  const frac = pos - lo;
  return sorted[lo] * (1 - frac) + sorted[hi] * frac;
}

function extractValid(rows: DailyInput[], field: keyof DailyInput): number[] {
  return rows
    .map((r) => r[field] as number | null | undefined)
    .filter((v): v is number => v != null && !isNaN(v as number));
}

function isWeekend(dateStr: string): boolean {
  const day = new Date(dateStr).getUTCDay(); // 0=Sun, 6=Sat
  return day === 0 || day === 6;
}

// ─────────────────────────────────────────
// RANGE PERCENTILES COMPUTATION
// Computes p20/p80 for each metric from the full valid history.
// Returns null for a metric if there are fewer than 7 valid readings
// (minimum floor for meaningful percentile computation).
// Only called when trust state is provisional or higher.
// ─────────────────────────────────────────

const MIN_READINGS_FOR_PERCENTILE = 7;

export function computeRangePercentiles(rows: DailyInput[]): RangePercentiles {
  const pct = (values: number[], p: number): number | null => {
    if (values.length < MIN_READINGS_FOR_PERCENTILE) return null;
    return computePercentile(values, p);
  };

  // ── HRV: uses 7d rolling avg values computed from history windows ──
  // For percentile computation, we compute a rolling 7d avg at each point
  // in history and collect those smoothed values as the distribution.
  const smoothedHRV = computeSmoothedHRVSeries(rows);
  const p10_hrv_7d = pct(smoothedHRV, 0.1);
  const p20_hrv_7d = pct(smoothedHRV, 0.2);
  const p80_hrv_7d = pct(smoothedHRV, 0.8);
  const p90_hrv_7d = pct(smoothedHRV, 0.9);

  // ── Resting HR ─────────────────────────────────────────────────────
  const rhrVals = extractValid(rows, "resting_hr_bpm");
  const p10_resting_hr = pct(rhrVals, 0.1);
  const p20_resting_hr = pct(rhrVals, 0.2);
  const p80_resting_hr = pct(rhrVals, 0.8);
  const p90_resting_hr = pct(rhrVals, 0.9);

  // ── Sleep Duration ──────────────────────────────────────────────────
  const sdVals = extractValid(rows, "sleep_duration_hrs");
  const p10_sleep_duration = pct(sdVals, 0.1);
  const p20_sleep_duration = pct(sdVals, 0.2);
  const p80_sleep_duration = pct(sdVals, 0.8);
  const p90_sleep_duration = pct(sdVals, 0.9);

  // ── Sleep Continuity (with ceiling-effect auto-widening on p80) ─────
  const scVals = extractValid(rows, "sleep_continuity_pct");
  const p10_sleep_continuity = pct(scVals, 0.1);
  const p20_sleep_continuity = pct(scVals, 0.2);
  let   p80_sleep_continuity = pct(scVals, 0.8);
  const p90_sleep_continuity = pct(scVals, 0.9);
  const p50_sleep_continuity = pct(scVals, 0.5);
  // Auto-widen p80: if within 3 percentage points of p50, use p85
  if (
    p80_sleep_continuity != null &&
    p50_sleep_continuity != null &&
    Math.abs(p80_sleep_continuity - p50_sleep_continuity) <= 3
  ) {
    p80_sleep_continuity = pct(scVals, 0.85);
  }

  // ── Steps — weekday / weekend split for zone classification ─────────
  // p10/p90 combined (no day-split needed for reserve flag tail signals)
  const weekdayRows = rows.filter((r) => !isWeekend(r.date));
  const weekendRows = rows.filter((r) =>  isWeekend(r.date));
  const stepsAll = extractValid(rows, "steps");
  const stepsWD  = extractValid(weekdayRows, "steps");
  const stepsWE  = extractValid(weekendRows, "steps");
  const p10_steps         = pct(stepsAll, 0.1);
  const p90_steps         = pct(stepsAll, 0.9);
  const p20_steps_weekday = pct(stepsWD, 0.2);
  const p80_steps_weekday = pct(stepsWD, 0.8);
  const p20_steps_weekend = pct(stepsWE, 0.2);
  const p80_steps_weekend = pct(stepsWE, 0.8);

  // ── Active Minutes — weekday / weekend split + combined tails ───────
  const amAll = extractValid(rows, "active_minutes");
  const amWD  = extractValid(weekdayRows, "active_minutes");
  const amWE  = extractValid(weekendRows, "active_minutes");
  const p10_active_minutes         = pct(amAll, 0.1);
  const p90_active_minutes         = pct(amAll, 0.9);
  const p20_active_minutes_weekday = pct(amWD, 0.2);
  const p80_active_minutes_weekday = pct(amWD, 0.8);
  const p20_active_minutes_weekend = pct(amWE, 0.2);
  const p80_active_minutes_weekend = pct(amWE, 0.8);

  return {
    p10_hrv_7d,              p20_hrv_7d,              p80_hrv_7d,              p90_hrv_7d,
    p10_resting_hr,          p20_resting_hr,          p80_resting_hr,          p90_resting_hr,
    p10_sleep_duration,      p20_sleep_duration,      p80_sleep_duration,      p90_sleep_duration,
    p10_sleep_continuity,    p20_sleep_continuity,    p80_sleep_continuity,    p90_sleep_continuity,
    p10_steps,               p90_steps,
    p20_steps_weekday,       p80_steps_weekday,
    p20_steps_weekend,       p80_steps_weekend,
    p10_active_minutes,      p90_active_minutes,
    p20_active_minutes_weekday, p80_active_minutes_weekday,
    p20_active_minutes_weekend, p80_active_minutes_weekend,
  };
}

// Computes the smoothed HRV series: for each row with non-null HRV,
// takes the trailing 7-day avg up to that row. Used as the input
// distribution for HRV p20/p80 boundary computation.
function computeSmoothedHRVSeries(rows: DailyInput[]): number[] {
  const result: number[] = [];
  for (let i = 0; i < rows.length; i++) {
    const window = rows.slice(Math.max(0, i - 6), i + 1)
      .map((r) => r.hrv_ms)
      .filter((v): v is number => v != null && !isNaN(v));
    if (window.length > 0) {
      result.push(window.reduce((a, b) => a + b, 0) / window.length);
    }
  }
  return result;
}

// ─────────────────────────────────────────
// ZONE CLASSIFICATION (Layer 1)
// Classifies a single metric reading against its p20/p80 boundaries.
// Returns null when:
//   - trust state is below provisional
//   - p20 or p80 is null (insufficient data for that metric)
//   - todayValue is null (metric not captured today)
//
// For steps and active_minutes: caller passes appropriate weekday or
// weekend boundary values based on dayOfWeek.
//
// flagged zone: maps to deviation === -2 (hard flag from scoring engine).
// Never computed independently here — caller passes isHardFlagged.
// ─────────────────────────────────────────

export function classifyZone(params: {
  todayValue:    number | null | undefined;
  p20:           number | null | undefined;
  p80:           number | null | undefined;
  p50?:          number | null | undefined; // optional, used for within_range_high/low split
  trustState:    RangeTrustState;
  isHardFlagged?: boolean; // true if deviation === -2 for this metric
}): ZoneState {
  const { todayValue, p20, p80, p50, trustState, isHardFlagged = false } = params;

  // Zone classification only active from provisional state upward
  if (trustState === "establishing" || trustState === "calibrating") return null;

  // Metric not captured today or boundaries not yet computed
  if (todayValue == null || p20 == null || p80 == null) return null;

  // Hard deviation takes precedence (safety signal)
  if (isHardFlagged) return "flagged";

  if (todayValue > p80) return "elevated";

  // Split within-range into high/low halves using p50 if available
  const midpoint = p50 ?? (p20 + p80) / 2;
  if (todayValue >= midpoint) return "within_range_high";
  if (todayValue >= p20)      return "within_range_low";

  return "below_range";
}

// ─────────────────────────────────────────
// ZONE LABEL FOR A DRIVER METRIC
// Convenience wrapper: resolves metric-specific boundary lookups,
// applies weekday/weekend selection, computes p50 for midpoint split.
// Returns ZoneState.
// ─────────────────────────────────────────

export function classifyDriverZone(params: {
  metric:       string;
  todayValue:   number | null | undefined;
  hrv7dAvg:     number | null;
  date:         string;  // date string for weekday/weekend detection
  percentiles:  RangePercentiles;
  trustState:   RangeTrustState;
  isHardFlagged: boolean;
}): ZoneState {
  const { metric, todayValue, hrv7dAvg, date, percentiles, trustState, isHardFlagged } = params;
  const weekend = isWeekend(date);

  let p20: number | null | undefined;
  let p80: number | null | undefined;
  let effectiveValue = todayValue;

  switch (metric) {
    case "hrv":
      // HRV zone uses smoothed 7d avg, not raw daily reading
      effectiveValue = hrv7dAvg;
      p20 = percentiles.p20_hrv_7d;
      p80 = percentiles.p80_hrv_7d;
      break;
    case "resting_hr":
      p20 = percentiles.p20_resting_hr;
      p80 = percentiles.p80_resting_hr;
      break;
    case "sleep_duration":
      p20 = percentiles.p20_sleep_duration;
      p80 = percentiles.p80_sleep_duration;
      break;
    case "sleep_continuity":
      p20 = percentiles.p20_sleep_continuity;
      p80 = percentiles.p80_sleep_continuity;
      break;
    case "steps":
      p20 = weekend ? percentiles.p20_steps_weekend    : percentiles.p20_steps_weekday;
      p80 = weekend ? percentiles.p80_steps_weekend    : percentiles.p80_steps_weekday;
      break;
    case "active_minutes":
      p20 = weekend ? percentiles.p20_active_minutes_weekend : percentiles.p20_active_minutes_weekday;
      p80 = weekend ? percentiles.p80_active_minutes_weekend : percentiles.p80_active_minutes_weekday;
      break;
    default:
      // Metrics without range boundaries (spo2, stand_hours, respiratory_rate, etc.)
      return null;
  }

  const p50 = (p20 != null && p80 != null) ? p20 + (p80 - p20) * 0.5 : undefined;

  return classifyZone({ todayValue: effectiveValue, p20, p80, p50, trustState, isHardFlagged });
}
