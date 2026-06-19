// backend/supabase/functions/narrate/index.ts
// MBI Phase 1 — Narrative Layer Edge Function
// Sprint 5 | Claude explains. Claude does not decide.
// Prompt Version: 2.0
//   1.2 ← S1-003: driver deviation direction passed to Claude
//   1.3 ← Audit: driver-state opening rule, narrative frame rotation, response tone scaffold
//   1.4 ← Range Architecture v1.0: zone_1/zone_2 context, trust-state framing rules, UX language guide
//   1.5 ← Pre-Beta Sprint: Yellowline band context; CALM narrative branch (all signals within range)
//   2.0 ← Brief expansion: raw metric values injected, domain scores injected, full-body synthesis instructions, 3-sentence rule
// Domain v1.6 ← Yellowline is now a momentum signal (decline_signal), not a band. Band context
//               drops Yellowline; prompt gains decline_signal framing + Drifting sub-range tone split.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

const MODEL                = "claude-sonnet-4-6";
const PROMPT_VERSION       = "2.0";
const NUDGE_POLICY_VERSION = "v1.0";
const DOMAIN_VERSION       = "1.6"; // must match contracts.ts DOMAIN_VERSION

// ─────────────────────────────────────────
// METRIC DISPLAY NAMES
// ─────────────────────────────────────────
const METRIC_LABELS: Record<string, string> = {
  hrv: "heart rate variability",
  resting_hr: "resting heart rate",
  respiratory_rate: "respiratory rate",
  sleep_duration: "sleep duration",
  sleep_continuity: "sleep quality",
  steps: "daily steps",
  active_minutes: "active minutes",
  distance: "activity distance",
};

const DOMAIN_LABELS: Record<string, string> = {
  d1_autonomic: "autonomic recovery",
  d2_sleep: "sleep recovery",
  d3_activity: "activity",
};

// ─────────────────────────────────────────
// DRIVER DIRECTION CONTEXT  (S1-003)
// Maps driver name → daily_inputs column and baselines column.
// Used to compute whether today's reading is above or below the user's
// 7-day baseline, and whether that direction indicates a stress signal.
// ─────────────────────────────────────────

const INPUT_COL: Record<string, string> = {
  hrv:              "hrv_ms",
  resting_hr:       "resting_hr_bpm",
  respiratory_rate: "respiratory_rate_rpm",
  sleep_duration:   "sleep_duration_hrs",
  sleep_continuity: "sleep_continuity_pct",
  steps:            "steps",
  active_minutes:   "active_minutes",
};

const BASELINE_COL: Record<string, string> = {
  hrv:              "hrv_avg",
  resting_hr:       "resting_hr_avg",
  respiratory_rate: "respiratory_rate_avg",
  sleep_duration:   "sleep_duration_avg",
  sleep_continuity: "sleep_continuity_avg",
  steps:            "steps_avg",
  active_minutes:   "active_minutes_avg",
};

// true = higher value is the stress direction for that metric
const STRESS_IS_HIGH: Record<string, boolean> = {
  hrv:              false,
  resting_hr:       true,
  respiratory_rate: true,
  sleep_duration:   false,
  sleep_continuity: false,
  steps:            false,
  active_minutes:   false,
};

function buildDriverContext(
  driver: string,
  // deno-lint-ignore no-explicit-any
  inputRow: Record<string, any> | null,
  // deno-lint-ignore no-explicit-any
  baselineRow: Record<string, any> | null
): string {
  const inputCol   = INPUT_COL[driver];
  const baselineCol = BASELINE_COL[driver];
  const label      = METRIC_LABELS[driver] ?? driver;

  if (!inputCol || !baselineCol || !inputRow || !baselineRow) {
    return `${label}: baseline still building — no direction yet`;
  }

  const todayVal    = inputRow[inputCol]    as number | null;
  const baselineVal = baselineRow[baselineCol] as number | null;

  if (todayVal == null || baselineVal == null || baselineVal === 0) {
    return `${label}: reading unavailable today`;
  }

  const pctDiff    = ((todayVal - baselineVal) / baselineVal) * 100;
  const absPct     = Math.abs(Math.round(pctDiff));
  const direction  = pctDiff >= 0 ? "above" : "below";
  const stressHigh = STRESS_IS_HIGH[driver] ?? false;
  const isStress   = stressHigh ? pctDiff > 0 : pctDiff < 0;
  const signal     = isStress ? "recovery demand" : "strength";

  return `${label} is ${absPct}% ${direction} the user's 7-day average — signaling ${signal}`;
}

