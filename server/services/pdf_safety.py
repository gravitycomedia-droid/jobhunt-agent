"""Phase 14 / ADR-026: bounds on an uploaded resume PDF before it reaches
pdf2image, pypdf, or an LLM.

The threat here is NOT code execution. That was measured, not assumed (see
ADR-026 and the note on _render_pages below): poppler's pdftoppm — the binary
pdf2image shells out to — has no JavaScript engine linked at all, and it
ignores /OpenAction, /AA and /Launch entirely, because it is a rasterizer and
nothing else. A PDF carrying a JS payload and a /Launch action renders as a
blank page and does nothing.

The real threat is RESOURCE exhaustion, and it's cheap to trigger: a 2KB
"zip-bomb"-shaped PDF can declare thousands of pages, and pdf2image will
happily try to rasterize every one of them at 200 DPI into RAM. On a Cloud Run
instance with a hard memory cap, that's an OOM kill — one request taking down
the container for everyone. So: cap the bytes, cap the pages, cap the wall
clock, and check the file is really a PDF before poppler ever sees it.
"""

import io

from pdf2image import convert_from_bytes
from pdf2image.exceptions import PDFPageCountError, PDFPopplerTimeoutError, PDFSyntaxError
from pypdf import PdfReader
from pypdf.errors import PdfReadError

# A text-based resume is tens of KB; a heavily-designed one with embedded
# imagery might reach 2-3MB. 10MB is far past any honest resume and still small
# enough that buffering it can't hurt.
MAX_UPLOAD_BYTES = 10 * 1024 * 1024

# Nobody's resume is 20 pages. This is the cap that actually stops the
# rasterization bomb — bytes alone don't, because page count is declared, not
# proportional to file size.
MAX_PDF_PAGES = 20

# Wall-clock ceiling on poppler. A malformed (not necessarily malicious) PDF can
# send pdftoppm into a pathological path; without this the request just hangs,
# holding a worker until the platform's own timeout kills it.
PDF_RENDER_TIMEOUT_SECONDS = 60

# Every PDF starts with this. The client's declared content-type and the
# filename extension are both attacker-controlled and prove nothing.
_PDF_MAGIC = b"%PDF-"


class PdfSafetyError(Exception):
    """The upload isn't a PDF we're willing to process. Always a 4xx to the
    caller — it's the user's file that's wrong, not our server."""


def assert_is_pdf(data: bytes) -> None:
    """Magic-byte check. `file.content_type == "application/pdf"` is a claim the
    client makes about itself, and `.pdf` is just the end of a string — neither
    is evidence. This is."""
    if not data:
        raise PdfSafetyError("That file was empty")
    if not data.startswith(_PDF_MAGIC):
        raise PdfSafetyError("That file isn't a PDF (its contents don't start with %PDF-)")


def assert_within_size_limit(data: bytes) -> None:
    if len(data) > MAX_UPLOAD_BYTES:
        mb = MAX_UPLOAD_BYTES // (1024 * 1024)
        raise PdfSafetyError(f"That PDF is too large — the limit is {mb}MB")


def count_pages(data: bytes) -> int:
    """Page count via pypdf, which only parses the page tree — it does NOT
    rasterize. That's the point: we learn how expensive the render WOULD be
    before paying for it."""
    try:
        return len(PdfReader(io.BytesIO(data)).pages)
    except (PdfReadError, ValueError, OSError) as e:
        raise PdfSafetyError(f"That PDF looks corrupted and couldn't be read: {e}") from e


def assert_page_count(data: bytes) -> int:
    pages = count_pages(data)
    if pages == 0:
        raise PdfSafetyError("That PDF has no pages")
    if pages > MAX_PDF_PAGES:
        raise PdfSafetyError(f"That PDF has {pages} pages — the limit is {MAX_PDF_PAGES}. Upload a resume, not a book.")
    return pages


def _render_pages(data: bytes) -> list[bytes]:
    """Rasterize to PNG bytes, one per page, under a hard timeout.

    pdf2image's own `timeout` is used rather than a thread + future.result():
    poppler runs in a SUBPROCESS, and a Python-side timeout would return control
    while pdftoppm kept chewing CPU in the background. pdf2image's timeout kills
    the process group, which is the only thing that actually stops the work.
    """
    try:
        pages = convert_from_bytes(data, timeout=PDF_RENDER_TIMEOUT_SECONDS)
    except PDFPopplerTimeoutError as e:
        raise PdfSafetyError("That PDF took too long to process — try a simpler or smaller file") from e
    except (PDFSyntaxError, PDFPageCountError) as e:
        raise PdfSafetyError(f"That PDF couldn't be rendered: {e}") from e

    images = []
    for page in pages:
        buf = io.BytesIO()
        page.save(buf, format="PNG")
        images.append(buf.getvalue())
    return images


def pdf_to_page_images(data: bytes) -> list[bytes]:
    """The one entry point routers should call: every check, in the order that
    makes the cheap ones reject first.

    Ordering is deliberate — magic bytes (a memcmp) before size (a len) before
    page count (a page-tree parse) before rendering (a subprocess per page).
    A hostile upload is rejected at the cheapest stage that can catch it, and
    NOTHING gets to poppler, an embedding, or an LLM until all four pass.
    """
    assert_is_pdf(data)
    assert_within_size_limit(data)
    assert_page_count(data)
    return _render_pages(data)
