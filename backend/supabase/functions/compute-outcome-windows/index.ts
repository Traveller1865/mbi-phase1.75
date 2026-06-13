// backend/supabase/functions/compute-outcome-windows/index.ts
// Learning Foundation v1.0 — Outcome Windows Cron Job
// Phase: Phase 2 Sprint 2 (full implementation deferred per handoff)
//
// Purpose: For each nudge_event, compute the delta between the user's
// Chronos score and key metrics at T+1 day and T+7 days after the nudge.
// Separates engagement signal (did user tap it?) from effectiveness signal
// (did anything improve?). This is the table that makes nudge policy
// improvement possible.
//
// Schedule: Run daily at 06:00 UTC via Supabase cron scheduler.
//   supabase functions schedule compute-outcome-windows --cron "0 6 * * *"
//
// Status: Scaffold only. Activated in Phase 2 Sprint 2 once narrate logging
// is confirmed producing clean nudge_event rows with stable data.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL         = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (_req) => {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
    const now      = new Date();

    const results = await Promise.all([
      processWindow(supabase, now, "next_day", 1),
      processWindow(supabase, now, "7_day",    7),
    ]);

    const total = results.reduce((a, b) => a + b, 0);
    console.log(`[compute-outcome-windows] processed ${total} rows`);

    return new Response(JSON.stringify({ success: true, rows_processed: total }), {
      headers: { "Content-Type": "application/json" },
    });

  } catch (err) {
    console.error("[compute-outcome-windows]", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});

// ─────────────────────────────────────────
// PROCESS ONE WINDOW TYPE
// ─────────────────────────────────────────

// deno-lint-ignore no-explicit-any
async function processWindow(supabase: any, now: Date, windowType: string, daysOffset: number): Promise<number> {
  // Target: nudge_events where shown_at falls in the window [daysOffset, daysOffset+1) days ago
  const windowEnd   = new Date(now);
  windowEnd.setUTCDate(windowEnd.getUTCDate() - daysOffset);
  const windowStart = new Date(windowEnd);
  windowStart.setUTCDate(windowStart.getUTCDate() - 1);

  // Fetch nudge events in the target window with no existing outcome row
  const { data: pendingEvents, error: fetchErr } = await supabase
    .from("nudge_events")
    .select("id, user_id, date, chronos_score, d1_autonomic, d2_sleep, d3_activity")
    .gte("shown_at", windowStart.toISOString())
    .lt("shown_at",  windowEnd.toISOString());

  if (fetchErr || !pendingEvents?.length) return 0;

  // Filter out events that already have an outcome_windows row for this window type
  const { data: existingOutcomes } = await supabase
    .from("outcome_windows")
    .select("nudge_event_id")
    .in("nudge_event_id", pendingEvents.map((e: { id: string }) => e.id))
    .eq("outcome_window", windowType);

  const existingIds = new Set((existingOutcomes ?? []).map((r: { nudge_event_id: string }) => r.nudge_event_id));
  const toProcess   = pendingEvents.filter((e: { id: string }) => !existingIds.has(e.id));

  if (toProcess.length === 0) return 0;

  let processed = 0;

  for (const event of toProcess) {
    try {
      // Calculate outcome date: nudge date + daysOffset
      const nudgeDate   = new Date(event.date);
      nudgeDate.setUTCDate(nudgeDate.getUTCDate() + daysOffset);
      const outcomeDate = nudgeDate.toISOString().split("T")[0];

      // Fetch the daily_score for the outcome date
      const { data: outcomeScore } = await supabase
        .from("daily_scores")
        .select("chronos_score, d1_autonomic, d2_sleep, d3_activity")
        .eq("user_id", event.user_id)
        .eq("date",    outcomeDate)
        .single();

      if (!outcomeScore) continue; // outcome day not yet scored

      // Fetch metric deltas from daily_inputs for the outcome date
      const { data: outcomeInput } = await supabase
        .from("daily_inputs")
        .select("hrv_ms, resting_hr_bpm, sleep_duration_hrs")
        .eq("user_id", event.user_id)
        .eq("date",    outcomeDate)
        .single();

      const { data: nudgeInput } = await supabase
        .from("daily_inputs")
        .select("hrv_ms, resting_hr_bpm, sleep_duration_hrs")
        .eq("user_id", event.user_id)
        .eq("date",    event.date)
        .single();

      const delta = (a: number | null, b: number | null) =>
        a != null && b != null ? a - b : null;

      await supabase.from("outcome_windows").insert({
        user_id:              event.user_id,
        nudge_event_id:       event.id,
        outcome_window:       windowType,
        chronos_score_delta:  delta(outcomeScore.chronos_score,  event.chronos_score),
        d1_delta:             delta(outcomeScore.d1_autonomic,   event.d1_autonomic),
        d2_delta:             delta(outcomeScore.d2_sleep,       event.d2_sleep),
        d3_delta:             delta(outcomeScore.d3_activity,    event.d3_activity),
        hrv_delta:            delta(outcomeInput?.hrv_ms,        nudgeInput?.hrv_ms),
        resting_hr_delta:     delta(outcomeInput?.resting_hr_bpm, nudgeInput?.resting_hr_bpm),
        sleep_duration_delta: delta(outcomeInput?.sleep_duration_hrs, nudgeInput?.sleep_duration_hrs),
        computed_at:          new Date().toISOString(),
      });

      processed++;
    } catch (rowErr) {
      console.error(`[compute-outcome-windows] row ${event.id} failed:`, rowErr);
    }
  }

  return processed;
}