// ─────────────────────────────────────────
// RAW METRIC VALUE FORMATTER (v2.0)
// Formats the raw daily_inputs value for a driver into a human-readable string.
// Mirrors the Swift ChronosMetricHelpers.formatValue contract.
// ─────────────────────────────────────────

function formatDriverValue(
  driver: string,
  // deno-lint-ignore no-explicit-any
  inputRow: Record<string, any> | null
): string {
  if (!inputRow) return "unavailable";
  const inputCol = INPUT_COL[driver];
  if (!inputCol) return "unavailable";
  const val = inputRow[inputCol] as number | null;
  if (val == null) return "unavailable";

  switch (driver) {
    case "hrv":              return `${Math.round(val)}ms`;
    case "resting_hr":       return `${Math.round(val)}bpm`;
    case "respiratory_rate": return `${(Math.round(val * 10) / 10).toFixed(1)}rpm`;
    case "sleep_duration": {
      const hrs = Math.floor(val);
      const mins = Math.round((val - hrs) * 60);
      return mins > 0 ? `${hrs}h ${mins}m` : `${hrs}h`;
    }
    case "sleep_continuity": return `${Math.round(val)}%`;
    case "steps":            return `${Math.round(val).toLocaleString()} steps`;
    case "active_minutes":   return `${Math.round(val)} min`;
    default:                 return `${Math.round(val)}`;
  }
}

// ─────────────────────────────────────────
// NARRATIVE FRAME ROTATION (Audit §2.3)
// Rotates through four entry-point frames keyed to day-of-week.
// Prevents structural sameness in daily explanations across a 14-day window.
// Server computes: FRAMES[date.getUTCDay() % 4]
// ─────────────────────────────────────────
const FRAMES = ["driver_led", "score_context", "tension_first", "momentum"] as const;
type NarrativeFrame = typeof FRAMES[number];

const FRAME_INSTRUCTIONS: Record<NarrativeFrame, string> = {
  driver_led:    "Open with what the primary driver is doing — name the metric first, then its direction relative to the user's baseline.",
  score_context: "Open with the score's position relative to the recent window — lead with trajectory context first, then explain the drivers.",
  tension_first: "Open by naming the gap between the best and worst signal today — name both metrics explicitly, then explain how they relate.",
  momentum:      "Open with the directional arc across recent days — describe the trend, then name today's position within that arc.",
};

// ─────────────────────────────────────────
// RESPONSE TONE SCAFFOLD (Audit §4.2)
// Hardcoded as 'balanced' for Phase 1. Phase 2 wires user preference toggle
// directly to this field — zero prompt restructuring required at that point.
// ─────────────────────────────────────────
type ResponseTone = "balanced" | "clinical" | "motivational";

const TONE_INSTRUCTIONS: Record<ResponseTone, string> = {
  balanced:      "Write in warm, observational, body-as-nature framing. Flowing prose, 2–4 sentences. Metaphor permitted. This is the default register.",
  clinical:      "Write metric-forward with no metaphor. Short sentences, data-first, no body-as-nature framing. Lead with numbers and percentages.",
  motivational:  "Write with energy and agency framing. Active voice, present tension. Forward-leaning. Invite action at the end.",
};

// ─────────────────────────────────────────
// TIME OF DAY CONTEXT
// Mirrors the Swift TimeOfDay enum boundaries exactly.
// morning  → hour < 12
// daytime  → hour 12–16
// evening  → hour ≥ 17
// ─────────────────────────────────────────
type TimeOfDay = "morning" | "daytime" | "evening";

const TIME_OF_DAY_CONTEXT: Record<TimeOfDay, string> = {
  morning: `The user is reading this in the morning, just after waking.
Their overnight biometric data has just been processed.
The brief must orient them toward the day ahead.
Tone: grounded, clear, forward-facing.
The explanation should describe what their body did overnight and what that means for today's capacity.
It must not reference the evening or sleep preparation — that is for the evening brief.
The nudge must be something actionable in the next few hours.`,

  daytime: `The user is reading this in the afternoon. Their day is already underway.
The brief should acknowledge what their data showed this morning and what it means for the remainder of today.
Tone: steady, practical, present-tense.
The nudge should be something still achievable before the evening begins.`,

  evening: `The user is reading this in the evening, as their active day winds down.
The brief must orient them toward tonight and the overnight recovery ahead.
Tone: calm, reflective, forward to sleep.
The explanation should describe what today's signals mean for tonight's recovery opportunity.
It must not dwell on what happened during the day — it should close the loop and point toward rest.
The nudge must target sleep preparation, wind-down, or stress reduction.`,
};

