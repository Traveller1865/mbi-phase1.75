// backend/supabase/functions/score-orchestrator/index.ts
// MBI Pipeline Performance — On-Demand Orchestrated Pipeline
// Spec: MBI_Chronos_BuildHandoff_PipelinePerformance_v1_0.docx §4
//
// Single entry point for the full Chronos pipeline.
// iOS client makes ONE call here; all pipeline steps run server-side.
// Each step is wrapped in try/catch — a step failure is logged and the
// pipeline continues. Critical failures (steps 1–3) return HTTP 500.
//
// Pipeline sequence:
//   1. ingest         — canonicalize HealthKit payload → daily_inputs
//   2. score          — compute domain scores + CRS → daily_scores
//   3. (shadow)       — p10/p90 shadow zones (internal to score, not a step here)
//   4. narrate        — Today tab narrative → explanations
//   5. narrate-trend  — Trend tab narrative → trend_narratives
//   6. narrate-domains-pattern — Domains tab → domain_narratives
//   STUB: ontology-classify   — Phase 1.75, not yet active
//   STUB: narrate-horizon     — Phase 1.75, not yet active
//
// Idempotency guard: if a post-5pm-local daily_scores row already exists
// for today, return { cached: true } without re-running the pipeline.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FUNCTION_BASE     = `${SUPABASE_URL}/functions/v1`;

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  try {
    const body = await req.json();
    const { userId, date, payload, timezone } = body as {
      userId:    string;
      date:      string;
      payload:   Record<string, unknown>;
      timezone?: string;
    };

    if (!userId || !date || !payload) {
      return new Response(
        JSON.stringify({ error: "userId, date, and payload are required" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() } },
      );
    }

    // ── Auth: caller must own the userId ─────────────────────────────
    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

    // ── Idempotency guard ─────────────────────────────────────────────
    // If a row for today was computed at or after 5pm in the user's local
    // timezone, the 5pm fallback has already run — return cached.
    const fivePmUtc = fivePmUtcForTimezone(date, timezone ?? "America/Chicago");
    const { data: existingScore } = await supabase
      .from("daily_scores")
      .select("chronos_score, created_at")
      .eq("user_id", userId)
      .eq("date", date)
      .gte("created_at", fivePmUtc.toISOString())
      .maybeSingle();

    if (existingScore) {
      return new Response(
        JSON.stringify({
          computed:   false,
          cached:     true,
          score_date: date,
          crs:        existingScore.chronos_score,
        }),
        { headers: { "Content-Type": "application/json", ...corsHeaders() } },
      );
    }

    // ── Persist timezone if provided ─────────────────────────────────
    if (timezone) {
      supabase
        .from("users")
        .update({ timezone })
        .eq("id", userId)
        .then(() => {/* fire-and-forget */});
    }

    const warnings: string[] = [];
    const serviceHeaders = {
      "Content-Type":  "application/json",
      "Authorization": `Bearer ${SUPABASE_SERVICE_KEY}`,
      "apikey":        SUPABASE_SERVICE_KEY,
    };

    // ── Helper: call a downstream Edge Function ───────────────────────
    async function callStep(
      name: string,
      path: string,
      stepBody: Record<string, unknown>,
    ): Promise<Record<string, unknown>> {
      const res = await fetch(`${FUNCTION_BASE}/${path}`, {
        method:  "POST",
        headers: serviceHeaders,
        body:    JSON.stringify(stepBody),
      });
      if (!res.ok) {
        const txt = await res.text().catch(() => "");
        throw new Error(`${name} returned HTTP ${res.status}: ${txt}`);
      }
      return res.json().catch(() => ({}));
    }

    // ── STEP 1: ingest ────────────────────────────────────────────────
    // Critical — throws on failure, returns HTTP 500
    await callStep("ingest", "ingest", { payload });

    // ── STEP 2: score ─────────────────────────────────────────────────
    // Critical — throws on failure, returns HTTP 500
    // Shadow layer (OI-004) runs inside score automatically.
    const scoreResult = await callStep("score", "score", { userId, date });

    // Extract CRS for the response — may be null if baseline still building
    const crs = (scoreResult as Record<string, Record<string, unknown>>).score?.chronos_score ?? null;

    // ── STEP 4b: ontology-classify (OI-008 / Phase 1.75) ─────────────
    // Runs after daily_scores write and shadow scoring.
    // Evaluates 12 activation rules + 3 pathway classifications.
    // Non-fatal — orchestrator continues on any error.
    try {
      const ontologyRes = await fetch(`${FUNCTION_BASE}/ontology-classify`, {
        method:  "POST",
        headers: serviceHeaders,
        body:    JSON.stringify({ user_id: userId, date }),
      });
      const ontologyData = ontologyRes.ok ? await ontologyRes.json().catch(() => ({})) : {};
      if (ontologyData.skipped) {
        console.log(`[score-orchestrator] ontology-classify skipped: ${ontologyData.reason ?? "unknown"}`);
      } else if (!ontologyRes.ok) {
        warnings.push(`ontology-classify: HTTP ${ontologyRes.status}`);
        console.error(`[score-orchestrator] ontology-classify returned HTTP ${ontologyRes.status}`);
      }
    } catch (e) {
      warnings.push(`ontology-classify: ${String(e)}`);
      console.error("[score-orchestrator] ontology-classify failed (non-fatal):", e);
    }

    // ── STEP 4: narrate (Today tab) ───────────────────────────────────
    // Non-critical — failure logged in warnings
    try {
      await callStep("narrate", "narrate", {
        userId,
        date,
        timeOfDay:    currentTimeOfDay(),
        briefSession: "morning",
      });
    } catch (e) {
      warnings.push(`narrate: ${String(e)}`);
      console.error("[score-orchestrator] narrate failed (non-fatal):", e);
    }

    // ── STEP 5: narrate-trend ─────────────────────────────────────────
    // Requires trend_aggregates row for the current week (written by score).
    // Non-critical.
    try {
      const trendInput = await buildTrendNarrativeInput(supabase, userId, date);
      if (trendInput) {
        await callStep("narrate-trend", "narrate-trend", {
          userId,
          ...trendInput,
        });
      }
    } catch (e) {
      warnings.push(`narrate-trend: failed, retrying next sync`);
      console.error("[score-orchestrator] narrate-trend failed (non-fatal):", e);
    }

    // ── STEP 6: narrate-domains-pattern ──────────────────────────────
    // Non-critical.
    try {
      const domainInput = await buildDomainPatternInput(supabase, userId, date);
      if (domainInput) {
        await callStep("narrate-domains-pattern", "narrate-domains-pattern", {
          userId,
          ...domainInput,
        });
      }
    } catch (e) {
      warnings.push(`narrate-domains-pattern: failed, retrying next sync`);
      console.error("[score-orchestrator] narrate-domains-pattern failed (non-fatal):", e);
    }

    // ── STUB: narrate-horizon (Phase 1.75 — not yet active) ──────────
    try {
      console.log("[score-orchestrator] narrate-horizon: reserved, not yet active");
    } catch (_) { /* never throws */ }

    // ── STEP 10: Return ───────────────────────────────────────────────
    return new Response(
      JSON.stringify({
        computed:   true,
        cached:     false,
        score_date: date,
        crs,
        ...(warnings.length > 0 ? { warnings } : {}),
      }),
      { headers: { "Content-Type": "application/json", ...corsHeaders() } },
    );

  } catch (err) {
    // Critical failure (steps 1–3)
    console.error("[score-orchestrator] critical failure:", err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders() } },
    );
  }
});

