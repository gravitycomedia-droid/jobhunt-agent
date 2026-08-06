"""Career-ops integration Brick 2 (ADR-056): the pure paragraph-selection
logic in services/cover_letter_pdf.py — the part that decides which
paragraphs make it into the compiled PDF. Doesn't touch ReportLab/Supabase,
so this runs without any of the heavier server dependencies."""

from services.cover_letter_pdf import _accepted, _paragraph_text


def test_accepted_paragraph_included():
    assert _accepted({"accepted": True, "guardrail_pass": True})


def test_rejected_paragraph_excluded_even_if_guardrail_passed():
    # The user can exclude a paragraph they just don't like, independent of
    # whether it was factually fine.
    assert not _accepted({"accepted": False, "guardrail_pass": True})


def test_missing_accepted_falls_back_to_guardrail_pass():
    # Pre-approval rows (accepted key not yet written) — same fallback
    # resume_pdf.py's identically-named helper uses.
    assert _accepted({"guardrail_pass": True})
    assert not _accepted({"guardrail_pass": False})


def test_paragraph_text_drops_rejected_and_empty():
    paragraphs = [
        {"role": "opening", "text": "Dear team,", "accepted": True, "guardrail_pass": True},
        {"role": "body", "text": "A fabricated claim.", "accepted": False, "guardrail_pass": False},
        {"role": "body", "text": "", "accepted": True, "guardrail_pass": True},
        {"role": "closing", "text": "Sincerely, me.", "accepted": True, "guardrail_pass": True},
    ]
    assert _paragraph_text(paragraphs) == ["Dear team,", "Sincerely, me."]


def test_paragraph_text_preserves_stored_order():
    paragraphs = [
        {"role": "opening", "text": "one", "guardrail_pass": True},
        {"role": "body", "text": "two", "guardrail_pass": True},
        {"role": "body", "text": "three", "guardrail_pass": True},
        {"role": "closing", "text": "four", "guardrail_pass": True},
    ]
    assert _paragraph_text(paragraphs) == ["one", "two", "three", "four"]
