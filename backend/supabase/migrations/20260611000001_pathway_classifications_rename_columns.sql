-- Rename legacy column names in pathway_classifications to canonical names.
-- 'pathway' → 'pathway_key'  (matches ontology spec and PathwayKey type)
-- 'date'    → 'classification_date'  (disambiguates from other date columns)
-- Unique constraint updated to match new names.

ALTER TABLE public.pathway_classifications
  RENAME COLUMN pathway TO pathway_key;

ALTER TABLE public.pathway_classifications
  RENAME COLUMN date TO classification_date;
