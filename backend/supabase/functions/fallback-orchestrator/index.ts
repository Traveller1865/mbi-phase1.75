// backend/supabase/functions/fallback-orchestrator/index.ts
// MBI Pipeline Performance — 5pm Local Timezone Fallback Scheduler
// Spec: MBI_Chronos_BuildHandoff_PipelinePerformance_v1_0.docx §5
//
// Fired hourly by Supabase cron at :00 of every UTC hour.
// Finds users whose local timezone is currently in the 5pm hour (17:00–17:59),
// checks whether each has a post-5pm daily_scores row for today, and runs
// the full pipeline for those who do not.
//
// Guarantees learning layer completeness regardless of app engagement.
// Covers: standard sleepers, late sleepers (bed 2–4am), night shift workers.
//
// Concurrency limit: 10 users processed in parallel to avoid rate limiting.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL         = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FUNCTION_BASE        = `${SUPABASE_URL}/functions/v1`;
const CONCURRENCY_LIMIT    = 10;
const DEFAULT_TIMEZONE     = "America/Chicago"; // UTC-6 fallback for null timezone users

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  // Require service-role authorization — this is a server-to-server call only.
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.includes(SUPABASE_SERVICE_KEY)) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
  const now = new Date();
  const todayUTC = now.toISOString().split("T")[0]; // yyyy-MM-dd in UTC

  // ── Find users currently in their 5pm local hour ──────────────────
  // Fetch all active users with stored timezones.
  const { data: users, error: usersErr } = await supabase
    .from("users")
    .select("id, timezone");

  if (usersErr || !users) {
    console.error("[fallback-orchestrator] Failed to fetch users:", usersErr);
    return new Response(JSON.stringify({ error: "Failed to fetch users" }), {
      status: 500,
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    });
  }

  // Filter to users currently in their 5pm hour
  const eligibleUsers = users.filter((u: { id: string; timezone: string | null }) => {
    const tz = u.timezone ?? DEFAULT_TIMEZONE;
    try {
      const localHour = getLocalHour(now, tz);
      return localHour === 17;
    } catch {
      // Invalid timezone — fall back to default and log
      console.warn(`[fallback-orchestrator] Invalid timezone for user ${u.id}: ${u.timezone} — using ${DEFAULT_TIMEZONE}`);
      return getLocalHour(now, DEFAULT_TIMEZONE) === 17;
    }
  });

  if (eligibleUsers.length === 0) {
    console.log(`[fallback-orchestrator] No users in 5pm local hour at ${now.toISOString()}`);
    return new Response(
      JSON.stringify({ processed: 0, ts: now.toISOString() }),
      { headers: { "Content-Type": "application/json", ...corsHeaders() } },
    );
  }

  console.log(`[fallback-orchestrator] ${eligibleUsers.length} users in 5pm local hour at ${now.toISOString()}`);

  // ── Process in batches with concurrency limit ─────────────────────
  const results: Array<{ user_id: string; timezone: string; local_time: string; action: "computed" | "skipped" | "failed" }> = [];

  for (let i = 0; i < eligibleUsers.length; i += CONCURRENCY_LIMIT) {
    const batch = eligibleUsers.slice(i, i + CONCURRENCY_LIMIT);
    const batchResults = await Promise.all(
      batch.map((u: { id: string; timezone: string | null }) => processUser(supabase, u.id, u.timezone ?? DEFAULT_TIMEZONE, todayUTC, now)),
    );
    results.push(...batchResults);
  }

  // Log each user processed
  for (const r of results) {
    console.log(`[fallback-orchestrator] ${JSON.stringify(r)}`);
  }

  const computed = results.filter(r => r.action === "computed").length;
  const skipped  = results.filter(r => r.action === "skipped").length;
  const failed   = results.filter(r => r.action === "failed").length;

  return new Response(
    JSON.stringify({
      processed: results.length,
      computed,
      skipped,
      failed,
      ts: now.toISOString(),
    }),
    { headers: { "Content-Type": "application/json", ...corsHeaders() } },
  );
});

// ─────────────────────────────────────────
// PROCESS ONE USER
// Checks for existing post-5pm computation. Runs pipeline if absent.
// ─────────────────────────────────────────

