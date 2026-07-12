"""ADR-026: every upload-safety gate rejects a bad PDF with a clear error
BEFORE any expensive work (render / embed / LLM) happens."""

import io

import pytest

from services import pdf_safety
from services.pdf_safety import (
    MAX_PDF_PAGES,
    MAX_UPLOAD_BYTES,
    PdfSafetyError,
    assert_is_pdf,
    assert_page_count,
    assert_within_size_limit,
    pdf_to_page_images,
)


def _pdf_with_pages(n: int) -> bytes:
    """A minimal-but-real multi-page PDF, built with pypdf so page-tree parsing
    sees exactly `n` pages."""
    from pypdf import PdfWriter

    writer = PdfWriter()
    for _ in range(n):
        writer.add_blank_page(width=200, height=200)
    buf = io.BytesIO()
    writer.write(buf)
    return buf.getvalue()


# --- magic bytes -----------------------------------------------------------


def test_rejects_a_non_pdf_renamed_to_pdf():
    """The whole point: a PNG (or anything) with a .pdf name and an
    application/pdf content-type is still not a PDF."""
    with pytest.raises(PdfSafetyError, match="isn't a PDF"):
        assert_is_pdf(b"\x89PNG\r\n\x1a\n this is really a png")


def test_rejects_empty_upload():
    with pytest.raises(PdfSafetyError, match="empty"):
        assert_is_pdf(b"")


def test_accepts_real_pdf_magic():
    assert_is_pdf(b"%PDF-1.7\n...")  # no raise


# --- size ------------------------------------------------------------------


def test_rejects_oversized_upload():
    oversized = b"%PDF-" + b"\x00" * MAX_UPLOAD_BYTES
    with pytest.raises(PdfSafetyError, match="too large"):
        assert_within_size_limit(oversized)


def test_accepts_normal_sized_upload():
    assert_within_size_limit(b"%PDF-" + b"\x00" * 1000)  # no raise


# --- page count ------------------------------------------------------------


def test_rejects_pdf_over_page_cap():
    too_many = _pdf_with_pages(MAX_PDF_PAGES + 1)
    with pytest.raises(PdfSafetyError, match="pages"):
        assert_page_count(too_many)


def test_accepts_pdf_at_page_cap():
    assert assert_page_count(_pdf_with_pages(MAX_PDF_PAGES)) == MAX_PDF_PAGES


def test_page_count_cap_is_checked_before_rendering(monkeypatch):
    """A 1000-page bomb must be rejected by the page-tree parse, never reaching
    the rasterizer — that's the whole memory-safety argument."""
    rendered = False

    def _boom(*a, **k):
        nonlocal rendered
        rendered = True
        raise AssertionError("render must not be reached for an over-cap PDF")

    monkeypatch.setattr(pdf_safety, "convert_from_bytes", _boom)
    with pytest.raises(PdfSafetyError, match="pages"):
        pdf_to_page_images(_pdf_with_pages(MAX_PDF_PAGES + 5))
    assert rendered is False


def test_corrupt_pdf_body_is_rejected_not_crashed():
    # Valid magic, garbage body — pypdf can't find a page tree.
    with pytest.raises(PdfSafetyError):
        assert_page_count(b"%PDF-1.7\nnot actually a pdf structure")
