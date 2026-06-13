// backend/supabase/functions/narrate-detail/index.ts
// MBI Phase 1.5 — Step 9b: Full 7-day system narrative
// Generates a pattern-level interpretation across all five domains for the past week.
// Output: explanations.detail_explanation_text + detail_generated_at
// Prompt Version: 1.0

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const SUPABASE_URL       = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY  = Deno.env.get("ANTHROPIC_API_KEY")!;

const MODEL         = "claude-sonnet-4-6";
const DETAIL_VERSION = "1.0";

// ─────────────────────────────────────────
// MATH HELPERS
// ─────────────────────────────────────────

function mean(values: number[]): number {
  if (values.length === 0) return 0;
  return values.reduce((s, v) => s + v, 0) / values.length;
}

function stdDev(values: number[]): number {
  if (values.length < 2) return 0;
  const m = mean(values);
  const variance = values.reduce((s, v) => s + Math.pow(v - m, 2), 0) / values.length;
  return Math.sqrt(variance);
}

// Linear regression slope over an array; null values are skipped.
function linearSlope(values: (number | null)[]): { slope: number; sd: number; count: number } {
  const pairs = values
    .map((v, i) => [i, v] as [number, number | null])
    .filter((p): p is [number, number] => p[1] !== null);

  if (pairs.length < 2) return { slope: 0, sd: 0, count: pairs.length };

  const n     = pairs.length;
  const sumX  = pairs.reduce((s, [x]) => s + x, 0);
  const sumY  = pairs.reduce((s, [, y]) => s + y, 0);
  const sumXY = pairs.reduce((s, [x, y]) => s + x * y, 0);
  const sumX2 = pairs.reduce((s, [x]) => s + x * x, 0);
  const denom = n * sumX2 - sumX * sumX;
  const slope = denom === 0 ? 0 : (n * sumXY - sumX * sumY) / denom;

  const vals = pairs.map(([, y]) => y);
  return { slope, sd: stdDev(vals), count: n };
}

type TrendDir = "improving" | "declining" | "stable" | "volatile";

function trendDirection(values: (number | null)[]): TrendDir {
  const { slope, sd, count } = linearSlope(values);
  if (count < 2)   return "stable";
  if (sd > 8)      return "volatile";
  if (slope > 0.5) return "improving";
  if (slope < -0.5) return "declining";
  return "stable";
}

