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
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (
    HRFlowable,
    KeepInFrame,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)
from reportlab.platypus.doctemplate import LayoutError
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
        # Centered, oversized name over a centered contact line — the classic
        # one-page résumé header (see the reference layout this was built to).
        "name": ParagraphStyle(
            "name", parent=body, fontName="Helvetica-Bold", fontSize=20 * scale, leading=23 * scale,
            textColor=accent, alignment=TA_CENTER, spaceAfter=2,
        ),
        "contact": ParagraphStyle(
            "contact", parent=body, fontSize=9 * scale, leading=12 * scale,
            alignment=TA_CENTER, spaceAfter=2,
        ),
        "title": ParagraphStyle(
            "title", parent=body, fontSize=11 * scale, leading=14 * scale, alignment=TA_CENTER, spaceAfter=6
        ),
        "headline": ParagraphStyle("headline", parent=body, fontSize=10.5 * scale, spaceAfter=6),
        "section": ParagraphStyle(
            "section", parent=body, fontName="Helvetica-Bold", fontSize=11 * scale, leading=14 * scale,
            textColor=accent, spaceBefore=10 * scale, spaceAfter=3,
        ),
        "entry": ParagraphStyle("entry", parent=body, fontName="Helvetica-Bold", spaceBefore=5 * scale),
        "bullet": ParagraphStyle("bullet", parent=body, leftIndent=14, bulletIndent=4),
    }


def _accepted(b: dict) -> bool:
    """Whether to use the TAILORED text (vs the original). Missing `accepted`
    (pre-approval rows) falls back to guardrail_pass, matching the approve
    endpoint's default."""
    return bool(b.get("accepted", b.get("guardrail_pass", False)))


def _on_resume(b: dict) -> bool:
    """Whether the bullet appears on the résumé at all. A SELECTED bullet (R2)
    always does — 'keep original' means use its original text, not drop it. A
    TRIMMED bullet only appears once restored (accepted flipped true). Legacy
    rows have no `selected` key and default to on-résumé, preserving the old
    all-bullets-render behaviour."""
    return bool(b.get("selected", True)) or _accepted(b)


def _bullet_text(b: dict) -> str:
    return b["tailored"] if _accepted(b) else b["original"]


def compile_final_bullets(bullets: list[dict]) -> list[str]:
    """The per-bullet human decision, resolved: accepted → tailored text,
    rejected → original. Missing `accepted` (pre-approval rows) falls back
    to guardrail_pass, matching PATCH /tailor/{id}/approve's default."""
    return [_bullet_text(b) for b in bullets]


def _tailored_experiences(experience: list[dict], bullets: list[dict]) -> list[dict]:
    """Rebuild the experience list with tailored text. ADR-034 (R2): when the
    bullets carry `experience_index` they were section-SELECTED, so regroup them
    under their real role, ordered by relevance, and DROP any role left with no
    included bullets (the trims never render). Rows without `experience_index`
    (legacy / bare-list callers) fall back to the old positional 1:1 slotting."""
    if not any("experience_index" in b for b in bullets):
        return _replace_experience_bullets(experience, compile_final_bullets(bullets))

    out: list[dict] = []
    for ei, exp in enumerate(experience):
        chosen = [b for b in bullets if b.get("experience_index") == ei and _on_resume(b)]
        # Best-first within the role; original order breaks ties deterministically.
        chosen.sort(key=lambda b: -(b.get("relevance") or 0.0))
        texts = [_bullet_text(b) for b in chosen]
        if texts:  # a role with every bullet trimmed simply drops off the résumé
            out.append({**exp, "bullets": texts})
    return out


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


def _section(label: str, st: dict, accent: HexColor) -> list:
    """A section heading and the hairline rule under it — the visual spine of a
    one-page résumé. ATS-safe: the rule is a vector line, so the heading itself
    stays plain extractable text."""
    return [
        _p(label, st["section"]),
        HRFlowable(width="100%", thickness=0.6, color=accent, spaceBefore=1, spaceAfter=4),
    ]


