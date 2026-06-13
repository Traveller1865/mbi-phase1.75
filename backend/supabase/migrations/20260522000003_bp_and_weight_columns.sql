-- Migration: 20260522000003_bp_and_weight_columns.sql
-- Adds blood pressure and weight/body composition columns to daily_inputs.
-- These columns are populated from iHealth (blood pressure) and VeSync (weight/body fat)
-- third-party HealthKit sources. They will be null for Apple Watch-only users.
-- These are NOT wearable discriminator signals — do not include in classifyDataTier().

ALTER TABLE daily_inputs
  ADD COLUMN IF NOT EXISTS blood_pressure_systolic NUMERIC,
  ADD COLUMN IF NOT EXISTS blood_pressure_diastolic NUMERIC,
  ADD COLUMN IF NOT EXISTS weight_lbs NUMERIC,
  ADD COLUMN IF NOT EXISTS body_fat_pct NUMERIC;
