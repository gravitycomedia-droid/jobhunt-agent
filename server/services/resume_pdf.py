"""Phase 4B / ADR-019: compile an approved tailored resume into an ATS-friendly
PDF, applying the tailoring framework's formatting rules.

Deterministic Python only (Golden Rule 2 / guardrail check): the LLM already
produced the language (tailored bullets, reframed summary, JD title) and the
guardrail already verified it upstream — every LAYOUT decision here is code:
which layout to use (from the LLM's culture_signal), the accent color (from the
job id), the skill order (already subset-verified), and the one-page auto-fit.
No LLM call here, ever.

ATS constraints honored: standard font (Helvetica), UPPERCASE section headings,
no images/icons/text-in-graphics, a real machine-readable text layer, and — for
the two-column startup layout — a single borderless two-cell table (no grid,
no nesting) so text still extracts left-cell-then-right-cell in order.
"""

import hashlib
from io import BytesIO

from reportlab.lib.colors import HexColor
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (
    KeepInFrame,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)
from xml.sax.saxutils import escape

# Framework §3.7: the accent varies per application purely for human visual
# freshness — it has zero effect on ATS and must never hurt contrast, so every
# entry here is a dark, high-contrast color on white. Picked deterministically
# from the job id so re-compiling the same resume is stable.
_ACCENTS = [
    "#3730A3",  # indigo
    "#0F766E",  # teal
    "#1E3A8A",  # navy
    "#9F1239",  # rose/maroon
    "#166534",  # forest
    "#334155",  # slate
    "#7C2D12",  # sienna
    "#5B21B6",  # violet
]

_LETTER_W, _LETTER_H = LETTER
_MARGIN = 0.6 * inch
_SIDE_MARGIN = 0.7 * inch
_CONTENT_W = _LETTER_W - 2 * _SIDE_MARGIN
# Framework §3.2: 60/40 split, left (profile/experience/projects) wider.
_LEFT_W = _CONTENT_W * 0.60
_RIGHT_W = _CONTENT_W * 0.40
# One-page auto-fit (framework §1): shrink the whole type scale a step at a
# time until the story fits on one page, down to a readability floor.
_FIT_SCALES = (1.0, 0.94, 0.88, 0.82, 0.76)


def _accent_for(job_id: str | None) -> HexColor:
    if not job_id:
        return HexColor(_ACCENTS[0])
    idx = int(hashlib.sha256(job_id.encode()).hexdigest(), 16) % len(_ACCENTS)
    return HexColor(_ACCENTS[idx])


def _styles(accent: HexColor, scale: float) -> dict[str, ParagraphStyle]:
    """All paragraph styles, scaled for the one-page auto-fit. Accent colors
    only the name and section headings — body text stays black for contrast."""
    body = ParagraphStyle(
        "body", fontName="Helvetica", fontSize=10 * scale, leading=13.5 * scale, alignment=TA_LEFT, spaceAfter=2
    )
    return {
        "body": body,
        "name": ParagraphStyle(
            "name", parent=body, fontName="Helvetica-Bold", fontSize=17 * scale, leading=20 * scale,
            textColor=accent, spaceAfter=1,
        ),
        "title": ParagraphStyle("title", parent=body, fontSize=11 * scale, leading=14 * scale, spaceAfter=6),
        "headline": ParagraphStyle("headline", parent=body, fontSize=10.5 * scale, spaceAfter=6),
        "section": ParagraphStyle(
            "section", parent=body, fontName="Helvetica-Bold", fontSize=11 * scale, leading=14 * scale,
            textColor=accent, spaceBefore=10 * scale, spaceAfter=3,
        ),
        "entry": ParagraphStyle("entry", parent=body, fontName="Helvetica-Bold", spaceBefore=5 * scale),
        "bullet": ParagraphStyle("bullet", parent=body, leftIndent=14, bulletIndent=4),
    }


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


def _skills_flowables(skills: list[str], st: dict) -> list:
    if not skills:
        return []
    return [_p("SKILLS", st["section"]), _p(", ".join(skills), st["body"])]


def _experience_flowables(experience: list[dict], st: dict) -> list:
    if not experience:
        return []
    out = [_p("EXPERIENCE", st["section"])]
    for exp in experience:
        title_bits = [exp.get("role") or "", exp.get("company") or ""]
        title = " — ".join(bit for bit in title_bits if bit)
        duration = exp.get("duration")
        out.append(_p(f"{title} ({duration})" if duration else title, st["entry"]))
        for bullet in exp.get("bullets") or []:
            out.append(Paragraph(escape(bullet), st["bullet"], bulletText="•"))
    return out


def _projects_flowables(projects: list[dict], st: dict) -> list:
    if not projects:
        return []
    out = [_p("PROJECTS", st["section"])]
    for proj in projects:
        tech = ", ".join(proj.get("tech") or [])
        name = proj.get("name") or ""
        out.append(_p(f"{name} ({tech})" if tech else name, st["entry"]))
        if proj.get("description"):
            out.append(_p(proj["description"], st["body"]))
    return out


