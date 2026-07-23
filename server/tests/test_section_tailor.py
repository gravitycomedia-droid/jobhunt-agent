from models.tailor import TailoredBullet
from services.guardrail import build_source_context
from services.section_tailor import (
    PER_EXPERIENCE_CAP,
    assemble_bullets,
    keyword_relevance,
    jd_token_set,
    score_bullets,
    select_bullets,
)

JD = "Backend engineer building Python FastAPI services on PostgreSQL and Docker at scale"

# Index 0 = most-recent role (résumé order). Its bullets are deliberately
# LOW-relevance to the JD, to prove the most-recent role is kept anyway.
EXPERIENCES = [
    {
        "role": "Operations Lead",
        "company": "Acme Corp",
        "bullets": [
            "Coordinated the annual office relocation across three cities",
            "Ran the internal newsletter and event calendar",
        ],
    },
    {
        "role": "Backend Engineer",
        "company": "Beta Labs",
        "bullets": [
            "Built Python FastAPI services backed by PostgreSQL",
            "Containerised the deploy pipeline with Docker",
            "Organised the office cricket league every weekend",
        ],
    },
]


def test_keyword_relevance_is_a_fraction():
    jd = jd_token_set(JD)
    assert keyword_relevance("Built Python FastAPI services on PostgreSQL", jd) > 0.5
    assert keyword_relevance("Coordinated the office relocation", jd) == 0.0


def test_selection_is_deterministic():
    a = select_bullets(EXPERIENCES, score_bullets(EXPERIENCES, JD))
    b = select_bullets(EXPERIENCES, score_bullets(EXPERIENCES, JD))
    assert a.selected == b.selected
    assert a.trimmed == b.trimmed


def test_most_recent_role_never_drops():
    result = select_bullets(EXPERIENCES, score_bullets(EXPERIENCES, JD))
    recent_selected = [s for s in result.selected if s["experience_index"] == 0]
    # Both low-relevance bullets of the current role survive — floor ignored.
    assert len(recent_selected) == 2
    assert not any(t["experience_index"] == 0 for t in result.trimmed)


def test_irrelevant_bullet_in_old_role_is_trimmed_and_disclosed():
    result = select_bullets(EXPERIENCES, score_bullets(EXPERIENCES, JD))
    trimmed_texts = {t["original"] for t in result.trimmed}
    assert "Organised the office cricket league every weekend" in trimmed_texts
    # The two on-topic bullets of the old role survive.
    beta_selected = {s["original"] for s in result.selected if s["experience_index"] == 1}
    assert "Built Python FastAPI services backed by PostgreSQL" in beta_selected


def test_per_experience_cap_trims_overflow():
    many = [{"role": "Dev", "company": "X", "bullets": [f"Shipped feature {i} in Python" for i in range(PER_EXPERIENCE_CAP + 3)]}]
    result = select_bullets(many, score_bullets(many, JD))
    assert len(result.selected) == PER_EXPERIENCE_CAP
    assert len(result.trimmed) == 3
    assert all("cap" in t["reason"].lower() for t in result.trimmed)


def test_every_source_bullet_is_either_selected_or_trimmed():
    result = select_bullets(EXPERIENCES, score_bullets(EXPERIENCES, JD))
    total = sum(len(e["bullets"]) for e in EXPERIENCES)
    assert len(result.selected) + len(result.trimmed) == total


# ---------- assemble_bullets: merge LLM survivors + trimmed ----------

PROFILE = {
    "id": "p1",
    "name": "Dev",
    "skills": ["Python", "FastAPI", "PostgreSQL", "Docker"],
    "raw_resume_text": "Built Python FastAPI services backed by PostgreSQL. Containerised with Docker.",
    "experience": EXPERIENCES,
}


def test_assemble_maps_experience_index_and_flags_trimmed():
    selection = select_bullets(EXPERIENCES, score_bullets(EXPERIENCES, JD))
    ctx = build_source_context(PROFILE)
    # LLM rephrases the two Beta backend survivors faithfully.
    tailored = [
        TailoredBullet(
            original="Built Python FastAPI services backed by PostgreSQL",
            tailored="Built Python FastAPI services on PostgreSQL",
            job_keyword_targeted="fastapi",
        ),
        TailoredBullet(
            original="Containerised the deploy pipeline with Docker",
            tailored="Containerised the deploy pipeline using Docker",
            job_keyword_targeted="docker",
        ),
    ]
    bullets, flags = assemble_bullets(selection, tailored, ctx)

    survivors = [b for b in bullets if b["selected"]]
    trimmed = [b for b in bullets if not b["selected"]]
    # Every stored bullet accounts for a source bullet.
    assert len(survivors) == len(selection.selected)
    assert len(trimmed) == len(selection.trimmed)
    # Faithful rephrases pass the guardrail; nothing flagged.
    assert flags == 0
    # The two rephrased survivors landed under Beta Labs (experience_index 1).
    beta = [b for b in survivors if b["tailored"].startswith("Built Python") or "Docker" in b["tailored"]]
    assert all(b["experience_index"] == 1 for b in beta)
    # Trimmed bullets are never auto-accepted (they're the restore list).
    assert all(b["accepted"] is False and b.get("trim_reason") for b in trimmed)


def test_assemble_flags_an_inflated_survivor():
    selection = select_bullets(EXPERIENCES, score_bullets(EXPERIENCES, JD))
    ctx = build_source_context(PROFILE)
    tailored = [
        TailoredBullet(
            original="Built Python FastAPI services backed by PostgreSQL",
            tailored="Built Python FastAPI services serving 5,000,000 requests",  # invented metric
            job_keyword_targeted="fastapi",
        )
    ]
    bullets, flags = assemble_bullets(selection, tailored, ctx)
    assert flags >= 1
    flagged = next(b for b in bullets if b["selected"] and not b["guardrail_pass"])
    assert flagged["accepted"] is False
