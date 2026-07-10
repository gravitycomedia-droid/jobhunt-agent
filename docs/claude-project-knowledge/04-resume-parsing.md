# Resume Parsing (Brick 2)

## Goal

Turn an uploaded resume PDF into a structured `ResumeProfile` (name, headline,
skills, experience, projects, education) that every downstream feature —
embeddings, matching, tailoring — depends on, without ever inventing content
that isn't actually on the page.

## Flow

1. **Client**: `resume_upload_screen.dart` picks a PDF via `file_picker`, sends
   it as multipart form data to `POST /resume/parse` via `ApiClient.parseResume`.
2. **Server** (`routers/resume.py` → `services/llm.py::parse_resume`):
   - The PDF is converted to page images via `pdf2image.convert_from_bytes`
     (requires the `poppler-utils` system package — this is exactly why the
     server's Dockerfile installs it explicitly, since Render's native Python
     buildpack doesn't include it).
   - The page images are sent to Gemini (`gemini-2.5-flash`, vision-capable) with
     the parser system prompt: *"You are a resume parser. Extract information
     EXACTLY as written. Never infer, embellish, or add skills that are not
     explicitly stated."* Temperature 0.1 (low — this is an extraction task, not
     a generative one).
   - The response is validated against the `ResumeProfile` Pydantic model
     (`server/models/resume.py`): `name`, `headline?`, `skills[]`,
     `experience[]` (`ExperienceItem`), `projects[]` (`ProjectItem`),
     `education[]` (`EducationItem`).
   - On validation failure, one retry with the error appended to the prompt
     (the shared pattern described in
     [03-llm-and-prompts.md](03-llm-and-prompts.md)).
   - The call is logged to `llm_calls` with `profile_id = None` (no profile row
     exists yet at this point — the parse *creates* the first one).
   - Result is upserted into the `profiles` table, and immediately embedded
     (`services/embeddings.py::profile_embedding_text` → `embed_text`) so the
     profile is match-ready right away.
3. **Client review**: the app pushes `ProfileReviewScreen`, which renders every
   parsed field in editable `TextEditingController`s so the human can correct
   any parsing mistake before it's used for anything else. Saves go through
   `PATCH /resume/profile`, which merges edits and re-embeds.

## Why a vision LLM instead of pure text extraction

Resumes have wildly inconsistent layouts (columns, tables, icons-as-bullets)
that plain PDF text extraction (`pypdf`) mangles into unreliable reading order.
Rendering pages as images and using a vision-capable LLM sidesteps that,
at the cost of being slower/more expensive than pure text extraction — an
acceptable tradeoff since resume parsing happens once (or on explicit re-upload),
not on a hot path.

## Guardrail note

Unlike resume *tailoring* (see
[06-resume-tailoring-and-guardrail.md](06-resume-tailoring-and-guardrail.md)),
parsing has no separate deterministic verification step — the anti-fabrication
instruction lives only in the prompt here, because there's no "original" to
fuzzy-match against yet (the parsed output *becomes* the source of truth). The
human-review step in `ProfileReviewScreen` is the safety net for parsing errors.

## Related files

- `server/routers/resume.py`
- `server/services/llm.py::parse_resume`, `PARSE_SYSTEM_PROMPT`
- `server/models/resume.py`
- `server/services/embeddings.py::profile_embedding_text`
- `app/lib/screens/resume_upload_screen.dart`, `profile_review_screen.dart`
- `app/lib/models/resume_profile.dart`
- `docs/PROMPTS.md` (section 1, "Resume Parser")
