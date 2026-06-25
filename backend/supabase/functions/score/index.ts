// backend/supabase/functions/score/index.ts
// MBI Phase 1 — Scoring Pipeline Edge Function
// Sprint 4 | Wires ingestion → domain layer → daily_scores
// Sprint 2 update: populates trend_aggregates after each daily score upsert
// Data Tier v1.0: steps_only guard (Section 4), qualified history filter (Section 5)
//
// ─────────────────────────────────────────────────────────────────────────────
// DATA INTEGRITY RULE: Driver Deduplication
// driver_1 and driver_2 (daily_scores) must never be identical non-null values.
// top_driver_1 and top_driver_2 (trend_aggregates) must never be identical non-null values.
// Enforced by: runtime assertion in selectTopDrivers(), DB constraint chk_drivers_distinct.
// Verification query:
//   SELECT COUNT(*) FROM daily_scores WHERE driver_1 = driver_2;
//   SELECT COUNT(*) FROM trend_aggregates WHERE top_driver_1 = top_driver_2;
// Expected result: 0 rows. If non-zero, recompute affected rows using upsertWeeklyAggregate().
// ─────────────────────────────────────────────────────────────────────────────

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  computeBaseline, scoreDay, DOMAIN_VERSION,
  computeValidDays, computeTrustState, computeHRV7dRollingAvg,
  computeRangePercentiles, classifyDriverZone,
} from "../../functions/_shared/domain/index.ts";
import type { DeclineSignal, DeviationState } from "../../functions/_shared/domain/index.ts";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
    const { userId, date } = await req.json();

    if (!userId || !date) {
      return new Response(JSON.stringify({ error: "userId and date required" }), {
        status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // ── S13: Verify the caller's JWT matches the requested userId ─────
    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    // ── 1. Fetch today's canonical input ──────────────────────────────
    const { data: input, error: inputErr } = await supabase
      .from("daily_inputs")
      .select("*")
      .eq("user_id", userId)
      .eq("date", date)
      .single();

    if (inputErr || !input) {
      return new Response(JSON.stringify({ error: "No input found for this date" }), {
        status: 404, headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // ── Section 4: Data tier guard — skip steps_only days ────────────────────
    // steps_only days have no wearable signals. The scoring engine cannot produce
    // meaningful domain scores without HRV, resting HR, or sleep continuity.
    // These days still exist in daily_inputs (for gap tracking) but get no score row.
    if (input.data_tier === "steps_only") {
      console.log(
        `[score] Skipping steps_only day for user ${userId} on ${date} — ` +
        `no wearable signals in daily_inputs.`
      );
      return new Response(
        JSON.stringify({ success: true, skipped: true, reason: "steps_only", data_tier: "steps_only" }),
        { headers: { "Content-Type": "application/json", ...corsHeaders() } }
      );
    }

    // ── 2. Fetch up to 90 days of history ────────────────────────────
    // Fetch descending (most recent first) then reverse to ascending so that:
    //   • historyRows[last] = yesterday (correct for deviationContext)
    //   • qualifiedHistory.slice(-7) = the 7 most recent rows (correct baseline window)
    //   • computeValidDays recency counts (last35, last60) use actual recent data
    // BUG NOTE: ascending+limit returns the OLDEST 90 rows, not the most recent 90.
    // With 365+ days of history this caused computeValidDays to return total≈0 for
    // the old sparse early-dataset rows → trustState "establishing" for all dates.
    const { data: history } = await supabase
      .from("daily_inputs")
      .select("*")
      .eq("user_id", userId)
      .lt("date", date)
      .order("date", { ascending: false })
      .limit(90);

    // Reverse to ascending date order for slice(-7) and deviationContext (yesterday = last element)
    const historyRows = (history ?? []).reverse();
    const historyDays = historyRows.length;

    // ── Section 5: Qualified history — wearable|partial only ─────────────────
    // Exclude steps_only days from baseline computation. Including them dilutes
    // HRV/sleep averages with zero-signal days, producing artificially low baselines.
    // Pre-migration rows with data_tier == null or 'unknown' are treated as wearable
    // (safe fallback: these rows were ingested before tier classification existed).
    const qualifiedHistory = historyRows.filter((r: Record<string, unknown>) =>
      r.data_tier === "wearable" ||
      r.data_tier === "partial"  ||
      r.data_tier == null        ||   // pre-migration rows (no tier column yet)
      r.data_tier === "unknown"       // unknown = truly empty payload — keep for now
    );

    const baselineRows = qualifiedHistory.slice(-7);
    const baseline = computeBaseline(baselineRows);

    // ── 2b. Range trust state + percentiles (computed before scoreDay) ──
    // Percentiles must be available before computeDeviations() runs so
    // deviation.ts can use personal p10/p90 thresholds for reserve flags.
    // Section 5: all range computations use qualifiedHistory (wearable|partial only).
    const validCounts = computeValidDays(qualifiedHistory, date);
    const trustState  = computeTrustState(validCounts);
    const hrv7dAvg    = computeHRV7dRollingAvg(qualifiedHistory);

    const percentiles = (trustState !== "establishing" && trustState !== "calibrating")
      ? computeRangePercentiles(qualifiedHistory)
      : null;

    // Augment baseline with personal p10/p90 so deviation.ts uses them
    // instead of hardcoded absolute values for reserve flag thresholds.
    if (baseline && percentiles) {
      baseline.p10_hrv_7d      = percentiles.p10_hrv_7d;
      baseline.p90_hrv_7d      = percentiles.p90_hrv_7d;
      baseline.p10_resting_hr  = percentiles.p10_resting_hr;
      baseline.p90_resting_hr  = percentiles.p90_resting_hr;
    }

    // ── 3. Fetch user step goal ───────────────────────────────────────
    const { data: user } = await supabase
      .from("users")
      .select("step_goal")
      .eq("id", userId)
      .single();

    const stepGoal = user?.step_goal ?? 8000;

    // ── 4. Fetch recent scores for delta override & fail state ────────
    const { data: recentScoreRows } = await supabase
      .from("daily_scores")
      .select("chronos_score, date")
      .eq("user_id", userId)
      .lt("date", date)
      .order("date", { ascending: false })
      .limit(5);

    const recentScores = (recentScoreRows ?? [])
      .map((r: { chronos_score: number }) => r.chronos_score)
      .filter((s: number) => s != null)
      .reverse();

    // ── 5. Compute last engagement gap ───────────────────────────────
    const engagementDays = recentScoreRows && recentScoreRows.length > 0
      ? daysBetween(recentScoreRows[0].date ?? date, date)
      : 0;

    // ── 5b. Decline-signal window (v1.6) — prior 7 calendar days ──────
    // Yellowline momentum signal: reference score (most recent non-null 5–7d ago),
    // scored-day gate, and yesterday's decline_signal for hysteresis. The pure
    // computeDeclineSignal (inside scoreDay) consumes these pre-computed inputs.
    const declineWindowStart = new Date(date);
    declineWindowStart.setUTCDate(declineWindowStart.getUTCDate() - 7);
    const { data: declineWindowRows } = await supabase
      .from("daily_scores")
      .select("date, chronos_score, decline_signal")
      .eq("user_id", userId)
      .gte("date", toDateString(declineWindowStart))
      .lt("date", date)
      .order("date", { ascending: false })
      .limit(7);

    const declineRows = (declineWindowRows ?? []) as Array<
      { date: string; chronos_score: number | null; decline_signal: DeclineSignal }
    >;
    // Reference: most recent row dated 5–7 days ago carrying a non-null score
    const referenceScore = declineRows.find((r) => {
      const daysAgo = daysBetween(date, r.date);
      return daysAgo >= 5 && daysAgo <= 7 && r.chronos_score != null;
    })?.chronos_score ?? null;
    // Gate: count of scored days in the prior 7-day window
    const scoredDaysInWindow = declineRows.filter((r) => r.chronos_score != null).length;
    // Hysteresis: yesterday's decline_signal (null if no prior row exists)
    const prevDeclineSignal: DeclineSignal =
      declineRows.find((r) => daysBetween(date, r.date) === 1)?.decline_signal ?? null;

    // ── 6. Run scoring engine ─────────────────────────────────────────
    const result = scoreDay({
      input: {
        userId,
        date,
        hrv_ms: input.hrv_ms,
        resting_hr_bpm: input.resting_hr_bpm,
        respiratory_rate_rpm: input.respiratory_rate_rpm,
        sleep_duration_hrs: input.sleep_duration_hrs,
        sleep_continuity_pct: input.sleep_continuity_pct,
        steps: input.steps,
        active_minutes: input.active_minutes,
        distance_km: input.distance_km,
        spo2_pct: input.spo2_pct,
        resting_energy: input.resting_energy,
        stand_hours: input.stand_hours,
      },
      baseline,
      historyDays,
      recentScores,
      stepGoal,
      engagementDays,
      // Decline signal v1.6 — pre-computed history inputs (see §5b)
      referenceScore,
      scoredDaysInWindow,
      prevDeclineSignal,
      // Bug #5 fix: populate prevSleepContinuityDeviation so sleep continuity corroboration works.
      // historyRows is ascending by date; the last row is yesterday's inputs.
      deviationContext: (() => {
        // Use historyRows (all rows) for yesterday — we want the most recent calendar day
        // regardless of its data tier, to compute sleep continuity corroboration correctly.
        const yesterday = historyRows.length > 0 ? historyRows[historyRows.length - 1] : null;
        const prevSC = yesterday?.sleep_continuity_pct ?? null;
        const scBaseline = baseline?.sleep_continuity_avg ?? null;
        if (prevSC === null || scBaseline === null || scBaseline === 0) return {};
        let prevSleepContinuityDeviation: DeviationState;
        if (prevSC < 70) {
          prevSleepContinuityDeviation = -2; // absolute hard — standalone threshold
        } else {
          const diff = (scBaseline - prevSC) / scBaseline;
          prevSleepContinuityDeviation = diff >= 0.05 ? -1 : 0;
        }
        return { prevSleepContinuityDeviation };
      })(),
    });

    // ── 6b. Null guard — confidence_tier "none" skips daily_scores upsert ────
    if (result.chronos_score === null) {
      return new Response(JSON.stringify({ success: true, baseline_building: true, confidence_tier: "none" }), {
        headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // ── 6b. Driver deduplication assertion ───────────────────────────
    if (result.driver_1 && result.driver_2 && result.driver_1 === result.driver_2) {
      throw new Error(
        `Driver deduplication failed: driver_1 and driver_2 are both "${result.driver_1}" for user ${userId} on ${date}`
      );
    }

    // ── 6c. Zone classification ───────────────────────────────────────
    // Trust state + percentiles already computed in step 2b.
    // Determine hard-flagged metrics (deviation === -2) for "flagged" zone label
    const hardFlagged = new Set<string>(
      result.deviations
        .filter((d) => d.deviation === -2)
        .map((d) => d.metric)
    );

    // Classify zones for the two driver metrics
    const zone_1 = percentiles
      ? classifyDriverZone({
          metric:       result.driver_1,
          todayValue:   getMetricValue(input, result.driver_1),
          hrv7dAvg,
          date,
          percentiles,
          trustState,
          isHardFlagged: hardFlagged.has(result.driver_1),
        })
      : null;

    // zone_2 is only meaningful when a second driver exists AND has a fresh reading
    // today. A null driver_2 (single weighted metric) or a stale/baseline-only driver_2
    // (v1.7 fallback — no today's value) both leave zone_2 null; classifyDriverZone
    // requires a real todayValue and must not receive a stale or null metric.
    const driver2 = result.driver_2;
    const zone_2 = (percentiles && driver2 && !result.driver_2_stale)
      ? classifyDriverZone({
          metric:       driver2,
          todayValue:   getMetricValue(input, driver2),
          hrv7dAvg,
          date,
          percentiles,
          trustState,
          isHardFlagged: hardFlagged.has(driver2),
        })
      : null;

    // ── 7. Upsert baseline snapshot ───────────────────────────────────
    if (baseline) {
      // Guard: resting_hr_avg and sleep_duration_avg must be non-null.
      // These two signals are present on virtually every Apple Watch day (wearable or partial).
      //
      // hrv_avg is intentionally NOT required: HRV is only captured on ~28% of days for
      // typical Watch users. Requiring it caused 0 baselines across a 365-day backfill
      // when the user's HRV data was sparse. hrv_avg will be non-null in the baseline
      // row whenever the 7-day window includes at least one HRV day — this is the correct
      // behaviour. The data_tier system (Section 4/5) now prevents corrupt steps-only
      // rows from reaching baseline computation, making the original strict guard redundant.
      const requiredFields = ["resting_hr_avg", "sleep_duration_avg"] as const;
      const hasMinimumData = requiredFields.every(
        (field) => baseline[field] != null
      );

      if (!hasMinimumData) {
        console.warn(
          `[baselines] Skipping write for user ${userId} on ${date} — ` +
          `missing required metric averages (resting_hr_avg, sleep_duration_avg)`
        );
      } else if (validCounts.total === 0) {
        console.warn(
          `[baselines] Skipping write for user ${userId} on ${date} — range_valid_days is 0`
        );
      } else {
        await supabase.from("baselines").upsert({
          user_id: userId,
          computed_on: date,
          ...baseline,
          domain_version: DOMAIN_VERSION,
          // Range Architecture columns
          ...(percentiles ?? {}),
          hrv_7d_rolling_avg: hrv7dAvg,
          range_trust_state:  trustState,
          range_valid_days:   validCounts.total,
          range_computed_at:  new Date().toISOString(),
        }, { onConflict: "user_id,computed_on" });
      }
    }

    // ── 8. Upsert score row ───────────────────────────────────────────
    const scoreRow = {
      user_id: userId,
      date,
      chronos_score: result.chronos_score,
      score_band: result.score_band,
      decline_signal: result.decline_signal,
      health_score: result.health_score,
      risk_score: result.risk_score,
      alpha: result.alpha,
      d1_autonomic: result.domain_scores.d1_autonomic,
      d2_sleep: result.domain_scores.d2_sleep,
      d3_activity: result.domain_scores.d3_activity,
      d4_stress: result.domain_scores.d4_stress,
      d5_allostatic: result.domain_scores.d5_allostatic,
      driver_1: result.driver_1,
      driver_2: result.driver_2,
      driver_2_stale: result.driver_2_stale,
      delta_override_triggered: result.delta_override_triggered,
      fail_state: result.fail_state,
      is_provisional: result.is_provisional,
      domain_version: result.domain_version,
      confidence_tier: result.confidence_tier,
      pre_drift_signal: result.pre_drift_signal,
      reserve_flags: result.reserve_flags,
      // Range Architecture v1.0
      zone_1,
      zone_2,
      range_trust_state: trustState,  // v1.5: also written to daily_scores for iOS direct access
      // Section 4: mirror data_tier from input row for iOS direct access
      data_tier: input.data_tier ?? "wearable",
    };

    const { data: savedScore, error: scoreErr } = await supabase
      .from("daily_scores")
      .upsert(scoreRow, { onConflict: "user_id,date" })
      .select()
      .single();

    if (scoreErr) throw scoreErr;

    // ── 8a. SHADOW LAYER: p10/p90 zone classification (OI-004) ───────
    // Runs after daily_scores write. Additive only — never touches production output.
    // Errors are caught and logged; a shadow failure must never surface to the iOS client.
    try {
      await writeShadowScore({
        supabase,
        userId,
        date,
        input,
        trustState,
        percentiles,
        hrv7dAvg,
      });
    } catch (shadowErr) {
      console.error("[score] shadow layer failed (non-fatal):", shadowErr);
    }

    // ── 9. First occurrence events (learning foundation) ─────────────
    // UNIQUE(user_id, event_name) deduplicates — second insert fails silently.
    // Non-fatal: unique constraint violations are expected and swallowed.
    const scoreId = savedScore?.id ?? null;

    if (trustState === "provisional") {
      logFirstOccurrence(supabase, userId, "first_provisional_state", scoreId);
    }
    if (trustState === "trusted") {
      logFirstOccurrence(supabase, userId, "first_trusted_state", scoreId);
    }
    if (result.fail_state === "Redline") {
      logFirstOccurrence(supabase, userId, "first_redline", scoreId);
    }
    if (result.fail_state === "Drift") {
      logFirstOccurrence(supabase, userId, "first_drift", scoreId);
    }
    // Personal percentile breach events — only fire when personal p10/p90
    // are available (i.e. not using the hardcoded fallback threshold)
    const hrvDev = result.deviations.find((d) => d.metric === "hrv");
    if (hrvDev?.reserve_flag === "LOW_ABSOLUTE_RESERVE" && percentiles?.p10_hrv_7d != null) {
      logFirstOccurrence(supabase, userId, "first_below_personal_p10_hrv", scoreId);
    }
    const rhrDev = result.deviations.find((d) => d.metric === "resting_hr");
    if (rhrDev?.reserve_flag === "HIGH_ABSOLUTE_RHR" && percentiles?.p90_resting_hr != null) {
      logFirstOccurrence(supabase, userId, "first_above_personal_p90_rhr", scoreId);
    }

    // ── 10. Populate trend_aggregates (non-fatal) ─────────────────────
    try {
      await upsertTrendAggregates(userId, date);
    } catch (aggErr) {
      console.error("[score] trend_aggregates upsert failed (non-fatal):", aggErr);
    }

    // ── 11. Horizon escalation check (non-fatal) — P4.1 / P4.2 ──────
    // Detects 3 consecutive calendar days below chronos_score 65.
    // Threshold: 65 (not 35 / Redline floor — catches declining trends early).
    // On detection: logs to horizon_escalations table for founder review.
    // On detection: sends email alert to founder via horizon-alert Edge Function.
    // APNs push deferred post-beta.
    try {
      if (result.chronos_score !== null) {
      await checkHorizonEscalation(supabase, userId, date, result.chronos_score);
      }
    } catch (escErr) {
      console.error("[score] horizon escalation check failed (non-fatal):", escErr);
    }

    return new Response(JSON.stringify({ success: true, score: savedScore, result }), {
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    });

  } catch (err) {
    console.error("[score]", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    });
  }
});

// ─────────────────────────────────────────
// TREND AGGREGATES
// Each helper instantiates its own Supabase client.
// Avoids ReturnType<typeof createClient> generic inference issues in Deno.
// ─────────────────────────────────────────

async function upsertTrendAggregates(userId: string, date: string): Promise<void> {
  await Promise.all([
    upsertWeeklyAggregate(userId, date),
    upsertMonthlyAggregate(userId, date),
  ]);
}

async function upsertWeeklyAggregate(userId: string, date: string): Promise<void> {
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  const d = new Date(date);
  const dayOfWeek = d.getUTCDay();
  const daysFromMonday = dayOfWeek === 0 ? 6 : dayOfWeek - 1;
  const weekStart = new Date(d);
  weekStart.setUTCDate(d.getUTCDate() - daysFromMonday);
  const weekEnd = new Date(weekStart);
  weekEnd.setUTCDate(weekStart.getUTCDate() + 6);
  const windowStart = toDateString(weekStart);
  const windowEnd = toDateString(weekEnd);

  const { data: scoreRows } = await sb
    .from("daily_scores")
    .select("date, chronos_score, driver_1, driver_2")
    .eq("user_id", userId)
    .gte("date", windowStart)
    .lte("date", windowEnd)
    .order("date", { ascending: true });

  const { data: inputRows } = await sb
    .from("daily_inputs")
    .select("date, hrv_ms, resting_hr_bpm, respiratory_rate_rpm, sleep_duration_hrs, sleep_continuity_pct, steps, active_minutes")
    .eq("user_id", userId)
    .gte("date", windowStart)
    .lte("date", windowEnd);

  if (!scoreRows || scoreRows.length === 0) return;

  const aggregate = computeAggregate(scoreRows, inputRows ?? []);

  if (aggregate.top_driver_1 && aggregate.top_driver_2 && aggregate.top_driver_1 === aggregate.top_driver_2) {
    throw new Error(
      `Driver deduplication failed in weekly aggregate: top_driver_1 and top_driver_2 are both "${aggregate.top_driver_1}" for user ${userId} window ${windowStart}`
    );
  }

  const trendDirection = await computeTrendDirection(sb, userId, windowStart, "weekly", aggregate.chronos_avg);

  const row: Record<string, unknown> = {
    user_id: userId,
    window_type: "weekly",
    window_start: windowStart,
    window_end: windowEnd,
    trend_direction: trendDirection,
    updated_at: new Date().toISOString(),
    ...aggregate,
  };

  // deno-lint-ignore no-explicit-any
  await (sb as any).from("trend_aggregates").upsert(row, { onConflict: "user_id,window_type,window_start" });
}

async function upsertMonthlyAggregate(userId: string, date: string): Promise<void> {
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  const d = new Date(date);
  const windowStart = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-01`;
  const lastDay = new Date(d.getUTCFullYear(), d.getUTCMonth() + 1, 0).getUTCDate();
  const windowEnd = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(lastDay).padStart(2, "0")}`;

  const { data: scoreRows } = await sb
    .from("daily_scores")
    .select("date, chronos_score, driver_1, driver_2")
    .eq("user_id", userId)
    .gte("date", windowStart)
    .lte("date", windowEnd)
    .order("date", { ascending: true });

  const { data: inputRows } = await sb
    .from("daily_inputs")
    .select("date, hrv_ms, resting_hr_bpm, respiratory_rate_rpm, sleep_duration_hrs, sleep_continuity_pct, steps, active_minutes")
    .eq("user_id", userId)
    .gte("date", windowStart)
    .lte("date", windowEnd);

  if (!scoreRows || scoreRows.length === 0) return;

  const aggregate = computeAggregate(scoreRows, inputRows ?? []);

  if (aggregate.top_driver_1 && aggregate.top_driver_2 && aggregate.top_driver_1 === aggregate.top_driver_2) {
    throw new Error(
      `Driver deduplication failed in monthly aggregate: top_driver_1 and top_driver_2 are both "${aggregate.top_driver_1}" for user ${userId} window ${windowStart}`
    );
  }

  const trendDirection = await computeTrendDirection(sb, userId, windowStart, "monthly", aggregate.chronos_avg);

  const row: Record<string, unknown> = {
    user_id: userId,
    window_type: "monthly",
    window_start: windowStart,
    window_end: windowEnd,
    trend_direction: trendDirection,
    updated_at: new Date().toISOString(),
    ...aggregate,
  };

  // deno-lint-ignore no-explicit-any
  await (sb as any).from("trend_aggregates").upsert(row, { onConflict: "user_id,window_type,window_start" });
}

// ─────────────────────────────────────────
// COMPUTE AGGREGATE — pure, no Supabase calls
// ─────────────────────────────────────────

function computeAggregate(
  scoreRows: Array<{ date: string; chronos_score: number; driver_1: string; driver_2: string }>,
  inputRows: Array<Record<string, unknown>>
): Record<string, unknown> {
  const chronosScores = scoreRows.map(r => r.chronos_score).filter(v => v != null);

  const chronos_avg = avg(chronosScores);
  const chronos_min = chronosScores.length > 0 ? Math.min(...chronosScores) : null;
  const chronos_max = chronosScores.length > 0 ? Math.max(...chronosScores) : null;

  const hrv_avg             = avgField(inputRows, "hrv_ms");
  const resting_hr_avg      = avgField(inputRows, "resting_hr_bpm");
  const respiratory_rate_avg = avgField(inputRows, "respiratory_rate_rpm");
  const sleep_duration_avg  = avgField(inputRows, "sleep_duration_hrs");
  const sleep_continuity_avg = avgField(inputRows, "sleep_continuity_pct");
  const steps_avg           = avgField(inputRows, "steps");
  const active_minutes_avg  = avgField(inputRows, "active_minutes");

  const driverFreq: Record<string, number> = {};
  for (const row of scoreRows) {
    if (row.driver_1) driverFreq[row.driver_1] = (driverFreq[row.driver_1] ?? 0) + 1;
    if (row.driver_2) driverFreq[row.driver_2] = (driverFreq[row.driver_2] ?? 0) + 1;
  }
  const sortedDrivers = Object.entries(driverFreq).sort((a, b) => b[1] - a[1]);
  const topDriver1 = sortedDrivers[0]?.[0] ?? null;
  // Never duplicate top_driver_1 — find the next distinct entry
  const topDriver2 = sortedDrivers.find(([k], i) => i > 0 && k !== topDriver1)?.[0] ?? null;

  return {
    chronos_avg,
    chronos_min,
    chronos_max,
    days_in_window: chronosScores.length,
    hrv_avg,
    resting_hr_avg,
    respiratory_rate_avg,
    sleep_duration_avg,
    sleep_continuity_avg,
    steps_avg,
    active_minutes_avg,
    top_driver_1: topDriver1,
    top_driver_2: topDriver2,
  };
}

// ─────────────────────────────────────────
// TREND DIRECTION
// ─────────────────────────────────────────

async function computeTrendDirection(
  // deno-lint-ignore no-explicit-any
  sb: any,
  userId: string,
  currentWindowStart: string,
  windowType: string,
  currentAvg: unknown
): Promise<"improving" | "stable" | "declining"> {
  if (currentAvg == null || typeof currentAvg !== "number") return "stable";

  const { data: prior } = await sb
    .from("trend_aggregates")
    .select("chronos_avg")
    .eq("user_id", userId)
    .eq("window_type", windowType)
    .lt("window_start", currentWindowStart)
    .order("window_start", { ascending: false })
    .limit(1)
    .single();

  const priorAvg = prior?.chronos_avg;
  if (priorAvg == null || typeof priorAvg !== "number") return "stable";

  const diff = currentAvg - priorAvg;
  if (diff > 3)  return "improving";
  if (diff < -3) return "declining";
  return "stable";
}

// ─────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────

function avg(values: number[]): number | null {
  if (values.length === 0) return null;
  return values.reduce((a, b) => a + b, 0) / values.length;
}

function avgField(rows: Array<Record<string, unknown>>, field: string): number | null {
  const vals = rows
    .map(r => r[field])
    .filter((v): v is number => v != null && typeof v === "number");
  return avg(vals);
}

function toDateString(date: Date): string {
  return date.toISOString().split("T")[0];
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}

// ─────────────────────────────────────────
// HORIZON ESCALATION CHECK — P4.1 / P4.2
//
// Fires when chronos_score < 65 for 3 consecutive calendar days.
// Writes to horizon_escalations table. On detection, sets push_sent=false;
// Sends email alert to founder via horizon-alert Edge Function. APNs deferred post-beta.
//
// Safety rules:
//   • Days must be consecutive calendar days (gap of exactly 1 between each)
//   • Deduplication: no re-escalation within 7 days of the last alert
//   • Non-fatal: all errors are swallowed by the caller
// ─────────────────────────────────────────

const ESCALATION_THRESHOLD  = 65;   // P4.1: below this for 3 days triggers alert
const ESCALATION_STREAK     = 3;    // P4.2: number of consecutive days required
const ESCALATION_COOLDOWN   = 7;    // days before another escalation can fire for same user

// deno-lint-ignore no-explicit-any
async function checkHorizonEscalation(
  supabase: any,
  userId: string,
  date: string,
  todayScore: number,
): Promise<void> {
  // Fast path: today doesn't meet threshold
  if (todayScore >= ESCALATION_THRESHOLD) return;

  // Fetch the 2 prior score rows (today is already < threshold)
  const { data: priorRows } = await supabase
    .from("daily_scores")
    .select("chronos_score, date")
    .eq("user_id", userId)
    .lt("date", date)
    .order("date", { ascending: false })
    .limit(ESCALATION_STREAK - 1);

  if (!priorRows || priorRows.length < ESCALATION_STREAK - 1) return;

  const [day2Row, day1Row] = priorRows;  // day2 = yesterday, day1 = day before

  // All must be below threshold
  if (day2Row.chronos_score >= ESCALATION_THRESHOLD) return;
  if (day1Row.chronos_score >= ESCALATION_THRESHOLD) return;

  // Verify calendar consecutiveness (gaps must each be exactly 1 day)
  const todayDate = new Date(date);
  const day2Date  = new Date(day2Row.date);
  const day1Date  = new Date(day1Row.date);

  const gap1 = Math.round((todayDate.getTime() - day2Date.getTime()) / 86_400_000);
  const gap2  = Math.round((day2Date.getTime()  - day1Date.getTime())  / 86_400_000);

  if (gap1 !== 1 || gap2 !== 1) return;  // not consecutive calendar days

  // Deduplication: no re-escalation within cooldown window
  const cooldownStart = new Date(todayDate);
  cooldownStart.setDate(cooldownStart.getDate() - ESCALATION_COOLDOWN);

  const { data: recentAlerts } = await supabase
    .from("horizon_escalations")
    .select("id")
    .eq("user_id", userId)
    .gte("triggered_date", cooldownStart.toISOString().split("T")[0])
    .limit(1);

  if (recentAlerts && recentAlerts.length > 0) return;  // cooldown active

  // Insert escalation record
  const { error: insertErr } = await supabase
    .from("horizon_escalations")
    .insert({
      user_id:        userId,
      triggered_date: date,
      score_day1:     day1Row.chronos_score,   // oldest
      score_day2:     day2Row.chronos_score,
      score_day3:     todayScore,              // most recent (today)
      streak_length:  ESCALATION_STREAK,
      push_sent:      false,
      // push_sent reserved for APNs implementation post-beta
    });

  if (insertErr) {
    console.error("[score] horizon_escalations insert failed:", insertErr);
    return;
  }

  // OI-018: Horizon escalation email alert (beta implementation).
  // Routes to founder monitoring address only. APNs deferred post-beta.
  try {
    const horizonAlertURL = `${SUPABASE_URL}/functions/v1/horizon-alert`;
    const alertPayload = {
      userId,
      triggeredDate: date,
      scoreDay1: day1Row.chronos_score,
      scoreDay2: day2Row.chronos_score,
      scoreDay3: todayScore,
      streakLength: ESCALATION_STREAK,
    };
    const alertResp = await fetch(horizonAlertURL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${SUPABASE_SERVICE_KEY}`,
      },
      body: JSON.stringify(alertPayload),
    });
    if (!alertResp.ok) {
      console.error(`[horizon-escalation] alert email failed: ${alertResp.status}`);
    } else {
      console.log(`[horizon-escalation] alert email sent for userId ...${userId.slice(-6)}`);
    }
  } catch (alertErr) {
    // Best-effort — do not let alert failure block the score response
    console.error("[horizon-escalation] alert call threw:", alertErr);
  }
}

function daysBetween(dateA: string, dateB: string): number {
  const msPerDay = 86_400_000;
  return Math.abs(new Date(dateB).getTime() - new Date(dateA).getTime()) / msPerDay;
}

// Maps a MetricName to its raw value from the daily_inputs row.
// Used to pass the correct today-value to classifyDriverZone().
// ─────────────────────────────────────────
// FIRST OCCURRENCE EVENTS (Learning Foundation)
// Idempotent via UNIQUE(user_id, event_name) constraint.
// Unique constraint violations are expected and swallowed — do not re-throw.
// ─────────────────────────────────────────

// deno-lint-ignore no-explicit-any
async function logFirstOccurrence(
  // deno-lint-ignore no-explicit-any
  supabase: any,
  userId: string,
  eventName: string,
  scoreId: string | null,
): Promise<void> {
  try {
    await supabase.from("first_occurrence_events").insert({
      user_id:          userId,
      event_name:       eventName,
      related_score_id: scoreId,
      first_seen_at:    new Date().toISOString(),
    });
  } catch (err) {
    // Unique constraint violation is expected on repeat triggers — swallow silently.
    // Only log unexpected errors.
    if (!String(err).includes("unique")) {
      console.error(`[score] first_occurrence ${eventName} log failed:`, err);
    }
  }
}

// ─────────────────────────────────────────
// SHADOW LAYER — OI-004 · p10/p90 Zone Classification
//
// Spec: MBI_Chronos_OI004_ShadowMode_SpecHandoff_v1_0.docx
// shadow-v0.1
//
// INVARIANT: This function is the only entry point for shadow writes.
// It must never modify production output, scores, flags, drivers, or narratives.
// It must be removable without touching any production logic.
//
// Zone definitions (LR-004):
//   NORMAL  — p20 ≤ value ≤ p80  (within production trust band)  side: null
//   OUTER   — p10 ≤ value < p20  (low) or p80 < value ≤ p90 (high)
//   EXTREME — value < p10 (low) or value > p90 (high)
// ─────────────────────────────────────────

const SHADOW_VERSION = "shadow-v0.1";

type ShadowZone = "NORMAL" | "OUTER" | "EXTREME";
type ShadowSide = "low" | "high" | null;

interface ShadowMetricResult {
  zone:  ShadowZone;
  value: number;
  p10:   number;
  p20:   number;
  p80:   number;
  p90:   number;
  side:  ShadowSide;
}

function classifyShadowZone(
  value: number,
  p10: number,
  p20: number,
  p80: number,
  p90: number,
): { zone: ShadowZone; side: ShadowSide } {
  if (value < p10)  return { zone: "EXTREME", side: "low" };
  if (value < p20)  return { zone: "OUTER",   side: "low" };
  if (value <= p80) return { zone: "NORMAL",  side: null };
  if (value <= p90) return { zone: "OUTER",   side: "high" };
  return                   { zone: "EXTREME", side: "high" };
}

// deno-lint-ignore no-explicit-any
async function writeShadowScore(params: {
  supabase:    any;
  userId:      string;
  date:        string;
  input:       Record<string, unknown>;
  trustState:  string;
  percentiles: import("../../functions/_shared/domain/range.ts").RangePercentiles | null;
  hrv7dAvg:    number | null;
}): Promise<void> {
  const { supabase, userId, date, input, trustState, percentiles, hrv7dAvg } = params;

  // Trust state gate: only run for provisional, trusted, or established.
  // Never runs during calibrating or establishing (mirrors production deviation gate).
  if (
    trustState === "calibrating" ||
    trustState === "establishing"
  ) {
    return;
  }

  // Percentiles must be present — they are computed only for provisional+.
  // This is a safety double-gate: trust state check above is the primary guard.
  if (!percentiles) return;

  const weekend = new Date(date).getUTCDay() === 0 || new Date(date).getUTCDay() === 6;
  const metric_zones: Record<string, ShadowMetricResult> = {};

  // Helper: classify one metric and add to metric_zones if all values present.
  function classify(
    key: string,
    rawValue: unknown,
    p10: number | null | undefined,
    p20: number | null | undefined,
    p80: number | null | undefined,
    p90: number | null | undefined,
  ): void {
    // Exclude metric if value or any boundary is null (spec §4.3)
    if (
      rawValue == null || typeof rawValue !== "number" ||
      p10 == null || p20 == null || p80 == null || p90 == null
    ) return;

    const { zone, side } = classifyShadowZone(rawValue, p10, p20, p80, p90);
    metric_zones[key] = {
      zone,
      value: Math.round(rawValue * 100) / 100,
      p10:   Math.round(p10  * 100) / 100,
      p20:   Math.round(p20  * 100) / 100,
      p80:   Math.round(p80  * 100) / 100,
      p90:   Math.round(p90  * 100) / 100,
      side,
    };
  }

  // HRV — uses smoothed 7d rolling avg (mirrors production classifyDriverZone)
  classify(
    "hrv_7d",
    hrv7dAvg,
    percentiles.p10_hrv_7d,
    percentiles.p20_hrv_7d,
    percentiles.p80_hrv_7d,
    percentiles.p90_hrv_7d,
  );

  // Resting HR
  classify(
    "resting_hr",
    input.resting_hr_bpm,
    percentiles.p10_resting_hr,
    percentiles.p20_resting_hr,
    percentiles.p80_resting_hr,
    percentiles.p90_resting_hr,
  );

  // Sleep Duration
  classify(
    "sleep_duration",
    input.sleep_duration_hrs,
    percentiles.p10_sleep_duration,
    percentiles.p20_sleep_duration,
    percentiles.p80_sleep_duration,
    percentiles.p90_sleep_duration,
  );

  // Sleep Continuity
  classify(
    "sleep_continuity",
    input.sleep_continuity_pct,
    percentiles.p10_sleep_continuity,
    percentiles.p20_sleep_continuity,
    percentiles.p80_sleep_continuity,
    percentiles.p90_sleep_continuity,
  );

  // Steps — weekday/weekend p20/p80 split; combined p10/p90
  classify(
    "steps",
    input.steps,
    percentiles.p10_steps,
    weekend ? percentiles.p20_steps_weekend    : percentiles.p20_steps_weekday,
    weekend ? percentiles.p80_steps_weekend    : percentiles.p80_steps_weekday,
    percentiles.p90_steps,
  );

  // Active Minutes — weekday/weekend p20/p80 split; combined p10/p90
  classify(
    "active_minutes",
    input.active_minutes,
    percentiles.p10_active_minutes,
    weekend ? percentiles.p20_active_minutes_weekend    : percentiles.p20_active_minutes_weekday,
    weekend ? percentiles.p80_active_minutes_weekend    : percentiles.p80_active_minutes_weekday,
    percentiles.p90_active_minutes,
  );

  // No classifiable metrics today — nothing to write
  if (Object.keys(metric_zones).length === 0) return;

  await supabase
    .from("shadow_scoring_p1090")
    .upsert(
      {
        user_id:        userId,
        score_date:     date,
        domain_version: DOMAIN_VERSION,
        trust_state:    trustState,
        computed_at:    new Date().toISOString(),
        metric_zones,
        shadow_version: SHADOW_VERSION,
      },
      { onConflict: "user_id,score_date" },
    );
}

function getMetricValue(
  input: Record<string, unknown>,
  metric: string,
): number | null | undefined {
  const MAP: Record<string, string> = {
    hrv:              "hrv_ms",
    resting_hr:       "resting_hr_bpm",
    respiratory_rate: "respiratory_rate_rpm",
    sleep_duration:   "sleep_duration_hrs",
    sleep_continuity: "sleep_continuity_pct",
    steps:            "steps",
    active_minutes:   "active_minutes",
    distance:         "distance_km",
    spo2:             "spo2_pct",
    resting_energy:   "resting_energy",
    stand_hours:      "stand_hours",
  };
  const col = MAP[metric];
  if (!col) return null;
  const v = input[col];
  return typeof v === "number" ? v : null;
}