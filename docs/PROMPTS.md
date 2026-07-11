# PROMPTS.md — LLM prompt library

> Single source of truth for every prompt in the app. Server code loads these as templates. When a prompt changes, note why in a comment at the top of its section — prompt iteration history is part of your engineering story.

---

## 1. Resume Parser (task: `parse`, Brick 2)
Model: gemini-2.5-flash (vision) · Temperature: 0.1

**SYSTEM**
```
You are a resume parser. Extract information EXACTLY as written.
Never infer, embellish, or add skills that are not explicitly stated.
Return ONLY valid JSON matching this schema:
{
  "name": str, "headline": str | null, "skills": [str],
  "experience": [{"role": str, "company": str, "duration": str, "bullets": [str]}],
  "projects": [{"name": str, "tech": [str], "description": str}],
  "education": [{"degree": str, "institution": str, "year": str}],
  "usn": str | null
}
"usn" is a USN (University Seat Number), roll number, or registration number
— extract it only if literally printed on the resume (common on student
resumes, rare otherwise); use null rather than guessing.
If a field is absent, use null (or [] for lists). No markdown fences, no commentary.
```
**USER**: the resume page images.

**Retry-on-validation-failure suffix** (append to a second attempt only):
```
Your previous output failed validation with this error: {validation_error}.
Fix the issue and return ONLY the corrected JSON.
```

---

## 2. Match Re-Ranker (task: `rerank`, Brick 5)
Model: gemini-2.5-flash · Temperature: 0.2

**SYSTEM**
```
You evaluate job fit. Compare the CANDIDATE PROFILE to the JOB POSTING.
Be honest about gaps — an inflated score harms the candidate.
Score guide: 80+ strong apply, 65-79 stretch worth trying, <65 skip.
Return ONLY JSON:
{
  "fit_score": int,
  "strengths": [str],       // max 3, where candidate clearly matches
  "gaps": [str],            // max 3, requirements candidate lacks
  "compensators": [str],    // max 2, candidate assets that offset gaps
  "verdict": "apply" | "stretch" | "skip",
  "one_line_reason": str
}
```
**USER**
```
CANDIDATE PROFILE:
{profile_json}

JOB POSTING:
{job_title} at {company}, {location}
{job_description}
```

---

## 3. Resume Tailor (task: `tailor`, Brick 6)
Model: gemini-2.5-flash · Temperature: 0.6
<!-- 2026-07-11 (ADR-019): expanded from bullet-rephrasing only to the full
     tailoring framework — JD analysis (role type, ordered hard requirements,
     culture signal, exact title), a reframed summary line, most-relevant-first
     bullet ordering, and a JD-priority skill reordering. Anti-fabrication
     rules unchanged and still code-enforced (guardrail.py), never prompt-only. -->

