"""Phase 4B: compile an approved tailored resume into an ATS-friendly PDF.

Deterministic Python only (Golden Rule 2 / guardrail check): the bullets
were already LLM-tailored, guardrail-verified, and human-accepted upstream —
this module just assembles text with ReportLab. No LLM call here, ever.

ATS constraints honored: single column, standard font (Helvetica), standard
UPPERCASE section headings, no tables/images/icons/text-in-graphics, real
machine-readable text layer, profile order preserved (parse order is the
resume's own reverse-chronological order).
"""

from io import BytesIO

from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer
from xml.sax.saxutils import escape

_BODY = ParagraphStyle(
    "body", fontName="Helvetica", fontSize=10, leading=13.5, alignment=TA_LEFT, spaceAfter=2
)
_NAME = ParagraphStyle("name", parent=_BODY, fontName="Helvetica-Bold", fontSize=16, leading=19, spaceAfter=1)
_HEADLINE = ParagraphStyle("headline", parent=_BODY, fontSize=10.5, spaceAfter=6)
_SECTION = ParagraphStyle(
    "section", parent=_BODY, fontName="Helvetica-Bold", fontSize=11, leading=14, spaceBefore=10, spaceAfter=3
)
_ENTRY_TITLE = ParagraphStyle("entry", parent=_BODY, fontName="Helvetica-Bold", spaceBefore=5)
_BULLET = ParagraphStyle("bullet", parent=_BODY, leftIndent=14, bulletIndent=4)


def compile_final_bullets(bullets: list[dict]) -> list[str]:
    """The per-bullet human decision, resolved: accepted → tailored text,
    rejected → original. Missing `accepted` (pre-approval rows) falls back
    to guardrail_pass, matching PATCH /tailor/{id}/approve's default."""
    return [
        b["tailored"] if b.get("accepted", b.get("guardrail_pass", False)) else b["original"]
        for b in bullets
    ]


def _replace_experience_bullets(experience: list[dict], final_bullets: list[str]) -> list[dict]:
    """Tailored bullets are a flat list flattened from the experiences in
    order (routers/tailor.py::_flatten_bullets) — walk the experiences and
    re-slot them the same way. Any experience bullets beyond the tailored
    list's length keep their original text."""
    replaced = []
    i = 0
    for exp in experience:
        bullets = list(exp.get("bullets") or [])
        for j in range(len(bullets)):
            if i < len(final_bullets):
                bullets[j] = final_bullets[i]
                i += 1
        replaced.append({**exp, "bullets": bullets})
    return replaced


def _p(text: str, style: ParagraphStyle) -> Paragraph:
    return Paragraph(escape(text), style)


def compile_ats_pdf(profile: dict, tailored_bullets: list[dict]) -> bytes:
    """Assembles profile + human-accepted tailored bullets into PDF bytes."""
    final_bullets = compile_final_bullets(tailored_bullets)
    experience = _replace_experience_bullets(profile.get("experience") or [], final_bullets)

    story = [_p(profile.get("name") or "", _NAME)]

    headline = profile.get("headline")
    if headline:
        story.append(_p("SUMMARY", _SECTION))
        story.append(_p(headline, _HEADLINE))

    skills = profile.get("skills") or []
    if skills:
        story.append(_p("SKILLS", _SECTION))
        story.append(_p(", ".join(skills), _BODY))

    if experience:
        story.append(_p("EXPERIENCE", _SECTION))
        for exp in experience:
            title_bits = [exp.get("role") or "", exp.get("company") or ""]
            title = " — ".join(bit for bit in title_bits if bit)
            duration = exp.get("duration")
            story.append(_p(f"{title} ({duration})" if duration else title, _ENTRY_TITLE))
            for bullet in exp.get("bullets") or []:
                story.append(Paragraph(escape(bullet), _BULLET, bulletText="•"))

    projects = profile.get("projects") or []
    if projects:
        story.append(_p("PROJECTS", _SECTION))
        for proj in projects:
            tech = ", ".join(proj.get("tech") or [])
            name = proj.get("name") or ""
            story.append(_p(f"{name} ({tech})" if tech else name, _ENTRY_TITLE))
            if proj.get("description"):
                story.append(_p(proj["description"], _BODY))

    education = profile.get("education") or []
    if education:
        story.append(_p("EDUCATION", _SECTION))
        for ed in education:
            bits = [ed.get("degree") or "", ed.get("institution") or "", ed.get("year") or ""]
            story.append(_p(" — ".join(bit for bit in bits if bit), _BODY))

    story.append(Spacer(1, 0.1 * inch))

    buf = BytesIO()
    doc = SimpleDocTemplate(
        buf,
        pagesize=LETTER,
        leftMargin=0.75 * inch,
        rightMargin=0.75 * inch,
        topMargin=0.6 * inch,
        bottomMargin=0.6 * inch,
        title=f"{profile.get('name') or 'Resume'} — Resume",
        author=profile.get("name") or "",
    )
    doc.build(story)
    return buf.getvalue()