function dateMinusDays(dateStr: string, days: number): string {
  const d = new Date(dateStr + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().slice(0, 10);
}

function dayOfWeek(dateStr: string): string {
  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  return days[new Date(dateStr + "T00:00:00Z").getUTCDay()];
}

// ─────────────────────────────────────────
// SIGNAL KEYS
// ─────────────────────────────────────────

const SIGNAL_KEYS = ["d1_autonomic", "d2_sleep", "d3_activity", "d4_stress", "d5_allostatic"] as const;
type SignalKey = typeof SIGNAL_KEYS[number];

const SIGNAL_LABELS: Record<SignalKey, string> = {
  d1_autonomic:  "Autonomic (d1)",
  d2_sleep:      "Sleep (d2)",
  d3_activity:   "Activity (d3)",
  d4_stress:     "Stress (d4)",
  d5_allostatic: "Body Load (d5)",
};

// ─────────────────────────────────────────
// PROMPT BUILDER
// ─────────────────────────────────────────

interface DetailPromptInput {
  date: string;
  todayScore: Record<string, unknown>;
  cardBrief: string | null;
  sevenDayRows: Record<string, unknown>[];
  signalTrends: Record<SignalKey, { direction: TrendDir; magnitude: number; daysAvailable: number }>;
  scoreTrajectory: { scores: (number | null)[]; direction: TrendDir; min: number; max: number };
  baselineDeviations: Record<SignalKey, number | null>;
  dataQuality: { cleanDays: number; flaggedDays: number; affectedSignals: string[] };
  historyMaturity: "forming" | "developing" | "established";
  historyDays: number;
}

const SYSTEM_PROMPT = `You are the intelligence layer of Chronos, a precision health system built by MBI — Mynd & Bodi Institute. Your role in this function is to produce a full system narrative — a 7-day pattern interpretation that helps the user understand what their body has been communicating across all five domains: autonomic (HRV), sleep, activity, stress, and allostatic load.

This narrative is shown when the user taps into their morning brief for deeper context. It must do something the Today tab card cannot: explain the relationship between signals, the direction of the user's system over the past week, and the practical implication for the next 24 to 72 hours.

RULES — follow all of these without exception:

STRUCTURE: Produce exactly five sections in this order. Use these exact section labels:

  System State
  What Chronos Is Noticing
  Why It Matters
  What To Watch Next
  System Recommendation

SYSTEM STATE:
  One sentence. A plain-English characterization of the user's overall system right now. Do not open with a score number. Do not reference a band name (Good, Fair, Optimal, etc.). Do not repeat the opening language of the card brief you are given as context.

WHAT CHRONOS IS NOTICING:
  Two to three sentences. Describe the 7-day pattern across signals. Focus on relationships between signals — what is moving together, what is diverging, what is the dominant pattern. Do not list metrics as a report. Do not write: "Sleep: 5h 9m. HRV: 35ms." Write interpretation, not data.

WHY IT MATTERS:
  Two to three sentences. Explain the practical consequence of this pattern for the user's capacity — cognitive, physical, emotional. Frame it constructively. Do not catastrophize.

WHAT TO WATCH NEXT:
  Two to three sentences. Tell the user which signal or pattern to watch over the coming days and what a positive or negative shift would look like. Be specific enough to be useful.

SYSTEM RECOMMENDATION:
  Two to three sentences. A system-level recommendation for the next 24 to 72 hours. Not a single metric nudge — that belongs in the Today's Focus card. This is a strategic posture recommendation.

ADDITIONAL RULES:
  - No em dashes
  - No bullet points or numbered lists
  - No score numbers in the output
  - No band state references anywhere in the output
  - No metric readouts ("HRV: 42ms", "5h 9m of sleep") — interpretation only
  - Do not repeat phrases, sentences, or ideas from the card brief text you are given as context
  - If data quality is imperfect (flagged, corrected, provisional signals in the window), include one sentence in What Chronos Is Noticing acknowledging that Chronos is reading the pattern with appropriate caution — do not omit this, do not place it elsewhere
  - If baseline maturity is 'forming', soften directional language throughout — use 'appears', 'suggests', 'early indication' rather than definitive statements
  - If baseline maturity is 'established', write with appropriate confidence`;

function buildDetailUserMessage(input: DetailPromptInput): string {
  const { date, todayScore, cardBrief, sevenDayRows, signalTrends,
          scoreTrajectory, baselineDeviations, dataQuality,
          historyMaturity, historyDays } = input;

  const scoreLines = sevenDayRows.map((row) => {
    const s = row["chronos_score"] != null
      ? String(Math.round(row["chronos_score"] as number))
      : "missing";
    return `  ${row["date"]}: ${s}`;
  }).join("\n");

  const trendLines = SIGNAL_KEYS.map((k) => {
    const t = signalTrends[k];
    return `  ${SIGNAL_LABELS[k]}: ${t.direction}, magnitude ${t.magnitude.toFixed(1)}, ${t.daysAvailable}/7 days available`;
  }).join("\n");

  const deviationLines = SIGNAL_KEYS.map((k) => {
    const z = baselineDeviations[k];
    return `  ${SIGNAL_LABELS[k]}: ${z !== null ? z.toFixed(2) : "insufficient history"}`;
  }).join("\n");

  const affectedStr = dataQuality.affectedSignals.length > 0
    ? dataQuality.affectedSignals.join(", ")
    : "none";

  const s = todayScore;

  return `TODAY: ${date}, ${dayOfWeek(date)}

CARD BRIEF (do not repeat this language):
${cardBrief ?? "No brief available for today."}

TODAY'S SCORES:
  Overall: ${s["chronos_score"] ?? "unavailable"}
  Autonomic (d1): ${s["d1_autonomic"] ?? "unavailable"}
  Sleep (d2): ${s["d2_sleep"] ?? "unavailable"}
  Activity (d3): ${s["d3_activity"] ?? "unavailable"}
  Stress (d4): ${s["d4_stress"] ?? "unavailable"}
  Body Load (d5): ${s["d5_allostatic"] ?? "unavailable"}
  Confidence tier: ${s["confidence_tier"] ?? "unavailable"}
  Range trust: ${s["range_trust_state"] ?? "unavailable"}
  Provisional: ${s["is_provisional"] ?? false}

7-DAY SCORE TRAJECTORY:
${scoreLines}
  Overall direction: ${scoreTrajectory.direction}
  Score range this week: ${scoreTrajectory.min} to ${scoreTrajectory.max}

SIGNAL TRENDS (7-day):
${trendLines}

BASELINE DEVIATION (today vs. 30-day rolling mean):
${deviationLines}

DATA QUALITY (past 7 days):
  Clean days: ${dataQuality.cleanDays}
  Flagged days: ${dataQuality.flaggedDays}
  Affected signals: ${affectedStr}

BASELINE MATURITY: ${historyMaturity}
  (${historyDays} days of history)`;
}

// ─────────────────────────────────────────
// HANDLER
// ─────────────────────────────────────────

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

    const { user_id: userId, date } = await req.json();
    if (!userId || !date) {
      return new Response(JSON.stringify({ success: false, error: "user_id and date required" }), {
        status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // ── Auth ─────────────────────────────────────────────────────────
    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    // ── Cache check: skip Claude if detail written within last 23 hours ──
    const { data: existingExpl } = await supabase
      .from("explanations")
      .select("detail_explanation_text, detail_generated_at")
      .eq("user_id", userId)
      .eq("date", date)
      .single();

    if (existingExpl?.detail_explanation_text && existingExpl?.detail_generated_at) {
      const generatedAt = new Date(existingExpl.detail_generated_at as string);
      const ageHours = (Date.now() - generatedAt.getTime()) / 3_600_000;
      if (ageHours < 23) {
        return new Response(JSON.stringify({ success: true, date, cached: true }), {
          headers: { "Content-Type": "application/json", ...corsHeaders() },
        });
      }
    }

    // ── Date bounds ───────────────────────────────────────────────────
    const windowStart   = dateMinusDays(date, 6);   // 7-day window start
    const baselineStart = dateMinusDays(date, 29);  // 30-day rolling baseline start
    const baselineEnd   = dateMinusDays(date, 7);   // baseline ends before 7-day window

    // ── Fetch in parallel ─────────────────────────────────────────────
    const [
      { data: todayScore },
      { data: todayExpl },
      { data: sevenDayRows },
      { data: corrections },
      { data: baselineRows },
      { count: historyCount },
    ] = await Promise.all([
      supabase
        .from("daily_scores")
        .select("id,chronos_score,score_band,confidence_tier,range_trust_state,is_provisional,fail_state,d1_autonomic,d2_sleep,d3_activity,d4_stress,d5_allostatic,driver_1,driver_2,created_at")
        .eq("user_id", userId)
        .eq("date", date)
        .single(),

      supabase
        .from("explanations")
        .select("explanation_text")
        .eq("user_id", userId)
        .eq("date", date)
        .single(),

      supabase
        .from("daily_scores")
        .select("date,chronos_score,d1_autonomic,d2_sleep,d3_activity,d4_stress,d5_allostatic,is_provisional,fail_state,confidence_tier")
        .eq("user_id", userId)
        .gte("date", windowStart)
        .lte("date", date)
        .order("date", { ascending: true }),

      supabase
        .from("score_corrections")
        .select("date,signal_name,correction_type,is_applied,dismissed")
        .eq("user_id", userId)
        .gte("date", windowStart)
        .lte("date", date),

      supabase
        .from("daily_scores")
        .select("d1_autonomic,d2_sleep,d3_activity,d4_stress,d5_allostatic")
        .eq("user_id", userId)
        .gte("date", baselineStart)
        .lt("date", baselineEnd),

      supabase
        .from("daily_scores")
        .select("id", { count: "exact", head: true })
        .eq("user_id", userId)
        .lte("date", date),
    ]);

    if (!todayScore) {
      return new Response(JSON.stringify({ success: false, error: "Score not found for this date" }), {
        status: 404, headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    const rows7  = (sevenDayRows  ?? []) as Record<string, unknown>[];
    const bRows  = (baselineRows  ?? []) as Record<string, unknown>[];
    const corrs  = (corrections   ?? []) as Record<string, unknown>[];
    const days7  = rows7.length;
    const historyDays = historyCount ?? 0;

    // ── Baseline mean/SD per signal ───────────────────────────────────
    const baselineSummary: Record<SignalKey, { mean: number; sd: number; count: number }> = {} as never;
    for (const k of SIGNAL_KEYS) {
      const vals = bRows
        .map((r) => r[k] as number | null)
        .filter((v): v is number => v !== null);
      baselineSummary[k] = { mean: mean(vals), sd: stdDev(vals), count: vals.length };
    }

    // ── Per-signal trend (7-day) ──────────────────────────────────────
    const signalTrends = {} as DetailPromptInput["signalTrends"];
    for (const k of SIGNAL_KEYS) {
      const vals = rows7.map((r) => r[k] as number | null);
      const nonNull = vals.filter((v): v is number => v !== null);
      const dir  = trendDirection(vals);
      const mag  = nonNull.length >= 2 ? Math.abs(nonNull[nonNull.length - 1] - nonNull[0]) : 0;
      signalTrends[k] = { direction: dir, magnitude: mag, daysAvailable: nonNull.length };
    }

    // ── Score trajectory ──────────────────────────────────────────────
    const scoreVals = rows7.map((r) => r["chronos_score"] as number | null);
    const nonNullScores = scoreVals.filter((v): v is number => v !== null);
    const scoreTrajectory: DetailPromptInput["scoreTrajectory"] = {
      scores: scoreVals,
      direction: trendDirection(scoreVals),
      min: nonNullScores.length > 0 ? Math.round(Math.min(...nonNullScores)) : 0,
      max: nonNullScores.length > 0 ? Math.round(Math.max(...nonNullScores)) : 0,
    };

    // ── Baseline Z-scores for today ───────────────────────────────────
    const baselineDeviations = {} as DetailPromptInput["baselineDeviations"];
    for (const k of SIGNAL_KEYS) {
      const todayVal = (todayScore as Record<string, unknown>)[k] as number | null;
      const b = baselineSummary[k];
      if (todayVal !== null && b.count >= 7 && b.sd > 0) {
        baselineDeviations[k] = (todayVal - b.mean) / b.sd;
      } else {
        baselineDeviations[k] = null;
      }
    }

    // ── Data quality map ──────────────────────────────────────────────
    // A day is "flagged" if it has any null signal, provisional, fail_state, or correction
    const corrDates = new Set(corrs.map((c) => c["date"] as string));
    let flaggedDays = 0;
    const affectedSignalSet = new Set<string>();

    for (const row of rows7) {
      let dayFlagged = false;

      // null signals
      for (const k of SIGNAL_KEYS) {
        if (row[k] == null) {
          dayFlagged = true;
          affectedSignalSet.add(k);
        }
      }
      // provisional or fail_state
      if (row["is_provisional"] || row["fail_state"]) dayFlagged = true;
      // corrections
      if (corrDates.has(row["date"] as string)) dayFlagged = true;

      if (dayFlagged) flaggedDays++;
    }

    // Corrected signals
    corrs.forEach((c) => affectedSignalSet.add(c["signal_name"] as string));

    const dataQuality: DetailPromptInput["dataQuality"] = {
      cleanDays: days7 - flaggedDays,
      flaggedDays,
      affectedSignals: Array.from(affectedSignalSet),
    };

    // ── History maturity ──────────────────────────────────────────────
    const historyMaturity: "forming" | "developing" | "established" =
      historyDays < 14  ? "forming"
      : historyDays < 30 ? "developing"
      : "established";

    // ── Build prompt ──────────────────────────────────────────────────
    const userMessage = buildDetailUserMessage({
      date,
      todayScore:       todayScore as Record<string, unknown>,
      cardBrief:        (todayExpl as Record<string, unknown> | null)?.["explanation_text"] as string | null ?? null,
      sevenDayRows:     rows7,
      signalTrends,
      scoreTrajectory,
      baselineDeviations,
      dataQuality,
      historyMaturity,
      historyDays,
    });

    // ── Call Claude API ───────────────────────────────────────────────
    const claudeRes = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1000,
        system: SYSTEM_PROMPT,
        messages: [{ role: "user", content: userMessage }],
      }),
    });

    if (!claudeRes.ok) {
      const err = await claudeRes.text();
      console.error("[narrate-detail] Claude API error:", err);
      return new Response(JSON.stringify({ success: false, error: `Claude API error: ${err}` }), {
        status: 500, headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    const claudeData = await claudeRes.json();
    const detailText: string = claudeData.content?.[0]?.text ?? "";

    if (!detailText) {
      return new Response(JSON.stringify({ success: false, error: "Empty response from Claude" }), {
        status: 500, headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // ── Upsert to explanations ────────────────────────────────────────
    const now = new Date().toISOString();
    const { error: saveErr } = await supabase
      .from("explanations")
      .upsert(
        {
          score_id:                (todayScore as Record<string, unknown>)["id"] ?? null,
          user_id:                 userId,
          date,
          detail_explanation_text: detailText,
          detail_generated_at:     now,
          // preserve required columns if row is new
          prompt_version:          DETAIL_VERSION,
          model_version:           MODEL,
        },
        { onConflict: "score_id" }
      );

    if (saveErr) {
      console.error("[narrate-detail] upsert error:", saveErr);
      return new Response(JSON.stringify({ success: false, error: saveErr.message }), {
        status: 500, headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    return new Response(JSON.stringify({ success: true, date }), {
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    });

  } catch (err) {
    console.error("[narrate-detail]", err);
    return new Response(JSON.stringify({ success: false, error: String(err) }), {
      status: 500, headers: { "Content-Type": "application/json", ...corsHeaders() },
    });
  }
});

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}