// ─────────────────────────────────────────
// ZONE CONTEXT BUILDER (Range Architecture v1.0)
// Translates zone state + trust state into a narrative-ready descriptor.
// Trust state gates zone language — provisional state adds qualifier.
// ─────────────────────────────────────────

type RangeTrustState = "establishing" | "calibrating" | "provisional" | "trusted" | "established";
type ZoneState = "elevated" | "within_range_high" | "within_range_low" | "below_range" | "flagged" | null;

const ZONE_LABELS: Record<Exclude<ZoneState, null>, string> = {
  elevated:          "above their personal range",
  within_range_high: "in the upper half of their personal range",
  within_range_low:  "in the lower half of their personal range",
  below_range:       "below their personal range",
  flagged:           "at an acutely low level",
};

// ─────────────────────────────────────────
// PHRASE-STEM BLACKLIST
// Programmatic post-gen enforcement — catches clinical/diagnostic language
// that the prompt rules were unable to suppress. Applied before save.
// ─────────────────────────────────────────
const BANNED_PHRASES: Array<[RegExp, string]> = [
  [/autonomic dysfunction/gi,       "autonomic signal shift"],
  [/systemic inflammation/gi,       "systemic load"],
  [/\bpathological\b/gi,            "outside their usual range"],
  [/\brisk factor/gi,               "signal worth watching"],
  [/consult a physician/gi,         "check in with a professional if this continues"],
  [/suggest medical evaluation/gi,  "pay attention to how you feel"],
  [/seek medical/gi,                "pay attention to how you feel"],
  [/\babnormal\b/gi,                "outside their recent usual range"],
  [/unhealthy today/gi,             "lower than their recent baseline"],
];

function sanitizeNarrative(text: string): string {
  return BANNED_PHRASES.reduce(
    (result, [pattern, replacement]) => result.replace(pattern, replacement),
    text
  );
}

function buildZoneContext(
  driver: string,
  zone: ZoneState,
  trustState: RangeTrustState,
): string {
  const label = METRIC_LABELS[driver] ?? driver;

  if (zone == null || trustState === "establishing" || trustState === "calibrating") {
    return ""; // no zone language in early states
  }

  const zoneDesc = ZONE_LABELS[zone];

  if (trustState === "provisional") {
    // Provisional: zone shown but must include qualifier
    return `${label} zone (provisional, based on early data): ${zoneDesc}`;
  }

  // trusted or established: full zone framing, no caveat
  return `${label} zone: ${zoneDesc}`;
}

// Trust-state-specific framing rule for Claude
const TRUST_STATE_FRAMING: Record<RangeTrustState, string> = {
  establishing:
    "The user is in baseline-building mode (0–2 days of data). Do NOT use any score language, range language, or zone language. Use only baseline-building framing — explain that the system is learning their patterns.",
  calibrating:
    "The user is calibrating (3–6 days of data). Use deviation language with an explicit provisional caveat. Do NOT use zone language or range references. Note that the score will become more personalised as more data accumulates.",
  provisional:
    "The user's range is provisional (7–20 days of data). Zone labels may be used but must include a qualifier such as 'your early range suggests' or 'based on your data so far.' Never state the range as definitive.",
  trusted:
    "The user has a trusted baseline (21+ recent valid days). Use full zone framing with no caveat. Zone labels drive the opening sentence when the driver_led frame is active.",
  established:
    "The user has an established baseline (42+ valid days). Use full zone framing. If a range shift direction is provided, you may acknowledge the multi-week trend when contextually appropriate — not in every daily narrate.",
};