# Only these schemes ever reach a clickable PDF annotation. The contact URLs are
# hand-typed in Settings, so "whatever the user pasted" is untrusted input —
# `javascript:` / `file:` must never be turned into a link a recruiter can click.
_SAFE_SCHEMES = ("http://", "https://", "mailto:", "tel:")


def _link(raw: str, href: str | None = None) -> str | None:
    """One contact item as escaped ReportLab inline markup.

    Returns the display text as a clickable, underlined link, or plain escaped
    text when the target isn't a safe URL. `href` overrides the target (used for
    mailto:/tel:, where what's displayed isn't what's linked)."""
    raw = (raw or "").strip()
    if not raw:
        return None
    target = (href or raw).strip()
    lowered = target.lower()
    if not lowered.startswith(_SAFE_SCHEMES):
        # A bare "linkedin.com/in/jane" is the normal way people write these —
        # assume https. Anything with some OTHER scheme is dropped to plain text.
        if "://" in lowered or lowered.startswith("javascript:") or ":" in lowered.split("/")[0]:
            return escape(raw)
        target = f"https://{target}"
    # Display bare: no scheme, no www., no trailing slash — "linkedin.com/in/jane".
    shown = raw
    for prefix in ("https://", "http://"):
        if shown.lower().startswith(prefix):
            shown = shown[len(prefix):]
    if shown.lower().startswith("www."):
        shown = shown[4:]
    shown = shown.rstrip("/")
    return f'<link href="{escape(target, {chr(34): "&quot;"})}"><u>{escape(shown)}</u></link>'


def contact_line(profile: dict) -> str:
    """The " · "-separated contact block under the name: phone, email, LinkedIn,
    GitHub, personal site, location — each one omitted entirely when the profile
    doesn't have it, so a sparse profile renders a short line rather than empty
    labels. Returns ReportLab inline markup (already escaped)."""
    phone = (profile.get("phone") or "").strip()
    email = (profile.get("email") or "").strip()
    parts = [
        _link(phone, href=f"tel:{phone.replace(' ', '')}") if phone else None,
        _link(email, href=f"mailto:{email}") if email else None,
        _link(profile.get("linkedin_url") or ""),
        _link(profile.get("github_url") or ""),
        _link(profile.get("website_url") or ""),
        escape(profile["location"].strip()) if (profile.get("location") or "").strip() else None,
    ]
    return " &nbsp;|&nbsp; ".join(p for p in parts if p)


def _skills_flowables(skills: list[str], st: dict, accent: HexColor) -> list:
    if not skills:
        return []
    return _section("SKILLS", st, accent) + [_p(", ".join(skills), st["body"])]


def _experience_flowables(experience: list[dict], st: dict, accent: HexColor) -> list:
    if not experience:
        return []
    out = _section("EXPERIENCE", st, accent)
    for exp in experience:
        title_bits = [exp.get("role") or "", exp.get("company") or ""]
        title = " — ".join(bit for bit in title_bits if bit)
        duration = exp.get("duration")
        out.append(_p(f"{title} ({duration})" if duration else title, st["entry"]))
        for bullet in exp.get("bullets") or []:
            out.append(Paragraph(escape(bullet), st["bullet"], bulletText="•"))
    return out


def _projects_flowables(projects: list[dict], st: dict, accent: HexColor) -> list:
    if not projects:
        return []
    out = _section("PROJECTS", st, accent)
    for proj in projects:
        tech = ", ".join(proj.get("tech") or [])
        name = proj.get("name") or ""
        out.append(_p(f"{name} ({tech})" if tech else name, st["entry"]))
        if proj.get("description"):
            out.append(_p(proj["description"], st["body"]))
    return out


def _education_flowables(education: list[dict], st: dict, accent: HexColor) -> list:
    if not education:
        return []
    out = _section("EDUCATION", st, accent)
    for ed in education:
        bits = [ed.get("degree") or "", ed.get("institution") or "", ed.get("year") or ""]
        out.append(_p(" — ".join(bit for bit in bits if bit), st["body"]))
    return out


