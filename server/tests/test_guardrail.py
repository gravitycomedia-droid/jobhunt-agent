from models.tailor import TailoredBullet
from services.guardrail import compute_gaps, verify_bullet, verify_bullets, verify_skills

RAW_RESUME = """
Jane Doe
Senior Backend Engineer

Experience:
Backend Engineer at Acme Corp (2021-2024)
- Led migration of monolith to microservices, cutting deploy time by 40%
- Built internal API gateway used by 12 downstream teams
- Mentored 3 junior engineers on Python best practices
"""


def test_verify_bullet_passes_for_exact_match():
    assert verify_bullet("Led migration of monolith to microservices, cutting deploy time by 40%", RAW_RESUME) is True


def test_verify_bullet_passes_for_close_rewording():
    # A rephrase of the *original* (not the tailored output) should still
    # trace back — fuzzy matching exists so the LLM's exact phrasing of
    # `original` doesn't have to be byte-identical to the source text.
    assert verify_bullet("Led migration of monolith to microservices, cutting deploy time by 40 percent", RAW_RESUME) is True


def test_verify_bullet_fails_for_fabricated_claim():
    # Golden Rule 4: an invented employer/skill must never pass.
    assert verify_bullet("Architected a distributed ML platform at Google", RAW_RESUME) is False


def test_verify_bullets_counts_pass_and_fail_per_bullet():
    bullets = [
        TailoredBullet(
            original="Led migration of monolith to microservices, cutting deploy time by 40%",
            tailored="Led a large-scale microservices migration, reducing deploy latency by 40%",
            job_keyword_targeted="microservices",
        ),
        TailoredBullet(
            original="Shipped a Kubernetes operator used by 500 clusters",
            tailored="Built and shipped a Kubernetes operator adopted across 500 clusters",
            job_keyword_targeted="kubernetes",
        ),
    ]
    results = verify_bullets(bullets, RAW_RESUME)

    assert results[0]["guardrail_pass"] is True
    assert results[1]["guardrail_pass"] is False
    assert results[0]["keyword"] == "microservices"
    assert results[1]["tailored"] == "Built and shipped a Kubernetes operator adopted across 500 clusters"


# ---------- ADR-019: skill subsetting + gap check ----------

REAL_SKILLS = ["Python", "FastAPI", "PostgreSQL", "Docker"]


def test_verify_skills_keeps_llm_order_and_appends_dropped():
    # LLM reordered to lead with FastAPI/Python; PostgreSQL/Docker it dropped
    # must still appear (full real set, just reprioritized).
    ordered = verify_skills(["FastAPI", "Python"], REAL_SKILLS)
    assert ordered[:2] == ["FastAPI", "Python"]
    assert set(ordered) == set(REAL_SKILLS)


def test_verify_skills_drops_invented_skills():
    # Golden Rule 4: a skill the candidate never listed can never enter the
    # column, even if the LLM tries to slip it in.
    ordered = verify_skills(["Kubernetes", "Python"], REAL_SKILLS)
    assert "Kubernetes" not in ordered
    assert set(ordered) == set(REAL_SKILLS)


def test_verify_skills_tolerates_light_recasing():
    ordered = verify_skills(["fastapi", "python"], REAL_SKILLS)
    # Matched back to the real spelling, not the LLM's lowercase.
    assert ordered[0] == "FastAPI"
    assert ordered[1] == "Python"


def test_compute_gaps_flags_only_missing_requirements():
    gaps = compute_gaps(["Python", "React", "Kubernetes"], REAL_SKILLS, RAW_RESUME)
    assert "Python" not in gaps  # a real skill
    assert "React" in gaps and "Kubernetes" in gaps  # neither listed nor in text


def test_compute_gaps_counts_skill_named_only_in_resume_text():
    # A requirement mentioned in the raw resume text counts as met even if it
    # isn't in the structured skills list.
    gaps = compute_gaps(["microservices"], REAL_SKILLS, RAW_RESUME)
    assert gaps == []
