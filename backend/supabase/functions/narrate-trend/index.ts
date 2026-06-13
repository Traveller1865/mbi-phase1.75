// backend/supabase/functions/narrate-trend/index.ts
// MBI Phase 1.5 — Trend Narrative Edge Function
// Sprint 2 · Epic 1
// Claude generates window synthesis text from structured inputs only.
// Claude never influences scores, aggregations, driver selections, or signal callouts.
// Prompt Version: 1.3
//   1.3 ← Section 11: Gap honesty framework (11a acknowledgment, 11b reframing, 11c 50% gap skip)
//   1.2 ← Fix 5: window-specific framing (5a), declining 7D suggestion (5b), driver dedup guard (5c)
//   1.1 ← Audit: phrase-stem blacklist vs narrate, provisional guard (days_in_window < 5), tone scaffold

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

const MODEL = "claude-sonnet-4-6";
const PROMPT_VERSION = "1.3";
const MAX_TOKENS = 300;

// Section 11c: When more than this fraction of days_in_window have no wearable data,
// skip the Claude API call entirely and return a structured not-enough-data response.
const GAP_SKIP_THRESHOLD = 0.50;

// ─────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────

type WindowType = "7d" | "8w" | "12m";

interface TrendNarrativeInput {
  window_type: WindowType;
  window_start: string;
  window_end: string;
  chronos_avg: number;
  chronos_min: number;
  chronos_max: number;
  trend_direction: "improving" | "stable" | "declining";
  top_drivers: string[];   // top 2 most-flagged metrics across the window
  days_in_window: number;
}

// TTL seconds per window type for trend_narratives cache
const NARRATIVE_TTL_SECONDS: Record<WindowType, number> = {
  "7d":  24 * 3600,
  "8w":  7  * 24 * 3600,
  "12m": 30 * 24 * 3600,
};

// ─────────────────────────────────────────
// METRIC LABELS — mirrors narrate/index.ts
// ─────────────────────────────────────────

const METRIC_LABELS: Record<string, string> = {
  hrv:               "heart rate variability",
  resting_hr:        "resting heart rate",
  respiratory_rate:  "respiratory rate",
  sleep_duration:    "sleep duration",
  sleep_continuity:  "sleep quality",
  steps:             "daily steps",
  active_minutes:    "active minutes",
  d1_autonomic:      "autonomic recovery",
  d2_sleep:          "sleep recovery",
  d3_activity:       "activity",
};

// ─────────────────────────────────────────
// WINDOW LABELS
// ─────────────────────────────────────────

const WINDOW_LABELS: Record<WindowType, string> = {
  "7d":  "the past 7 days",
  "8w":  "the past 8 weeks",
  "12m": "the past 12 months",
};

// ─────────────────────────────────────────
// RESPONSE TONE SCAFFOLD (Audit §4.2)
// Hardcoded 'balanced' for Phase 1. Phase 2 reads from users table preference.
// ─────────────────────────────────────────

const TONE_INSTRUCTIONS: Record<string, string> = {
  balanced:     "Write in warm, observational framing. Flowing prose, 3–5 sentences. Metaphor permitted. This is the default register.",
  clinical:     "Write metric-forward with no metaphor. Short sentences, data-first, no body-as-nature framing.",
  motivational: "Write with directional energy framing. Arc-focused, forward-leaning.",
};

// ─────────────────────────────────────────
// PROVISIONAL NOT-ENOUGH-DATA RESPONSE
// Returned when days_in_window < 5. No Claude call made.
// ─────────────────────────────────────────

const PROVISIONAL_RESPONSE = {
  not_enough_data: true,
  narrative: null,
  message: "Not enough data to generate a trend narrative for this window yet. Keep tracking — this will activate once you have at least 5 days of readings.",
};

// ─────────────────────────────────────────
// WINDOW-SPECIFIC FRAMING (Fix 5a)
// ─────────────────────────────────────────

const WINDOW_FRAMING: Record<WindowType, string> = {
  "7d":  "Frame this as signal vs noise. Is this week a meaningful signal or short-term noise? " +
         "Focus on what the pattern across the past 7 days reveals about the user's current state. " +
         "Arc-based, specific, grounded.",
  "8w":  "Frame this as trajectory. Is momentum building or eroding over the medium term? " +
         "Focus on sustained patterns across the past 8 weeks, not single-week events. " +
         "Describe the direction and texture of the arc.",
  "12m": "Frame this as the long arc. Look for seasonal patterns, peak months, structural habits. " +
         "Avoid language tied to specific weeks — speak to the shape of the year as a whole.",
};

// ─────────────────────────────────────────
// PROMPT BUILDER
// Voice & tone rules match narrate/index.ts.
// Structured data in → narrative copy out.
// Claude does not compute anything from this prompt.
// Fix 5a: window-specific framing block
// Fix 5b: declining 7D suggestion appended when applicable
// Fix 5c: top_drivers deduped before this function is called
// ─────────────────────────────────────────

