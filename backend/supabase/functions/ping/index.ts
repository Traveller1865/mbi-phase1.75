// backend/supabase/functions/ping/index.ts
// MBI Pipeline Performance — Keep-Warm Ping
// Spec: MBI_Chronos_BuildHandoff_PipelinePerformance_v1_0.docx §3
//
// Lightweight endpoint called by the keep-warm cron every 30 minutes.
// No database reads or writes. No Supabase client initialization.
// Returns HTTP 200 with { status: 'warm', ts } within ~5ms.
//
// Also serves as the single ping target once score-orchestrator is the
// pipeline entry point — a warm orchestrator implies warm downstream functions.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

serve((req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  return new Response(
    JSON.stringify({ status: "warm", ts: new Date().toISOString() }),
    {
      status: 200,
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    },
  );
});

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}