def _education_flowables(education: list[dict], st: dict) -> list:
    if not education:
        return []
    out = [_p("EDUCATION", st["section"])]
    for ed in education:
        bits = [ed.get("degree") or "", ed.get("institution") or "", ed.get("year") or ""]
        out.append(_p(" — ".join(bit for bit in bits if bit), st["body"]))
    return out


def _summary_flowables(summary: str, st: dict) -> list:
    if not summary:
        return []
    return [_p("SUMMARY", st["section"]), _p(summary, st["headline"])]


def _header_flowables(name: str, jd_title: str, st: dict) -> list:
    # Framework §3.8: the title field mirrors the exact JD title so ATS
    # literal title-matching hits before a human opens the file.
    out = [_p(name, st["name"])]
    if jd_title:
        out.append(_p(jd_title, st["title"]))
    return out


def _single_column_story(name, jd_title, summary, skills, experience, projects, education, st) -> list:
    story = _header_flowables(name, jd_title, st)
    story += _summary_flowables(summary, st)
    story += _skills_flowables(skills, st)
    story += _experience_flowables(experience, st)
    story += _projects_flowables(projects, st)
    story += _education_flowables(education, st)
    story.append(Spacer(1, 0.1 * inch))
    return story


def _two_column_story(name, jd_title, summary, skills, experience, projects, education, st) -> list:
    """Framework §3.2 startup layout: 60/40, left = summary/experience/
    projects, right = skills/education. A single borderless two-cell table —
    no grid, no nesting — so ATS extraction reads the left cell fully, then the
    right cell, keeping the machine-readable text layer coherent."""
    left = _summary_flowables(summary, st) + _experience_flowables(experience, st) + _projects_flowables(projects, st)
    right = _skills_flowables(skills, st) + _education_flowables(education, st)

    table = Table(
        [[left, right]],
        colWidths=[_LEFT_W, _RIGHT_W],
    )
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (0, 0), 0),
                ("RIGHTPADDING", (0, 0), (0, 0), 12),
                ("LEFTPADDING", (1, 0), (1, 0), 12),
                ("RIGHTPADDING", (1, 0), (1, 0), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 0),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
            ]
        )
    )
    return _header_flowables(name, jd_title, st) + [Spacer(1, 0.06 * inch), table]


def _build(name, author, story, scale) -> tuple[bytes, int]:
    buf = BytesIO()
    doc = SimpleDocTemplate(
        buf,
        pagesize=LETTER,
        leftMargin=_SIDE_MARGIN,
        rightMargin=_SIDE_MARGIN,
        topMargin=_MARGIN,
        bottomMargin=_MARGIN,
        title=f"{name or 'Resume'} — Resume",
        author=author or "",
    )
    # KeepInFrame at the tightest scale is a safety net so a still-too-long
    # story shrinks-to-fit rather than spilling to page 2.
    if scale == _FIT_SCALES[-1]:
        frame_w = _CONTENT_W
        frame_h = _LETTER_H - 2 * _MARGIN
        story = [KeepInFrame(frame_w, frame_h, story, mode="shrink")]
    doc.build(story)
    return buf.getvalue(), getattr(doc, "page", 1)


def compile_ats_pdf(profile: dict, tailored: dict | list) -> bytes:
    """Assembles profile + human-accepted tailored bullets + JD analysis into
    PDF bytes.

    `tailored` is a tailored_resumes row dict ({bullets, analysis, gaps, ...}).
    A bare list of bullets is still accepted for backward compatibility
    (pre-ADR-019 callers / tests) and renders single-column from the profile's
    own summary and skill order."""
    row = {"bullets": tailored} if isinstance(tailored, list) else tailored
    bullets = row.get("bullets") or []
    analysis = row.get("analysis") or {}

    final_bullets = compile_final_bullets(bullets)
    experience = _replace_experience_bullets(profile.get("experience") or [], final_bullets)
    projects = profile.get("projects") or []
    education = profile.get("education") or []

    name = profile.get("name") or ""
    jd_title = analysis.get("jd_title") or ""
    # Reframed summary if the LLM produced one; else the profile's own headline.
    summary = analysis.get("summary_line") or profile.get("headline") or ""
    # JD-priority skill order (already subset-verified upstream); else profile's.
    skills = analysis.get("skills_ordered") or profile.get("skills") or []
    # Framework §3.3: two-column for startup signal, single-column otherwise
    # (the safest ATS parse, and the default when there's no analysis at all).
    two_column = analysis.get("culture_signal") == "startup"

    accent = _accent_for(row.get("job_id"))

    pdf = b""
    for scale in _FIT_SCALES:
        st = _styles(accent, scale)
        builder = _two_column_story if two_column else _single_column_story
        story = builder(name, jd_title, summary, skills, experience, projects, education, st)
        pdf, pages = _build(name, name, story, scale)
        if pages <= 1:
            break
    return pdf
