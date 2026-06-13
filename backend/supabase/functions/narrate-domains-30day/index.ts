// backend/supabase/functions/narrate-domains-30day/index.ts
// MBI Phase 1.5 — 30-Day Domain Synthesis Edge Function
// Domains Tab Redesign Sprint
//
// Receives 30-day avg + volatility per domain → returns 1-2 sentence synthesis of
// the 30-day cross-domain picture. Session-cached in iOS caller.
// Prompt Version: 1.0

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

const MODEL = "claude-sonnet-4-6";
const PROMPT_VERSION = "1.0";

// ─────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────

interface ThirtyDayInput {
  userId: string;
  d1_avg: number | null;
  d1_volatility: number | null;
  d2_avg: number | null;
  d2_volatility: number | null;
  d3_avg: number | null;
  d3_volatility: number | null;
  d4_avg: number | null;
  d4_volatility: number | null;
  d5_avg: number | null;
  d5_volatility: number | null;
  days_of_history: number;
}

// ─────────────────────────────────────────
// DOMAIN LABELS
// ─────────────────────────────────────────

const DOMAIN_LABELS: Record<string, string> = {
  d1: "Autonomic Recovery",
  d2: "Sleep Recovery",
  d3: "Activity Load",
  d4: "Inferred Stress",
  d5: "Allostatic Trend",
};

// ─────────────────────────────────────────
// PROMPT BUILDER
// ─────────────────────────────────────────

function buildPrompt(input: ThirtyDayInput): string {
  const domainLines = (["d1", "d2", "d3", "d4", "d5"] as const)
    .filter((d) => input[`${d}_avg` as keyof ThirtyDayInput] != null)
    .map((d) => {
      const avg = Math.round(input[`${d}_avg` as keyof ThirtyDayInput] as number);
      const vol = input[`${d}_volatility` as keyof ThirtyDayInput];
      const volStr = vol != null ? ` (volatility: ${Math.round(vol as number)} pts std dev)` : "";
      return `  ${DOMAIN_LABELS[d]}: avg ${avg}/100${volStr}`;
    })
    .join("\n");

  return `You are the voice of Mynd & Bodi Institute, a prevention-first health intelligence platform.

Your role is to describe the 30-day domain picture in 1–2 sentences. You name what you see across the user's five biological systems over the past month. You do not advise.

ABSOLUTE RULES — NEVER VIOLATE:
- Never use clinical language or diagnostic framing
- Never tell the user what to do — this tab observes only
- Within-user context only — no population comparisons
- Tone: calm, direct, informative
- No em dashes
- No forward-facing language (do not say "if this continues" or "going forward")

30-DAY DOMAIN SUMMARY (${input.days_of_history} days of data):
${domainLines}

Note: For D4 (Inferred Stress) and D5 (Allostatic Trend), LOWER scores mean more stress/load, and HIGHER scores mean the body is handling load well. For D1, D2, D3 — higher is better.
Volatility = standard deviation of daily scores over 30 days. Higher volatility = more day-to-day variation in that domain.

Write 1–2 sentences that:
1. Name which domain has been most variable (highest volatility) if meaningful
2. Name which domains have been the strongest, most consistent anchors
3. Give a directional summary of what the 30-day picture says about this body's current state

Respond in this exact JSON format:
{
  "synthesis_text": "..."
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
    const body = await req.json() as ThirtyDayInput;

    const { userId } = body;

    if (!userId) {
      return new Response(
        JSON.stringify({ error: "userId required" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() } }
      );
    }

    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    if (body.days_of_history == null) {
      return new Response(
        JSON.stringify({ error: "Missing required field: days_of_history" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders() } }
      );
    }

    const prompt = buildPrompt(body);

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
        max_tokens: 120,
        system: "You are the Mynd & Bodi Institute wellness voice. Observe only — never advise. Never use clinical language. Respond only with the JSON object requested. No preamble. No markdown.",
        messages: [{ role: "user", content: prompt }],
      }),
    });

    if (!claudeResponse.ok) {
      const err = await claudeResponse.text();
      throw new Error(`Claude API error: ${err}`);
    }

    const claudeData = await claudeResponse.json();
    const rawText = (claudeData.content?.[0]?.text ?? "").trim();

    let parsed: { synthesis_text: string };
    try {
      const jsonMatch = rawText.match(/\{[\s\S]*\}/);
      parsed = JSON.parse(jsonMatch?.[0] ?? rawText);
    } catch {
      parsed = {
        synthesis_text: "Your domain scores show variation across the past 30 days. Check each system below for detail.",
      };
    }

    return new Response(
      JSON.stringify({
        success: true,
        synthesis_text: parsed.synthesis_text,
        prompt_version: PROMPT_VERSION,
        model_version: MODEL,
      }),
      { headers: { "Content-Type": "application/json", ...corsHeaders() } }
    );

  } catch (err) {
    console.error("[narrate-domains-30day]", err);
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
