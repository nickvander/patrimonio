-- Optional explicit "expected repayment date" for a loan.
--
-- Lets even a no-interest, open-ended loan carry a due date (e.g. "pay back
-- by Jul 31") so it shows a countdown in the UI, drives the repayment
-- reminders (the notifications bell), and anchors interest-to-date once a
-- rate is set. term_months/payment_frequency still drive *generated*
-- amortization schedules; this is the schedule-less fallback due date.
ALTER TABLE loans ADD COLUMN IF NOT EXISTS expected_repayment_date DATE;
