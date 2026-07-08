import io

from fastapi import APIRouter, File, HTTPException, UploadFile
from pdf2image import convert_from_bytes
from pypdf import PdfReader

from db.supabase_client import supabase
from models.resume import ResumeProfile, ResumeProfileUpdate
from services.llm import LlmApiError, ResumeParseError, parse_resume

router = APIRouter(prefix="/resume", tags=["resume"])


def _page_to_png_bytes(page_image) -> bytes:
    buf = io.BytesIO()
    page_image.save(buf, format="PNG")
    return buf.getvalue()


def _extract_raw_text(pdf_bytes: bytes) -> str:
    reader = PdfReader(io.BytesIO(pdf_bytes))
    return "\n".join(page.extract_text() or "" for page in reader.pages)


def _upsert_profile(profile: ResumeProfile, raw_text: str) -> dict:
    payload = {
        "name": profile.name,
        "headline": profile.headline,
        "skills": profile.skills,
        "experience": [e.model_dump() for e in profile.experience],
        "projects": [p.model_dump() for p in profile.projects],
        "education": [ed.model_dump() for ed in profile.education],
        "raw_resume_text": raw_text,
    }
    # Single-user until Brick 9 auth lands: one profile row, upserted in place.
    existing = supabase.table("profiles").select("id").limit(1).execute()
    if existing.data:
        profile_id = existing.data[0]["id"]
        result = supabase.table("profiles").update(payload).eq("id", profile_id).execute()
    else:
        result = supabase.table("profiles").insert(payload).execute()
    return result.data[0]


@router.post("/parse")
async def parse_resume_endpoint(file: UploadFile = File(...)):
    if file.content_type != "application/pdf":
        raise HTTPException(status_code=400, detail="Only PDF uploads are supported")

    pdf_bytes = await file.read()
    raw_text = _extract_raw_text(pdf_bytes)
    page_images = [_page_to_png_bytes(img) for img in convert_from_bytes(pdf_bytes)]

    try:
        profile = parse_resume(page_images)
    except ResumeParseError as e:
        raise HTTPException(status_code=422, detail=f"Could not parse resume: {e}")
    except LlmApiError as e:
        raise HTTPException(status_code=502, detail=f"Resume parser is temporarily unavailable: {e}")

    row = _upsert_profile(profile, raw_text)
    return {"data": row, "error": None}


@router.patch("/profile/{profile_id}")
async def update_profile(profile_id: str, update: ResumeProfileUpdate):
    payload = update.model_dump(exclude_unset=True)
    result = supabase.table("profiles").update(payload).eq("id", profile_id).execute()
    if not result.data:
        raise HTTPException(status_code=404, detail="Profile not found")
    return {"data": result.data[0], "error": None}
