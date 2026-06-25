// backend/supabase/functions/horizon-assist/index.ts
// MBI Phase 1.75 — OI-008 Horizon Assist
//
// Stateless Q&A surface: the user asks about their Horizon pathway patterns and
// receives a plain-language, wellness-only response. Presented from the Escalate
// page (HorizonAssistView). No conversation history, no DB logging — each call
// is a fresh, stateless request.
//
// Hard constraints (non-negotiable — Legal Framework §4.1, mirrors narrate-horizon):
//   - No clinical, diagnostic, or medical language
//   - Never suggest a diagnosis, treatment, or to seek medical care
//   - Wellness-and-awareness framing only
//   - Responses under 150 words
//
// Auth:  verifyCallerOwnsUser (same pattern as narrate / narrate-horizon / score).
// Model: claude-haiku-4-5 — fast + cost-appropriate Haiku tier for a mobile Q&A surface.
//        (OI-008 spec named claude-3-5-haiku-20241022, retired by 2026-06; this is the
//         current Haiku, honouring the spec's "Haiku tier, not Opus/Sonnet" constraint.)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { verifyCallerOwnsUser } from "../../functions/_shared/auth.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const MODEL      = "claude-haiku-4-5-20251001";
const MAX_TOKENS = 400;

// ─────────────────────────────────────────
// REQUEST / SIGNAL CONTRACT
// ─────────────────────────────────────────

interface HorizonSignalPayload {
  pathway: string;
  conditionClass: string | null;
  trajectoryLabel: string | null;
  escalationLevel: number;
  confidenceGate: number;
  daysInPattern: number;
  dbState: string;          // "CALM" | "ELEVATED" | "FLAGGED"
  isActive: boolean;
}

interface HorizonSignalsPayload {
  // Score context
  chronosScore: number;
  scoreBand: string;
  driver1: string | null;
  driver2: string | null;
  zone1: string | null;
  zone2: string | null;
  rangeTrustState: string | null;
  isProvisional: boolean;
  // Pathway signals (null = pathway not active / not in escalation)
  autonomic: HorizonSignalPayload | null;
  sleep: HorizonSignalPayload | null;
  metabolic: HorizonSignalPayload | null;
  // Momentum
  momentumState: string | null;
}

// ─────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}

// Formats one pathway signal into a readable prompt line.
// Active   → "Autonomic: ELEVATED — conditionClass: hrv_suppression, trajectory: declining, level 2, 4 days in pattern"
// Inactive → "Sleep: within baseline range"
function signalLine(label: string, signal: HorizonSignalPayload | null): string {
  if (!signal || !signal.isActive) {
    return `${label}: within baseline range`;
  }
  const condition  = signal.conditionClass ?? "unspecified";
  const trajectory = signal.trajectoryLabel ?? "steady";
  return `${label}: ${signal.dbState} — conditionClass: ${condition}, ` +
    `trajectory: ${trajectory}, level ${signal.escalationLevel}, ` +
    `${signal.daysInPattern} days in pattern`;
}

function buildSignalContext(signals: HorizonSignalsPayload): string {
  return [
    signalLine("Autonomic", signals.autonomic),
    signalLine("Sleep",     signals.sleep),
    signalLine("Metabolic", signals.metabolic),
  ].join("\n");
}

function buildSystemPrompt(signals: HorizonSignalsPayload, question: string): string {
  return `You are Horizon Assist, an AI wellness pattern interpreter for the Chronos app by MBI.

Your role is to help users understand their physiological pattern data in plain, wellness-focused language. You explain what the data shows — never what it means clinically, medically, or diagnostically.

HARD RULES — violating any of these is a failure regardless of response quality:
1. Never use clinical, diagnostic, or medical language. You are not a clinician. This is not a clinical tool.
2. Never suggest, imply, or recommend a diagnosis, treatment, medication, or medical intervention.
3. Never tell a user to seek medical care, see a doctor, or consult a healthcare professional — even if their data is concerning. That framing belongs in a clinical context, not here.
4. Never make definitive statements about the user's health. Use observational language: "your data shows," "your patterns suggest," "Chronos has detected."
5. Never fabricate data. If the signals payload does not contain information relevant to the question, say so plainly.
6. Keep responses under 150 words. This is a mobile Q&A surface, not a report.
7. Always maintain wellness-and-awareness framing. The user is tracking patterns, not being diagnosed.

USER CONTEXT:
- Chronos Resilience Score: ${signals.chronosScore} (${signals.scoreBand})
- Primary driver today: ${signals.driver1 ?? "not identified"}
- Secondary driver today: ${signals.driver2 ?? "not identified"}
- Zone 1: ${signals.zone1 ?? "not computed"}
- Zone 2: ${signals.zone2 ?? "not computed"}
- Baseline trust: ${signals.rangeTrustState ?? "unknown"}
- Score is provisional: ${signals.isProvisional}

ACTIVE PATHWAY SIGNALS:
${buildSignalContext(signals)}

MOMENTUM STATE: ${signals.momentumState ?? "not available"}

The user has asked: "${question}"

Respond in plain English, 2–4 sentences, under 150 words. Do not use bullet points. Do not repeat the question back. Do not start with "I" or "As an AI."`;
}

// ─────────────────────────────────────────
// HANDLER
// ─────────────────────────────────────────

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  try {
    const body = await req.json() as {
      userId?: string;
      question?: string;
      signals?: HorizonSignalsPayload;
    };

    const { userId, question, signals } = body;

    // 1d/1f: missing required fields → 400
    if (!userId || !question || !signals) {
      return jsonResponse(
        { error: "userId, question, and signals are required" },
        400,
      );
    }

    // 1c: caller must own the userId → 401/403 handled inside the helper
    const authErr = await verifyCallerOwnsUser(req, userId);
    if (authErr !== null) return authErr;

    // 1f: missing API key → 500, log warning, never fabricate
    if (!ANTHROPIC_API_KEY) {
      console.warn("[horizon-assist] ANTHROPIC_API_KEY not configured");
      return jsonResponse({ error: "Server not configured for AI responses" }, 500);
    }

    const systemPrompt = buildSystemPrompt(signals, question);

    const claudeResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type":      "application/json",
        "x-api-key":         ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model:      MODEL,
        max_tokens: MAX_TOKENS,
        system:     systemPrompt,
        messages:   [{ role: "user", content: question }],
      }),
    });

    // 1f: Claude API error → 500 with detail, do NOT fabricate a fallback answer
    if (!claudeResponse.ok) {
      const err = await claudeResponse.text();
      console.error("[horizon-assist] Claude API error:", err);
      return jsonResponse({ error: "horizon-assist: Claude API error" }, 500);
    }

    const claudeData = await claudeResponse.json();
    const answer = (claudeData.content?.[0]?.text ?? "").trim();

    if (!answer) {
      return jsonResponse({ error: "horizon-assist: empty response" }, 500);
    }

    return jsonResponse({ answer });

  } catch (err) {
    console.error("[horizon-assist]", err);
    return jsonResponse({ error: String(err) }, 500);
  }
});
