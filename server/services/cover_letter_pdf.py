"""Career-ops integration Brick 2 (docs/21-career-ops-integration-plan.md
§1.1, DECISIONS.md ADR-056): compile an approved cover letter into a
one-page PDF.

Deterministic Python only (Golden Rule 2, same posture as resume_pdf.py):
the LLM already produced the language and the guardrail already verified it
upstream — this module only lays text out. No LLM call here, ever.

Reuses resume_pdf.py's accent-color and contact-line logic directly rather
than re-deriving it — same candidate, same "one accent per job id" visual
identity across both documents, and duplicating either would be the two
files silently drifting apart the first time one changes.
"""

from datetime import date
from io import BytesIO
from xml.sax.saxutils import escape

from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import KeepInFrame, Paragraph, SimpleDocTemplate, Spacer
from reportlab.platypus.doctemplate import LayoutError

from services.resume_pdf import _accent_for, contact_line

_LETTER_W, _LETTER_H = LETTER
_MARGIN = 0.85 * inch
_CONTENT_W = _LETTER_W - 2 * _MARGIN
# A cover letter is inherently short (3-6 paragraphs), so unlike
# resume_pdf.py's five-step ladder this only needs a light shrink before the
# KeepInFrame safety net — an over-long draft is a prompt-quality problem to
# fix, not something to design the layout around.
_FIT_SCALES = (1.0, 0.9)


def _styles(accent, scale: float) -> dict[str, ParagraphStyle]:
    body = ParagraphStyle(
        "body", fontName="Helvetica", fontSize=10.5 * scale, leading=15 * scale, alignment=TA_LEFT, spaceAfter=10
    )
    return {
        "body": body,
        "name": ParagraphStyle(
            "name", parent=body, fontName="Helvetica-Bold", fontSize=16 * scale, leading=19 * scale,
            textColor=accent, spaceAfter=2,
        ),
        "contact": ParagraphStyle("contact", parent=body, fontSize=9 * scale, leading=12 * scale, spaceAfter=14),
        "meta": ParagraphStyle("meta", parent=body, fontSize=10 * scale, leading=13 * scale, spaceAfter=4),
    }


def _accepted(p: dict) -> bool:
    """Whether to include this paragraph at all. Missing `accepted`
    (pre-approval rows) falls back to guardrail_pass, matching the approve
    endpoint's default and resume_pdf.py's identically-named helper.

    Unlike a résumé bullet — which always appears, just as either the
    tailored or the original text (resume_pdf.py::_accepted) — a cover
    letter paragraph has no "original" to fall back to: it's generated
    prose about one specific achievement, not a rephrase of something the
    candidate already wrote elsewhere. So "not accepted" here means the
    paragraph is DROPPED from the compiled letter, not swapped for
    alternate text.
    """
    return bool(p.get("accepted", p.get("guardrail_pass", False)))


def _paragraph_text(paragraphs: list[dict]) -> list[str]:
    """`paragraphs` is a cover_letters.paragraphs row (see
    routers/cover_letters.py) — the `text` of every ACCEPTED item, in
    stored order (opening, then each body paragraph, then closing). A
    paragraph the user rejected (or that failed the guardrail and was never
    reviewed) is silently omitted rather than sent with a warning baked in —
    the review screen is where that conversation happens, not the PDF."""
    return [p["text"] for p in paragraphs if _accepted(p) and (p.get("text") or "").strip()]


def compile_cover_letter_pdf(profile: dict, cover_letter: dict, job: dict) -> bytes:
    """`cover_letter` is a cover_letters row; `job` is the jobs row it was
    written for (title/company for the salutation and Re: line)."""
    name = profile.get("name") or ""
    company = job.get("company") or "your team"
    jd_title = job.get("title") or ""
    accent = _accent_for(cover_letter.get("job_id"))
    body_paragraphs = _paragraph_text(cover_letter.get("paragraphs") or [])

    # %-d (no leading zero) is a glibc/macOS extension — safe here since the
    # server always runs in the Linux container this project deploys
    # (server/Dockerfile, ADR-010/014), never on Windows.
    today = date.today().strftime("%B %-d, %Y")

    pdf = b""
    for scale in _FIT_SCALES:
        st = _styles(accent, scale)
        story: list = [Paragraph(escape(name), st["name"])]
        contact = contact_line(profile)
        if contact:
            story.append(Paragraph(contact, st["contact"]))
        else:
            story.append(Spacer(1, 0.1 * inch))

        if today:
            story.append(Paragraph(escape(today), st["meta"]))
        story.append(Paragraph(f"Re: {escape(jd_title)}" if jd_title else "Re: Application", st["meta"]))
        story.append(Paragraph(f"Dear {escape(company)} Hiring Team,", st["meta"]))
        story.append(Spacer(1, 0.05 * inch))

        for text in body_paragraphs:
            story.append(Paragraph(escape(text), st["body"]))

        story.append(Spacer(1, 0.1 * inch))
        story.append(Paragraph("Sincerely,", st["body"]))
        story.append(Paragraph(escape(name), st["body"]))

        buf = BytesIO()
        doc = SimpleDocTemplate(
            buf,
            pagesize=LETTER,
            leftMargin=_MARGIN,
            rightMargin=_MARGIN,
            topMargin=_MARGIN,
            bottomMargin=_MARGIN,
            title=f"{name or 'Candidate'} — Cover Letter",
            author=name or "",
        )
        if scale == _FIT_SCALES[-1]:
            # Safety net, same pattern as resume_pdf.py's tightest scale: an
            # unusually long draft shrinks-to-fit rather than spilling to a
            # second page.
            frame_w = _CONTENT_W
            frame_h = _LETTER_H - 2 * _MARGIN
            story = [KeepInFrame(frame_w, frame_h, story, mode="shrink")]
        try:
            doc.build(story)
        except LayoutError:
            continue
        pdf = buf.getvalue()
        if getattr(doc, "page", 1) <= 1:
            break
    return pdf
