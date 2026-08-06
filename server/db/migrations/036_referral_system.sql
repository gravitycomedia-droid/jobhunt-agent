-- ============================================
-- Job-Hunt Agent — Migration 036: referral system + match gating (Plan 21, Phase 1)
-- Run in Supabase SQL Editor (Dashboard → SQL).
--
-- NOTE ON NUMBERING: the plan called this "019_referral_system.sql", but 019
-- through 035 were already taken (019_jobs_work_type … 035_offer_reviews). This
-- is 036 — the next free number. Nothing else about the plan changed.
--
-- What this adds:
--   * profiles.referral_code — short shareable code, unique, never null. The
--     DEFAULT does the generating, so EVERY insert path gets one without any
--     Python change (there are two profile-creation sites today and more later;
--     a column default can't be forgotten the way a code path can).
--   * profiles.referred_by_profile_id — who invited this user, one-time-set.
--   * profiles.bonus_match_quota — matches earned on top of BASE_FREE_MATCH_LIMIT.
--   * referrals — the ledger. One row per referred profile, ever.
--
-- This is INDEPENDENT of subscription_tier (migration 022). See the open
-- reconciliation question flagged before Phase 2 — do not assume the two
-- systems compose until that's settled.
-- ============================================

-- --- Columns ------------------------------------------------------------
-- referral_code lands nullable and defaultless FIRST: the generator function
-- below reads profiles.referral_code to check collisions, so the column has to
-- exist before the function, and the function has to exist before it can be a
-- default. Order here is load-bearing.
alter table profiles
  add column if not exists referral_code text,
  add column if not exists referred_by_profile_id uuid references profiles(id),
  -- No upper-bound CHECK here on purpose. The cap is MAX_BONUS_MATCH_QUOTA in
  -- config.py (default 50) and is enforced at grant time; hardcoding 50 in SQL
  -- would silently desync the moment that config value is tuned, and would turn
  -- a config change into a failed migration. The floor is worth pinning, though
  -- — a negative quota has no meaning and could only come from a bug.
  add column if not exists bonus_match_quota int not null default 0
    check (bonus_match_quota >= 0);

-- --- Code generator -----------------------------------------------------
-- 7 chars from a 32-symbol Crockford-style alphabet with I/L/O/U removed, so a
-- code read aloud or typed off a screenshot can't be mangled by 1-vs-I or
-- 0-vs-O. 32^7 ≈ 34 billion — collisions are vanishingly rare, but the loop
-- makes "rare" into "never" rather than leaving it to the unique index to
-- surface as a failed insert in a user's face.
create or replace function generate_referral_code() returns text as $$
declare
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  code text;
  i int;
begin
  loop
    code := '';
    for i in 1..7 loop
      code := code || substr(alphabet, 1 + floor(random() * 32)::int, 1);
    end loop;
    exit when not exists (select 1 from profiles where referral_code = code);
  end loop;
  return code;
end;
$$ language plpgsql volatile;

-- --- Backfill -----------------------------------------------------------
-- Row-at-a-time, deliberately. A single `update profiles set referral_code =
-- generate_referral_code()` would run every collision check against the
-- statement's start snapshot, so codes minted earlier in that same statement
-- are invisible to the ones minted later and two rows can collide. Separate
-- UPDATE statements each get a fresh snapshot, so each generated code sees all
-- the ones before it. Beta-sized tables make the loop's cost irrelevant.
do $$
declare
  r record;
begin
  for r in select id from profiles where referral_code is null loop
    update profiles set referral_code = generate_referral_code() where id = r.id;
  end loop;
end $$;

-- --- Constraints (after backfill, so NOT NULL can actually be satisfied) --
create unique index if not exists profiles_referral_code_key
  on profiles (referral_code);

alter table profiles
  alter column referral_code set default generate_referral_code(),
  alter column referral_code set not null;

-- Self-referral is rejected in the schema, not only in Python — a bug in a
-- future redemption path can't quietly credit someone for inviting themselves.
alter table profiles
  drop constraint if exists profiles_no_self_referral;
alter table profiles
  add constraint profiles_no_self_referral
    check (referred_by_profile_id is null or referred_by_profile_id <> id);

-- --- Referral ledger ----------------------------------------------------
create table if not exists referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_profile_id uuid not null references profiles(id),
  -- UNIQUE is the actual guarantee that a reward is granted once per referred
  -- user. Application logic also checks, but this is what holds under a double
  -- POST /referrals/redeem or a retried request.
  referred_profile_id uuid not null unique references profiles(id),
  created_at timestamptz not null default now(),
  constraint referrals_no_self_referral
    check (referrer_profile_id <> referred_profile_id)
);

-- "Who did I refer, and how many?" is the one read /referrals/me does.
create index if not exists referrals_referrer_idx
  on referrals (referrer_profile_id);