// ─────────────────────────────────────────
// PROMPT BUILDER
// Voice & tone rules enforced here (SoT §5.3, PRD §5.3)
// ─────────────────────────────────────────
function buildPrompt(input: {
  chronos_score: number;
  score_band: string;
  decline_signal: string | null;   // ← v1.6 momentum signal ("yellowline" | null)
  driver_1: string;
  driver_2: string;
  driver_1_context: string;   // ← S1-003
  driver_2_context: string;   // ← S1-003
  driver_1_value: string;     // ← v2.0 raw formatted value e.g. "35ms", "5h 9m"
  driver_2_value: string;     // ← v2.0 raw formatted value
  delta_override_triggered: boolean;
  fail_state: string | null;
  domain_scores: Record<string, number | null>;
  is_provisional: boolean;
  nudge_domain: string;
  time_of_day: TimeOfDay;
  narrative_frame: NarrativeFrame;  // ← Audit §2.3
  response_tone: ResponseTone;      // ← Audit §4.2
  // Range Architecture v1.0
  range_trust_state: RangeTrustState;
  zone_1_context: string;   // pre-built zone descriptor or ""
  zone_2_context: string;   // pre-built zone descriptor or ""
  // CALM branch (v1.5): all active driver signals within personal range
  is_calm: boolean;
}): string {
  const driver1Label = METRIC_LABELS[input.driver_1] ?? input.driver_1;
  const driver2Label = METRIC_LABELS[input.driver_2] ?? input.driver_2;
  const nudgeLabel = DOMAIN_LABELS[input.nudge_domain] ?? input.nudge_domain;

  const bandContext = {
    Thriving:   "The user is in strong recovery. Maintain momentum.",
    Recovering: "The user is in a mild stress load but within adaptive range.",
    Drifting:   "Risk is accumulating. The user needs attention before it compounds.",
    Redline:    "Acute physiological stress. Calm and supportive tone. Not alarming.",
  }[input.score_band] ?? "";

  const deltaContext = input.delta_override_triggered
    ? "IMPORTANT: The score has dropped more than 15 points over the last 3 days. Even if the current band is Recovering or Drifting, write as if the user is trending down quickly. Acknowledge the trajectory, not just today's state."
    : "";

  const provisionalNote = input.is_provisional
    ? "NOTE: This score is provisional — the user is still building their baseline. Mention gently that the score will become more personalized over the next few days."
    : "";

  // E-09: time-gated nudge framing
  const timeContext = TIME_OF_DAY_CONTEXT[input.time_of_day];

  const frameInstruction = FRAME_INSTRUCTIONS[input.narrative_frame];
  const toneInstruction  = TONE_INSTRUCTIONS[input.response_tone];

  // Range Architecture v1.0 — trust state framing rule and zone context
  const trustStateInstruction = TRUST_STATE_FRAMING[input.range_trust_state];
  const zoneSection = (input.zone_1_context || input.zone_2_context)
    ? `ZONE POSITION DATA (use where zone language is permitted by trust state below):
- ${input.zone_1_context || `${driver1Label} zone: not yet available`}
- ${input.zone_2_context || `${driver2Label} zone: not yet available`}`
    : "";

  // v2.0: time window label for explanation instructions
  const timeWindowLabel = input.time_of_day === "morning" ? "this morning"
    : input.time_of_day === "evening" ? "this evening"
    : "today";

  // v2.0: domain scores — were computed upstream but never reached Claude
  const domainScoresContext = `
DOMAIN SCORES TODAY (0–100 scale, each represents a body system):
- Autonomic (nervous system / HRV): ${input.domain_scores["d1_autonomic"] ?? "unavailable"}
- Sleep (duration, quality, continuity): ${input.domain_scores["d2_sleep"] ?? "unavailable"}
- Activity (movement, steps, active minutes): ${input.domain_scores["d3_activity"] ?? "unavailable"}
A score below 50 indicates below-baseline performance for that system. A score above 70 indicates above-baseline performance. Use these to understand which body systems are carrying load and which are holding steady — beyond just the two primary drivers.`;

  // CALM framing (v1.5): injected when all active driver signals are within personal range.
  // Horizon CALM card copy — the narrative acknowledges equilibrium as meaningful,
  // not just the absence of a problem.
  const calmSection = input.is_calm
    ? `CALM STATE: Both primary driver signals are within the user's personal range today. Use CALM framing:
- Acknowledge the equilibrium directly — "both your primary signals are within your usual range"
- Frame being in range as a positive signal, not just the absence of a problem
- Do not use language that implies the user should be worried or looking for problems
- The nudge should target maintenance and consolidation, not correction
- Avoid phrases that imply fragility or edge-case thinking`
    : "";

  // Decline signal (v1.6, Change B): the user is still in the upper range by band, but
  // their score has fallen meaningfully over the past week. Surface the momentum shift —
  // this narrative must NOT read identically to a stable user at the same score.
  const declineSection = input.decline_signal === "yellowline"
    ? `MOMENTUM SIGNAL — DECLINE DETECTED: The user's score has declined meaningfully over the past week, even though their current band is still in the upper range. Emphasize what is shifting and why it matters, not just where the score currently sits. This is an early-intercept signal — the goal is to interrupt complacency, not to alarm. Name the downward trajectory plainly and constructively; do not write as if the user is stable.`
    : "";

  // Drifting sub-range differentiation (v1.6, Change C): Drifting now spans 40–69, a wide
  // band. Upper Drifting (60–69) is recoverable-with-attention; lower Drifting (40–59) warrants
  // clearer urgency. Tone must differ across the two ranges.
  const driftingSubRangeSection = input.score_band === "Drifting"
    ? (input.chronos_score >= 60
        ? `DRIFTING SUB-RANGE (upper, score ${input.chronos_score}): Use awareness language — something is slipping but the situation is recoverable with attention. Do not use high-urgency or alarming framing.`
        : `DRIFTING SUB-RANGE (lower, score ${input.chronos_score}): Use clearer urgency — sustained patterns need to be addressed. Be direct that this is more than a momentary dip, while staying within wellness (non-clinical) framing.`)
    : "";

  return `You are the voice of Mynd & Bodi Institute, a prevention-first health intelligence platform.

Your role is to translate physiological data into plain-language wellness context. You are a trusted, warm, knowledgeable guide — not a clinician.

ABSOLUTE RULES — NEVER VIOLATE:
- Never use clinical language or diagnostic framing
- Never say "autonomic dysfunction", "systemic inflammation", "pathological", "risk factor", or any medical diagnostic term
- Never say "consult a physician" or suggest medical evaluation
- Never induce anxiety, shame, or obsessive self-monitoring
- Always use wellness framing: recovery, resilience, patterns, energy, balance
- One nudge only. Never a list. One single action sentence.
- Never contradict the DRIVER DIRECTION DATA below — these are deterministic facts about the user's body today

LANGUAGE RULES — ALWAYS FOLLOW:
- Never say "abnormal" — use "outside their recent usual range"
- Never say "unhealthy today" — use "lower than their recent baseline"
- Never say "your recovery crashed" — use "your recovery markers were lower than usual today"
- Never say "warning" for a single outlier — use "worth noticing" or "worth keeping an eye on"
- Never imply underperformance when a metric is within range — within range is within range
- Never say "your score says..." — use "your recent measurements suggest..."
- Never suggest illness or condition from a single-day signal
- Never say "you need to..." — use direct action framing that starts with the action itself

CRITICAL RULE — DRIVER-STATE OPENING: If driver_1_context signals 'recovery demand' (meaning the primary driver is underperforming relative to baseline), the opening sentence of EXPLANATION must acknowledge this signal directly. Never open with purely positive framing when the primary driver is underperforming — regardless of score band. The explanation must honour the tension between a healthy composite score and a struggling primary signal.

TRUST STATE FRAMING RULE (${input.range_trust_state}): ${trustStateInstruction}

TODAY'S DATA (deterministic — do not change these values):
- Chronos Score: ${input.chronos_score}/100
- Band: ${input.score_band}
- Primary drivers: ${driver1Label} and ${driver2Label}
- Nudge target domain: ${nudgeLabel}

DRIVER DIRECTION DATA (deterministic — your explanation must align with these):
- ${input.driver_1_context} [today's value: ${input.driver_1_value}]
- ${input.driver_2_context} [today's value: ${input.driver_2_value}]

${zoneSection}
${calmSection}
${domainScoresContext}

BAND CONTEXT: ${bandContext}
${driftingSubRangeSection}
${declineSection}
${deltaContext}
${provisionalNote}

TIME OF DAY CONTEXT: ${timeContext}

NARRATIVE FRAME (${input.narrative_frame}): ${frameInstruction}

RESPONSE TONE (${input.response_tone}): ${toneInstruction}

BRIEF RULES — NON-NEGOTIABLE:
1. The explanation must be exactly 3 sentences. Count before outputting. Delete sentences until exactly 3 remain.
2. The first sentence is the hook. It must be about what the body is doing — not what the score is. Do not open with "Your Chronos Score of X". Do not restate the score card.
3. No em dashes anywhere in the output. Replace with commas or periods.
4. No score band name references in the explanation (do not write "Recovering", "Yellow Line", "Thriving" etc.) — these appear elsewhere in the UI.
5. The explanation must not repeat what the Recovery Window card already said. The Recovery Window covers the combined signal of the two drivers. The brief covers the body's wider story — what these signals mean across the day or night.
6. The nudge must be direct and confident. Do not open with "If this matches how you feel" or "consider" or any other hedge. Start with the action.
7. The nudge is one sentence. Two maximum if the second adds meaningful supporting context.
8. No em dashes in the nudge.

Generate exactly two outputs:

EXPLANATION INSTRUCTIONS:

Your job is to write the user's body brief for ${timeWindowLabel}.

The brief must tell the user's full body story — synthesizing across ALL signals, not just the two primary drivers. The driver cards and Recovery Window card already explain what the two drivers are and what they mean together. Do not repeat that. The brief must add new information.

What the brief should do:
- Look at the complete picture: all three domain scores, both driver signals, and the zone context
- Surface what is worth noticing beyond the two drivers — is one domain holding strong while others dip? Is the pattern compressed across all systems or isolated to one?
- Give the user a sense of their body as a whole organism today, not a list of flagged metrics
- Connect today to a pattern or trajectory where the data supports it
- Close with what this means for the time window ahead (morning = the day ahead, evening = tonight and overnight)

What the brief must NOT do:
- Repeat what the driver cards already say (do not name the drivers and restate their deviations)
- Repeat what the Recovery Window already said (do not restate the combined driver signal)
- Open with the Chronos score or score band
- Use score band names (Recovering, Yellow Line, Thriving etc.)
- Use em dashes
- Use hedging language (may, might, could suggest)
- Reference the scoring system or algorithm

BRIEF RULES:
1. Exactly 3 sentences. Count before outputting. Delete sentences until exactly 3 remain.
2. First sentence: the hook — what is the body's overall state today, in terms that go beyond the two drivers
3. Second sentence: what the full signal picture reveals — include at least one reference to a domain or signal that is NOT one of the two primary drivers
4. Third sentence: what this means for the time window ahead — orient toward action or awareness
5. No em dashes anywhere
6. No score or band references
7. No repetition of driver card or Recovery Window content

NUDGE: 1 sentence (2 maximum). A single, concrete, achievable action targeting ${nudgeLabel}. The nudge must be appropriate for when the user is actually reading this (see TIME OF DAY CONTEXT above). Never a list. Never more than one action. Start directly with the action — no hedging opener.

Respond in this exact JSON format:
{
  "explanation": "...",
  "nudge": "..."
}`;
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

    // E-09: timeOfDay added to payload. iOS client sends it; falls back to
    // "morning" if omitted so existing callers don't break.
    // briefSession: "morning" | "evening" — determines which columns are upserted.
    // Defaults to "morning" for backward compatibility.
    const { userId, date, timeOfDay, briefSession } = await req.json();
    const time_of_day: TimeOfDay =
      timeOfDay === "daytime" || timeOfDay === "evening" ? timeOfDay : "morning";
    const brief_session: "morning" | "evening" =
      briefSession === "evening" ? "evening" : "morning";

    // Audit §2.3: narrative frame rotates by day-of-week so daily structure
    // varies across a 4-day cycle without any client change required.
    const date_obj = new Date(date);
    const narrative_frame: NarrativeFrame = FRAMES[date_obj.getUTCDay() % 4];

    // ── S13: Verify the caller's JWT matches the requested userId ─────
    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    // ── Fetch the score for this day ──────────────────────────────────
    const { data: score, error: scoreErr } = await supabase
      .from("daily_scores")
      .select("*")
      .eq("user_id", userId)
      .eq("date", date)
      .single();

    if (scoreErr || !score) {
      return new Response(JSON.stringify({ error: "Score not found — run /score first" }), {
        status: 404, headers: { "Content-Type": "application/json", ...corsHeaders() },
      });
    }

    // ── S1-003: Fetch daily_inputs + latest baselines in parallel ─────
    // Both are guaranteed to exist because score already ran successfully.
    const [{ data: inputRow }, { data: baselineRow }] = await Promise.all([
      supabase
        .from("daily_inputs")
        .select("*")
        .eq("user_id", userId)
        .eq("date", date)
        .single(),
      supabase
        .from("baselines")
        .select("*")
        .eq("user_id", userId)
        .order("computed_on", { ascending: false })
        .limit(1)
        .single(),
    ]);

    const driver1Context = buildDriverContext(score.driver_1, inputRow, baselineRow);
    const driver2Context = buildDriverContext(score.driver_2, inputRow, baselineRow);

    // ── Range Architecture v1.0 — zone context and trust state ───────
    // zone_1/zone_2 are written to daily_scores by the scoring pipeline.
    // range_trust_state is written to baselines by the scoring pipeline (and
    // now also to daily_scores as of migration 20260514000002).
    const rangeTrustState: RangeTrustState =
      (score.range_trust_state as RangeTrustState)                           // v1.5: prefer daily_scores
      ?? (baselineRow as Record<string, unknown>)?.range_trust_state as RangeTrustState
      ?? "establishing";
    const zone1: ZoneState = (score.zone_1 as ZoneState) ?? null;
    const zone2: ZoneState = (score.zone_2 as ZoneState) ?? null;
    const zone1Context = buildZoneContext(score.driver_1, zone1, rangeTrustState);
    const zone2Context = buildZoneContext(score.driver_2, zone2, rangeTrustState);

    // ── CALM state detection (v1.5 — Horizon CALM card copy) ─────────
    // CALM: both driver zones are active and neither is below_range or flagged.
    // Only applicable when trust state is provisional or above (zone data is valid).
    const zoneStatesActive = zone1 !== null && zone2 !== null;
    const DISTRESS_ZONES: ZoneState[] = ["below_range", "flagged"];
    const isCalm =
      zoneStatesActive &&
      !DISTRESS_ZONES.includes(zone1) &&
      !DISTRESS_ZONES.includes(zone2) &&
      rangeTrustState !== "establishing" &&
      rangeTrustState !== "calibrating";

    // ── Determine nudge domain (lowest active D1/D2/D3) ──────────────
    const candidates: Array<[string, number | null]> = [
      ["d1_autonomic", score.d1_autonomic],
      ["d2_sleep", score.d2_sleep],
      ["d3_activity", score.d3_activity],
    ];
    const available = candidates.filter(([, v]) => v != null) as Array<[string, number]>;
    available.sort((a, b) => a[1] - b[1]);
    const nudge_domain = available.length > 0 ? available[0][0] : "d1_autonomic";

    // ── Log nudge event (learning foundation) ────────────────────────
    // Morning sessions only — evening brief doesn't log a separate nudge event.
    // Inserted before Claude call so nudge_event_id is available for
    // decision_context_snapshot linkage. nudge_text backfilled after Claude
    // responds. Both inserts are non-fatal — never block narrate on logging.
    let nudgeEventId: string | null = null;

    if (brief_session === "morning") try {
      // Data completeness: fraction of 6 primary metrics present today
      const primaryMetrics = ["hrv_ms", "resting_hr_bpm", "sleep_duration_hrs",
                              "sleep_continuity_pct", "steps", "active_minutes"];
      // deno-lint-ignore no-explicit-any
      const inputData = inputRow as Record<string, any> | null;
      const presentCount = primaryMetrics.filter((m) => inputData?.[m] != null).length;
      const completenessScore = primaryMetrics.length > 0
        ? presentCount / primaryMetrics.length : null;

      const { data: nudgeEvent } = await supabase
        .from("nudge_events")
        .insert({
          user_id:         userId,
          date:            date,
          score_id:        score.id,
          nudge_domain:    nudge_domain,
          chronos_score:   score.chronos_score,
          score_band:      score.score_band,
          d1_autonomic:    score.d1_autonomic,
          d2_sleep:        score.d2_sleep,
          d3_activity:     score.d3_activity,
          fail_state:      score.fail_state ?? null,
          trust_state:     rangeTrustState ?? null,
          data_confidence: score.confidence_tier ?? null,
          delta_override:  score.delta_override_triggered ?? false,
          policy_version:  NUDGE_POLICY_VERSION,
          prompt_version:  PROMPT_VERSION,
          scoring_version: DOMAIN_VERSION,
          // shown_at = now: the narrate function generates the nudge at the moment
          // it is first shown to the user, so shown_at = insert time is semantically
          // correct. This is required by compute-outcome-windows to find eligible
          // nudge_events for T+1 and T+7 outcome window computation.
          shown_at:        new Date().toISOString(),
        })
        .select("id")
        .single();

      nudgeEventId = nudgeEvent?.id ?? null;

      // Decision context snapshot — freeze full system state at this moment
      await supabase.from("decision_context_snapshots").insert({
        user_id:              userId,
        date:                 date,
        event_type:           "nudge_shown",
        score_id:             score.id,
        nudge_event_id:       nudgeEventId,
        chronos_score:        score.chronos_score,
        score_band:           score.score_band,
        primary_driver:       score.driver_1,
        secondary_driver:     score.driver_2,
        fail_state:           score.fail_state ?? null,
        trust_state:          rangeTrustState ?? null,
        data_confidence:      score.confidence_tier ?? null,
        completeness_score:   completenessScore,
        scoring_version:      DOMAIN_VERSION,
        nudge_policy_version: NUDGE_POLICY_VERSION,
        prompt_version:       PROMPT_VERSION,
      });
    } catch (err) {
      console.error("[narrate] learning foundation log failed (non-fatal):", err);
    } // end if (brief_session === "morning")

    const narrativeInput = {
      chronos_score: score.chronos_score,
      score_band: score.score_band,
      decline_signal: score.decline_signal ?? null,   // ← v1.6 momentum signal
      driver_1: score.driver_1,
      driver_2: score.driver_2,
      driver_1_context: driver1Context,   // ← S1-003
      driver_2_context: driver2Context,   // ← S1-003
      driver_1_value: formatDriverValue(score.driver_1, inputRow),   // ← v2.0
      driver_2_value: formatDriverValue(score.driver_2, inputRow),   // ← v2.0
      delta_override_triggered: score.delta_override_triggered,
      fail_state: score.fail_state,
      domain_scores: {
        d1_autonomic: score.d1_autonomic,
        d2_sleep: score.d2_sleep,
        d3_activity: score.d3_activity,
      },
      is_provisional: score.is_provisional,
      nudge_domain,
      time_of_day,
      narrative_frame,              // ← Audit §2.3: day-of-week frame rotation
      response_tone: "balanced" as ResponseTone,  // ← Audit §4.2: Phase 2 wires user pref here
      // Range Architecture v1.0
      range_trust_state: rangeTrustState,
      zone_1_context: zone1Context,
      zone_2_context: zone2Context,
      // CALM branch (v1.5)
      is_calm: isCalm,
    };

    const prompt = buildPrompt(narrativeInput);

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
        max_tokens: 512,
        messages: [{ role: "user", content: prompt }],
      }),
    });

    if (!claudeResponse.ok) {
      const err = await claudeResponse.text();
      throw new Error(`Claude API error: ${err}`);
    }

    const claudeData = await claudeResponse.json();
    const rawText = claudeData.content?.[0]?.text ?? "";

    // Parse JSON from Claude response
    let parsed: { explanation: string; nudge: string };
    try {
      const jsonMatch = rawText.match(/\{[\s\S]*\}/);
      parsed = JSON.parse(jsonMatch?.[0] ?? rawText);
    } catch {
      parsed = {
        explanation: "Your body is showing some changes today worth paying attention to.",
        nudge: "Take a moment to rest and recover today.",
      };
    }

    // ── Phrase-stem blacklist: programmatic post-gen enforcement ─────────
    // Catches any banned clinical/diagnostic phrases that slipped past the prompt rules.
    // Runs before save so nothing harmful ever reaches the database or the user.
    parsed.explanation = sanitizeNarrative(parsed.explanation);
    parsed.nudge       = sanitizeNarrative(parsed.nudge);

    // ── Upsert explanation ────────────────────────────────────────────
    // Morning: writes explanation_text + nudge_text.
    // Evening: writes evening_explanation_text + evening_nudge_text only.
    // Both use onConflict: "score_id" so they land on the same row.
    const upsertPayload =
      brief_session === "evening"
        ? {
            score_id:                  score.id,
            user_id:                   userId,
            date,
            evening_explanation_text:  parsed.explanation,
            evening_nudge_text:        parsed.nudge,
            prompt_version:            PROMPT_VERSION,
            model_version:             MODEL,
          }
        : {
            score_id:          score.id,
            user_id:           userId,
            date,
            explanation_text:  parsed.explanation,
            nudge_text:        parsed.nudge,
            prompt_version:    PROMPT_VERSION,
            model_version:     MODEL,
          };

    const { data: saved, error: saveErr } = await supabase
      .from("explanations")
      .upsert(upsertPayload, { onConflict: "score_id" })
      .select()
      .single();

    if (saveErr) throw saveErr;

    // ── Backfill nudge_text into nudge_events (non-fatal, morning only) ──
    // Evening session never creates a nudge_event row, so there is nothing to backfill.
    if (brief_session === "morning" && nudgeEventId) {
      try {
        await supabase
          .from("nudge_events")
          .update({ nudge_text: parsed.nudge })
          .eq("id", nudgeEventId);
      } catch (err) {
        console.error("[narrate] nudge_text backfill failed (non-fatal):", err);
      }
    }

    return new Response(JSON.stringify({
      success: true,
      narrative: saved,
      brief_session,                 // ← "morning" | "evening" — iOS client uses this
      nudge_event_id: nudgeEventId,  // ← iOS client stores this for nudge_responses
    }), {
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    });

  } catch (err) {
    console.error("[narrate]", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    });
  }
});

function corsHeaders() {
  return { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type" };
}