function buildPrompt(input: TrendNarrativeInput, gapDays: number = 0): string {
  const windowLabel = WINDOW_LABELS[input.window_type];
  const driver1 = METRIC_LABELS[input.top_drivers[0]] ?? input.top_drivers[0] ?? "your primary metric";
  const driver2 = METRIC_LABELS[input.top_drivers[1]] ?? input.top_drivers[1] ?? null;
  const driverPhrase = driver2
    ? `${driver1} and ${driver2}`
    : driver1;

  const directionPhrase = {
    improving: "an improving trend",
    stable:    "a stable pattern",
    declining: "a declining trend",
  }[input.trend_direction];

  const toneInstruction = TONE_INSTRUCTIONS["balanced"];  // ← Audit §4.2: Phase 2 reads from users table
  const windowFraming = WINDOW_FRAMING[input.window_type];

  // Fix 5b: add one suggestion when 7D window is declining
  const suggestionInstruction = (input.window_type === "7d" && input.trend_direction === "declining")
    ? `\nSUGGESTION REQUIREMENT: Because this is a declining 7-day window, add one plain-language wellness suggestion at the end of the narrative. ` +
      `It must relate to the drivers (${driverPhrase}). Frame it as an invitation, not a directive. ` +
      `Example tone: "This week reads as an invitation to protect rest a little more deliberately." ` +
      `Keep it to one sentence. Never clinical. Never alarming.`
    : "";

  // Section 11a: Gap acknowledgment — added to DATA context when ≥1 day had no wearable data.
  // Section 11b: Reframe language for partial windows — do not project confidence the data cannot support.
  const gapNote = gapDays > 0
    ? `\nDATA COMPLETENESS: ${gapDays} of ${input.days_in_window} scored days in this window had incomplete ` +
      `wearable data (device not worn or sync failure). The trend reflects wearable-quality days only. ` +
      `If referencing patterns or consistency, acknowledge that some days in the window may not be fully represented. ` +
      `Do not over-project — write with appropriate nuance about what the data can and cannot show.`
    : "";

  return `You are the voice of Mynd & Bodi Institute, a prevention-first health intelligence platform.

Your role is to translate physiological trend data into plain-language wellness context for a time window. You are a trusted, warm, knowledgeable guide — not a clinician.

ABSOLUTE RULES — NEVER VIOLATE:
- Never use clinical language or diagnostic framing
- Never say "autonomic dysfunction", "systemic inflammation", "pathological", "risk factor", or any medical diagnostic term
- Never say "consult a physician" or suggest medical evaluation
- Never induce anxiety, shame, or obsessive self-monitoring
- Always use wellness framing: recovery, resilience, patterns, energy, balance
- Write 3–5 sentences (plus the suggestion sentence if required below). No more. No less.
- Reference specific metric names from the drivers provided
- Describe the arc of the window — where things started, what the pattern was, what is driving it
- Do not repeat or paraphrase the stat line — it is shown separately below the narrative

PHRASE-STEM BLACKLIST — DO NOT USE ANY OF THESE PATTERNS (Audit §2.4):
These stems appear in the Today tab daily explanation. Do not use them here — the user may read
both surfaces in the same session and repeated phrasing destroys the sense of intelligence.
- "your body is navigating"
- "your body is showing"
- "your recovery system"
- "the signal worth watching"
- "working harder than usual"
- "holding strong"
- "the composite score"
- "signals today"
Use window-specific, arc-based, time-oriented language instead — e.g. "over this window", "across the past [N] days", "the pattern across this period".

WINDOW FRAMING (Fix 5a — apply this perspective): ${windowFraming}

WINDOW DATA (deterministic — do not alter these values):
- Window: ${windowLabel}
- Average Chronos score: ${Math.round(input.chronos_avg)}
- Range: ${Math.round(input.chronos_min)} low · ${Math.round(input.chronos_max)} high
- Trend direction: ${directionPhrase}
- Key drivers across this window: ${driverPhrase}
- Days of data in window: ${input.days_in_window}
${gapNote}
RESPONSE TONE (balanced): ${toneInstruction}
${suggestionInstruction}
Write a 3–5 sentence window synthesis. Describe the arc of ${windowLabel}. Reference ${driverPhrase} by name. Keep the tone warm, grounded, and specific. Do not write a list. Write connected prose.

Respond with only the narrative text. No labels. No JSON. No preamble.`;
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

    const body = await req.json() as TrendNarrativeInput & { userId: string; window_key?: string };
    const { userId, window_type, window_start, window_end,
            chronos_avg, chronos_min, chronos_max,
            trend_direction, top_drivers, days_in_window, window_key } = body;

    // ── Validate required fields ─────────────────────────────────────
    if (!userId || !window_type || chronos_avg == null) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: userId, window_type, chronos_avg" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() } }
      );
    }

    // ── S13: Verify the caller's JWT matches the requested userId ─────
    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    // ── Provisional guard (Audit §2.4 Issue 6) ───────────────────────
    // Fewer than 5 days in window → return structured not-enough-data response.
    // No Claude call. Prevents confident-sounding narrative from sparse data.
    if ((days_in_window ?? 0) < 5) {
      return new Response(
        JSON.stringify({
          success: true,
          prompt_version: PROMPT_VERSION,
          model_version: MODEL,
          ...PROVISIONAL_RESPONSE,
        }),
        { headers: { "Content-Type": "application/json", ...corsHeaders() } }
      );
    }

    // ── Section 11: Gap honesty — count steps_only days in window ────────────
    // Query daily_inputs for steps_only rows within the narrative window.
    // This is the authoritative server-side count — iOS does not need to pass gap_days.
    let gapDays = 0;
    if (window_start && window_end) {
      const { data: gapRows } = await supabase
        .from("daily_inputs")
        .select("date")
        .eq("user_id", userId)
        .gte("date", window_start)
        .lte("date", window_end)
        .eq("data_tier", "steps_only");
      gapDays = gapRows?.length ?? 0;
    }

    // Section 11c: Skip Claude API when >50% of window days have no wearable data.
    // A narrative built on fewer than half the window's days cannot honestly
    // characterise the arc — returning not_enough_data is more honest.
    if (gapDays > (days_in_window ?? 0) * GAP_SKIP_THRESHOLD) {
      console.log(
        `[narrate-trend] Skipping Claude call — ${gapDays}/${days_in_window} gap days ` +
        `(>${Math.round(GAP_SKIP_THRESHOLD * 100)}% threshold) for user ${userId} window ${window_type}`
      );
      return new Response(
        JSON.stringify({
          success: true,
          not_enough_data: true,
          narrative: null,
          gap_days: gapDays,
          message: `More than half of this window had incomplete wearable data. Trend narrative is paused until more wearable days are available.`,
          prompt_version: PROMPT_VERSION,
          model_version: MODEL,
        }),
        { headers: { "Content-Type": "application/json", ...corsHeaders() } }
      );
    }

    // ── Fix 6: Cache check — serve from trend_narratives if non-expired ──
    if (window_key) {
      const { data: cached } = await supabase
        .from("trend_narratives")
        .select("narrative_text")
        .eq("user_id", userId)
        .eq("window_type", window_type)
        .eq("window_key", window_key)
        .gt("expires_at", new Date().toISOString())
        .maybeSingle();

      if (cached?.narrative_text) {
        return new Response(
          JSON.stringify({
            success: true,
            narrative: cached.narrative_text,
            prompt_version: PROMPT_VERSION,
            model_version: MODEL,
            cache_hit: true,
          }),
          { headers: { "Content-Type": "application/json", ...corsHeaders() } }
        );
      }
    }

    // Fix 5c: dedup top_drivers before passing to prompt — prevents "steps and steps" phrasing
    const rawDrivers: string[] = top_drivers ?? [];
    const dedupedDrivers = rawDrivers.length >= 2 && rawDrivers[0] === rawDrivers[1]
      ? [rawDrivers[0]]
      : rawDrivers;

    const input: TrendNarrativeInput = {
      window_type,
      window_start,
      window_end,
      chronos_avg,
      chronos_min,
      chronos_max,
      trend_direction,
      top_drivers: dedupedDrivers,
      days_in_window: days_in_window ?? 0,
    };

    const prompt = buildPrompt(input, gapDays);

    // ── Call Claude API ───────────────────────────────────────────────
    const claudeResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system: "You are the Mynd & Bodi Institute wellness voice. Write only warm, plain-language wellness narrative. Never use clinical or diagnostic language. Respond with narrative prose only — no labels, no JSON, no lists.",
        messages: [{ role: "user", content: prompt }],
      }),
    });

    if (!claudeResponse.ok) {
      const err = await claudeResponse.text();
      throw new Error(`Claude API error: ${err}`);
    }

    const claudeData = await claudeResponse.json();
    const narrativeText = (claudeData.content?.[0]?.text ?? "").trim();

    if (!narrativeText) {
      throw new Error("Claude returned empty narrative");
    }

    // ── Fix 6: Persist to trend_narratives cache ──────────────────────
    if (window_key) {
      const ttlSeconds = NARRATIVE_TTL_SECONDS[window_type as WindowType] ?? 24 * 3600;
      const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();
      await supabase.from("trend_narratives").upsert({
        user_id:        userId,
        window_type,
        window_key,
        narrative_text: narrativeText,
        expires_at:     expiresAt,
      }, { onConflict: "user_id,window_type,window_key" });
    }

    return new Response(
      JSON.stringify({
        success: true,
        narrative: narrativeText,
        prompt_version: PROMPT_VERSION,
        model_version: MODEL,
        cache_hit: false,
      }),
      { headers: { "Content-Type": "application/json", ...corsHeaders() } }
    );

  } catch (err) {
    console.error("[narrate-trend]", err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders() } }
    );
  }
});

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}