// ─────────────────────────────────────────
// IDEMPOTENCY HELPER
// Returns the UTC instant corresponding to 5pm in the given IANA timezone
// on the given date string. Falls back to UTC-6 if timezone is invalid.
// ─────────────────────────────────────────

function fivePmUtcForTimezone(dateStr: string, timezone: string): Date {
  try {
    // Build a wall-clock 5pm in the user's timezone, convert to UTC
    const fmt = new Intl.DateTimeFormat("en-US", {
      timeZone: timezone,
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
      hour12: false,
    });
    // Parse dateStr as local date in timezone
    const [year, month, day] = dateStr.split("-").map(Number);
    // Construct 5pm local time by working out the UTC equivalent
    // Use the Intl API to find the UTC offset at 5pm on this date
    const fivePmLocal = new Date(Date.UTC(year, month - 1, day, 17, 0, 0));
    // Get the offset by formatting a known UTC time in the target timezone
    const parts = fmt.formatToParts(fivePmLocal);
    const p: Record<string, string> = {};
    for (const { type, value } of parts) p[type] = value;
    const localHour = parseInt(p.hour ?? "17");
    const offsetHours = 17 - localHour;
    return new Date(fivePmLocal.getTime() + offsetHours * 3_600_000);
  } catch {
    // Fallback: UTC-6 (CST)
    const [year, month, day] = dateStr.split("-").map(Number);
    return new Date(Date.UTC(year, month - 1, day, 23, 0, 0)); // 5pm CST = 23:00 UTC
  }
}