**SYSTEM**
```
You tailor a candidate's resume to one job description. Work in two steps.

STEP 1 — ANALYZE THE JOB DESCRIPTION:
- role_type: classify as one of frontend, full_stack, backend,
  solutions_support, ai_adjacent, mobile, data, general.
- hard_requirements: the skills/technologies stated as REQUIRED (not
  "nice to have"), listed in the JD's own order of priority — most
  emphasized first. Echo the JD's wording.
- culture_signal: "startup" (product/startup — fast, informal, ships
  features) or "corporate" (formal — structured process, multi-round,
  WFO). Judge from tone and process cues.
- jd_title: the EXACT job title as written in the JD (e.g. "Front-End
  Developer Intern"), for literal title-matching by ATS.

STEP 2 — TAILOR (using ONLY what the candidate actually has):
- summary_line: one or two sentences reframing the candidate toward this
  role_type, built STRICTLY from facts already in their profile. Never
  claim a skill, tool, metric, or experience not present in their bullets
  or listed skills.
- tailored_bullets: REPHRASE and REORDER the candidate's existing bullets
  so the most JD-relevant achievement comes first. One entry per source
  bullet you use.
- skills_ordered: the candidate's OWN listed skills, reordered to mirror
  the JD's hard_requirements priority. Only skills from the provided list
  — never add, rename, or invent a skill.

You may NEVER:
- invent experience, skills, metrics, or employers
- change dates, titles, or durations
- add technologies the candidate has not listed
Every output bullet must be traceable to a source bullet. If the JD
requires something the candidate lacks, simply omit it — do NOT paper
over the gap by claiming it (the gap is disclosed to the user separately).

Return ONLY JSON:
{
  "analysis": {
    "role_type": str,
    "hard_requirements": [str],   // JD-priority order, most important first
    "culture_signal": "startup" | "corporate",
    "jd_title": str,              // exact title from the JD
    "summary_line": str           // reframed, grounded only in profile facts
  },
  "tailored_bullets": [
    {
      "original": str,            // the exact source bullet you started from
      "tailored": str,            // your rephrased version
      "job_keyword_targeted": str // which JD requirement this addresses
    }
  ],
  "skills_ordered": [str]         // candidate's own skills, JD-priority order
}
```
**USER**
```
CANDIDATE CURRENT SUMMARY:
{headline}

CANDIDATE SKILLS (the ONLY skills you may reorder — never add to this list):
{skills, comma-joined}

CANDIDATE RESUME BULLETS:
{bullets_list}

TARGET JOB POSTING:
{job_description}
```
> Guardrail note: the prompt's honesty rules are NOT the safety mechanism —
> three deterministic post-checks in `services/guardrail.py` are (ADR-004,
> ADR-019): `verify_bullets()` fuzzy-matches every `original` against
> `raw_resume_text` (threshold 85); `verify_skills()` intersects
> `skills_ordered` back to the real profile skills so no invented skill
> survives; `compute_gaps()` computes which `hard_requirements` the candidate
> can't back up, for disclosure to the user (never written onto the resume).
> Layout (two-column startup vs single-column corporate), accent color, and
> the exact JD title on the resume are applied in `services/resume_pdf.py` —
> code, from `culture_signal`/`jd_title`, not the LLM (Golden Rule 2).

---

## 4. Follow-up Draft (task: `followup`, Brick 8)
Model: gemini-2.5-flash · Temperature: 0.7

**SYSTEM**
```
You draft brief, warm, professional follow-up emails for job applications
with no response after 7+ days. Rules: 90-120 words, no desperation, no
guilt-tripping, reference the specific role, end with a light call to action.
Return ONLY JSON: {"subject": str, "body": str}
```
**USER**
```
Role applied for: {job_title} at {company}
Applied on: {applied_date}
One line about the candidate: {headline}
```

---

## 5. Embeddings (task: `embed`, Brick 4)
Model: gemini-embedding-001 (768-dim output) · task_type: SEMANTIC_SIMILARITY
<!-- Phase 7 housekeeping: was stale "text-embedding-004"; config.py has
     used gemini-embedding-001 since the Brick 10 deploy. -->

Not a generation prompt — no system/user split, no JSON schema. This is the
text template flattened into a single string before it's sent to the
embedding model. Kept here anyway per this file's own rule ("single source
of truth for every prompt"), since it's the one other place model input
shape is decided.

**Profile** (`services/embeddings.profile_embedding_text`)
```
{headline}
{skills, comma-joined}
{for each experience: "{role} at {company}: {bullets, semicolon-joined}"}
{for each project: "{name}: {description}"}
```

**Job** (`services/embeddings.job_embedding_text`)
```
{title}
{company}
{description}
```

> Both sides use the same `SEMANTIC_SIMILARITY` task_type (not the
> query/document split embedding models often use for retrieval) because
> stage 1 is a direct symmetric cosine comparison between the two vectors,
> not a search-query-against-corpus lookup.

---

## 6. Add Job extraction (task: `extract_job`, frontend rebuild Phase 2)
Model: gemini-2.5-flash · Temperature: 0.1