def _summary_flowables(summary: str, st: dict, accent: HexColor) -> list:
    if not summary:
        return []
    return _section("SUMMARY", st, accent) + [_p(summary, st["headline"])]


def _header_flowables(profile: dict, jd_title: str, st: dict) -> list:
    """Centered name, the JD title, then the contact line — phone, email,
    LinkedIn, GitHub, personal site and location, each a real clickable link
    (migration 026). A recruiter opening the PDF can reach the candidate from
    the first line; before this, the header carried only the name."""
    out = [_p(profile.get("name") or "", st["name"])]
    # Framework §3.8: the title field mirrors the exact JD title so ATS
    # literal title-matching hits before a human opens the file.
    if jd_title:
        out.append(_p(jd_title, st["title"]))
    contact = contact_line(profile)
    if contact:
        # Already-escaped inline markup (links) — Paragraph directly, not _p.
        out.append(Paragraph(contact, st["contact"]))
    return out


def _single_column_story(profile, jd_title, summary, skills, experience, projects, education, st, accent) -> list:
    story = _header_flowables(profile, jd_title, st)
    story += _summary_flowables(summary, st, accent)
    story += _skills_flowables(skills, st, accent)
    story += _experience_flowables(experience, st, accent)
    story += _projects_flowables(projects, st, accent)
    story += _education_flowables(education, st, accent)
    story.append(Spacer(1, 0.1 * inch))
    return story


def _two_column_story(profile, jd_title, summary, skills, experience, projects, education, st, accent) -> list:
    """Framework §3.2 startup layout: 60/40, left = summary/experience/
    projects, right = skills/education. A single borderless two-cell table —
    no grid, no nesting — so ATS extraction reads the left cell fully, then the
    right cell, keeping the machine-readable text layer coherent."""
    left = (
        _summary_flowables(summary, st, accent)
        + _experience_flowables(experience, st, accent)
        + _projects_flowables(projects, st, accent)
    )
    right = _skills_flowables(skills, st, accent) + _education_flowables(education, st, accent)

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
    return _header_flowables(profile, jd_title, st) + [Spacer(1, 0.06 * inch), table]


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

    experience = _tailored_experiences(profile.get("experience") or [], bullets)
    projects = profile.get("projects") or []
    education = profile.get("education") or []

    name = profile.get("name") or ""
    jd_title = analysis.get("jd_title") or ""
    # Reframed summary if the LLM produced one; else the profile's own headline.
    summary = analysis.get("summary_line") or profile.get("headline") or ""
    # JD-priority skill order (already subset-verified upstream); else profile's.
    skills = analysis.get("skills_ordered") or profile.get("skills") or []
    # Two-column is now the default layout (denser, one-page-friendly, and the
    # look the app markets). The single-column fallback only kicks in for sparse
    # résumés where a 60/40 split would leave a near-empty right rail — i.e. no
    # skills AND no education to fill it. ATS text still extracts left-then-right
    # from the single borderless two-cell table (see module docstring).
    has_right_rail = bool(skills) or bool(education)
    has_left_body = bool(experience) or bool(projects) or bool(summary)
    two_column = has_right_rail and has_left_body

    accent = _accent_for(row.get("job_id"))

    pdf = b""
    for scale in _FIT_SCALES:
        st = _styles(accent, scale)
        builder = _two_column_story if two_column else _single_column_story
        story = builder(profile, jd_title, summary, skills, experience, projects, education, st, accent)
        try:
            pdf, pages = _build(name, name, story, scale)
        except LayoutError:
            # The two-column layout is a single-row table that can't split across
            # pages, so an over-long story raises here instead of flowing to
            # page 2. Shrink a step and retry; the tightest scale wraps the story
            # in a shrink-to-fit KeepInFrame (see _build) so it can never raise.
            continue
        if pages <= 1:
            break
    return pdf
