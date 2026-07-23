# 19 — Résumé Quality Plan

Goal: tailored résumés that read as if a skilled human wrote them, while
fabricating **less** than today, not more.

Runs on its own track. Only touches the frontend at `18-frontend-rebuild-execution.md`
Phase 7.

---

## The diagnosis

Current output is a *lightly reworded* résumé, not a rewritten one. The cause is
not the prompt — it is the guardrail's shape.

`guardrail.py::verify_bullet` runs
`rapidfuzz.partial_ratio(bullet.original, raw_resume_text) >= 85`.

That forces every tailored bullet to stay **lexically** close to the source. But
the distance between an average bullet and an excellent one is almost entirely
rewriting: outcome-first restructuring, cutting hedges, replacing "responsible
for" with a real verb, tightening to one line. All of that lowers the fuzzy
ratio. So the model has learned to make small, safe, timid edits.

Worse, the current check is **weak exactly where it should be strong.** A
fabricated `40%` inside an otherwise-faithful sentence still scores ~87 and
passes. The check is loose on numbers and tight on prose — precisely backwards.

**The fix is not lowering the threshold.** It is changing *what* gets verified.

---

## R1 — Atom-level guardrail (replaces whole-bullet fuzzy matching)

**This modifies Golden Rule 4's mechanism. Its purpose is unchanged and its
strength increases. Requires an ADR before merge.**

Decompose every tailored bullet into **factual atoms**, and verify each atom
against the source résumé exactly. Connecting prose floats free.

| Atom class | Extraction | Match rule |
|---|---|---|
| Numbers & metrics | regex: `\d+(\.\d+)?\s*(%|k|K|M|x|×|hrs?|days?|weeks?|months?|years?)?` | **Exact.** `40%` must appear in source. No fuzz. |
| Technologies & tools | match against a tech lexicon + the profile's `skills[]` | Exact, case-insensitive. |
| Employers, titles | from `profiles.experience[]` structured fields | Exact. |
| Dates & durations | date regex + duration phrases | Exact. |
| Scope claims | verb lexicon: `led`, `owned`, `managed`, `architected`, `mentored` + quantified scope (`3 engineers`, `two teams`) | Must trace to a source scope claim of **equal or greater** strength. Never an upgrade. |

**Rules**
- Every atom in the tailored bullet must be present in the source. One missing atom → bullet flagged, exactly as today.
- Atoms may be **dropped** freely. Dropping is always safe.
- Atoms may never be **added, inflated, or upgraded**. `led` where the source says `contributed to` is a violation even though both are verbs.
- Prose between atoms is unconstrained — that is where the quality gain comes from.

**Net effect:** stricter on facts (catches the `40%` case that passes today),
far looser on phrasing. Better safety *and* better prose from one change.

**Keep** `verify_skills` at 80 unchanged. Keep `compute_gaps` unchanged.

**Acceptance**
- A golden-set test: ≥30 hand-labelled bullets (fabricated / faithful) where atom-level catches every fabrication the current check misses, and flags nothing the current check correctly passes.
- Specifically: a bullet with an invented percentage inside otherwise-faithful text must fail. Today it passes.
- A bullet that is a total rewrite but factually identical must pass. Today it fails.

---

## R2 — Section-level tailoring (selection, not just rephrasing)

The largest quality gap is that we tailor *every* bullet rather than choosing
which experiences and bullets appear at all. Human-quality résumés are
**edited** — the irrelevant is cut.

**Pipeline (Python-first, Golden Rule 2)**
1. **Score** every experience and every bullet for relevance to the JD. Use embedding cosine against the JD text — `embeddings.py` already does this — plus keyword overlap. **Pure Python. No LLM.**
2. **Select** by a deterministic rule: keep experiences above a relevance floor; cap bullets per experience (3–4 for the most relevant, 1–2 for older/less relevant); always keep the most recent role regardless of score.
3. **Order** experiences by recency, bullets by relevance within each experience.
4. **Rephrase** only what survived. This is the existing `tailor_resume` call, now on a smaller, better-chosen set.
5. **Disclose** every drop. `tailored_resumes.gaps` (migration `015`) already exists for this.

**The user must see and be able to reverse every drop.** A dropped experience is
a bigger deal than a reworded bullet, and silent removal would be a trust
failure. The diff screen gains a "Trimmed" section listing what was cut and why,
with a one-tap restore.

**Also tailor the headline.** `profiles.headline` exists and is currently never
touched. It is the first line a human reader sees. Same atom-level guardrail
applies.

**Acceptance**
- For a backend JD, a frontend-heavy experience drops or shrinks; for a frontend JD, the reverse.
- The most recent role never drops.
- Every drop appears in the Trimmed list and is restorable.
- Selection is deterministic: same profile + same JD → same selection, every time.

---

## R3 — Deterministic prose lint (no LLM)

Cheap, fast, catches most of what makes a résumé read amateur. Runs after
generation, before the guardrail.

| Check | Rule |
|---|---|
| Weak openers | Flag `Responsible for`, `Worked on`, `Helped with`, `Assisted in`, `Participated in`, `Involved in` |
| Verb repetition | No leading verb used more than twice across the whole résumé |
| Passive voice | Flag `was/were + past participle` |
| Length | Flag bullets over ~180 chars (≈2 lines at résumé type sizes) |
| Tense consistency | Present tense for the current role, past for all others |
| Filler | Flag `successfully`, `various`, `several`, `numerous`, `effectively` |
| Pronouns | Flag `I`, `my`, `we` — résumé convention |
| Density | Flag any bullet with zero atoms (no metric, tech, or scope claim) |