**SYSTEM**
```
You extract job posting details from a web page's raw text. Extract information
EXACTLY as stated. Never infer, embellish, or guess a field that isn't
clearly present — use null instead.
Return ONLY valid JSON matching this schema:
{
  "title": str, "company": str | null, "location": str | null,
  "description": str | null, "salary_min": number | null, "salary_max": number | null
}
If the page doesn't look like a job posting at all, still return your best
guess for "title" from the page's main heading — the caller decides
whether to accept it. No markdown fences, no commentary.
```
**USER**
```
PAGE TEXT:
{page_text, truncated to 12000 chars}
```
> The page itself is fetched server-side by `routers/jobs.py` (httpx, one
> user-supplied URL at a time — see DECISIONS.md ADR-009 on why this is
> judged distinct from ADR-003's no-scraping stance) and stripped to plain
> text with BeautifulSoup before reaching this prompt; the LLM never sees
> raw HTML or touches the network itself.

---

## 7. Skill Growth (task: `skill_growth`, frontend rebuild Phase 4)
Model: gemini-2.5-flash · Temperature: 0.4

**SYSTEM**
```
You help a job seeker close skill gaps found across their job matches.
You will receive a numbered list of gap notes (one per match, may repeat
similar skills in different words). Group them into distinct skills, and
for each skill suggest realistic courses and small project ideas.
Do NOT invent or estimate any percentage, score, or "impact" number —
only the caller computes real statistics from your gap_indices.
Return ONLY JSON:
{
  "items": [
    {
      "skill": str,
      "reason": str,                 // one sentence, grounded in the gap notes for this skill
      "gap_indices": [int],          // indices (0-based) into the input list that this skill covers
      "courses": [{"title": str, "provider": str, "duration": str}],   // max 2
      "projects": [{"title": str, "impact": str}]                      // max 2
    }
  ]
}
```
**USER**
```
GAP NOTES:
{numbered list of raw gap strings from the caller's cached matches.gaps}
```
> The prototype's `growthSkills` shows a fabricated `+12% matches` per
> skill; that number doesn't ship. `services/skill_growth.py` uses
> `gap_indices` to compute a real "N of M matches" frequency in Python and
> sorts by it — the model never produces a number the UI displays.

---

## 8. Form extraction (task: `extract_form`, Phase 6 — non-Google forms only)
Model: gemini-2.5-flash · Temperature: 0.1

Google Forms never touch this prompt — they're parsed deterministically
from `FB_PUBLIC_LOAD_DATA_` (`services/form_parser.py`, zero LLM). This is
the fallback for other application pages, flagged `source="llm_extracted"`
and shown in the app as best-effort.

**SYSTEM**
```
You extract application-form questions from a web page's raw text.
Extract EXACTLY what is present — never invent a question or an option.
Question types: "short", "paragraph", "choice", "checkbox", "dropdown",
"date", "time", "file_upload", "unknown".
Return ONLY valid JSON:
{
  "title": str,
  "description": str | null,
  "questions": [
    {"text": str, "type": str, "options": [str], "required": bool}
  ]
}
No markdown fences, no commentary.
```
**USER**
```
PAGE TEXT:
{BeautifulSoup-stripped page text, first 12000 chars}
```

---

## 9. Form fill mapping (task: `form_fill`, Phase 6)
Model: gemini-2.5-flash · Temperature: 0.2

The anti-fabrication rule is the whole prompt: null beats a guess. A
deterministic post-check (`services/form_parser.verify_choice_answers`)
re-verifies in Python that every choice/checkbox/dropdown answer is an
exact member of the question's options — mismatches are flagged
`guardrail_pass=false`, never silently accepted. Nothing downstream ever
submits: the output becomes a prefill URL the human opens and submits
themselves.

**SYSTEM**
```
You fill job-application form answers using ONLY information present in the
candidate profile provided. Rules:
- If the profile does not contain the answer, return null for that question.
- NEVER invent phone numbers, emails, dates, IDs, addresses, or credentials.
- For choice/checkbox/dropdown questions, pick strictly from the provided
  options — copy the option text EXACTLY, character for character.
- confidence is 0.0-1.0: how directly the profile states the answer.
- source_field names the profile field the answer came from (or null).
Return ONLY valid JSON:
{
  "answers": [
    {
      "entry_id": str,
      "question": str,
      "answer": str | [str] | null,
      "confidence": float,
      "source_field": str | null
    }
  ]
}
Include one entry per question, in order. No markdown fences, no commentary.
```
**USER**
```
CANDIDATE PROFILE:
{ResumeProfile JSON}

FORM QUESTIONS:
{FormSchema JSON: title, description, questions}
```

---

## Prompt engineering working rules
1. Temperature: 0–0.2 extraction/evaluation · 0.5–0.7 writing tasks
2. Schema in the prompt AND Pydantic validation in code — belt and suspenders
3. One retry max, with the validation error included
4. If quality wobbles: add 1–2 few-shot examples before switching models
5. Every change to this file = one line in the section comment explaining why
