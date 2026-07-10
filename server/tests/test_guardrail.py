from models.tailor import TailoredBullet
from services.guardrail import verify_bullet, verify_bullets

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
