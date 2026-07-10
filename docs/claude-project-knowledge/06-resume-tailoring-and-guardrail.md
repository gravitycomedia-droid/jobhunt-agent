# Resume Tailoring & the Anti-Fabrication Guardrail (Brick 6)

This is the single most safety-critical feature in the project — see Golden
Rule 4 in [00-overview.md](00-overview.md) and ADR-004 in
[08-decisions-log.md](08-decisions-log.md). Read this file before touching
anything under `services/guardrail.py`, `services/llm.py::tailor_resume`, or
the resume diff/preview screens.

## The problem it solves

An LLM asked to "tailor a resume for this job" will, left unchecked, invent
metrics, skills, and phrasing that make the candidate look better but aren't
true. That's not just a UX bug — it's a trust and integrity failure that could
get a real person in trouble in a real interview. The project's answer is:
**never trust the LLM's own promise not to fabricate — verify it deterministically,
in code, every time.**

## Flow

1. **Trigger**: `POST /tailor/{job_id}` (`routers/tailor.py`), called when the
   user taps "Tailor for this job" from a match card.
2. **Generation** (`services/llm.py::tailor_resume`): the candidate's existing
   resume bullets + the job description go to Gemini with `TAILOR_SYSTEM_PROMPT`:
   > "You may REPHRASE, REORDER, and EMPHASIZE existing content... You may
   > NEVER: invent experience, skills, metrics, or employers / change dates,
   > titles, or durations / add technologies the candidate has not listed.
   > Every output bullet must be traceable to a source bullet."

   Temperature 0.6 (higher than parsing/extraction — this is a legitimately
   generative rephrasing task, not pure extraction). Output is validated
   against `TailorLlmResponse` → `TailoredBullet[]`, each with `original`,
   `tailored`, and `job_keyword_targeted`.

   The prompt comment in the code is explicit that **this prompt is not the
   safety mechanism** — it's a best-effort instruction, immediately followed
   by a deterministic check.

3. **Deterministic verification** (`services/guardrail.py`):
   - `GUARDRAIL_THRESHOLD = 85`.
   - `verify_bullet(bullet, raw_resume_text)` uses `rapidfuzz.fuzz.
     partial_ratio` (not the stricter `ratio`) to check that the bullet's
     `original` field is a fuzzy substring match somewhere in the candidate's
     full raw resume text.
   - `verify_bullets(...)` runs every tailored bullet through this check and
     returns `[{original, tailored, keyword, guardrail_pass}]`.
   - This runs **after** the LLM call, in plain Python, with no LLM involved —
     it is the actual enforcement layer, not a formality.
4. **Storage**: the tailoring result (with `guardrail_pass` per bullet) is
   stored in `tailored_resumes`, unapproved.
5. **Human review** (`resume_diff_screen.dart`): renders a bullet-by-bullet diff
   of tailored vs. original text. Bullets that failed the guardrail are
   visually flagged (highlighted) — the user can accept or reject each bullet
   individually.
6. **Approval** (`PATCH /tailor/{tailored_resume_id}/approve`): takes a
   per-bullet `accepted: list[bool]` (added during the frontend rebuild's Phase
   2, per ADR-009) so the human's accept/reject choices are recorded, not just
   a blanket approve/reject.
7. **Compilation & submission**: `resume_generating_screen.dart` (a short,
   server-call-free transitional screen) → `resume_preview_screen.dart`, which
   compiles the approved bullets into a preview and, on "Submit application,"
   saves it into the Kanban tracker (`applications`) linked to that specific
   tailored resume version. This is the actual human-approval submission
   action referenced throughout the project rules — the app never submits
   anything anywhere on its own.

## Why `partial_ratio` and threshold 85 specifically

`partial_ratio` finds the best-matching substring rather than requiring the
whole strings to be similar in length — appropriate here because a tailored
bullet is often shorter or reordered relative to the original, and the check
cares whether the *content* still traces back, not whether the two strings are
near-identical overall. 85 was chosen empirically as a threshold that catches
real fabrication (numbers/skills that don't exist anywhere in the original
text) without generating false positives on legitimate rephrasing.

## Related files

- `server/routers/tailor.py`
- `server/services/llm.py::tailor_resume`, `TAILOR_SYSTEM_PROMPT`
- `server/services/guardrail.py`
- `server/models/tailor.py`
- `server/db/migrations/001_core_schema.sql` (`tailored_resumes` table)
- `app/lib/screens/resume_diff_screen.dart`, `resume_generating_screen.dart`, `resume_preview_screen.dart`
- `app/lib/models/tailored_resume.dart`
- `server/tests/test_guardrail.py`
- `docs/PROMPTS.md` (section 3, "Resume Tailor")