Lint results feed the R4 critique pass and surface as soft hints in the diff UI.
They **never** block — this is advice, not a gate.

**Acceptance:** pure functions, fully unit-tested, no I/O, no LLM.

---

## R4 — Two-pass generate → critique → revise

Approved despite roughly doubling tokens on the tailoring path.

**Pass 1** — generate, as today, on the R2-selected content.
**Pass 2** — score the draft against an explicit rubric and revise.

Rubric (the model returns a score per axis plus a revised draft):
- **Relevance** — does each bullet speak to this JD?
- **Specificity** — metrics and concrete outcomes over responsibilities?
- **Density** — is every word earning its place?
- **Variety** — verb and structure diversity?
- **Voice** — active, outcome-first, no filler?
- **ATS** — JD keywords present naturally, never stuffed?

R3's lint output is passed into the critique prompt as concrete findings, so the
critique has real signal instead of vibes.

**Cost control**
- Pass 2 runs **only** on résumés where pass 1 produced a lint finding or a low self-score. Clean drafts skip it.
- Both passes log to `llm_calls` under distinct task names (`tailor`, `tailor_critique`) so `GET /stats/costs` shows the true split.
- `tailor_provider` stays Gemini (`config.py:37`). ADR-023's DeepSeek move for tailoring stays gated on a guardrail-pass A/B that has never been recorded — do not flip it as part of this work.

**Acceptance:** on a fixed test JD + profile, the two-pass output scores higher
on the R3 lint than the one-pass output, measured, not asserted. Token cost is
visible in the cost dashboard.

---

## R5 — Metric prompting (ask, never invent)

The honest response to a bullet with no numbers is to **ask the human**, not to
fabricate a plausible figure.

- Where R3 flags zero density and the JD emphasises measurable impact, the diff screen shows an inline prompt: *"This would be stronger with a number — what was the scale?"*
- Free-text answer feeds back into a single-bullet regeneration.
- Answers persist to the **profile**, not just this tailoring run — the user should never be asked the same question twice. New `profiles.metric_answers jsonb`, or extend the existing experience items.
- Optional and skippable. Never blocks approval.

This is the single largest quality lever that stays entirely inside the
guardrail: it adds real facts rather than loosening what counts as one.

**Acceptance:** answering a metric prompt regenerates that bullet with the
number present; the number passes the atom check because it is now genuinely in
the source; a second tailoring run does not re-ask.

---

## R6 — One-page ATS-safe layout

**Always one page.** Both branches, no exceptions.

`resume_pdf.py` already does deterministic one-page fitting. Change **how** it
fits: today it shrinks to fit. It should instead **cut to fit**, using R2's
relevance ranking — drop the lowest-ranked surviving bullet and re-measure, in a
loop. Type size stays in a readable, ATS-safe band.

**ATS constraints (hard)**
- Single column. No tables for layout. No text boxes, headers, or footers.
- Standard section headings: `Experience`, `Education`, `Skills`, `Projects`.
- No graphics, icons, or rules carrying meaning. No colour carrying meaning.
- Embedded, selectable text — never rasterised.
- Standard bullet glyphs.
- Dates in one consistent parseable format.
- Contact details as plain text in the body, never in a header.

**Human-quality constraints**
- Consistent vertical rhythm; no orphaned single-line sections.
- Generous margins — density is not the goal, readability is.
- One accent colour maximum, and only for section rules.

**Acceptance:** output is always exactly one page; text extracts cleanly via
`pypdf` in correct reading order; content is cut by relevance, never shrunk
below the readable band; a two-column layout is never produced.

---

## Execution order

R1 → R3 → R2 → R5 → R4 → R6.

R1 first because everything downstream depends on the new guardrail contract.
R3 before R2 because the lint is what makes selection quality measurable. R4
late because it is the most expensive and benefits from R3's signal. R6 last
because it needs R2's ranking to cut intelligently.

---

## ADRs required

- **ADR-033** — Atom-level guardrail replaces whole-bullet fuzzy matching. Must state plainly: this is a *stricter* factual check and a *looser* prose check, and why that is the correct trade.
- **ADR-034** — Section-level tailoring. Selection is Python; rephrasing is LLM; every drop is disclosed and reversible.
- **ADR-035** — Two-pass critique, its cost, and the conditional-trigger rule.
- **ADR-036** — One-page-always, cut-to-fit rather than shrink-to-fit.

---

## Risks

1. **R1 is a real change to the safety boundary.** The golden-set test is not optional — it is the evidence that the new check is stronger. Do not merge R1 without it.
2. **R2 can drop something the user wanted.** Disclosure and one-tap restore are load-bearing, not polish.
3. **R4 doubles cost on the most expensive path.** The conditional trigger is what keeps it affordable; verify it actually skips clean drafts.
4. **Atom extraction will have false negatives** — an unusual metric format the regex misses becomes an unverified fact. Log every unextractable token for review; err toward flagging.
5. **R5 stores more personal data.** Metric answers are career facts, not sensitive identifiers, but they fall under the same handling as the rest of the profile.
