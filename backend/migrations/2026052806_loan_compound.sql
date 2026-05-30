-- Phase 3 completion: compound interest type.
--
-- 'compound' interest compounds each period over the term and is paid
-- as a single balloon at maturity (P·(1+i)^n). Distinct from
-- 'amortized', whose declining-balance schedule already compounds but
-- is paid down periodically.
ALTER TABLE loans DROP CONSTRAINT IF EXISTS loans_interest_type_check;
ALTER TABLE loans ADD CONSTRAINT loans_interest_type_check
    CHECK (interest_type IN ('none', 'simple', 'amortized', 'interest_only', 'compound'));