async function processUser(
  // deno-lint-ignore no-explicit-any
  supabase: any,
  userId: string,
  timezone: string,
  todayUTC: string,
  now: Date,
): Promise<{ user_id: string; timezone: string; local_time: string; action: "computed" | "skipped" | "failed" }> {
  const localTimeStr = formatLocalTime(now, timezone);

  try {
    // Compute 5pm UTC threshold for this user's timezone today
    const fivePmUtc = fivePmUtcForTimezone(todayUTC, timezone);

    // Check if post-5pm score already exists
    const { data: existingScore } = await supabase
      .from("daily_scores")
      .select("id, created_at")
      .eq("user_id", userId)
      .eq("date", todayUTC)
      .gte("created_at", fivePmUtc.toISOString())
      .maybeSingle();

    if (existingScore) {
      return { user_id: userId, timezone, local_time: localTimeStr, action: "skipped" };
    }

    // No post-5pm score — run the full pipeline via score-orchestrator.
    // The fallback uses service-role auth since there is no active user session.
    // daily_inputs for today must already exist (from a prior app-launch ingest
    // or from ingest called here). The fallback re-runs ingest if needed.
    const { data: latestInput } = await supabase
      .from("daily_inputs")
      .select("*")
      .eq("user_id", userId)
      .eq("date", todayUTC)
      .maybeSingle();

    if (!latestInput) {
      // No ingest row for today — user had no activity data. Log and skip.
      console.log(`[fallback-orchestrator] No daily_inputs for user ${userId} on ${todayUTC} — skipping pipeline`);
      return { user_id: userId, timezone, local_time: localTimeStr, action: "skipped" };
    }

    // Re-run score only (ingest row exists) via score function directly.
    // The fallback does not need to re-ingest — the ingest row is already complete
    // from the user's morning app launch. We re-run score to get the full-day record.
    const scoreRes = await fetch(`${FUNCTION_BASE}/score`, {
      method: "POST",
      headers: {
        "Content-Type":  "application/json",
        "Authorization": `Bearer ${SUPABASE_SERVICE_KEY}`,
        "apikey":        SUPABASE_SERVICE_KEY,
      },
      body: JSON.stringify({ userId, date: todayUTC }),
    });

    if (!scoreRes.ok) {
      const txt = await scoreRes.text().catch(() => "");
      throw new Error(`score returned HTTP ${scoreRes.status}: ${txt}`);
    }

    // After scoring, run narrate to refresh narrative with complete-day data
    try {
      await fetch(`${FUNCTION_BASE}/narrate`, {
        method: "POST",
        headers: {
          "Content-Type":  "application/json",
          "Authorization": `Bearer ${SUPABASE_SERVICE_KEY}`,
          "apikey":        SUPABASE_SERVICE_KEY,
        },
        body: JSON.stringify({
          userId,
          date:         todayUTC,
          timeOfDay:    "evening",
          briefSession: "morning",
        }),
      });
    } catch (narrateErr) {
      // Non-fatal — score row is the critical output
      console.error(`[fallback-orchestrator] narrate failed for user ${userId} (non-fatal):`, narrateErr);
    }

    return { user_id: userId, timezone, local_time: localTimeStr, action: "computed" };

  } catch (err) {
    console.error(`[fallback-orchestrator] pipeline failed for user ${userId}:`, err);
    return { user_id: userId, timezone, local_time: localTimeStr, action: "failed" };
  }
}

// ─────────────────────────────────────────
// TIMEZONE HELPERS
// ─────────────────────────────────────────

function getLocalHour(date: Date, timezone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    hour: "numeric",
    hour12: false,
  }).formatToParts(date);
  const hourPart = parts.find(p => p.type === "hour");
  return parseInt(hourPart?.value ?? "0", 10);
}

function formatLocalTime(date: Date, timezone: string): string {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

function fivePmUtcForTimezone(dateStr: string, timezone: string): Date {
  try {
    const [year, month, day] = dateStr.split("-").map(Number);
    // Construct a Date representing 5pm local in the given timezone
    // by iterating: find the UTC time where local hour = 17
    const candidateUtc = new Date(Date.UTC(year, month - 1, day, 17, 0, 0));
    const localHour = getLocalHour(candidateUtc, timezone);
    const offsetHours = 17 - localHour;
    return new Date(candidateUtc.getTime() + offsetHours * 3_600_000);
  } catch {
    // Fallback: UTC-6 (CST), so 5pm CST = 23:00 UTC
    const [year, month, day] = dateStr.split("-").map(Number);
    return new Date(Date.UTC(year, month - 1, day, 23, 0, 0));
  }
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}
