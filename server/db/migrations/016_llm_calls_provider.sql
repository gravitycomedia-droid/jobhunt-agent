-- ============================================
-- Job-Hunt Agent — Migration 016: record WHICH provider served each LLM call
-- (Phase 14 / ADR-023 — DeepSeek added alongside Gemini)
-- Run in Supabase SQL Editor (Dashboard → SQL).
-- ============================================

-- llm_calls has always assumed Gemini: `model` alone was enough to identify a
-- call, because there was only ever one provider behind it. With DeepSeek
-- serving rerank/extract/followup/skill-growth (ADR-023), the provider is now
-- an independent dimension — GET /stats/costs splits spend by it, and it's how
-- a silent Gemini fallback (DEEPSEEK_API_KEY missing in prod) becomes VISIBLE
-- rather than just quietly costing more.
--
-- Default 'gemini' backfills every existing row correctly: every call logged
-- before this migration was, by construction, a Gemini call.
alter table llm_calls
  add column if not exists provider text not null default 'gemini';

-- Explicit backfill for clarity. The column default already covers existing
-- rows, so this is a no-op on a fresh apply — it's here so the intent survives
-- if the default is ever dropped.
update llm_calls set provider = 'gemini' where provider is null;

create index if not exists llm_calls_provider_idx on llm_calls(provider);
