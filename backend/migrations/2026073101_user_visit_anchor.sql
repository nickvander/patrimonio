-- "Since your last visit" anchors on a VISIT, not on a login.
--
-- The summary (GET /api/dashboard/since-last-login — the Overview banner and
-- the bell's "N new transactions" / "largest move" rows) anchored on
-- `users.previous_login_at`, which only moves when the user actually
-- authenticates. On a phone that stays signed in for weeks, that is not "your
-- last visit" by any reading: a user opening the app daily since Jul 13 was
-- still shown "143 new transactions since your last visit · Jul 13".
--
-- Two additive columns turn the anchor into what the copy already claims:
--
-- * last_visit_at     — the most recent time we saw this user look at the
--                       dashboard.
-- * previous_visit_at — when the visit BEFORE this one ended. This is the
--                       anchor the summary is computed against.
--
-- The handler rolls them in one statement: if the last visit was more than
-- the visit gap ago, this is a new visit, so the old `last_visit_at` becomes
-- the anchor. Within a visit the anchor holds still, so reloading the
-- dashboard doesn't erase the summary you were reading.
--
-- `previous_login_at` stays exactly as it is — it still backs the security
-- screen's "new since last visit" session flag, and it remains the fallback
-- anchor for a user with no recorded visit yet (which keeps a first-ever
-- session suppressed rather than showing "0 since never").

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS last_visit_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS previous_visit_at TIMESTAMPTZ;

-- Seed both from the best evidence of real activity we already keep:
-- `user_sessions.last_seen_at` is bumped (throttled to once a minute) on
-- every authenticated request, so its max is genuinely "when this user was
-- last using the app" — far closer to the truth than last_login_at.
--
-- Both columns get that same instant, which starts every existing user's
-- anchor at "you were last here just now": the first post-upgrade load
-- reports nothing new (the banner hides itself when it has nothing to say)
-- and every visit after that is measured honestly. Seeding the anchor from
-- previous_login_at instead would have replayed the very staleness this
-- migration exists to end.
--
-- GREATEST ignores NULL arguments in Postgres, so a user with no sessions
-- falls back to last_login_at, and one with neither is left NULL — no
-- anchor, no banner, same as a brand-new account.
WITH activity AS (
    SELECT u.id,
           GREATEST(
               u.last_login_at,
               (SELECT MAX(s.last_seen_at)
                  FROM user_sessions s
                 WHERE s.user_id = u.id)
           ) AS last_active_at
      FROM users u
)
UPDATE users u
   SET last_visit_at = a.last_active_at,
       previous_visit_at = a.last_active_at
  FROM activity a
 WHERE a.id = u.id
   AND a.last_active_at IS NOT NULL
   AND u.last_visit_at IS NULL;
