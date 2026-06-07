-- Statement-derived account identity, kept on the account so it's all in one
-- place: the CLABE (18-digit Mexican interbank account number, the thing users
-- copy to receive transfers) and the account holder's name. Populated when a
-- manual account is created from a parsed statement; null otherwise.
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS clabe TEXT;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS holder_name TEXT;