function currentTimeOfDay(): string {
  const hour = new Date().getUTCHours();
  if (hour >= 17) return "evening";
  if (hour >= 12) return "daytime";
  return "morning";
}

// ─────────────────────────────────────────
// NARRATE-TREND INPUT BUILDER
// Queries trend_aggregates for the current ISO week.
// Returns null if no aggregate row is available yet.
// ─────────────────────────────────────────

// deno-lint-ignore no-explicit-any
async function buildTrendNarrativeInput(supabase: any, userId: string, date: string): Promise<Record<string, unknown> | null> {
  const { data: row } = await supabase
    .from("trend_aggregates")
    .select("*")
    .eq("user_id", userId)
    .eq("window_type", "weekly")
    .lte("window_start", date)
    .gte("window_end", date)
    .maybeSingle();

  if (!row || row.chronos_avg == null) return null;

  const topDrivers = [row.top_driver_1, row.top_driver_2].filter(Boolean);
  return {
    window_type:     "weekly",
    window_start:    row.window_start,
    window_end:      row.window_end,
    chronos_avg:     row.chronos_avg,
    chronos_min:     row.chronos_min,
    chronos_max:     row.chronos_max,
    trend_direction: row.trend_direction ?? "stable",
    top_drivers:     topDrivers,
    days_in_window:  row.days_in_window ?? 1,
  };
}

// ─────────────────────────────────────────
// NARRATE-DOMAINS-PATTERN INPUT BUILDER
// Queries the most recent daily_scores for pattern and driver context.
// Returns null if no score row is available.
// ─────────────────────────────────────────

// deno-lint-ignore no-explicit-any
async function buildDomainPatternInput(supabase: any, userId: string, date: string): Promise<Record<string, unknown> | null> {
  const { data: row } = await supabase
    .from("daily_scores")
    .select("driver_1, driver_2, d1_autonomic, d2_sleep, d3_activity, d4_stress, d5_allostatic, score_band")
    .eq("user_id", userId)
    .eq("date", date)
    .maybeSingle();

  if (!row || !row.driver_1) return null;

  // Determine the most prominent domain from the top driver
  const driverDomainMap: Record<string, string> = {
    hrv:              "d1_autonomic",
    resting_hr:       "d1_autonomic",
    respiratory_rate: "d1_autonomic",
    sleep_duration:   "d2_sleep",
    sleep_continuity: "d2_sleep",
    steps:            "d3_activity",
    active_minutes:   "d3_activity",
    stand_hours:      "d3_activity",
    spo2:             "d1_autonomic",
  };

  const driver_domain = driverDomainMap[row.driver_1] ?? "d1_autonomic";

  // Classify pattern type from score_band
  const patternMap: Record<string, string> = {
    Thriving:   "thriving",
    Recovering: "recovering",
    Yellowline: "trending_down",
    Drifting:   "trending_down",
    Redline:    "at_risk",
  };
  const pattern_type = patternMap[row.score_band] ?? "recovering";

  return {
    pattern_type,
    driver_domain,
    domain_scores: {
      d1_autonomic:  row.d1_autonomic,
      d2_sleep:      row.d2_sleep,
      d3_activity:   row.d3_activity,
      d4_stress:     row.d4_stress,
      d5_allostatic: row.d5_allostatic,
    },
  };
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}
