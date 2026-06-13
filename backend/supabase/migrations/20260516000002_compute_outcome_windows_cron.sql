-- 20260516000002_compute_outcome_windows_cron.sql
-- Registers compute-outcome-windows as a daily cron job via pg_cron + pg_net.
-- Runs at 06:00 UTC daily — after most users' morning syncs have completed.
-- Requires pg_cron and pg_net extensions (enabled in Supabase by default on hosted plans).

SELECT cron.schedule(
  'compute-outcome-windows-daily',
  '0 6 * * *',
  $$
    SELECT net.http_post(
      url     := current_setting('app.supabase_url') || '/functions/v1/compute-outcome-windows',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || current_setting('app.service_role_key')
      ),
      body    := '{}'::jsonb
    ) AS request_id;
  $$
);
