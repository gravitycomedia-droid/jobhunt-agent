-- ============================================
-- Job-Hunt Agent — Migration 022: subscription + wallet (frontend rebuild v2, Phase 4)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- Two DIFFERENT things that the UI conflates but the code must not:
--
--  * subscription_tier — the ONLY real entitlement. services/entitlements.py
--    reads it; nothing else gates on anything else. Defaults 'pro' so the whole
--    beta is unrestricted until a paid tier ships (DEFAULT_TIER=pro backs this).
--
--  * wallet_balance_paise — COSMETIC telemetry (R-B). It decrements as real LLM
--    spend accrues and resets to ₹200 (20000 paise) on the subscription_period_end
--    rollover, but it is NEVER read in an authorization path. A user at ₹0 keeps
--    full access; the number is a "credits used this period" mirror, not a gate.
--    This is deliberate: "decrement and clamp at zero, then block" would leave
--    every user staring at a permanent false "0 actions left" card.
alter table profiles
  add column if not exists subscription_tier text not null default 'pro'
    check (subscription_tier in ('free', 'pro')),
  -- Free-text lifecycle marker ('active'/'trialing'/'past_due'/...). No CHECK:
  -- whatever a future billing provider stamps here is display-only until real
  -- billing exists, and an over-tight CHECK would reject the provider's vocab.
  add column if not exists subscription_status text not null default 'active',
  -- When the current period ends → when the cosmetic wallet resets (R-B). NULL
  -- for profiles created before this column; /wallet treats NULL as "no reset
  -- scheduled" and never resets on it.
  add column if not exists subscription_period_end timestamptz,
  add column if not exists wallet_balance_paise bigint not null default 20000;

-- Backfill every existing row to the pro/active/₹200 starting state. The column
-- defaults already cover NEW rows and rows added by `add column` inherit the
-- default, so this is belt-and-suspenders for any row a prior partial run left
-- with a NULL (e.g. if a column pre-existed without the default).
update profiles
  set subscription_tier = coalesce(subscription_tier, 'pro'),
      subscription_status = coalesce(subscription_status, 'active'),
      wallet_balance_paise = coalesce(wallet_balance_paise, 20000);
