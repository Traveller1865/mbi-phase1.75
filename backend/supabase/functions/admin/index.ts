// backend/supabase/functions/admin/index.ts
// MBI Phase 1 — Admin View Edge Function
// Sprint 7 | All users' scores. No PII exposed. Role-gated.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SB_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders() });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response("Unauthorized", { status: 401 });

    const userToken = authHeader.replace("Bearer ", "");
    const supabaseUser = createClient(SUPABASE_URL, Deno.env.get("SB_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY")!);
    const { data: { user }, error: authErr } = await supabaseUser.auth.getUser(userToken);

    if (authErr || !user) return new Response("Unauthorized", { status: 401 });

    // Verify admin role
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
    const { data: role } = await supabase
      .from("user_roles")
      .select("role")
      .eq("user_id", user.id)
      .single();

    if (role?.role !== "admin") return new Response("Forbidden", { status: 403 });

    // Fetch last 14 days of scores for all users (no PII — display_name only)
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - 14);
    const cutoffStr = cutoff.toISOString().split("T")[0];

    const { data: scores, error: scoresErr } = await supabase
      .from("daily_scores")
      .select(`
        id, user_id, date, chronos_score, score_band,
        d1_autonomic, d2_sleep, d3_activity,
        driver_1, driver_2, fail_state, is_provisional,
        users!inner(display_name)
      `)
      .gte("date", cutoffStr)
      .order("date", { ascending: false });

    if (scoresErr) throw scoresErr;

    // Group by user
    const byUser: Record<string, {
      display_name: string;
      scores: unknown[];
    }> = {};

    for (const row of scores ?? []) {
      const uid = row.user_id;
      if (!byUser[uid]) {
        byUser[uid] = {
          // @ts-ignore — joined field
          display_name: row.users?.display_name ?? "Unknown",
          scores: [],
        };
      }
      const { users: _u, ...scoreData } = row as Record<string, unknown>;
      byUser[uid].scores.push(scoreData);
    }

    return new Response(JSON.stringify({ users: Object.values(byUser) }), {
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    });

  } catch (err) {
    console.error("[admin]", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    });
  }
});

function corsHeaders() {
  return { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type" };
}
