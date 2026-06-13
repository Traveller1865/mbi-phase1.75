-- 20260516000002_compute_outcome_windows_cron.sql
-- Registers compute-outcome-windows as a daily cron job via pg_cron + pg_net.
-- Runs at 06:00 UTC daily — after most users' morning syncs have completed.
-- Requires pg_cron and pg_net extensions (enabled in Supabase by default on hosted plans).
--
-- SECRETS: the project URL and service key are read from Supabase Vault, NOT from
-- database GUCs. The original version used current_setting('app.service_role_key'),
-- but that GUC could not be set on Supabase hosted (ALTER DATABASE is superuser-only),
-- so the job never registered. Migrated to Vault (2026-06-13). Prerequisite secrets:
--   SELECT vault.create_secret('https://<project>.supabase.co', 'project_url');
--   SELECT vault.create_secret('<sb_secret_ value>',            'service_role_key');

SELECT cron.schedule(
  'compute-outcome-windows-daily',
  '0 6 * * *',
  $$
    SELECT net.http_post(
      url     := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'project_url')
                 || '/functions/v1/compute-outcome-windows',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key')
      ),
      body    := '{}'::jsonb
    ) AS request_id;
  $$
);
