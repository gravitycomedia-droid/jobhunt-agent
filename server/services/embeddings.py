import time

from google import genai
from google.genai import types

from config import settings
from db.supabase_client import supabase

# The five-line cosine-distance explainer promised in docs/BRICKS.md Brick 4:
# an embedding is a vector; cosine distance measures the ANGLE between two
# vectors, not their length, so it's unaffected by resume/job-description
# length. pgvector's `<=>` operator computes that distance directly in SQL —
# 0 means identical direction (perfect match), 2 means opposite. We store
# `1 - distance` as "similarity" so bigger always means more alike.

_client = genai.Client(api_key=settings.gemini_api_key)

# 100 real (long) job descriptions in one request tripped the free tier's
# per-request token-volume cap in testing; 50 real job descriptions (~32K
# chars) did not. Kept conservative rather than tuned to the exact edge.
_BATCH_SIZE = 50


def _log_embed_call(
    *, count: int, billable_chars: int | None, latency_ms: int, ok: bool, profile_id: str | None = None
) -> None:
    supabase.table("llm_calls").insert(
        {
            "task": "embed",
            "model": settings.gemini_embed_model,
            "prompt_hash": f"batch:{count}",
            "tokens_in": billable_chars,
            "tokens_out": None,
            "latency_ms": latency_ms,
            "validation_passed": ok,
            "retried": False,
            "profile_id": profile_id,
        }
    ).execute()


def _embed_batch(texts: list[str], profile_id: str | None = None) -> list[list[float]]:
    start = time.monotonic()
    try:
        response = _client.models.embed_content(
            model=settings.gemini_embed_model,
            contents=texts,
            # output_dimensionality pins gemini-embedding-001's output to 768
            # so it matches the `vector(768)` columns migration 001 already
            # defined — see ADR-006.
            config=types.EmbedContentConfig(task_type="SEMANTIC_SIMILARITY", output_dimensionality=768),
        )
    except Exception:
        _log_embed_call(
            count=len(texts),
            billable_chars=None,
            latency_ms=int((time.monotonic() - start) * 1000),
            ok=False,
            profile_id=profile_id,
        )
        raise

    latency_ms = int((time.monotonic() - start) * 1000)
    billable_chars = response.metadata.billable_character_count if response.metadata else None
    _log_embed_call(count=len(texts), billable_chars=billable_chars, latency_ms=latency_ms, ok=True, profile_id=profile_id)

    return [list(e.values) for e in (response.embeddings or [])]


def embed_texts(texts: list[str], profile_id: str | None = None) -> list[list[float]]:
    """Embed a list of strings with text-embedding-004, batching requests of
    more than _BATCH_SIZE and logging one llm_calls row per batch
    (Golden Rule 5). Order of the returned vectors matches `texts`.
    `profile_id` attributes cost to a user when embedding their profile
    (Phase 3); job-pool embeddings have no owner (shared pool) and are
    logged with it left as None.
    """
    if not texts:
        return []

    vectors: list[list[float]] = []
    for i in range(0, len(texts), _BATCH_SIZE):
        vectors.extend(_embed_batch(texts[i : i + _BATCH_SIZE], profile_id=profile_id))
    return vectors


def embed_text(text: str, profile_id: str | None = None) -> list[float]:
    """Embed a single string. Convenience wrapper around embed_texts()."""
    return embed_texts([text], profile_id=profile_id)[0]


def profile_embedding_text(profile: dict) -> str:
    """Flattens the fields of a stored profile row into one string for
    embedding — headline and skills carry the most matching signal, so they
    lead; experience/project bullets follow.
    """
    parts = [profile.get("headline") or "", ", ".join(profile.get("skills") or [])]
    for exp in profile.get("experience") or []:
        parts.append(f"{exp.get('role', '')} at {exp.get('company', '')}: {'; '.join(exp.get('bullets') or [])}")
    for proj in profile.get("projects") or []:
        parts.append(f"{proj.get('name', '')}: {proj.get('description', '')}")
    return "\n".join(p for p in parts if p)


def job_embedding_text(job: dict) -> str:
    """Flattens a job row into one string for embedding — title/company
    carry the most matching signal, so they lead; description follows.
    """
    parts = [job.get("title") or "", job.get("company") or "", job.get("description") or ""]
    return "\n".join(p for p in parts if p)
